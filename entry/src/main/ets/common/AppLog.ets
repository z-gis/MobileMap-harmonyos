// AppLog.ets —— 统一日志门面（对应 Android com.zys.mobilemap.util.AppLog）。
//
// Android 侧日志同时落 hilog 与外部「/调查宝/log」文本文件（便于外业现场取回反馈）；
// 鸿蒙侧外部目录不可随意写，日志文件落沙箱 filesDir/调查宝/log，路径由设置页「存储」分组提示。
// domain 固定，tag 用调用方类名，格式与 hilog 惯例一致（%{public}s）。
//
// 落盘策略：hilog 实时输出；文件侧 D/I 攒批异步落盘，缓冲满或 W/E 级立即触发刷盘——
// 避免高频路径（要素拾取耗时日志等）每条日志一次同步 open/write/close 阻塞主线程。
// 日志仅在主线程产生（全项目无 TaskPool/Worker），缓冲无需加锁。
import { hilog } from '@kit.PerformanceAnalysisKit';
import fs from '@ohos.file.fs';

const DOMAIN: number = 0x8811;
const TAG: string = 'MobileMap';
/** 缓冲行数上限：达到即触发一次异步刷盘 */
const MAX_BUFFERED_LINES: number = 64;

export class AppLog {
  /** 日志文件绝对路径（沙箱 filesDir/调查宝/log/app.log）；由 AppDirs 初始化时赋值，未就绪时仅 hilog */
  static logFile: string = '';
  /** 待落盘行缓冲（join 后整批一次异步写入） */
  private static buffer: string[] = [];
  /** 异步刷盘进行中标记：串行化文件写入，避免两批交错写坏文件 */
  private static flushing: boolean = false;

  static d(msg: string, detail: string = ''): void {
    hilog.debug(DOMAIN, TAG, '%{public}s %{public}s', msg, detail);
    AppLog.enqueue('D', msg, detail);
  }

  static i(msg: string, detail: string = ''): void {
    hilog.info(DOMAIN, TAG, '%{public}s %{public}s', msg, detail);
    AppLog.enqueue('I', msg, detail);
  }

  static w(msg: string, detail: string = ''): void {
    hilog.warn(DOMAIN, TAG, '%{public}s %{public}s', msg, detail);
    AppLog.enqueue('W', msg, detail);
  }

  /** 错误日志：error 携带 catch 到的异常，统一 toString 兜底（ArkTS catch 形参不可标注类型） */
  static e(msg: string, error?: Object): void {
    const detail: string = error === undefined ? '' : `${error}`;
    hilog.error(DOMAIN, TAG, '%{public}s %{public}s', msg, detail);
    AppLog.enqueue('E', msg, detail);
  }

  /** 入缓冲；警告/错误立即刷盘（外业排障需及时），普通日志攒批由缓冲上限触发 */
  private static enqueue(level: string, msg: string, detail: string): void {
    if (AppLog.logFile.length === 0) {
      return;
    }
    AppLog.buffer.push(`${new Date().toISOString()} ${level}/${msg} ${detail}\n`);
    if (level === 'W' || level === 'E' || AppLog.buffer.length >= MAX_BUFFERED_LINES) {
      AppLog.flush();
    }
  }

  /**
   * 异步刷盘：取出缓冲整批追加写文件；任何 IO 异常静默丢弃本批（日志不可影响主流程）。
   * 退后台/销毁前由 Ability 生命周期调用一次，减小缓冲日志随进程回收丢失的窗口。
   */
  static flush(): void {
    if (AppLog.flushing || AppLog.buffer.length === 0 || AppLog.logFile.length === 0) {
      return;
    }
    AppLog.flushLocked();
  }

  private static async flushLocked(): Promise<void> {
    AppLog.flushing = true;
    const chunk: string = AppLog.buffer.join('');
    AppLog.buffer = [];
    let file: fs.File | null = null;
    try {
      file = await fs.open(AppLog.logFile,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.APPEND);
      await fs.write(file.fd, chunk);
    } catch (e) {
      // 打开/写入失败静默丢弃本批（与原逐条写失败静默口径一致）
    } finally {
      if (file !== null) {
        try {
          fs.closeSync(file);
        } catch (e) {
          // 关闭失败无需处理
        }
      }
      AppLog.flushing = false;
      // 刷盘期间新入缓冲的行继续排空
      if (AppLog.buffer.length > 0) {
        AppLog.flushLocked();
      }
    }
  }
}
