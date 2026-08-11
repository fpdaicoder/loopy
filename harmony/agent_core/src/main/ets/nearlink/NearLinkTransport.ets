import dataTransfer from '@ohos.nearlink.dataTransfer';
import nearlinkConstant from '@ohos.nearlink.constant';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import util from '@ohos.util';

const LOG_DOMAIN: number = 0x1304;
const LOG_TAG: string = 'LoopNearLinkXfer';

/**
 * 文件分片二进制帧协议（内嵌头，单次 writeData 发一片）。
 * 格式：[magic:1B][kind:1B][seq:4B][index:4B][totalChunks:4B][dataLen:4B][data:dataLen]
 *   - magic=0x55：帧同步标记，收端据此区分二进制文件帧与纯文本消息。
 *   - kind：0=file_begin（首片，含 total 字段在 head 扩展）、1=file_data、2=file_end。
 *   - seq：文件序号（全局自增，收端据此命名 recv_<seq>.bin）。
 *   - index：当前数据片的 0-based 序号。
 *   - totalChunks：该文件总片数。
 *   - dataLen：本片数据负载字节数（不含头）。
 * file_begin 片额外在 data 区前 4 字节放 total（文件总字节数），供收端提前获知大小。
 * 头总长 18 字节，收端按定长解析，不依赖 JSON。
 */
export const NEARLINK_FILE_FRAME_MAGIC: number = 0x55;
export const NEARLINK_FILE_FRAME_HEAD_LEN: number = 18;
export const NEARLINK_FILE_KIND_BEGIN: number = 0;
export const NEARLINK_FILE_KIND_DATA: number = 1;
export const NEARLINK_FILE_KIND_END: number = 2;

/** 文件帧解析结果，供 FileReassembler 使用。 */
export interface FileFrameInfo {
  kind: number;       // NEARLINK_FILE_KIND_BEGIN/DATA/END
  seq: number;        // 文件序号
  index: number;      // 当前片 0-based
  totalChunks: number;
  dataLen: number;    // 本片数据字节数
  dataOffset: number; // 帧内数据负载起始下标
  totalSize: number;  // 仅 begin 片有效，文件总字节；其余 -1
}

/**
 * 星闪数据传输端口 UUID。双端（source/sink）必须一致：
 *   - 双端都调 createPort(同一 UUID) 注册端口通道
 *   - source 端调 connect({address, uuid, transferMode}) 建链
 *   - 双端用 writeData({address, uuid, data}) / onReadData 收发
 * 文档原文：「同一设备可以同时承担数据发送端和接收端的角色」——对称端口模型，无需 createServer。
 *
 * ⚠️ UUID 不能是"星闪标准 UUID"：中间三段不能是 FC70-11EA-B720（星闪标准基签名，
 * 类似蓝牙 0000-1000-8000-00805F9B34FB）。旧 UUID `37bea880-fc70-11ea-b720-0000000099ab`
 * 命中该签名，26.0.0 SDK 的 createPort 报 errCode 36100044「NearLink standard UUIDs not allowed」。
 * 文档示例用 FFFFFFFF-1234-5678-ABCD-000000001234（非标准基）。此处用自定义 v4 UUID，全 hex、
 * 中间三段 3a4d-4971-8b6f 不撞标准基，双端共享同一常量即可。
 */
export const NEARLINK_PORT_UUID: string = '9b2c5e8f-3a4d-4971-8b6f-2c1d5e3a7b04';

/**
 * 星闪广播/扫描 manufacturerData 过滤约定（双端对称）。
 * scan.ScanFilters 不认 serviceUuid 字段（真机报 Unexpect object property name: "serviceUuid"），
 * 但认 manufacturerData（日志 ParseScanFilterManufactureDataParameters 解析 manufacturerId）。
 * 广播端在 AdvertisingData.manufacturerData 发 {manufacturerId, data}，
 * 扫描端 ScanFilters.manufacturerData 配对，确保 filter 非空且只发现本服务设备。
 * manufacturerId 取一个非 0 的占位值（BLE company id 范围内任意，0 会被 SDK 当缺省）。
 */
export const NEARLINK_MANUFACTURER_ID: number = 0x0666;
export const NEARLINK_MANUFACTURER_PAYLOAD: Uint8Array = new Uint8Array([0x4C, 0x6F, 0x6F, 0x70]); // 'Loop'

