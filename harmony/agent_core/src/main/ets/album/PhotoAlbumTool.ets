import picker from '@ohos.file.picker';
import { hilog } from '@kit.PerformanceAnalysisKit';
import fs from '@ohos.file.fs';
import { AgentTool } from '../agent/AgentTool';
import { NearLinkTransport } from '../nearlink/NearLinkTransport';

const LOG_DOMAIN = 0x0000;
const LOG_TAG = 'LoopPhotoAlbum';
const DEFAULT_LIMIT = 1;
const MAX_LIMIT = 50;
const READ_CHUNK_BYTES = 64 * 1024; // 读图循环缓冲，避免预分配大块。

interface PhotoAlbumToolInput {
  operation?: string; // 'pick'
  limit?: number;
}


/**
 * 相册选择工具。仅支持系统选择器路径，无需任何权限：
 *   operation=pick —— PhotoViewPicker 拉起系统相册选择器，用户选照片，读字节经星闪连接发到对端。
 * 不直接读取相册元数据（photoAccessHelper 路径需受限权限 READ_IMAGEVIDEO，普通签名声明会导致安装失败，故不提供）。
 *
 * 传输通道：星闪 NearLinkTransport（dataTransfer）—— 分片发送，规避 softbus 4MiB 单片限制，大文件可靠。
 * softbus 已屏蔽，未建立星闪连接时直接提示先 nearlink_device connect。
 */
export class PhotoAlbumTool implements AgentTool {
  private nearLinkTransport: NearLinkTransport | null;

  constructor(nearLinkTransport: NearLinkTransport | null = null) {
    this.nearLinkTransport = nearLinkTransport;
  }

  name(): string {
    return 'photo_album';
  }

  description(): string {
    return '从**本机**相册选照片并发送给对端设备（本机是发送方，不是接收方）。' +
      '{"operation":"pick","limit":1} —— 拉起系统相册选择器，用户手动选照片，选完经星闪连接发送给对端。' +
      '经星闪 dataTransfer 分片传输（大文件可靠，无 4MiB 限制）。' +
      '需先 nearlink_device connect 建立星闪连接；未连接时 pick 仅选图不发。' +
      '注意：若用户要「从对端获取照片」（即从附近手机拉照片到本机），应先 nearlink_device connect 连接对端，' +
      '再让对端执行 photo_album pick 发过来，本机用 nearlink_device received 接收——本工具 pick 是本机发送方向，不是接收方向。';
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

      const connected = this.isAnyTransportReady();
      const sent: string[] = [];
      const skipped: string[] = [];
      for (let index = 0; index < uris.length; index++) {
        const uri = uris[index];
        if (connected) {
          const sendResult = await this.sendPhotoUri(uri);
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

  /** 星闪就绪即视为可发送。softbus 已屏蔽。 */
  private isAnyTransportReady(): boolean {
    return this.nearLinkTransport !== null && this.nearLinkTransport.isReady();
  }

  /**
   * 读 URI 字节经星闪分片发送。softbus 已屏蔽，未连接星闪时直接报错提示先 connect。
   */
  private async sendPhotoUri(uri: string): Promise<string> {
    if (this.nearLinkTransport === null || !this.nearLinkTransport.isReady()) {
      return '未建立星闪连接，请先 nearlink_device execute action=connect 建链。';
    }
    return await this.sendViaNearLink(uri);
  }

  /**
   * 星闪传输：读全图字节进单缓冲 → 一次 transport.writeFileData 调用。
   * writeFileData 内部按 getChunkSize() 切片，每片前内嵌二进制头（magic/kind/seq/
   * index/totalChunks/dataLen），单片一次 writeData——不再分独立 sendText 控制帧。
   * 收端 FileReassembler 按 magic=0x55 解析头，提取数据写入沙箱，收齐触发 SaveButton。
   * seq 全局自增保证文件名唯一（收端存 recv_<seq>.bin）。
   */
  private async sendViaNearLink(uri: string): Promise<string> {
    const transport = this.nearLinkTransport!;
    let file: fs.File | undefined;
    try {
      file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      const totalSize = await this.readFileSize(file);
      if (totalSize <= 0) {
        return '文件为空';
      }
      hilog.info(LOG_DOMAIN, LOG_TAG, 'total size %{public}d', totalSize);
      const seq = (AppStorage.get<number>('loopSentFileSeq') ?? 0) + 1;
      AppStorage.setOrCreate<number>('loopSentFileSeq', seq);

      // 整文件读进单缓冲，交给 transport.writeFileData 切片+内嵌头发送
      const buffer = new ArrayBuffer(totalSize);
      let sent = 0;
      while (sent < totalSize) {
        const bytesRead = fs.readSync(file.fd, buffer, { offset: sent, length: totalSize - sent });
        if (bytesRead <= 0) {
          break;
        }
        sent += bytesRead;
      }
      const payload = sent < totalSize ? buffer.slice(0, sent) : buffer;
      const sentBytes = await transport.writeFileData(payload, seq);

      hilog.info(LOG_DOMAIN, LOG_TAG, 'nearLink sent uri=%{public}s bytes=%{public}d (whole-file via writeFileData)',
        uri, sentBytes);
      return `已发送 ${sentBytes} 字节（星闪分片，内嵌头）`;
    } catch (error) {
      const message = error instanceof Error ? error.message : `${error}`;
      hilog.error(LOG_DOMAIN, LOG_TAG, 'sendViaNearLink failed uri=%{public}s err=%{public}s', uri, message);
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

  /** 读文件总大小：fs.statSync(fd) 不可靠时循环 readSync 探测。优先 statSync。 */
  private async readFileSize(file: fs.File): Promise<number> {
    try {
      const stat = fs.statSync(file.fd);
      if (stat.size > 0) {
        return stat.size;
      }
    } catch (_error) {
      // stat 失败时回退循环探测
    }
    // 循环读至 EOF 累计字节数（不预知大小时安全）。
    const probe = new ArrayBuffer(READ_CHUNK_BYTES);
    let total = 0;
    let read = 0;
    do {
      read = fs.readSync(file.fd, probe, { offset: total });
      total += read > 0 ? read : 0;
    } while (read > 0);
    // 复位 fd 偏移到 0 供后续发送读
    try {
      fs.readSync(file.fd, new ArrayBuffer(0), { offset: 0 });
    } catch (_error) {
    }
    return total;
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
