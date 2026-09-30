// FeatureIcons.ets —— 内置点要素图标（对应 Android vector.FeatureIcons）。
//
// Android 侧图标是 drawable 资源，经 decodeIconArgb 解码为 ARGB 像素数组传给 native billboard 纹理；
// 鸿蒙侧不引外部图片资源，改为「程序化生成位图」：同一套 key（pin/circle/triangle/square/star/flag）、
// 同一份像素契约（row-major 0xAARRGGBB，长度 = w*h），native 侧零改动。
// 默认图标 pin；样式覆盖里 iconKey 未命中时回退默认，与 Android 行为一致。
import { StyleOverride } from '../doc/DocModels';

export class FeatureIcons {
  static readonly DEFAULT_KEY: string = 'pin';
  static readonly CIRCLE: string = 'circle';
  static readonly TRIANGLE: string = 'triangle';
  static readonly SQUARE: string = 'square';
  static readonly STAR: string = 'star';
  static readonly FLAG: string = 'flag';

  /** 生成位图边长（像素）：native 按 iconW/iconH 作 dp 尺寸，纹理分辨率固定 64 */
  static readonly SIZE: number = 64;

  /** 可选图标清单（样式对话框下拉用，顺序即显示顺序） */
  static keys(): string[] {
    return [FeatureIcons.DEFAULT_KEY, FeatureIcons.CIRCLE, FeatureIcons.TRIANGLE,
      FeatureIcons.SQUARE, FeatureIcons.STAR, FeatureIcons.FLAG];
  }

  static labelOf(key: string): string {
    switch (key) {
      case FeatureIcons.CIRCLE:
        return '圆形';
      case FeatureIcons.TRIANGLE:
        return '三角';
      case FeatureIcons.SQUARE:
        return '方形';
      case FeatureIcons.STAR:
        return '星形';
      case FeatureIcons.FLAG:
        return '旗帜';
      case FeatureIcons.DEFAULT_KEY:
      default:
        return '图钉';
    }
  }

  /** 样式覆盖里的图标 key，未设置回退默认 */
  static keyOf(style: StyleOverride | undefined): string {
    const key: string | undefined = style === undefined ? undefined : style.iconKey;
    return (key === undefined || key.length === 0) ? FeatureIcons.DEFAULT_KEY : key;
  }

  /**
   * 生成图标 ARGB 像素数组（0xAARRGGBB，行优先，长度 SIZE*SIZE）。
   * @param key 图标名
   * @param argb 图标着色（alpha 由形状自身覆盖：形状内不透明、形状外全透明）
   */
  static pixels(key: string, argb: number): number[] {
    const size: number = FeatureIcons.SIZE;
    const rgb: number = argb & 0x00FFFFFF;
    const out: number[] = [];
    const c: number = (size - 1) / 2.0;
    // 统一留 10% 边距，避免图标贴边被裁
    const r: number = c * 0.9;
    for (let y = 0; y < size; y++) {
      for (let x = 0; x < size; x++) {
        const dx: number = x - c;
        const dy: number = y - c;
        const inside: boolean = FeatureIcons.contains(key, dx, dy, r, c, size);
        out.push(inside ? (0xFF000000 + rgb) : 0);
      }
    }
    return out;
  }

  /** 形状命中判定（局部坐标：原点=中心，y 轴向下） */
  private static contains(key: string, dx: number, dy: number, r: number,
    c: number, size: number): boolean {
    if (key === FeatureIcons.CIRCLE) {
      return dx * dx + dy * dy <= r * r;
    }
    if (key === FeatureIcons.SQUARE) {
      const half: number = r * 0.82;
      return Math.abs(dx) <= half && Math.abs(dy) <= half;
    }
    if (key === FeatureIcons.TRIANGLE) {
      // 等边三角形：顶点在上，底边在下
      const top: number = -r;
      const bottom: number = r * 0.75;
      if (dy < top || dy > bottom) {
        return false;
      }
      const t: number = (dy - top) / (bottom - top);
      return Math.abs(dx) <= r * t;
    }
    if (key === FeatureIcons.STAR) {
      return FeatureIcons.inStar(dx, dy, r);
    }
    if (key === FeatureIcons.FLAG) {
      // 旗杆 + 旗面
      if (dx >= -r * 0.75 && dx <= -r * 0.55 && dy <= r * 0.9 && dy >= -r * 0.9) {
        return true;
      }
      return dx >= -r * 0.55 && dx <= r * 0.9 && dy >= -r * 0.9 && dy <= r * 0.15;
    }
    // 默认图钉：上部圆头 + 下部尖尾
    const headCy: number = -r * 0.3;
    const headR: number = r * 0.62;
    const hdx: number = dx;
    const hdy: number = dy - headCy;
    if (hdx * hdx + hdy * hdy <= headR * headR) {
      return true;
    }
    const tipY: number = r * 0.95;
    if (dy > headCy && dy <= tipY) {
      const t: number = (tipY - dy) / (tipY - headCy);
      return Math.abs(dx) <= headR * 0.42 * t;
    }
    return false;
  }

  /** 五角星判定：极坐标下按角度分段在内/外半径之间 */
  private static inStar(dx: number, dy: number, r: number): boolean {
    const dist: number = Math.sqrt(dx * dx + dy * dy);
    if (dist > r) {
      return false;
    }
    let angle: number = Math.atan2(dy, dx);
    angle = (angle + Math.PI * 2.5) % (Math.PI * 2);
    const step: number = Math.PI / 5;
    const sector: number = Math.floor(angle / step);
    const local: number = angle - sector * step;
    // 交替外/内顶点：尖角处半径 r，凹角处 0.4r
    const t: number = local / step;
    const outer: number = sector % 2 === 0 ? 1.0 : 0.4;
    const radiusAt: number = r * (outer - (outer - (sector % 2 === 0 ? 0.4 : 1.0)) * t);
    return dist <= radiusAt;
  }
}
