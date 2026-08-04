import { common } from '@kit.AbilityKit';
import { distributedDeviceManager } from '@kit.DistributedServiceKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const LOG_DOMAIN: number = 0x1300;
const LOG_TAG: string = 'LoopDeviceManager';
const DISCOVER_TIMEOUT_MS: number = 3000;

export interface DiscoveredDevice {
  deviceId: string;
  deviceName: string;
  deviceType: string;
  networkId: string;
}

interface BindResult {
  deviceId: string;
}

interface DeviceStateChangeInfo {
  action: distributedDeviceManager.DeviceStateChange;
  device: distributedDeviceManager.DeviceBasicInfo;
}

interface DiscoverSuccessInfo {
  device: distributedDeviceManager.DeviceBasicInfo;
}

interface DiscoverFailureInfo {
  reason: number;
}

/**
 * 封装分布式设备管理（发现 + 绑定）。仅负责发现周边设备与发起绑定；
 * 绑定后拿到的 networkId 交给 {@link AbilityConnectionClient} 建会话通信。
 *
 * API 签名取自 SDK @ohos.distributedDeviceManager.d.ts：
 * - createDeviceManager(bundleName): DeviceManager
 * - getAvailableDeviceListSync(): Array<DeviceBasicInfo>   已绑定（可信）设备，同步
 * - getLocalDeviceId(): string                              本机设备 ID
 * - startDiscovering(discoverParam, filterOptions?)        发现未绑定设备
 * - stopDiscovering()
 * - bindTarget(deviceId, bindParam, callback)               发起绑定（PIN 码对端确认）
 * - on('deviceStateChange' | 'discoverSuccess' | 'discoverFailure', cb)
 */
export class DeviceManagerClient {
  private context: common.UIAbilityContext;
  private dm: distributedDeviceManager.DeviceManager | null = null;
  private initialized: boolean = false;
  private initError: string = '';

  private discoverResolve: ((devices: DiscoveredDevice[]) => void) | null = null;
  private discoverTimer: number = -1;
  private discoveredBuffer: DiscoveredDevice[] = [];
  private stateListener: ((action: distributedDeviceManager.DeviceStateChange, device: DiscoveredDevice) => void) | null = null;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  async initialize(): Promise<void> {
    if (this.initialized) {
      return;
    }
    this.initialized = true;
    try {
      // createDeviceManager 同步返回实例，参数为本应用 bundleName。
      this.dm = distributedDeviceManager.createDeviceManager(this.context.applicationInfo.name);
      this.registerDiscoverCallbacks();
      hilog.info(LOG_DOMAIN, LOG_TAG, 'deviceManager created');
    } catch (error) {
      this.initError = this.errorMessage(error);
      this.initialized = false;
      hilog.error(LOG_DOMAIN, LOG_TAG, 'createDeviceManager failed: %{public}s', this.initError);
    }
  }

  isAvailable(): boolean {
    return this.dm !== null && this.initError.length === 0;
  }

  initErrorText(): string {
    return this.initError;
  }

