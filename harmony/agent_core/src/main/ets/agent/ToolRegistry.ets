import { common } from '@kit.AbilityKit';
import { ComposioConfig } from '../composio/ComposioConfig';
import { ComposioSessionClient } from '../composio/ComposioSessionClient';
import { ComposioTool } from '../composio/ComposioTool';
import { SandboxFileWriteTool } from '../file/SandboxFileWriteTool';
import { PhotoAlbumTool } from '../album/PhotoAlbumTool';
import { ModelScopeConfig } from '../modelscope/ModelScopeConfig';
import { ModelScopeDirectClient } from '../modelscope/ModelScopeDirectClient';
import { ModelScopeTool } from '../modelscope/ModelScopeTool';
import { NearLinkScanner } from '../nearlink/NearLinkScanner';
import { NearLinkTransport } from '../nearlink/NearLinkTransport';
import { NearLinkDeviceTool } from '../nearlink/NearLinkDeviceTool';
import { FileReassembler } from '../nearlink/FileReassembler';
import { SkillReadTool } from '../skill/SkillReadTool';
import { SkillSnapshot } from '../skill/SkillSnapshot';
import { AgentTool } from './AgentTool';
import { UiTool } from './UiTool';

export type ToolRegistryCloseHandler = () => Promise<void>;

/** 工具可选的 UI 产出回调：工具调用后若产出了 A2UI JSONL，由此回调取出并清空。 */
export type ToolUiPayloadProvider = () => string;

/** 设备绑定成功回调：deviceStateChange(AVAILABLE) 时通知，参数为 deviceId。 */
export type DeviceBoundListener = (deviceId: string) => void;

class NoteTool implements AgentTool {
  name(): string {
    return 'note';
  }

  description(): string {
    return 'Echoes a note back into the loop.';
  }

  async run(input: string): Promise<string> {
    const trimmed = input.trim();
    return trimmed.length === 0 ? 'No note provided.' : `Noted: ${trimmed}`;
  }
}

class TimeTool implements AgentTool {
  name(): string {
    return 'time';
  }

  description(): string {
    return 'Returns the device\'s local date and time.';
  }

  async run(_input: string): Promise<string> {
    return new Date().toLocaleString();
  }
}

export class ToolRegistry {
  private tools: Map<string, AgentTool> = new Map();
  private uiPayloadProviders: Map<string, ToolUiPayloadProvider> = new Map();
  private deviceBoundListeners: DeviceBoundListener[] = [];
  private closeHandlers: ToolRegistryCloseHandler[] = [];

  constructor() {
    this.register(new NoteTool());
    this.register(new TimeTool());
  }

  register(tool: AgentTool): void {
    this.tools.set(tool.name(), tool);
  }

  /** 注册一个工具的 UI 产出回调，供 runner 在该工具调用后确定性渲染 UI 卡片。 */
  registerUiPayloadProvider(name: string, provider: ToolUiPayloadProvider): void {
    this.uiPayloadProviders.set(name, provider);
  }

  /** 注册设备绑定成功监听，deviceStateChange(AVAILABLE) 时触发，参数为 deviceId。 */
  registerDeviceBoundListener(listener: DeviceBoundListener): void {
    this.deviceBoundListeners.push(listener);
  }

  /** 通知所有注册的监听器：某设备绑定成功。 */
  notifyDeviceBound(deviceId: string): void {
    for (let index = 0; index < this.deviceBoundListeners.length; index++) {
      try {
        this.deviceBoundListeners[index](deviceId);
      } catch (_error) {
        // 忽略单个监听器异常
      }
    }
  }

  has(name: string): boolean {
    return this.tools.has(name);
  }

  getTool(name: string): AgentTool | null {
    return this.tools.get(name) ?? null;
  }

  /**
   * 若该工具注册了 UI 产出回调，取出并清空其 pending UI payload；否则返回空串。
   * 供 runner 在工具调用后确定性渲染 UI，不依赖模型调 ui。
   */
  consumeToolUiPayload(name: string): string {
    const provider = this.uiPayloadProviders.get(name);
    if (provider === undefined) {
      return '';
    }
    return provider();
  }

  registerCloseHandler(handler: ToolRegistryCloseHandler): void {
    this.closeHandlers.push(handler);
  }

  describeTools(): string {
    let description = '';
    this.tools.forEach((tool: AgentTool) => {
      description += `- ${tool.name()}: ${tool.description()}\n`;
    });
    return description;
  }

