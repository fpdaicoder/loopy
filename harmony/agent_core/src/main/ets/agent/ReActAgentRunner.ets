import { AgentEvent, AgentEventKind } from './AgentEvent';
import { summarizeA2uiObservation } from './A2uiObservationDigest';
import { ConversationContext } from './ConversationContext';
import { ToolRegistry } from './ToolRegistry';
import { LocalModel } from '../model/LocalModel';
import { skillLogInfo, skillLogWarn } from '../skill/SkillLog';
import { buildSkillsSection, SkillSnapshot } from '../skill/SkillSnapshot';
import { parseJsonl } from '../a2ui/A2uiProtocol';

export type AgentListener = (event: AgentEvent) => void;
export type UiRenderHandler = (description: string) => Promise<string[]>;

const UI_TOOL_NAME = 'ui';
const READ_TOOL_NAME = 'read';
const REACT_TAGS: string[] = ['Thought:', 'Execution:', 'Action:', 'Observation:', 'Final:'];

/** 标签匹配结果：start=标签起始下标（-1 表未找到），length=命中的标签串长度（中英文别名长度不同）。 */
interface TagMatch {
  start: number;
  length: number;
}

/**
 * ReAct 标签的中文别名。GLM 等中文模型在中文上下文里常把英文标签本地化
 * （Thought→思考、Execution→执行、Action→动作、Observation→观察、Final→最终/最终答案），
 * 且可能用中文全角冒号「：」或英文半角冒号「:」。这里把每个英文标签映射到它的中文别名集合，
 * 让 findTagStart/extractTaggedLines/truncateAtFirstAction 同时认英文与中文，避免模型用中文
 * 输出「动作：photo_album[...]」时解析器认不出 Action 导致工具不执行。
 */
const REACT_TAG_ALIASES: Map<string, string[]> = new Map<string, string[]>([
  ['Thought:', ['思考:', '思考：']],
  ['Execution:', ['执行:', '执行：']],
  ['Action:', ['动作:', '动作：']],
  ['Observation:', ['观察:', '观察：']],
  ['Final:', ['最终:', '最终：', '最终答案:', '最终答案：']]
]);

/** 取某英文标签的全部识别形态（含自身与中文别名，含半角/全角冒号）。 */
function tagVariants(prefix: string): string[] {
  const variants: string[] = [prefix];
  const aliases = REACT_TAG_ALIASES.get(prefix);
  if (aliases !== undefined) {
    for (let i = 0; i < aliases.length; i++) {
      variants.push(aliases[i]);
    }
  }
  return variants;
}

type ExecutionMode = 'parallel' | 'serial';

function padDatePart(value: number): string {
  return value < 10 ? '0' + value.toString() : value.toString();
}

function currentLocalDateTime(now: Date = new Date()): string {
  const offsetMinutes = -now.getTimezoneOffset();
  const sign = offsetMinutes >= 0 ? '+' : '-';
  const absoluteOffset = Math.abs(offsetMinutes);
  return now.getFullYear().toString() + '-' + padDatePart(now.getMonth() + 1) + '-' + padDatePart(now.getDate()) +
    'T' + padDatePart(now.getHours()) + ':' + padDatePart(now.getMinutes()) + ':' + padDatePart(now.getSeconds()) +
    sign + padDatePart(Math.floor(absoluteOffset / 60)) + ':' + padDatePart(absoluteOffset % 60);
}

class ToolCall {
  name: string;
  input: string;

  constructor(name: string, input: string) {
    this.name = name;
    this.input = input;
  }
}

class ActionPlan {
  mode: ExecutionMode;
  calls: ToolCall[];

  constructor(mode: ExecutionMode, calls: ToolCall[]) {
    this.mode = mode;
    this.calls = calls;
  }
}

class ProcessedObservation {
  text: string;
  shouldStop: boolean;
  failureKey: string;
  finalText: string;

  constructor(text: string, shouldStop: boolean, failureKey: string, finalText: string) {
    this.text = text;
    this.shouldStop = shouldStop;
    this.failureKey = failureKey;
    this.finalText = finalText;
  }
}

export class ReActAgentRunner {
  private model: LocalModel;
  private tools: ToolRegistry;
  private skillSnapshot: SkillSnapshot | null;
  private skillsInSystemPrompt: boolean;
  private maxSteps: number;
  private uiHandler: UiRenderHandler | null;