  /** 已绑定（可信）设备列表，同步返回。每项含 networkId，供连接会话使用。 */
  listTrusted(): DiscoveredDevice[] {
    if (!this.isAvailable()) {
      return [];
    }
    try {
      const list = this.dm!.getAvailableDeviceListSync();
      const result: DiscoveredDevice[] = [];
      const localId = this.safeLocalDeviceId();
      hilog.info(LOG_DOMAIN, LOG_TAG, 'listTrusted: count=%{public}d localDeviceId=%{public}s', list.length, localId);
      for (let index = 0; index < list.length; index++) {
        const device = this.toDiscovered(list[index]);
        result.push(device);
        hilog.info(LOG_DOMAIN, LOG_TAG,
          'listTrusted[%{public}d]: deviceName=%{public}s deviceId=%{public}s networkId=%{public}s deviceType=%{public}s',
          index, device.deviceName, device.deviceId, device.networkId, device.deviceType);
      }
      return result;
    } catch (error) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'getAvailableDeviceListSync failed: %{public}s', this.errorMessage(error));
      return [];
    }
  }

  /** 本机设备 ID。 */
  localDeviceId(): string {
    if (!this.isAvailable()) {
      return '';
    }
    try {
      return this.dm!.getLocalDeviceId();
    } catch (error) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'getLocalDeviceId failed: %{public}s', this.errorMessage(error));
      return '';
    }
  }

  private safeLocalDeviceId(): string {
    try {
      return this.dm !== null ? this.dm.getLocalDeviceId() : '';
    } catch (_error) {
      return '';
    }
  }

  /**
   * 发现未绑定设备。startDiscovering 的 discoverParam 在当前 SDK 为 Record<string, Object>，
   * discoverTargetType 默认为 1（设备）。filterOptions 省略使用默认过滤。
   * @returns 发现到的设备，超时返回已收到的部分。
   */
  discover(): Promise<DiscoveredDevice[]> {
    if (!this.isAvailable()) {
      return Promise.resolve([]);
    }
    return new Promise<DiscoveredDevice[]>((resolve: (devices: DiscoveredDevice[]) => void): void => {
      this.discoveredBuffer = [];
      this.discoverResolve = resolve;
      try {
        const discoverParam: Record<string, Object> = { 'discoverTargetType': 1 };
        this.dm!.startDiscovering(discoverParam);
      } catch (error) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'startDiscovering failed: %{public}s', this.errorMessage(error));
        this.discoverResolve = null;
        resolve([]);
        return;
      }
      // 超时兜底：到点停止发现并返回已收到的设备。
      this.discoverTimer = setTimeout((): void => {
        this.finishDiscovery();
      }, DISCOVER_TIMEOUT_MS);
    });
  }

  /** 发起绑定（PIN 码对端确认流程），异步回调。 */
  async bind(deviceId: string): Promise<string> {
    if (!this.isAvailable()) {
      return 'DeviceManager 未初始化。';
    }
    return new Promise<string>((resolve: (text: string) => void): void => {
      const bindParam: Record<string, Object> = {
        'bindType': 1, // PIN 码方式
        'targetPkgName': this.context.applicationInfo.name,
        'appName': 'Loop'
      };
      try {
        this.dm!.bindTarget(deviceId, bindParam, (err: BusinessError, data: BindResult): void => {
          if (err) {
            hilog.error(LOG_DOMAIN, LOG_TAG, 'bindTarget failed: %{public}s', JSON.stringify(err));
            resolve(`绑定失败：${err.message ?? JSON.stringify(err)}`);
            return;
          }
          resolve(`绑定已发起，请在对端设备确认：${JSON.stringify(data)}`);
        });
      } catch (error) {
        resolve(`绑定异常：${this.errorMessage(error)}`);
      }
    });
  }

  /** 注册绑定状态变化监听。action 为 DeviceStateChange 枚举（UNKNOWN/AVAILABLE/UNAVAILABLE）。 */
  onStateChange(listener: (action: distributedDeviceManager.DeviceStateChange, device: DiscoveredDevice) => void): void {
    this.stateListener = listener;
    if (!this.isAvailable()) {
      return;
    }
    try {
      this.dm!.on('deviceStateChange', (data: DeviceStateChangeInfo): void => {
        const mapped = this.toDiscovered(data.device);
        hilog.info(LOG_DOMAIN, LOG_TAG, 'deviceStateChange action=%{public}d', data.action);
        if (this.stateListener !== null) {
          this.stateListener(data.action, mapped);
        }
      });
    } catch (error) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'on deviceStateChange failed: %{public}s', this.errorMessage(error));
    }
  }

  async close(): Promise<void> {
    if (!this.isAvailable()) {
      return;
    }
    const discovering = this.discoverTimer >= 0;
    if (discovering) {
      clearTimeout(this.discoverTimer);
      this.discoverTimer = -1;
      try {
        this.dm!.stopDiscovering();
      } catch (error) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'stopDiscovering failed: %{public}s', this.errorMessage(error));
      }
    }
    this.discoverResolve = null;
    this.discoveredBuffer = [];
    hilog.info(LOG_DOMAIN, LOG_TAG, 'closed');
  }

  private registerDiscoverCallbacks(): void {
    if (this.dm === null) {
      return;
    }
    this.dm.on('discoverSuccess', (data: DiscoverSuccessInfo): void => {
      const mapped = this.toDiscovered(data.device);
      // 去重
      const exists = this.discoveredBuffer.some((item: DiscoveredDevice): boolean => item.deviceId === mapped.deviceId);
      if (!exists) {
        this.discoveredBuffer.push(mapped);
      }
      hilog.info(LOG_DOMAIN, LOG_TAG,
        'discoverSuccess deviceName=%{public}s deviceId=%{public}s networkId=%{public}s deviceType=%{public}s localDeviceId=%{public}s',
        mapped.deviceName, mapped.deviceId, mapped.networkId, mapped.deviceType, this.safeLocalDeviceId());
    });
    this.dm.on('discoverFailure', (data: DiscoverFailureInfo): void => {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'discoverFailure: %{public}d', data.reason);
      this.finishDiscovery();
    });
  }

  private finishDiscovery(): void {
    this.cleanupDiscoverTimer();
    try {
      this.dm?.stopDiscovering();
    } catch (_error) {
      // 忽略
    }
    if (this.discoverResolve !== null) {
      this.discoverResolve(this.discoveredBuffer.slice());
      this.discoverResolve = null;
    }
  }

  private cleanupDiscoverTimer(): void {
    if (this.discoverTimer >= 0) {
      clearTimeout(this.discoverTimer);
      this.discoverTimer = -1;
    }
  }

  private toDiscovered(info: distributedDeviceManager.DeviceBasicInfo): DiscoveredDevice {
    return {
      deviceId: info.deviceId,
      deviceName: info.deviceName,
      deviceType: info.deviceType,
      networkId: info.networkId ?? ''
    };
  }

  private errorMessage(error: Object): string {
    return error instanceof Error ? error.message : `${error}`;
  }
}
