// ColorPickerDialog.ets —— 颜色选取对话框（对应 Android ui.dialog.ColorPickerDialog + control.ColorPickerView）。
//
// Android 用自绘 View 承载「饱和度明度二维色板 + 色相色谱条」；鸿蒙侧无等价自绘手势面，
// 改为「色相滑条 + 透明度滑条 + 预设色块」的组合，表达能力略窄但覆盖外业实际用法
// （选一个与底图区分得开的填色/线色），且保留了完全一致的 HEX 输入通道：
// 手输 8 位 AARRGGBB 或 6 位 RGB（补不透明）可直接精确给色，这是唯一需要「准确值」的入口。
// 旧色固定为打开时的初值，新色随任一输入源变化；确定时优先取 HEX 输入值（与 Android 同规则）。
//
// 结构体名不跟随文件名：ArkTS 禁止自定义组件与内置组件同名，故取名 AppColorPicker。

import { ColorHex, RgbColor } from '../common/ColorHex';
import { Theme } from '../common/Theme';

/** 预设色块：取自 Android 图层样式常用色 + 测量/轨迹/调查主题色，保证常用值一步可达 */
const PRESET_COLORS: number[] = [
  0xFFFF5733, 0xFFFFC42F, 0xFF2ECC71, 0xFF1ABC9C, 0xFF3DA5FF, 0xFF8E44AD,
  0xFFE74C3C, 0xFFF39C12, 0xFF27AE60, 0xFF2980B9, 0xFF9B59B6, 0xFF7F8C8D,
  0xFFFF00FF, 0xFF00FFFF, 0xFFFFFF00, 0xFFFF8899, 0xFFFFFFFF, 0xFF000000,
];
/** HEX 长度：含 alpha 的 AARRGGBB 与仅 RGB（按不透明处理） */
const HEX_LEN_ARGB: number = 8;
const HEX_LEN_RGB: number = 6;

@CustomDialog
export struct AppColorPicker {
  controller: CustomDialogController;
  /** 打开时的初值（无符号 ARGB） */
  initialColor: number = 0xFF4A90D9;
  onConfirmColor: (argb: number) => void = (): void => {};

  @State hue: number = 200;
  @State alpha: number = 255;
  @State hexText: string = '';
  /** 色相/透明度滑条与 HEX 输入互填时的护栏，避免 onChange 回环 */
  private updatingFromSlider: boolean = false;

  aboutToAppear(): void {
    const rgb: RgbColor = ColorHex.toRgb(this.initialColor);
    const hsv: number[] = AppColorPicker.toHsv(rgb);
    this.hue = hsv[0];
    this.alpha = ColorHex.alpha(this.initialColor);
    this.hexText = ColorHex.toHex(this.initialColor);
  }

  /** 当前色相 + 饱和度/明度满值 + 透明度 → 无符号 ARGB（滑条合成结果显示用） */
  private currentArgb(): number {
    const rgb: RgbColor = AppColorPicker.toRgbFromHsv(this.hue, 1.0, 1.0);
    return ColorHex.fromRgb(rgb, this.alpha);
  }

  private colorText(argb: number): string {
    return `#${ColorHex.toHex(argb)}`;
  }

  /** 色相滑条的拖块取当前色相纯色（不透明），给出「正在拖到哪」的直接反馈 */
  private blockColor(): string {
    return this.colorText(ColorHex.fromRgb(AppColorPicker.toRgbFromHsv(this.hue, 1.0, 1.0), 255));
  }

  /** 色相/透明度变化 → 重写 HEX 文本 */
  private syncHex(): void {
    this.updatingFromSlider = true;
    this.hexText = ColorHex.toHex(this.currentArgb());
    this.updatingFromSlider = false;
  }

  private applyPreset(argb: number): void {
    const rgb: RgbColor = ColorHex.toRgb(argb);
    const hsv: number[] = AppColorPicker.toHsv(rgb);
    // 预设色可能饱和度不足（灰/白），此时保留其色相 0 但把滑条归到当前值，避免无意义跳变
    this.hue = hsv[1] > 0.01 ? hsv[0] : this.hue;
    this.alpha = ColorHex.alpha(argb);
    this.syncHex();
  }

  private confirm(): void {
    const parsed: number | undefined = AppColorPicker.parseHex(this.hexText);
    this.onConfirmColor(parsed === undefined ? this.currentArgb() : parsed);
    this.controller.close();
  }

  /** 手输解析：6 位补不透明、8 位原样，其余视为非法（返回 undefined 由调用方回退滑条色） */
  private static parseHex(text: string): number | undefined {
    let s: string = text.trim().toUpperCase();
    if (s.startsWith('#')) {
      s = s.substring(1);
    }
    if (s.length !== HEX_LEN_RGB && s.length !== HEX_LEN_ARGB) {
      return undefined;
    }
    if (!AppColorPicker.isHexDigits(s)) {
      return undefined;
    }
    return ColorHex.parse(s);
  }

  private static isHexDigits(s: string): boolean {
    const digits: string = '0123456789ABCDEF';
    for (let i = 0; i < s.length; i++) {
      if (digits.indexOf(s.charAt(i)) < 0) {
        return false;
      }
    }
    return s.length > 0;
  }

