// ColorHex.ets —— ARGB 数值与 #AARRGGBB 文本互转（对应 Android com.zys.mobilemap.util.ColorHex）。
//
// 渲染内核样式字段（VectorStyle.fillColor 等）统一为 #AARRGGBB 打包 int32；ArkTS number 无溢出，
// 故写入 native 前须经 toSigned32 折算为有符号位模式，读取时反向无符号化。
// 与 ArkUI 的 '#AARRGGBB' 字符串色值互通，供样式对话框所见即所得回显。

/** 颜色三元组 + 透明度（对话框取色器中间态），r/g/b 取值 0..255 */
export class RgbColor {
  r: number = 0;
  g: number = 0;
  b: number = 0;

  constructor(r: number = 0, g: number = 0, b: number = 0) {
    this.r = r;
    this.g = g;
    this.b = b;
  }
}

export class ColorHex {
  /** int32 位模式 → '#AARRGGBB' 大写文本（对话框显示用） */
  static toHex(argb: number): string {
    return ColorHex.component(argb >>> 24) + ColorHex.component(argb >>> 16)
      + ColorHex.component(argb >>> 8) + ColorHex.component(argb);
  }

  /** '#AARRGGBB' / '#RRGGBB' 文本 → 无符号 ARGB 数值；解析失败返回默认值 */
  static parse(text: string, fallback: number = 0xFFFFFFFF): number {
    let s: string = text.trim();
    if (s.startsWith('#')) {
      s = s.substring(1);
    }
    if (s.length === 6) {
      s = `FF${s}`;
    }
    if (s.length !== 8) {
      return fallback;
    }
    const value: number = Number.parseInt(s, 16);
    return Number.isNaN(value) ? fallback : value;
  }

  /** 无符号 ARGB → native 需要的有符号 int32 位模式 */
  static toSigned32(argb: number): number {
    return argb | 0;
  }

  /** 有符号 int32 → 无符号 ARGB */
  static toUnsigned(argb: number): number {
    return argb >>> 0;
  }

  /** 取 alpha 分量（0..255） */
  static alpha(argb: number): number {
    return (argb >>> 24) & 0xFF;
  }

  /** 覆盖 alpha 分量，返回新的无符号 ARGB */
  static withAlpha(argb: number, alpha: number): number {
    const a: number = Math.max(0, Math.min(255, Math.round(alpha)));
    return ((a << 24) | (argb & 0x00FFFFFF)) >>> 0;
  }

  /** ARGB → RGB 三元组（丢弃 alpha） */
  static toRgb(argb: number): RgbColor {
    return new RgbColor((argb >>> 16) & 0xFF, (argb >>> 8) & 0xFF, argb & 0xFF);
  }

  /** RGB 三元组 + alpha → 无符号 ARGB */
  static fromRgb(color: RgbColor, alpha: number = 255): number {
    const a: number = Math.max(0, Math.min(255, Math.round(alpha)));
    return (((a << 24) | (color.r << 16) | (color.g << 8) | color.b)) >>> 0;
  }

  /** 单字节转两位大写十六进制 */
  private static component(value: number): string {
    const v: number = value & 0xFF;
    return v < 0x10 ? `0${v.toString(16).toUpperCase()}` : v.toString(16).toUpperCase();
  }
}
