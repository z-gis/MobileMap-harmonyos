// TocPanel.ets —— ArcMap 内容表（Table of Contents）：数据框根 + 分组树 + 图层树 + 右键菜单 + 显示/源页签。
//
// 行结构照 ArcMap：复选框（显隐）→ 符号色块（按几何类别画面/线/点/栅格）→ 图层名。
// 分组（Group Layer）：组头复选框扇出成员显隐、箭头折叠；右键组头「重命名/删除」，右键数据框根「新建分组」。
// 图层右键菜单给「缩放至图层 / 打开属性表 / 属性 / 移至分组 / 移除」，命令字回抛宿主单点分发。
// 底部「显示 | 源」页签：源页签在名字下多显示一行沙箱路径（ArcMap 的 List By Source 同义）。
// 行/符号做成子组件 + @Prop：@Builder 值参不随状态刷新，本项目已实测踩过。
// 分组只是组织视图，不改绘制顺序；成员/未分组行都携带原始 rows 下标回抛（宿主按下标定位）。
import { DeskCmd, DeskLayerGroup, DeskTheme, GeomKind, LayerRow } from '../common/DeskTheme';
import { ToolIcon } from './ToolIcon';

/** 显示行 → 原始 rows 下标的映射（分组过滤后 ForEach 的 index 不再是原始下标） */
class TocEntry {
  row: LayerRow;
  index: number;

  constructor(row: LayerRow, index: number) {
    this.row = row;
    this.index = index;
  }
}

@Component
struct LayerSymbol {
  @Prop geom: string = GeomKind.MIXED;
  @Prop color: number = 0xFF1F6FB2;

  build() {
    Stack() {
      if (this.geom === GeomKind.POINT) {
        Circle()
          .width(8)
          .height(8)
          .fill(DeskTheme.css(this.color))
          .stroke('#3A3A3A')
          .strokeWidth(0.6)
      } else if (this.geom === GeomKind.LINE) {
        Path()
          .commands('M2 13 L16 4')
          .width(18)
          .height(16)
          .fill('rgba(0,0,0,0)')
          .stroke(DeskTheme.css(this.color))
          .strokeWidth(2.4)
          .antiAlias(true)
      } else if (this.geom === GeomKind.RASTER || this.geom === GeomKind.TILE) {
        Rect()
          .width(16)
          .height(11)
          .fill('#9CC77E')
          .stroke('#4A4A4A')
          .strokeWidth(0.8)
      } else {
        Rect()
          .width(16)
          .height(11)
          .fill(DeskTheme.rgba(this.color))
          .stroke(DeskTheme.css(this.color))
          .strokeWidth(1)
      }
    }
    .width(20)
    .height(16)
  }
}

@Component
struct TocRow {
  @Prop row: LayerRow = new LayerRow('', 'vector', -1, true);
  @Prop selected: boolean = false;
  @Prop sourceTab: boolean = false;
  @Prop indent: number = 22;
  onToggle: ((visible: boolean) => void) | undefined = undefined;
  onSelect: (() => void) | undefined = undefined;
  onCommand: ((cmd: string) => void) | undefined = undefined;
  private lastTapMs: number = 0;

  private emit(cmd: string): void {
    const cb = this.onCommand;
    if (cb !== undefined) {
      cb(cmd);
    }
  }

  // bindContextMenu 只收 CustomBuilder（MenuElement[] 是 bindMenu 的入参），故右键菜单走 Menu/MenuItem
  @Builder
  rowMenu() {
    Menu() {
      MenuItem({ content: '缩放至图层' })
        .onClick((): void => { this.emit(DeskCmd.LAYER_ZOOM); })
      MenuItem({ content: '打开属性表' })
        .enabled(this.row.isVector())
        .onClick((): void => { this.emit(DeskCmd.LAYER_TABLE); })
      MenuItem({ content: '属性…' })
        .onClick((): void => { this.emit(DeskCmd.LAYER_PROPERTY); })
      MenuItem({ content: '移至分组…' })
        .onClick((): void => { this.emit(DeskCmd.LAYER_MOVE_GROUP); })
      MenuItem({ content: '刷新' })
        .enabled(this.row.isVector() && this.row.engineIndex >= 0)
        .onClick((): void => { this.emit(DeskCmd.LAYER_REFRESH); })
      MenuItem({ content: '移除图层' })
        .enabled(this.row.engineIndex >= 0)
        .onClick((): void => { this.emit(DeskCmd.LAYER_REMOVE); })
    }
  }

