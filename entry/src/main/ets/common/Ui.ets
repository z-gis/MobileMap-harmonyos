// Ui.ets —— 轻量界面反馈工具（对应 Android 侧 Toast / AlertDialog 的分散调用）。
//
// ArkTS 无「任意上下文弹窗」的命令式 API，短提示统一走 promptAction.showToast；
// 需要用户决策的场景提供 confirm() 包装 promptAction.showDialog，返回是否点击了肯定项。
// 控制器层（测量/轨迹/定位）不持有组件实例，故经此文件全局调用，避免把 UIAbilityContext 层层下传。

import { promptAction } from '@kit.ArkUI';
import { AppLog } from './AppLog';

/** 提示时长：短（≈1.5s） */
const DURATION_SHORT: number = 1500;
/** 提示时长：长（≈3.5s） */
const DURATION_LONG: number = 3500;

export class Ui {
  /** 轻提示（等价 Toast.LENGTH_SHORT） */
  static toast(message: string): void {
    Ui.toastImpl(message, DURATION_SHORT);
  }

  /** 长提示（等价 Toast.LENGTH_LONG） */
  static toastLong(message: string): void {
    Ui.toastImpl(message, DURATION_LONG);
  }

  private static toastImpl(message: string, duration: number): void {
    if (message.length === 0) {
      return;
    }
    try {
      promptAction.showToast({ message: message, duration: duration });
    } catch (e) {
      // 页面已销毁等场景下 toast 会抛异常；提示丢失不应中断业务流程
      AppLog.w(`toast 失败: ${message}`, `${e}`);
    }
  }

  /**
   * 确认对话框：返回是否点击肯定项。
   * 取消按钮固定为「取消」，肯定按钮文案由调用方给（如「删除」「确定」）。
   */
  static async confirm(title: string, message: string,
    agreeText: string = '确定'): Promise<boolean> {
    try {
      const res: promptAction.ShowDialogSuccessResponse = await promptAction.showDialog({
        title: title,
        message: message,
        buttons: [
          { text: '取消', color: '#FF888888' },
          { text: agreeText, color: '#FFE64545' },
        ],
      });
      return res.index === 1;
    } catch (e) {
      AppLog.w(`confirm 对话框失败: ${title}`, `${e}`);
      return false;
    }
  }

  /**
   * 信息对话框（等价 Android AlertDialog.setMessage + 单个「知道了」按钮）：
   * 图层信息、查询结果这类「只读展示」用它与 confirm 区分，调用方不关心返回值。
   */
  static async alert(title: string, message: string): Promise<void> {
    try {
      await promptAction.showDialog({
        title: title,
        message: message,
        buttons: [{ text: '知道了', color: '#FF1A73C8' }],
      });
    } catch (e) {
      AppLog.w(`alert 对话框失败: ${title}`, `${e}`);
    }
  }

  /**
   * 列表选择对话框（等价 Android setItems）：返回被选项下标，取消返回 -1。
   * 最多 6 项（showDialog 按钮数限制），超出由调用方改为独立页面。
   */
  static async items(title: string, options: string[]): Promise<number> {
    const buttons: promptAction.Button[] = [];
    const limit: number = Math.min(options.length, 6);
    for (let i = 0; i < limit; i++) {
      buttons.push({ text: options[i], color: '#FF333333' });
    }
    if (buttons.length === 0) {
      return -1;
    }
    try {
      const res: promptAction.ShowDialogSuccessResponse = await promptAction.showDialog({
        title: title,
        message: '',
        buttons: buttons,
      });
      return res.index;
    } catch (e) {
      AppLog.w(`items 对话框失败: ${title}`, `${e}`);
      return -1;
    }
  }

  /** 时间戳命名：`轨迹 yyyy-MM-dd HH:mm:ss` 形态（Android String.format %tY..%tS 等价） */
  static stampName(prefix: string, ts: number): string {
    const d: Date = new Date(ts);
    return `${prefix} ${d.getFullYear()}-${Ui.pad(d.getMonth() + 1)}-${Ui.pad(d.getDate())} `
      + `${Ui.pad(d.getHours())}:${Ui.pad(d.getMinutes())}:${Ui.pad(d.getSeconds())}`;
  }

  static pad(n: number): string {
    return n < 10 ? `0${n}` : `${n}`;
  }

  /** 数值显示：去尾零（0.5 → '0.5'、3.0 → '3'），供线宽/透明度等回显 */
  static num(value: number, digits: number = 2): string {
    let text: string = value.toFixed(digits);
    if (text.indexOf('.') >= 0) {
      text = text.replace(/0+$/, '').replace(/\.$/, '');
    }
    return text.length === 0 ? '0' : text;
  }

  /**
   * 定长小数（等价 Android String.format("%.Nf")）：不剥尾零。
   * 坐标显示需保持位数恒定以便人工比对，故不用 num()。
   */
  static fixed(value: number, digits: number = 6): string {
    if (!Number.isFinite(value)) {
      return '-';
    }
    return value.toFixed(digits);
  }
}
