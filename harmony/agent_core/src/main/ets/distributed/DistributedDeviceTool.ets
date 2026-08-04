import { AgentTool } from '../agent/AgentTool';
import { DeviceManagerClient, DiscoveredDevice } from './DeviceManagerClient';
import { AbilityConnectionClient } from './AbilityConnectionClient';
import { buildDeviceListCardJsonl } from '../a2ui/DeviceListCard';

interface DistributedDeviceToolInput {
  operation?: string;     // 'search' | 'execute'
  useCase?: string;       // search 阶段的任务描述
  action?: string;        // execute 阶段：list | discover | bind | connect | send | received
  deviceId?: string;     // bind / connect 的目标
  message?: string;       // send 的消息
}

/**
 * 对外暴露的分布式设备工具。两阶段语义与 Composio/ModelScope 一致：
 *   operation=search   —— 列出已绑定设备 + 周边发现候选，供模型选择
 *   operation=execute  —— 执行具体动作（list/discover/bind/connect/send/received）
 */
export class DistributedDeviceTool implements AgentTool {
  private dmClient: DeviceManagerClient;
  private connClient: AbilityConnectionClient;
  private pendingUiPayload: string = '';

  /** 取出并清空待渲染的设备列表卡片 payload，供 ToolRegistry 注册的 UI 回调调用。 */
  consumeUiPayload(): string {
    const payload = this.pendingUiPayload;
    this.pendingUiPayload = '';
    return payload;
  }

  /** 直接发起绑定（绕过 agent runAgent），供 UI 点设备行后直接调用。 */
  async bindDevice(deviceId: string): Promise<string> {
    return await this.dmClient.bind(deviceId);
  }

  /**
   * sink 端接管 onCollaborate 建立的会话，让 distributed_device 的 send/received
   * 在被拉起的对端也能用。供 Index 在 AppStorage('loopSinkSessionId') 出现时调用。
   */
  adoptSinkSession(sessionId: number): void {
    this.connClient.adoptSinkSession(sessionId);
  }

  /**
   * sink 端直接回发：用 AppStorage('loopSinkSessionId') 里由 onCollaborate 建立的
   * 会话 sessionId 直接发，不依赖本实例的 adopted 状态（adopt 链时序不可靠）。
   * receive 能收到即证明该 sessionId 存活，sendMessage 在其上可用。
   */
  async sendAsSink(message: string): Promise<string> {
    const sessionId = AppStorage.get<number>('loopSinkSessionId') ?? -1;
    return await this.connClient.sendOnSession(sessionId, message);
  }

  /**
   * 最近一次 search/discover/list 返回的设备列表。供 ui 工具的
   * distributed_device:list 渲染分支读取，以保真卡片展示。
   */
  lastDevices: DiscoveredDevice[] = [];

  constructor(dmClient: DeviceManagerClient, connClient: AbilityConnectionClient) {
    this.dmClient = dmClient;
    this.connClient = connClient;
  }

  name(): string {
    return 'distributed_device';
  }

  description(): string {
    return this.toolDescription();
  }

  async run(input: string): Promise<string> {
    let parsed: DistributedDeviceToolInput;
    try {
      parsed = JSON.parse(input) as DistributedDeviceToolInput;
    } catch (_error) {
      return 'distributed_device 参数错误：输入必须是 JSON。';
    }

    if (parsed.operation === 'search') {
      return this.search();
    }
    if (parsed.operation === 'execute') {
      return this.execute(parsed);
    }
    return 'distributed_device 参数错误：operation 必须是 search 或 execute。';
  }

  private toolDescription(): string {
    if (!this.dmClient.isAvailable()) {
      return `distributed_device unavailable (${this.dmClient.initErrorText()}). Do not call this tool.`;
    }
    const trusted = this.dmClient.listTrusted();
    const connStatus = this.connClient.statusText();
    const trustedText = trusted.length > 0
      ? trusted.map((d: DiscoveredDevice): string => `${d.deviceName}(${d.deviceId})`).join(', ')
      : '无';
    const connected = connStatus.startsWith('connected');
    const sinkSessionId = AppStorage.get<number>('loopSinkSessionId') ?? -1;
    const hasSession = connected || sinkSessionId >= 0;
    // 已有活动会话时，明确告诉模型无需再 search/discover，直接 send，避免冗余调用。
    const flowHint = hasSession
      ? `当前已有活动会话，无需再 search/discover，直接用 {"operation":"execute","action":"send","message":"..."} 发送文本。`
      : '两阶段：先用 {"operation":"search"} 列出已绑定设备并发现周边候选；再用 {"operation":"execute","action":"bind|connect|send|..."} 执行。';
    return '跨设备发现、绑定与消息收发。' + flowHint +
      ` 已绑定设备: ${trustedText}. 连接状态: ${connStatus}. ` +
      'connect/send 需在对端接受连接后方可通信；绑定需对端确认 PIN 码。' +
      ' 返回设备列表后，建议调用 ui 工具并以 distributed_device:list 作为描述，将设备以卡片展示。';
  }

  private async search(): Promise<string> {
    // 先取已绑定设备，再发现周边未绑定设备，合并去重（已绑定的不重复列）。
    const trusted = this.dmClient.listTrusted();
    const discovered = await this.dmClient.discover();
    const trustedIds = new Set<string>();
    for (let i = 0; i < trusted.length; i++) {
      trustedIds.add(trusted[i].deviceId);
    }
    const fresh: DiscoveredDevice[] = [];
    for (let i = 0; i < discovered.length; i++) {
      if (!trustedIds.has(discovered[i].deviceId)) {
        fresh.push(discovered[i]);
      }
    }
    this.lastDevices = [...trusted, ...fresh];
    this.pendingUiPayload = buildDeviceListCardJsonl(this.lastDevices);
    const parts: string[] = [];
    if (trusted.length > 0) {
      parts.push(`已绑定设备（${trusted.length}）：${this.formatDevices(trusted)}`);
    }
    if (fresh.length > 0) {
      parts.push(`周边新发现设备（${fresh.length}）：${this.formatDevices(fresh)}`);
    }
    if (parts.length === 0) {
      return '未发现任何设备。可稍后重试。';
    }
    return parts.join('\n');
  }

  private async execute(parsed: DistributedDeviceToolInput): Promise<string> {
    const action = parsed.action ?? '';
    switch (action) {
      case 'list':
        return await this.search();
      case 'discover': {
        const devices = await this.dmClient.discover();
        this.lastDevices = devices;
        this.pendingUiPayload = buildDeviceListCardJsonl(devices);
        return this.formatDevices(devices);
      }
      case 'bind':
        return await this.dmClient.bind(parsed.deviceId ?? '');
      case 'connect':
        return await this.connClient.connect(parsed.deviceId ?? '');
      case 'send':
        return await this.connClient.sendMessage(parsed.message ?? '');
      case 'received': {
        const msgs = this.connClient.drainReceived();
        return msgs.length === 0 ? '暂无收到消息。' : `收到消息：\n${msgs.join('\n')}`;
      }
      default:
        return `distributed_device 参数错误：未知 action=${action}。支持 list/discover/bind/connect/send/received。`;
    }
  }

  private formatDevices(devices: DiscoveredDevice[]): string {
    if (devices.length === 0) {
      return '未发现设备。';
    }
    const parts: string[] = [];
    for (let index = 0; index < devices.length; index++) {
      const device = devices[index];
      parts.push(`- ${device.deviceName} | deviceId=${device.deviceId}`);
    }
    return `设备列表：\n${parts.join('\n')}`;
  }
}
