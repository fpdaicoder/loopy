import picker from '@ohos.file.picker';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import fs from '@ohos.file.fs';
import { AgentTool } from '../agent/AgentTool';
import { AbilityConnectionClient } from '../distributed/AbilityConnectionClient';

const LOG_DOMAIN = 0x0000;
const LOG_TAG = 'LoopPhotoAlbum';
const DEFAULT_LIMIT = 1;
const MAX_LIMIT = 50;
const MAX_PHOTO_BYTES = 5 * 1024 * 1024; // 5MB 上限，防 sendData 单次过大。

interface PhotoAlbumToolInput {
  operation?: string; // 'pick'
  limit?: number;
}

/**
 * 相册选择工具。仅支持系统选择器路径，无需任何权限：
 *   operation=pick —— PhotoViewPicker 拉起系统相册选择器，用户选照片，读字节经分布式 sendData 发到对端。
 * 不直接读取相册元数据（photoAccessHelper 路径需受限权限 READ_IMAGEVIDEO，普通签名声明会导致安装失败，故不提供）。
 */
export class PhotoAlbumTool implements AgentTool {
  private context: common.UIAbilityContext;
  private connClient: AbilityConnectionClient;

  constructor(context: common.UIAbilityContext, connClient: AbilityConnectionClient) {
    this.context = context;
    this.connClient = connClient;
  }

  name(): string {
    return 'photo_album';
  }

  description(): string {
    return '选择设备相册照片并发送给对端设备（选图后自动经已建立的分布式连接发送字节，无需先调 distributed_device）。' +
      '{"operation":"pick","limit":1} —— 拉起系统相册选择器，用户手动选照片；' +
      '若已与对端建立分布式连接（连接状态非 disconnected），自动读取照片字节经 sendData 发送到对端（对端存沙箱+提供保存按钮）。无需权限。' +
      '收到「选照片/发照片/获取照片」类请求时直接调本工具 pick，不要先调 distributed_device search/discover。';
  }

  async run(input: string): Promise<string> {
    let parsed: PhotoAlbumToolInput;
    try {
      parsed = JSON.parse(input) as PhotoAlbumToolInput;
    } catch (_error) {
      return 'photo_album 参数错误：输入必须是 JSON。';
    }

    const operation = parsed.operation ?? '';
    const limit = this.clampLimit(parsed.limit);
    if (operation === 'pick') {
      return await this.pickPhotos(limit);
    }
    return 'photo_album 参数错误：operation 必须是 pick。';
  }

  private clampLimit(raw: number | undefined): number {
    if (raw === undefined || raw === null || raw <= 0) {
      return DEFAULT_LIMIT;
    }
    return raw > MAX_LIMIT ? MAX_LIMIT : raw;
  }

  private async pickPhotos(limit: number): Promise<string> {
    try {
      // PhotoViewPicker/PhotoSelectOptions 在本 SDK 版本已 deprecated，且
      // PhotoViewMIMETypes 的成员名 / PhotoSelectResult 的 URI 字段名本机 SDK .d.ts
      // 无法静态确认（编译器否认 IMAGE 成员与 uris 字段）。绕开不确定字段：
      //  - 不设 MIMEType（字段可选，默认含图片+视频），仅限 maxSelectNumber；
      //  - 不按字段名读结果，而是 JSON.stringify(selectResult) 后正则提取 URI 串。
      const options = new picker.PhotoSelectOptions();
      options.maxSelectNumber = limit;
      const photoPicker = new picker.PhotoViewPicker();
      const selectResult = await photoPicker.select(options);
      const uris = this.extractUris(JSON.stringify(selectResult));
      if (uris.length === 0) {
        return '用户未选择照片。';
      }
      hilog.info(LOG_DOMAIN, LOG_TAG, 'pick got %{public}d uris', uris.length);

      // 发送判定：source 端看 connClient adopted 状态（connected）；sink 端看
      // AppStorage('loopSinkSessionId')（onCollaborate 建的会话，API 确认双向支持 sendData）。
      const sinkSessionId = AppStorage.get<number>('loopSinkSessionId') ?? -1;
      const status = this.connClient.statusText();
      const connected = sinkSessionId >= 0 || status.startsWith('connected');
      const sent: string[] = [];
      const skipped: string[] = [];
      for (let index = 0; index < uris.length; index++) {
        const uri = uris[index];
        if (connected) {
          const sendResult = await this.sendPhotoUri(uri, sinkSessionId);
          sent.push(`- ${uri} → ${sendResult}`);
        } else {
          skipped.push(`- ${uri}（未连接对端，未发送）`);
        }
      }
      if (connected) {
        return `已选 ${uris.length} 张并尝试发送：\n${sent.join('\n')}` +
          (skipped.length > 0 ? `\n${skipped.join('\n')}` : '');
      }
      return `已选择 ${uris.length} 张照片（临时 URI，仅本会话可读；未连接对端，未发送）：\n${skipped.join('\n')}`;
    } catch (error) {
      const message = error instanceof Error ? error.message : `${error}`;
      hilog.error(LOG_DOMAIN, LOG_TAG, 'pick failed: %{public}s', message);
      return `选择照片失败：${message}`;
    }
  }

  /**
   * 读 URI 字节发送。sink 端（sinkSessionId>=0）用 sendDataOnSession 直接发；
   * source 端用 connClient.sendData（adopted）。API 确认会话双向支持 sendData。
   */
  private async sendPhotoUri(uri: string, sinkSessionId: number): Promise<string> {
    let file: fs.File | undefined;
    try {
      // 只读打开媒体库 URI（file://media/...）。用 READ_ONLY 而非 READ_WRITE：
      // READ_WRITE 申请写权限，系统对媒体库只读 URI 拒绝 → Operation not permitted。
      // （OpenMode 三态为 READ_ONLY / WRITE_ONLY / READ_WRITE，无单独 READ。）
      file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      // 预分配上限缓冲，readSync 返回实际读取字节数，再 slice 出精确大小发送。
      const buffer = new ArrayBuffer(MAX_PHOTO_BYTES);
      const bytesRead = fs.readSync(file.fd, buffer);
      if (bytesRead <= 0) {
        return '文件为空';
      }
      const data = buffer.slice(0, bytesRead);
      hilog.info(LOG_DOMAIN, LOG_TAG, 'sendPhotoUri uri=%{public}s bytes=%{public}d', uri, bytesRead);
      // sink 端用已知 sessionId 直接发（sendDataOnSession 绕 adopted 状态检查）；
      // source 端走 adopted 的 sendData。API 确认会话双向支持 sendData。
      if (sinkSessionId >= 0) {
        return await this.connClient.sendDataOnSession(sinkSessionId, data);
      }
      return await this.connClient.sendData(data);
    } catch (error) {
      const message = error instanceof Error ? error.message : `${error}`;
      hilog.error(LOG_DOMAIN, LOG_TAG, 'sendPhotoUri failed uri=%{public}s err=%{public}s', uri, message);
      return `发送失败：${message}`;
    } finally {
      if (file !== undefined) {
        try {
          fs.closeSync(file);
        } catch (_error) {
        }
      }
    }
  }

  /** 从 select 结果的 JSON 序列化串里正则提取 URI（datasync://、file://、storage:// 等），避免依赖不确定的字段名。 */
  private extractUris(json: string): string[] {
    const result: string[] = [];
    const pattern = /(?:datasync|file|storage|photos|media):\/\/[^\s"',]+/g;
    let match: RegExpExecArray | null;
    while ((match = pattern.exec(json)) !== null) {
      if (match[0].length > 0) {
        result.push(match[0]);
      }
    }
    return result;
  }
}
