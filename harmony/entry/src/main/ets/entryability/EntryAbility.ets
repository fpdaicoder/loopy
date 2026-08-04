import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { abilityAccessCtrl, Permissions } from '@kit.AbilityKit';
import { abilityConnectionManager } from '@kit.DistributedServiceKit';
import { ReceivedDataHandler } from '@loop/agent-core';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import fs from '@ohos.file.fs';

const DOMAIN = 0x0000;
const LOG_TAG = 'Loop';
// 必须与 agent_core 中 AbilityConnectionClient.SERVICE_NAME 保持一致：source/sink 双端
// 使用同一 serviceName 才能建立协同会话。当前值为 'loopDeviceSession'。
const COLLAB_SERVICE_NAME: string = 'loopDeviceSession';

// DISTRIBUTED_DATASYNC 是 user_grant 权限，安装时不会自动授予，必须运行时弹窗请求。
// 注意：READ_IMAGEVIDEO 是受限权限，普通调试签名声明会导致安装失败（code:9568289），
// 故未声明；photo_album 的 list 路径运行时若无权限会抛错并返回明确提示，
// pick 路径（系统选择器）不依赖该权限，照常可用。
const REQUIRED_PERMISSIONS: Permissions[] = [
  'ohos.permission.DISTRIBUTED_DATASYNC'
];

export default class EntryAbility extends UIAbility {
  // sink 端收到字节流时的处理回调。由外部业务注册（如照片→存 .jpg + 通知 SaveButton）。
  // 不注册则走默认行为：存 recv_<seq>.bin + 通知 Index 显示 SaveButton。
  private dataHandler: ReceivedDataHandler | null = null;

