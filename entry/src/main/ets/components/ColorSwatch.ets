// ColorSwatch.ets —— 色块与「标签 + 色块」行（点一下弹选色器）。
//
// 用 @Component + @Prop 而非 @Builder：色块的颜色会被选色器改，@Builder 的按值入参不随父状态刷新
// （见 SwitchRow 同一取舍）。dim 用于「不填充」时把色块压淡，等价 Android 给 ImageView 设 alpha 0.3。

import { Theme } from '../common/Theme';

@Component
export struct ColorSwatch {
  /** '#AARRGGBB'，直接喂 ArkUI 的颜色串 */
  @Prop color: string = '#FF000000';
  /** 半透明态：功能开关关闭时的视觉抑制（同为 @Prop：开关可被程序回显） */
  @Prop dim: boolean = false;
  /** 无障碍标签（同一屏多个色块时区分） */
  label: string = '';
  onTap: () => void = (): void => {};

  build() {
    Column()
      .width(44)
      .height(26)
      .backgroundColor(this.color)
      .opacity(this.dim ? 0.3 : 1)
      .borderRadius(4)
      .borderWidth(1)
      .borderColor(Theme.DIVIDER)
      .accessibilityText(this.label)
      .onClick((): void => {
        this.onTap();
      })
  }
}

/**
 * 「标签 + 色块」整行：样式页的四行同构，收敛到一处，与 ColorSwatch 同文共存。
 * color / dim 均走 @Prop，选色回填与开关回显都能跟随父状态。
 */
@Component
export struct ColorRow {
  label: string = '';
  @Prop color: string = '#FF000000';
  @Prop dim: boolean = false;
  onTap: () => void = (): void => {};

  build() {
    Row() {
      Text(this.label)
        .fontSize(Theme.FONT)
        .fontColor(Theme.TEXT)
      Blank()
      ColorSwatch({
        color: this.color,
        dim: this.dim,
        label: this.label,
        onTap: this.onTap,
      })
    }
    .width('100%')
    .height(38)
  }
}