  constructor(
    model: LocalModel,
    tools: ToolRegistry,
    maxSteps: number,
    uiHandler?: UiRenderHandler,
    skillSnapshot?: SkillSnapshot,
    skillsInSystemPrompt: boolean = false
  ) {
    this.model = model;
    this.tools = tools;
    this.skillSnapshot = skillSnapshot ?? null;
    this.skillsInSystemPrompt = skillsInSystemPrompt;
    this.maxSteps = maxSteps;
    this.uiHandler = uiHandler ?? null;
  }

  async run(task: string, listener: AgentListener, conversation?: ConversationContext): Promise<void> {
    const scratchpad: string[] = [];

    for (let step = 0; step < this.maxSteps; step++) {
      let response: string;
      try {
        response = await this.model.complete(this.buildPrompt(task, scratchpad, conversation), conversation);
      } catch (error) {
        const message = error instanceof Error ? error.message : `${error}`;
        listener(new AgentEvent(AgentEventKind.ERROR, message));
        return;
      }

      this.emitResponse(response, listener);

      const plan = this.parseActionPlan(response);

      // ReAct 循环纪律：模型在一个 response 里自编多轮 Thought/Action/Observation/Final
      // 是违规（Observation 必须由工具真实返回）。若本 response 含真实 Action，
      // 则无视模型自编的 Final——先执行 Action，不让"幻觉 Final"提前结束循环。
      // 仅当无 Action 时才认 Final 为最终答案。
      if (plan === null) {
        const finalAnswer = this.readLineValue(response, 'Final:');
        if (finalAnswer !== null) {
          listener(new AgentEvent(AgentEventKind.FINAL, finalAnswer));
          return;
        }
        listener(new AgentEvent(AgentEventKind.ERROR, 'Model did not return an Action or Final answer.'));
        return;
      }

      skillLogInfo(`ReActAgentRunner: execution=${plan.mode} toolCount=${plan.calls.length}`);
      const observationsForModel: string[] = [];
      try {
        if (plan.mode === 'parallel' && plan.calls.length > 1) {
          const parallelObservations = await this.executeParallelToolCalls(plan.calls, listener);
          if (parallelObservations === null) {
            return;
          }
          for (const observation of parallelObservations) {
            observationsForModel.push(observation);
          }
        } else {
          for (const call of plan.calls) {
            listener(new AgentEvent(AgentEventKind.ACTION, `${call.name}(${call.input})`));
            const observation = await this.executeToolCall(call, listener);
            if (observation === null) {
              return;
            }
            const processed = this.processObservation(observation, listener);
            observationsForModel.push(processed.text);
            if (processed.shouldStop) {
              this.emitDigestFinal(processed, listener);
              return;
            }
          }
        }
      } catch (error) {
        const message = error instanceof Error ? error.message : `${error}`;
        listener(new AgentEvent(AgentEventKind.ERROR, message));
        return;
      }

      // scratchpad 只保留到首个 Action（截断模型自编的 Observation/Final），
      // 真实 Observation 由工具返回后追加。防止模型自编内容污染下一轮上下文。
      scratchpad.push(this.truncateAtFirstAction(response));
      for (const observation of observationsForModel) {
        scratchpad.push(observation);
      }
    }

    listener(new AgentEvent(AgentEventKind.ERROR, `Stopped after ${this.maxSteps} steps without a final answer.`));
  }

  private async executeParallelToolCalls(
    calls: ToolCall[],
    listener: AgentListener
  ): Promise<string[] | null> {
    for (const call of calls) {
      listener(new AgentEvent(AgentEventKind.ACTION, `${call.name}(${call.input})`));
    }
    const observations = await Promise.all(calls.map(async (call: ToolCall): Promise<string | null> => {
      return await this.executeToolCall(call, listener);
    }));
    const result: string[] = [];
    for (const observation of observations) {
      if (observation === null) {
        return null;
      }
      const processed = this.processObservation(observation, listener);
      result.push(processed.text);
      if (processed.shouldStop) {
        this.emitDigestFinal(processed, listener);
        return null;
      }
    }
    return result;
  }

  private async executeToolCall(call: ToolCall, listener: AgentListener): Promise<string | null> {
    if (call.name === UI_TOOL_NAME) {
      if (this.uiHandler === null) {
        listener(new AgentEvent(AgentEventKind.FINAL, call.input));
        return null;
      }
      return await this.runUiTool(call.input, listener);
    }

    if (call.name === READ_TOOL_NAME) {
      skillLogInfo(`ReActAgentRunner: executing skill read input=${call.input}`);
    }
    let observation: string;
    try {
      observation = await this.tools.run(call.name, call.input);
    } catch (error) {
      const message = error instanceof Error ? error.message : `${error}`;
      throw new Error(`Tool ${call.name} failed: ${message}`);
    }
    if (call.name === READ_TOOL_NAME) {
      this.emitSkillRead(call.input, observation, listener);
    }
    if (this.uiHandler !== null) {
      const payload = this.tools.consumeToolUiPayload(call.name);
      if (payload.length > 0) {
        const lines = parseJsonl(payload);
        if (lines.length > 0) {
          listener(new AgentEvent(AgentEventKind.UI, lines.join('\n')));
          observation += '\n(已将结果渲染到主页 UI 卡片)';
        }
      }
    }
    return observation;
  }

