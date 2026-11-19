// LayerManagePage.ets —— 图层管理页（对应 Android ui.dialog.LayerManageDialog）。
//
// Android 是覆盖在主地图上、可继续看到地图的 BottomSheet；鸿蒙侧同类面板做成全屏页会挡住地图，
// 但图层行操作密度高（预览 + 名称 + 5~6 个动作），对话框放不下，故仍做成 router 页，
// 「所见即所得」靠两条补偿：① 行内样式预览块按文档样式实时绘制；② 需要看地图的动作（缩放/查询）
// 直接作用到主地图页的控制器（MapServices），执行后返回地图即见结果。
// 三个页签与逐条行为对齐 Android：
//  · 矢量/栅格：行 = 样式预览 + 名称 + 动作组；地图源：直接复用 MapSourceList 组件（其自带添加按钮）。
//  · 样式预览可点（仅 shp/kml/kmz/gpkg 开放整层样式，dwg/dxf 提示不支持）；名称点击仅选中高亮。
//  · SQL 查询仅 shp/gpkg；级别可见性对所有矢量开放，按钮上回显生效级别。
//  · 移除仅从文档摘除图层，不删源文件（提示语与 Android 同）。
// 文档变更即时重载列表（Android registerDocumentChangeListener 于 onStart/onStop，此处 on/off 页面对称）。

import fs from '@ohos.file.fs';
import { router } from '@kit.ArkUI';
import { AppDirs } from '../common/AppDirs';
import { AppLog } from '../common/AppLog';
import { ColorHex } from '../common/ColorHex';
import { LayerFileDeleter } from '../common/LayerFileDeleter';
import { PageData, PageKeys } from '../common/PageData';
import { Theme } from '../common/Theme';
import { Ui } from '../common/Ui';
import { LayerGroupRecord, LayerInfo, MapDocument, StyleOverride } from '../doc/DocModels';
import { DocumentListener, DocumentManager } from '../doc/DocumentManager';
import { FeatureDetailRequest } from '../map/FeaturePickController';
import { MapServices } from '../map/MapServices';
import { MapStyle } from '../map/MapStyle';
import { GdalVectorReader } from '../vector/GdalVectorReader';
import { FeatureIcons } from '../vector/FeatureIcons';
import { VectorFormats } from '../vector/VectorFormats';
import { VectorMetaCache } from '../vector/VectorMetaCache';
import { LayerLevelDialog } from '../components/LayerLevelDialog';
import { LayerGroupDialog } from '../components/LayerGroupDialog';
import { LayerInfoDialog, LayerInfoItem } from '../components/LayerInfoDialog';
import { LayerStylePreview } from '../components/LayerStylePreview';
import { MapSourceList } from '../components/MapSourceList';
import { NameEditDialog } from '../components/NameEditDialog';
import { RemoveLayerDialog } from '../components/RemoveLayerDialog';
import { SqlQueryDialog } from '../components/SqlQueryDialog';
import { TitleBar } from '../components/TitleBar';
import { AddLayerParams } from './RouteParams';

/** 页签下标（与 Android TAB_VECTOR / TAB_RASTER / TAB_MAP_SOURCE 同序） */
const TAB_VECTOR: number = 0;
const TAB_RASTER: number = 1;
const TAB_MAP_SOURCE: number = 2;

/** 无样式覆盖时的面要素默认渲染色（与内核矢量默认样式一致，保证色块所见即所得） */
const DEFAULT_SHAPE_FILL: string = '#664A8FE3';
const DEFAULT_SHAPE_OUTLINE: string = '#FFFFFFFF';
/** 标注色 / 标注轮廓色未设置时的缺省色串（与要素详情页默认标注色一致） */
const DEFAULT_LABEL: string = '#FFFFFFFF';
const DEFAULT_LABEL_OUTLINE: string = '#FF000000';
/** 大小未知的展示文本（Android R.string.layer_info_size_unknown） */
const SIZE_UNKNOWN: string = '未知';

/**
 * 图层行快照：文档对象的可见性/样式字段是普通字段，改值不会触发 ArkUI 刷新，
 * 故每次同步都重建这份视图模型（ForEach 键含全部影响渲染的值，值变即重绘）。
 */
class LayerRow {
  /** 节头行（组头）还是图层行 */
  header: boolean = false;
  /** 组 id（-1 = 未分组虚拟节）；图层行同样携带，供 ForEach 键与移组回显 */
  groupId: number = LayerInfo.UNGROUPED_ID;
  /** 节头：组名 / 成员数 / 整组开关回显 / 折叠态 */
  groupName: string = '';
  count: number = 0;
  allVisible: boolean = true;
  collapsed: boolean = false;
  name: string = '';
  path: string = '';
  /** 数据集内要素类名（GDB）；空串为普通单图层文件 */
  layerName: string = '';
  vector: boolean = true;
  visible: boolean = true;
  /** 矢量页签内的单选高亮 */
  selected: boolean = false;
  /** 级别按钮上显示的生效级别，-1 不限制（不显数字） */
  minLevel: number = -1;
  levelVisible: boolean = false;
  sqlQueryable: boolean = false;
  styleEditable: boolean = false;
  // ── 样式预览绘制参数（已按「文档样式 > 实际渲染色 > 默认色」解析完）──
  fill: string = DEFAULT_SHAPE_FILL;
  fillEnabled: boolean = true;
  outline: string = DEFAULT_SHAPE_OUTLINE;
  outlineWidth: number = 1;
  /** 几何类型（0 点 / 1 线 / 2 面 / -1 未知）：预览线层画折线示例 */
  geomType: number = -1;
  /** 点层预览图标 key 与着色（着色同渲染口径：outlineColor 未设取线通道默认橙） */
  iconKey: string = FeatureIcons.DEFAULT_KEY;
  iconColor: string = '';
  labelField: string = '';
  /** 标注样本值（数据首条非空注记值）：预览示例文本，空则回退字段名 */
  labelText: string = '';
  labelColor: string = DEFAULT_LABEL;
  labelScale: number = 1;
  labelOutline: boolean = false;
  labelOutlineColor: string = DEFAULT_LABEL_OUTLINE;

  /** ForEach 键：任一影响显示的值变化即重建该行 */
  key(): string {
    if (this.header) {
      return `h|${this.groupId}|${this.groupName}|${this.count}|${this.allVisible}|${this.collapsed}`;
    }
    return `${this.path}|${this.visible}|${this.selected}|${this.minLevel}|${this.fill}|${this.fillEnabled}`
      + `|${this.outline}|${this.outlineWidth}|${this.labelField}|${this.labelText}|${this.labelColor}`
      + `|${this.labelScale}|${this.labelOutline}|${this.labelOutlineColor}|${this.name}|${this.groupId}`;
  }
}

