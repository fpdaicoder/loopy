import { A2uiComponentDef } from '@loop/agent-core';
import { common } from '@kit.AbilityKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import fs from '@ohos.file.fs';
import {
  AgentEvent,
  AgentEventKind,
  A2uiAgentRunner,
  buildDeviceListCardJsonl,
  clearStoredConversation,
  ConversationContext,
  ConversationRole,
  createA2uiModelInfo,
  createConfiguredLoopToolRegistry,
  createLoopModelInfo,
  createSkillSnapshot,
  DistributedDeviceTool,
  loadConversation,
  parseJsonl,
  ReActAgentRunner,
  saveConversation,
  ScriptedA2uiModel,
  SkillSnapshot,
  ToolRegistry,
  UiRenderHandler
} from '@loop/agent-core';
import { A2uiFallbackView } from '../agenui/A2uiFallbackView';
import { hasRenderableRoot, parseComponentsFromJsonl } from '../agenui/A2uiFallbackParser';
import { componentsFromUiEvent } from '../agenui/LoopUiApplier';

const MAX_STEPS = 6;
const WELCOME_TRANSCRIPT = 'Loop is ready. Ask anything — I will show a UI card when helpful.\n';

@Entry
@Component
struct Index {
  @State transcript: string = WELCOME_TRANSCRIPT;
  @State message: string = '';
  @State sending: boolean = false;
  @State modelStatus: string = 'Checking model…';
  @State uiComponents: A2uiComponentDef[] = [];
  @State hasUiPanel: boolean = false;
  @State bindingDevices: string[] = [];
  @State boundDevices: string[] = [];
  // sink 端：本设备被对端 connect 拉起并已接管协同会话。此时用户输入直接经
  // distributed_device send 回发，不走 agent（避免依赖 LLM 选择调用 send）。
  @State isSink: boolean = false;
  // sink 端协同：被对端 connect 拉起后，onCollaborate 里 acceptConnect 建立的会话，
  // 其 receiveMessage 把消息塞进 AppStorage('loopSinkPendingMessages') 并自增本序号。
  // 序号变化即有新消息，drain 队列追加到 transcript（仅展示，不自动回发）。
  @StorageProp('loopSinkMessageSeq') @Watch('onSinkMessageSeqChanged') loopSinkMessageSeq: number = 0;
  // sink 端会话 sessionId：EntryAbility 在 acceptConnect 成功后写入。出现即接管进
  // AbilityConnectionClient，使本端 distributed_device 的 send/received 可用（可回发）。
  @StorageProp('loopSinkSessionId') @Watch('onSinkSessionIdChanged') loopSinkSessionId: number = -1;
  // source 端：本端 connect 建立会话后，对端回发的消息由 AbilityConnectionClient 的
  // receiveMessage 回调塞进 AppStorage('loopSourcePendingMessages') 并自增本序号。
  // 序号变化即 drain 队列，以「对端」身份追加到 transcript（自动展示，无需 agent 调 received）。
  @StorageProp('loopSourceMessageSeq') @Watch('onSourceMessageSeqChanged') loopSourceMessageSeq: number = 0;
  // sink 端收到文件：EntryAbility 存沙箱后把路径写进 AppStorage 并自增本序号。
  // 序号变化即取路径存入 pendingFilePath，主页显示 SaveButton，点击控件授权存进图库。
  @StorageProp('loopSinkFileSeq') @Watch('onSinkFileArrived') loopSinkFileSeq: number = 0;
  // source 端收到对端回发的文件：AbilityConnectionClient 存沙箱后写 loopSourcePendingFile
  // 并自增本序号。source/sink 任一端收到文件都触发 pendingFilePath 渲染 SaveButton。
  @StorageProp('loopSourceFileSeq') @Watch('onSourceFileArrived') loopSourceFileSeq: number = 0;
  // 待存进图库的文件沙箱路径；非空时主页显示「保存到相册」SaveButton。
  @State pendingFilePath: string = '';

