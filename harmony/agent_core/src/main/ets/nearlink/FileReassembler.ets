import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import fs from '@ohos.file.fs';
import {
  NEARLINK_FILE_FRAME_MAGIC,
  NEARLINK_FILE_FRAME_HEAD_LEN,
  NEARLINK_FILE_KIND_BEGIN,
  NEARLINK_FILE_KIND_DATA,
  NEARLINK_FILE_KIND_END,
  FileFrameInfo
} from './NearLinkTransport';

const LOG_DOMAIN: number = 0x1306;
const LOG_TAG: string = 'LoopFileReasm';

/**
 * 文件重组器。接收 NearLinkTransport.readData 的 payload（每片是内嵌二进制头的文件帧），
 * 按 magic=0x55 解析头，提取数据写入沙箱 recv_<seq>.bin，收齐后触发 SaveButton。
 *
 * sink 端用 role='sink'（写 loopSink* 键），source 端用 role='source'（写 loopSource* 键）。
 * 协议：writeFileData 每片格式 [magic:1][kind:1][seq:4][index:4][totalChunks:4][dataLen:4][data]，
 * begin 片 data 区前 4 字节额外放 total（文件总字节）。
 */
export class FileReassembler {
  private context: common.UIAbilityContext;
  private role: 'source' | 'sink';
  private currentSeq: number = -1;
  private currentFd: number = -1;
  private currentPath: string = '';
  private currentTotal: number = 0;
  private receivedChunks: number = 0;
  private totalChunks: number = 0;

  constructor(context: common.UIAbilityContext, role: 'source' | 'sink') {
    this.context = context;
    this.role = role;
  }

  /**
   * 处理 readData 收到的 payload。若是文件帧（magic=0x55）解析头并写数据；
   * 否则返回 false 让 transport 回退到文本消息处理。
   * @returns 已消费返回 true；非本协议负载返回 false。
   */
  handleData(data: ArrayBuffer): boolean {
    const info = this.parseFileFrame(data);
    if (info === null) {
      return false;
    }
    switch (info.kind) {
      case NEARLINK_FILE_KIND_BEGIN: {
        // begin 片：开新文件 + 写首片数据。若 totalChunks<=1（单片文件），直接 endFile 触发 SaveButton。
        this.beginFile(info.seq, info.totalSize);
        this.appendFrameData(data, info);
        if (info.totalChunks <= 1) {
          this.endFile(info.seq, info.totalChunks);
        }
        return true;
      }
      case NEARLINK_FILE_KIND_DATA: {
        this.appendFrameData(data, info);
        return true;
      }
      case NEARLINK_FILE_KIND_END: {
        // end 片可能也带末尾数据
        this.appendFrameData(data, info);
        this.endFile(info.seq, info.totalChunks);
        return true;
      }
      default:
        return false;
    }
  }

  /** 解析文件帧头。非文件帧（无 magic）返回 null。 */
  private parseFileFrame(payload: ArrayBuffer): FileFrameInfo | null {
    if (payload.byteLength < NEARLINK_FILE_FRAME_HEAD_LEN) {
      return null;
    }
    const view = new Uint8Array(payload);
    if (view[0] !== NEARLINK_FILE_FRAME_MAGIC) {
      return null;
    }
    const kind = view[1];
    const seq = this.readU32(view, 2);
    const index = this.readU32(view, 6);
    const totalChunks = this.readU32(view, 10);
    const dataLen = this.readU32(view, 14);
    let dataOffset = NEARLINK_FILE_FRAME_HEAD_LEN;
    let totalSize = -1;
    if (kind === NEARLINK_FILE_KIND_BEGIN && payload.byteLength >= NEARLINK_FILE_FRAME_HEAD_LEN + 4) {
      totalSize = this.readU32(view, NEARLINK_FILE_FRAME_HEAD_LEN);
      dataOffset = NEARLINK_FILE_FRAME_HEAD_LEN + 4;
    }
    const info: FileFrameInfo = {
      kind: kind,
      seq: seq,
      index: index,
      totalChunks: totalChunks,
      dataLen: dataLen,
      dataOffset: dataOffset,
      totalSize: totalSize
    };
    return info;
  }

  private readU32(buf: Uint8Array, offset: number): number {
    return ((buf[offset] & 0xFF) << 24)
      | ((buf[offset + 1] & 0xFF) << 16)
      | ((buf[offset + 2] & 0xFF) << 8)
      | (buf[offset + 3] & 0xFF);
  }

  /** 从帧 payload 的 info.dataOffset 处取 info.dataLen 字节写入当前文件。 */
  private appendFrameData(payload: ArrayBuffer, info: FileFrameInfo): void {
    if (this.currentFd < 0) {
      return;
    }
    if (info.dataLen <= 0) {
      return;
    }
    const chunk = payload.slice(info.dataOffset, info.dataOffset + info.dataLen);
    try {
      fs.writeSync(this.currentFd, chunk);
      this.receivedChunks += 1;
    } catch (error) {
      const message = error instanceof Error ? error.message : `${error}`;
      hilog.error(LOG_DOMAIN, LOG_TAG, 'appendFrameData failed: %{public}s', message);
    }
  }

  private beginFile(seq: number, total: number): void {
    this.closeCurrent();
    this.currentSeq = seq;
    this.currentTotal = total > 0 ? total : 0;
    this.receivedChunks = 0;
    this.totalChunks = 0;
    const path = `${this.context.cacheDir}/recv_${seq}.bin`;
    try {
      const file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      this.currentFd = file.fd;
      this.currentPath = path;
      hilog.info(LOG_DOMAIN, LOG_TAG, 'beginFile seq=%{public}d total=%{public}d path=%{public}s',
        seq, total, path);
    } catch (error) {
      const message = error instanceof Error ? error.message : `${error}`;
      hilog.error(LOG_DOMAIN, LOG_TAG, 'beginFile open failed: %{public}s', message);
      this.currentFd = -1;
    }
  }

  private endFile(seq: number, totalChunks: number): void {
    if (seq !== this.currentSeq) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'endFile seq mismatch expect=%{public}d got=%{public}d',
        this.currentSeq, seq);
      return;
    }
    this.totalChunks = totalChunks;
    const path = this.currentPath;
    hilog.info(LOG_DOMAIN, LOG_TAG, 'endFile seq=%{public}d chunks=%{public}d/%{public}d path=%{public}s',
      seq, this.receivedChunks, totalChunks, path);
    this.closeCurrent();
    // 触发 SaveButton 显示链路：写 pendingFile + 自增 fileSeq（Index @Watch 响应）。
    const pendingFileKey = this.role === 'sink' ? 'loopSinkPendingFile' : 'loopSourcePendingFile';
    const fileSeqKey = this.role === 'sink' ? 'loopSinkFileSeq' : 'loopSourceFileSeq';
    AppStorage.setOrCreate<string>(pendingFileKey, path);
    const seq2 = (AppStorage.get<number>(fileSeqKey) ?? 0) + 1;
    AppStorage.setOrCreate<number>(fileSeqKey, seq2);
  }

  private closeCurrent(): void {
    if (this.currentFd >= 0) {
      try {
        fs.closeSync(this.currentFd);
      } catch (_error) {
      }
      this.currentFd = -1;
    }
    this.currentSeq = -1;
    this.currentPath = '';
    this.currentTotal = 0;
    this.receivedChunks = 0;
    this.totalChunks = 0;
  }
}