/** 拖拽落盘用的显示节：组 id + 该节当前显示的图层行（不含组头） */
class DragSection {
  groupId: number = LayerInfo.UNGROUPED_ID;
  rows: LayerRow[] = [];
}

@Entry
@Component
struct LayerManagePage {
  /** 底部导航条避让高度（vp）：主窗口是全屏布局，列表末项要让开导航条 */
  @StorageProp('bottomInsetVp') bottomInset: number = 0;
  @State tab: number = TAB_VECTOR;
  @State rows: LayerRow[] = [];
  /** 矢量页签单选高亮路径（Android selectedVectorPath） */
  @State selectedPath: string = '';
  /** 单选高亮要素类名（GDB 同路径多图层时区分） */
  private selectedLayerName: string = '';
  /** MapSourceList 刷新令牌：切页签 / 子页返回时递增触发其重载 */
  @State sourceToken: number = 0;
  @State activeSource: string = '';
  /**
   * 折叠的分组 id 集合（含未分组虚拟节 -1；用数组而非 Set：@State 的 Set 变更不触发刷新）。
   * 与拍照的展开白名单相反：图层管理现状是全展开平铺，默认保持全展开。
   */
  @State collapsedIds: number[] = [];

  /** 拖拽排序状态：拖动期间行序由 onItemDragMove 就地维护，文档广播不得重建列表 */
  private dragging: boolean = false;
  private dragIndex: number = -1;
  private dragRow: LayerRow | undefined = undefined;

  private levelDialog: CustomDialogController | undefined = undefined;
  private sqlDialog: CustomDialogController | undefined = undefined;
  private infoDialog: CustomDialogController | undefined = undefined;
  private groupDialog: CustomDialogController | undefined = undefined;
  private moveDialog: CustomDialogController | undefined = undefined;
  private removeDialog: CustomDialogController | undefined = undefined;
  private docListener: DocumentListener | undefined = undefined;

  aboutToAppear(): void {
    const raw: Object = router.getParams();
    if (raw !== undefined && raw !== null) {
      const tab: number = (raw as Record<string, number>).tab ?? TAB_VECTOR;
      this.tab = tab === TAB_RASTER || tab === TAB_MAP_SOURCE ? tab : TAB_VECTOR;
    }
    this.docListener = (doc: MapDocument): void => {
      this.sync();
    };
    DocumentManager.getInstance().registerListener(this.docListener);
    this.sync();
  }

  aboutToDisappear(): void {
    DocumentManager.getInstance().unregisterListener(this.docListener);
  }

  onPageShow(): void {
    // 从导入页 / 样式页返回后重建：文档可能已被子页改写
    this.sourceToken += 1;
    this.sync();
  }

  // ── 列表同步 ────────────────────────────────────────────────────

  private sync(): void {
    // 拖动中不重建：行序暂由拖拽维护，落盘（commitDragOrder）后才按文档重排
    if (this.dragging) {
      return;
    }
    const doc: MapDocument | null = DocumentManager.getInstance().getDocument();
    const out: LayerRow[] = [];
    if (doc !== null && this.tab !== TAB_MAP_SOURCE) {
      const vector: boolean = this.tab === TAB_VECTOR;
      const list: LayerInfo[] = vector ? doc.vectorLayers : doc.rasterLayers;
      // 无图层且无组时维持空态提示；有组则始终列出（空组也要可管理）
      if (list.length > 0 || doc.groups.length > 0) {
        for (let i = 0; i < doc.groups.length; i++) {
          const g: LayerGroupRecord = doc.groups[i];
          const members: LayerInfo[] = LayerManagePage.inGroup(list, g.id);
          // 页签内只显示含本类型成员的组 + 完全空的组（空组两个页签都可管理）
          if (members.length === 0 && !LayerManagePage.isGroupEmpty(doc, g.id)) {
            continue;
          }
          out.push(this.headerRow(g.id, g.name, members));
          if (!this.isCollapsed(g.id)) {
            this.appendLayers(out, members, vector);
          }
        }
        const rest: LayerInfo[] = LayerManagePage.inGroup(list, LayerInfo.UNGROUPED_ID);
        out.push(this.headerRow(LayerInfo.UNGROUPED_ID, '未分组', rest));
        if (!this.isCollapsed(LayerInfo.UNGROUPED_ID)) {
          this.appendLayers(out, rest, vector);
        }
      }
    }
    // 选中态清理：非矢量页签、或选中图层已被移除时不残留高亮（Android syncFromDocument 同）
    const selected: string = this.tab === TAB_VECTOR ? this.selectedPath : '';
    const selectedLayer: string = this.tab === TAB_VECTOR ? this.selectedLayerName : '';
    if (selected.length > 0
      && !out.some((r: LayerRow): boolean => r.path === selected && r.layerName === selectedLayer)) {
      this.selectedPath = '';
      this.selectedLayerName = '';
    }
    for (let i = 0; i < out.length; i++) {
      out[i].selected = out[i].path === this.selectedPath && out[i].layerName === this.selectedLayerName
        && this.selectedPath.length > 0;
    }
    this.rows = out;
    this.activeSource = DocumentManager.getInstance().activeBaseMap();
  }

  private static inGroup(list: LayerInfo[], groupId: number): LayerInfo[] {
    const out: LayerInfo[] = [];
    for (let i = 0; i < list.length; i++) {
      if (list[i].groupId === groupId) {
        out.push(list[i]);
      }
    }
    return out;
  }

  /** 组在矢量 + 栅格两侧都无成员 */
  private static isGroupEmpty(doc: MapDocument, groupId: number): boolean {
    return LayerManagePage.inGroup(doc.vectorLayers, groupId).length === 0
      && LayerManagePage.inGroup(doc.rasterLayers, groupId).length === 0;
  }

  private headerRow(groupId: number, name: string, members: LayerInfo[]): LayerRow {
    const row: LayerRow = new LayerRow();
    row.header = true;
    row.groupId = groupId;
    row.groupName = name;
    row.count = members.length;
    row.collapsed = this.isCollapsed(groupId);
    let allVisible: boolean = members.length > 0;
    for (let i = 0; i < members.length; i++) {
      allVisible = allVisible && members[i].visible;
    }
    row.allVisible = allVisible;
    return row;
  }

  private appendLayers(out: LayerRow[], members: LayerInfo[], vector: boolean): void {
    // 矢量列表顶 = 最上层（doc 数组尾 = 压盖顶，倒序显示；栅格本批不参与排序，保持原序）
    if (vector) {
      for (let i = members.length - 1; i >= 0; i--) {
        out.push(this.buildRow(members[i], vector));
      }
      return;
    }
    for (let i = 0; i < members.length; i++) {
      out.push(this.buildRow(members[i], vector));
    }
  }

