import { AgentTool } from '../agent/AgentTool';
import { NearLinkScanner, NearLinkDevice } from './NearLinkScanner';
import { NearLinkTransport } from './NearLinkTransport';
import { buildNearLinkDeviceCardJsonl } from '../a2ui/DeviceListCard';
import { hilog } from '@kit.PerformanceAnalysisKit';

const LOG_DOMAIN: number = 0x1305;
const LOG_TAG: string = 'LoopNearLinkTool';

interface NearLinkDeviceToolInput {
  operation?: string;   // 'search' | 'execute'
  useCase?: string;     // search 阶段任务描述
  action?: string;     // execute 阶段：connect | send | received
  address?: string;    // connect 目标 MAC
  message?: string;    // send 文本消息（主要字段名）
  data?: string;       // send 文本消息（兼容模型可能用的字段名）
  text?: string;       // send 文本消息（兼容模型可能用的字段名）
}

/**
 * 对外暴露的星闪设备工具。softbus 已屏蔽，星闪为唯一跨设备发现/建链/传输通道。
 *   operation=search   —— 扫描周边星闪广播设备，返回 address+deviceName 列表
 *   operation=execute  —— 执行具体动作（connect/send/received）
 *
 * 照片字节与文本均走星闪 dataTransfer（writeData/sendText + readData）。
 *
 * API 依据官方文档《发起星闪扫描》《使用星闪传输数据》。
 */
export class NearLinkDeviceTool implements AgentTool {
  private scanner: NearLinkScanner;
  private transport: NearLinkTransport;
  private pendingUiPayload: string = '';

  /** 最近一次扫描返回的设备列表，供 ui 工具渲染。 */
  lastDevices: NearLinkDevice[] = [];

  constructor(scanner: NearLinkScanner, transport: NearLinkTransport) {
    this.scanner = scanner;
    this.transport = transport;
  }

  /** 取出并清空待渲染的星闪设备列表卡片 payload，供 ToolRegistry 注册的 UI 回调调用。 */
  consumeUiPayload(): string {
    const payload = this.pendingUiPayload;
    this.pendingUiPayload = '';
    return payload;
  }

  /** UI 点设备行后直接发起星闪连接（绕过 agent runAgent），供 Index 在 onDeviceSelect 调用。 */
  async connectDevice(address: string): Promise<string> {
    return await this.connect(address);
  }

  name(): string {
    return 'nearlink_device';
  }

  description(): string {
    const connStatus = this.transport.statusText();
    return '星闪（NearLink）设备发现与数据传输，唯一跨设备通道（softbus 已屏蔽），用于照片/文本跨设备传输。' +
      '两阶段：先用 {"operation":"search"} 扫描周边星闪广播设备；' +
      '再用 {"operation":"execute","action":"connect|send|received",...} 执行。' +
      ` 连接状态: ${connStatus}. ` +
      'connect 需在对端已启动星闪广播（NearLinkAdvertiser）后方可建立端口通道。' +
      ' send 用 "message" 字段传文本（也兼容 data/text）。' +
      ' 照片传输建议走 photo_album pick（自动用星闪 dataTransfer 分片发送）。' +
      ' 对端收到 send 的文本会注入其 agent loop，由其 agent 触发工具调用（如 photo_album pick）在现有连接上回发照片——' +
      ' 故发文本可远程驱动对端动作。';
  }

  async run(input: string): Promise<string> {
    let parsed: NearLinkDeviceToolInput;
    try {
      parsed = JSON.parse(input) as NearLinkDeviceToolInput;
    } catch (_error) {
      return 'nearlink_device 参数错误：输入必须是 JSON。';
    }

    if (parsed.operation === 'search') {
      return await this.search();
    }
    if (parsed.operation === 'execute') {
      return await this.execute(parsed);
    }
    return 'nearlink_device 参数错误：operation 必须是 search 或 execute。';
  }

  private async search(): Promise<string> {
    try {
      const devices = await this.scanner.start();
      this.lastDevices = devices;
      this.pendingUiPayload = buildNearLinkDeviceCardJsonl(devices);
      if (devices.length === 0) {
        return '未发现星闪设备。请确认对端已启动广播，可稍后重试。';
      }
      return `星闪设备列表：\n${this.formatDevices(devices)}`;
    } catch (error) {
      const message = error instanceof Error ? error.message : `${error}`;
      hilog.error(LOG_DOMAIN, LOG_TAG, 'search failed: %{public}s', message);
      return `扫描失败：${message}`;
    }
  }

  private async execute(parsed: NearLinkDeviceToolInput): Promise<string> {
    const action = parsed.action ?? '';
    switch (action) {
      case 'connect':
        return await this.connect(parsed.address ?? '');
      case 'send':
        return await this.send(parsed.message ?? parsed.data ?? parsed.text ?? '');
      case 'received': {
        const msgs = this.transport.drainReceivedText();
        return msgs.length === 0 ? '暂无收到消息。' : `收到消息：\n${msgs.join('\n')}`;
      }
      default:
        return `nearlink_device 参数错误：未知 action=${action}。支持 connect/send/received。`;
    }
  }

  private async connect(address: string): Promise<string> {
    if (address.length === 0) {
      return 'connect 参数错误：缺少 address（从 search 结果取 MAC）。';
    }
    try {
      await this.transport.connect(address);
      return `已连接星闪设备 ${address}（${this.transport.statusText()}）。`;
    } catch (error) {
      const message = error instanceof Error ? error.message : `${error}`;
      hilog.error(LOG_DOMAIN, LOG_TAG, 'connect failed addr=%{public}s err=%{public}s', address, message);
      return `连接失败：${message}（常见原因：对端未启动广播、地址错误或链路未就绪）`;
    }
  }

  private async send(message: string): Promise<string> {
    if (message.length === 0) {
      return '消息为空。';
    }
    if (!this.transport.isReady()) {
      return '未连接，请先 execute action=connect。';
    }
    try {
      await this.transport.sendText(message);
      return `已发送：${message}`;
    } catch (error) {
      const message2 = error instanceof Error ? error.message : `${error}`;
      return `发送失败：${message2}`;
    }
  }

  private formatDevices(devices: NearLinkDevice[]): string {
    const parts: string[] = [];
    for (let index = 0; index < devices.length; index++) {
      const device = devices[index];
      parts.push(`- ${device.deviceName} | address=${device.address}`);
    }
    return parts.join('\n');
  }
}