/**
 * 收到字节流时的处理回调。由外部业务注册（如照片→存沙箱+通知 SaveButton）。
 * @param data 收到的原始字节流
 * @param fromAddress 发送端设备地址（MAC）
 * @returns 已消费返回 true；transport 据此决定是否回退到文本消息队列。
 *   （FileReassembler 对 file_* 控制帧/数据片返回 true，对纯文本返回 false）
 */
export type NearLinkDataHandler = (data: ArrayBuffer, fromAddress: string) => boolean;

/**
 * 收到纯文本消息时的回调（非 file_* 协议帧）。由 Index 注册，把对端消息注入 agent loop。
 * @param text 解码后的 UTF-8 文本
 * @param fromAddress 发送端设备地址（MAC）
 */
export type NearLinkTextMessageListener = (text: string, fromAddress: string) => void;

/**
 * 封装星闪数据传输（{@link dataTransfer} 模块）。替代 {@link AbilityConnectionClient.sendData}
 * 的照片字节通道：softbus sendData 在 5MB+ 照片时第 2 个 4MiB 片缓冲区溢出（errorCode 29425699），
 * 星闪 dataTransfer 由底层链路管理分片重组，应用层只需按 MTU 切片循环 writeData。
 *
 * API 签名取自官方文档《使用星闪传输数据》/ openharmony 侧声明（@ohos.nearlink.dataTransfer.d.ts，@since 26.0.0）：
 *   dataTransfer.createPort(uuid: string): void               双端注册端口
 *   dataTransfer.connect(params: ConnectionParams): Promise<void>  建链 {address, uuid, transferMode?}
 *   dataTransfer.disconnect(params: ConnectionParams): Promise<void>  断链 {address, uuid}
 *   dataTransfer.getConnectionState(params: ConnectionStateParams): ConnectionState  同步查链路状态
 *   dataTransfer.writeData(params: DataParams): Promise<void>   发字节 {address, uuid, data: ArrayBuffer}
 *   dataTransfer.onConnectionStateChanged(cb: Callback<ConnectionResult>): void   连接状态变更
 *   dataTransfer.onReadData(cb: Callback<DataParams>): void     接收字节
 *   dataTransfer.offConnectionStateChanged(cb?) / offReadData(cb?)  反订阅
 * 导入：@kit.ConnectivityKit，常量符号 nearlinkConstant（@ohos.nearlink.constant.d.ts 声明 namespace nearlinkConstant）。
 * ConnectionParams 入参无 mtu（mtu 是 ConnectionResult 的协商输出，从 onConnectionStateChanged 回调取）。
 * transferMode=RELIABLE 走可靠传输（有重传），适合照片分片。
 *
 * ⚠️ 前置：需把 8 个 nearlink 符号注册进 SDK 的 @kit.ConnectivityKit.json（build-tools/ets-loader/kit_configs），
 * 否则编译报 'has no exported member dataTransfer'。注册表改好版在 harmony/@kit.ConnectivityKit.json，
 * 用管理员权限覆盖到 SDK 目录即可。
 */
export class NearLinkTransport {
  private portCreated: boolean = false;
  private portCallbacksRegistered: boolean = false;
  private connected: boolean = false;
  private peerAddress: string = '';
  private negotiatedMtu: number = 1024;
  private handler: NearLinkDataHandler | null = null;
  private connectionStateCallback: ((data: dataTransfer.ConnectionResult) => void) | null = null;
  private readDataCallback: ((data: dataTransfer.DataParams) => void) | null = null;
  private receivedTextMessages: string[] = [];
  private textMessageListeners: NearLinkTextMessageListener[] = [];
  private utf8Decoder: util.TextDecoder = util.TextDecoder.create('utf-8');

  constructor() {
    this.ensurePortCreated();
  }

