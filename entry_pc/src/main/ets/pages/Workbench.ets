// Workbench.ets —— 桌面端主页面：ArcMap 式工作台（菜单 / 双工具条 / 内容表 / 地图 / 属性表 / 状态栏）。
//
// 结构对齐 ArcMap 10.x：
//   系统标题栏     —— 工程名经 setWindowTitle 写入，不自绘第二条（实测自绘会重叠）；
//   菜单栏         —— 文件/编辑/视图/插入/选择/地理处理/自定义/窗口/帮助；
//   标准工具条     —— 新建/打开/保存（待接工程文档）、添加数据、比例尺下拉；
//   工具工具条     —— 选择/平移/放大/缩小 | 全图/上一视图/下一视图 | 识别/量测/清除选择 | TOC/属性表；
//   内容表（左）   —— 数据框根 + 图层树（复选框/符号/右键菜单）+ 显示|源 页签；
//   地图（中）     —— 引擎视口 + 鼠标增强层；
//   识别结果（右） —— 点要素出字段值清单 + 青色高亮；
//   属性表（下）   —— OGR SQL 分页网格，点记录高亮并缩放至要素；
//   状态栏         —— 提示 / 光标坐标（单位可切）/ 比例尺 1:N / 级别 / 模式 / 工具。
//
// 数据面：添加数据走系统选择器 → 拷沙箱 → GDAL 读四至/字段 → 引擎上图，全是真功能。
// 工程文档（DocumentManager）仍在 entry 模块，HAP 之间不能互引，故「新建/打开/保存」暂禁用，
// 待业务层下沉 HSP 后接入；图层清单已在内存里按 ArcMap 数据框语义组织，届时只换持久化来源。
import { bundleManager, common } from '@kit.AbilityKit';
import { picker } from '@kit.CoreFileKit';
import { window } from '@kit.ArkUI';
import fs from '@ohos.file.fs';
import { Camera, FeatureGeometry, NativeLayerInfo, NativeMapView, ViewMode } from '@zys/globecore';
import { DeskDirs } from '../common/DeskDirs';
import { DeskFormats, DeskImportResult, DeskImporter } from '../common/DeskImporter';
import { DeskLog } from '../common/DeskLog';
import { AttrField, CoordUnit, DeskCmd, DeskLayerGroup, DeskTheme, DeskTool, GeomKind, LayerRow,
  LayerSpace, TablePage, toolLabel } from '../common/DeskTheme';
import { DeskVector } from '../common/DeskVector';
import { AttributeTable } from '../desktop/AttributeTable';
import { DeskGotoDialog, DeskGroupPickDialog, DeskNameDialog } from '../desktop/DeskGroupDialogs';
import { DockPanel } from '../desktop/DockPanel';
import { IdentifyPanel } from '../desktop/IdentifyPanel';
import { LayerPropsPanel } from '../desktop/LayerPropsPanel';
import { MapCanvas, ViewInfo } from '../desktop/MapCanvas';
import { MenuBar } from '../desktop/MenuBar';
import { StatusBar } from '../desktop/StatusBar';
import { TocPanel } from '../desktop/TocPanel';
import { ToolBar } from '../desktop/ToolBar';

/** 内置在线底图（与手机端 DocumentManager 的无 Token 图源同源） */
const URL_VECTOR: string =
  'https://webrd0{rand=1,2,3,4}.is.autonavi.com/appmaptile?lang=zh_cn&size=1&scale=1&style=8&x={x}&y={y}&z={z}';
const URL_IMAGE: string =
  'https://webst0{rand=1,2,3,4}.is.autonavi.com/appmaptile?style=6&x={x}&y={y}&z={z}';
const BASE_MAX_LEVEL: number = 18;
/** 默认视野：山西浑源一带（与示例工程同域） */
const HOME_LAT: number = 39.7015;
const HOME_LON: number = 113.6841;
const HOME_ALT_M: number = 60000;
/** 属性表每页记录数 */
const PAGE_SIZE: number = 200;
/** 视图历史栈上限（ArcMap 的上一视图/下一视图） */
const HISTORY_MAX: number = 60;
/** 视图静止判定：最后一次回抛后这么多毫秒无变化即记一笔历史 */
const SETTLE_MS: number = 500;

@Entry
@Component
struct Workbench {
  // ── 外壳状态 ──
  @State private versionName: string = '';
  @State private projectName: string = '无标题';
  @State private activeTool: DeskTool = DeskTool.SELECT;
  @State private leftVisible: boolean = true;
  @State private rightVisible: boolean = false;
  @State private bottomVisible: boolean = false;
  @State private sourceTab: boolean = false;
  // 停靠尺寸自管（vp）：RowSplit/ColumnSplit 的分隔条位置只按子件初始份额定一次，
  // 停靠显隐或窗口缩放后不复算（实测左栏被裁、右侧留死区），故改普通 Row/Column + 手拖分隔条。
  @State private leftWidthVp: number = 260;
  @State private rightWidthVp: number = 300;
  @State private bottomHeightVp: number = 220;
  @State private message: string = '正在初始化地图…';
  @State private hint: string = '';
  @State private busy: boolean = false;

  // ── 地图读数（由 MapCanvas 回抛后格式化）──
  @State private wheelUpZoomsIn: boolean = true;
  @State private is3D: boolean = false;
  @State private coordUnit: CoordUnit = CoordUnit.DEG;
  @State private coordText: string = '--';
  @State private scaleText: string = '--';
  @State private scaleReady: boolean = false;
  @State private level: number = 0;
  @State private canBack: boolean = false;
  @State private canForward: boolean = false;

  // ── 图层 / 识别 / 属性表 ──
  @State private layers: LayerRow[] = [];
  @State private selectedLayer: number = -1;
  @State private idLayerName: string = '';
  @State private idFid: number = -1;
  @State private idGeomText: string = '';
  @State private idFields: AttrField[] = [];
  @State private tableLayer: number = -1;
  @State private tablePage: TablePage = new TablePage();
  @State private tableFid: number = -1;
  @State private tableSubLayers: string[] = [];
  @State private tableSubLayer: string = '';

  // ── 图层属性面板 ──
  @State private propsOpen: boolean = false;
  @State private propsIndex: number = -1;
  @State private propsRow: LayerRow = new LayerRow('', LayerSpace.VECTOR, -1, true);
  @State private propsFields: string[] = [];
  @State private propsSrs: string = '';
  @State private propsFormat: string = '';
  @State private propsSize: string = '';

  // ── 图层分组（PC 端仅内存态，无持久化）──
  @State private groups: DeskLayerGroup[] = [];
  /** 命名面板：0=关，1=新建组，2=重命名组 */
  @State private nameDialogMode: number = 0;
  @State private nameDialogInitial: string = '';
  /** 重命名/删除目标组 id */
  private groupTargetId: number = -1;
  /** 移组面板：目标图层在 layers 里的下标；-1=关 */
  @State private moveDialogIndex: number = -1;
  /** 转到 XY 面板：开合 + 打开时的相机现值（作输入框初值） */
  @State private gotoOpen: boolean = false;
  @State private gotoLat: number = 0;
  @State private gotoLon: number = 0;