  private isCollapsed(groupId: number): boolean {
    return this.collapsedIds.indexOf(groupId) >= 0;
  }

  private toggleCollapse(groupId: number): void {
    const idx: number = this.collapsedIds.indexOf(groupId);
    if (idx >= 0) {
      this.collapsedIds.splice(idx, 1);
    } else {
      this.collapsedIds.push(groupId);
    }
    this.collapsedIds = this.collapsedIds.slice();
    this.sync();
  }

  // ── 拖拽排序（矢量页签；组纯显示分节，跨组拖动 = 移组 + 改序，组头不可拖）──

  /** 起拖：仅矢量图层行可拖；组头/栅格返回 undefined 取消。返回浮起卡片 builder */
  private handleDragStart(itemIndex: number): (() => void) | void {
    const row: LayerRow | undefined = this.rows[itemIndex];
    if (row === undefined || row.header || !row.vector || this.tab !== TAB_VECTOR) {
      return undefined;
    }
    this.dragging = true;
    this.dragIndex = itemIndex;
    this.dragRow = row;
    return (): void => {
      this.dragCard();
    };
  }

  /** 拖动中就地挪行（不落盘）：组头落点夹取到节内，折叠组头落点 = 该节显示顶部 */
  private handleDragMove(insertIndex: number): void {
    if (!this.dragging || insertIndex < 0 || insertIndex >= this.rows.length) {
      return;
    }
    const from: number = this.dragIndex;
    let to: number = insertIndex;
    const target: LayerRow = this.rows[to];
    if (target.header) {
      if (target.collapsed) {
        to = to > from ? to : to + 1;
      } else {
        const end: number = this.sectionEnd(to);
        to = to > from ? to : (from < end ? end - 1 : end);
      }
    }
    if (to === from || to < 0 || to >= this.rows.length) {
      return;
    }
    const moved: LayerRow[] = this.rows.splice(from, 1);
    this.rows.splice(to, 0, moved[0]);
    this.dragIndex = to;
  }

  /** 组头节尾（下一个组头下标，无则数组长度） */
  private sectionEnd(headerIndex: number): number {
    for (let i = headerIndex + 1; i < this.rows.length; i++) {
      if (this.rows[i].header) {
        return i;
      }
    }
    return this.rows.length;
  }

  /** 落点：成功按显示序落盘，失败回滚到文档序 */
  private handleDragDrop(isSuccess: boolean): void {
    if (!this.dragging) {
      return;
    }
    this.dragging = false;
    this.dragIndex = -1;
    this.dragRow = undefined;
    if (isSuccess) {
      this.commitDragOrder();
    } else {
      this.sync();
    }
  }

  /**
   * 显示序 → doc.vectorLayers：节倒序 × 节内行倒序 = 压盖序（数组尾 = 最上层）。
   * 折叠节保持旧成员相对序，拖入的行展开置顶；跨节行改写 groupId；未显示成员兜底置底。
   * 只改数组位置，一次 save → 监听器广播 → sync 下发 order，零新增持久化字段。
   */
  private commitDragOrder(): void {
    const doc: MapDocument | null = DocumentManager.getInstance().getDocument();
    if (doc === null) {
      this.sync();
      return;
    }
    const oldOrder: LayerInfo[] = doc.vectorLayers.slice();
    const byKey: Map<string, LayerInfo> = new Map<string, LayerInfo>();
    for (let i = 0; i < oldOrder.length; i++) {
      byKey.set(`${oldOrder[i].path ?? ''}|${oldOrder[i].layerName}`, oldOrder[i]);
    }
    const sections: DragSection[] = [];
    let current: DragSection | undefined = undefined;
    for (let i = 0; i < this.rows.length; i++) {
      const r: LayerRow = this.rows[i];
      if (r.header) {
        current = new DragSection();
        current.groupId = r.groupId;
        sections.push(current);
      } else if (current !== undefined) {
        current.rows.push(r);
      }
    }
    const reordered: LayerInfo[] = [];
    const placed: Set<string> = new Set<string>();
    let groupChanged: boolean = false;
    let expanded: boolean = false;
    for (let s = sections.length - 1; s >= 0; s--) {
      const sec: DragSection = sections[s];
      const displayed: LayerRow[] = sec.rows;
      if (this.isCollapsed(sec.groupId)) {
        for (let i = 0; i < oldOrder.length; i++) {
          const li: LayerInfo = oldOrder[i];
          if (li.groupId === sec.groupId) {
            reordered.push(li);
            placed.add(`${li.path ?? ''}|${li.layerName}`);
          }
        }
        if (displayed.length > 0) {
          const ci: number = this.collapsedIds.indexOf(sec.groupId);
          if (ci >= 0) {
            this.collapsedIds.splice(ci, 1);
            expanded = true;
          }
        }
      }
      for (let i = displayed.length - 1; i >= 0; i--) {
        const r: LayerRow = displayed[i];
        const key: string = `${r.path}|${r.layerName}`;
        const li: LayerInfo | undefined = byKey.get(key);
        if (li === undefined || placed.has(key)) {
          continue;
        }
        if (li.groupId !== sec.groupId) {
          li.groupId = sec.groupId;
          groupChanged = true;
        }
        reordered.push(li);
        placed.add(key);
      }
    }
    const orphans: LayerInfo[] = [];
    for (let i = 0; i < oldOrder.length; i++) {
      const li: LayerInfo = oldOrder[i];
      if (!placed.has(`${li.path ?? ''}|${li.layerName}`)) {
        orphans.push(li);
      }
    }
    for (let i = 0; i < orphans.length; i++) {
      reordered.splice(i, 0, orphans[i]);
    }
    if (expanded) {
      this.collapsedIds = this.collapsedIds.slice();
    }
    let same: boolean = !groupChanged && reordered.length === oldOrder.length;
    if (same) {
      for (let i = 0; i < reordered.length; i++) {
        if (reordered[i] !== oldOrder[i]) {
          same = false;
          break;
        }
      }
    }
    if (same) {
      this.sync();
      return;
    }
    doc.vectorLayers = reordered;
    AppLog.i('LayerManagePage', `拖拽排序落盘：${reordered.length} 层，移组=${groupChanged}`);
    DocumentManager.getInstance().save();
    this.sync();
  }