  /**
   * 发送响应给客户端（调试用）。被动方收到连接后直接 writeData 回发，无需 connect。
   * 复用已有连接的端口通道。
   */
  async sendResponse(clientAddress: string, response: string): Promise<boolean> {
    this.ensurePortCreated();
    try {
      const responseBuffer: ArrayBuffer = this.encodeText(response);
      const dataParams: dataTransfer.DataParams = {
        address: clientAddress,
        uuid: NEARLINK_PORT_UUID,
        data: responseBuffer
      } as dataTransfer.DataParams;
      hilog.info(LOG_DOMAIN, LOG_TAG, 'start sendResponse to %{public}s: %{public}s, UUID: %{public}s', dataParams.address, response, dataParams.uuid);
      await dataTransfer.writeData(dataParams);
      hilog.info(LOG_DOMAIN, LOG_TAG, 'sendResponse to %{public}s: %{public}s, UUID: %{public}s', dataParams.address, response, dataParams.uuid);
      return true;
    } catch (err) {
      const message = this.errorMessage(err);
      hilog.error(LOG_DOMAIN, LOG_TAG, 'sendResponse failed: %{public}s', message);
      return false;
    }
  }

  // 安全销毁端口
  private async safeDestroyPort(): Promise<void> {
    try {
      dataTransfer.destroyPort(NEARLINK_PORT_UUID);
      console.info('destroyPort success');
    } catch (err) {
      const error = err as BusinessError;
      if (error.code !== 1009700022) { // 忽略"端口未注册"错误
        console.warn(`destroyPort failed: errCode: ${error.code}, errMessage: ${error.message}`);
      }
    }
  }

  // 重新初始化端口（同步：destroyPort + createPort，无 await 延时）
  private reinitializePort(): boolean {
    try {
      // 1. 先销毁端口
      this.safeDestroyPort();

      // 2. 重新创建端口
      dataTransfer.createPort(NEARLINK_PORT_UUID);
      this.portCreated = true;
      hilog.info(LOG_DOMAIN, LOG_TAG, 'reinitializePort ok uuid=%{public}s', NEARLINK_PORT_UUID);
      return true;
    } catch (err) {
      const message = this.errorMessage(err);
      hilog.error(LOG_DOMAIN, LOG_TAG, 'reinitializePort failed: %{public}s', message);
      return false;
    }
  }

  /**
   * 注册端口通道并订阅事件。构造时自动调用，source/sink 双端对称。
   * createPort 在同一 UUID 重复调用框架报 existed port（errCode 1009700020），
   * 故仅在未注册时调；端口失效需 destroyPort 后重建（当前不处理，进程重启即恢复）。
   * 公开为 ensurePortCreated：sink 端热启动可能不走 onCreate（NearLinkTransport 未构造），
   * writeData/sendText/connect 前调此方法兜底，确保端口已注册。
   */
  ensurePortCreated(): void {
    // 端口已注册则直接返回——createPort 在同一 UUID 重复调用报 existed port（errCode 1009700020）。
    // portCreated 标志确保 createPort 只调一次（构造时或首次 writeData 兜底时）。
    if (this.portCreated) {
      return;
    }
    try {
      dataTransfer.createPort(NEARLINK_PORT_UUID);
      this.portCreated = true;
      hilog.info(LOG_DOMAIN, LOG_TAG, 'createPort ok uuid=%{public}s', NEARLINK_PORT_UUID);
    } catch (error) {
      // existed port（errCode 1009700020）说明端口已被本进程注册过（如构造时已建），
      // 视为成功——置 portCreated=true 避免后续重复尝试。
      const record = error as Record<string, Object>;
      const code = record.code;
      if (typeof code === 'number' && (code === 1009700020 || code === 36100020)) {
        this.portCreated = true;
        hilog.info(LOG_DOMAIN, LOG_TAG, 'createPort already registered uuid=%{public}s', NEARLINK_PORT_UUID);
        return;
      }
      const message = this.errorMessage(error);
      hilog.error(LOG_DOMAIN, LOG_TAG, 'createPort failed: %{public}s, UUID: %{public}s', message, NEARLINK_PORT_UUID);
      return;
    }
    // 回调订阅只注册一次（重复 on 会重复触发回调）。
    if (this.portCallbacksRegistered) {
      return;
    }
    this.connectionStateCallback = (data: dataTransfer.ConnectionResult): void => {
      const json = JSON.stringify(data);
      hilog.info(LOG_DOMAIN, LOG_TAG, 'connectionStateChanged: %{public}s', json);
      // ConnectionResult 结构：{address, uuid, mtu, state}。
      // state 用 nearlinkConstant.ConnectionState 枚举值：STATE_CONNECTING=0，STATE_CONNECTED=1，
      // STATE_DISCONNECTING=2，STATE_DISCONNECTED=3。mtu 是协商输出（connect 入参无 mtu）。
      // sink 端被动收到连接，必须在此提取 address 设给 peerAddress，
      // 否则 writeData 因 peerAddress 空而拒绝发送。
      // ConnectionResult 不能直接转 Record（ArkTS 类型限制），用 JSON.parse 绕过。
      const result = JSON.parse(json) as Record<string, Object>;
      const state = result.state;
      const addr = result.address;
      if (state === nearlinkConstant.ConnectionState.STATE_CONNECTED) {
        this.connected = true;
        if (typeof addr === 'string' && addr.length > 0) {
          this.peerAddress = addr;
        }
        const mtuVal = result.mtu;
        if (typeof mtuVal === 'number' && mtuVal > 0) {
          this.negotiatedMtu = mtuVal;
        }
        hilog.info(LOG_DOMAIN, LOG_TAG, 'connected peer=%{public}s mtu=%{public}d', this.peerAddress, this.negotiatedMtu);
        // 星闪连接是双向的：被动方收到连接后可直接 writeData 回发，无需再 connect。
        // （establishOutbound 已移除：connect 会 getPortByUuid failed 并破坏已有连接状态。）
      } else {
        this.connected = false;
        hilog.info(LOG_DOMAIN, LOG_TAG, 'disconnected state=%{public}d', state);
      }
    };
    this.readDataCallback = (data: dataTransfer.DataParams): void => {
      const payload = data.data;
      const fromAddress = data.address ?? '';
      if (payload === undefined || payload === null || payload.byteLength === 0) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'readData empty from=%{public}s', fromAddress);
        return;
      }
      this.peerAddress = fromAddress;
      hilog.info(LOG_DOMAIN, LOG_TAG, 'readData %{public}d bytes from=%{public}s', payload.byteLength, fromAddress);

