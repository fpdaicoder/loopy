import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { abilityAccessCtrl, Permissions } from '@kit.AbilityKit';
import { NearLinkTransport, NearLinkAdvertiser, FileReassembler, NEARLINK_PORT_UUID } from '@loop/agent-core';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';

const DOMAIN = 0x0000;
const LOG_TAG = 'Loop';

// ACCESS_NEARLINK 是 user_grant 权限，安装时不会自动授予，必须运行时弹窗请求。
// 注意：READ_IMAGEVIDEO 是受限权限，普通调试签名声明会导致安装失败（code:9568289），
// 故未声明；photo_album 的 pick 路径（系统选择器）不依赖该权限，照常可用。
// softbus（abilityConnectionManager）已屏蔽，不再声明 DISTRIBUTED_DATASYNC。
const REQUIRED_PERMISSIONS: Permissions[] = [
  'ohos.permission.ACCESS_NEARLINK'
];

export default class EntryAbility extends UIAbility {

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    hilog.info(DOMAIN, LOG_TAG, 'EntryAbility onCreate');
    this.requestRequiredPermissions();
    this.setupNearLinkReceiver();
  }

  /**
   * 星闪接收端接线：构造 NearLinkTransport（或复用 ToolRegistry 已建的实例），
   * 注册 FileReassembler 处理 readData（控制帧+数据片重组沙箱文件），启动广播让本设备可被扫描。
   * source 端扫描到本设备后发起 dataTransfer.connect，readData 即开始收照片字节。
   * softbus 已屏蔽，sink 端不再经 onCollaborate 建协同会话，全程走星闪端口通道。
   */
  private setupNearLinkReceiver(): void {
    // ToolRegistry（Index aboutToAppear 异步建）可能尚未建 transport；优先复用已建实例，避免重复 createPort。
    let transport = AppStorage.get<NearLinkTransport>('loopNearLinkTransport');
    if (transport === undefined || transport === null) {
      transport = new NearLinkTransport();
      AppStorage.setOrCreate<NearLinkTransport>('loopNearLinkTransport', transport);
    }
    const reassembler = new FileReassembler(this.context, 'sink');
    // handler 返回 reassembler 是否消费：true 表示协议帧/数据片已处理，
    // false 表示非协议负载（纯文本），transport 据此回退到文本消息队列→agent loop。
    transport.registerDataHandler((data: ArrayBuffer, _fromAddress: string): boolean => {
      return reassembler.handleData(data);
    });
    // 启动广播：让 source 端扫描到本设备。广播与端口共用同一 serviceUuid。
    this.startNearLinkAdvertising();
  }

  private nearLinkAdvertiser: NearLinkAdvertiser | null = null;

  private startNearLinkAdvertising(): void {
    if (this.nearLinkAdvertiser !== null) {
      return;
    }
    this.nearLinkAdvertiser = new NearLinkAdvertiser();
    this.nearLinkAdvertiser.start(NEARLINK_PORT_UUID).then((): void => {
      hilog.info(DOMAIN, LOG_TAG, 'NearLink advertising started uuid=%{public}s', NEARLINK_PORT_UUID);
    }).catch((error: Object): void => {
      const message = error instanceof Error ? error.message : `${error}`;
      hilog.warn(DOMAIN, LOG_TAG, 'NearLink advertising failed: %{public}s', message);
    });
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
    if (this.nearLinkAdvertiser !== null) {
      this.nearLinkAdvertiser.stop().catch((error: Object): void => {
        const message = error instanceof Error ? error.message : `${error}`;
        hilog.warn(DOMAIN, LOG_TAG, 'NearLink advertiser stop failed: %{public}s', message);
      });
    }
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

  // 注：softbus（abilityConnectionManager）协同链路已屏蔽，不再实现 onCollaborate。
  // 跨设备全程走星闪：source scan → connect → writeData；sink advertising + readData。
  // 系统图片查看器走 viewData 打不开应用沙箱文件（跨沙箱墙），已弃用；
  // 改为 Index 页面 SaveButton 控件授权存进媒体库。
}