  private canvas: MapCanvas | undefined = undefined;
  /** 高亮叠加层索引（与矢量层共享索引空间，noPick 不参与拾取） */
  private hiliteIndex: number = -1;
  private lastInfo: ViewInfo | undefined = undefined;
  private history: Camera[] = [];
  private historyPos: number = -1;
  /** 历史前进/后退期间抑制记录，否则会把目标视图又压一笔 */
  private navigating: boolean = false;
  private settleTimer: number = -1;
  /** 分隔条拖拽起点尺寸（vp） */
  private dragBase: number = 0;
  /** 矢量层计数（分配符号色用） */
  private vectorCount: number = 0;

  aboutToAppear(): void {
    bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION)
      .then((info: bundleManager.BundleInfo): void => {
        this.versionName = info.versionName;
      }, (e: Error): void => {
        DeskLog.w(`读版本号失败: ${e}`);
      });
    this.applyWindowTitle();
  }

  aboutToDisappear(): void {
    if (this.settleTimer >= 0) {
      clearTimeout(this.settleTimer);
      this.settleTimer = -1;
    }
  }

  /** 工程名写进系统标题栏（2in1 的窗控三键与边缘缩放由系统给，自绘只会重复） */
  private applyWindowTitle(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    window.getLastWindow(ctx).then((win: window.Window): void => {
      win.setWindowTitle(`调查宝 - ${this.projectName}`).then((): void => {
      }, (e: Error): void => {
        DeskLog.w(`setWindowTitle 失败: ${e}`);
      });
    }, (e: Error): void => {
      DeskLog.w(`取窗口失败: ${e}`);
    });
  }

  // ── 地图接线 ──

  private engine(): NativeMapView | undefined {
    const canvas = this.canvas;
    return canvas === undefined ? undefined : canvas.engine();
  }

  private onCanvasReady(canvas: MapCanvas): void {
    this.canvas = canvas;
    const view = canvas.engine();
    if (view === undefined) {
      this.message = '地图引擎创建失败';
      return;
    }
    this.attachBaseLayers(view);
    // 高亮叠加层先建（常驻，靠覆盖式更新清空），noPick 保证拾取不会被高亮自己挡住
    this.hiliteIndex = view.addOverlayLayer(DeskVector.highlightStyle());
    if (this.hiliteIndex >= 0) {
      view.setOverlayNoPick(this.hiliteIndex, true);
    }
    view.setOnTapListener((x: number, y: number): void => {
      this.onMapTap(x, y);
    });
    canvas.moveTo(HOME_LAT, HOME_LON, HOME_ALT_M);
    this.message = `就绪：${this.layers.length} 个底图图源（在线底图需联网）｜点「添加数据」加载 SHP/GPKG/KML/GeoTIFF`;
  }

  private attachBaseLayers(view: NativeMapView): void {
    const vectorName: string = '高德矢量';
    const imageName: string = '高德影像';
    view.addTileLayer(DeskDirs.tileDir(vectorName), URL_VECTOR, BASE_MAX_LEVEL, false);
    view.addTileLayer(DeskDirs.tileDir(imageName), URL_IMAGE, BASE_MAX_LEVEL, true);
    view.setLayerVisible(1, false);
    const rows: LayerRow[] = [];
    rows.push(new LayerRow(vectorName, LayerSpace.TILE, 0, true, '', GeomKind.TILE, 0xFF6FA8DC));
    rows.push(new LayerRow(imageName, LayerSpace.TILE, 1, false, '', GeomKind.TILE, 0xFF6FA8DC));
    this.layers = rows;
  }

  /** 地图点击：放大/缩小工具以点击点为锚缩放；选择/识别工具走拾取 */
  private onMapTap(xPx: number, yPx: number): void {
    const canvas = this.canvas;
    const view = this.engine();
    if (canvas === undefined || view === undefined) {
      return;
    }
    if (this.activeTool === DeskTool.ZOOM_IN) {
      this.recordHistory();
      canvas.zoomAtScreenPx(1.6, xPx, yPx);
      this.message = '放大（点击锚点）';
      return;
    }
    if (this.activeTool === DeskTool.ZOOM_OUT) {
      this.recordHistory();
      canvas.zoomAtScreenPx(1 / 1.6, xPx, yPx);
      this.message = '缩小（点击锚点）';
      return;
    }
    if (this.activeTool === DeskTool.PAN || this.activeTool === DeskTool.MEASURE) {
      return;
    }
    const hit = view.pickVector(xPx, yPx);
    if (hit === undefined) {
      this.clearSelection();
      this.message = '未命中要素（点击矢量要素可识别属性）';
      return;
    }
    let index: number = -1;
    for (let i = 0; i < this.layers.length; i++) {
      const row: LayerRow = this.layers[i];
      if (row.space === LayerSpace.VECTOR && row.engineIndex === hit.layerIndex) {
        index = i;
        break;
      }
    }
    if (index < 0) {
      this.message = `命中叠加层 ${hit.layerIndex}（非数据图层）`;
      return;
    }
    this.identifyFeature(index, hit.fid);
  }

  /** 识别：按 FID 回取全字段 + 画青色高亮 + 开右侧结果面板 */
  private identifyFeature(index: number, fid: number): void {
    const view = this.engine();
    if (view === undefined || index < 0 || index >= this.layers.length) {
      return;
    }
    const row: LayerRow = this.layers[index];
    const json: string | null = DeskVector.featureAttributes(row.path, fid);
    const fields: AttrField[] = DeskVector.attributesOf(json);
    this.selectedLayer = index;
    this.idLayerName = row.name;
    this.idFid = fid;
    this.idFields = fields;
    this.tableFid = fid;
    const geom: FeatureGeometry | undefined = view.featureGeometry(row.engineIndex, fid);
    this.idGeomText = geom === undefined ? '' : Workbench.geomLabel(geom.type);
    this.drawHighlight(row.engineIndex, fid, geom);
    this.rightVisible = true;
    this.message = fields.length > 0
      ? `识别：${row.name} · FID ${fid} · ${fields.length} 个字段`
      : `识别：${row.name} · FID ${fid}（属性回取为空，检查数据是否可读）`;
  }

  private static geomLabel(type: number): string {
    switch (type) {
      case 0: return '点';
      case 1: return '线';
      case 2: return '面';
      default: return '';
    }
  }

  /** 覆盖式更新常驻高亮层；geom 为空即清空 */
  private drawHighlight(layerIndex: number, fid: number, geom: FeatureGeometry | undefined): void {
    const view = this.engine();
    if (view === undefined || this.hiliteIndex < 0) {
      return;
    }
    if (geom === undefined || geom.lonlat.length === 0) {
      view.updateOverlayPoints(this.hiliteIndex, []);
      return;
    }
    const fids: number[] = [fid];
    if (geom.type === 0) {
      view.updateOverlayPoints(this.hiliteIndex, geom.lonlat, fids);
    } else if (geom.type === 1) {
      view.updateOverlayLines(this.hiliteIndex, geom.lonlat, geom.ringCounts, fids);
    } else {
      view.updateOverlayPolygons(this.hiliteIndex, geom.lonlat, geom.ringCounts,
        geom.ringsPerFeature, fids);
    }
  }

  private clearSelection(): void {
    const view = this.engine();
    if (view !== undefined && this.hiliteIndex >= 0) {
      view.updateOverlayPoints(this.hiliteIndex, []);
    }
    this.idFid = -1;
    this.idFields = [];
    this.idLayerName = '';
    this.idGeomText = '';
    this.tableFid = -1;
  }

  // ── 视图读数与历史 ──

  private onViewInfo(info: ViewInfo): void {
    this.lastInfo = info;
    this.refreshReadouts();
    if (this.settleTimer >= 0) {
      clearTimeout(this.settleTimer);
    }
    this.settleTimer = setTimeout((): void => {
      this.settleTimer = -1;
      this.recordHistory();
    }, SETTLE_MS);
  }

  private refreshReadouts(): void {
    const info = this.lastInfo;
    if (info === undefined) {
      return;
    }
    const lon: number = info.hasCursor ? info.cursorLon : info.centerLon;
    const lat: number = info.hasCursor ? info.cursorLat : info.centerLat;
    const text: string = DeskVector.coordText(lon, lat, this.coordUnit);
    if (text !== this.coordText) {
      this.coordText = text;
    }
    const scale: string = DeskVector.scaleText(info.mpp);
    if (scale !== this.scaleText) {
      this.scaleText = scale;
    }
    const ready: boolean = info.mpp > 0;
    if (ready !== this.scaleReady) {
      this.scaleReady = ready;
    }
    if (Math.abs(info.level - this.level) > 0.01) {
      this.level = info.level;
    }
  }

  /** 记一笔视图历史（静止后自动调；导航命令前也同步调，保证「上一视图」回到命令前） */
  private recordHistory(): void {
    if (this.navigating) {
      return;
    }
    const info = this.lastInfo;
    if (info === undefined || info.altitude <= 0) {
      return;
    }
    const cam: Camera = new Camera(info.centerLat, info.centerLon, info.altitude,
      info.heading, info.tilt);
    if (this.historyPos >= 0 && this.historyPos < this.history.length) {
      const top: Camera = this.history[this.historyPos];
      if (Math.abs(top.latitude - cam.latitude) < 1e-7
        && Math.abs(top.longitude - cam.longitude) < 1e-7
        && Math.abs(top.altitude - cam.altitude) < cam.altitude * 1e-4) {
        return;
      }
    }
    // 当前位置之后还有「前进」分支时截断（ArcMap 同语义）
    this.history = this.history.slice(0, this.historyPos + 1);
    this.history.push(cam);
    if (this.history.length > HISTORY_MAX) {
      this.history = this.history.slice(this.history.length - HISTORY_MAX);
    }
    this.historyPos = this.history.length - 1;
    this.syncHistoryButtons();
  }

  private syncHistoryButtons(): void {
    const back: boolean = this.historyPos > 0;
    const forward: boolean = this.historyPos >= 0 && this.historyPos < this.history.length - 1;
    if (back !== this.canBack) {
      this.canBack = back;
    }
    if (forward !== this.canForward) {
      this.canForward = forward;
    }
  }

  private jumpHistory(delta: number): void {
    const canvas = this.canvas;
    const target: number = this.historyPos + delta;
    if (canvas === undefined || target < 0 || target >= this.history.length) {
      return;
    }
    this.navigating = true;
    this.historyPos = target;
    canvas.applyCamera(this.history[target]);
    this.syncHistoryButtons();
    setTimeout((): void => {
      this.navigating = false;
    }, SETTLE_MS + 200);
  }

  // ── 命令分发 ──

  private onCommand(cmd: string): void {
    const canvas = this.canvas;
    const view = this.engine();
    if (cmd === DeskCmd.ADD_DATA) {
      this.addData();
      return;
    }
    if (cmd === DeskCmd.ZOOM_IN) {
      this.recordHistory();
      if (canvas !== undefined) {
        canvas.zoomAtCursor(1.6);
      }
      this.message = '放大';
      return;
    }
    if (cmd === DeskCmd.ZOOM_OUT) {
      this.recordHistory();
      if (canvas !== undefined) {
        canvas.zoomAtCursor(1 / 1.6);
      }
      this.message = '缩小';
      return;
    }
    if (cmd === DeskCmd.ZOOM_EXTENT) {
      this.fullExtent();
      return;
    }
    if (cmd === DeskCmd.ZOOM_BACK) {
      this.jumpHistory(-1);
      this.message = '返回上一视图';
      return;
    }
    if (cmd === DeskCmd.ZOOM_FORWARD) {
      this.jumpHistory(1);
      this.message = '前进到下一视图';
      return;
    }
    if (cmd === DeskCmd.CLEAR_SELECTION) {
      this.clearSelection();
      this.message = '已清除所选要素';
      return;
    }
    if (cmd === DeskCmd.TOGGLE_3D) {
      this.is3D = !this.is3D;
      if (view !== undefined) {
        view.setViewMode(this.is3D ? ViewMode.THREE_D : ViewMode.TWO_D);
      }
      this.message = this.is3D ? '三维地球（中键/双指转视角）' : '二维平面墨卡托';
      return;
    }
    if (cmd === DeskCmd.FLIP_WHEEL) {
      this.wheelUpZoomsIn = !this.wheelUpZoomsIn;
      this.message = `滚轮方向：向上${this.wheelUpZoomsIn ? '放大' : '缩小'}`;
      return;
    }
    if (cmd === DeskCmd.TOC_DOCK) {
      this.leftVisible = !this.leftVisible;
      return;
    }
    if (cmd === DeskCmd.TABLE_DOCK) {
      if (this.bottomVisible) {
        this.bottomVisible = false;
      } else {
        this.openTable(this.selectedLayer >= 0 ? this.selectedLayer : this.firstVectorLayer());
      }
      return;
    }
    if (cmd === DeskCmd.IDENTIFY_DOCK) {
      this.rightVisible = !this.rightVisible;
      return;
    }
    if (cmd === DeskCmd.LAYER_PROPERTY) {
      this.openProps(this.selectedLayer);
      return;
    }
    if (cmd === DeskCmd.EXIT) {
      this.terminate();
      return;
    }
    if (cmd === DeskCmd.ABOUT) {
      this.message = `调查宝 桌面端 v${this.versionName}｜GDAL ${NativeLayerInfo.getGdalVersion()}｜ArcMap 式内业工作台`;
      return;
    }
    if (cmd === DeskCmd.TOOL_GOTO_XY) {
      this.openGotoDialog();
      return;
    }
    this.message = `「${cmd}」尚未接入（工程文档待下沉 HSP）`;
  }

  /** 打开「转到 XY」：初值取当前相机中心；引擎未就绪时只提示，不开面板 */
  private openGotoDialog(): void {
    const view = this.engine();
    const cam = view === undefined ? undefined : view.getCamera();
    if (cam === undefined) {
      this.message = '转到 XY：地图引擎未就绪';
      return;
    }
    this.gotoLat = cam.latitude;
    this.gotoLon = cam.longitude;
    this.gotoOpen = true;
  }

  /** 确认转到：先记历史（可「返回上一视图」撤销），中心搬到输入点，级别与姿态不动 */
  private confirmGoto(lat: number, lon: number): void {
    const canvas = this.canvas;
    this.recordHistory();
    if (canvas === undefined || !canvas.goTo(lat, lon)) {
      this.message = '转到 XY 失败：地图引擎未就绪';
      return;
    }
    this.message = `已转到 ${DeskVector.coordText(lon, lat, this.coordUnit)}`;
  }

  private onLayerCommand(cmd: string, index: number): void {
    if (index < 0 || index >= this.layers.length) {
      return;
    }
    this.selectedLayer = index;
    if (cmd === DeskCmd.LAYER_ZOOM) {
      this.zoomToLayer(index);
      return;
    }
    if (cmd === DeskCmd.LAYER_TABLE) {
      this.openTable(index);
      return;
    }
    if (cmd === DeskCmd.LAYER_PROPERTY) {
      this.openProps(index);
      return;
    }
    if (cmd === DeskCmd.LAYER_REMOVE) {
      this.removeLayer(index);
      return;
    }
    if (cmd === DeskCmd.LAYER_REFRESH) {
      this.refreshLayer(index);
      return;
    }
    if (cmd === DeskCmd.LAYER_MOVE_GROUP) {
      this.moveDialogIndex = index;
      return;
    }
    this.message = `图层命令「${cmd}」尚未接入`;
  }

  private terminate(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    ctx.terminateSelf().then((): void => {
    }, (e: Error): void => {
      DeskLog.w(`退出失败: ${e}`);
    });
  }

  // ── 添加数据 ──

  private async addData(): Promise<void> {
    if (this.busy) {
      return;
    }
    const view = this.engine();
    if (view === undefined) {
      this.message = '地图引擎未就绪';
      return;
    }
    this.busy = true;
    this.message = '选择数据文件…';
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      options.maxSelectNumber = DeskImporter.MAX_SELECT;
      options.fileSuffixFilters = DeskFormats.filters();
      const uris: string[] = await new picker.DocumentViewPicker(ctx).select(options);
      if (uris === undefined || uris.length === 0) {
        this.message = '已取消添加数据';
        return;
      }
      this.message = `正在导入 ${uris.length} 个文件…`;
      const results: DeskImportResult[] = await DeskImporter.importPicked(uris);
      if (results.length === 0) {
        this.message = '未导入任何图层（格式不支持或拷贝失败，详见日志）';
        return;
      }
      let added: number = 0;
      let lastExtent: number[] = [];
      for (let i = 0; i < results.length; i++) {
        const extent: number[] = this.addResult(results[i]);
        if (extent.length >= 4) {
          lastExtent = extent;
          added++;
        }
      }
      if (added === 0) {
        this.message = '数据已拷入沙箱，但上图失败（检查坐标系/格式，详见日志）';
        return;
      }
      if (lastExtent.length >= 4) {
        this.recordHistory();
        const canvas = this.canvas;
        if (canvas !== undefined && !canvas.zoomToExtent(lastExtent)) {
          this.message = `已添加 ${added} 个图层（视图量算未就绪，未自动缩放）`;
          return;
        }
      }
      this.message = `已添加 ${added} 个图层并缩放至数据范围`;
    } catch (e) {
      this.message = `添加数据失败：${e}`;
      DeskLog.e(`添加数据失败: ${e}`);
    } finally {
      this.busy = false;
    }
  }

  /** 单个导入结果上图；返回四至（空数组 = 失败） */
  private addResult(result: DeskImportResult): number[] {
    const view = this.engine();
    if (view === undefined) {
      return [];
    }
    // 同路径已在图内则不重复加层（避免同一文件产生两个渲染层）
    for (let i = 0; i < this.layers.length; i++) {
      if (this.layers[i].path === result.path) {
        this.selectedLayer = i;
        this.message = `${result.name} 已在内容表中`;
        return this.layers[i].extent;
      }
    }
    const extent: number[] = DeskVector.extentOf(result.path) ?? [];
    if (extent.length < 4) {
      this.message = `${result.name}：取不到四至（无地理参考或文件损坏）`;
      DeskLog.w(`四至为空: ${result.path}`);
      return [];
    }
    if (result.raster) {
      const index: number = view.addRasterImageLayer(DeskDirs.tileDir('raster'), result.path);
      if (index < 0) {
        const err: string | null = view.rasterImageError(index);
        this.message = `${result.name} 上图失败：${err === null ? '未知原因' : err}`;
        return [];
      }
      this.pushLayer(new LayerRow(result.name, LayerSpace.RASTER_IMAGE, index, true,
        result.path, GeomKind.RASTER, 0xFF9CC77E, -1, extent));
      return extent;
    }
    const probe: string = DeskVector.probeError(result.path);
    if (probe.length > 0) {
      this.message = `${result.name} 无法加载：${probe}`;
      DeskLog.w(`探针失败 ${result.path}: ${probe}`);
      return [];
    }
    const geom: string = DeskVector.geomKindOf(result.path);
    const color: number = this.nextColor();
    const index: number = view.addVectorLayer(result.path, DeskVector.styleFor(geom, color));
    if (index < 0) {
      this.message = `${result.name} 上图失败（引擎返回 -1）`;
      return [];
    }
    const count: number = DeskVector.countOf(result.path);
    this.vectorCount++;
    this.pushLayer(new LayerRow(result.name, LayerSpace.VECTOR, index, true, result.path,
      geom, color, count, extent));
    return extent;
  }

  private pushLayer(row: LayerRow): void {
    const rows: LayerRow[] = this.layers.slice();
    // ArcMap 后加的层画在上层：内容表按绘制顺序倒序列出，故新层插到最前
    rows.unshift(row);
    this.layers = rows;
    this.selectedLayer = 0;
    if (this.tableLayer >= 0) {
      this.tableLayer++;
    }
    if (this.propsIndex >= 0) {
      this.propsIndex++;
    }
  }

  /** 符号色按加载次序取色板（错开 5 格避免相邻层同色） */
  private nextColor(): number {
    const palette: number[] = DeskTheme.PALETTE;
    return palette[(this.vectorCount * 5 + 6) % palette.length];
  }

  private firstVectorLayer(): number {
    for (let i = 0; i < this.layers.length; i++) {
      if (this.layers[i].isVector()) {
        return i;
      }
    }
    return -1;
  }

  // ── 图层操作 ──

  private setLayerVisible(row: LayerRow, visible: boolean): void {
    const view = this.engine();
    if (view === undefined || row.engineIndex < 0) {
      return;
    }
    if (row.space === LayerSpace.TILE) {
      view.setLayerVisible(row.engineIndex, visible);
    } else if (row.space === LayerSpace.RASTER_IMAGE) {
      view.setRasterImageVisible(row.engineIndex, visible);
    } else {
      view.setVectorLayerVisible(row.engineIndex, visible);
    }
  }

  private toggleLayer(index: number, visible: boolean): void {
    if (index < 0 || index >= this.layers.length) {
      return;
    }
    const rows: LayerRow[] = this.layers.slice();
    const old: LayerRow = rows[index];
    this.setLayerVisible(old, visible);
    rows[index] = new LayerRow(old.name, old.space, old.engineIndex, visible, old.path,
      old.geom, old.color, old.featureCount, old.extent, old.groupId, old.labelField);
    this.layers = rows;
    this.message = `${visible ? '显示' : '隐藏'} ${old.name}`;
  }

  private toggleAll(visible: boolean): void {
    const view = this.engine();
    if (view === undefined) {
      return;
    }
    const rows: LayerRow[] = [];
    for (let i = 0; i < this.layers.length; i++) {
      const old: LayerRow = this.layers[i];
      this.setLayerVisible(old, visible);
      rows.push(new LayerRow(old.name, old.space, old.engineIndex, visible, old.path,
        old.geom, old.color, old.featureCount, old.extent, old.groupId, old.labelField));
    }
    this.layers = rows;
    this.message = visible ? '显示全部图层' : '隐藏全部图层';
  }

  // ── 图层分组（仅内存态：组可见性扇出成员显隐，不改绘制顺序）──

  private findGroup(groupId: number): DeskLayerGroup | undefined {
    for (let i = 0; i < this.groups.length; i++) {
      if (this.groups[i].id === groupId) {
        return this.groups[i];
      }
    }
    return undefined;
  }

  /** 建组并返回新 id（max+1） */
  private createGroup(name: string): number {
    let maxId: number = 0;
    for (let i = 0; i < this.groups.length; i++) {
      if (this.groups[i].id > maxId) {
        maxId = this.groups[i].id;
      }
    }
    const id: number = maxId + 1;
    const next: DeskLayerGroup[] = this.groups.slice();
    next.push(new DeskLayerGroup(id, name));
    this.groups = next;
    return id;
  }

  private toggleGroup(groupId: number, visible: boolean): void {
    const view = this.engine();
    if (view === undefined) {
      return;
    }
    const rows: LayerRow[] = this.layers.slice();
    let n: number = 0;
    for (let i = 0; i < rows.length; i++) {
      const old: LayerRow = rows[i];
      if (old.groupId !== groupId) {
        continue;
      }
      this.setLayerVisible(old, visible);
      rows[i] = new LayerRow(old.name, old.space, old.engineIndex, visible, old.path,
        old.geom, old.color, old.featureCount, old.extent, old.groupId, old.labelField);
      n++;
    }
    this.layers = rows;
    const g: DeskLayerGroup | undefined = this.findGroup(groupId);
    this.message = `${visible ? '显示' : '隐藏'}分组「${g !== undefined ? g.name : `${groupId}`}」（${n} 个图层）`;
  }

  private onGroupCommand(cmd: string, groupId: number): void {
    if (cmd === DeskCmd.GROUP_NEW) {
      this.groupTargetId = -1;
      this.nameDialogInitial = '';
      this.nameDialogMode = 1;
      return;
    }
    const g: DeskLayerGroup | undefined = this.findGroup(groupId);
    if (g === undefined) {
      return;
    }
    if (cmd === DeskCmd.GROUP_RENAME) {
      this.groupTargetId = groupId;
      this.nameDialogInitial = g.name;
      this.nameDialogMode = 2;
      return;
    }
    if (cmd === DeskCmd.GROUP_DELETE) {
      this.getUIContext().showAlertDialog({
        title: '删除分组',
        message: `删除「${g.name}」？组内图层将回落为未分组（不会删除图层）。`,
        primaryButton: { value: '取消', action: (): void => {} },
        secondaryButton: {
          value: '删除',
          fontColor: '#C00000',
          action: (): void => { this.deleteGroup(groupId); }
        }
      });
    }
  }

  private confirmNameDialog(name: string): void {
    if (this.nameDialogMode === 1) {
      this.createGroup(name);
      this.message = `已新建分组：${name}`;
    } else if (this.nameDialogMode === 2) {
      const next: DeskLayerGroup[] = this.groups.slice();
      for (let i = 0; i < next.length; i++) {
        if (next[i].id === this.groupTargetId) {
          next[i] = new DeskLayerGroup(this.groupTargetId, name);
        }
      }
      this.groups = next;
      this.message = `分组已重命名为：${name}`;
    }
    this.nameDialogMode = 0;
  }

  private deleteGroup(groupId: number): void {
    const g: DeskLayerGroup | undefined = this.findGroup(groupId);
    this.groups = this.groups.filter((x: DeskLayerGroup): boolean => x.id !== groupId);
    const rows: LayerRow[] = this.layers.slice();
    for (let i = 0; i < rows.length; i++) {
      const old: LayerRow = rows[i];
      if (old.groupId === groupId) {
        rows[i] = new LayerRow(old.name, old.space, old.engineIndex, old.visible, old.path,
          old.geom, old.color, old.featureCount, old.extent, LayerRow.UNGROUPED_ID, old.labelField);
      }
    }
    this.layers = rows;
    this.message = `已删除分组「${g !== undefined ? g.name : `${groupId}`}」，成员回落未分组`;
  }

  private confirmMoveDialog(groupId: number, newGroupName: string): void {
    const index: number = this.moveDialogIndex;
    this.moveDialogIndex = -1;
    if (index < 0 || index >= this.layers.length) {
      return;
    }
    let target: number = groupId;
    if (newGroupName.length > 0) {
      target = this.createGroup(newGroupName);
    }
    const rows: LayerRow[] = this.layers.slice();
    const old: LayerRow = rows[index];
    rows[index] = new LayerRow(old.name, old.space, old.engineIndex, old.visible, old.path,
      old.geom, old.color, old.featureCount, old.extent, target, old.labelField);
    this.layers = rows;
    const g: DeskLayerGroup | undefined = this.findGroup(target);
    this.message = target === LayerRow.UNGROUPED_ID
      ? `${old.name} 已移出分组`
      : `${old.name} 已移至「${g !== undefined ? g.name : `${target}`}」`;
  }

  private zoomToLayer(index: number): void {
    if (index < 0 || index >= this.layers.length) {
      return;
    }
    const row: LayerRow = this.layers[index];
    const canvas = this.canvas;
    if (canvas === undefined) {
      return;
    }
    if (row.extent.length < 4) {
      this.message = `${row.name}：无四至，无法缩放`;
      return;
    }
    this.recordHistory();
    this.message = canvas.zoomToExtent(row.extent)
      ? `缩放至图层：${row.name}`
      : `${row.name}：视图量算未就绪，稍后再试`;
  }

  /** 全图 = 所有可见数据层的四至并集（在线底图是全球范围，不参与，否则永远缩到世界） */
  private fullExtent(): void {
    let minLon: number = 0;
    let minLat: number = 0;
    let maxLon: number = 0;
    let maxLat: number = 0;
    let has: boolean = false;
    for (let i = 0; i < this.layers.length; i++) {
      const row: LayerRow = this.layers[i];
      if (!row.visible || row.path.length === 0 || row.extent.length < 4) {
        continue;
      }
      const e: number[] = row.extent;
      if (!has) {
        minLon = e[0]; minLat = e[1]; maxLon = e[2]; maxLat = e[3];
        has = true;
      } else {
        minLon = Math.min(minLon, e[0]);
        minLat = Math.min(minLat, e[1]);
        maxLon = Math.max(maxLon, e[2]);
        maxLat = Math.max(maxLat, e[3]);
      }
    }
    const canvas = this.canvas;
    if (canvas === undefined) {
      return;
    }
    this.recordHistory();
    if (!has) {
      canvas.moveTo(HOME_LAT, HOME_LON, HOME_ALT_M);
      this.message = '全图：尚无数据图层，回到默认视野';
      return;
    }
    this.message = canvas.zoomToExtent([minLon, minLat, maxLon, maxLat])
      ? '全图：缩放至所有可见数据图层'
      : '全图：视图量算未就绪，稍后再试';
  }

  /**
   * 图层刷新（对应右键菜单「刷新」）：引擎没有就地重读接口，按当前符号与标注字段重挂同一数据源，
   * 并回读要素数与四至——外部改过 shp/gpkg 后不必重启。其余层索引稳定（同 applyProps 换层口径）。
   * 栅格/底图没有重挂接口（见 removeLayer 里同款说明），只提示不动；属性表正开着该层则一并重读。
   */
  private refreshLayer(index: number): void {
    const view = this.engine();
    if (view === undefined || index < 0 || index >= this.layers.length) {
      return;
    }
    const old: LayerRow = this.layers[index];
    if (!old.isVector()) {
      this.message = `${old.name}：栅格/底图无重挂接口，刷新只对矢量数据层有效`;
      return;
    }
    const probe: string = DeskVector.probeError(old.path);
    if (probe.length > 0) {
      this.message = `刷新失败：${probe}`;
      return;
    }
    if (old.engineIndex >= 0) {
      view.removeVectorLayer(old.engineIndex);
    }
    const engineIndex: number = view.addVectorLayer(old.path,
      DeskVector.styleFor(old.geom, old.color, old.labelField));
    if (engineIndex < 0) {
      // 旧层已摘、新层没建上：行留成未上图占位（engineIndex=-1），避免 TOC 指向失效索引
      const dead: LayerRow[] = this.layers.slice();
      dead[index] = new LayerRow(old.name, old.space, -1, old.visible, old.path,
        old.geom, old.color, -1, [], old.groupId, old.labelField);
      this.layers = dead;
      this.message = `${old.name} 刷新失败（引擎返回 -1），已移出绘制，请重新添加数据`;
      DeskLog.w(`刷新失败 addVectorLayer=-1: ${old.path}`);
      return;
    }
    view.setVectorLayerVisible(engineIndex, old.visible);
    const extent: number[] = DeskVector.extentOf(old.path) ?? [];
    const rows: LayerRow[] = this.layers.slice();
    rows[index] = new LayerRow(old.name, old.space, engineIndex, old.visible, old.path,
      old.geom, old.color, DeskVector.countOf(old.path), extent, old.groupId, old.labelField);
    this.layers = rows;
    if (this.bottomVisible && this.tableLayer === index) {
      this.openTable(index);
    }
    this.message = `已刷新 ${old.name}（要素 ${rows[index].featureCount} 个）`;
  }

  private removeLayer(index: number): void {
    const view = this.engine();
    if (view === undefined || index < 0 || index >= this.layers.length) {
      return;
    }
    const row: LayerRow = this.layers[index];
    if (row.space === LayerSpace.RASTER_IMAGE) {
      // 引擎对全幅栅格层只给显隐、没有移除接口：隐藏并保留行，避免 TOC 与绘制状态不一致
      this.setLayerVisible(row, false);
      const rows: LayerRow[] = this.layers.slice();
      rows[index] = new LayerRow(row.name, row.space, row.engineIndex, false, row.path,
        row.geom, row.color, row.featureCount, row.extent, row.groupId, row.labelField);
      this.layers = rows;
      this.message = `${row.name} 已隐藏（全幅栅格层引擎无移除接口，重启后不再加载）`;
      return;
    }
    if (row.engineIndex >= 0) {
      if (row.space === LayerSpace.TILE) {
        view.removeTileLayer(row.engineIndex);
      } else {
        view.removeVectorLayer(row.engineIndex);
      }
    }
    const rows: LayerRow[] = this.layers.slice();
    rows.splice(index, 1);
    this.layers = rows;
    if (this.selectedLayer === index) {
      this.selectedLayer = -1;
    } else if (this.selectedLayer > index) {
      this.selectedLayer--;
    }
    if (this.tableLayer === index) {
      this.tableLayer = -1;
      this.tablePage = new TablePage();
      this.bottomVisible = false;
    } else if (this.tableLayer > index) {
      this.tableLayer--;
    }
    if (this.idLayerName === row.name) {
      this.clearSelection();
    }
    this.message = `已移除图层：${row.name}`;
  }

  // ── 属性表 ──

  private openTable(index: number): void {
    if (index < 0 || index >= this.layers.length) {
      this.bottomVisible = true;
      this.tableLayer = -1;
      this.tablePage = new TablePage();
      this.message = '属性表：先在内容表里选一个矢量图层';
      return;
    }
    const row: LayerRow = this.layers[index];
    if (!row.isVector()) {
      this.message = `${row.name} 不是矢量数据层，无属性表`;
      return;
    }
    this.selectedLayer = index;
    this.tableLayer = index;
    this.bottomVisible = true;
    this.tableSubLayers = [];
    this.tableSubLayer = '';
    this.loadTablePage(0);
  }

  private loadTablePage(offset: number): void {
    if (this.tableLayer < 0 || this.tableLayer >= this.layers.length) {
      return;
    }
    const row: LayerRow = this.layers[this.tableLayer];
    const fields: string[] = DeskVector.fieldNames(row.path);
    const total: number = row.featureCount >= 0 ? row.featureCount : DeskVector.countOf(row.path);
    let json: string | null = DeskVector.queryPage(row.path, PAGE_SIZE, offset);
    if (json !== null) {
      this.tableSubLayers = [];
      this.tableSubLayer = '';
      this.tablePage = DeskVector.tableOf(json, fields, total, offset);
      this.message = `属性表：${row.name}（SQL 分页，共 ${DeskVector.groupDigits(Math.max(0, total))} 条）`;
      return;
    }
    // SQL 不可用（多子层 gpkg / 驱动不支持 LIMIT 等）：全量读取后按子层切片
    json = DeskVector.readAll(row.path);
    this.tableSubLayers = DeskVector.layerNamesOf(json);
    const all: TablePage = DeskVector.layerTable(json, this.tableSubLayer, this.tableFid);
    if (this.tableSubLayer.length === 0) {
      this.tableSubLayer = all.subLayer;
    }
    if (all.error.length > 0) {
      this.tablePage = new TablePage(['FID'].concat(fields), [], [], 0, offset, all.error);
      this.message = `属性表读取失败：${all.error}`;
      return;
    }
    const end: number = Math.min(all.rows.length, offset + PAGE_SIZE);
    const start: number = Math.min(offset, end);
    const page: TablePage = new TablePage(all.headers, all.rows.slice(start, end),
      all.fids.slice(start, end), all.rows.length, start, '');
    page.subLayer = all.subLayer;
    this.tablePage = page;
    this.message = `属性表：${row.name}（全量读取回退，共 ${DeskVector.groupDigits(all.rows.length)} 条）`;
  }

  /** 属性表子层切换（gpkg 多表）：换表后回到第一页 */
  private onTableSubLayer(name: string): void {
    this.tableSubLayer = name;
    this.loadTablePage(0);
  }

  /** 属性表点记录：高亮 + 缩放至该要素 */
  private onTableRow(fid: number): void {
    const view = this.engine();
    const canvas = this.canvas;
    if (view === undefined || canvas === undefined
      || this.tableLayer < 0 || this.tableLayer >= this.layers.length) {
      return;
    }
    const row: LayerRow = this.layers[this.tableLayer];
    const geom: FeatureGeometry | undefined = view.featureGeometry(row.engineIndex, fid);
    this.tableFid = fid;
    this.drawHighlight(row.engineIndex, fid, geom);
    if (geom === undefined || geom.lonlat.length < 2) {
      this.message = `FID ${fid}：取不到几何（可能不在当前加载范围内）`;
      return;
    }
    this.recordHistory();
    const extent: number[] = DeskVector.extentOfLonLat(geom.lonlat);
    // 单点/极小要素给一个最小视野，避免海拔被算到 0
    const padded: number[] = Workbench.padExtent(extent);
    this.message = canvas.zoomToExtent(padded)
      ? `缩放至要素：${row.name} · FID ${fid}`
      : `已选中 FID ${fid}（视图量算未就绪，未缩放）`;
  }

  /** 点/极小范围垫一个最小跨度（约 100m），否则目标海拔趋 0 被引擎钳到最大级别 */
  private static padExtent(extent: number[]): number[] {
    if (extent.length < 4) {
      return extent;
    }
    const minSpan: number = 0.001;
    let minLon: number = extent[0];
    let maxLon: number = extent[2];
    let minLat: number = extent[1];
    let maxLat: number = extent[3];
    if (maxLon - minLon < minSpan) {
      const mid: number = (minLon + maxLon) / 2;
      minLon = mid - minSpan / 2;
      maxLon = mid + minSpan / 2;
    }
    if (maxLat - minLat < minSpan) {
      const mid: number = (minLat + maxLat) / 2;
      minLat = mid - minSpan / 2;
      maxLat = mid + minSpan / 2;
    }
    return [minLon, minLat, maxLon, maxLat];
  }

  // ── 图层属性 ──

  private openProps(index: number): void {
    if (index < 0 || index >= this.layers.length) {
      this.message = '图层属性：先在内容表里选一个图层';
      return;
    }
    const row: LayerRow = this.layers[index];
    this.propsIndex = index;
    this.propsRow = row;
    this.propsFields = row.isVector() ? DeskVector.fieldNames(row.path) : [];
    this.propsSrs = row.path.length > 0 ? DeskVector.srsOf(row.path) : 'Web 墨卡托（在线瓦片图源）';
    this.propsFormat = row.path.length > 0 ? DeskFormats.labelOf(row.path) : '在线瓦片图源（XYZ）';
    this.propsSize = row.path.length > 0 ? Workbench.sizeText(row.path) : '';
    this.propsOpen = true;
  }

  /** 写样式：矢量层就地换层（remove + add，其它层索引稳定），底图/栅格只改 TOC 色块 */
  private applyProps(color: number, labelField: string): void {
    const view = this.engine();
    if (view === undefined || this.propsIndex < 0 || this.propsIndex >= this.layers.length) {
      return;
    }
    const old: LayerRow = this.layers[this.propsIndex];
    let engineIndex: number = old.engineIndex;
    if (old.isVector()) {
      const probe: string = DeskVector.probeError(old.path);
      if (probe.length > 0) {
        this.message = `样式未应用：${probe}`;
        return;
      }
      if (old.engineIndex >= 0) {
        view.removeVectorLayer(old.engineIndex);
      }
      engineIndex = view.addVectorLayer(old.path, DeskVector.styleFor(old.geom, color, labelField));
      if (engineIndex < 0) {
        this.message = `${old.name} 换层失败，样式未生效`;
        return;
      }
      view.setVectorLayerVisible(engineIndex, old.visible);
    }
    const rows: LayerRow[] = this.layers.slice();
    rows[this.propsIndex] = new LayerRow(old.name, old.space, engineIndex, old.visible, old.path,
      old.geom, color, old.featureCount, old.extent, old.groupId, labelField);
    this.layers = rows;
    this.propsRow = rows[this.propsIndex];
    this.message = old.isVector()
      ? `已应用符号：${old.name}${labelField.length > 0 ? `（标注 ${labelField}）` : ''}`
      : `${old.name} 的符号由数据源决定，仅更新内容表色块`;
  }

  private static sizeText(path: string): string {
    try {
      const bytes: number = fs.statSync(path).size;
      if (bytes >= 1024 * 1024) {
        return `${(bytes / (1024 * 1024)).toFixed(2)} MB`;
      }
      if (bytes >= 1024) {
        return `${(bytes / 1024).toFixed(1)} KB`;
      }
      return `${bytes} B`;
    } catch (e) {
      return '';
    }
  }

  private visibleCount(): number {
    let n: number = 0;
    for (let i = 0; i < this.layers.length; i++) {
      if (this.layers[i].visible) {
        n++;
      }
    }
    return n;
  }

  private tableLayerName(): string {
    if (this.tableLayer < 0 || this.tableLayer >= this.layers.length) {
      return '';
    }
    const name: string = this.layers[this.tableLayer].name;
    return this.tableSubLayers.length > 1 && this.tableSubLayer.length > 0
      ? `${name} · ${this.tableSubLayer}` : name;
  }

  // ── 布局 ──

  @Builder
  mapPane() {
    MapCanvas({
      wheelUpZoomsIn: $wheelUpZoomsIn,
      onMapReady: (canvas: MapCanvas): void => {
        this.onCanvasReady(canvas);
      },
      onViewInfo: (info: ViewInfo): void => {
        this.onViewInfo(info);
      }
    })
  }

  @Builder
  tocContent() {
    TocPanel({
      rows: this.layers,
      groups: this.groups,
      selectedIndex: this.selectedLayer,
      sourceTab: this.sourceTab,
      frameName: '图层',
      onToggle: (index: number, visible: boolean): void => { this.toggleLayer(index, visible); },
      onToggleAll: (visible: boolean): void => { this.toggleAll(visible); },
      onSelect: (index: number): void => {
        this.selectedLayer = index;
        this.message = `选中图层：${this.layers[index].name}`;
      },
      onCommand: (cmd: string, index: number): void => { this.onLayerCommand(cmd, index); },
      onTab: (source: boolean): void => { this.sourceTab = source; },
      onToggleGroup: (groupId: number, visible: boolean): void => { this.toggleGroup(groupId, visible); },
      onGroupCommand: (cmd: string, groupId: number): void => { this.onGroupCommand(cmd, groupId); }
    })
  }

  @Builder
  identifyContent() {
    IdentifyPanel({
      layerName: this.idLayerName,
      fid: this.idFid,
      fields: this.idFields,
      geomText: this.idGeomText,
      onZoom: (): void => {
        if (this.selectedLayer >= 0 && this.idFid >= 0) {
          this.onTableRow(this.idFid);
        }
      },
      onTable: (): void => { this.openTable(this.selectedLayer); }
    })
  }

  @Builder
  tableContent() {
    AttributeTable({
      page: this.tablePage,
      layerName: this.tableLayerName(),
      selectedFid: this.tableFid,
      pageSize: PAGE_SIZE,
      subLayers: this.tableSubLayers,
      subLayer: this.tableSubLayer,
      onPage: (offset: number): void => { this.loadTablePage(offset); },
      onRow: (fid: number): void => { this.onTableRow(fid); },
      onSubLayer: (name: string): void => { this.onTableSubLayer(name); }
    })
  }

  /** 竖直分隔条：拖拽调停靠宽（leftSide=true 调左栏，false 调右栏） */
  @Builder
  vDivider(leftSide: boolean) {
    Column()
      .width(5)
      .height('100%')
      .backgroundColor(DeskTheme.DIVIDER_SOFT)
      .gesture(
        PanGesture({ direction: PanDirection.Horizontal })
          .onActionStart((): void => {
            this.dragBase = leftSide ? this.leftWidthVp : this.rightWidthVp;
          })
          .onActionUpdate((e: GestureEvent): void => {
            const delta: number = leftSide ? e.offsetX : -e.offsetX;
            const next: number = Math.min(520, Math.max(DeskTheme.DOCK_MIN_W, this.dragBase + delta));
            if (leftSide) {
              this.leftWidthVp = next;
            } else {
              this.rightWidthVp = next;
            }
          })
      )
  }

  /** 水平分隔条：拖拽调属性表高 */
  @Builder
  hDivider() {
    Row()
      .width('100%')
      .height(5)
      .backgroundColor(DeskTheme.DIVIDER_SOFT)
      .gesture(
        PanGesture({ direction: PanDirection.Vertical })
          .onActionStart((): void => {
            this.dragBase = this.bottomHeightVp;
          })
          .onActionUpdate((e: GestureEvent): void => {
            this.bottomHeightVp =
              Math.min(460, Math.max(DeskTheme.DOCK_MIN_H, this.dragBase - e.offsetY));
          })
      )
  }

  /** 中部：地图 + 可选下停靠（属性表） */
  @Builder
  centerColumn() {
    Column() {
      Column() {
        this.mapPane()
      }
      .width('100%')
      .layoutWeight(1)

      if (this.bottomVisible) {
        this.hDivider()
        Column() {
          DockPanel({
            title: '属性表',
            badge: this.tableLayerName(),
            isLeft: false,
            onClose: (): void => { this.bottomVisible = false; },
            content: (): void => { this.tableContent() }
          })
        }
        .width('100%')
        .height(this.bottomHeightVp)
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  workspace() {
    Row() {
      if (this.leftVisible) {
        Column() {
          DockPanel({
            title: '内容表',
            badge: `${this.visibleCount()}/${this.layers.length}`,
            onClose: (): void => { this.leftVisible = false; },
            content: (): void => { this.tocContent() }
          })
        }
        .width(this.leftWidthVp)
        .height('100%')
        this.vDivider(true)
      }

      Column() {
        this.centerColumn()
      }
      .layoutWeight(1)
      .height('100%')

      if (this.rightVisible) {
        this.vDivider(false)
        Column() {
          DockPanel({
            title: '识别结果',
            badge: this.idFid >= 0 ? `FID ${this.idFid}` : '空',
            onClose: (): void => { this.rightVisible = false; },
            content: (): void => { this.identifyContent() }
          })
        }
        .width(this.rightWidthVp)
        .height('100%')
      }
    }
    .width('100%')
    .layoutWeight(1)
  }

  build() {
    Stack() {
      Column() {
        MenuBar({
          onCommand: (cmd: string): void => { this.onCommand(cmd); },
          canBack: this.canBack,
          canForward: this.canForward,
          hasSelection: this.idFid >= 0,
          busy: this.busy
        })

        ToolBar({
          activeTool: $activeTool,
          scaleText: this.scaleText,
          scaleReady: this.scaleReady,
          canBack: this.canBack,
          canForward: this.canForward,
          tocOn: this.leftVisible,
          tableOn: this.bottomVisible,
          busy: this.busy,
          onCommand: (cmd: string): void => { this.onCommand(cmd); },
          onScale: (denominator: number): void => {
            this.recordHistory();
            const canvas = this.canvas;
            if (canvas !== undefined) {
              canvas.setScaleDenominator(denominator);
            }
            this.message = `比例尺 1:${DeskVector.groupDigits(denominator)}`;
          },
          onTip: (tip: string): void => { this.hint = tip; }
        })

        this.workspace()

        StatusBar({
          coordText: this.coordText,
          unitText: DeskVector.unitLabel(this.coordUnit),
          scaleText: this.scaleText,
          level: this.level,
          modeText: this.is3D ? '三维' : '二维',
          toolText: toolLabel(this.activeTool),
          message: this.message,
          hint: this.hint,
          onUnit: (unit: number): void => {
            this.coordUnit = unit as CoordUnit;
            this.refreshReadouts();
            this.message = `坐标单位：${DeskVector.unitLabel(this.coordUnit)}`;
          }
        })
      }
      .width('100%')
      .height('100%')
      .backgroundColor(DeskTheme.WINDOW)

      // 图层属性：遮罩 + 居中面板（点遮罩关闭，点面板内部不冒泡到遮罩）
      if (this.propsOpen) {
        Stack({ alignContent: Alignment.Center }) {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor('rgba(0,0,0,0.28)')
            .onClick((): void => { this.propsOpen = false; })
          LayerPropsPanel({
            row: this.propsRow,
            fieldNames: this.propsFields,
            srs: this.propsSrs,
            formatLabel: this.propsFormat,
            sizeText: this.propsSize,
            onApply: (color: number, labelField: string): void => {
              this.applyProps(color, labelField);
            },
            onClose: (): void => { this.propsOpen = false; }
          })
        }
        .width('100%')
        .height('100%')
      }

      // 分组命名（新建/重命名）：遮罩 + 居中面板
      if (this.nameDialogMode !== 0) {
        Stack({ alignContent: Alignment.Center }) {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor('rgba(0,0,0,0.28)')
            .onClick((): void => { this.nameDialogMode = 0; })
          DeskNameDialog({
            title: this.nameDialogMode === 1 ? '新建分组' : '重命名分组',
            initial: this.nameDialogInitial,
            onConfirm: (name: string): void => { this.confirmNameDialog(name); },
            onClose: (): void => { this.nameDialogMode = 0; }
          })
        }
        .width('100%')
        .height('100%')
      }

      // 移至分组：遮罩 + 居中面板
      if (this.moveDialogIndex >= 0 && this.moveDialogIndex < this.layers.length) {
        Stack({ alignContent: Alignment.Center }) {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor('rgba(0,0,0,0.28)')
            .onClick((): void => { this.moveDialogIndex = -1; })
          DeskGroupPickDialog({
            layerName: this.layers[this.moveDialogIndex].name,
            currentGroupId: this.layers[this.moveDialogIndex].groupId,
            groups: this.groups,
            onConfirm: (groupId: number, newGroupName: string): void => {
              this.confirmMoveDialog(groupId, newGroupName);
            },
            onClose: (): void => { this.moveDialogIndex = -1; }
          })
        }
        .width('100%')
        .height('100%')
      }
      // 转到 XY：遮罩 + 居中面板（初值 = 打开时的相机中心）
      if (this.gotoOpen) {
        Stack({ alignContent: Alignment.Center }) {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor('rgba(0,0,0,0.28)')
            .onClick((): void => { this.gotoOpen = false; })
          DeskGotoDialog({
            initLat: this.gotoLat,
            initLon: this.gotoLon,
            onConfirm: (lat: number, lon: number): void => { this.confirmGoto(lat, lon); },
            onClose: (): void => { this.gotoOpen = false; }
          })
        }
        .width('100%')
        .height('100%')
      }
    }
    .width('100%')
    .height('100%')
  }
}