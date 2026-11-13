// LayerPropsPanel.ets —— ArcMap「图层属性」对话框内容：通用（源/四至/坐标系/字段）+ 符号系统（颜色/标注）。
//
// 不做成 @CustomDialog 而由宿主在 Stack 里盖遮罩渲染：CustomDialogController 的 builder 参数
// 在构造期快照，换图层再开容易拿到旧值；普通 @Component + @Prop 每次开面板重建，值一定是当前的。
// 「应用/确定」回抛 (color, labelField)，宿主就地换层（removeVectorLayer + addVectorLayer）写样式。
import { DeskTheme, GeomKind, LayerRow } from '../common/DeskTheme';
import { DeskVector } from '../common/DeskVector';

@Component
struct InfoRow {
  @Prop label: string = '';
  @Prop value: string = '';

  build() {
    Row() {
      Text(this.label)
        .fontSize(DeskTheme.FONT_BODY)
        .fontColor(DeskTheme.TEXT_SUB)
        .width(76)
        .padding({ left: 2, top: 4, bottom: 4 })
      Text(this.value.length > 0 ? this.value : '—')
        .fontSize(DeskTheme.FONT_BODY)
        .fontColor(DeskTheme.TEXT)
        .layoutWeight(1)
        .padding({ left: 6, right: 2, top: 4, bottom: 4 })
        .copyOption(CopyOptions.LocalDevice)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .border({ width: { bottom: 1 }, color: { bottom: DeskTheme.GRID_LINE } })
  }
}

@Component
struct TabHead {
  @Prop label: string = '';
  @Prop active: boolean = false;
  onTap: (() => void) | undefined = undefined;

  build() {
    Text(this.label)
      .fontSize(DeskTheme.FONT_BODY)
      .fontColor(this.active ? DeskTheme.TEXT : DeskTheme.TEXT_SUB)
      .fontWeight(this.active ? FontWeight.Medium : FontWeight.Normal)
      .height(26)
      .padding({ left: 16, right: 16 })
      .backgroundColor(this.active ? DeskTheme.PANEL : DeskTheme.CHROME)
      .border({
        width: { bottom: this.active ? 0 : 1, left: 1, right: 1, top: 1 },
        color: {
          bottom: DeskTheme.DIVIDER_SOFT,
          left: DeskTheme.DIVIDER_SOFT,
          right: DeskTheme.DIVIDER_SOFT,
          top: DeskTheme.DIVIDER_SOFT
        }
      })
      .onClick((): void => {
        const cb = this.onTap;
        if (cb !== undefined) {
          cb();
        }
      })
  }
}

@Component
export struct LayerPropsPanel {
  @Prop row: LayerRow = new LayerRow('', 'vector', -1, true);
  @Prop fieldNames: string[] = [];
  @Prop srs: string = '';
  @Prop formatLabel: string = '';
  @Prop sizeText: string = '';
  onApply: ((color: number, labelField: string) => void) | undefined = undefined;
  onClose: (() => void) | undefined = undefined;

  @State private tab: number = 0;
  @State private color: number = 0xFF1F6FB2;
  @State private labelField: string = '';
  @State private labelIndex: number = 0;

  aboutToAppear(): void {
    this.color = this.row.color;
    // 标注从行现值起（未记录则 0=不标注）：否则每次开面板都把已应用的标注当未设，
    // 用户点「应用」会连带清掉标注，刷新/换层也拿不到字段名
    const at: number = this.fieldNames.indexOf(this.row.labelField);
    this.labelField = at >= 0 ? this.row.labelField : '';
    this.labelIndex = at >= 0 ? at + 1 : 0;
    this.tab = 0;
  }

  private apply(): void {
    const cb = this.onApply;
    if (cb !== undefined) {
      cb(this.color, this.labelField);
    }
  }

  private close(): void {
    const cb = this.onClose;
    if (cb !== undefined) {
      cb();
    }
  }

