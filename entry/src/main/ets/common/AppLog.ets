// AppLog.ets —— 统一日志门面（对应 Android com.zys.mobilemap.util.AppLog）。
//
// Android 侧日志同时落 hilog 与外部「/调查宝/log」文本文件（便于外业现场取回反馈）；
// 鸿蒙侧外部目录不可随意写，日志文件落沙箱 filesDir/调查宝/log，由「关于」页提供路径提示。
// domain 固定，tag 用调用方类名，格式与 hilog 惯例一致（%{public}s）。
import { hilog } from '@kit.PerformanceAnalysisKit';
import fs from '@ohos.file.fs';

const DOMAIN: number = 0x8811;
const TAG: string = 'MobileMap';

export class AppLog {
  /** 日志文件绝对路径（沙箱 filesDir/调查宝/log/app.log）；由 AppDirs 初始化时赋值，未就绪时仅 hilog */
  static logFile: string = '';

  static d(msg: string, detail: string = ''): void {
    hilog.debug(DOMAIN, TAG, '%{public}s %{public}s', msg, detail);
    AppLog.writeToFile('D', msg, detail);
  }

  static i(msg: string, detail: string = ''): void {
    hilog.info(DOMAIN, TAG, '%{public}s %{public}s', msg, detail);
    AppLog.writeToFile('I', msg, detail);
  }

  static w(msg: string, detail: string = ''): void {
    hilog.warn(DOMAIN, TAG, '%{public}s %{public}s', msg, detail);
    AppLog.writeToFile('W', msg, detail);
  }

  /** 错误日志：error 携带 catch 到的异常，统一 toString 兜底（ArkTS catch 形参不可标注类型） */
  static e(msg: string, error?: Object): void {
    const detail: string = error === undefined ? '' : `${error}`;
    hilog.error(DOMAIN, TAG, '%{public}s %{public}s', msg, detail);
    AppLog.writeToFile('E', msg, detail);
  }

  /** 追加一行到日志文件；任何 IO 异常静默忽略（日志不可影响主流程） */
  private static writeToFile(level: string, msg: string, detail: string): void {
    const path = AppLog.logFile;
    if (path.length === 0) {
      return;
    }
    try {
      const file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.APPEND);
      fs.writeSync(file.fd, `${new Date().toISOString()} ${level}/${msg} ${detail}\n`);
      fs.closeSync(file);
    } catch (e) {
      // 日志落盘失败不上抛
    }
  }
}