  private processObservation(observation: string, listener: AgentListener): ProcessedObservation {
    const digest = summarizeA2uiObservation(observation);
    const text = digest.isA2ui ? digest.text : `Observation: ${observation}`;
    listener(new AgentEvent(AgentEventKind.OBSERVATION, text));
    return new ProcessedObservation(
      text,
      digest.isA2ui && digest.shouldStop,
      digest.failureKey,
      digest.finalText
    );
  }

  private emitDigestFinal(processed: ProcessedObservation, listener: AgentListener): void {
    if (processed.failureKey.indexOf(':error') >= 0) {
      listener(new AgentEvent(AgentEventKind.FINAL, '工具执行失败，结果已更新到主页。'));
      return;
    }
    if (processed.failureKey.length > 0) {
      listener(new AgentEvent(AgentEventKind.FINAL, '需要用户确认或授权，工具结果已更新到主页。'));
      return;
    }
    listener(new AgentEvent(AgentEventKind.FINAL,
      processed.finalText.length > 0 ? processed.finalText : '工具结果已更新到主页。'));
  }

  private emitSkillRead(input: string, observation: string, listener: AgentListener): void {
    if (this.skillSnapshot === null || !observation.startsWith('# Skill:')) {
      skillLogWarn(`ReActAgentRunner: skill read did not return skill content input=${input}`);
      return;
    }
    const skill = this.skillSnapshot.findByName(input.trim());
    if (skill !== null) {
      skillLogInfo(`ReActAgentRunner: skill selected name=${skill.name}`);
      listener(new AgentEvent(AgentEventKind.SKILL, skill.name));
    } else {
      skillLogWarn(`ReActAgentRunner: skill content returned but snapshot lookup failed input=${input}`);
    }
  }

  private async runUiTool(description: string, listener: AgentListener): Promise<string> {
    if (this.uiHandler === null) {
      return 'UI rendering is not available in this session.';
    }

    const prompt = description.trim().length > 0 ? description : 'Simple information card';
    try {
      const lines = await this.uiHandler(prompt);
      if (lines.length === 0) {
        return 'UI tool returned no protocol data.';
      }
      listener(new AgentEvent(AgentEventKind.UI, lines.join('\n')));
      return `Rendered on-screen UI (${lines.length} protocol lines) for: ${prompt}`;
    } catch (error) {
      const message = error instanceof Error ? error.message : `${error}`;
      return `UI render failed: ${message}`;
    }
  }