  /** 拖拽浮起卡片：样式色块 + 名称（行快照在起拖时定格） */
  @Builder
  dragCard() {
    Row({ space: 10 }) {
      Column()
        .width(18)
        .height(18)
        .borderRadius(4)
        .backgroundColor(this.dragRow !== undefined ? this.dragRow.fill : DEFAULT_SHAPE_FILL)
      Text(this.dragRow !== undefined ? this.dragRow.name : '')
        .fontSize(Theme.FONT)
        .fontColor(Theme.TEXT)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
    }
    .width('100%')
    .padding(12)
    .backgroundColor(Theme.CARD)
    .borderRadius(Theme.RADIUS)
    .opacity(0.9)
  }

  /** 行视图模型：样式预览色解析链与 Android drawStylePreview 同序 */
  private buildRow(info: LayerInfo, vector: boolean): LayerRow {
    const row: LayerRow = new LayerRow();
    const path: string = info.path ?? '';
    row.path = path;
    row.vector = vector;
    row.layerName = info.layerName;
    const base: string = LayerManagePage.displayName(path, info.name ?? '');
    row.name = info.layerName.length > 0 ? `${base} / ${info.layerName}` : base;
    row.visible = info.visible;
    row.groupId = info.groupId;
    row.sqlQueryable = vector && VectorFormats.sqlQueryable(path);
    row.levelVisible = vector;
    row.minLevel = vector ? info.effectiveMinDisplayLevel() : -1;
    // 整层样式编辑开放范围以能力主表为准（kml/kmz 自带样式，不开放整层样式编辑）
    row.styleEditable = vector && VectorFormats.styleEditable(path);

    const style: StyleOverride | undefined = vector ? info.vectorStyle : undefined;
    let render: string[] = ['', ''];
    const layers = MapServices.instance.layers;
    if (vector && layers !== undefined) {
      render = layers.layerRenderColorsOf(path, info.layerName);
    }
    row.fill = LayerManagePage.firstOf(style === undefined ? undefined : style.fillColor,
      render.length > 0 ? render[0] : '');
    row.fillEnabled = !(style !== undefined && style.fillEnabled === false);
    row.outline = LayerManagePage.firstOf(style === undefined ? undefined : style.outlineColor,
      render.length > 1 ? render[1] : '');
    const width: number | undefined = style === undefined ? undefined : style.outlineWidth;
    const geom: number = vector ? VectorMetaCache.geomTypeOf(info) : -1;
    row.geomType = geom;
    // 未加载（render 空）兜底：线层第二色取线通道默认橙，面描边默认白对线层是误导
    if (row.outline.length === 0) {
      row.outline = geom === 1 ? MapStyle.argbToHex(MapStyle.DEFAULT_LINE_COLOR) : DEFAULT_SHAPE_OUTLINE;
    }
    row.outlineWidth = width === undefined
      ? (geom === 1 ? MapStyle.DEFAULT_LINE_WIDTH : MapStyle.DEFAULT_OUTLINE_WIDTH) : width;
    row.iconKey = FeatureIcons.keyOf(style);
    const iconOutline: string = LayerManagePage.firstOf(
      style === undefined ? undefined : style.outlineColor, '');
    row.iconColor = iconOutline.length > 0 ? iconOutline : MapStyle.argbToHex(MapStyle.DEFAULT_LINE_COLOR);
    // 标注有效样式与加图入地图同口径（MapLayerController.addVectorLayerNative）：
    // KML 受 showKmlLabel 门控、字段缺省 Name、轮廓缺省开 + 白晕（白晕复用 DEFAULT_LABEL 白色）；
    // 非 KML 仅读文档显式值（轮廓缺省关、晕色缺省黑）
    const isKml: boolean = VectorFormats.isKml(path);
    const doc: MapDocument | null = DocumentManager.getInstance().getDocument();
    const showKmlLabel: boolean = doc === null ? true : doc.systemConfig.showKmlLabel;
    const userField: string = (style === undefined || style.labelField === undefined)
      ? '' : style.labelField.trim();
    row.labelField = (isKml && !showKmlLabel) ? '' :
      (isKml ? (userField.length > 0 ? userField : 'Name') : userField);
    row.labelColor = LayerManagePage.pick(LayerManagePage.firstOf(
      style === undefined ? undefined : style.labelColor, ''), DEFAULT_LABEL);
    const scale: number | undefined = style === undefined ? undefined : style.labelSize;
    row.labelScale = scale === undefined ? 1 : scale;
    row.labelOutline = style !== undefined && style.labelOutline !== undefined
      ? style.labelOutline : isKml;
    row.labelOutlineColor = LayerManagePage.pick(LayerManagePage.firstOf(
      style === undefined ? undefined : style.labelOutlineColor, ''),
      isKml ? DEFAULT_LABEL : DEFAULT_LABEL_OUTLINE);
    // 示例文本与地图渲染内容同口径：取数据首条非空注记值（指纹缓存），取不到回退字段名
    row.labelText = row.labelField.length > 0
      ? VectorMetaCache.labelSampleOf(path, info.layerName, row.labelField) : '';
    // 填充透明度单独设置时折进颜色（预览与 Android fillPaint.alpha 同效）
    const opacity: number | undefined = style === undefined ? undefined : style.fillOpacity;
    if (opacity !== undefined) {
      row.fill = LayerManagePage.applyOpacity(row.fill, opacity);
    }
    return row;
  }

  /** 文档名 + 实际加载扩展名（kmz 解压后文档名是压缩包名，需补 .kml） */
  static displayName(path: string, name: string): string {
    const ext: string = VectorFormats.extOf(path);
    if (ext.length === 0 || name.toLowerCase().endsWith(`.${ext}`)) {
      return name;
    }
    return `${name}.${ext}`;
  }

  /** 首个非空值：文档样式 > 实际渲染色 > 默认色 */
  private static firstOf(primary: string | undefined, secondary: string): string {
    if (primary !== undefined && primary.length > 0) {
      return primary;
    }
    if (secondary.length > 0) {
      return secondary;
    }
    return '';
  }

  /** firstOf 结果兜底默认值（默认值单列一处，避免行内三元式套叠） */
  private static pick(value: string, fallback: string): string {
    return value.length > 0 ? value : fallback;
  }

  /** 把 0~1 的填充透明度折进 '#AARRGGBB' 颜色串 */
  private static applyOpacity(hex: string, opacity: number): string {
    const clamped: number = Math.max(0, Math.min(1, opacity));
    const argb: number = ColorHex.parse(hex, ColorHex.parse(DEFAULT_SHAPE_FILL));
    const alpha: number = Math.round(clamped * 255);
    return MapStyle.argbToHex(ColorHex.withAlpha(argb, alpha));
  }

  private tabLabel(index: number): string {
    if (index === TAB_VECTOR) {
      return '矢量图层';
    }
    return index === TAB_RASTER ? '栅格图层' : '地图源';
  }

