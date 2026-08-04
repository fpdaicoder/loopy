import { common } from '@kit.AbilityKit';
import { distributedDeviceManager } from '@kit.DistributedServiceKit';
import { ComposioConfig } from '../composio/ComposioConfig';
import { ComposioSessionClient } from '../composio/ComposioSessionClient';
import { ComposioTool } from '../composio/ComposioTool';
import { SandboxFileWriteTool } from '../file/SandboxFileWriteTool';
import { PhotoAlbumTool } from '../album/PhotoAlbumTool';
import { ModelScopeConfig } from '../modelscope/ModelScopeConfig';
import { ModelScopeDirectClient } from '../modelscope/ModelScopeDirectClient';
import { ModelScopeTool } from '../modelscope/ModelScopeTool';
import { DeviceManagerClient, DiscoveredDevice } from '../distributed/DeviceManagerClient';
import { AbilityConnectionClient } from '../distributed/AbilityConnectionClient';
import { DistributedDeviceTool } from '../distributed/DistributedDeviceTool';
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

  // 分布式设备管理：发现 + 绑定 + 跨设备消息收发。
  const dmClient = new DeviceManagerClient(context);
  await dmClient.initialize();
  const connClient = new AbilityConnectionClient(context, dmClient);
  await connClient.initialize();
  const distributedTool = new DistributedDeviceTool(dmClient, connClient);
  registry.register(distributedTool);
  registry.registerUiPayloadProvider('distributed_device', (): string => distributedTool.consumeUiPayload());
  // 绑定成功（设备 AVAILABLE）时通知 UI 刷新行状态为已绑定。
  dmClient.onStateChange((action: distributedDeviceManager.DeviceStateChange, device: DiscoveredDevice): void => {
    if (action === distributedDeviceManager.DeviceStateChange.AVAILABLE && device.deviceId.length > 0) {
      registry.notifyDeviceBound(device.deviceId);
    }
  });
  registry.registerCloseHandler(async (): Promise<void> => { await connClient.close(); await dmClient.close(); });

  // 相册选择：仅 pick（PhotoViewPicker 系统选择器）；选完若已连接对端，自动读字节经 sendData 发送。
  const photoAlbumTool = new PhotoAlbumTool(context, connClient);
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
