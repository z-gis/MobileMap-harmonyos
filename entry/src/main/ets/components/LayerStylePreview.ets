// LayerStylePreview.ets —— 图层样式预览块（对应 Android LayerManageDialog.drawStylePreview）。
//
// Android 用 Canvas 现画一张位图塞进 ImageView；ArkUI 有声明式图元，直接用圆角矩形 + 文本组合等价呈现，
// 且样式改动能随属性刷新自动重绘（Android 靠 notifyItemChanged 重画位图）。
// 绘制口径逐条对齐：
//  · 面块 = 填充色（fillEnabled 为假时不填充）+ 描边色，线宽限幅 1~4 保证细值也可见；
//  · 线层（geomType=1）= 微折线示例（无填充），线色/线宽同面块描边口径；
//  · 点层（geomType=0）= 该层实际标识图标（iconKey → FeatureIcons 程序化位图，着色同渲染口径）；
//  · 标注字段已设置时居中绘制样本值（宿主取数据首条非空注记值，同地图实际渲染内容；缺省回退字段名），
//    字号 = 16 × 缩放系数（同 native 渲染基准，Renderer.drawVectorLabels），
//    轮廓开启时画 8 方向 1vp 偏移掩膜（同 native poor-man's halo，非阴影近似）；
//  · 栅格图层无样式概念，画固定灰色格阵（与 Android 的静态图标同义），且不响应点击。
// 颜色串统一为 '#AARRGGBB'（文档存储格式，ArkUI 直接接受，无需转换）。

import { image } from '@kit.ImageKit';
import { ColorHex } from '../common/ColorHex';
import { MapStyle } from '../map/MapStyle';
import { FeatureIcons } from '../vector/FeatureIcons';

/** 预览块尺寸（Android 布局声明 72dp × 36dp） */
const PREVIEW_W: number = 72;
const PREVIEW_H: number = 36;
/** 栅格固定色（Android R.color.icon_gray 近似） */
const RASTER_BLOCK: string = '#FFB0B8C0';
const RASTER_LINE: string = '#FF8A939C';
/** 轮廓掩膜 8 方向（同 native Renderer.cpp kDir）：偏移 1vp ≈ 渲染 1dp */
const HALO_DIRS: number[][] = [
  [1, 0], [-1, 0], [0, 1], [0, -1],
  [0.7071, 0.7071], [-0.7071, 0.7071], [0.7071, -0.7071], [-0.7071, -0.7071],
];

@Component
export struct LayerStylePreview {
  /** 填充色（含 alpha，已由宿主把 fillOpacity 折进颜色） */
  @Prop fill: string = '#664A8FE3';
  @Prop fillEnabled: boolean = true;
  // 注：成员名避开 CustomComponent 内置属性（outline / outlineWidth / borderWidth），否则编译期报重名
  @Prop strokeColor: string = '#FFFFFFFF';
  @Prop strokeWidthValue: number = 1;
  /** 标注字段名：非空时在面块上居中显示 */
  @Prop labelField: string = '';
  /** 标注样本值（数据首条非空注记值，同地图实际渲染内容）；空则回退显示字段名 */
  @Prop labelText: string = '';
  /** 默认白字（同 MapStyle.DEFAULT_LABEL_COLOR / native 渲染默认） */
  @Prop labelColor: string = '#FFFFFFFF';
  /** 字号缩放系数（文档存的 labelSize，1.0 = 基准） */
  @Prop labelScale: number = 1;
  @Prop labelOutline: boolean = false;
  @Prop labelOutlineColor: string = '#FF000000';
  /** 栅格图层：画固定格阵、不可点击 */
  @Prop raster: boolean = false;
  /** 几何类型（0 点 / 1 线 / 2 面 / -1 未知）：点层画标识图标、线层画折线示例（无填充），其余画面块 */
  @Prop @Watch('onIconParamChange') geomType: number = -1;
  /** 点层标识图标 key（FeatureIcons，缺省 pin）；与 iconColor 变化时重建图标位图 */
  @Prop @Watch('onIconParamChange') iconKey: string = FeatureIcons.DEFAULT_KEY;
  /** 点图标着色（渲染口径：outlineColor 未设时取线通道默认橙，见 MapLayerController） */
  @Prop @Watch('onIconParamChange') iconColor: string = '#FFE66B33';

  onTap: () => void = (): void => {};

  /** 点图标位图缓存：key+色未变不重生成（列表刷新频繁，64×64 逐像素生成不宜进 build 热路） */
  @State private iconPm: image.PixelMap | undefined = undefined;
  private iconPmKey: string = '';

  aboutToAppear(): void {
    this.refreshIconPm();
  }

  aboutToDisappear(): void {
    if (this.iconPm !== undefined) {
      this.iconPm.release();
      this.iconPm = undefined;
    }
  }

  private onIconParamChange(): void {
    this.refreshIconPm();
  }