  private switchTab(index: number): void {
    if (this.tab === index) {
      return;
    }
    this.tab = index;
    this.sourceToken += 1;
    this.sync();
  }

  // ── 行动作 ──────────────────────────────────────────────────────

  /** 导入：走系统文件选择器页（Android 于对话框内直接起 OpenFileActivity，此处等价跳页） */
  private toImport(): void {
    // 不传页签：本页仍在路由栈上，返回时 onPageShow 重建列表、页签自然保持
    router.pushUrl({ url: 'pages/AddLayerPage', params: new AddLayerParams() });
  }

  /** 名称点击：仅选中高亮（Android 点名称不缩放，缩放另有按键） */
  private selectLayer(row: LayerRow): void {
    if (this.tab !== TAB_VECTOR
      || (this.selectedPath === row.path && this.selectedLayerName === row.layerName)) {
      return;
    }
    this.selectedPath = row.path;
    this.selectedLayerName = row.layerName;
    this.sync();
  }

  private toggleVisible(row: LayerRow): void {
    DocumentManager.getInstance().update((doc: MapDocument): void => {
      const list: LayerInfo[] = row.vector ? doc.vectorLayers : doc.rasterLayers;
      for (let i = 0; i < list.length; i++) {
        if (list[i].path === row.path && list[i].layerName === row.layerName) {
          list[i].visible = !list[i].visible;
          break;
        }
      }
    });
    this.sync();
  }

  private removeLayer(row: LayerRow): void {
    // 「同时删除图层文件」选项：源文件存在且无其他图层共享删除目标（同 GDB 要素类/同 gpkg 层/同压缩包 shp）才提供
    const doc: MapDocument | null = DocumentManager.getInstance().getDocument();
    const others: string[] = [];
    if (doc !== null) {
      const all: LayerInfo[] = doc.vectorLayers.concat(doc.rasterLayers);
      for (let i = 0; i < all.length; i++) {
        const p: string = all[i].path ?? '';
        if (p.length > 0 && !(p === row.path && all[i].layerName === row.layerName)) {
          others.push(p);
        }
      }
    }
    const offer: boolean = LayerFileDeleter.offerDelete(row.path, others);
    this.removeDialog = new CustomDialogController({
      builder: RemoveLayerDialog({
        layerName: row.name,
        offerDelete: offer,
        onConfirm: (deleteFile: boolean): void => {
          DocumentManager.getInstance().update((d: MapDocument): void => {
            const list: LayerInfo[] = row.vector ? d.vectorLayers : d.rasterLayers;
            for (let i = 0; i < list.length; i++) {
              if (list[i].path === row.path && list[i].layerName === row.layerName) {
                list.splice(i, 1);
                break;
              }
            }
          });
          this.sync();
          if (deleteFile) {
            LayerFileDeleter.deleteSource(row.path);
          }
          Ui.toast(deleteFile ? '已移除图层并删除源文件' : '已从地图移除图层');
        },
      }),
      customStyle: true,
      alignment: DialogAlignment.Center,
      autoCancel: true,
    });
    this.removeDialog.open();
  }

  // ── 分组动作 ────────────────────────────────────────────────────

  private openNewGroup(): void {
    this.groupDialog = new CustomDialogController({
      builder: NameEditDialog({
        title: '新建分组',
        label: '分组',
        placeholder: '请输入分组名称',
        onConfirmName: (name: string): void => {
          const id: number = DocumentManager.getInstance().addGroup(name);
          if (id < 0) {
            Ui.toast('新建分组失败');
            return;
          }
          this.sync();
          Ui.toast(`已新建分组：${name}`);
        },
      }),
      customStyle: true,
      alignment: DialogAlignment.Center,
      autoCancel: true,
    });
    this.groupDialog.open();
  }

  private openRenameGroup(row: LayerRow): void {
    this.groupDialog = new CustomDialogController({
      builder: NameEditDialog({
        title: '重命名分组',
        label: '分组',
        initialValue: row.groupName,
        placeholder: '请输入分组名称',
        onConfirmName: (name: string): void => {
          DocumentManager.getInstance().renameGroup(row.groupId, name);
          this.sync();
          Ui.toast('已重命名分组');
        },
      }),
      customStyle: true,
      alignment: DialogAlignment.Center,
      autoCancel: true,
    });
    this.groupDialog.open();
  }

  private async removeGroup(row: LayerRow): Promise<void> {
    const ok: boolean = await Ui.confirm('删除分组',
      `删除分组“${row.groupName}”后，组内图层不会被移除，将移到“未分组”。是否继续？`, '删除');
    if (!ok) {
      return;
    }
    DocumentManager.getInstance().removeGroup(row.groupId);
    const idx: number = this.collapsedIds.indexOf(row.groupId);
    if (idx >= 0) {
      this.collapsedIds.splice(idx, 1);
      this.collapsedIds = this.collapsedIds.slice();
    }
    this.sync();
    Ui.toast('已删除分组');
  }

  /** 整组显隐：扇出写成员 visible（含未分组虚拟节），渲染层不认组 */
  private toggleGroupVisible(row: LayerRow, visible: boolean): void {
    DocumentManager.getInstance().setGroupLayersVisible(row.groupId, visible);
    this.sync();
  }

  private openMoveGroup(row: LayerRow): void {
    const doc: MapDocument | null = DocumentManager.getInstance().getDocument();
    this.moveDialog = new CustomDialogController({
      builder: LayerGroupDialog({
        layerName: row.name,
        currentGroupId: row.groupId,
        groups: doc === null ? [] : doc.groups,
        onConfirmGroup: (groupId: number, newGroupName: string): void => {
          DocumentManager.getInstance().moveLayerToGroup(row.path, row.vector, groupId, newGroupName,
            row.layerName);
          this.sync();
        },
      }),
      customStyle: true,
      alignment: DialogAlignment.Center,
      autoCancel: true,
    });
    this.moveDialog.open();
  }

  /** 缩放到图层四至：相机在主地图页，故经登记表驱动，返回地图即见结果 */
  private zoomToLayer(row: LayerRow): void {
    const camera = MapServices.instance.camera;
    if (camera === undefined) {
      Ui.toast('地图未就绪，无法缩放');
      return;
    }
    if (row.path.length === 0) {
      Ui.toast('无法获取图层范围');
      return;
    }
    camera.zoomToLayerExtent(row.path, row.layerName);
    Ui.toast('已缩放，返回地图查看');
  }