  private buildPrompt(task: string, scratchpad: string[], conversation?: ConversationContext): string {
    let prompt = 'You are Loop, a HarmonyOS ReAct agent with tools.\n';
    prompt += 'Current device local datetime: ' + currentLocalDateTime() + '. Resolve relative dates yourself before calling tools.\n';
    prompt += 'Use Thought, Execution, Action, Observation, and Final.\n';
    prompt += 'ReAct discipline (CRITICAL): one response = at most ONE step. Emit Thought, then Execution, then Action, then STOP. Do NOT write Observation or Final in the same response as an Action — Observation comes only from real tool execution in the next step, and Final only when no Action remains. Never fabricate an Observation or assume a tool succeeded without seeing its returned Observation. If you have not received an Observation for an Action, you must wait; do not proceed to a Final.\n';
    prompt += 'For tool use, add Execution: serial or Execution: parallel, then one Action: tool_name[input] line per call.\n';
    prompt += 'Use parallel only when every call is independent. Use serial for ordered calls whose inputs are already known. If a later call needs an earlier result, emit only the first Action and wait for its Observation.\n';
    prompt += 'Never run read, ui, composio, or modelscope in parallel. A missing or unsafe Execution mode falls back to serial.\n';
    prompt += 'When an Action needs parameters, pass a JSON object inside brackets, for example Action: tool.name[{"query":"value"}]; use normal JSON arrays like ["a@example.com"], and do not pass bare keywords.\n';
    if (this.uiHandler !== null) {
      prompt += 'Use the ui tool when the user wants something shown on screen (card, form, dashboard, visual summary).\n';
    } else {
      prompt += 'Do not call ui unless it is listed in Tools. If a tool observation already contains UI or protocol output, return Final with a concise summary.\n';
    }
    prompt += 'When tools expose risk labels, prefer read or draft tools over blocked tools. Use blocked tools only when the user explicitly asks to bypass review or confirmation.\n';
    prompt += 'If a tool observation already contains UI or A2UI protocol output, return Final; the visible result is already on screen.\n';
    prompt += 'Tools that require confirmation, user input, blocked actions, sending, payment, or irreversible writes must stop for user confirmation instead of bypassing review.\n';
    if (this.tools.has('modelscope')) {
      prompt += 'Call modelscope only for an activated ModelScope MCP. First call modelscope with operation=search and the full task; then execute one returned qualifiedName whose risk is read.\n';
      prompt += 'Never invent a ModelScope qualifiedName. If ModelScope blocks an unsafe or unannotated tool, stop and explain that a real confirmation flow is required.\n';
    }
    prompt += 'Calendar write rule: when the requested end state creates, updates, moves, or deletes a Google Calendar event, use the matching calendar.event.* write tool, never calendar.events.search. For an update or move with an incomplete destination time, call calendar.event.update with the existing-event query/timeMin/timeMax selector and omit missing new start or end; the client will keep real matches visible and ask for the missing time without writing. Never ask the user for an Event ID.\n';
    prompt += 'Use other tools or Final for plain text answers.\n\n';

    if (conversation !== undefined && !conversation.isEmpty()) {
      prompt += conversation.formatPriorConversation();
    }

    if (!this.skillsInSystemPrompt) {
      const skillsSection = buildSkillsSection(this.skillSnapshot);
      if (skillsSection.length > 0) {
        prompt += `${skillsSection}\n\n`;
      }
    }

    prompt += 'Tools:\n';
    prompt += this.tools.describeTools();
    prompt += '\nUser task:\n';
    prompt += task;
    prompt += '\n\n';

    for (const item of scratchpad) {
      prompt += `${item}\n`;
    }
    return prompt;
  }

  private emitResponse(response: string, listener: AgentListener): void {
    const thought = this.readLineValue(response, 'Thought:');
    if (thought !== null) {
      listener(new AgentEvent(AgentEventKind.THOUGHT, thought));
    }
    const execution = this.readLineValue(response, 'Execution:');
    if (execution !== null) {
      skillLogInfo(`ReActAgentRunner: model chose execution=${execution.trim().toLowerCase()}`);
    }
  }

  private readLineValue(text: string, prefix: string): string | null {
    const match = this.findTagMatch(text, prefix);
    if (match.start < 0) {
      return null;
    }
    const valueStart = match.start + match.length;
    const tail = text.substring(valueStart);
    const next = this.findNextTagStart(tail, prefix);
    const value = next < 0 ? tail : tail.substring(0, next);
    return value.trim();
  }

  /** 找到标签首次出现的合法位置（兼容英文与中文别名）。仅返回起始下标。 */
  private findTagStart(text: string, prefix: string): number {
    return this.findTagMatch(text, prefix).start;
  }

  /** 找到标签首次出现的合法位置，同时返回匹配到的标签串长度（中英文别名长度不同）。 */
  private findTagMatch(text: string, prefix: string): TagMatch {
    // 同时尝试英文标签与其中文别名（思考/执行/动作/观察/最终），取最早出现的合法边界匹配。
    const variants = tagVariants(prefix);
    let bestStart = -1;
    let bestLength = 0;
    for (let v = 0; v < variants.length; v++) {
      const variant = variants[v];
      let searchFrom = 0;
      while (searchFrom < text.length) {
        const index = text.indexOf(variant, searchFrom);
        if (index < 0) {
          break;
        }
        if (this.isTagBoundary(text, index)) {
          if (bestStart < 0 || index < bestStart) {
            bestStart = index;
            bestLength = variant.length;
          }
          break;
        }
        searchFrom = index + variant.length;
      }
    }
    const match: TagMatch = { start: bestStart, length: bestLength };
    return match;
  }

  private findNextTagStart(text: string, currentPrefix: string): number {
    let result = -1;
    for (let index = 0; index < REACT_TAGS.length; index++) {
      const prefix = REACT_TAGS[index];
      if (prefix === currentPrefix) {
        continue;
      }
      const start = this.findTagStart(text, prefix);
      if (start >= 0 && (result < 0 || start < result)) {
        result = start;
      }
    }
    return result;
  }

