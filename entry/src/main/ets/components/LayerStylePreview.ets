// LayerStylePreview.ets —— 图层样式预览块（对应 Android LayerManageDialog.drawStylePreview）。
//
// Android 用 Canvas 现画一张位图塞进 ImageView；ArkUI 有声明式图元，直接用圆角矩形 + 文本组合等价呈现，
// 且样式改动能随属性刷新自动重绘（Android 靠 notifyItemChanged 重画位图）。
// 绘制口径逐条对齐：
//  · 面块 = 填充色（fillEnabled 为假时不填充）+ 描边色，线宽限幅 1~4 保证细值也可见；
//  · 标注字段已设置时，字段名居中绘制，字号 = 11 × 缩放系数并限幅 8~16，轮廓开启时用阴影近似描边；
//  · 栅格图层无样式概念，画固定灰色格阵（与 Android 的静态图标同义），且不响应点击。
// 颜色串统一为 '#AARRGGBB'（文档存储格式，ArkUI 直接接受，无需转换）。

/** 预览块尺寸（Android 布局声明 72dp × 36dp） */
const PREVIEW_W: number = 72;
const PREVIEW_H: number = 36;
/** 栅格固定色（Android R.color.icon_gray 近似） */
const RASTER_BLOCK: string = '#FFB0B8C0';
const RASTER_LINE: string = '#FF8A939C';

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
  @Prop labelColor: string = '#FF212121';
  /** 字号缩放系数（文档存的 labelSize，1.0 = 基准） */
  @Prop labelScale: number = 1;
  @Prop labelOutline: boolean = false;
  @Prop labelOutlineColor: string = '#FF000000';
  /** 栅格图层：画固定格阵、不可点击 */
  @Prop raster: boolean = false;

  onTap: () => void = (): void => {};

  /** 描边线宽：限幅 1~4（与 Android strokePaint 的 coerceIn(density, 4*density) 同） */
  private strokeWidthOf(): number {
    return Math.max(1, Math.min(4, this.strokeWidthValue));
  }

  /** 标注字号：11 × 缩放系数，限幅 8~16 */
  private labelFontSize(): number {
    return Math.max(8, Math.min(16, 11 * this.labelScale));
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.raster) {
        this.rasterGlyph()
      } else {
        this.vectorBlock()
      }
    }
    .width(PREVIEW_W)
    .height(PREVIEW_H)
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
        Text(this.labelField)
          .fontSize(this.labelFontSize())
          .fontColor(this.labelColor)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .constraintSize({ maxWidth: PREVIEW_W - 12 })
          // 关闭轮廓时用零半径透明阴影占位（属性形状保持一致，避免条件式传入 undefined）
          .textShadow(this.labelOutline ? {
            radius: Math.max(1, this.labelFontSize() / 6),
            color: this.labelOutlineColor,
            offsetX: 0,
            offsetY: 0,
          } : {
            radius: 0,
            color: Color.Transparent,
            offsetX: 0,
            offsetY: 0,
          })
      }
    }
    .justifyContent(FlexAlign.Center)
    .width('100%')
    .height('100%')
    .padding(3)
    .backgroundColor(this.fillEnabled ? this.fill : Color.Transparent)
    .border({ width: this.strokeWidthOf(), color: this.strokeColor, radius: 4 })
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