  /** RGB → [色相 0..360, 饱和 0..1, 明度 0..1] */
  private static toHsv(rgb: RgbColor): number[] {
    const r: number = rgb.r / 255;
    const g: number = rgb.g / 255;
    const b: number = rgb.b / 255;
    const max: number = Math.max(r, g, b);
    const min: number = Math.min(r, g, b);
    const delta: number = max - min;
    let hue: number = 0;
    if (delta > 1e-6) {
      if (max === r) {
        hue = 60 * (((g - b) / delta) % 6);
      } else if (max === g) {
        hue = 60 * ((b - r) / delta + 2);
      } else {
        hue = 60 * ((r - g) / delta + 4);
      }
    }
    if (hue < 0) {
      hue += 360;
    }
    const sat: number = max <= 1e-6 ? 0 : delta / max;
    return [Math.round(hue), sat, max];
  }

  /** [色相, 饱和, 明度] → RGB 三元组（供预设色/手输 HEX 反推色相滑条位置） */
  static toRgbFromHsv(h: number, s: number, v: number): RgbColor {
    const c: number = v * s;
    const x: number = c * (1 - Math.abs(((h / 60) % 2) - 1));
    const m: number = v - c;
    let r: number = 0;
    let g: number = 0;
    let b: number = 0;
    if (h < 60) {
      r = c;
      g = x;
    } else if (h < 120) {
      r = x;
      g = c;
    } else if (h < 180) {
      g = c;
      b = x;
    } else if (h < 240) {
      g = x;
      b = c;
    } else if (h < 300) {
      r = x;
      b = c;
    } else {
      r = c;
      b = x;
    }
    return new RgbColor(Math.round((r + m) * 255), Math.round((g + m) * 255), Math.round((b + m) * 255));
  }

  build() {
    Column() {
      Text('选择颜色')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.TEXT)
        .margin({ bottom: 10 })

      Row({ space: 12 }) {
        Column() {
          Text('原色')
            .fontSize(Theme.FONT_SUB)
            .fontColor(Theme.TEXT_SUB)
          Column()
            .width(56)
            .height(28)
            .backgroundColor(this.colorText(this.initialColor))
            .borderRadius(4)
            .borderWidth(1)
            .borderColor(Theme.DIVIDER)
        }
        .alignItems(HorizontalAlign.Start)

        Column() {
          Text('新色')
            .fontSize(Theme.FONT_SUB)
            .fontColor(Theme.TEXT_SUB)
          Column()
            .width(56)
            .height(28)
            .backgroundColor(this.colorText(this.currentArgb()))
            .borderRadius(4)
            .borderWidth(1)
            .borderColor(Theme.DIVIDER)
        }
        .alignItems(HorizontalAlign.Start)

        Column() {
          Text('HEX（AARRGGBB）')
            .fontSize(Theme.FONT_SUB)
            .fontColor(Theme.TEXT_SUB)
          TextInput({ text: this.hexText })
            .width(140)
            .height(28)
            .fontSize(Theme.FONT_SUB)
            .backgroundColor(Theme.SUBTLE)
            .onChange((v: string): void => {
              this.hexText = v;
              if (this.updatingFromSlider) {
                return;
              }
              const parsed: number | undefined = AppColorPicker.parseHex(v);
              if (parsed !== undefined) {
                this.applyPreset(parsed);
              }
            })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Bottom)

      Row() {
        Text('色相')
          .fontSize(Theme.FONT_SUB)
          .fontColor(Theme.TEXT_SUB)
          .width(40)
        Slider({ value: this.hue, min: 0, max: 360, step: 1 })
          .layoutWeight(1)
          .blockColor(this.blockColor())
          .onChange((v: number): void => {
            this.hue = v;
            this.syncHex();
          })
      }
      .width('100%')
      .margin({ top: 12 })

      Row() {
        Text('透明')
          .fontSize(Theme.FONT_SUB)
          .fontColor(Theme.TEXT_SUB)
          .width(40)
        Slider({ value: this.alpha, min: 0, max: 255, step: 1 })
          .layoutWeight(1)
          .onChange((v: number): void => {
            this.alpha = v;
            this.syncHex();
          })
      }
      .width('100%')
      .margin({ top: 4 })

      Text(`预设`)
        .fontSize(Theme.FONT_SUB)
        .fontColor(Theme.TEXT_SUB)
        .alignSelf(ItemAlign.Start)
        .margin({ top: 10, bottom: 4 })
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(PRESET_COLORS, (color: number): void => {
          Column()
            .width(28)
            .height(22)
            .margin({ right: 6, bottom: 6 })
            .borderRadius(4)
            .backgroundColor(this.colorText(color))
            .borderWidth(1)
            .borderColor(Theme.DIVIDER)
            .onClick((): void => {
              this.applyPreset(color);
            })
        }, (color: number): string => `${color}`)
      }
      .width('100%')

      Row({ space: 10 }) {
        Button('取消')
          .layoutWeight(1)
          .height(38)
          .fontSize(Theme.FONT)
          .fontColor(Theme.TEXT_SUB)
          .backgroundColor(Theme.SUBTLE)
          .onClick((): void => {
            this.controller.close();
          })
        Button('确定')
          .layoutWeight(1)
          .height(38)
          .fontSize(Theme.FONT)
          .fontColor(Theme.TEXT_ON_DARK)
          .backgroundColor(Theme.PRIMARY)
          .onClick((): void => {
            this.confirm();
          })
      }
      .width('100%')
      .margin({ top: 14 })
    }
    .width('100%')
    .padding(Theme.PAD)
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(Theme.CARD)
    .borderRadius(Theme.RADIUS)
  }
}
