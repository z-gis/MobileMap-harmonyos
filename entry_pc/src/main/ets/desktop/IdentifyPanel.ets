// IdentifyPanel.ets —— ArcMap「识别」结果面板：命中层名 + FID + 字段/值两列清单。
//
// 数据来自 NativeVector.getFeatureAttributes（按 FID 单要素回取全字段），几何高亮由宿主
// 经 featureGeometry + 叠加层画青色。面板只负责展示与回抛「缩放至要素 / 打开属性表」。
import { AttrField, DeskTheme } from '../common/DeskTheme';
import { DeskVector } from '../common/DeskVector';

@Component
struct FieldRow {
  @Prop field: AttrField = new AttrField('', '');
  @Prop odd: boolean = false;

  build() {
    Row() {
      Text(this.field.key)
        .fontSize(DeskTheme.FONT_BODY)
        .fontColor(DeskTheme.TEXT_SUB)
        .width('38%')
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .padding({ left: 8, right: 6, top: 3, bottom: 3 })
      Text(this.field.value)
        .fontSize(DeskTheme.FONT_BODY)
        .fontColor(DeskTheme.TEXT)
        .layoutWeight(1)
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .padding({ left: 6, right: 8, top: 3, bottom: 3 })
        .copyOption(CopyOptions.LocalDevice)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .backgroundColor(this.odd ? '#F7F7F7' : DeskTheme.PANEL)
    .border({ width: { bottom: 1 }, color: { bottom: DeskTheme.GRID_LINE } })
  }
}

@Component
export struct IdentifyPanel {
  @Prop layerName: string = '';
  @Prop fid: number = -1;
  @Prop fields: AttrField[] = [];
  /** 几何类别文本（点/线/面） */
  @Prop geomText: string = '';
  onZoom: (() => void) | undefined = undefined;
  onTable: (() => void) | undefined = undefined;

  private zoom(): void {
    const cb = this.onZoom;
    if (cb !== undefined) {
      cb();
    }
  }

  private table(): void {
    const cb = this.onTable;
    if (cb !== undefined) {
      cb();
    }
  }

  build() {
    Column() {
      if (this.fid < 0) {
        Column({ space: 6 }) {
          Text('未识别到要素')
            .fontSize(DeskTheme.FONT_BODY)
            .fontColor(DeskTheme.TEXT_DISABLED)
          Text('选工具条「识别」或「选择要素」，再点地图上的矢量要素。')
            .fontSize(DeskTheme.FONT_CAPTION)
            .fontColor(DeskTheme.TEXT_SUB)
            .textAlign(TextAlign.Center)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .padding(12)
      } else {
        Row({ space: 6 }) {
          Column({ space: 2 }) {
            Text(this.layerName)
              .fontSize(DeskTheme.FONT_BODY)
              .fontWeight(FontWeight.Medium)
              .fontColor(DeskTheme.TEXT)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(`FID ${this.fid}${this.geomText.length > 0 ? ` · ${this.geomText}` : ''}`)
              .fontSize(DeskTheme.FONT_CAPTION)
              .fontColor(DeskTheme.TEXT_SUB)
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)

          Text('缩放')
            .fontSize(DeskTheme.FONT_CAPTION)
            .fontColor(DeskTheme.ACCENT)
            .padding({ left: 7, right: 7, top: 3, bottom: 3 })
            .border({ width: 1, color: DeskTheme.DIVIDER_SOFT })
            .borderRadius(2)
            .hoverEffect(HoverEffect.Highlight)
            .onClick((): void => { this.zoom(); })
          Text('属性表')
            .fontSize(DeskTheme.FONT_CAPTION)
            .fontColor(DeskTheme.ACCENT)
            .padding({ left: 7, right: 7, top: 3, bottom: 3 })
            .border({ width: 1, color: DeskTheme.DIVIDER_SOFT })
            .borderRadius(2)
            .hoverEffect(HoverEffect.Highlight)
            .onClick((): void => { this.table(); })
        }
        .width('100%')
        .padding({ left: 8, right: 8, top: 6, bottom: 6 })
        .backgroundColor(DeskTheme.CHROME)

        Row() {
          Text('字段')
            .fontSize(DeskTheme.FONT_CAPTION)
            .fontColor(DeskTheme.TEXT_SUB)
            .width('38%')
            .padding({ left: 8, right: 6 })
          Text('值')
            .fontSize(DeskTheme.FONT_CAPTION)
            .fontColor(DeskTheme.TEXT_SUB)
            .layoutWeight(1)
            .padding({ left: 6 })
        }
        .width('100%')
        .height(20)
        .backgroundColor('#ECECEC')
        .border({ width: { bottom: 1 }, color: { bottom: DeskTheme.DIVIDER_SOFT } })

        List() {
          ForEach(this.fields, (f: AttrField, i: number) => {
            ListItem() {
              FieldRow({ field: f, odd: i % 2 === 1 })
            }
          }, (f: AttrField, i: number): string => `${i}-${f.key}-${f.value}`)
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Auto)
        .edgeEffect(EdgeEffect.None)

        Text(`${DeskVector.groupDigits(this.fields.length)} 个字段`)
          .fontSize(9)
          .fontColor(DeskTheme.TEXT_DISABLED)
          .width('100%')
          .padding({ left: 8, top: 3, bottom: 3 })
          .backgroundColor(DeskTheme.CHROME)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(DeskTheme.PANEL)
  }
}