  async run(name: string, input: string): Promise<string> {
    const tool = this.tools.get(name);
    if (tool === undefined) {
      return `Unknown tool: ${name}`;
    }
    return await tool.run(input ?? '');
  }

  async close(): Promise<void> {
    for (let index = 0; index < this.closeHandlers.length; index++) {
      try {
        await this.closeHandlers[index]();
      } catch (_error) {
      }
    }
  }
}

export async function createConfiguredLoopToolRegistry(
  context: common.UIAbilityContext,
  skillSnapshot?: SkillSnapshot | null
): Promise<ToolRegistry> {
  const registry = createLoopToolRegistry(skillSnapshot);
  if (skillSnapshot !== undefined && skillSnapshot !== null && !skillSnapshot.isEmpty()) {
    registry.register(new SandboxFileWriteTool(context));
  }
  const client = new ComposioSessionClient(await ComposioConfig.fromContext(context));
  await client.initialize();
  registry.register(new ComposioTool(client));
  registry.registerCloseHandler(async (): Promise<void> => client.close());
  const modelScopeConfig = await ModelScopeConfig.fromContext(context);
  const modelScopeClient = new ModelScopeDirectClient(modelScopeConfig);
  await modelScopeClient.initialize();
  registry.register(new ModelScopeTool(modelScopeClient));

  // 星闪（NearLink）：设备扫描 + 端口数据传输。softbus 已屏蔽，星闪为唯一跨设备发现/建链/传输通道。
  // dataTransfer 从 5.1.0(18) 起支持（compatibleSdkVersion 已提升）。构造即 createPort 注册端口，
  // source/sink 双端对称；source 扫描后 connect，sink 启动广播等连接。
  // 复用 EntryAbility（sink 端）已建的 transport（若 onCreate 先于 Index 建好），避免重复 createPort；
  // source 端（EntryAbility 未建 transport）则在此新建。
  const nearLinkScanner = new NearLinkScanner();
  const existingTransport = AppStorage.get<NearLinkTransport>('loopNearLinkTransport');
  const nearLinkTransport = existingTransport !== undefined && existingTransport !== null
    ? existingTransport
    : new NearLinkTransport();
  if (existingTransport === undefined || existingTransport === null) {
    AppStorage.setOrCreate<NearLinkTransport>('loopNearLinkTransport', nearLinkTransport);
  }
  // source 端也注册 FileReassembler，使 sink→source 回发照片/文件走星闪双向闭环。
  // sink 端的 reassembler 由 EntryAbility.setupNearLinkReceiver 注册；两端 transport 实例不同时
  // 各自注册不冲突（readData 回调按端口实例分发）。复用同一 AppStorage transport 时，
  // EntryAbility 已注册过 sink reassembler，此处按 source role 再注册一个——
  // transport.registerDataHandler 是单 handler 覆盖语义，故仅在本端 transport 尚未注册时设置。
  if (existingTransport === undefined || existingTransport === null) {
    const sourceReassembler = new FileReassembler(context, 'source');
    nearLinkTransport.registerDataHandler((data: ArrayBuffer, _fromAddress: string): boolean => {
      return sourceReassembler.handleData(data);
    });
  }
  const nearLinkTool = new NearLinkDeviceTool(nearLinkScanner, nearLinkTransport);
  registry.register(nearLinkTool);
  registry.registerUiPayloadProvider('nearlink_device', (): string => nearLinkTool.consumeUiPayload());
  // 注意：不注册 nearLinkTransport.close() 为 registry closeHandler。
  // transport 是跨 registry 复用的进程级单例（EntryAbility/ToolRegistry 共用同一 AppStorage 实例），
  // Index 在 llm 模式重建 registry 时会调旧 registry.close()——若 close() 清掉 transport 的
  // connected/peerAddress/textMessageListeners，会导致刚收到的对端连接被误判断开（agent 看到 disconnected）。
  // transport 的生命周期随进程，不随 registry 重建。

  // 相册选择：仅 pick（PhotoViewPicker 系统选择器）；选完若星闪已连接，自动读字节分片发送。
  const photoAlbumTool = new PhotoAlbumTool(nearLinkTransport);
  registry.register(photoAlbumTool);
  return registry;
}

export function createLoopToolRegistry(skillSnapshot?: SkillSnapshot | null): ToolRegistry {
  const registry = new ToolRegistry();
  registry.register(new UiTool());
  if (skillSnapshot !== undefined && skillSnapshot !== null && !skillSnapshot.isEmpty()) {
    registry.register(new SkillReadTool(skillSnapshot));
  }
  return registry;
}