  /** 整层样式编辑：复用要素详情页的图层样式模式（保存写 LayerInfo.vectorStyle 图层级字段） */
  private editLayerStyle(row: LayerRow): void {
    if (!row.styleEditable) {
      Ui.toast('该格式不支持修改样式');
      return;
    }
    const doc: MapDocument | null = DocumentManager.getInstance().getDocument();
    const info: LayerInfo | undefined = doc === null ? undefined
      : doc.findVectorLayer(row.path, row.layerName);
    if (info === undefined) {
      Ui.toast('图层未在文档中');
      return;
    }
    const req: FeatureDetailRequest = new FeatureDetailRequest();
    req.path = row.path;
    req.fid = -1;
    req.layerName = row.layerName.length > 0 ? row.layerName : row.name;
    req.layerStyleMode = true;
    req.styleEditable = true;
    req.geomType = VectorMetaCache.geomTypeOf(info);
    // 几何构成掩码：KML 层声明 wkbUnknown（geomType=-1），按要素采样出点/线/面节
    req.geomMask = GdalVectorReader.geomMaskOf(row.path, row.layerName);
    req.style = info.vectorStyle ?? new StyleOverride();
    // 初值回退链：文档样式在页面内优先，这里只给「地图实际渲染色」这一层兜底
    const layers = MapServices.instance.layers;
    // 未加载兜底：含线构成取线通道默认橙（面描边默认白对线层是误导）
    const hasLine: boolean = req.geomType === 1 || (req.geomMask & 2) !== 0;
    const outlineFallback: string = hasLine
      ? MapStyle.argbToHex(MapStyle.DEFAULT_LINE_COLOR) : DEFAULT_SHAPE_OUTLINE;
    if (layers !== undefined) {
      const render: string[] = layers.layerRenderColorsOf(row.path, row.layerName);
      req.fallbackFill = render.length > 0 && render[0].length > 0 ? render[0] : DEFAULT_SHAPE_FILL;
      req.fallbackOutline = render.length > 1 && render[1].length > 0 ? render[1] : outlineFallback;
    } else {
      req.fallbackFill = DEFAULT_SHAPE_FILL;
      req.fallbackOutline = outlineFallback;
    }
    // 复杂对象走交接槽（router params 只承载标量），与主地图页拾取弹详情同一条通道
    PageData.put(PageKeys.FEATURE_DETAIL, req);
    router.pushUrl({ url: 'pages/FeatureDetailPage' });
  }

  private openLevelDialog(row: LayerRow): void {
    const doc: MapDocument | null = DocumentManager.getInstance().getDocument();
    const info: LayerInfo | undefined = doc === null ? undefined
      : doc.findVectorLayer(row.path, row.layerName);
    if (info === undefined) {
      Ui.toast('图层未在文档中');
      return;
    }
    this.levelDialog = new CustomDialogController({
      builder: LayerLevelDialog({
        layerName: row.name,
        autoLevel: info.autoMinDisplayLevel,
        effectiveLevel: info.effectiveMinDisplayLevel(),
        initialLevel: info.userMinDisplayLevel >= 0 ? info.userMinDisplayLevel
          : (info.autoMinDisplayLevel >= 0 ? info.autoMinDisplayLevel : 0),
        onConfirmLevel: (level: number): void => {
          this.writeUserLevel(row.path, row.layerName, level);
        },
        onResetAuto: (): void => {
          this.writeUserLevel(row.path, row.layerName, LayerInfo.UNSET_LEVEL);
          Ui.toast('已恢复自动计算级别');
        },
      }),
      customStyle: true,
      alignment: DialogAlignment.Center,
      autoCancel: true,
    });
    this.levelDialog.open();
  }

  private writeUserLevel(path: string, layerName: string, level: number): void {
    DocumentManager.getInstance().update((doc: MapDocument): void => {
      const info: LayerInfo | undefined = doc.findVectorLayer(path, layerName);
      if (info !== undefined) {
        info.userMinDisplayLevel = level;
      }
    });
    this.sync();
  }

  /** SQL 查询：可视化条件对话框 → 交主地图页的查询控制器执行并高亮 */
  private openSqlDialog(row: LayerRow): void {
    const fields: string[] = GdalVectorReader.fieldNames(row.path, row.layerName);
    this.sqlDialog = new CustomDialogController({
      builder: SqlQueryDialog({
        layerName: row.name,
        tableName: LayerManagePage.tableNameOf(row.path, row.layerName),
        fields: fields,
        onExecuteSql: (sql: string): void => {
          this.runQuery(row.path, sql, row.layerName);
        },
        onClearResult: (): void => {
          const ctl = MapServices.instance.sql;
          if (ctl === undefined) {
            Ui.toast('地图未就绪');
            return;
          }
          ctl.clearSqlQuery();
          Ui.toast('已清除查询结果');
        },
      }),
      customStyle: true,
      alignment: DialogAlignment.Center,
      autoCancel: true,
    });
    this.sqlDialog.open();
  }

  private runQuery(path: string, sql: string, layerName: string = ''): void {
    const ctl = MapServices.instance.sql;
    if (ctl === undefined) {
      Ui.toast('地图未就绪，无法执行查询');
      return;
    }
    ctl.runQuery(path, sql, layerName);
    Ui.toastLong('查询已应用，返回地图查看高亮要素');
  }

  /** SQL 表名：GDB 用要素类名；其余 OGR 图层命名即文件主名（用户可在语句内改） */
  private static tableNameOf(path: string, layerName: string = ''): string {
    if (layerName.length > 0) {
      return layerName;
    }
    const query: number = path.indexOf('?');
    const s: string = query > 0 ? path.substring(0, query) : path;
    const slash: number = Math.max(s.lastIndexOf('/'), s.lastIndexOf('\\'));
    return AppDirs.deriveBaseName(slash >= 0 ? s.substring(slash + 1) : s);
  }

  /** 图层信息：名称 / 类型 / 大小 / 坐标系 / 路径各项独立成行（0.3.0.4 对齐 Android dialog_layer_info，每项可单独复制） */
  private showInfo(row: LayerRow): void {
    const items: LayerInfoItem[] = [];
    items.push(new LayerInfoItem('名称', row.name));
    if (row.layerName.length > 0) {
      items.push(new LayerInfoItem('要素类', row.layerName));
    }
    items.push(new LayerInfoItem('类型',
      row.vector ? LayerManagePage.geomTypeText(row.path, row.layerName) : '栅格图层'));
    items.push(new LayerInfoItem('大小', LayerManagePage.sizeText(row.path)));
    items.push(new LayerInfoItem('坐标系', LayerManagePage.srsTextOf(row.path, row.layerName)));
    items.push(new LayerInfoItem('路径', row.path));
    this.infoDialog = new CustomDialogController({
      builder: LayerInfoDialog({ items: items }),
      customStyle: true,
      alignment: DialogAlignment.Center,
      autoCancel: true,
    });
    this.infoDialog.open();
  }

