import advertising from '@ohos.nearlink.advertising';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { NEARLINK_MANUFACTURER_ID, NEARLINK_MANUFACTURER_PAYLOAD } from './NearLinkTransport';

const LOG_DOMAIN: number = 0x1303;
const LOG_TAG: string = 'LoopNearLinkAdv';

/**
 * 封装星闪广播（{@link advertising} 模块）。让本设备可被星闪扫描发现，
 * sink 端启动广播，source 端扫描到后发起 dataTransfer.connect。
 *
 * API 签名取自官方文档《发送星闪广播》/ openharmony 侧声明（@ohos.nearlink.advertising.d.ts，@since 26.0.0）：
 *   advertising.startAdvertising(params: AdvertisingParams): Promise<number>  返回 advertisingId
 *   advertising.stopAdvertising(advertisingId: number): Promise<void>
 *   advertising.onAdvertisingStateChange(cb: Callback<AdvertisingStateChangeInfo>): void
 *   advertising.offAdvertisingStateChange(callback?): void
 *
 * 广播 payload 携带 serviceUuid，与 dataTransfer.createPort 的 UUID 一致，
 * 扫描端据此过滤目标设备（当前扫描端仅按 address/deviceName 过滤，serviceUuid 过滤后续加）。
 */
export class NearLinkAdvertiser {
  private advertisingId: number = -1;
  private advertising: boolean = false;
  private stateCallback: ((data: advertising.AdvertisingStateChangeInfo) => void) | null = null;

  constructor() {
  }

  /**
   * 启动广播。payload 携带 manufacturerData(NEARLINK_MANUFACTURER_ID + 'Loop' 字节)，
   * 扫描端按同一 manufacturerData 过滤，确保 filter 非空且只发现本服务设备
   *（scan.ScanFilters 不认 serviceUuid，改用 manufacturerData 双端对称）。
   */
  async start(serviceUuid: string): Promise<void> {
    if (this.advertising) {
      await this.stop();
    }
    this.stateCallback = (data: advertising.AdvertisingStateChangeInfo): void => {
      hilog.info(LOG_DOMAIN, LOG_TAG, 'advertisingState advId=%{public}d state=%{public}d',
        data.advertisingId, data.state);
    };
    try {
      advertising.onAdvertisingStateChange(this.stateCallback);
    } catch (error) {
      const message = this.errorMessage(error);
      hilog.error(LOG_DOMAIN, LOG_TAG, 'onAdvertisingStateChange failed: %{public}s', message);
    }

    // settings.power 用 TxPowerMode 枚举成员（文档 AdvertisingSettings.power: TxPowerMode）。
    // 取 MEDIUM（值 2）以保留原真机验证过的发射功率档位，提升可发现性。
    const settings: advertising.AdvertisingSettings = {
      interval: 160,
      power: advertising.TxPowerMode.ADV_TX_POWER_MEDIUM
    } as advertising.AdvertisingSettings;
    const serviceValueBuffer = new Uint8Array(0);
    const serviceDataUnit: advertising.ServiceData = {
      serviceUuid: serviceUuid,
      serviceData: serviceValueBuffer.buffer
    } as advertising.ServiceData;
    // manufacturerData：广播 payload 携带，供扫描端/对端识别本服务设备。
    const manufacturerDataUnit: advertising.ManufacturerData = {
      manufacturerId: NEARLINK_MANUFACTURER_ID,
      manufacturerData: NEARLINK_MANUFACTURER_PAYLOAD.buffer
    } as advertising.ManufacturerData;
    const advData: advertising.AdvertisingData = {
      serviceUuids: [serviceUuid],
      serviceData: [serviceDataUnit],
      manufacturerData: [manufacturerDataUnit],
      includeDeviceName: true
    } as advertising.AdvertisingData;
    const params: advertising.AdvertisingParams = {
      advertisingSettings: settings,
      advertisingData: advData
    } as advertising.AdvertisingParams;

    this.advertising = true;
    try {
      const id = await advertising.startAdvertising(params);
      this.advertisingId = id;
      hilog.info(LOG_DOMAIN, LOG_TAG, 'startAdvertising ok advId=%{public}d', id);
    } catch (error) {
      this.advertising = false;
      const message = this.errorMessage(error);
      hilog.error(LOG_DOMAIN, LOG_TAG, 'startAdvertising failed: %{public}s', message);
      throw new Error(`startAdvertising failed: ${message}`);
    }
  }

  /** 停止广播并清理回调。 */
  async stop(): Promise<void> {
    if (!this.advertising) {
      return;
    }
    this.advertising = false;
    if (this.advertisingId >= 0) {
      try {
        await advertising.stopAdvertising(this.advertisingId);
        hilog.info(LOG_DOMAIN, LOG_TAG, 'stopAdvertising ok advId=%{public}d', this.advertisingId);
      } catch (error) {
        const message = this.errorMessage(error);
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'stopAdvertising failed: %{public}s', message);
      }
      this.advertisingId = -1;
    }
    if (this.stateCallback !== null) {
      try {
        advertising.offAdvertisingStateChange(this.stateCallback);
      } catch (error) {
        const message = this.errorMessage(error);
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'offAdvertisingStateChange failed: %{public}s', message);
      }
      this.stateCallback = null;
    }
  }

  isAdvertising(): boolean {
    return this.advertising;
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
