// StepField.ets —— 「标签 − 数值 +」步进行（线宽、字号等整数小范围取值）。
//
// 对应 Android 布局里的 tv_width_value + btn_minus/btn_plus 三件套：整数、限幅、长按无意义，
// 故不做成长按连发的自绘控件，两个按钮足够。取值在 [min,max] 内钳位（Android coerceIn 同口径）。

import { Theme } from '../common/Theme';

@Component
export struct StepField {
  label: string = '';
  /** 数值后缀（如「磅」），空表示纯数字 */
  suffix: string = '';
  labelWidth: number = 56;
  min: number = 0;
  max: number = 100;
  @Prop value: number = 0;
  onValueChange: (v: number) => void = (): void => {};

  private step(delta: number): void {
    const next: number = Math.max(this.min, Math.min(this.max, this.value + delta));
    if (next !== this.value) {
      this.onValueChange(next);
    }
  }

  build() {
    Row() {
      Text(this.label)
        .fontSize(Theme.FONT_SUB)
        .fontColor(Theme.TEXT_SUB)
        .width(this.labelWidth)
      Blank()
      Text('−')
        .fontSize(18)
        .fontColor(Theme.PRIMARY_DARK)
        .width(32)
        .height(32)
        .textAlign(TextAlign.Center)
        .backgroundColor(Theme.SUBTLE)
        .borderRadius(6)
        .onClick((): void => {
          this.step(-1);
        })
      Text(this.suffix.length > 0 ? `${this.value}${this.suffix}` : `${this.value}`)
        .fontSize(Theme.FONT)
        .fontColor(Theme.TEXT)
        .textAlign(TextAlign.Center)
        .width(56)
      Text('＋')
        .fontSize(18)
        .fontColor(Theme.PRIMARY_DARK)
        .width(32)
        .height(32)
        .textAlign(TextAlign.Center)
        .backgroundColor(Theme.SUBTLE)
        .borderRadius(6)
        .onClick((): void => {
          this.step(1);
        })
    }
    .width('100%')
    .height(36)
  }
}