  /** 矢量层几何子类型文案：点/线/面要素；混合几何（KML 常见）按构成列组合；未知回退「矢量图层」 */
  private static geomTypeText(path: string, layerName: string = ''): string {
    switch (VectorMetaCache.geomTypeOfPath(path, layerName)) {
      case 0:
        return '点要素';
      case 1:
        return '线要素';
      case 2:
        return '面要素';
      default: {
        const mask: number = GdalVectorReader.geomMaskOf(path, layerName);
        const parts: string[] = [];
        if ((mask & 1) !== 0) {
          parts.push('点');
        }
        if ((mask & 2) !== 0) {
          parts.push('线');
        }
        if ((mask & 4) !== 0) {
          parts.push('面');
        }
        return parts.length > 0 ? `${parts.join('/')}要素` : '矢量图层';
      }
    }
  }

  /** 坐标系名：原生返回「名称\nproj4」，界面只取首行 */
  private static srsTextOf(path: string, layerName: string = ''): string {
    const srs: string | null = path.length === 0 ? null : GdalVectorReader.layerSrs(path, layerName);
    if (srs === null || srs === undefined) {
      return '未知';
    }
    const first: string = srs.split('\n')[0].trim();
    return first.length > 0 ? first : '未知';
  }

  private static sizeText(path: string): string {
    if (path.length === 0) {
      return SIZE_UNKNOWN;
    }
    try {
      if (!fs.accessSync(path)) {
        return SIZE_UNKNOWN;
      }
      const stat: fs.Stat = fs.statSync(path);
      if (stat.isDirectory()) {
        return LayerManagePage.formatSize(LayerManagePage.dirSizeOf(path));
      }
      return LayerManagePage.formatSize(stat.size);
    } catch (e) {
      AppLog.w(`取文件大小失败: ${path}`, `${e}`);
      return SIZE_UNKNOWN;
    }
  }

  /** GDB 目录总大小（递归累加，失败按已统计部分返回） */
  private static dirSizeOf(dirPath: string): number {
    let total: number = 0;
    let names: string[] = [];
    try {
      names = fs.listFileSync(dirPath, { recursion: false });
    } catch (e) {
      return total;
    }
    for (let i = 0; i < names.length; i++) {
      const child: string = `${dirPath}/${names[i]}`;
      try {
        const st: fs.Stat = fs.statSync(child);
        total += st.isDirectory() ? LayerManagePage.dirSizeOf(child) : st.size;
      } catch (e) {
        continue;
      }
    }
    return total;
  }

  private static formatSize(size: number): string {
    if (size < 1024) {
      return `${size} B`;
    }
    const kb: number = size / 1024;
    if (kb < 1024) {
      return `${Ui.fixed(kb, 1)} KB`;
    }
    const mb: number = kb / 1024;
    if (mb < 1024) {
      return `${Ui.fixed(mb, 1)} MB`;
    }
    return `${Ui.fixed(mb / 1024, 2)} GB`;
  }