  private labelOptions(): SelectOption[] {
    const out: SelectOption[] = [{ value: '（不标注）' }];
    for (let i = 0; i < this.fieldNames.length; i++) {
      out.push({ value: this.fieldNames[i] });
    }
    return out;
  }

  private extentText(): string {
    const e: number[] = this.row.extent;
    if (e.length < 4) {
      return '';
    }
    return `西 ${e[0].toFixed(6)}°  南 ${e[1].toFixed(6)}°\n东 ${e[2].toFixed(6)}°  北 ${e[3].toFixed(6)}°`;
  }

  private geomText(): string {
    switch (this.row.geom) {
      case GeomKind.POINT: return '点';
      case GeomKind.LINE: return '线';
      case GeomKind.POLYGON: return '面';
      case GeomKind.RASTER: return '栅格';
      case GeomKind.TILE: return '瓦片底图';
      default: return '混合 / 未知';
    }
  }

  build() {
    Column() {
      // 标题条
      Row() {
        Text(`${this.row.name} 属性`)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(DeskTheme.TEXT)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text('×')
          .fontSize(16)
          .fontColor(DeskTheme.TEXT_SUB)
          .width(24)
          .height(24)
          .textAlign(TextAlign.Center)
          .hoverEffect(HoverEffect.Highlight)
          .onClick((): void => { this.close(); })
      }
      .width('100%')
      .height(32)
      .padding({ left: 12, right: 6 })
      .backgroundColor(DeskTheme.CHROME)
      .border({ width: { bottom: 1 }, color: { bottom: DeskTheme.DIVIDER } })

      // 页签
      Row() {
        TabHead({ label: '通用', active: this.tab === 0,
          onTap: (): void => { this.tab = 0; } })
        TabHead({ label: '符号系统', active: this.tab === 1,
          onTap: (): void => { this.tab = 1; } })
        Blank()
      }
      .width('100%')
      .padding({ left: 10, top: 8 })
      .backgroundColor(DeskTheme.CHROME)

      Column() {
        if (this.tab === 0) {
          Scroll() {
            Column() {
              InfoRow({ label: '名称', value: this.row.name })
              InfoRow({ label: '数据格式', value: this.formatLabel })
              InfoRow({ label: '类型', value: `${this.row.kindLabel()} · ${this.geomText()}` })
              InfoRow({ label: '要素数',
                value: this.row.featureCount >= 0 ? DeskVector.groupDigits(this.row.featureCount) : '' })
              InfoRow({ label: '文件大小', value: this.sizeText })
              InfoRow({ label: '四至', value: this.extentText() })
              InfoRow({ label: '坐标系', value: this.srs })
              InfoRow({ label: '字段数',
                value: this.fieldNames.length > 0 ? `${this.fieldNames.length}` : '' })
              InfoRow({ label: '字段', value: this.fieldNames.join(', ') })
              InfoRow({ label: '路径', value: this.row.path })
            }
            .width('100%')
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          }
          .width('100%')
          .layoutWeight(1)
          .scrollBar(BarState.Auto)
          .align(Alignment.TopStart)
        } else {
          Scroll() {
            Column({ space: 12 }) {
              Column({ space: 6 }) {
                Text('颜色')
                  .fontSize(DeskTheme.FONT_BODY)
                  .fontColor(DeskTheme.TEXT_SUB)
                  .width('100%')
                Flex({ wrap: FlexWrap.Wrap }) {
                  ForEach(DeskTheme.PALETTE, (c: number) => {
                    Stack() {
                      Rect()
                        .width(22)
                        .height(16)
                        .fill(DeskTheme.css(c))
                        .stroke(c === this.color ? DeskTheme.TEXT : DeskTheme.DIVIDER)
                        .strokeWidth(c === this.color ? 2 : 0.8)
                    }
                    .width(30)
                    .height(24)
                    .onClick((): void => {
                      this.color = c;
                    })
                  }, (c: number): string => `${c}`)
                }
                .width('100%')
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)

              Row({ space: 8 }) {
                Text('当前符号')
                  .fontSize(DeskTheme.FONT_BODY)
                  .fontColor(DeskTheme.TEXT_SUB)
                Rect()
                  .width(46)
                  .height(24)
                  .fill(DeskTheme.rgba(this.color))
                  .stroke(DeskTheme.css(this.color))
                  .strokeWidth(1.6)
                Text(DeskTheme.css(this.color))
                  .fontSize(DeskTheme.FONT_CAPTION)
                  .fontColor(DeskTheme.TEXT_SUB)
              }
              .width('100%')

              Column({ space: 6 }) {
                Text('标注')
                  .fontSize(DeskTheme.FONT_BODY)
                  .fontColor(DeskTheme.TEXT_SUB)
                  .width('100%')
                Select(this.labelOptions())
                  .selected(this.labelIndex)
                  .value(this.labelIndex === 0 ? '（不标注）' : this.labelField)
                  .font({ size: DeskTheme.FONT_BODY })
                  .width(240)
                  .height(30)
                  .onSelect((index: number, value: string): void => {
                    this.labelIndex = index;
                    this.labelField = index === 0 ? '' : value;
                  })
                Text('标注以白色描黑边绘制在要素上；字段为空则整层不标注。')
                  .fontSize(DeskTheme.FONT_CAPTION)
                  .fontColor(DeskTheme.TEXT_DISABLED)
                  .width('100%')
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)

              if (!this.row.isVector()) {
                Text('底图 / 栅格图层的符号由数据源决定，颜色与标注仅对矢量图层生效。')
                  .fontSize(DeskTheme.FONT_CAPTION)
                  .fontColor(DeskTheme.TEXT_DISABLED)
                  .width('100%')
              }
            }
            .width('100%')
            .padding(14)
          }
          .width('100%')
          .layoutWeight(1)
          .scrollBar(BarState.Auto)
          .align(Alignment.TopStart)
        }
      }
      .width('100%')
      .layoutWeight(1)
      .backgroundColor(DeskTheme.PANEL)
      .border({ width: { top: 1 }, color: { top: DeskTheme.DIVIDER_SOFT } })

      // 按钮条
      Row({ space: 8 }) {
        Blank()
        Text('确定')
          .fontSize(DeskTheme.FONT_BODY)
          .fontColor(DeskTheme.TEXT)
          .width(76)
          .height(26)
          .textAlign(TextAlign.Center)
          .backgroundColor(DeskTheme.CHROME)
          .border({ width: 1, color: DeskTheme.DIVIDER })
          .borderRadius(2)
          .hoverEffect(HoverEffect.Highlight)
          .onClick((): void => {
            this.apply();
            this.close();
          })
        Text('取消')
          .fontSize(DeskTheme.FONT_BODY)
          .fontColor(DeskTheme.TEXT)
          .width(76)
          .height(26)
          .textAlign(TextAlign.Center)
          .backgroundColor(DeskTheme.CHROME)
          .border({ width: 1, color: DeskTheme.DIVIDER })
          .borderRadius(2)
          .hoverEffect(HoverEffect.Highlight)
          .onClick((): void => { this.close(); })
        Text('应用')
          .fontSize(DeskTheme.FONT_BODY)
          .fontColor(DeskTheme.TEXT)
          .width(76)
          .height(26)
          .textAlign(TextAlign.Center)
          .backgroundColor(DeskTheme.CHROME)
          .border({ width: 1, color: DeskTheme.DIVIDER })
          .borderRadius(2)
          .hoverEffect(HoverEffect.Highlight)
          .onClick((): void => { this.apply(); })
      }
      .width('100%')
      .height(42)
      .padding({ left: 12, right: 12 })
      .backgroundColor(DeskTheme.CHROME)
      .border({ width: { top: 1 }, color: { top: DeskTheme.DIVIDER_SOFT } })
    }
    .width(560)
    .height(480)
    .backgroundColor(DeskTheme.PANEL)
    .border({ width: 1, color: DeskTheme.DIVIDER })
    .borderRadius(3)
    .shadow({ radius: 18, color: 'rgba(0,0,0,0.35)', offsetX: 0, offsetY: 6 })
  }
}