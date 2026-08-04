import { common } from '@kit.AbilityKit';
import { abilityConnectionManager } from '@kit.DistributedServiceKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import fs from '@ohos.file.fs';
import { DeviceManagerClient, DiscoveredDevice } from './DeviceManagerClient';

const LOG_DOMAIN: number = 0x1301;
const LOG_TAG: string = 'LoopAbilityConn';
const SERVICE_NAME: string = 'loopDeviceSession';
// 必须与 AppScope/app.json5 的 bundleName 一致，且与 sink 端 EntryAbility 的
// COLLAB_SERVICE_NAME 同名，source/sink 双端才能建立协同会话。
const BUNDLE_NAME: string = 'com.example.agentdfp';
const MODULE_NAME: string = 'entry';
const ABILITY_NAME: string = 'EntryAbility';

/**
 * 收到字节流数据时的处理回调。不同业务（照片/视频/其他文件）注册不同 handler，
 * 各自决定如何存盘、通知 UI。
 * @param data 收到的原始字节流
 * @param context UIAbilityContext（可用来拿 cacheDir 等）
 */
export type ReceivedDataHandler = (data: ArrayBuffer, context: common.UIAbilityContext) => void;

/**
 * 封装跨设备 Ability 连接会话（{@link abilityConnectionManager}）。负责建会话、
 * 收发消息、监听事件。绑定后的 networkId 由 {@link DeviceManagerClient} 提供。
 *
 * API 签名取自官方文档《跨设备连接 UIAbility 开发指南》：
 * - createAbilityConnectionSession(serviceName, context, peerInfo, connectOptions): sessionId
 * - connect(sessionId): Promise<ConnectResult>          source 端发起连接
 * - acceptConnect(sessionId, token): Promise<void>       sink 端接受连接
 * - sendMessage(sessionId, msg): Promise<void>           发送字符串
 * - sendData(sessionId, data: ArrayBuffer): Promise<void> 发送二进制
 * - on('connect' | 'disconnect' | 'receiveMessage' | 'receiveData', sessionId, cb)
 * - disconnect(sessionId) / destroyAbilityConnectionSession(sessionId)
 */
export class AbilityConnectionClient {
  private context: common.UIAbilityContext;
  private dmClient: DeviceManagerClient;
  private sessionId: number = -1;
  private connected: boolean = false;
  private lastError: string = '';
  private receivedMessages: string[] = [];
  // 标记本实例的 sessionId 是否由 adoptSinkSession 接管（而非 source 端 connect 自建）。
  // adopted 会话由 EntryAbility 的 onCollaborate 创建，close() 不能销毁它，否则
  // sink 端 agent 切换 ToolRegistry 时旧 registry.close() 会误毁协同会话。
  private adopted: boolean = false;
  // 收到字节流时的处理回调。由外部业务注册（如照片→存 .jpg + 通知 SaveButton）。
  // 不注册则走默认行为：存 recv_<seq>.bin + 通知 Index 显示 SaveButton。
  private dataHandler: ReceivedDataHandler | null = null;

  constructor(context: common.UIAbilityContext, dmClient: DeviceManagerClient) {
    this.context = context;
    this.dmClient = dmClient;
  }

  /**
   * 注册收到字节流时的处理回调。不同业务场景注册不同 handler：
   * - 照片传输：handler 存 .jpg + 写 AppStorage('loopSourcePendingFile') 通知 SaveButton
   * - 视频传输：handler 存 .mp4 + 通知 UI
   * - 其他文件：handler 自定义存盘逻辑
   * 不注册则走默认行为（存 .bin + 通知 SaveButton）。
   */
  registerDataHandler(handler: ReceivedDataHandler): void {
    this.dataHandler = handler;
  }

