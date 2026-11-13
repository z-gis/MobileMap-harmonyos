// DeskLog.ets —— 桌面端日志门面（hilog）。
// 与手机端 AppLog 分离：本模块只写 hilog，不落沙箱日志文件（内业端暂无离线取证诉求）。
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x9527;
const SLOT: string = 'DcbPc';

export class DeskLog {
  static i(msg: string): void {
    hilog.info(DOMAIN, SLOT, '%{public}s', msg);
  }

  static w(msg: string): void {
    hilog.warn(DOMAIN, SLOT, '%{public}s', msg);
  }

  static e(msg: string): void {
    hilog.error(DOMAIN, SLOT, '%{public}s', msg);
  }
}