  /** 点层才生成图标位图：FeatureIcons 像素（0xAARRGGBB）→ RGBA_8888 PixelMap */
  private refreshIconPm(): void {
    if (this.geomType !== 0) {
      return;
    }
    const key: string = `${this.iconKey}|${this.iconColor}`;
    if (key === this.iconPmKey && this.iconPm !== undefined) {
      return;
    }
    const argb: number[] = FeatureIcons.pixels(this.iconKey,
      ColorHex.parse(this.iconColor, MapStyle.DEFAULT_LINE_COLOR));
    const size: number = FeatureIcons.SIZE;
    const buf: ArrayBuffer = new ArrayBuffer(size * size * 4);
    const px: Uint8Array = new Uint8Array(buf);
    for (let i = 0; i < argb.length; i++) {
      const c: number = argb[i];
      px[i * 4] = (c >> 16) & 0xFF;
      px[i * 4 + 1] = (c >> 8) & 0xFF;
      px[i * 4 + 2] = c & 0xFF;
      px[i * 4 + 3] = (c >>> 24) & 0xFF;
    }
    try {
      const pm: image.PixelMap = image.createPixelMapSync(buf, {
        size: { width: size, height: size },
        pixelFormat: image.PixelMapFormat.RGBA_8888,
      });
      if (this.iconPm !== undefined) {
        this.iconPm.release();
      }
      this.iconPm = pm;
      this.iconPmKey = key;
    } catch (e) {
      // 生成失败保留旧位图（或空），点分支回退面块观感不中断列表
    }
  }

  /** 描边线宽：限幅 1~4（与 Android strokePaint 的 coerceIn(density, 4*density) 同） */
  private strokeWidthOf(): number {
    return Math.max(1, Math.min(4, this.strokeWidthValue));
  }

  /** 标注字号：16 × 缩放系数（同 native 渲染基准 16dp×labelSize，不限幅；超大字号由块裁剪兜底） */
  private labelFontSize(): number {
    return 16 * this.labelScale;
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.raster) {
        this.rasterGlyph()
      } else if (this.geomType === 0) {
        this.pointBlock()
      } else if (this.geomType === 1) {
        this.lineBlock()
      } else {
        this.vectorBlock()
      }
    }
    .width(PREVIEW_W)
    .height(PREVIEW_H)
    .clip(true)
    .onClick((): void => {
      if (!this.raster) {
        this.onTap();
      }
    })
    .accessibilityText(this.raster ? '栅格图层' : '图层样式预览')
  }

  /** 矢量面块：圆角矩形填充 + 描边，可选居中标注字段名 */
  @Builder
  vectorBlock() {
    Column() {
      if (this.labelField.length > 0) {
        this.labelGlyph()
      }
    }
    .justifyContent(FlexAlign.Center)
    .width('100%')
    .height('100%')
    .padding(3)
    .backgroundColor(this.fillEnabled ? this.fill : Color.Transparent)
    .border({ width: this.strokeWidthOf(), color: this.strokeColor, radius: 4 })
  }

  /** 点层示例：该层实际标识图标居中（位图未就绪时回退面块观感），标注字段名叠加同其余分支 */
  @Builder
  pointBlock() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.iconPm !== undefined) {
        Image(this.iconPm)
          .width(24)
          .height(24)
          .objectFit(ImageFit.Contain)
      } else {
        Circle({ width: 14, height: 14 })
          .fill(this.iconColor)
      }
      if (this.labelField.length > 0) {
        this.labelGlyph()
      }
    }
    .width('100%')
    .height('100%')
  }

  /** 线层示例：横贯预览区的微折线（无填充），线色/线宽与文档一致，标注字段名居中（与 Android 折线示例同构） */
  @Builder
  lineBlock() {
    Stack({ alignContent: Alignment.Center }) {
      Polyline({ width: PREVIEW_W, height: PREVIEW_H })
        .points([[4, PREVIEW_H * 0.72], [PREVIEW_W * 0.42, PREVIEW_H * 0.30],
          [PREVIEW_W - 4, PREVIEW_H * 0.58]])
        .fill(Color.Transparent)
        .stroke(this.strokeColor)
        .strokeWidth(this.strokeWidthOf())
        .strokeLineCap(LineCapStyle.Round)
        .strokeLineJoin(LineJoinStyle.Round)
      if (this.labelField.length > 0) {
        this.labelGlyph()
      }
    }
    .width('100%')
    .height('100%')
  }

  /** 标注样本文本：字号 16×缩放（同渲染），轮廓开启时画 8 方向 1vp 偏移掩膜（同 native halo 口径） */
  @Builder
  labelGlyph() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.labelOutline) {
        ForEach(HALO_DIRS, (d: number[]) => {
          Text(this.labelText.length > 0 ? this.labelText : this.labelField)
            .fontSize(this.labelFontSize())
            .fontColor(this.labelOutlineColor)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: PREVIEW_W - 12 })
            .offset({ x: d[0], y: d[1] })
        }, (d: number[]) => `${d[0]},${d[1]}`)
      }
      Text(this.labelText.length > 0 ? this.labelText : this.labelField)
        .fontSize(this.labelFontSize())
        .fontColor(this.labelColor)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .constraintSize({ maxWidth: PREVIEW_W - 12 })
    }
  }

  /** 栅格示意：2×2 灰格（表达「影像瓦片」语义，不可点击） */
  @Builder
  rasterGlyph() {
    Column({ space: 2 }) {
      Row({ space: 2 }) {
        this.rasterCell()
        this.rasterCell()
      }
      .width(PREVIEW_W - 16)
      .justifyContent(FlexAlign.Center)

      Row({ space: 2 }) {
        this.rasterCell()
        this.rasterCell()
      }
      .width(PREVIEW_W - 16)
      .justifyContent(FlexAlign.Center)
    }
    .justifyContent(FlexAlign.Center)
    .width('100%')
    .height('100%')
    .border({ width: 1, color: RASTER_LINE, radius: 4 })
  }

  @Builder
  rasterCell() {
    // 用形状组件而非空容器：栅格格块无需子节点，Rect 的 fill/stroke 直接对应「影像瓦片」观感
    Rect({ width: 12, height: 10 })
      .fill(RASTER_BLOCK)
      .stroke(RASTER_LINE)
      .strokeWidth(1)
      .radius(2)
  }
}
