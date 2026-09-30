// TimeText.ets —— 时间显示格式化（对应 Android 布局里的 SimpleDateFormat 常量与扩展函数）。
//
// 记录列表（轨迹/照片/样地/更新日志）都要显示时间，Android 各处 new SimpleDateFormat(...)，
// 格式易漂移；此处集中三种粒度，页面只选粒度不拼字符串。
// 一律补零到两位，便于列表按文本对齐（等宽字体下天然成列）。

import { Ui } from './Ui';

/** 时间显示粒度与换算 */
export class TimeText {
  /** yyyy-MM-dd HH:mm（列表副标题，分钟粒度足够定位到外业时段） */
  static dateTime(ts: number): string {
    if (ts <= 0) {
      return '-';
    }
    const d: Date = new Date(ts);
    return `${TimeText.date(ts)} ${TimeText.clock(ts)}`;
  }

  /** yyyy-MM-dd HH:mm:ss（秒粒度：定位详情等需精确到秒的场合，dateTime 只到分钟） */
  static dateTimeSec(ts: number): string {
    if (ts <= 0) {
      return '-';
    }
    const d: Date = new Date(ts);
    return `${TimeText.dateTime(ts)}:${Ui.pad(d.getSeconds())}`;
  }

  /** yyyy-MM-dd */
  static date(ts: number): string {
    if (ts <= 0) {
      return '-';
    }
    const d: Date = new Date(ts);
    return `${d.getFullYear()}-${Ui.pad(d.getMonth() + 1)}-${Ui.pad(d.getDate())}`;
  }

  /** HH:mm */
  static clock(ts: number): string {
    if (ts <= 0) {
      return '-';
    }
    const d: Date = new Date(ts);
    return `${Ui.pad(d.getHours())}:${Ui.pad(d.getMinutes())}`;
  }

  /**
   * 相对时长文本（轨迹用时、录音长度）：不足 1 小时显示 mm:ss，否则 h:mm:ss。
   */
  static duration(ms: number): string {
    if (!Number.isFinite(ms) || ms <= 0) {
      return '0:00';
    }
    const total: number = Math.floor(ms / 1000);
    const h: number = Math.floor(total / 3600);
    const m: number = Math.floor((total % 3600) / 60);
    const s: number = total % 60;
    if (h <= 0) {
      return `${m}:${Ui.pad(s)}`;
    }
    return `${h}:${Ui.pad(m)}:${Ui.pad(s)}`;
  }
}
