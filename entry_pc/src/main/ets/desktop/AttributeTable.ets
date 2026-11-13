// AttributeTable.ets —— ArcMap 式属性表：记录导航条 + 横向滚动网格 + 行选中定位。
//
// 分页由宿主用 OGR SQL（LIMIT/OFFSET）取，SQL 不可用时回退全量读取再切片；本组件只展示一页。
// 横向 Scroll 套纵向 List：两轴垂直，各自消费自己的滚动手势（列多时横滚看字段，行多时纵滚翻页）。
// 行点击回抛 FID，宿主据此高亮要素并缩放至该要素——ArcMap 属性表左下角「选中记录」的同义操作。
import { DeskTheme, TablePage } from '../common/DeskTheme';
import { DeskVector } from '../common/DeskVector';

/** 列宽（vp）：FID 窄列，属性列等宽 */
const FID_COL_W: number = 64;
const ATTR_COL_W: number = 132;
const ROW_H: number = 22;

@Component
struct NavButton {
  @Prop text: string = '';
  @Prop isEnabled: boolean = true;
  onTap: (() => void) | undefined = undefined;

  build() {
    Text(this.text)
      .fontSize(DeskTheme.FONT_CAPTION)
      .fontColor(this.isEnabled ? DeskTheme.TEXT : DeskTheme.TEXT_DISABLED)
      .width(24)
      .height(20)
      .textAlign(TextAlign.Center)
      .border({ width: 1, color: DeskTheme.DIVIDER_SOFT })
      .borderRadius(2)
      .backgroundColor(DeskTheme.PANEL)
      .hoverEffect(this.isEnabled ? HoverEffect.Highlight : HoverEffect.None)
      .onClick((): void => {
        const cb = this.onTap;
        if (this.isEnabled && cb !== undefined) {
          cb();
        }
      })
  }
}

@Component
export struct AttributeTable {
  @Prop page: TablePage = new TablePage();
  @Prop layerName: string = '';
  @Prop selectedFid: number = -1;
  @Prop pageSize: number = 200;
  @Prop subLayers: string[] = [];
  @Prop subLayer: string = '';
  onPage: ((offset: number) => void) | undefined = undefined;
  onRow: ((fid: number) => void) | undefined = undefined;
  onSubLayer: ((name: string) => void) | undefined = undefined;

  private totalWidth(): number {
    const n: number = this.page.headers.length;
    return n <= 1 ? FID_COL_W : FID_COL_W + (n - 1) * ATTR_COL_W;
  }

  private pageCount(): number {
    if (this.page.total <= 0) {
      return 1;
    }
    return Math.max(1, Math.ceil(this.page.total / this.pageSize));
  }

  private currentPage(): number {
    return Math.floor(this.page.offset / this.pageSize) + 1;
  }

  private go(offset: number): void {
    const cb = this.onPage;
    if (cb !== undefined) {
      cb(Math.max(0, offset));
    }
  }

  private pickRow(fid: number): void {
    const cb = this.onRow;
    if (cb !== undefined) {
      cb(fid);
    }
  }

  private colWidth(index: number): number {
    return index === 0 ? FID_COL_W : ATTR_COL_W;
  }

  /** 多子层数据源（gpkg）的子表下拉；单表不显示 */
  private subLayerMenu(): MenuElement[] {
    const out: MenuElement[] = [];
    for (let i = 0; i < this.subLayers.length; i++) {
      const name: string = this.subLayers[i];
      out.push({
        value: name,
        action: (): void => {
          const cb = this.onSubLayer;
          if (cb !== undefined) {
            cb(name);
          }
        }
      });
    }
    return out;
  }

