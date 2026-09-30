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
import { PageData, PageKeys } from '../common/PageData';
import { Theme } from '../common/Theme';
import { Ui } from '../common/Ui';
import { LayerInfo, MapDocument, StyleOverride } from '../doc/DocModels';
import { DocumentListener, DocumentManager } from '../doc/DocumentManager';
import { FeatureDetailRequest } from '../map/FeaturePickController';
import { MapServices } from '../map/MapServices';
import { MapStyle } from '../map/MapStyle';
import { GdalVectorReader } from '../vector/GdalVectorReader';
import { VectorFormats } from '../vector/VectorFormats';
import { LayerLevelDialog } from '../components/LayerLevelDialog';
import { LayerStylePreview } from '../components/LayerStylePreview';
import { MapSourceList } from '../components/MapSourceList';
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
const DEFAULT_LABEL: string = '#FF212121';
const DEFAULT_LABEL_OUTLINE: string = '#FF000000';
/** 大小未知的展示文本（Android R.string.layer_info_size_unknown） */
const SIZE_UNKNOWN: string = '未知';

/**
 * 图层行快照：文档对象的可见性/样式字段是普通字段，改值不会触发 ArkUI 刷新，
 * 故每次同步都重建这份视图模型（ForEach 键含全部影响渲染的值，值变即重绘）。
 */
class LayerRow {
  name: string = '';
  path: string = '';
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
  labelField: string = '';
  labelColor: string = DEFAULT_LABEL;
  labelScale: number = 1;
  labelOutline: boolean = false;
  labelOutlineColor: string = DEFAULT_LABEL_OUTLINE;

  /** ForEach 键：任一影响显示的值变化即重建该行 */
  key(): string {
    return `${this.path}|${this.visible}|${this.selected}|${this.minLevel}|${this.fill}|${this.fillEnabled}`
      + `|${this.outline}|${this.outlineWidth}|${this.labelField}|${this.name}`;
  }
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
  /** MapSourceList 刷新令牌：切页签 / 子页返回时递增触发其重载 */
  @State sourceToken: number = 0;
  @State activeSource: string = '';