  private isTagBoundary(text: string, index: number): boolean {
    if (index === 0) {
      return true;
    }
    const previous = text.charAt(index - 1);
    return previous === '\n' || previous === '\r' || previous === ' ' || previous === '\t';
  }

  private parseActionPlan(response: string): ActionPlan | null {
    const actionTexts = this.extractTaggedLines(response, 'Action:');
    if (actionTexts.length === 0) {
      return null;
    }

    const calls: ToolCall[] = [];
    for (const action of actionTexts) {
      const call = this.parseActionText(action);
      if (call !== null) {
        calls.push(call);
      }
    }
    return calls.length === 0 ? null : new ActionPlan(this.parseExecutionMode(response, calls), calls);
  }

  /**
   * 截断 response 到首个 Action: 行之后（含该行）。
   * 防止模型在一个 response 里自编多轮 Observation/Final 污染 scratchpad——
   * 真实 Observation 由工具返回后单独追加，Final 仅在无 Action 时被认作结束。
   */
  private truncateAtFirstAction(response: string): string {
    const actionVariants = tagVariants('Action:');
    const lines = response.split(/\r?\n/);
    let firstActionIndex = -1;
    for (let index = 0; index < lines.length; index++) {
      const trimmed = lines[index].trim();
      for (let v = 0; v < actionVariants.length; v++) {
        if (trimmed.startsWith(actionVariants[v])) {
          firstActionIndex = index;
          break;
        }
      }
      if (firstActionIndex >= 0) {
        break;
      }
    }
    if (firstActionIndex < 0) {
      return response;
    }
    // 保留首个 Action: 及其后紧跟该 Action 的连续 Action 行（parallel 多 Action 同行场景）。
    // 遇到 Observation:/Final:/Thought:（下一个 ReAct 段）即停止。
    const stopVariants: string[] = [];
    this.pushAll(stopVariants, tagVariants('Observation:'));
    this.pushAll(stopVariants, tagVariants('Final:'));
    this.pushAll(stopVariants, tagVariants('Thought:'));
    const kept: string[] = [];
    for (let index = 0; index <= firstActionIndex; index++) {
      kept.push(lines[index]);
    }
    for (let index = firstActionIndex + 1; index < lines.length; index++) {
      const trimmed = lines[index].trim();
      let stop = false;
      for (let v = 0; v < stopVariants.length; v++) {
        if (trimmed.startsWith(stopVariants[v])) {
          stop = true;
          break;
        }
      }
      if (stop) {
        break;
      }
      kept.push(lines[index]);
    }
    return kept.join('\n');
  }

  private pushAll(target: string[], source: string[]): void {
    for (let i = 0; i < source.length; i++) {
      target.push(source[i]);
    }
  }

  private parseExecutionMode(response: string, calls: ToolCall[]): ExecutionMode {
    const raw = this.readLineValue(response, 'Execution:');
    if (raw === null) {
      return 'serial';
    }
    const mode = raw.trim().toLowerCase();
    if (mode === 'parallel' && calls.length > 1 && !this.hasParallelUnsafeTools(calls)) {
      return 'parallel';
    }
    return 'serial';
  }

  private hasParallelUnsafeTools(calls: ToolCall[]): boolean {
    return calls.some((call: ToolCall): boolean => {
      return call.name === READ_TOOL_NAME ||
        call.name === UI_TOOL_NAME ||
        call.name === 'composio' ||
        call.name === 'modelscope';
    });
  }

  private extractTaggedLines(text: string, prefix: string): string[] {
    // 兼容中文别名（动作：/思考：等）与全角冒号：逐行匹配首个命中的变体，截取其后的内容。
    const variants = tagVariants(prefix);
    const values: string[] = [];
    for (const line of text.split(/\r?\n/)) {
      const trimmed = line.trim();
      let matched: string | null = null;
      for (let v = 0; v < variants.length; v++) {
        const variant = variants[v];
        if (trimmed.startsWith(variant)) {
          matched = variant;
          break;
        }
      }
      if (matched !== null) {
        values.push(trimmed.substring(matched.length).trim());
      }
    }
    return values;
  }

  private parseActionText(action: string): ToolCall | null {
    const bracketCall = this.parseDelimitedAction(action, '[', ']');
    return bracketCall ?? this.parseDelimitedAction(action, '(', ')');
  }

  private parseDelimitedAction(action: string, openToken: string, closeToken: string): ToolCall | null {
    const open = action.indexOf(openToken);
    const close = action.lastIndexOf(closeToken);
    if (open <= 0 || close < open) {
      return null;
    }

    const name = action.substring(0, open).trim();
    const input = action.substring(open + 1, close).trim();
    return new ToolCall(name, input);
  }
}