  private scroller: Scroller = new Scroller();
  private conversation: ConversationContext = new ConversationContext();
  private skillSnapshot: SkillSnapshot | null = null;
  private lastUiTask: string = '';
  private toolRegistryPromise: Promise<ToolRegistry> | null = null;
  private toolRegistryIncludesSkills: boolean = false;

  private getAbilityContext(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  aboutToAppear(): void {
    const context = this.getAbilityContext();
    this.restoreConversation();
    this.toolRegistryPromise = this.createToolRegistry(context);
    createLoopModelInfo(context).then((info) => {
      this.updateModelStatus(info.mode, info.modelName);
    });
    // 若本进程已是 sink（onCollaborate 早于首帧把 sessionId 写入 AppStorage），
    // 首帧兜底接管，避免 @Watch 因值未变化而漏触发。
    const existingSinkSession = AppStorage.get<number>('loopSinkSessionId') ?? -1;
    if (existingSinkSession >= 0) {
      this.onSinkSessionIdChanged();
    }
  }

  private createToolRegistry(context: common.UIAbilityContext, skillSnapshot?: SkillSnapshot): Promise<ToolRegistry> {
    const registryPromise = skillSnapshot !== undefined
      ? createConfiguredLoopToolRegistry(context, skillSnapshot)
      : createConfiguredLoopToolRegistry(context);
    registryPromise.then((registry: ToolRegistry): void => {
      registry.registerDeviceBoundListener((deviceId: string): void => {
        this.markDeviceBound(deviceId);
      });
    }).catch((): void => {});
    return registryPromise;
  }

  private markDeviceBound(deviceId: string): void {
    if (deviceId.length === 0) {
      return;
    }
    this.bindingDevices = this.removeId(this.bindingDevices, deviceId);
    this.boundDevices = this.appendId(this.boundDevices, deviceId);
  }

  aboutToDisappear(): void {
    const tools = this.toolRegistryPromise;
    this.toolRegistryPromise = null;
    this.toolRegistryIncludesSkills = false;
    tools?.then(async (registry: ToolRegistry): Promise<void> => registry.close()).catch((_error: Error): void => {});
  }

  /**
   * sink 端收到对端消息：drain AppStorage 队列，最后一条作为 task 注入 agent。
   * agent 推理后可能调 photo_album pick（回发照片）或 distributed_device send（回发文本）。
   * 之前的消息作为对端发言显示，避免丢上下文。
   */
  onSinkMessageSeqChanged(): void {
    const pending = AppStorage.get<string[]>('loopSinkPendingMessages');
    if (pending === undefined || pending === null || pending.length === 0) {
      return;
    }
    AppStorage.setOrCreate<string[]>('loopSinkPendingMessages', []);
    let lastTask: string = '';
    for (let index = 0; index < pending.length; index++) {
      const msg = pending[index];
      if (msg.length > 0) {
        lastTask = msg;
      }
    }
    if (lastTask.length === 0) {
      return;
    }
    // sink 端收到对端指令后跑 agent 自动响应（选照片/回发文本）。
    this.runAgentWithTask(lastTask, false);
  }

  /**
   * source 端收到对端回发消息：序号变化即 drain AppStorage('loopSourcePendingMessages')，
   * 逐条以「对端」身份追加到 transcript。自动展示，无需 agent 调 distributed_device received。
   * 与 sink 端路径独立：agent 的 received action 仍读 AbilityConnectionClient.receivedMessages。
   */
  onSourceMessageSeqChanged(): void {
    const pending = AppStorage.get<string[]>('loopSourcePendingMessages');
    if (pending === undefined || pending === null || pending.length === 0) {
      return;
    }
    AppStorage.setOrCreate<string[]>('loopSourcePendingMessages', []);
    for (let index = 0; index < pending.length; index++) {
      const msg = pending[index];
      if (msg.length > 0) {
        this.appendLine('对端', msg);
      }
    }
  }

  /**
   * sink 端收到文件：从 AppStorage 取沙箱路径存入 pendingFilePath，主页显示 SaveButton。
   */
  onSinkFileArrived(): void {
    const path = AppStorage.get<string>('loopSinkPendingFile') ?? '';
    if (path.length > 0) {
      this.pendingFilePath = path;
    }
  }

  /**
   * source 端收到对端回发文件：从 AppStorage 取沙箱路径存入 pendingFilePath，显示 SaveButton。
   */
  onSourceFileArrived(): void {
    const path = AppStorage.get<string>('loopSourcePendingFile') ?? '';
    if (path.length > 0) {
      this.pendingFilePath = path;
    }
  }

  /**
   * SaveButton 点击成功（控件授权窗口内）：读沙箱文件字节 → photoAccessHelper.createAsset
   * 写入系统媒体库（图库可见）。控件授权仅在 onClick 回调内有效，须在此发起 createAsset。
   */
  async saveReceivedFileToGallery(): Promise<void> {
    const path = this.pendingFilePath;
    if (path.length === 0) {
      return;
    }
    try {
      const helper = photoAccessHelper.getPhotoAccessHelper(this.getAbilityContext());
      const uri = await this.writeFileToGallery(helper, path);
      this.appendLine('Loop', `已保存到相册：${uri}`);
    } catch (error) {
      const text = error instanceof Error ? error.message : `${error}`;
      this.appendLine('Error', `保存到相册失败：${text}`);
    } finally {
      this.pendingFilePath = '';
    }
  }

  /**
   * 读沙箱文件字节，createAsset 创建媒体库条目并写入字节，返回媒体库 URI。
   * 当前统一按 IMAGE 类型存（SaveButton 控件授权支持图片）；视频需改 PhotoType.VIDEO。
   */
  private async writeFileToGallery(helper: photoAccessHelper.PhotoAccessHelper,
    path: string): Promise<string> {
    // 读沙箱文件字节。
    const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
    let bytes: ArrayBuffer;
    try {
      const stat = fs.statSync(file.fd);
      const size = stat.size > 0 ? stat.size : 0;
      if (size <= 0) {
        throw new Error('文件为空');
      }
      bytes = new ArrayBuffer(size);
      fs.readSync(file.fd, bytes);
    } finally {
      fs.closeSync(file);
    }
    // createAsset(PhotoType.IMAGE, 'jpg') 在本 SDK 返回媒体库 URI 字符串（非 PhotoAsset 对象）。
    // TODO: 根据实际文件类型（照片/视频）选 PhotoType.IMAGE / VIDEO。
    const targetUri = await helper.createAsset(photoAccessHelper.PhotoType.IMAGE, 'jpg');
    // 打开媒体库 URI 写入字节。SaveButton 控件授权窗口内有效。
    const target = fs.openSync(targetUri, fs.OpenMode.READ_WRITE);
    try {
      fs.writeSync(target.fd, bytes);
    } finally {
      fs.closeSync(target);
    }
    return targetUri;
  }

  /**
   * sink 端接管协同会话：EntryAbility acceptConnect 成功后把 sessionId 写入
   * AppStorage('loopSinkSessionId')。本回调把它接入 AbilityConnectionClient，
   * 使本端 distributed_device 的 send/received 可用——用户手动输入由 agent 经
   * distributed_device send 回发。
   */
  onSinkSessionIdChanged(): void {
    const sessionId = AppStorage.get<number>('loopSinkSessionId') ?? -1;
    if (sessionId < 0) {
      return;
    }
    const registryPromise = this.toolRegistryPromise;
    if (registryPromise === null) {
      return;
    }
    registryPromise.then((registry: ToolRegistry): void => {
      const tool = registry.getTool('distributed_device');
      if (tool instanceof DistributedDeviceTool) {
        tool.adoptSinkSession(sessionId);
        this.isSink = true;
        this.appendLine('Loop', `已接管协同会话，可输入消息回发对端（sessionId=${sessionId}）。`);
      }
    }).catch((_error: Error): void => {});
  }

  /**
   * sink 端直接回发：用户输入的消息经 distributed_device 的 send 动作发往对端，
   * 不走 ReAct agent。失败时把错误作为 Observation 展示，并复位 sending。
   */
  private async sendAsSink(message: string): Promise<void> {
    try {
      const registry = await this.toolRegistryPromise;
      if (registry === null) {
        this.appendLine('Error', '工具未就绪，无法回发。');
        return;
      }
      const tool = registry.getTool('distributed_device');
      if (tool instanceof DistributedDeviceTool) {
        // 直接用 onCollaborate 建立的 sink 会话回发，不经 tool 的 send action（那条依赖 adopted 状态）。
        const result = await tool.sendAsSink(message);
        this.appendLine('Observation', result);
      } else {
        this.appendLine('Error', 'distributed_device 工具未就绪，无法回发。');
      }
    } catch (error) {
      const text = error instanceof Error ? error.message : `${error}`;
      this.appendLine('Error', `回发失败：${text}`);
    } finally {
      this.sending = false;
    }
  }

  build() {
    Column() {
      Row() {
        Text(this.modelStatus)
          .fontSize(12)
          .fontColor($r('app.color.text_primary'))
          .opacity(0.7)
          .layoutWeight(1)

        Button('Clear')
          .fontSize(12)
          .height(28)
          .backgroundColor(Color.Transparent)
          .fontColor($r('app.color.send_button'))
          .enabled(!this.sending)
          .onClick(() => {
            this.clearConversation();
          })
      }
      .width('100%')
      .margin({ bottom: 8 })

      if (this.hasUiPanel) {
        Column() {
          Text('On-screen UI')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .width('100%')
            .margin({ bottom: 6 })

          Scroll() {
            A2uiFallbackView({
              components: this.uiComponents,
              bindingDevices: this.bindingDevices,
              boundDevices: this.boundDevices,
              onDeviceSelect: (deviceId: string, deviceName: string): void => {
                this.onDeviceSelected(deviceId, deviceName);
              }
            })
              .width('100%')
          }
          .width('100%')
          .height(220)
        }
        .width('100%')
        .padding(12)
        .margin({ bottom: 8 })
        .borderRadius(12)
        .backgroundColor(Color.White)
        .border({ width: 1, color: $r('app.color.input_stroke') })
      }

      if (this.pendingFilePath.length > 0) {
        Column() {
          Text('收到对端文件')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .width('100%')
            .margin({ bottom: 8 })

          // SaveButton 是安全控件：点击成功时系统临时授予媒体库写权限（无需声明
          // WRITE_IMAGEVIDEO 受限权限，绕开受限权限安装失败）。onClick 回调内调
          // saveReceivedFileToGallery 完成存图库。
          SaveButton()
            .onClick((_event: ClickEvent, result: SaveButtonOnClickResult) => {
              if (result === SaveButtonOnClickResult.SUCCESS) {
                this.saveReceivedFileToGallery();
              }
            })
        }
        .width('100%')
        .padding(12)
        .margin({ bottom: 8 })
        .borderRadius(12)
        .backgroundColor(Color.White)
        .border({ width: 1, color: $r('app.color.input_stroke') })
      }

      Scroll(this.scroller) {
        Text(this.transcript)
          .fontSize(16)
          .fontColor($r('app.color.text_primary'))
          .lineHeight(24)
          .width('100%')
          .textAlign(TextAlign.Start)
      }
      .layoutWeight(1)
      .width('100%')
      .align(Alignment.BottomStart)
      .padding({ left: 4, right: 4, top: 4, bottom: 12 })

      Row() {
        TextInput({ text: this.message, placeholder: 'Message Loop' })
          .layoutWeight(1)
          .height(52)
          .borderRadius(20)
          .backgroundColor(Color.White)
          .border({ width: 1, color: $r('app.color.input_stroke') })
          .padding({ left: 14, right: 14 })
          .enabled(!this.sending)
          .onChange((value: string) => {
            this.message = value;
          })
          .onSubmit(() => {
            this.runAgent();
          })

        Button(this.sending ? '...' : 'Send')
          .width(86)
          .height(52)
          .margin({ left: 8 })
          .backgroundColor($r('app.color.send_button'))
          .fontColor(Color.White)
          .enabled(!this.sending)
          .onClick(() => {
            this.runAgent();
          })
      }
      .width('100%')
      .padding({ top: 10 })
    }
    .width('100%')
    .height('100%')
    .padding(14)
    .backgroundColor($r('app.color.page_background'))
  }

  private async runAgent(): Promise<void> {
    const task = this.message.trim();
    if (task.length === 0 || this.sending) {
      return;
    }
    this.message = '';
    await this.runAgentWithTask(task, true);
  }

  /**
   * sink 端收到对端消息后自动注入 agent：对端发的「选照片」类指令经 LLM 推理，
   * agent 调 photo_album pick（自动经 connClient.sendData 回发照片字节）或
   * distributed_device send（回发文本）。sink 端也走完整 ReAct 流程，不再直接 sendAsSink。
   */
  private async runAgentWithTask(task: string, fromUser: boolean): Promise<void> {
    if (task.length === 0 || this.sending) {
      return;
    }
    if (fromUser) {
      this.appendUserMessage(task);
    } else {
      // 对端消息作为「用户任务」注入，标注来源为对端。
      this.appendLine('对端', task);
    }
    this.sending = true;

    let finalAnswer: string | null = null;

    try {
      const context = this.getAbilityContext();
      let modelInfo = await createLoopModelInfo(context);
      let skillSnapshot: SkillSnapshot | undefined = undefined;
      if (modelInfo.mode === 'llm') {
        skillSnapshot = this.skillSnapshot ?? await createSkillSnapshot(context);
        this.skillSnapshot = skillSnapshot;
        modelInfo = await createLoopModelInfo(context, skillSnapshot);
      }
      this.updateModelStatus(modelInfo.mode, modelInfo.modelName);

      const uiHandler = await this.buildUiHandler();
      if (modelInfo.mode === 'llm' && skillSnapshot !== undefined && !this.toolRegistryIncludesSkills) {
        const oldTools = this.toolRegistryPromise;
        oldTools?.then(async (registry: ToolRegistry): Promise<void> => registry.close()).catch((_error: Error): void => {});
        this.toolRegistryPromise = this.createToolRegistry(context, skillSnapshot);
        this.toolRegistryIncludesSkills = true;
      } else if (modelInfo.mode !== 'llm' && this.toolRegistryIncludesSkills) {
        const oldTools = this.toolRegistryPromise;
        oldTools?.then(async (registry: ToolRegistry): Promise<void> => registry.close()).catch((_error: Error): void => {});
        this.toolRegistryPromise = this.createToolRegistry(context);
        this.toolRegistryIncludesSkills = false;
      } else if (this.toolRegistryPromise === null) {
        this.toolRegistryPromise = this.createToolRegistry(context);
        this.toolRegistryIncludesSkills = false;
      }
      const tools = await this.toolRegistryPromise;
      const runner = new ReActAgentRunner(
        modelInfo.model,
        tools,
        MAX_STEPS,
        uiHandler,
        skillSnapshot,
        modelInfo.mode === 'llm'
      );

      await runner.run(task, (event: AgentEvent) => {
        if (event.kind === AgentEventKind.FINAL) {
          finalAnswer = event.text;
        }
        if (event.kind === AgentEventKind.ACTION && event.text.startsWith('ui(')) {
          this.lastUiTask = this.extractToolInput(event.text);
        }
        if (event.kind === AgentEventKind.ACTION && event.text.startsWith('write_sandbox_file(')) {
          this.skillSnapshot = null;
          this.toolRegistryIncludesSkills = false;
        }
        if (event.kind === AgentEventKind.UI) {
          const uiTask = this.lastUiTask.length > 0 ? this.lastUiTask : task;
          this.applyUiPayload(event.text, uiTask);
        }
        this.addEvent(event);
      }, this.conversation);
    } finally {
      if (finalAnswer !== null) {
        this.conversation.addUser(task);
        this.conversation.addAssistant(finalAnswer);
        saveConversation(this.getAbilityContext(), this.conversation);
      }
      this.sending = false;
    }
  }

  private async buildUiHandler(): Promise<UiRenderHandler> {
    const a2uiInfo = await createA2uiModelInfo(this.getAbilityContext());
    const a2uiRunner = new A2uiAgentRunner(a2uiInfo.model);
    const scripted = new ScriptedA2uiModel();

    return async (description: string): Promise<string[]> => {
      // 确定性分支：distributed_device:list 直接用脚本化卡片展示设备列表，跳过 LLM，保真。
      if (description.trim().startsWith('distributed_device:list')) {
        try {
          const registryPromise = this.toolRegistryPromise;
          if (registryPromise !== null) {
            const registry = await registryPromise;
            const tool = registry.getTool('distributed_device');
            if (tool instanceof DistributedDeviceTool) {
              const devices = tool.lastDevices;
              return parseJsonl(buildDeviceListCardJsonl(devices));
            }
          }
        } catch (_error) {
          // 回退到 LLM 路径
        }
      }

      const lines: string[] = [];
      const surfaceId = await a2uiRunner.run(
        description,
        (line: string) => {
          lines.push(line);
        },
        (_message: string) => {
          // errors surface as observation via empty lines + fallback below
        }
      );

      if (surfaceId !== null && hasRenderableRoot(parseComponentsFromJsonl(lines))) {
        return lines;
      }

      const fallbackRaw = await scripted.generate(description, surfaceId ?? 'loop_ui', undefined);
      return parseJsonl(fallbackRaw);
    };
  }

  private extractToolInput(actionText: string): string {
    const open = actionText.indexOf('(');
    const close = actionText.lastIndexOf(')');
    if (open >= 0 && close > open) {
      return actionText.substring(open + 1, close);
    }
    return actionText;
  }

  private applyUiPayload(jsonlPayload: string, fallbackTask: string): void {
    this.uiComponents = componentsFromUiEvent(jsonlPayload, fallbackTask);
    this.hasUiPanel = this.uiComponents.length > 0;
  }

  private updateModelStatus(mode: 'llm' | 'scripted', modelName: string): void {
    if (mode === 'llm') {
      this.modelStatus = `LLM: ${modelName}`;
    } else {
      this.modelStatus = 'Offline demo (no API key — add entry/.../rawfile/llm_config.json)';
    }
  }

  private restoreConversation(): void {
    this.conversation = loadConversation(this.getAbilityContext());
    this.transcript = this.buildTranscriptFromConversation(this.conversation);
  }

  private buildTranscriptFromConversation(conversation: ConversationContext): string {
    const turns = conversation.toChatMessages();
    if (turns.length === 0) {
      return WELCOME_TRANSCRIPT;
    }

    let transcript = WELCOME_TRANSCRIPT.trim();
    for (const turn of turns) {
      const speaker = turn.role === ConversationRole.USER ? 'You' : 'Loop';
      transcript += `\n\n${speaker}\n${turn.content}`;
    }
    return `${transcript}\n`;
  }

  private clearConversation(): void {
    this.conversation.clear();
    clearStoredConversation(this.getAbilityContext());
    this.transcript = WELCOME_TRANSCRIPT;
    this.uiComponents = [];
    this.hasUiPanel = false;
    this.lastUiTask = '';
  }

  private addEvent(event: AgentEvent): void {
    switch (event.kind) {
      case AgentEventKind.THOUGHT:
        this.appendLine('Loop', event.text);
        break;
      case AgentEventKind.SKILL:
        this.appendLine('Skill', event.text === 'none' ? 'none (continue with tools)' : event.text);
        break;
      case AgentEventKind.ACTION:
        this.appendLine('Tool', event.text);
        break;
      case AgentEventKind.OBSERVATION:
        this.appendLine('Observation', event.text);
        break;
      case AgentEventKind.UI:
        this.appendLine('UI', 'Updated on-screen panel above.');
        break;
      case AgentEventKind.FINAL:
        this.appendLine('Loop', event.text);
        break;
      case AgentEventKind.ERROR:
      default:
        this.appendLine('Error', event.text);
        break;
    }
  }

  private appendUserMessage(message: string): void {
    this.appendLine('You', message);
  }

  private async onDeviceSelected(deviceId: string, deviceName: string): Promise<void> {
    if (deviceId.length === 0 || this.contains(this.boundDevices, deviceId) || this.contains(this.bindingDevices, deviceId)) {
      return;
    }
    this.bindingDevices = this.appendId(this.bindingDevices, deviceId);
    const name = deviceName.length > 0 ? deviceName : '该设备';
    this.appendLine('You', `绑定设备${name}`);
    try {
      const registryPromise = this.toolRegistryPromise;
      if (registryPromise === null) {
        this.bindingDevices = this.removeId(this.bindingDevices, deviceId);
        return;
      }
      const registry = await registryPromise;
      const tool = registry.getTool('distributed_device');
      if (tool instanceof DistributedDeviceTool) {
        // 先启动超时兜底，再 await bindTarget。bindTarget 在对端不响应时回调可能永不触发，
        // 若 setTimeout 放在 await 之后会被挂起的 Promise 永久阻塞。
        let timedOut = false;
        const timer = setTimeout((): void => {
          timedOut = true;
          if (this.contains(this.bindingDevices, deviceId) && !this.contains(this.boundDevices, deviceId)) {
            const next: string[] = this.removeId(this.bindingDevices, deviceId);
            this.bindingDevices = [];
            this.bindingDevices = next;
            this.appendLine('Loop', `绑定${name}超时，对端可能未响应或 PIN 码认证失败。`);
          }
        }, 30000);
        try {
          await (tool as DistributedDeviceTool).bindDevice(deviceId);
        } finally {
          if (!timedOut) {
            clearTimeout(timer);
          }
        }
      } else {
        this.bindingDevices = this.removeId(this.bindingDevices, deviceId);
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : `${error}`;
      this.appendLine('Error', `绑定失败：${message}`);
      this.bindingDevices = this.removeId(this.bindingDevices, deviceId);
    }
  }

  private contains(arr: string[], value: string): boolean {
    for (let index = 0; index < arr.length; index++) {
      if (arr[index] === value) {
        return true;
      }
    }
    return false;
  }

  private appendId(arr: string[], value: string): string[] {
    if (this.contains(arr, value)) {
      return arr;
    }
    const next: string[] = arr.slice();
    next.push(value);
    return next;
  }

  private removeId(arr: string[], value: string): string[] {
    const next: string[] = [];
    for (let index = 0; index < arr.length; index++) {
      if (arr[index] !== value) {
        next.push(arr[index]);
      }
    }
    return next;
  }

  private appendLine(speaker: string, text: string): void {
    const prefix = this.transcript.trim().length === 0 ? '' : '\n\n';
    this.transcript += `${prefix}${speaker}\n${text}`;
    this.scroller.scrollEdge(Edge.Bottom);
  }
}