  private levelDialog: CustomDialogController | undefined = undefined;
  private sqlDialog: CustomDialogController | undefined = undefined;
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
    const doc: MapDocument | null = DocumentManager.getInstance().getDocument();
    const out: LayerRow[] = [];
    if (doc !== null) {
      if (this.tab === TAB_VECTOR) {
        for (let i = 0; i < doc.vectorLayers.length; i++) {
          out.push(this.buildRow(doc.vectorLayers[i], true));
        }
      } else if (this.tab === TAB_RASTER) {
        for (let i = 0; i < doc.rasterLayers.length; i++) {
          out.push(this.buildRow(doc.rasterLayers[i], false));
        }
      }
    }
    // 选中态清理：非矢量页签、或选中图层已被移除时不残留高亮（Android syncFromDocument 同）
    let selected: string = this.tab === TAB_VECTOR ? this.selectedPath : '';
    if (selected.length > 0 && !out.some((r: LayerRow): boolean => r.path === selected)) {
      selected = '';
    }
    this.selectedPath = selected;
    for (let i = 0; i < out.length; i++) {
      out[i].selected = out[i].path === selected && selected.length > 0;
    }
    this.rows = out;
    this.activeSource = DocumentManager.getInstance().activeBaseMap();
  }

  /** 行视图模型：样式预览色解析链与 Android drawStylePreview 同序 */
  private buildRow(info: LayerInfo, vector: boolean): LayerRow {
    const row: LayerRow = new LayerRow();
    const path: string = info.path ?? '';
    row.path = path;
    row.vector = vector;
    row.name = LayerManagePage.displayName(path, info.name ?? '');
    row.visible = info.visible;
    const ext: string = VectorFormats.extOf(path);
    row.sqlQueryable = vector && (ext === 'shp' || ext === 'gpkg');
    row.levelVisible = vector;
    row.minLevel = vector ? info.effectiveMinDisplayLevel() : -1;
    // 整层样式编辑开放范围与 Android onStyleClick 一致（dwg/dxf 只读不改样式）
    row.styleEditable = vector && (ext === 'shp' || ext === 'kml' || ext === 'kmz' || ext === 'gpkg');

    const style: StyleOverride | undefined = vector ? info.vectorStyle : undefined;
    let render: string[] = ['', ''];
    const layers = MapServices.instance.layers;
    if (vector && layers !== undefined) {
      render = layers.layerRenderColorsOf(path);
    }
    row.fill = LayerManagePage.firstOf(style === undefined ? undefined : style.fillColor,
      render.length > 0 ? render[0] : '');
    row.fillEnabled = !(style !== undefined && style.fillEnabled === false);
    row.outline = LayerManagePage.firstOf(style === undefined ? undefined : style.outlineColor,
      render.length > 1 ? render[1] : '');
    const width: number | undefined = style === undefined ? undefined : style.outlineWidth;
    row.outlineWidth = width === undefined ? 1 : width;
    const labelField: string | undefined = style === undefined ? undefined : style.labelField;
    row.labelField = labelField === undefined ? '' : labelField;
    row.labelColor = LayerManagePage.pick(LayerManagePage.firstOf(
      style === undefined ? undefined : style.labelColor, ''), DEFAULT_LABEL);
    const scale: number | undefined = style === undefined ? undefined : style.labelSize;
    row.labelScale = scale === undefined ? 1 : scale;
    row.labelOutline = style !== undefined && style.labelOutline === true;
    row.labelOutlineColor = LayerManagePage.pick(LayerManagePage.firstOf(
      style === undefined ? undefined : style.labelOutlineColor, ''), DEFAULT_LABEL_OUTLINE);
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
    if (this.tab !== TAB_VECTOR || this.selectedPath === row.path) {
      return;
    }
    this.selectedPath = row.path;
    this.sync();
  }

  private toggleVisible(row: LayerRow): void {
    DocumentManager.getInstance().update((doc: MapDocument): void => {
      const list: LayerInfo[] = row.vector ? doc.vectorLayers : doc.rasterLayers;
      for (let i = 0; i < list.length; i++) {
        if (list[i].path === row.path) {
          list[i].visible = !list[i].visible;
          break;
        }
      }
    });
    this.sync();
  }

  private async removeLayer(row: LayerRow): Promise<void> {
    const ok: boolean = await Ui.confirm('移除确认',
      `确定移除图层：${row.name} ？（仅从地图移除，不删除源文件）`, '移除');
    if (!ok) {
      return;
    }
    DocumentManager.getInstance().update((doc: MapDocument): void => {
      const list: LayerInfo[] = row.vector ? doc.vectorLayers : doc.rasterLayers;
      for (let i = 0; i < list.length; i++) {
        if (list[i].path === row.path) {
          list.splice(i, 1);
          break;
        }
      }
    });
    this.sync();
    Ui.toast('已从地图移除图层');
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
    camera.zoomToLayerExtent(row.path);
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
      : doc.findVectorLayer(row.path);
    if (info === undefined) {
      Ui.toast('图层未在文档中');
      return;
    }
    const req: FeatureDetailRequest = new FeatureDetailRequest();
    req.path = row.path;
    req.fid = -1;
    req.layerName = row.name;
    req.layerStyleMode = true;
    req.styleEditable = true;
    req.style = info.vectorStyle ?? new StyleOverride();
    // 初值回退链：文档样式在页面内优先，这里只给「地图实际渲染色」这一层兜底
    const layers = MapServices.instance.layers;
    if (layers !== undefined) {
      const render: string[] = layers.layerRenderColorsOf(row.path);
      req.fallbackFill = render.length > 0 ? render[0] : DEFAULT_SHAPE_FILL;
      req.fallbackOutline = render.length > 1 ? render[1] : DEFAULT_SHAPE_OUTLINE;
    } else {
      req.fallbackFill = DEFAULT_SHAPE_FILL;
      req.fallbackOutline = DEFAULT_SHAPE_OUTLINE;
    }
    // 复杂对象走交接槽（router params 只承载标量），与主地图页拾取弹详情同一条通道
    PageData.put(PageKeys.FEATURE_DETAIL, req);
    router.pushUrl({ url: 'pages/FeatureDetailPage' });
  }

  private openLevelDialog(row: LayerRow): void {
    const doc: MapDocument | null = DocumentManager.getInstance().getDocument();
    const info: LayerInfo | undefined = doc === null ? undefined : doc.findVectorLayer(row.path);
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
          this.writeUserLevel(row.path, level);
        },
        onResetAuto: (): void => {
          this.writeUserLevel(row.path, LayerInfo.UNSET_LEVEL);
          Ui.toast('已恢复自动计算级别');
        },
      }),
      customStyle: true,
      alignment: DialogAlignment.Center,
      autoCancel: true,
    });
    this.levelDialog.open();
  }

  private writeUserLevel(path: string, level: number): void {
    DocumentManager.getInstance().update((doc: MapDocument): void => {
      const info: LayerInfo | undefined = doc.findVectorLayer(path);
      if (info !== undefined) {
        info.userMinDisplayLevel = level;
      }
    });
    this.sync();
  }

  /** SQL 查询：可视化条件对话框 → 交主地图页的查询控制器执行并高亮 */
  private openSqlDialog(row: LayerRow): void {
    const fields: string[] = GdalVectorReader.fieldNames(row.path);
    this.sqlDialog = new CustomDialogController({
      builder: SqlQueryDialog({
        layerName: row.name,
        tableName: LayerManagePage.tableNameOf(row.path),
        fields: fields,
        onExecuteSql: (sql: string): void => {
          this.runQuery(row.path, sql);
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

  private runQuery(path: string, sql: string): void {
    const ctl = MapServices.instance.sql;
    if (ctl === undefined) {
      Ui.toast('地图未就绪，无法执行查询');
      return;
    }
    ctl.runQuery(path, sql);
    Ui.toastLong('查询已应用，返回地图查看高亮要素');
  }

  /** SQL 表名：OGR 对 shp 的图层命名即文件主名（gpkg 亦按主名预填，用户可在语句内改） */
  private static tableNameOf(path: string): string {
    const query: number = path.indexOf('?');
    const s: string = query > 0 ? path.substring(0, query) : path;
    const slash: number = Math.max(s.lastIndexOf('/'), s.lastIndexOf('\\'));
    return AppDirs.deriveBaseName(slash >= 0 ? s.substring(slash + 1) : s);
  }

  /** 图层信息：名称 / 类型 / 大小 / 坐标系 / 路径（Android onShowInfo 同字段） */
  private showInfo(row: LayerRow): void {
    const typeText: string = row.vector ? '矢量图层' : '栅格图层';
    const srsText: string = LayerManagePage.srsTextOf(row.path);
    const message: string = `名称：${row.name}\n\n类型：${typeText}\n\n大小：`
      + `${LayerManagePage.sizeText(row.path)}\n\n坐标系：${srsText}\n\n路径：${row.path}`;
    Ui.alert('图层信息', message);
  }

  /** 坐标系名：原生返回「名称\nproj4」，界面只取首行 */
  private static srsTextOf(path: string): string {
    const srs: string | null = path.length === 0 ? null : GdalVectorReader.layerSrs(path);
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
      return LayerManagePage.formatSize(stat.size);
    } catch (e) {
      AppLog.w(`取文件大小失败: ${path}`, `${e}`);
      return SIZE_UNKNOWN;
    }
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
                this.layerCard(row)
              }
            }, (row: LayerRow): string => row.key())
          }
          .width('100%')
          .layoutWeight(1)
          .scrollBar(BarState.Off)
          .padding({ left: Theme.PAD, right: Theme.PAD, top: Theme.GAP, bottom: Theme.PAD })
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
    return `${this.tabLabel(this.tab)}　${this.rows.length} 个`;
  }

  /** 顶栏动作：地图源页签的「添加」在列表内自带按钮，此处不重复放 */
  @Builder
  barActions() {
    if (this.tab !== TAB_MAP_SOURCE) {
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

  @Builder
  layerCard(row: LayerRow) {
    Row({ space: 10 }) {
      LayerStylePreview({
        raster: !row.vector,
        fill: row.fill,
        fillEnabled: row.fillEnabled,
        strokeColor: row.outline,
        strokeWidthValue: row.outlineWidth,
        labelField: row.labelField,
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