  /**
   * 注册收到字节流时的处理回调。不同业务场景注册不同 handler。
   * 不注册则走默认行为（存 .bin + 通知 SaveButton）。
   */
  registerDataHandler(handler: ReceivedDataHandler): void {
    this.dataHandler = handler;
  }

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    hilog.info(DOMAIN, LOG_TAG, 'EntryAbility onCreate');
    this.requestRequiredPermissions();
  }

  private requestRequiredPermissions(): void {
    try {
      const manager = abilityAccessCtrl.createAtManager();
      manager.requestPermissionsFromUser(
        this.context, REQUIRED_PERMISSIONS, (err, result) => {
          if (err) {
            hilog.warn(DOMAIN, LOG_TAG, 'requestPermissionsFromUser err: %{public}s', JSON.stringify(err));
            return;
          }
          hilog.info(DOMAIN, LOG_TAG, 'permissions authResults=%{public}s',
            JSON.stringify(result.authResults));
        });
    } catch (error) {
      const message = error instanceof Error ? error.message : `${error}`;
      hilog.warn(DOMAIN, LOG_TAG, 'requestPermissionsFromUser failed: %{public}s', message);
    }
  }

  onDestroy(): void {
    hilog.info(DOMAIN, LOG_TAG, 'EntryAbility onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, LOG_TAG, 'EntryAbility onWindowStageCreate');
    windowStage.loadContent('pages/Index', (error) => {
      if (error.code) {
        hilog.error(DOMAIN, LOG_TAG, 'Failed to load content. Cause: %{public}s', JSON.stringify(error));
        return;
      }
      hilog.info(DOMAIN, LOG_TAG, 'Succeeded in loading content.');
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, LOG_TAG, 'EntryAbility onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, LOG_TAG, 'EntryAbility onForeground');
  }

  onBackground(): void {
    hilog.info(DOMAIN, LOG_TAG, 'EntryAbility onBackground');
  }

  /**
   * sink 端协同生命周期回调。source 端调用 abilityConnectionManager.connect() 后，
   * 本设备（被拉起方）会触发该回调。必须在此处用 wantParam 携带的 PeerInfo /
   * ConnectOption 重建会话，并调用 acceptConnect(sessionId, collabToken) 接受连接，
   * 否则 source 端 connect() 会以 errorCode 5（协同未接受）失败。
   *
   * 实现依据官方文档《跨设备连接 UIAbility 开发指南》中“设备B”一节。
   */
  onCollaborate(wantParam: Record<string, Object>): AbilityConstant.CollaborateResult {
    hilog.info(DOMAIN, LOG_TAG, 'EntryAbility onCollaborate');
    const param = wantParam['ohos.extra.param.key.supportCollaborateIndex'] as Record<string, Object>;
    if (param === undefined || param === null) {
      hilog.warn(DOMAIN, LOG_TAG, 'onCollaborate: missing supportCollaborateIndex, reject collaboration');
      return 1; // AbilityConstant.CollaborateResult.FAIL
    }
    this.acceptCollaboration(param);
    return 0; // AbilityConstant.CollaborateResult.SUCCESS
  }

  private acceptCollaboration(collabParam: Record<string, Object>): void {
    const sessionId = this.createSinkSession(collabParam);
    if (sessionId === -1) {
      hilog.warn(DOMAIN, LOG_TAG, 'acceptCollaboration: sink session not created, skip acceptConnect');
      return;
    }
    this.registerSinkSessionEvent(sessionId);
    const collabToken = collabParam['ohos.dms.collabToken'] as string;
    if (collabToken === undefined || collabToken === null || collabToken.length === 0) {
      hilog.warn(DOMAIN, LOG_TAG, 'acceptCollaboration: missing collabToken, skip acceptConnect');
      return;
    }
    abilityConnectionManager.acceptConnect(sessionId, collabToken).then(() => {
      AppStorage.setOrCreate<number>('loopSinkSessionId', sessionId);
      hilog.info(DOMAIN, LOG_TAG, 'acceptConnect ok sessionId=%{public}d', sessionId);
    }).catch((error: Object) => {
      const message = error instanceof Error ? error.message : `${error}`;
      hilog.error(DOMAIN, LOG_TAG, 'acceptConnect failed: %{public}s', message);
    });
  }

  private createSinkSession(collabParam: Record<string, Object>): number {
    let sessionId = -1;
    const peerInfoRaw = collabParam['PeerInfo'] as abilityConnectionManager.PeerInfo;
    if (peerInfoRaw === undefined || peerInfoRaw === null) {
      hilog.warn(DOMAIN, LOG_TAG, 'createSinkSession: PeerInfo missing in collabParam');
      return sessionId;
    }
    // 补全 serviceName：PeerInfo 由 source 传来，可能缺 serviceName（source 端已加，
    // 但 collabParam 序列化/反序列化可能丢），显式补上确保与 createAbilityConnectionSession
    // 的第一个参数一致——serviceName 缺失可能导致 sendData 报 no match session。
    const peerInfo: abilityConnectionManager.PeerInfo = {
      deviceId: peerInfoRaw.deviceId,
      bundleName: peerInfoRaw.bundleName,
      moduleName: peerInfoRaw.moduleName,
      abilityName: peerInfoRaw.abilityName,
      serviceName: COLLAB_SERVICE_NAME
    } as abilityConnectionManager.PeerInfo;
    const optionsRaw = collabParam['ConnectOption'] as abilityConnectionManager.ConnectOptions;
    const options: abilityConnectionManager.ConnectOptions = {
      needSendData: true,
      startOptions: optionsRaw?.startOptions ?? abilityConnectionManager.StartOptionParams.START_IN_FOREGROUND,
      parameters: optionsRaw?.parameters ?? {}
    } as abilityConnectionManager.ConnectOptions;
    hilog.info(DOMAIN, LOG_TAG, 'sink createSession options=%{public}s peerInfo=%{public}s',
      JSON.stringify(options), JSON.stringify(peerInfo));
    try {
      sessionId = abilityConnectionManager.createAbilityConnectionSession(
        COLLAB_SERVICE_NAME, this.context, peerInfo, options);
      hilog.info(DOMAIN, LOG_TAG, 'sink createSession sessionId=%{public}d', sessionId);
    } catch (error) {
      const message = error instanceof Error ? error.message : `${error}`;
      hilog.error(DOMAIN, LOG_TAG, 'sink createSession failed: %{public}s', message);
    }
    return sessionId;
  }

  private registerSinkSessionEvent(sessionId: number): void {
    try {
      abilityConnectionManager.on('connect', sessionId,
        (info: abilityConnectionManager.EventCallbackInfo): void => {
          hilog.info(DOMAIN, LOG_TAG, 'sink connect sessionId=%{public}d', info.sessionId);
        });
      abilityConnectionManager.on('disconnect', sessionId,
        (info: abilityConnectionManager.EventCallbackInfo): void => {
          hilog.info(DOMAIN, LOG_TAG, 'sink disconnect sessionId=%{public}d', info.sessionId);
        });
      abilityConnectionManager.on('receiveMessage', sessionId,
        (info: abilityConnectionManager.EventCallbackInfo): void => {
          const msg = info.msg ?? '';
          if (msg.length > 0) {
            // 待消费消息队列：Index 页面用 @StorageProp('loopSinkMessageSeq') 观察
            // 序号变化，变化时 drain 本队列并追加到 transcript（仅展示，不自动回发）。
            const pending = AppStorage.get<string[]>('loopSinkPendingMessages') ?? [];
            pending.push(msg);
            AppStorage.setOrCreate<string[]>('loopSinkPendingMessages', pending);
            const seq = (AppStorage.get<number>('loopSinkMessageSeq') ?? 0) + 1;
            AppStorage.setOrCreate<number>('loopSinkMessageSeq', seq);
          }
          hilog.info(DOMAIN, LOG_TAG, 'sink receiveMessage sessionId=%{public}d msg=%{public}s',
            info.sessionId, msg);
        });
      abilityConnectionManager.on('receiveData', sessionId,
        (info: abilityConnectionManager.EventCallbackInfo): void => {
          // 收到对端发来的字节流：交给业务 handler 或走默认行为（存沙箱 + 通知 SaveButton）。
          const data = info.data;
          if (data === undefined || data === null || data.byteLength === 0) {
            hilog.warn(DOMAIN, LOG_TAG, 'sink receiveData empty sessionId=%{public}d', info.sessionId);
            return;
          }
          hilog.info(DOMAIN, LOG_TAG, 'sink receiveData %{public}d bytes sessionId=%{public}d',
            data.byteLength, info.sessionId);
          // 有自定义 handler 则交给业务处理；否则走默认行为（存 .bin + 通知 SaveButton）。
          if (this.dataHandler !== null) {
            this.dataHandler(data, this.context);
            return;
          }
          this.defaultSinkDataHandler(data);
        });
    } catch (error) {
      const message = error instanceof Error ? error.message : `${error}`;
      hilog.warn(DOMAIN, LOG_TAG, 'sink register listener failed: %{public}s', message);
    }
  }

  /**
   * 默认行为：收到字节流后存沙箱 recv_<seq>.bin + 通知 Index 显示 SaveButton。
   * 业务可通过 registerDataHandler() 覆盖此行为（如照片存 .jpg + 通知 UI）。
   */
  private defaultSinkDataHandler(data: ArrayBuffer): void {
    const path = this.saveSinkReceivedData(data);
    AppStorage.setOrCreate<string>('loopSinkPendingFile', path);
    const seq = (AppStorage.get<number>('loopSinkFileSeq') ?? 0) + 1;
    AppStorage.setOrCreate<number>('loopSinkFileSeq', seq);
    const pending = AppStorage.get<string[]>('loopSinkPendingMessages') ?? [];
    pending.push('收到文件，点「保存到相册」可存入图库');
    AppStorage.setOrCreate<string[]>('loopSinkPendingMessages', pending);
    const msgSeq = (AppStorage.get<number>('loopSinkMessageSeq') ?? 0) + 1;
    AppStorage.setOrCreate<number>('loopSinkMessageSeq', msgSeq);
    hilog.info(DOMAIN, LOG_TAG, 'defaultSinkDataHandler saved %{public}d bytes to %{public}s',
      data.byteLength, path);
  }

  /**
   * 将 sink 端收到的字节流写入沙箱 cacheDir/recv_<seq>.bin，返回路径。
   * 不假设文件类型，统一 .bin；后续保存时根据实际类型选 PhotoType。
   */
  private saveSinkReceivedData(data: ArrayBuffer): string {
    const seq = (AppStorage.get<number>('loopSinkReceivedDataSeq') ?? 0) + 1;
    AppStorage.setOrCreate<number>('loopSinkReceivedDataSeq', seq);
    const path = `${this.context.cacheDir}/recv_${seq}.bin`;
    try {
      const file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, data);
      } finally {
        fs.closeSync(file);
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : `${error}`;
      hilog.warn(DOMAIN, LOG_TAG, 'saveSinkReceivedData failed: %{public}s', message);
    }
    return path;
  }

  // 注：系统图片查看器走 viewData+FLAG_AUTH_READ_URI_PERMISSION 打不开应用沙箱文件
  // （跨应用沙箱墙），已弃用。改为 Index 页面 SaveButton 控件授权存进媒体库。
}