      //this.sendResponse(fromAddress, 'Hello world');
      // 双路分发：先交 handler（FileReassembler），若它不消费（返回 false，如纯文本），
      // 则回退到文本消息队列 + onTextMessage 回调，由 Index 注入 agent loop。
      // 大数据帧（>=512B）必是照片分片数据，handler 会消费（appendChunk）。
      if (this.handler !== null) {
        const consumed = this.handler(payload, fromAddress);
        if (consumed) {
          return;
        }
      }
      // handler 未注册或未消费：当文本消息入队（中文/JSON/末片二进制兜底）。
      // decodeText 对照片二进制会得乱码但 length>0，push 进队列无害（agent 收到会忽略）。
      if (payload.byteLength < 512) {
        const text = this.decodeText(payload);
        if (text.length > 0) {
          this.pushTextMessage(text, fromAddress);
        }
      }
    };
    try {
      dataTransfer.onConnectionStateChanged(this.connectionStateCallback);
    } catch (error) {
      const message = this.errorMessage(error);
      hilog.error(LOG_DOMAIN, LOG_TAG, 'onConnectionStateChanged failed: %{public}s', message);
    }
    try {
      dataTransfer.onReadData(this.readDataCallback);
    } catch (error) {
      const message = this.errorMessage(error);
      hilog.error(LOG_DOMAIN, LOG_TAG, 'onReadData failed: %{public}s', message);
    }
    this.portCallbacksRegistered = true;
  }

  /**
   * 连接远端设备建立端口通道。transferMode=RELIABLE 走可靠传输（有重传），适合照片分片。
   * MTU 不作为入参——文档 ConnectionParams 只有 {address, uuid, transferMode?}，
   * mtu 是 ConnectionResult 的协商输出（onConnectionStateChanged 回调里取，存入 negotiatedMtu）。
   * @param peerAddress 扫描得到的远端 MAC 地址
   */
  async connect(peerAddress: string): Promise<void> {
    // 兜底：sink 热启动可能未走 onCreate（transport 未构造/未 createPort），
    // connect 前确保端口已注册，否则 connect 会 getPortByUuid failed。
    this.ensurePortCreated();
    this.peerAddress = peerAddress;
    const params: dataTransfer.ConnectionParams = {
      address: peerAddress,
      uuid: NEARLINK_PORT_UUID,
      transferMode: dataTransfer.TransferMode.BASIC
    } as dataTransfer.ConnectionParams;
    try {
      await dataTransfer.connect(params);
      // mtu 由 on('connectionStateChanged') 回调协商后回填；connect 返回前置兜底值。
      this.connected = true;
      hilog.info(LOG_DOMAIN, LOG_TAG, 'connect ok addr=%{public}s mtu=%{public}d', peerAddress, this.negotiatedMtu);
      return;
    } catch (error) {
      // BusinessError 是 {code,message} 结构不是 Error 实例，统一走 errorMessage 提取。
      const lastErrorMessage = this.errorMessage(error);
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'connect failed: %{public}s', lastErrorMessage);
      this.connected = false;
      throw new Error(`connect failed: ${lastErrorMessage}`);
    }
  }

  /**
   * 发送字节流（如照片分片）。被动方收到连接后也可直接 writeData 回发，无需 connect。
   * @param data 单片字节（应用层按 negotiatedMtu 切片，留余量）
   */
  async writeData(data: ArrayBuffer): Promise<void> {
    // 兜底：sink 热启动可能未走 onCreate（transport 未构造/未 createPort），
    // 发数据前确保端口已注册，否则 writeData 会 getPortByUuid failed。
    this.ensurePortCreated();
    if (!this.connected || this.peerAddress.length === 0) {
      throw new Error('未连接，请先 connect。');
    }
    // 官方同步接口校验真实链路状态：内部 connected 标志可能滞后于对端断链。
    const stateParams: dataTransfer.ConnectionStateParams = {
      address: this.peerAddress,
      uuid: NEARLINK_PORT_UUID
    } as dataTransfer.ConnectionStateParams;
    let realState: nearlinkConstant.ConnectionState;
    try {
      realState = dataTransfer.getConnectionState(stateParams);
    } catch (error) {
      const message = this.errorMessage(error);
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'getConnectionState failed: %{public}s', message);
      realState = nearlinkConstant.ConnectionState.STATE_CONNECTED; // 查询失败不阻断，交 writeData 自身处理
    }
    if (realState !== nearlinkConstant.ConnectionState.STATE_CONNECTED) {
      this.connected = false;
      throw new Error(`链路未就绪（state=${realState}），请重新 connect。`);
    }
    if (data.byteLength === 0) {
      return;
    }
    hilog.info(LOG_DOMAIN, LOG_TAG, 'writeData %{public}d bytes to=%{public}s', data.byteLength, this.peerAddress);
    const params: dataTransfer.DataParams = {
      address: this.peerAddress,
      uuid: NEARLINK_PORT_UUID,
      data: data
    } as dataTransfer.DataParams;
    // 拥塞重试：底层 SLE send queue 满时报 Write data congestion（errCode 36100023 / 本地 1009700101），
    // 不是致命错——短暂等待让队列排空再重试，避免直接抛错中止整张照片传输。
    const MAX_RETRIES = 10;
    let lastError: Object | null = null;
    for (let attempt = 0; attempt < MAX_RETRIES; attempt++) {
      try {
        await dataTransfer.writeData(params);
        return; // 成功
      } catch (error) {
        lastError = error;
        if (this.isCongestionError(error) && attempt < MAX_RETRIES - 1) {
          hilog.warn(LOG_DOMAIN, LOG_TAG, 'writeData congest, retry %{public}d/%{public}d after backoff',
            attempt + 1, MAX_RETRIES);
          await this.delay(1 + 10 * attempt + 1); // 50ms, 100ms, ... 退避
          continue;
        }
        const message = this.errorMessage(error);
        hilog.error(LOG_DOMAIN, LOG_TAG, 'writeData %{public}d bytes failed: %{public}s', data.byteLength, message);
        throw new Error(`writeData failed: ${message}`);
      }
    }
    const message = this.errorMessage(lastError as Object);
    throw new Error(`writeData failed after retries: ${message}`);
  }

  /**
   * 判定错误是否为 send queue 拥塞（可重试）。底层 napi 把 1009700101 转成通用
   * 36100099「Operation failed」，code 字段不可靠；JSON.stringify 对 BusinessError
   * 可能返回 "{}"（属性不可枚举）。故与 errorMessage 同路用 record.message/code 读，
   * 再兜底 `${error}` 拼接，任一命中拥塞特征即判可重试。
   */
  private isCongestionError(error: Object): boolean {
    const parts: string[] = [];
    const record = error as Record<string, Object>;
    const code = record.code;
    if (typeof code === 'number') {
      parts.push(`${code}`);
    }
    const message = record.message;
    if (typeof message === 'string') {
      parts.push(message);
    }
    parts.push(`${error}`); // 兜底 toString
    const lower = parts.join(' ').toLowerCase();
    return lower.includes('congest')
      || lower.includes('senddata failed')
      || lower.includes('queue is full')
      || lower.includes('1009700101')
      || lower.includes('36100023')
      || lower.includes('operation failed');
  }

  private delay(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void): void => {
      setTimeout((): void => resolve(), ms);
    });
  }

  /**
   * 发送整个文件。内部按 getChunkSize() 切片，每片前内嵌二进制头（magic/kind/seq/index/
   * totalChunks/dataLen），单片一次 writeData——不再分独立 sendText 控制帧。
   * 收端 FileReassembler 按 magic=0x55 解析头，提取数据写入，收齐触发 SaveButton。
   * @param fileData 整个文件字节
   * @param seq 文件序号（全局自增，收端据此命名 recv_<seq>.bin）
   */
  async writeFileData(fileData: ArrayBuffer, seq: number): Promise<number> {
    const totalSize = fileData.byteLength;
    if (totalSize === 0) {
      return 0;
    }
    const chunkSize = this.getChunkSize();
    const totalChunks = Math.ceil(totalSize / chunkSize);
    const view = new Uint8Array(fileData);
    let sent = 0;
    for (let index = 0; index < totalChunks; index++) {
      const offset = index * chunkSize;
      const end = offset + chunkSize > totalSize ? totalSize : offset + chunkSize;
      const dataLen = end - offset;
      // 首片是 begin（data 区前 4 字节放 total），末片是 end，中间是 data。
      // 单片文件（totalChunks==1）：kind=BEGIN，收端 beginFile 后立即 endFile（totalChunks==1 即收齐）。
      // 末片（非首）：kind=END。中间：kind=DATA。
      let kind = NEARLINK_FILE_KIND_DATA;
      if (index === 0) {
        kind = NEARLINK_FILE_KIND_BEGIN;
      } else if (index === totalChunks - 1) {
        kind = NEARLINK_FILE_KIND_END;
      }
      // begin 片数据区多 4 字节 total，payload = [total:4B][data]
      const extraBegin = kind === NEARLINK_FILE_KIND_BEGIN ? 4 : 0;
      const frameLen = NEARLINK_FILE_FRAME_HEAD_LEN + extraBegin + dataLen;
      const frame = new ArrayBuffer(frameLen);
      const head = new Uint8Array(frame);
      head[0] = NEARLINK_FILE_FRAME_MAGIC;
      head[1] = kind;
      this.writeU32(head, 2, seq);
      this.writeU32(head, 6, index);
      this.writeU32(head, 10, totalChunks);
      this.writeU32(head, 14, dataLen);
      let dataOff = NEARLINK_FILE_FRAME_HEAD_LEN;
      if (extraBegin > 0) {
        this.writeU32(head, dataOff, totalSize);
        dataOff += 4;
      }
      head.set(view.subarray(offset, end), dataOff);
      hilog.info(LOG_DOMAIN, LOG_TAG, 'writeFileData seq=%{public}d chunk=%{public}d/%{public}d kind=%{public}d frameLen=%{public}d',
        seq, index + 1, totalChunks, kind, frameLen);
      await this.writeData(frame);
      sent += dataLen;
    }
    return sent;
  }

  /** 大端写 4 字节无符号整数到 buf 的 offset 处。 */
  private writeU32(buf: Uint8Array, offset: number, value: number): void {
    buf[offset] = (value >>> 24) & 0xFF;
    buf[offset + 1] = (value >>> 16) & 0xFF;
    buf[offset + 2] = (value >>> 8) & 0xFF;
    buf[offset + 3] = value & 0xFF;
  }

  /** 从 buf 的 offset 处大端读 4 字节无符号整数。 */
  private readU32(buf: Uint8Array, offset: number): number {
    return ((buf[offset] & 0xFF) << 24)
      | ((buf[offset + 1] & 0xFF) << 16)
      | ((buf[offset + 2] & 0xFF) << 8)
      | (buf[offset + 3] & 0xFF);
  }

  /**
   * 暴露给收端 FileReassembler 的帧解析：判断 payload 是否以文件帧 magic 开头。
   */
  isFileFrame(payload: ArrayBuffer): boolean {
    if (payload.byteLength < NEARLINK_FILE_FRAME_HEAD_LEN) {
      return false;
    }
    const view = new Uint8Array(payload);
    return view[0] === NEARLINK_FILE_FRAME_MAGIC;
  }

  /**
   * 解析文件帧头。返回 { kind, seq, index, totalChunks, dataLen, dataOffset }。
   * dataOffset 指向帧内数据负载起始（begin 片含 4 字节 total，已跳过）。
   */
  parseFileFrame(payload: ArrayBuffer): FileFrameInfo | null {
    if (!this.isFileFrame(payload)) {
      return null;
    }
    const view = new Uint8Array(payload);
    const kind = view[1];
    const seq = this.readU32(view, 2);
    const index = this.readU32(view, 6);
    const totalChunks = this.readU32(view, 10);
    const dataLen = this.readU32(view, 14);
    let dataOffset = NEARLINK_FILE_FRAME_HEAD_LEN;
    let totalSize = -1;
    if (kind === NEARLINK_FILE_KIND_BEGIN && payload.byteLength >= NEARLINK_FILE_FRAME_HEAD_LEN + 4) {
      totalSize = this.readU32(view, NEARLINK_FILE_FRAME_HEAD_LEN);
      dataOffset = NEARLINK_FILE_FRAME_HEAD_LEN + 4;
    }
    const info: FileFrameInfo = {
      kind: kind,
      seq: seq,
      index: index,
      totalChunks: totalChunks,
      dataLen: dataLen,
      dataOffset: dataOffset,
      totalSize: totalSize
    };
    return info;
  }

  /**
   * 发送小文本消息。纯文本消息（对端收到注入其 agent loop），统一 UTF-8 编码。
   * 不再用于发文件控制帧——文件走 writeFileData 内嵌二进制头。
   */
  async sendText(message: string): Promise<void> {
    if (message.length === 0) {
      return;
    }
    const bytes = this.encodeText(message);
    await this.writeData(bytes);
  }

  /** 注册收到字节流时的处理回调（照片分片重组）。 */
  registerDataHandler(handler: NearLinkDataHandler): void {
    this.handler = handler;
  }

  /** 注册收到纯文本消息时的回调（Index 用来注入 agent loop）。 */
  onTextMessage(listener: NearLinkTextMessageListener): void {
    this.textMessageListeners.push(listener);
  }

  /** 清理所有文本消息回调（Index aboutToDisappear 时调）。 */
  offTextMessage(): void {
    this.textMessageListeners = [];
  }

  /** 读取并清空自上次以来收到的文本消息（兼容 nearlink_device received action）。 */
  drainReceivedText(): string[] {
    const copy = this.receivedTextMessages.slice();
    this.receivedTextMessages = [];
    return copy;
  }

  /** 文本消息入队并通知监听器（Index agent loop 桥接）。 */
  private pushTextMessage(text: string, fromAddress: string): void {
    this.receivedTextMessages.push(text);
    for (let index = 0; index < this.textMessageListeners.length; index++) {
      try {
        this.textMessageListeners[index](text, fromAddress);
      } catch (error) {
        const message = error instanceof Error ? error.message : `${error}`;
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'textMessageListener threw: %{public}s', message);
      }
    }
  }

  /** 协商成功的 MTU（connect 后可用）。照片切片大小以此为上限留余量。 */
  getMtu(): number {
    return this.negotiatedMtu;
  }

  /**
   * 单次 writeData 建议的最大字节数。不用 negotiatedMtu 算：真机日志显示底层 SLE send queue
   * 单次容量约 2.4KB（availableLength≈2492），而 mtu 协商值常为 0（回退兜底）。
   * 用保守固定 512 字节：单片 512 + 协议头远低于队列容量，避免 Write data congestion（errCode 36100023）。
   * 拥塞由 writeData 内部重试兜底，不靠切片大小精确卡队列。
   */
  getChunkSize(): number {
    return 30 * 1024;
  }

  isReady(): boolean {
    return this.connected && this.peerAddress.length > 0;
  }

  statusText(): string {
    return this.connected
      ? `connected (peer=${this.peerAddress}, mtu=${this.negotiatedMtu})`
      : 'disconnected';
  }

  /**
   * 断开并清理（不 destroyPort，保持实例可重连）。
   * 文档 dataTransfer.disconnect(params: ConnectionParams): Promise<void> 主动断链；
   * offConnectionStateChanged/offReadData 反订阅回调，避免重连时回调堆积。端口保留供复用。
   */
  async close(): Promise<void> {
    // 主动断链（文档第 417 行）：ConnectionParams={address, uuid}，无需 transferMode。
    if (this.connected && this.peerAddress.length > 0) {
      const params: dataTransfer.ConnectionParams = {
        address: this.peerAddress,
        uuid: NEARLINK_PORT_UUID
      } as dataTransfer.ConnectionParams;
      try {
        await dataTransfer.disconnect(params);
        hilog.info(LOG_DOMAIN, LOG_TAG, 'disconnect ok addr=%{public}s', this.peerAddress);
      } catch (error) {
        const message = this.errorMessage(error);
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'disconnect failed: %{public}s', message);
      }
    }
    // 反订阅回调（具名 off 方法，传具体 callback；不传则清全部）。
    if (this.portCallbacksRegistered) {
      if (this.connectionStateCallback !== null) {
        try {
          dataTransfer.offConnectionStateChanged(this.connectionStateCallback);
        } catch (error) {
          const message = this.errorMessage(error);
          hilog.warn(LOG_DOMAIN, LOG_TAG, 'offConnectionStateChanged failed: %{public}s', message);
        }
      }
      if (this.readDataCallback !== null) {
        try {
          dataTransfer.offReadData(this.readDataCallback);
        } catch (error) {
          const message = this.errorMessage(error);
          hilog.warn(LOG_DOMAIN, LOG_TAG, 'offReadData failed: %{public}s', message);
        }
      }
      this.portCallbacksRegistered = false;
    }
    this.connected = false;
    this.peerAddress = '';
    this.receivedTextMessages = [];
    this.textMessageListeners = [];
  }

  private decodeText(buffer: ArrayBuffer): string {
    try {
      return this.utf8Decoder.decodeToString(new Uint8Array(buffer));
    } catch (_error) {
      // 非 UTF-8 或解码失败，回退逐字节（保 ASCII/控制帧可读）
      const view = new Uint8Array(buffer);
      let result = '';
      for (let index = 0; index < view.length; index++) {
        result += String.fromCharCode(view[index]);
      }
      return result;
    }
  }

  private encodeText(text: string): ArrayBuffer {
    // 手工 UTF-8 编码（util.TextEncoder 在 ArkTS 的 API 形态不确定，故手写以保中文正确）。
    const bytes: number[] = [];
    for (let index = 0; index < text.length; index++) {
      let code = text.charCodeAt(index);
      if (code < 0x80) {
        bytes.push(code);
      } else if (code < 0x800) {
        bytes.push(0xC0 | (code >> 6));
        bytes.push(0x80 | (code & 0x3F));
      } else if (code < 0xD800 || code >= 0xE000) {
        bytes.push(0xE0 | (code >> 12));
        bytes.push(0x80 | ((code >> 6) & 0x3F));
        bytes.push(0x80 | (code & 0x3F));
      } else {
        // 代理对（emoji 等 4 字节 UTF-8）
        index++;
        code = 0x10000 + (((code & 0x3FF) << 10) | (text.charCodeAt(index) & 0x3FF));
        bytes.push(0xF0 | (code >> 18));
        bytes.push(0x80 | ((code >> 12) & 0x3F));
        bytes.push(0x80 | ((code >> 6) & 0x3F));
        bytes.push(0x80 | (code & 0x3F));
      }
    }
    const result = new Uint8Array(bytes.length);
    for (let i = 0; i < bytes.length; i++) {
      result[i] = bytes[i];
    }
    return result.buffer;
  }

  private errorMessage(error: Object): string {
    if (error instanceof Error) {
      return error.message;
    }
    const record = error as Record<string, Object>;
    const code = record.code;
    const message = record.message;
    const parts: string[] = [];
    if (code !== undefined && code !== null) {
      parts.push(`code=${code}`);
    }
    if (message !== undefined && message !== null) {
      parts.push(`${message}`);
    }
    return parts.length > 0 ? parts.join(' ') : JSON.stringify(error);
  }
}
