import scan from '@ohos.nearlink.scan';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { NEARLINK_MANUFACTURER_ID } from './NearLinkTransport';

const LOG_DOMAIN: number = 0x1302;
const LOG_TAG: string = 'LoopNearLinkScan';
const DISCOVER_TIMEOUT_MS: number = 8000;

/**
 * 星闪扫描到的远端设备。address 是 MAC 地址，作为后续 dataTransfer.connect 的目标。
 */
export interface NearLinkDevice {
  address: string;
  deviceName: string;
}

/**
 * 扫描过滤条件。至少携带一个字段，否则扫描过滤器无效（文档约束）。
 */
export interface ScanFilter {
  deviceName?: string;
  address?: string;
}

/**
 * 封装星闪扫描（{@link scan} 模块）。对称于 distributed 的 {@link DeviceManagerClient}，
 * 但星闪基于广播/扫描模型（类 BLE），不依赖设备绑定流程：
 *   - startScan(filters, options) 启动扫描
 *   - onDeviceFound 回调上报扫描结果
 *   - stopScan() / offDeviceFound 停止
 *
 * API 签名取自官方文档《发起星闪扫描》/ openharmony 侧声明（@ohos.nearlink.scan.d.ts，@since 26.0.0）：
 *   scan.startScan(filters: Array<ScanFilters>, options?: ScanOptions): Promise<void>
 *   scan.stopScan(): Promise<void>
 *   scan.onDeviceFound(callback: Callback<Array<ScanResults>>): void
 *   scan.offDeviceFound(callback?): void
 * ScanResults 字段：address、deviceName、data(ArrayBuffer 广播数据)。
 */
export class NearLinkScanner {
  private scanning: boolean = false;
  private foundBuffer: NearLinkDevice[] = [];
  private seenAddresses: Set<string> = new Set<string>();
  private discoverResolve: ((devices: NearLinkDevice[]) => void) | null = null;
  private discoverTimer: number = -1;
  private deviceFoundCallback: ((data: Array<scan.ScanResults>) => void) | null = null;

  /**
   * 启动一次限时扫描（默认 5s 窗口），返回期间发现的去重设备列表。
   * 可选 filters 按 deviceName/address 过滤；不传则扫所有星闪广播设备。
   */
  async start(filters?: ScanFilter): Promise<NearLinkDevice[]> {
    if (this.scanning) {
      // 已在扫描，复用当前 promise
      await this.stop();
    }
    this.foundBuffer = [];
    this.seenAddresses = new Set<string>();
    this.scanning = true;

    const scanFilters: Array<scan.ScanFilters> = [];
    // 真机约束：filter 必须至少一个非空字段，空 deviceName('') 被拒（ParseScanFilterLocalNameParameters: name is empty）。
    // 官方 sample 用 deviceName 过滤（需已知对端名），但我们不知对端名。
    // 改用 manufacturerId 作为非空过滤锚点：广播端 AdvertisingData.manufacturerData 带 manufacturerId=NEARLINK_MANUFACTURER_ID，
    // 扫描端 filter 按 manufacturerId 匹配（ScanFilters.manufacturerId 是 number 平铺字段，SDK ParseScanFilterManufactureDataParameters 解析它）。
    // 不带 manufacturerData(ArrayBuffer) 避免类型不匹配；仅 manufacturerId 即可让 filter 非空且匹配本服务广播设备。
    const filter: scan.ScanFilters = {
      manufacturerId: NEARLINK_MANUFACTURER_ID
    } as scan.ScanFilters;
    if (filters !== undefined && filters !== null) {
      if (filters.deviceName !== undefined && filters.deviceName.length > 0) {
        filter.deviceName = filters.deviceName;
      }
      if (filters.address !== undefined && filters.address.length > 0) {
        filter.address = filters.address;
      }
    }
    scanFilters.push(filter);
    // scanMode 用枚举成员（数字裸值 ArkTS 严格类型不接受）。
    const scanOptions: scan.ScanOptions = {
      scanMode: scan.ScanMode.SCAN_MODE_LOW_POWER
    } as scan.ScanOptions;

    return await new Promise<NearLinkDevice[]>((resolve: (devices: NearLinkDevice[]) => void): void => {
      this.discoverResolve = resolve;
      this.deviceFoundCallback = (results: Array<scan.ScanResults>): void => {
        this.handleScanResults(results);
      };
      try {
        scan.onDeviceFound(this.deviceFoundCallback);
      } catch (error) {
        const message = this.errorMessage(error);
        hilog.error(LOG_DOMAIN, LOG_TAG, 'onDeviceFound failed: %{public}s', message);
        this.scanning = false;
        resolve([]);
        return;
      }
      hilog.info(LOG_DOMAIN, LOG_TAG, 'startScan filter manufacturerId=%{public}d deviceName=%{public}s address=%{public}s',
        NEARLINK_MANUFACTURER_ID,
        (filter.deviceName ?? ''),
        (filter.address ?? ''));
      try {
        scan.startScan(scanFilters, scanOptions).then((): void => {
          hilog.info(LOG_DOMAIN, LOG_TAG, 'startScan ok');
        }).catch((err: BusinessError): void => {
          hilog.error(LOG_DOMAIN, LOG_TAG, 'startScan failed code=%{public}d msg=%{public}s', err.code, err.message);
          this.cleanupAfterScan();
          resolve([]);
        });
      } catch (error) {
        const message = this.errorMessage(error);
        hilog.error(LOG_DOMAIN, LOG_TAG, 'startScan throw: %{public}s', message);
        this.cleanupAfterScan();
        resolve([]);
      }
      // 限时窗口：到点 stopScan 并 resolve 当前累积结果。
      this.discoverTimer = setTimeout((): void => {
        this.stop().then((): void => {
          resolve(this.foundBuffer);
        });
      }, DISCOVER_TIMEOUT_MS);
    });
  }

  /** 停止扫描并清理回调。 */
  async stop(): Promise<void> {
    if (!this.scanning) {
      return;
    }
    this.scanning = false;
    if (this.discoverTimer >= 0) {
      clearTimeout(this.discoverTimer);
      this.discoverTimer = -1;
    }
    try {
      await scan.stopScan();
      hilog.info(LOG_DOMAIN, LOG_TAG, 'stopScan ok');
    } catch (error) {
      const message = this.errorMessage(error);
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'stopScan failed: %{public}s', message);
    }
    this.cleanupAfterScan();
    const resolve = this.discoverResolve;
    this.discoverResolve = null;
    if (resolve !== null) {
      resolve(this.foundBuffer);
    }
  }

  isScanning(): boolean {
    return this.scanning;
  }

  private handleScanResults(results: Array<scan.ScanResults>): void {
    for (let index = 0; index < results.length; index++) {
      const result = results[index];
      const address = result.address ?? '';
      const deviceName = result.deviceName ?? '';
      if (address.length === 0) {
        continue;
      }
      if (this.seenAddresses.has(address)) {
        continue;
      }
      this.seenAddresses.add(address);
      this.foundBuffer.push({ address, deviceName });
      hilog.info(LOG_DOMAIN, LOG_TAG, 'deviceFound addr=%{public}s name=%{public}s', address, deviceName);
    }
  }

  private cleanupAfterScan(): void {
    if (this.deviceFoundCallback !== null) {
      try {
        scan.offDeviceFound(this.deviceFoundCallback);
      } catch (error) {
        const message = this.errorMessage(error);
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'offDeviceFound failed: %{public}s', message);
      }
      this.deviceFoundCallback = null;
    }
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