  build() {
    Column() {
      // ── 记录导航条 ──
      Row({ space: 5 }) {
        Text(`${this.layerName} 属性表`)
          .fontSize(DeskTheme.FONT_BODY)
          .fontWeight(FontWeight.Medium)
          .fontColor(DeskTheme.TEXT)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        if (this.subLayers.length > 1) {
          Row({ space: 4 }) {
            Text(this.subLayer.length > 0 ? this.subLayer : this.subLayers[0])
              .fontSize(DeskTheme.FONT_CAPTION)
              .fontColor(DeskTheme.TEXT)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            Text('▾')
              .fontSize(9)
              .fontColor(DeskTheme.TEXT_SUB)
          }
          .width(120)
          .height(20)
          .padding({ left: 6, right: 5 })
          .backgroundColor(DeskTheme.PANEL)
          .border({ width: 1, color: DeskTheme.DIVIDER })
          .borderRadius(1)
          .bindMenu(this.subLayerMenu())
        }
        Text(this.page.total > 0
          ? `${DeskVector.groupDigits(this.page.offset + 1)}-${DeskVector.groupDigits(
              this.page.offset + this.page.rows.length)} / ${DeskVector.groupDigits(this.page.total)}`
          : '0 条记录')
          .fontSize(DeskTheme.FONT_CAPTION)
          .fontColor(DeskTheme.TEXT_SUB)
          .fontFeature('"tnum" on')
        NavButton({ text: '|<', isEnabled: this.page.offset > 0,
          onTap: (): void => { this.go(0); } })
        NavButton({ text: '<', isEnabled: this.page.offset > 0,
          onTap: (): void => { this.go(this.page.offset - this.pageSize); } })
        Text(`${this.currentPage()}/${this.pageCount()}`)
          .fontSize(DeskTheme.FONT_CAPTION)
          .fontColor(DeskTheme.TEXT_SUB)
          .width(46)
          .textAlign(TextAlign.Center)
        NavButton({ text: '>', isEnabled: this.page.offset + this.pageSize < this.page.total,
          onTap: (): void => { this.go(this.page.offset + this.pageSize); } })
        NavButton({ text: '>|', isEnabled: this.page.offset + this.pageSize < this.page.total,
          onTap: (): void => { this.go((this.pageCount() - 1) * this.pageSize); } })
      }
      .width('100%')
      .height(28)
      .padding({ left: 8, right: 8 })
      .backgroundColor(DeskTheme.CHROME)
      .border({ width: { bottom: 1 }, color: { bottom: DeskTheme.DIVIDER_SOFT } })

      if (this.page.error.length > 0) {
        Text(this.page.error)
          .fontSize(DeskTheme.FONT_BODY)
          .fontColor('#B00000')
          .width('100%')
          .padding(10)
      } else if (this.page.headers.length === 0) {
        Text('先在内容表里选一个矢量图层，再右键「打开属性表」。')
          .fontSize(DeskTheme.FONT_BODY)
          .fontColor(DeskTheme.TEXT_DISABLED)
          .width('100%')
          .padding(10)
      } else {
        // ── 网格：横滚看字段，纵滚看记录 ──
        Scroll() {
          Column() {
            Row() {
              ForEach(this.page.headers, (h: string, i: number) => {
                Text(h)
                  .fontSize(DeskTheme.FONT_CAPTION)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(DeskTheme.TEXT)
                  .width(this.colWidth(i))
                  .height(ROW_H)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .padding({ left: 5, right: 5 })
                  .backgroundColor('#ECECEC')
                  .border({
                    width: { right: 1, bottom: 1 },
                    color: { right: DeskTheme.DIVIDER_SOFT, bottom: DeskTheme.DIVIDER }
                  })
              }, (h: string, i: number): string => `${i}-${h}`)
            }
            .width(this.totalWidth())
            .height(ROW_H)

            List() {
              ForEach(this.page.rows, (cells: string[], r: number) => {
                ListItem() {
                  Row() {
                    ForEach(cells, (c: string, i: number) => {
                      Text(c)
                        .fontSize(DeskTheme.FONT_STATUS)
                        .fontColor(i === 0 ? DeskTheme.TEXT_SUB : DeskTheme.TEXT)
                        .width(this.colWidth(i))
                        .height(ROW_H)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .padding({ left: 5, right: 5 })
                        .border({
                          width: { right: 1, bottom: 1 },
                          color: { right: DeskTheme.GRID_LINE, bottom: DeskTheme.GRID_LINE }
                        })
                    }, (c: string, i: number): string => `${r}-${i}-${c}`)
                  }
                  .width(this.totalWidth())
                  .height(ROW_H)
                  .backgroundColor(this.page.fids[r] === this.selectedFid ? DeskTheme.ACTIVE
                    : (r % 2 === 1 ? '#FAFAFA' : DeskTheme.PANEL))
                  .onClick((): void => {
                    this.pickRow(this.page.fids[r]);
                  })
                }
              }, (cells: string[], r: number): string => `${this.page.offset}-${r}-${this.page.fids[r]}`)
            }
            .width(this.totalWidth())
            .layoutWeight(1)
            .scrollBar(BarState.Auto)
            .edgeEffect(EdgeEffect.None)
          }
          .width(this.totalWidth())
          .height('100%')
        }
        .width('100%')
        .layoutWeight(1)
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Auto)
        .align(Alignment.TopStart)
      }

      // ── 底部选择集提示 ──
      Row({ space: 6 }) {
        Text(this.selectedFid >= 0 ? `选中记录：FID ${this.selectedFid}` : '未选中记录')
          .fontSize(DeskTheme.FONT_CAPTION)
          .fontColor(this.selectedFid >= 0 ? DeskTheme.ACCENT : DeskTheme.TEXT_DISABLED)
        Blank()
        Text('点击记录可高亮并缩放至该要素')
          .fontSize(9)
          .fontColor(DeskTheme.TEXT_DISABLED)
      }
      .width('100%')
      .height(20)
      .padding({ left: 8, right: 8 })
      .backgroundColor(DeskTheme.CHROME)
      .border({ width: { top: 1 }, color: { top: DeskTheme.DIVIDER_SOFT } })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(DeskTheme.PANEL)
  }
}