  build() {
    Column() {
      TitleBar({
        title: '图层管理',
        subtitle: this.barSubtitle(),
        // 必须用箭头函数包裹：直接传 this.barActions 是「未绑定的方法引用」，子组件里
        // this.actions() 执行时 this 指向 TitleBar，回调中 this.toImport 就成 undefined
        actions: (): void => {
          this.barActions();
        },
      })

      Row({ space: 8 }) {
        this.tabItem(TAB_VECTOR)
        this.tabItem(TAB_RASTER)
        this.tabItem(TAB_MAP_SOURCE)
      }
      .width('100%')
      .padding({ left: Theme.PAD, right: Theme.PAD, top: Theme.GAP })

      if (this.tab === TAB_MAP_SOURCE) {
        Column() {
          MapSourceList({
            refreshToken: this.sourceToken,
            emptyText: '暂无地图源',
            onActiveChanged: (name: string): void => {
              this.activeSource = name;
            },
          })
        }
        .layoutWeight(1)
        .width('100%')
        .padding({ left: Theme.PAD, right: Theme.PAD, top: Theme.GAP, bottom: Theme.PAD })
      } else {
        if (this.rows.length === 0) {
          Column() {
            Text(this.tab === TAB_VECTOR ? '暂无矢量图层' : '暂无栅格图层')
              .fontSize(Theme.FONT)
              .fontColor(Theme.TEXT_SUB)
            Text('点右上角「+ 导入」添加本地图层文件')
              .fontSize(Theme.FONT_SUB)
              .fontColor(Theme.TEXT_HINT)
              .margin({ top: Theme.GAP })
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          List({ space: Theme.GAP }) {
            ForEach(this.rows, (row: LayerRow): void => {
              ListItem() {
                if (row.header) {
                  this.groupCard(row)
                } else {
                  this.layerCard(row)
                }
              }
            }, (row: LayerRow): string => row.key())
          }
          .width('100%')
          .layoutWeight(1)
          .scrollBar(BarState.Off)
          .padding({ left: Theme.PAD, right: Theme.PAD, top: Theme.GAP, bottom: Theme.PAD })
          .editMode(this.tab === TAB_VECTOR)
          .onItemDragStart((event: ItemDragInfo, itemIndex: number): (() => void) | void => {
            return this.handleDragStart(itemIndex);
          })
          .onItemDragMove((event: ItemDragInfo, itemIndex: number, insertIndex: number): void => {
            this.handleDragMove(insertIndex);
          })
          .onItemDrop((event: ItemDragInfo, itemIndex: number, insertIndex: number,
            isSuccess: boolean): void => {
            this.handleDragDrop(isSuccess);
          })
        }
      }
    }
    .width('100%')
    .height('100%')
    .padding({ bottom: this.bottomInset })
    .backgroundColor(Theme.BG)
  }

  private barSubtitle(): string {
    if (this.tab === TAB_MAP_SOURCE) {
      return this.activeSource.length > 0 ? `当前底图：${this.activeSource}` : '当前未选择底图';
    }
    return `${this.tabLabel(this.tab)}　${this.rows.filter((r: LayerRow): boolean => !r.header).length} 个`;
  }

  /** 顶栏动作：地图源页签的「添加」在列表内自带按钮，此处不重复放 */
  @Builder
  barActions() {
    if (this.tab !== TAB_MAP_SOURCE) {
      Row({ space: 8 }) {
        Text('新建分组')
          .fontSize(Theme.FONT_SUB)
          .fontColor(Theme.TEXT_ON_DARK)
          .height(30)
          .padding({ left: 12, right: 12 })
          .backgroundColor('#33FFFFFF')
          .borderRadius(15)
          .onClick((): void => {
            this.openNewGroup();
          })
        Text('+ 导入')
          .fontSize(Theme.FONT)
          .fontColor(Theme.TEXT_ON_DARK)
          .height(30)
          .padding({ left: 12, right: 12 })
          .backgroundColor('#33FFFFFF')
          .borderRadius(15)
          .onClick((): void => {
            this.toImport();
          })
      }
    }
  }

  @Builder
  tabItem(index: number) {
    Text(this.tabLabel(index))
      .fontSize(Theme.FONT)
      .fontColor(this.tab === index ? Theme.TEXT_ON_DARK : Theme.TEXT_SUB)
      .textAlign(TextAlign.Center)
      .height(34)
      .layoutWeight(1)
      .backgroundColor(this.tab === index ? Theme.PRIMARY : Theme.SUBTLE)
      .borderRadius(Theme.RADIUS)
      .onClick((): void => {
        this.switchTab(index);
      })
  }

  /** 组头节：折叠箭头 + 组名 + 计数 + 整组显隐开关；真实组另有改名/删组（照 PhotoPage.groupCard） */
  @Builder
  groupCard(row: LayerRow) {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(16)
          .fontColor([Theme.TEXT_SUB])
          .rotate({ angle: row.collapsed ? 0 : 90 })

        Column({ space: 2 }) {
          Text(row.groupName)
            .fontSize(Theme.FONT)
            .fontColor(Theme.TEXT)
            .fontWeight(FontWeight.Medium)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(row.count > 0 ? `${row.count} 个图层` : '无图层')
            .fontSize(Theme.FONT_SUB)
            .fontColor(Theme.TEXT_SUB)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Toggle({ type: ToggleType.Switch, isOn: row.allVisible })
          .selectedColor(Theme.PRIMARY)
          .enabled(row.count > 0)
          .onChange((v: boolean): void => {
            // 节重建时 Toggle 会按初值回调一次，与当前值相同不写库
            if (v !== row.allVisible) {
              this.toggleGroupVisible(row, v);
            }
          })
      }
      .width('100%')
      .onClick((): void => {
        this.toggleCollapse(row.groupId);
      })

      if (row.groupId !== LayerInfo.UNGROUPED_ID) {
        Flex({ wrap: FlexWrap.Wrap }) {
          this.groupChip('改名', Theme.PRIMARY_DARK, (): void => {
            this.openRenameGroup(row);
          })
          this.groupChip('删组', Theme.DANGER, (): void => {
            this.removeGroup(row);
          })
        }
        .width('100%')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(10)
    .backgroundColor(Theme.SUBTLE)
    .borderRadius(Theme.RADIUS)
  }

  /** 组头内的药丸：卡片底是 SUBTLE，药丸用 CARD 底区分（actionChip 的 SUBTLE 底会融底） */
  @Builder
  groupChip(label: string, color: string, onTap: () => void) {
    Text(label)
      .fontSize(Theme.FONT_SUB)
      .fontColor(color)
      .textAlign(TextAlign.Center)
      .height(26)
      .padding({ left: 8, right: 8 })
      .backgroundColor(Theme.CARD)
      .borderRadius(6)
      .margin({ right: 6, top: 6 })
      .onClick((): void => {
        onTap();
      })
  }

  @Builder
  layerCard(row: LayerRow) {
    Row({ space: 10 }) {
      LayerStylePreview({
        raster: !row.vector,
        fill: row.fill,
        fillEnabled: row.fillEnabled,
        strokeColor: row.outline,
        strokeWidthValue: row.outlineWidth,
        geomType: row.geomType,
        iconKey: row.iconKey,
        iconColor: row.iconColor,
        labelField: row.labelField,
        labelText: row.labelText,
        labelColor: row.labelColor,
        labelScale: row.labelScale,
        labelOutline: row.labelOutline,
        labelOutlineColor: row.labelOutlineColor,
        onTap: (): void => {
          this.editLayerStyle(row);
        },
      })

      Column({ space: 6 }) {
        Text(row.name)
          .fontSize(Theme.FONT)
          .fontColor(row.selected ? Theme.PRIMARY_DARK : Theme.TEXT)
          .fontWeight(row.selected ? FontWeight.Bold : FontWeight.Normal)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .onClick((): void => {
            this.selectLayer(row);
          })

        Flex({ wrap: FlexWrap.Wrap }) {
          if (row.sqlQueryable) {
            this.actionChip('SQL', Theme.PRIMARY_DARK, (): void => {
              this.openSqlDialog(row);
            })
          }
          if (row.levelVisible) {
            this.levelChip(row)
          }
          this.actionChip('缩放', Theme.TEXT_SUB, (): void => {
            this.zoomToLayer(row);
          })
          this.actionChip('分组', Theme.TEXT_SUB, (): void => {
            this.openMoveGroup(row);
          })
          this.actionChip(row.visible ? '显示' : '隐藏',
            row.visible ? Theme.OK : Theme.TEXT_HINT, (): void => {
            this.toggleVisible(row);
          })
          this.actionChip('信息', Theme.TEXT_SUB, (): void => {
            this.showInfo(row);
          })
          this.actionChip('移除', Theme.DANGER, (): void => {
            this.removeLayer(row);
          })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding(12)
    .backgroundColor(Theme.CARD)
    .borderRadius(Theme.RADIUS)
  }

  @Builder
  actionChip(label: string, color: string, onTap: () => void) {
    Text(label)
      .fontSize(Theme.FONT_SUB)
      .fontColor(color)
      .textAlign(TextAlign.Center)
      .height(26)
      .padding({ left: 8, right: 8 })
      .backgroundColor(Theme.SUBTLE)
      .borderRadius(6)
      // 间距由子项 margin 给（Flex 的 space 需 LengthMetrics，换边距更直白）
      .margin({ right: 6, top: 6 })
      .onClick((): void => {
        onTap();
      })
  }

  /** 级别按键：文字 + 生效级别数字角标（不限制时无角标，与 Android 徽标同义） */
  @Builder
  levelChip(row: LayerRow) {
    Row({ space: 3 }) {
      Text('级别')
        .fontSize(Theme.FONT_SUB)
        .fontColor(Theme.TEXT_SUB)
      if (row.minLevel >= 0) {
        Text(`${row.minLevel}`)
          .fontSize(10)
          .fontColor(Theme.TEXT_ON_DARK)
          .textAlign(TextAlign.Center)
          .width(16)
          .height(16)
          .backgroundColor(Theme.PRIMARY)
          .borderRadius(8)
      }
    }
    .height(26)
    .padding({ left: 8, right: 8 })
    .backgroundColor(Theme.SUBTLE)
    .borderRadius(6)
    .margin({ right: 6, top: 6 })
    .onClick((): void => {
      this.openLevelDialog(row);
    })
  }
}