  async initialize(): Promise<void> {
    // 会话按需创建，初始化仅做前置校验。
    this.lastError = '';
    if (!this.dmClient.isAvailable()) {
      this.lastError = 'DeviceManager 未初始化，无法解析对端 networkId。';
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'initialize: %{public}s', this.lastError);
    }
  }

  isAvailable(): boolean {
    return this.dmClient.isAvailable();
  }

  statusText(): string {
    if (this.lastError.length > 0) {
      return `unavailable (${this.lastError})`;
    }
    return this.connected ? `connected (sessionId=${this.sessionId})` : 'disconnected';
  }

  /**
   * 建立到指定 deviceId 的会话。deviceId 必须来自
   * {@link DeviceManagerClient.listTrusted}（已绑定设备，含 networkId）。
   */
  async connect(deviceId: string): Promise<string> {
    if (!this.isAvailable()) {
      return 'DeviceManager 未初始化。';
    }
    const trusted = this.dmClient.listTrusted();
    const networkId = this.resolveNetworkId(deviceId, trusted);
    if (networkId.length === 0) {
      return `未找到设备 ${deviceId} 的 networkId，请先绑定设备。可用设备：${this.formatTrusted(trusted)}`;
    }
    if (this.sessionId >= 0) {
      return `已存在会话 sessionId=${this.sessionId}，请先 disconnect。`;
    }
    const peerInfo: abilityConnectionManager.PeerInfo = {
      deviceId: networkId,
      bundleName: BUNDLE_NAME,
      moduleName: MODULE_NAME,
      abilityName: ABILITY_NAME,
      serviceName: SERVICE_NAME
    } as abilityConnectionManager.PeerInfo;
    const connectOptions: abilityConnectionManager.ConnectOptions = {
      needSendData: true,
      startOptions: abilityConnectionManager.StartOptionParams.START_IN_FOREGROUND,
      parameters: {}
    } as abilityConnectionManager.ConnectOptions;
    try {
      this.sessionId = abilityConnectionManager.createAbilityConnectionSession(
        SERVICE_NAME, this.context, peerInfo, connectOptions);
      hilog.info(LOG_DOMAIN, LOG_TAG, 'createSession sessionId=%{public}d', this.sessionId);
    } catch (error) {
      this.lastError = this.errorMessage(error);
      return `建会话失败：${this.lastError}`;
    }
    this.registerReceiveListener(this.sessionId);
    try {
      const result = await abilityConnectionManager.connect(this.sessionId);
      this.connected = Boolean(result.isConnected);
      return this.connected
        ? `已连接设备 ${deviceId}（sessionId=${this.sessionId}）。`
        : `连接未成功：${JSON.stringify(result)}。请确认对端设备已安装本应用、已组网，并在前台/已申请长时任务以触发 onCollaborate 接受连接。`;
    } catch (error) {
      this.lastError = this.errorMessage(error);
      // connect 抛错（如 errorCode 5 / ret=29425730）通常是 sink 端未 acceptConnect：
      // 对端必须被拉起并在 onCollaborate 中调用 acceptConnect。同时需双端组网成功。
      return `连接失败：${this.lastError}（常见原因：对端未接受协同、双端未组网或 bundleName 不一致）`;
    }
  }

  /**
   * sink 端接管 onCollaborate 中由 EntryAbility 直接创建的会话。
   * source 端 connect 会拉起对端，对端在 onCollaborate 里调
   * createAbilityConnectionSession + acceptConnect 建立会话；本方法让 sink 端的
   * AbilityConnectionClient 实例拿到该 sessionId，从而 sendMessage 可用（回发消息）。
   *
   * receiveMessage 路径仍由 EntryAbility 拥有（推入 AppStorage 供 Index 展示），
   * 此处只注册 connect/disconnect 以维护 connected 状态，避免重复消费消息。
   * sessionId 由 EntryAbility 写入 AppStorage('loopSinkSessionId')。
   */
  adoptSinkSession(sessionId: number): void {
    if (sessionId < 0) {
      return;
    }
    if (this.sessionId >= 0) {
      // 已有会话（source 端自建，或 sink 已接管），不覆盖。
      return;
    }
    this.sessionId = sessionId;
    this.connected = true;
    this.adopted = true;
    try {
      abilityConnectionManager.on('connect', sessionId, (_info: abilityConnectionManager.EventCallbackInfo): void => {
        this.connected = true;
      });
      abilityConnectionManager.on('disconnect', sessionId, (_info: abilityConnectionManager.EventCallbackInfo): void => {
        this.connected = false;
      });
    } catch (error) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'adoptSinkSession register listener failed: %{public}s', this.errorMessage(error));
    }
    hilog.info(LOG_DOMAIN, LOG_TAG, 'adopted sink sessionId=%{public}d', sessionId);
  }

  /**
   * sink 端用已知 sessionId 直接回发，不依赖本实例的 adopted 状态
   *（adopt 链 AppStorage→@Watch→registry 时序脆弱，回发路径不应被它阻塞）。
   * sessionId 来自 AppStorage('loopSinkSessionId')，由 onCollaborate 建会话后写入，
   * receive 能收到即证明该会话存活，sendMessage 在其上可用。
   */
  async sendOnSession(sessionId: number, message: string): Promise<string> {
    if (sessionId < 0) {
      return '未接管协同会话，无法回发。';
    }
    if (message.trim().length === 0) {
      return '消息为空。';
    }
    try {
      await abilityConnectionManager.sendMessage(sessionId, message);
      return `已发送：${message}`;
    } catch (error) {
      this.lastError = this.errorMessage(error);
      return `发送失败：${this.lastError}`;
    }
  }

  /**
   * 发送字节流（如照片）。三方应用经文档确认可用 sendData 发 ArrayBuffer。
   * 供 source 端在已 connect 的会话上发送。
   */
  async sendData(data: ArrayBuffer): Promise<string> {
    if (this.sessionId < 0 || !this.connected) {
      return '无活动会话，请先 connect。';
    }
    if (data.byteLength === 0) {
      return '数据为空。';
    }
    try {
      await abilityConnectionManager.sendData(this.sessionId, data);
      return `已发送 ${data.byteLength} 字节。`;
    } catch (error) {
      this.lastError = this.errorMessage(error);
      return `发送字节失败：${this.lastError}`;
    }
  }

  /**
   * sink 端用已知 sessionId 直接发送字节流，不依赖 adopted 状态
   *（与 sendOnSession 文本回发一致的策略）。
   */
  async sendDataOnSession(sessionId: number, data: ArrayBuffer): Promise<string> {
    if (sessionId < 0) {
      return '未接管协同会话，无法发送。';
    }
    if (data.byteLength === 0) {
      return '数据为空。';
    }
    try {
      await abilityConnectionManager.sendData(sessionId, data);
      return `已发送 ${data.byteLength} 字节。`;
    } catch (error) {
      this.lastError = this.errorMessage(error);
      return `发送字节失败：${this.lastError}`;
    }
  }

  /** 发送字符串消息。 */
  async sendMessage(message: string): Promise<string> {
    if (this.sessionId < 0 || !this.connected) {
      return '无活动会话，请先 connect。';
    }
    if (message.trim().length === 0) {
      return '消息为空。';
    }
    try {
      await abilityConnectionManager.sendMessage(this.sessionId, message);
      return `已发送：${message}`;
    } catch (error) {
      this.lastError = this.errorMessage(error);
      return `发送失败：${this.lastError}`;
    }
  }

  /** 读取并清空自上次以来收到的消息。 */
  drainReceived(): string[] {
    const copy = this.receivedMessages.slice();
    this.receivedMessages = [];
    return copy;
  }

  async close(): Promise<void> {
    if (this.sessionId < 0) {
      return;
    }
    const id = this.sessionId;
    const isAdopted = this.adopted;
    this.sessionId = -1;
    this.connected = false;
    this.adopted = false;
    this.receivedMessages = [];
    // adopted 会话由 EntryAbility 的 onCollaborate 创建，不应被 close 销毁——
    // 否则 sink 端 agent 切换 ToolRegistry（skill 模式重建）时旧 registry.close()
    // 会误毁协同会话，导致后续 sendData 报 401 no match session。
    if (isAdopted) {
      hilog.info(LOG_DOMAIN, LOG_TAG, 'close skip adopted sessionId=%{public}d', id);
      return;
    }
    try {
      abilityConnectionManager.disconnect(id);
    } catch (error) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'disconnect failed: %{public}s', this.errorMessage(error));
    }
    try {
      abilityConnectionManager.destroyAbilityConnectionSession(id);
    } catch (error) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'destroySession failed: %{public}s', this.errorMessage(error));
    }
    hilog.info(LOG_DOMAIN, LOG_TAG, 'closed sessionId=%{public}d', id);
  }

  private registerReceiveListener(sessionId: number): void {
    try {
      abilityConnectionManager.on('receiveMessage', sessionId, (info: abilityConnectionManager.EventCallbackInfo): void => {
        const payload = info.msg ?? '';
        // 两路独立消费：
        //  1) receivedMessages[] —— agent 的 distributed_device received action 经 drainReceived() 取（按需查）。
        //  2) AppStorage 待消费队列 + 序号 —— Index 用 @Watch 监听序号，drain 后即时追加到 transcript「对端」（自动展示）。
        //    两队列各自 drain，互不影响：UI 即时显示，不影响 agent 后续读取（agent 读的是 receivedMessages）。
        this.receivedMessages.push(payload);
        if (payload.length > 0) {
          const pending = AppStorage.get<string[]>('loopSourcePendingMessages') ?? [];
          pending.push(payload);
          AppStorage.setOrCreate<string[]>('loopSourcePendingMessages', pending);
          const seq = (AppStorage.get<number>('loopSourceMessageSeq') ?? 0) + 1;
          AppStorage.setOrCreate<number>('loopSourceMessageSeq', seq);
        }
        hilog.info(LOG_DOMAIN, LOG_TAG, 'receiveMessage sessionId=%{public}d', sessionId);
      });
      abilityConnectionManager.on('connect', sessionId, (_info: abilityConnectionManager.EventCallbackInfo): void => {
        this.connected = true;
      });
      abilityConnectionManager.on('disconnect', sessionId, (_info: abilityConnectionManager.EventCallbackInfo): void => {
        this.connected = false;
      });
      abilityConnectionManager.on('receiveData', sessionId, (info: abilityConnectionManager.EventCallbackInfo): void => {
        // EventCallbackInfo.data 携带 ArrayBuffer（字段名 data 基于文档；若 SDK 不认可编译器会报）。
        const data = info.data;
        if (data === undefined || data === null || data.byteLength === 0) {
          hilog.warn(LOG_DOMAIN, LOG_TAG, 'receiveData empty sessionId=%{public}d', sessionId);
          return;
        }
        hilog.info(LOG_DOMAIN, LOG_TAG, 'receiveData %{public}d bytes sessionId=%{public}d', data.byteLength, sessionId);
        // 有自定义 handler 则交给业务处理；否则走默认行为（存 .bin + 通知 SaveButton）。
        if (this.dataHandler !== null) {
          this.dataHandler(data, this.context);
          return;
        }
        this.defaultDataHandler(data);
      });
    } catch (error) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'register listener failed: %{public}s', this.errorMessage(error));
    }
  }

  private resolveNetworkId(deviceId: string, trusted: DiscoveredDevice[]): string {
    for (let index = 0; index < trusted.length; index++) {
      const device = trusted[index];
      if (device.deviceId === deviceId || device.networkId === deviceId) {
        return device.networkId;
      }
    }
    return '';
  }

  private formatTrusted(trusted: DiscoveredDevice[]): string {
    if (trusted.length === 0) {
      return '(无已绑定设备)';
    }
    const parts: string[] = [];
    for (let index = 0; index < trusted.length; index++) {
      const device = trusted[index];
      parts.push(`${device.deviceName}(${device.deviceId})`);
    }
    return parts.join(', ');
  }

  private errorMessage(error: Object): string {
    // HarmonyOS 的 BusinessError 是 {code, message, ...}，不是 Error 实例，
    // `${error}` 会返回 [object Object] 吞掉真错。优先取 .code/.message 兜底。
    if (error instanceof Error) {
      return error.message;
    }
    const record = error as Record<string, Object>;
    const code = record.code;
    const message = record.message;
    const codeText = code === undefined || code === null ? '' : `code=${code}`;
    const messageText = message === undefined || message === null ? '' : `${message}`;
    const parts: string[] = [];
    if (codeText.length > 0) {
      parts.push(codeText);
    }
    if (messageText.length > 0) {
      parts.push(messageText);
    }
    return parts.length > 0 ? parts.join(' ') : JSON.stringify(error);
  }

  /**
   * 默认行为：收到字节流后存沙箱 recv_<seq>.bin + 通知 Index 显示 SaveButton。
   * 业务可通过 registerDataHandler() 覆盖此行为（如照片存 .jpg + 通知 UI）。
   */
  private defaultDataHandler(data: ArrayBuffer): void {
    const path = this.saveReceivedData(data);
    AppStorage.setOrCreate<string>('loopSourcePendingFile', path);
    const seq = (AppStorage.get<number>('loopSourceFileSeq') ?? 0) + 1;
    AppStorage.setOrCreate<number>('loopSourceFileSeq', seq);
    const pending = AppStorage.get<string[]>('loopSourcePendingMessages') ?? [];
    pending.push('收到文件，点「保存到相册」可存入图库');
    AppStorage.setOrCreate<string[]>('loopSourcePendingMessages', pending);
    const msgSeq = (AppStorage.get<number>('loopSourceMessageSeq') ?? 0) + 1;
    AppStorage.setOrCreate<number>('loopSourceMessageSeq', msgSeq);
    hilog.info(LOG_DOMAIN, LOG_TAG, 'defaultDataHandler saved %{public}d bytes to %{public}s', data.byteLength, path);
  }

  /**
   * 将收到的字节流写入沙箱 cacheDir/recv_<seq>.bin，返回保存路径。
   * 不假设文件类型（照片/视频/其他），统一用 .bin 扩展名；后续保存到媒体库时
   * 根据实际类型选 PhotoType。seq 自增保证文件名不冲突。
   */
  private saveReceivedData(data: ArrayBuffer): string {
    const seq = (AppStorage.get<number>('loopReceivedDataSeq') ?? 0) + 1;
    AppStorage.setOrCreate<number>('loopReceivedDataSeq', seq);
    const dir = this.context.cacheDir;
    const path = `${dir}/recv_${seq}.bin`;
    try {
      const file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, data);
      } finally {
        fs.closeSync(file);
      }
    } catch (error) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'saveReceivedData failed: %{public}s', this.errorMessage(error));
    }
    return path;
  }
}