  build() {
    Row({ space: 5 }) {
      Toggle({ type: ToggleType.Checkbox, isOn: this.row.visible })
        .width(14)
        .height(14)
        .selectedColor(DeskTheme.ACCENT)
        .onChange((isOn: boolean): void => {
          const cb = this.onToggle;
          if (cb !== undefined) {
            cb(isOn);
          }
        })
      LayerSymbol({ geom: this.row.geom, color: this.row.color })
      Column({ space: 1 }) {
        Text(this.row.name)
          .fontSize(DeskTheme.FONT_BODY)
          .fontColor(this.row.engineIndex >= 0 ? DeskTheme.TEXT : DeskTheme.TEXT_DISABLED)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        if (this.sourceTab) {
          Text(this.row.path.length > 0 ? this.row.path : this.row.kindLabel())
            .fontSize(9)
            .fontColor(DeskTheme.TEXT_SUB)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height(this.sourceTab ? 34 : 22)
    .padding({ left: this.indent, right: 6 })
    .backgroundColor(this.selected ? DeskTheme.SELECT_ROW : DeskTheme.PANEL)
    .onClick((): void => {
      // ArcMap 惯例：双击图层行 = 打开图层属性。onClick 与 TapGesture(count:2) 仲裁会吞双击，
      // 故用时间窗自判（450ms 内同行二次点击）。
      const now: number = Date.now();
      if (now - this.lastTapMs < 450) {
        this.lastTapMs = 0;
        this.emit(DeskCmd.LAYER_PROPERTY);
        return;
      }
      this.lastTapMs = now;
      const cb = this.onSelect;
      if (cb !== undefined) {
        cb();
      }
    })
    .bindContextMenu(this.rowMenu, ResponseType.RightClick)
  }
}

@Component
struct TocGroupRow {
  @Prop group: DeskLayerGroup = new DeskLayerGroup();
  @Prop count: number = 0;
  @Prop allVisible: boolean = false;
  @Prop collapsed: boolean = false;
  onToggleVisible: ((visible: boolean) => void) | undefined = undefined;
  onToggleCollapse: (() => void) | undefined = undefined;
  onCommand: ((cmd: string) => void) | undefined = undefined;

  private emit(cmd: string): void {
    const cb = this.onCommand;
    if (cb !== undefined) {
      cb(cmd);
    }
  }

  private collapse(): void {
    const cb = this.onToggleCollapse;
    if (cb !== undefined) {
      cb();
    }
  }

  @Builder
  groupMenu() {
    Menu() {
      MenuItem({ content: '重命名分组' })
        .onClick((): void => { this.emit(DeskCmd.GROUP_RENAME); })
      MenuItem({ content: '删除分组' })
        .onClick((): void => { this.emit(DeskCmd.GROUP_DELETE); })
    }
  }

  build() {
    Row({ space: 4 }) {
      Text(this.collapsed ? '▸' : '▾')
        .fontSize(9)
        .fontColor(DeskTheme.TEXT_SUB)
        .width(10)
        .onClick((): void => { this.collapse(); })
      Toggle({ type: ToggleType.Checkbox, isOn: this.allVisible })
        .width(14)
        .height(14)
        .selectedColor(DeskTheme.ACCENT)
        .enabled(this.count > 0)
        .onChange((isOn: boolean): void => {
          // 重建会触发初始 onChange，仅在值真正变化时扇出，避免回环
          if (isOn !== this.allVisible) {
            const cb = this.onToggleVisible;
            if (cb !== undefined) {
              cb(isOn);
            }
          }
        })
      ToolIcon({ name: 'folder' })
      Text(this.group.name)
        .fontSize(DeskTheme.FONT_BODY)
        .fontWeight(FontWeight.Medium)
        .fontColor(DeskTheme.TEXT)
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .onClick((): void => { this.collapse(); })
      Text(this.count > 0 ? `${this.count}` : '空')
        .fontSize(9)
        .fontColor(DeskTheme.TEXT_DISABLED)
    }
    .width('100%')
    .height(24)
    .padding({ left: 16, right: 6 })
    .backgroundColor(DeskTheme.CHROME)
    .bindContextMenu(this.groupMenu, ResponseType.RightClick)
  }
}

@Component
struct TocTab {
  @Prop label: string = '';
  @Prop active: boolean = false;
  onTap: (() => void) | undefined = undefined;

  build() {
    Text(this.label)
      .fontSize(DeskTheme.FONT_CAPTION)
      .fontColor(this.active ? DeskTheme.TEXT : DeskTheme.TEXT_SUB)
      .fontWeight(this.active ? FontWeight.Medium : FontWeight.Normal)
      .height(22)
      .padding({ left: 14, right: 14 })
      .backgroundColor(this.active ? DeskTheme.PANEL : DeskTheme.CHROME)
      .border({
        width: { top: this.active ? 2 : 1, left: 1, right: 1 },
        color: {
          top: this.active ? DeskTheme.ACCENT : DeskTheme.DIVIDER_SOFT,
          left: DeskTheme.DIVIDER_SOFT,
          right: DeskTheme.DIVIDER_SOFT
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
export struct TocPanel {
  @Prop rows: LayerRow[] = [];
  @Prop groups: DeskLayerGroup[] = [];
  /** 选中行在 rows 里的下标；-1 = 未选 */
  @Prop selectedIndex: number = -1;
  @Prop sourceTab: boolean = false;
  @Prop frameName: string = '图层';
  onToggle: ((index: number, visible: boolean) => void) | undefined = undefined;
  onToggleAll: ((visible: boolean) => void) | undefined = undefined;
  onSelect: ((index: number) => void) | undefined = undefined;
  onCommand: ((cmd: string, index: number) => void) | undefined = undefined;
  onTab: ((source: boolean) => void) | undefined = undefined;
  onToggleGroup: ((groupId: number, visible: boolean) => void) | undefined = undefined;
  onGroupCommand: ((cmd: string, groupId: number) => void) | undefined = undefined;

  @State private frameExpanded: boolean = true;
  /** 折叠的组 id 黑名单（默认全展开，保持原扁平列表观感） */
  @State private collapsedIds: number[] = [];

  private allVisible(): boolean {
    if (this.rows.length === 0) {
      return false;
    }
    for (let i = 0; i < this.rows.length; i++) {
      if (!this.rows[i].visible) {
        return false;
      }
    }
    return true;
  }

  private visibleCount(): number {
    let n: number = 0;
    for (let i = 0; i < this.rows.length; i++) {
      if (this.rows[i].visible) {
        n++;
      }
    }
    return n;
  }

  /** 某组的成员（携带原始 rows 下标） */
  private membersOf(groupId: number): TocEntry[] {
    const out: TocEntry[] = [];
    for (let i = 0; i < this.rows.length; i++) {
      if (this.rows[i].groupId === groupId) {
        out.push(new TocEntry(this.rows[i], i));
      }
    }
    return out;
  }

  /** 未分组行（携带原始 rows 下标），列在所有分组之后 */
  private ungrouped(): TocEntry[] {
    const out: TocEntry[] = [];
    for (let i = 0; i < this.rows.length; i++) {
      if (this.rows[i].groupId === LayerRow.UNGROUPED_ID) {
        out.push(new TocEntry(this.rows[i], i));
      }
    }
    return out;
  }

  private groupAllVisible(groupId: number): boolean {
    const m: TocEntry[] = this.membersOf(groupId);
    if (m.length === 0) {
      return false;
    }
    for (let i = 0; i < m.length; i++) {
      if (!m[i].row.visible) {
        return false;
      }
    }
    return true;
  }

  private isCollapsed(groupId: number): boolean {
    return this.collapsedIds.indexOf(groupId) >= 0;
  }

  private toggleCollapse(groupId: number): void {
    const next: number[] = this.collapsedIds.slice();
    const at: number = next.indexOf(groupId);
    if (at >= 0) {
      next.splice(at, 1);
    } else {
      next.push(groupId);
    }
    this.collapsedIds = next;
  }

  private emitToggle(index: number, visible: boolean): void {
    const cb = this.onToggle;
    if (cb !== undefined) {
      cb(index, visible);
    }
  }

  private emitSelect(index: number): void {
    const cb = this.onSelect;
    if (cb !== undefined) {
      cb(index);
    }
  }

  private emitCommand(cmd: string, index: number): void {
    const cb = this.onCommand;
    if (cb !== undefined) {
      cb(cmd, index);
    }
  }

  private emitTab(source: boolean): void {
    const cb = this.onTab;
    if (cb !== undefined) {
      cb(source);
    }
  }

  private emitToggleGroup(groupId: number, visible: boolean): void {
    const cb = this.onToggleGroup;
    if (cb !== undefined) {
      cb(groupId, visible);
    }
  }

  private emitGroupCommand(cmd: string, groupId: number): void {
    const cb = this.onGroupCommand;
    if (cb !== undefined) {
      cb(cmd, groupId);
    }
  }

  private listByMenu(): MenuElement[] {
    return [
      { value: '按绘制顺序列出', action: (): void => { this.emitTab(false); } },
      { value: '按源列出', action: (): void => { this.emitTab(true); } }
    ];
  }

  @Builder
  rootMenu() {
    Menu() {
      MenuItem({ content: '新建分组' })
        .onClick((): void => { this.emitGroupCommand(DeskCmd.GROUP_NEW, -1); })
    }
  }

  build() {
    Column() {
      Row({ space: 3 }) {
        Text(this.sourceTab ? '按源列出' : '按绘制顺序列出')
          .fontSize(DeskTheme.FONT_CAPTION)
          .fontColor(DeskTheme.TEXT_SUB)
        Text('▾')
          .fontSize(8)
          .fontColor(DeskTheme.TEXT_SUB)
        Blank()
        Text(`${this.visibleCount()}/${this.rows.length}`)
          .fontSize(9)
          .fontColor(DeskTheme.TEXT_DISABLED)
      }
      .width('100%')
      .height(22)
      .padding({ left: 8, right: 8 })
      .backgroundColor(DeskTheme.CHROME)
      .bindMenu(this.listByMenu())

      Divider().color(DeskTheme.DIVIDER_SOFT).strokeWidth(1)

      Scroll() {
        Column() {
          // 数据框根节点
          Row({ space: 4 }) {
            Text(this.frameExpanded ? '▾' : '▸')
              .fontSize(9)
              .fontColor(DeskTheme.TEXT_SUB)
              .width(10)
              .onClick((): void => {
                this.frameExpanded = !this.frameExpanded;
              })
            Toggle({ type: ToggleType.Checkbox, isOn: this.allVisible() })
              .width(14)
              .height(14)
              .selectedColor(DeskTheme.ACCENT)
              .onChange((isOn: boolean): void => {
                const cb = this.onToggleAll;
                if (cb !== undefined) {
                  cb(isOn);
                }
              })
            ToolIcon({ name: 'dataFrame' })
            Text(this.frameName)
              .fontSize(DeskTheme.FONT_BODY)
              .fontWeight(FontWeight.Bold)
              .fontColor(DeskTheme.TEXT)
              .layoutWeight(1)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .width('100%')
          .height(24)
          .padding({ left: 4, right: 6 })
          .backgroundColor(DeskTheme.PANEL)
          .bindContextMenu(this.rootMenu, ResponseType.RightClick)

          if (this.frameExpanded) {
            // 分组（含空组）：组头 + 展开时的成员行
            ForEach(this.groups, (g: DeskLayerGroup) => {
              Column() {
                TocGroupRow({
                  group: g,
                  count: this.membersOf(g.id).length,
                  allVisible: this.groupAllVisible(g.id),
                  collapsed: this.isCollapsed(g.id),
                  onToggleVisible: (visible: boolean): void => { this.emitToggleGroup(g.id, visible); },
                  onToggleCollapse: (): void => { this.toggleCollapse(g.id); },
                  onCommand: (cmd: string): void => { this.emitGroupCommand(cmd, g.id); }
                })
                if (!this.isCollapsed(g.id)) {
                  ForEach(this.membersOf(g.id), (entry: TocEntry) => {
                    TocRow({
                      row: entry.row,
                      selected: entry.index === this.selectedIndex,
                      sourceTab: this.sourceTab,
                      indent: 34,
                      onToggle: (visible: boolean): void => { this.emitToggle(entry.index, visible); },
                      onSelect: (): void => { this.emitSelect(entry.index); },
                      onCommand: (cmd: string): void => { this.emitCommand(cmd, entry.index); }
                    })
                  }, (entry: TocEntry): string =>
                    `${entry.index}-${entry.row.name}-${entry.row.visible}-${entry.row.color}`
                    + `-${entry.row.engineIndex}-${entry.row.groupId}-${this.sourceTab}`)
                }
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
            }, (g: DeskLayerGroup): string =>
              `g|${g.id}-${g.name}-${this.membersOf(g.id).length}`
              + `-${this.groupAllVisible(g.id)}-${this.isCollapsed(g.id)}`)

            // 未分组行：直接挂在数据框下（ArcMap 惯例，无虚拟组头）
            ForEach(this.ungrouped(), (entry: TocEntry) => {
              TocRow({
                row: entry.row,
                selected: entry.index === this.selectedIndex,
                sourceTab: this.sourceTab,
                indent: 22,
                onToggle: (visible: boolean): void => { this.emitToggle(entry.index, visible); },
                onSelect: (): void => { this.emitSelect(entry.index); },
                onCommand: (cmd: string): void => { this.emitCommand(cmd, entry.index); }
              })
            }, (entry: TocEntry): string =>
              `${entry.index}-${entry.row.name}-${entry.row.visible}-${entry.row.color}`
              + `-${entry.row.engineIndex}-${entry.row.groupId}-${this.sourceTab}`)
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      .align(Alignment.TopStart)
      .backgroundColor(DeskTheme.PANEL)

      // 底部页签（ArcMap TOC 的 Display | Source）
      Row() {
        TocTab({ label: '显示', active: !this.sourceTab,
          onTap: (): void => { this.emitTab(false); } })
        TocTab({ label: '源', active: this.sourceTab,
          onTap: (): void => { this.emitTab(true); } })
        Blank()
      }
      .width('100%')
      .height(23)
      .backgroundColor(DeskTheme.CHROME)
      .border({ width: { top: 1 }, color: { top: DeskTheme.DIVIDER_SOFT } })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(DeskTheme.PANEL)
  }
}