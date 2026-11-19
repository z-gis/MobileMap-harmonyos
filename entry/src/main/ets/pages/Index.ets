// Index.ets —— 主地图页（对应 Android ui.activity.MainActivity）。
//
// 本页是全部功能域的装配点：创建内核视图与八个地图控制器、按 Android 侧同一顺序互接回调、
// 装配图层与相机、拾取分流到各详情入口、HUD 控件（缩放/注记/定位/测量/轨迹/拍照/移动到）。
//
// 与 Android 的平台差异（功能等价，仅载体不同）：
//  · Android 图源/栅格结构变更调 activity.recreate()；鸿蒙侧 NativeMapView 是 @Component（不可 new），
//    故以 ForEach 的键（mapEpoch）触发子组件销毁重建，等价一次「重进界面」；
//  · Android 的 MediaManageDialog 等弹层在本端是独立页面（PhotoPage）；定位详情 0.3.0.1 起本端
//    同样做成真对话框（components/LocationDetailDialog）；
//  · 权限门由 Android 的「所有文件访问」收敛为定位权限（沙箱无全局文件概念，见 PermissionUtil）；
//  · 启动遮罩门控同 Android：矢量加载完成且最少展示 3s 才淡出，另加最长兜底时长防卡死。

import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { display, router } from '@kit.ArkUI';
import { Camera, NativeMapView, VectorExtent, ViewMode } from '@zys/globecore';
import { LocationDetailDialog } from '../components/LocationDetailDialog';
import { DetailTitleHandle, MeasureDetailDialog } from '../components/MeasureDetailDialog';
import { MediaEditDialog } from '../components/MediaEditDialog';
import { PhotoSheetDialog } from '../components/PhotoSheetDialog';
import { PieMenuAction, PieMenuLayer, PieMenuSpec } from '../components/PieMenuLayer';
import { MoveToDialog } from '../components/MoveToDialog';
import { NameEditDialog } from '../components/NameEditDialog';
import { AppConfig } from '../common/AppConfig';
import { AppLog } from '../common/AppLog';
import { PageData, PageKeys, PageSignals } from '../common/PageData';
import { PermissionUtil } from '../common/PermissionUtil';
import { Theme } from '../common/Theme';
import { Ui } from '../common/Ui';
import { LayerInfo, MapDocument } from '../doc/DocModels';
import { DocumentListener, DocumentManager } from '../doc/DocumentManager';
import { BackgroundLocationController } from '../location/BackgroundLocationController';
import { LocationManager, LocationPoint } from '../location/LocationManager';
import { MediaCaptureHelper } from '../media/MediaCaptureHelper';
import { MediaPackage } from '../media/MediaPackage';
import { BusinessOverlayManager } from '../map/BusinessOverlayManager';
import { CameraNavigator, DEFAULT_LAT, DEFAULT_LON } from '../map/CameraNavigator';
import { FeatureDetailRequest, FeaturePickController, PickRouter } from '../map/FeaturePickController';
import { GeomEditController, GeomEditPhase } from '../map/GeomEditController';
import { LocationController } from '../map/LocationController';
import { MapLayerController } from '../map/MapLayerController';
import { MapServices } from '../map/MapServices';
import { MapStyle } from '../map/MapStyle';
import { MeasureController, MeasureMode } from '../map/MeasureController';
import { SqlQueryController } from '../map/SqlQueryController';
import { TrackController } from '../map/TrackController';
import { ProjectManager } from '../project/ProjectManager';
import { MeasureRecord, MediaGroupRecord, PhotoRecord, SurveyPlot, TrackRecord } from '../project/ProjectModels';
import { TrackSharePackage } from '../track/TrackSharePackage';
import { FeatureIcons } from '../vector/FeatureIcons';
import { ImportResult, VectorFileImporter } from '../vector/VectorFileImporter';
import { AndroidIcons, IconBitmap } from '../vector/AndroidIcons';
import { LayerManageParams, SurveyEditParams } from './RouteParams';

const TAG: string = 'Index';

/** 图标按钮边长（Android dimens main_icon_size=32dp） */
const ICON_SIZE: number = 32;
/** 图标按钮底色（Android colors main_icon_bg=#a0dddddd） */
const ICON_BG: string = '#A0DDDDDD';
/**
 * 图标按钮文字色（深灰，全栏统一，含「北」）。
 * Android 早期还有 jni_map_go（白字 textColor=@color/white），该键已删、「移动到」改挂中心坐标文本；
 * 那两枚在 Android 上本就与一排深色图形图标（nav_*.png）同放于 #a0dddddd 浅底，白字只是点缀；本端 HUD 全部以文字
 * 标签代替图标，白字落在同一浅底上几乎看不清，故不照搬，统一用深色。
 */
const ICON_TEXT: string = '#FF20241F';
/** 图标按钮文字字号（32vp 方块内容纳两字标签） */
const ICON_FONT: number = 11;
/** 缩放面板内部（＋ / 级别 / －）间距：比外群 space 更小，收紧「放大 / 缩小」两键距离 */
const ZOOM_GAP: number = 2;
/** 左右边距（Android marginStart/End=10） */
const SIDE_MARGIN: number = 10;
/** 顶部控件下移量（避开状态栏，Android marginTop=50） */
const TOP_MARGIN: number = 50;
/** 左下/右下竖排距「底部信息条上沿」的间隙（信息条已贴底，按钮紧随其上即可，不再沿用 Android
 *  非全屏布局里的 marginBottom=60：那边导航栏本就在内容区之外，此处叠加避让会离得偏远） */
const SIDE_BOTTOM_GAP: number = 6;
/** 底部状态栏高度与底色（Android 24dp / #80111111） */
const STATUS_HEIGHT: number = 24;
const STATUS_BG: string = '#80111111';
/** 「矢量加载中」胶囊底色（Android #B3111111） */
const PILL_BG: string = '#B3111111';
/** 测量采集工具条距「底部信息条上沿」的间隙 */
const TOOL_BOTTOM_GAP: number = 10;
/** 指北针显示阈值（度）：|heading| 超过此值且 3D 才显示（手势尾差不足半度视为正北） */
const HEADING_SHOW_THRESHOLD_DEG: number = 0.5;
/** 冷启动遮罩最少展示时长（毫秒，Android STARTUP_MIN_DISPLAY_MS） */
const STARTUP_MIN_DISPLAY_MS: number = 3000;
/** 遮罩加载轮询间隔（毫秒） */
const STARTUP_LOAD_POLL_MS: number = 200;
/** 遮罩最长兜底（毫秒）：装配异常时也不允许永久遮挡 */
const STARTUP_MAX_MS: number = 20000;
const SPLASH_TEXT: string = '正在加载地图资源...';

/**
 * 主地图页。
 * 控制器字段全部为 `X | undefined`：NativeMapView 的 onReady 之前不存在，
 * 装配期用局部变量承接（ArkTS 无非空断言），完成后一并写入字段与 MapServices。
 */
@Entry
@Component
struct Index {
  // ── HUD 状态（控制器回调驱动刷新）──
  @State mapEpoch: number = 0;
  @State density: number = 1.0;
  @State level: number = 0;
  @State centerText: string = '';
  @State locationText: string = '未定位';
  @State compassVisible: boolean = false;
  @State vectorLoading: boolean = false;
  @State annotationOn: boolean = true;
  @State showCross: boolean = true;
  @State measureCapturing: boolean = false;
  @State trackRecording: boolean = false;
  @State trackPaused: boolean = false;
  @State following: boolean = false;
  @State splash: boolean = true;
  /** 底部导航条避让高度（vp）：窗口开了全屏布局，底部 HUD 需自行上移，由 EntryAbility 写入 AppStorage */
  @StorageProp('bottomInsetVp') bottomInset: number = 0;
  /** 横屏标志：可视高度不足，底部按钮群由竖排改横排，保证任何屏幕比例下按钮互不重叠（根 Stack onAreaChange 维护） */
  @State hudLandscape: boolean = false;
  /**
   * 长按落点圆菜单：内容与开关。
   * 拆成两个字段而不是 `PieMenuSpec | undefined`——build() 里对可空字段的类型窄化不可靠，
   * 浮层构造参数拿到 undefined 会直接编译报错。
   */
  @State pieMenu: PieMenuSpec = new PieMenuSpec();
  @State pieMenuOpen: boolean = false;
  /** 几何编辑态（gdb/shp 分割/删除/合并）：阶段驱动 HUD 显隐与底部工具条 */
  @State geomPhase: GeomEditPhase = GeomEditPhase.NONE;
  @State geomSplitPoints: number = 0;
  @State geomIsPolygon: boolean = false;
  @State geomFid: number = -1;

  // ── 地图控制器（onReady 后就位）──
  private appCtx: common.UIAbilityContext | undefined = undefined;
  private view: NativeMapView | undefined = undefined;
  private navigator: CameraNavigator | undefined = undefined;
  private layers: MapLayerController | undefined = undefined;
  private overlays: BusinessOverlayManager | undefined = undefined;
  private measure: MeasureController | undefined = undefined;
  private track: TrackController | undefined = undefined;
  private locationCtl: LocationController | undefined = undefined;
  private sql: SqlQueryController | undefined = undefined;
  private pick: FeaturePickController | undefined = undefined;
  private capture: MediaCaptureHelper | undefined = undefined;
  private geomEdit: GeomEditController | undefined = undefined;

  // ── 弹层与挂起任务 ──
  private measureDialog: CustomDialogController | undefined = undefined;
  private moveDialog: CustomDialogController | undefined = undefined;
  private mediaDialog: CustomDialogController | undefined = undefined;
  /** 拍照点位详情弹层（点地图拍照标识先弹此层，对应 Android PhotoSheetDialog） */
  private photoSheet: CustomDialogController | undefined = undefined;
  /** 改名输入框（详情弹层标题栏「重命名」用，叠在详情弹层之上） */
  private nameDialog: CustomDialogController | undefined = undefined;
  /** 详情弹层标题就地刷新句柄：改名落库后 setTitle，不重建弹层（用户已改的色/线宽不丢）。
   *  每次开弹层换一个实例，弹层各自持有自己的挂钩，旧弹层销毁时的解绑不会误伤新弹层 */
  private detailTitle: DetailTitleHandle = new DetailTitleHandle();
  /** 拍照点位弹层标题就地刷新句柄（改名落库后 setTitle，同 detailTitle 口径） */
  private photoTitle: DetailTitleHandle = new DetailTitleHandle();
  /** 定位详情对话框（点底部定位文本弹出，对应 Android LocationDetailDialog.show） */
  private locDialog: CustomDialogController | undefined = undefined;
  /** 拍照点位编辑对话框的分组下拉数据（打开前取当前工程） */
  private mediaGroups: MediaGroupRecord[] = [];
  private splashPoll: number = -1;
  /** 冷启动标志：仅首装配完成后挂加载门控，重建（图源/栅格结构变更）时跳过遮罩 */
  private coldStart: boolean = true;
  /** 视口尺寸（vp）：onAreaChange 下发给相机反算与测量中心点 */
  private vpWidth: number = 0;
  private vpHeight: number = 0;
  private docListener: DocumentListener | undefined = undefined;

  // ── 生命周期 ──────────────────────────────────────────────────────

  aboutToAppear(): void {
    this.appCtx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      this.density = display.getDefaultDisplaySync().densityPixels;
    } catch (e) {
      AppLog.w('取屏幕密度失败，按 1.0 继续', `${e}`);
      this.density = 1.0;
    }
    // 文档监听器一次性创建：注册/注销须同一引用（DocumentManager 按下标移除）
    this.docListener = (doc: MapDocument): void => {
      this.onDocumentChanged(doc);
    };
  }

  onPageShow(): void {
    // 外部导入图层返回：缩放到新图层四至（Android ExternalImportHandler 的页面化等价）
    this.consumeImportedLayer();
    // 工程管理页打开/新建工程返回：清交接槽（数据签名已变，下面 overlays.rebuild 统一刷新，
    // 对齐 Android ProjectManageDialog 回调只重建叠加层）
    PageData.take(PageKeys.PROJECT_CHANGED);
    const nav: CameraNavigator | undefined = this.navigator;
    const overlays: BusinessOverlayManager | undefined = this.overlays;
    if (nav === undefined || overlays === undefined) {
      return;
    }
    // 对应 Android onResume：数据签名变化才重建叠加层（二级页改显隐/增删测量轨迹样地后回来即见），并恢复轮询
    overlays.rebuild();
    nav.startPolling();
    // 视图模式回读：设置页「3D 视图（球模式）」开关改的就是这一项，返回主界面即时生效（Android onResume 同调）
    this.applyViewMode();
  }

  onPageHide(): void {
    // 对应 Android onPause：停轮询省电、视角落盘（独立 prefs，不碰共享文档相机）
    const nav: CameraNavigator | undefined = this.navigator;
    if (nav !== undefined) {
      nav.stopPolling();
      nav.saveCameraState();
    }
  }

  onBackPress(): boolean {
    // 圆菜单开着：返回键只收菜单，不动应用
    if (this.pieMenuOpen) {
      this.pieMenuOpen = false;
      return true;
    }
    // 几何编辑态分级退出：画线/选靶子模式先回工具条，工具条再整体退出
    if (this.geomPhase === GeomEditPhase.SPLIT_LINE || this.geomPhase === GeomEditPhase.MERGE_PICK) {
      const ge: GeomEditController | undefined = this.geomEdit;
      if (ge !== undefined) {
        ge.cancelSubMode();
      }
      return true;
    }
    if (this.geomPhase === GeomEditPhase.EDIT) {
      const ge: GeomEditController | undefined = this.geomEdit;
      if (ge !== undefined) {
        ge.exit();
      }
      return true;
    }
    this.confirmExit();
    return true;
  }

  aboutToDisappear(): void {
    this.clearSplashPoll();
    this.teardownMap();
    MapServices.instance.clear();
  }

  /** 装配收尾：停轮询、注销定位与文档监听、清空登记表（重建与销毁共用） */
  private teardownMap(): void {
    const nav: CameraNavigator | undefined = this.navigator;
    if (nav !== undefined) {
      nav.stopPolling();
    }
    const location: LocationController | undefined = this.locationCtl;
    if (location !== undefined) {
      location.dispose();
    }
    const layers: MapLayerController | undefined = this.layers;
    if (layers !== undefined) {
      layers.dispose();
    }
    const listener: DocumentListener | undefined = this.docListener;
    if (listener !== undefined) {
      DocumentManager.getInstance().unregisterListener(listener);
    }
    PageSignals.unbind(PageKeys.EXTERNAL_OPEN_URI);
    if (this.view !== undefined) {
      this.view.setOnTapListener(undefined);
    }
    this.view = undefined;
    this.navigator = undefined;
    this.layers = undefined;
    this.overlays = undefined;
    this.measure = undefined;
    this.track = undefined;
    this.locationCtl = undefined;
    this.sql = undefined;
    this.pick = undefined;
    this.capture = undefined;
    this.geomEdit = undefined;
    this.geomPhase = GeomEditPhase.NONE;
    // 落点圆菜单是瞬态浮层：装配收尾一并收掉，别让它带着旧坐标活到下一轮
    this.pieMenuOpen = false;
    MapServices.instance.clear();
  }

  // ── 装配 ─────────────────────────────────────────────────────────

  /**
   * 地图与控制器装配（对应 Android setupMapUi）：
   * 全部控制器以局部变量创建并互相接线（闭包内直接引用局部量，避免访问尚未赋值的字段），
   * 再按「瓦片层 → 栅格层 → 相机 → 矢量层 → 叠加层」的 Android 同序装配，最后登记到 MapServices。
   */
  private async setupMap(view: NativeMapView): Promise<void> {
    const ctx: common.UIAbilityContext | undefined = this.appCtx;
    if (ctx === undefined) {
      AppLog.w('宿主上下文未就绪，跳过地图装配');
      return;
    }
    const t0: number = Date.now();
    const doc: MapDocument | null = DocumentManager.getInstance().getDocument();

    const navigator: CameraNavigator = new CameraNavigator(view, ctx);
    const layers: MapLayerController = new MapLayerController(view);
    const sql: SqlQueryController = new SqlQueryController(view, navigator);
    const overlays: BusinessOverlayManager = new BusinessOverlayManager(view, ctx);
    const measure: MeasureController = new MeasureController(view, ctx);
    const track: TrackController = new TrackController(view, ctx, navigator);
    const location: LocationController = new LocationController(view, navigator);
    const pickRouter: PickRouter = new PickRouter();
    const pick: FeaturePickController = new FeaturePickController(view, ctx, layers, overlays, sql,
      measure, pickRouter);
    const capture: MediaCaptureHelper = new MediaCaptureHelper(ctx);
    const geomEdit: GeomEditController = new GeomEditController(view, ctx, layers, pick);
    geomEdit.onStateChanged = (phase: GeomEditPhase): void => {
      this.geomPhase = phase;
      this.geomSplitPoints = geomEdit.pointCount();
      this.geomIsPolygon = geomEdit.isPolygon();
      this.geomFid = geomEdit.targetFid();
    };

    // 互接线（与 Android setupMapUi 的构造后赋值一一对应）
    layers.extentProvider = (): VectorExtent | undefined => {
      const cam: Camera | undefined = view.getCamera();
      return cam === undefined ? undefined : navigator.computeVisibleExtent(cam);
    };
    layers.onRebuildOverlays = (): void => {
      overlays.rebuild();
    };
    layers.onVectorLoadingChange = (loading: boolean): void => {
      this.vectorLoading = loading;
    };
    layers.onNoBaseSource = (): void => {
      Ui.toast('无可见地图源，请在图层管理的地图源中启用底图');
    };
    navigator.onCameraSettled = (cam: Camera, extent: VectorExtent): void => {
      layers.onCameraSettled(extent);
    };
    navigator.onStatusChanged = (lv: number, center: string): void => {
      this.level = lv;
      this.centerText = center;
    };
    navigator.onHeadingChanged = (deg: number): void => {
      this.compassVisible = Math.abs(deg) > HEADING_SHOW_THRESHOLD_DEG
        && view.getViewMode() === ViewMode.THREE_D;
    };
    overlays.isCapturing = (): boolean => measure.capturing() || track.capturing() || geomEdit.capturing();
    overlays.onOverlayLayersCleared = (): void => {
      sql.onOverlayLayersCleared();
      pick.onOverlayLayersCleared();
    };
    overlays.restoreQueryHighlight = (): void => {
      sql.restoreAfterRebuild();
    };
    measure.rebuildOverlays = (): void => {
      overlays.rebuild();
    };
    measure.onCapturingChanged = (capturing: boolean, mode: MeasureMode): void => {
      this.measureCapturing = capturing;
    };
    track.rebuildOverlays = (): void => {
      overlays.rebuild();
    };
    track.onStateChanged = (recording: boolean, paused: boolean): void => {
      this.trackRecording = recording;
      this.trackPaused = paused;
      // 轨迹开始/恢复记录自动锁定跟随、停止记录自动解锁还原（Android MainActivity 同一接线；
      // 暂停不改 recording 故不解锁，setFollowEnabled 幂等判重）
      location.setFollowEnabled(recording);
      // 后台定位保活门控：记录中且开关为开时申请 location 长时任务，停止记录即刻释放（幂等）
      BackgroundLocationController.onTrackRecordingChanged(ctx, recording);
    };
    location.onLocationText = (text: string): void => {
      this.locationText = text;
    };
    location.onFollowChanged = (enabled: boolean): void => {
      this.following = enabled;
    };
    location.onTrackLocation = (point: LocationPoint): void => {
      track.onLocation(point);
    };
    capture.onMediaChanged = (): void => {
      overlays.rebuild();
    };
    capture.onEditSession = (placemark: PhotoRecord): void => {
      this.openMediaEdit(placemark, ctx);
    };
    this.bindPickRouter(pickRouter, ctx);
    // 几何编辑态门控：编辑期间单击/长按整体交编辑控制器（画线加点/选靶），不弹详情与圆菜单
    pickRouter.isGeomEditing = (): boolean => geomEdit.phase() !== GeomEditPhase.NONE;
    pickRouter.handleEditTap = (x: number, y: number): boolean => geomEdit.handleTap(x, y);

    // 单击回调在此就挂上：必须在下面那串 await（相机就位/矢量层装配/叠加层重建）之前——
    // 放在尾部时，任一 await 卡住或抛异常都会让 setOnTapListener 永不执行，
    // 表现就是「地图能看能拖，但点测量/点要素毫无反馈」（测量加点、要素拾取同走这一路）。
    view.setOnTapListener((x: number, y: number): void => {
      // 单位自检（拾取偏位排障用）：回传坐标须与引擎视口同口径（px = vp×密度）。
      // 若日志里 x/y 的上限只到 vp 宽而视口是 px 宽，说明触摸层回了 vp，pickVector/screenToGeo 会整体偏 1/密度。
      AppLog.d(`单击回传 (${x.toFixed(1)},${y.toFixed(1)}) 视口px ${(this.vpWidth * this.density).toFixed(0)}x${(this.vpHeight * this.density).toFixed(0)} density=${this.density.toFixed(2)}`);
      pick.onMapTap(x, y);
    });
    AppLog.i(`${TAG} 单击回调已注册（拾取/测量共用）`);

    // 长按回调与单击同口径注册（同一 native 事件源、同一像素坐标），空白落点开圆菜单（含兴趣点拍照）。
    // 长按触发后抬手那次补发单击由 FeaturePickController 按「圆菜单是否还浮着」吞掉（判据在 bindPickRouter 下发），此处无需再处理。
    view.setOnLongPressListener((x: number, y: number): void => {
      // 单位自检同单击：长按回传须与视口 px 同量级，若只到 vp 宽则落点经纬度会整体偏 1/密度
      AppLog.d(`长按回传 (${x.toFixed(1)},${y.toFixed(1)}) 视口px ${(this.vpWidth * this.density).toFixed(0)}x${(this.vpHeight * this.density).toFixed(0)} density=${this.density.toFixed(2)}`);
      pick.onMapLongPress(x, y);
    });
    AppLog.i(`${TAG} 长按回调已注册（空白落点=圆菜单）`);

    // 定位标记图标：对齐 Android MainActivity 的 ic_compass（rawfile 同图解码，带外圈指北环），
    // 宽高必须传解码后的真实像素尺寸（桥接层按 argb.length===w*h 校验，不符即丢纹理回退蓝点）。
    // 解码失败才退回程序化三角，同样按纹理真实分辨率 64×64 传尺寸。
    const markerIcon: IconBitmap | undefined = AndroidIcons.of(this.appCtx, AndroidIcons.COMPASS);
    if (markerIcon !== undefined) {
      view.setLocationMarkerIcon(markerIcon.argb, markerIcon.w, markerIcon.h);
    } else {
      view.setLocationMarkerIcon(FeatureIcons.pixels(FeatureIcons.TRIANGLE, 0xFF3DA5FF),
        FeatureIcons.SIZE, FeatureIcons.SIZE);
    }
    if (this.vpWidth > 0) {
      // 视口以 px 下发：screenToGeo/pickVector 走的是引擎视口（surface px）坐标系，传 vp 会整体偏 1/密度
      navigator.setViewportSize(this.vpWidth * this.density, this.vpHeight * this.density);
      measure.setViewportSize(this.vpWidth * this.density, this.vpHeight * this.density);
    }

    // 字体先行加载（对齐 Android MainActivity.setFontPath("")）：native FontAtlas 只能由宿主显式触发
    // 加载，否则 drawVectorLabels/drawVectorLabels3D 首行 isLoaded() 判假即整体早退，矢量层与叠加层的
    // 文字标注一个都不出（几何线/面/点照画）——表现为「测量有线面无标注文字」。空串走 native 系统字体自动
    // 探测；必须在矢量层/叠加层装配之前调用，使首帧即带字体。若日志报「未找到可用系统字体」，需改为随包
    // 附带字体文件并传其可读绝对路径。
    view.setFontPath('');

    // 图层栈与相机：相机必须先于矢量层就位，使大数据矢量层首屏按视口范围加载
    layers.buildLayers(doc);
    layers.syncRasterLayers(doc);
    let t: number = Date.now();
    const cam: Camera = await navigator.initialCamera(
      doc === null ? Number.NaN : doc.camLongitude,
      doc === null ? Number.NaN : doc.camLatitude,
      doc === null ? Number.NaN : doc.camAltitude);
    view.setCamera(cam);
    AppLog.i(`${TAG} 相机就位 ${Date.now() - t}ms`);
    t = Date.now();
    layers.syncVectorLayers(doc);
    AppLog.i(`${TAG} 矢量层装配 ${Date.now() - t}ms`);
    // 工程装载（含首启旧库迁移）必须先于首轮叠加层重建：叠加层读的是当前工程数据
    // （Android 在 setupMapUi 前 ensureLoaded；EntryAbility 已预热，此处 await 同一 Promise）
    t = Date.now();
    await ProjectManager.get(ctx).ensureLoaded();
    AppLog.i(`${TAG} 工程装载 ${Date.now() - t}ms`);
    t = Date.now();
    await overlays.rebuild();
    AppLog.i(`${TAG} 叠加层重建 ${Date.now() - t}ms`);

    navigator.updateStatusText();
    DocumentManager.getInstance().registerListener(this.docListener);

    // 定位：已授权直接开始，未授权申请（拒绝只提示，与 Android locationPermissionLauncher 同口径）
    PermissionUtil.hasLocation(ctx).then((granted: boolean): void => {
      if (granted) {
        location.startLocating();
        return;
      }
      PermissionUtil.requestLocation(ctx).then((ok: boolean): void => {
        if (ok) {
          location.startLocating();
        } else {
          Ui.toast('未授予定位权限，定位与轨迹功能不可用');
        }
      }, (e: Error): void => {
        AppLog.e('申请定位权限失败', `${e}`);
      });
    }, (e: Error): void => {
      AppLog.e('检查定位权限失败', `${e}`);
    });

    // 上次采集未结束（进程被回收）时恢复草稿轨迹：读回落库点重建活动轨迹并恢复记录态
    await track.restoreDraftTrack();
    navigator.startPolling();
    // 视图模式取自系统配置（0.3.0.1 起不再随相机独立持久化，改由设置页「3D 视图」开关控制）
    this.applyViewMode();
    this.annotationOn = layers.isAnnotationVisible();
    this.showCross = doc === null ? true : doc.systemConfig.showCenterCross;

    // 登记到进程内服务表：二级页（图层管理/轨迹/照片/要素详情）据此驱动地图
    const services: MapServices = MapServices.instance;
    this.view = view;
    this.navigator = navigator;
    this.layers = layers;
    this.overlays = overlays;
    this.measure = measure;
    // 视口兜底下发：onAreaChange 若先于本行赋值 this.measure 触发（当时 measure 仍 undefined 被跳过），
    // 之后区域不再变化 → measure.vpWidth 恒为 0 → addCenterPoint 直接 return（中心点取坐标无反应）。
    // 赋值后立即用当前尺寸补一次，闭合这一时序空窗（与 onAreaChange 同 px 口径）。
    if (this.vpWidth > 0) {
      measure.setViewportSize(this.vpWidth * this.density, this.vpHeight * this.density);
    }
    this.track = track;
    this.locationCtl = location;
    this.sql = sql;
    this.pick = pick;
    this.capture = capture;
    this.geomEdit = geomEdit;
    services.view = view;
    services.layers = layers;
    services.overlays = overlays;
    services.camera = navigator;
    services.location = location;
    services.sql = sql;
    services.measure = measure;
    services.track = track;
    services.pick = pick;

    AppLog.i(`${TAG} 地图装配完成 合计=${Date.now() - t0}ms`);
    this.beginSplashGate();
    // 外部打开：冷启动时 URI 已在交接槽里（EntryAbility.onCreate 早于本页装配），此处消费；
    // 再绑定信号承接运行中的 onNewWant（singleton 复用实例，不会再走 onCreate）
    PageSignals.bind(PageKeys.EXTERNAL_OPEN_URI, (): void => {
      this.consumeExternalOpen();
    });
    this.consumeExternalOpen();
  }

  /** 装配失败兜底：解除遮罩并提示（不抛出，避免页面停在空白遮罩） */
  private onSetupFailed(e: Error): void {
    AppLog.e('地图装配失败', `${e}`);
    this.clearSplashPoll();
    this.splash = false;
    Ui.toastLong('地图初始化失败，请重启应用');
  }

  /**
   * 拾取分流（对应 Android MainActivity 实现的 PickHitRouter）：
   * 测量/轨迹命中复用同一个样式对话框；点位命中直接进照片浏览；样地命中进录入页；
   * 文件要素命中走详情页（对象经 PageData 交接，属性异步回取后经 PageSignals 通知回填）；
   * 长按空白落点开圆菜单（capture/navigator 由本页面字段取，不作参数传）。
   */
  private bindPickRouter(pickRouter: PickRouter, ctx: common.UIAbilityContext): void {
    pickRouter.onMeasureHit = (recordId: number): void => {
      // 记录可能已被外部删除：取不到即静默忽略
      const hit: MeasureRecord | null = ProjectManager.get(ctx).findMeasure(recordId);
      if (hit !== null) {
        this.openMeasureDetail(hit, ctx);
      }
    };
    pickRouter.onTrackHit = (recordId: number): void => {
      const hit: TrackRecord | null = ProjectManager.get(ctx).findTrack(recordId);
      if (hit !== null) {
        this.openTrackDetail(hit, ctx);
      }
    };
    pickRouter.onMediaHit = (placemark: PhotoRecord): void => {
      // 与 Android 一致：点拍照标识先弹详情层（重命名/备注/分享/删除 + 照片网格），不再直进浏览页
      this.openPhotoSheet(placemark, ctx);
    };
    pickRouter.onSurveyHit = (plotId: number): void => {
      const plot: SurveyPlot | null = ProjectManager.get(ctx).findSurveyPlot(plotId);
      if (plot === null) {
        return;
      }
      const params: SurveyEditParams = new SurveyEditParams();
      params.sourcePath = plot.sourcePath;
      params.sourceFid = plot.sourceFid;
      params.compartmentNo = plot.compartmentNo;
      params.centerLat = plot.centerLatitude;
      params.centerLon = plot.centerLongitude;
      params.plotId = plot.id;
      router.pushUrl({ url: 'pages/SurveyEditPage', params: params });
    };
    pickRouter.onFeatureDetail = (req: FeatureDetailRequest): void => {
      PageData.put(PageKeys.FEATURE_DETAIL, req);
      router.pushUrl({ url: 'pages/FeatureDetailPage' });
    };
    pickRouter.onFeatureAttributes = (req: FeatureDetailRequest): void => {
      // req 与详情页持有同一对象：属性字段已回填，发信号让页面重取一次即可
      AppLog.d(`要素属性已回取: ${req.path}#${req.fid}`);
      PageSignals.fire(PageKeys.FEATURE_DETAIL);
    };
    pickRouter.onDropPoint = (lat: number, lon: number, xPx: number, yPx: number,
      hasFeature: boolean): void => {
      this.showMapPieMenu(lat, lon, xPx, yPx, hasFeature);
    };
    // 长按抬手补发的那次单击归 native（浮层遮罩拦不住已在进行的手势），判据交回本页的菜单开关：
    // 菜单还浮着 = 地图不该响应这次单击，按住多久都吞得掉（旧的时间窗在慢放开时会漏）。
    pickRouter.isPieMenuOpen = (): boolean => this.pieMenuOpen;
  }

  /**
   * 长按圆菜单（对应 Android MainActivity.showMapPieMenu，并把它那份 showFeatureEditMenu 合成一项）：
   * 以落点为锚弹快捷动作，图标在上、文案在下（见 PieMenuLayer）；命中要素时首位多挂一项：
   * gdb/shp 文件要素挂「编辑」（进几何编辑模式），其余挂「属性」（按同一落点重跑单击分流：
   * 测量/轨迹/拍照点位/样地→各自详情层），于是一份菜单同时管「落点」和「要素」两种语义。
   * 锚点口径：native 回传 px（与 screenToGeo 同一引擎口径），浮层是 ArkUI 布局要 vp，故 ÷densityPixels。
   * 兴趣点仍守「确认后才建点」：点位记录在点「添加兴趣点」之后才落库，取消/收起不留空点。
   */
  private showMapPieMenu(lat: number, lon: number, xPx: number, yPx: number, hasFeature: boolean): void {
    const density: number = this.density > 0 ? this.density : 1;
    // 经度在前、6 位小数，与定位详情弹层的复制口径一致
    const coordText: string = `${Ui.fixed(lon)},${Ui.fixed(lat)}`;
    const capture: MediaCaptureHelper | undefined = this.capture;
    const navigator: CameraNavigator | undefined = this.navigator;
    const pick: FeaturePickController | undefined = this.pick;
    const actions: PieMenuAction[] = [];
    if (hasFeature) {
      // gdb/shp 文件要素 →「编辑」进几何编辑模式（分割/删除/合并）；
      // 其余（业务叠加/其他格式）→「属性」走原详情分流（原「编辑」项改名，语义不变）
      const ge: GeomEditController | undefined = this.geomEdit;
      if (ge !== undefined && ge.editableHitAt(xPx, yPx)) {
        actions.push(new PieMenuAction($rawfile('ic_pie_edit.svg'), '编辑', (): void => {
          const edit: GeomEditController | undefined = this.geomEdit;
          if (edit === undefined) {
            AppLog.w('[PieMenu] 编辑：几何编辑控制器未就绪');
            return;
          }
          edit.enterAt(xPx, yPx);
        }));
      } else {
        actions.push(new PieMenuAction($rawfile('ic_pie_edit.svg'), '属性', (): void => {
          if (pick === undefined) {
            AppLog.w('[PieMenu] 属性：拾取控制器未就绪');
            return;
          }
          pick.editHitAt(xPx, yPx);
        }));
      }
    }
    // 居中到此处：相机平移到落点，保留当前缩放级别
    actions.push(new PieMenuAction($rawfile('ic_pie_center.svg'), '居中到此处', (): void => {
      if (navigator === undefined) {
        AppLog.w('[PieMenu] 居中到此处：相机导航器未就绪');
        return;
      }
      navigator.moveToLocation(lat, lon);
    }));
    // 复制坐标：落点经纬度写系统剪贴板
    actions.push(new PieMenuAction($rawfile('ic_pie_copy.svg'), '复制坐标', (): void => {
      this.copyToClipboard(coordText);
    }));
    // 添加兴趣点：以落点坐标建点位，图片来源二选一（相机连拍 / 相册选图），都不依赖定位
    actions.push(new PieMenuAction($rawfile('ic_pie_poi.svg'), '添加兴趣点', (): void => {
      if (capture === undefined) {
        AppLog.w('[PieMenu] 添加兴趣点：拍照助手未就绪');
        return;
      }
      Ui.items('兴趣点图片来源', ['拍照', '从相册选图']).then((which: number): void => {
        // 弹窗被取消（-1）时什么都不做：点位还没建，天然不留空点
        let run: Promise<void> = Promise.resolve();
        if (which === 0) {
          run = capture.startSessionAt(lat, lon, '兴趣点');
        } else if (which === 1) {
          run = capture.addPhotosFromAlbum(lat, lon, '兴趣点');
        }
        run.then((): void => {}, (e: Error): void => {
          AppLog.e('落点兴趣点写入失败', e);
        });
      }, (e: Error): void => {
        AppLog.e('兴趣点图片来源弹窗失败', e);
      });
    }));
    // 位置信息：直接报出落点坐标
    actions.push(new PieMenuAction($rawfile('ic_pie_info.svg'), '位置信息', (): void => {
      Ui.toast(`落点坐标 ${coordText}`);
    }));

    const spec: PieMenuSpec = new PieMenuSpec();
    spec.anchorXVp = xPx / density;
    spec.anchorYVp = yPx / density;
    spec.actions = actions;
    this.openPieMenu(spec);
  }

  /**
   * 弹出圆菜单。浮层的内容参数只在组件创建时赋值一次（普通成员，@Prop 深拷贝又会把 run 函数丢掉），
   * 故菜单还开着又要换锚点时先收掉、下一帧再弹——原地改 this.pieMenu 会得到一份停在旧坐标的菜单。
   */
  private openPieMenu(spec: PieMenuSpec): void {
    if (this.pieMenuOpen) {
      this.pieMenuOpen = false;
      setTimeout((): void => {
        this.pieMenu = spec;
        this.pieMenuOpen = true;
      }, 0);
      return;
    }
    this.pieMenu = spec;
    this.pieMenuOpen = true;
  }

  /** 写系统剪贴板（口径同定位详情弹层的「复制」：成功/失败都给 Toast，异常只记日志不抛） */
  private copyToClipboard(text: string): void {
    try {
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      pasteboard.getSystemPasteboard().setData(data).then((): void => {
        Ui.toast('坐标已复制');
      }, (e: Error): void => {
        AppLog.e('写剪贴板失败', `${e}`);
        Ui.toast('复制失败');
      });
    } catch (e) {
      AppLog.e('写剪贴板失败', `${e}`);
      Ui.toast('复制失败');
    }
  }

  // ── 弹层：测量 / 轨迹 / 拍照点位 / 移动到 ──────────────────────────

  /** 测量详情（Android MeasureCaptureController.showMeasureDetail 等价） */
  private openMeasureDetail(record: MeasureRecord, ctx: common.UIAbilityContext): void {
    this.detailTitle = new DetailTitleHandle();
    this.measureDialog = new CustomDialogController({
      builder: MeasureDetailDialog({
        title: record.name,
        typeText: MeasureController.typeDisplayName(record.type),
        geometryText: MeasureController.geometryText(record),
        widthEditable: record.type !== MeasureRecord.TYPE_POINT,
        initialColor: ProjectManager.parseColor(record.color, Index.defaultColorForMeasureType(record.type)),
        initialLineWidth: record.lineWidth,
        initialRemark: record.remark,
        titleHandle: this.detailTitle,
        onSave: (color: number, lineWidth: number): void => {
          ProjectManager.get(ctx).updateMeasureStyle(record.id, color, lineWidth).then((): void => {
            this.rebuildOverlays();
            Ui.toast('样式已更新');
          }, (e: Error): void => {
            AppLog.e('更新测量样式失败', `${e}`);
          });
        },
        onDelete: (): void => {
          this.confirmDeleteMeasurement(record, ctx);
        },
        onRename: (): void => {
          this.promptRenameDetail(record.id, false, record.name, ctx);
        },
        onRemark: (remark: string): void => {
          this.saveMeasureRemark(record, remark, ctx);
        },
      }),
      customStyle: true,
      alignment: DialogAlignment.Center,
      autoCancel: true,
    });
    this.measureDialog.open();
  }

  /** 轨迹详情（Android TrackCaptureController.showTrackDetail 复用同一对话框） */
  private openTrackDetail(record: TrackRecord, ctx: common.UIAbilityContext): void {
    this.detailTitle = new DetailTitleHandle();
    this.measureDialog = new CustomDialogController({
      builder: MeasureDetailDialog({
        title: record.name,
        typeText: '轨迹',
        geometryText: TrackController.geometryText(record),
        widthEditable: true,
        initialColor: ProjectManager.parseColor(record.color, 0xFF33CCFF),
        initialLineWidth: record.lineWidth,
        titleHandle: this.detailTitle,
        onSave: (color: number, lineWidth: number): void => {
          ProjectManager.get(ctx).updateTrackStyle(record.id, color, lineWidth).then((): void => {
            this.rebuildOverlays();
            Ui.toast('样式已更新');
          }, (e: Error): void => {
            AppLog.e('更新轨迹样式失败', `${e}`);
          });
        },
        onDelete: (): void => {
          this.confirmDeleteTrack(record, ctx);
        },
        onRename: (): void => {
          this.promptRenameDetail(record.id, true, record.name, ctx);
        },
        // 分享按导出 shp 数据包（折线 + WGS84，见 track/TrackSharePackage）经系统分享面板发出
        onShare: (): void => {
          TrackSharePackage.shareTrack(ctx, record);
        },
      }),
      customStyle: true,
      alignment: DialogAlignment.Center,
      autoCancel: true,
    });
    this.measureDialog.open();
  }

  /** 测量类型默认色（记录未设色时对话框初值，对齐 Android defaultColorForType） */
  private static defaultColorForMeasureType(type: string): number {
    if (type === MeasureRecord.TYPE_AREA) {
      return MapStyle.MEASURE_COLOR_AREA;
    }
    if (type === MeasureRecord.TYPE_POINT) {
      return MapStyle.MEASURE_COLOR_POINT;
    }
    return MapStyle.MEASURE_COLOR_DISTANCE;
  }

  /**
   * 详情弹层「编辑」→ 改名（Android promptRenameMeasure / promptRenameTrack 等价）：
   * 名称写库 → 重建叠加层刷新标注 → 经当前弹层的 titleHandle 就地刷新标题 → 轻提示。
   * 弹层保持打开（改名框叠在其上），故用户未保存的颜色/线宽不丢。
   * @param isTrack true=轨迹，false=测量
   */
  private promptRenameDetail(recordId: number, isTrack: boolean, currentName: string,
    ctx: common.UIAbilityContext): void {
    this.nameDialog = new CustomDialogController({
      builder: NameEditDialog({
        title: isTrack ? '重命名轨迹' : '重命名测量',
        label: isTrack ? '轨迹名称' : '测量名称',
        placeholder: '请输入名称',
        initialValue: currentName,
        onConfirmName: (name: string): void => {
          const pm: ProjectManager = ProjectManager.get(ctx);
          const task: Promise<void | boolean> =
            isTrack ? pm.updateTrackName(recordId, name) : pm.updateMeasureName(recordId, name);
          Promise.resolve(task).then((): void => {
            this.rebuildOverlays();
            this.detailTitle.setTitle(name);
            Ui.toast('已重命名');
          }, (e: Error): void => {
            AppLog.e(isTrack ? '轨迹改名失败' : '测量改名失败', `${e}`);
          });
        },
      }),
      customStyle: true,
      alignment: DialogAlignment.Center,
      autoCancel: true,
    });
    this.nameDialog.open();
  }

  private confirmDeleteMeasurement(record: MeasureRecord, ctx: common.UIAbilityContext): void {
    Ui.confirm('删除确认', `确定删除测量数据：${record.name} ？`, '删除').then((ok: boolean): void => {
      if (!ok) {
        return;
      }
      ProjectManager.get(ctx).removeMeasure(record.id).then((): void => {
        this.rebuildOverlays();
        Ui.toast('已删除');
      }, (e: Error): void => {
        AppLog.e('删除测量记录失败', `${e}`);
      });
    });
  }

  private confirmDeleteTrack(record: TrackRecord, ctx: common.UIAbilityContext): void {
    Ui.confirm('删除确认', `确定删除轨迹：${record.name} ？删除后该轨迹及其全部坐标点将一并删除。`,
      '删除').then((ok: boolean): void => {
        if (!ok) {
          return;
        }
        ProjectManager.get(ctx).removeTrack(record.id).then((): void => {
          this.rebuildOverlays();
          Ui.toast('已删除');
        }, (e: Error): void => {
          AppLog.e('删除轨迹失败', `${e}`);
        });
      });
  }

  /** 拍照会话完成后的「名称 + 分组」编辑面板（Android MediaEditDialog 等价） */
  private openMediaEdit(placemark: PhotoRecord, ctx: common.UIAbilityContext): void {
    this.mediaGroups = ProjectManager.get(ctx).listGroups();
    this.mediaDialog = new CustomDialogController({
      builder: MediaEditDialog({
        placemark: placemark,
        groups: this.mediaGroups,
        onConfirmEdit: (name: string, groupId: number, newGroupName: string): void => {
          this.applyMediaEdit(ctx, placemark.id, name, groupId, newGroupName);
        },
      }),
      customStyle: true,
      alignment: DialogAlignment.Center,
      autoCancel: true,
    });
    this.mediaDialog.open();
  }

  /** 新建分组要先落库拿到主键，再把点位改到该组（与 PhotoPage.applyEdit 同编排） */
  private applyMediaEdit(ctx: common.UIAbilityContext, placemarkId: number, name: string,
    groupId: number, newGroupName: string): void {
    this.saveMediaEdit(ctx, placemarkId, name, groupId, newGroupName).then((): void => {
      this.rebuildOverlays();
      // 拍照详情弹层若开着，就地刷新标题（句柄未绑定即落空，拍照会话流程不受影响）
      this.photoTitle.setTitle(name);
    }, (e: Error): void => {
      AppLog.e('保存拍照点位失败', `${e}`);
    });
  }

  private async saveMediaEdit(ctx: common.UIAbilityContext, placemarkId: number, name: string,
    groupId: number, newGroupName: string): Promise<void> {
    const pm: ProjectManager = ProjectManager.get(ctx);
    let target: number = groupId;
    if (newGroupName.length > 0) {
      const created: number = await pm.addGroup(newGroupName, Date.now());
      if (created < 0) {
        Ui.toast('新建分组失败');
        return;
      }
      target = created;
    }
    await pm.updatePhotoName(placemarkId, name);
    await pm.updatePhotoGroup(placemarkId, target);
    Ui.toast('已保存');
  }

  /** 拍照点位详情弹层（Android PhotoSheetDialog 等价）：重命名/备注/分享/删除 + 照片网格 */
  private openPhotoSheet(placemark: PhotoRecord, ctx: common.UIAbilityContext): void {
    this.photoTitle = new DetailTitleHandle();
    const pm: ProjectManager = ProjectManager.get(ctx);
    this.photoSheet = new CustomDialogController({
      builder: PhotoSheetDialog({
        placemark: placemark,
        gpkgPath: pm.currentProjectPath,
        cacheDir: ctx.cacheDir,
        titleHandle: this.photoTitle,
        onRename: (): void => {
          this.openMediaEdit(placemark, ctx);
        },
        onRemark: (remark: string): void => {
          this.savePhotoRemark(placemark, remark, ctx);
        },
        onShare: (): void => {
          MediaPackage.sharePlacemark(ctx, placemark);
        },
        onDelete: (): void => {
          this.confirmDeletePlacemark(placemark, ctx);
        },
      }),
      customStyle: true,
      alignment: DialogAlignment.Center,
      autoCancel: true,
    });
    this.photoSheet.open();
  }

  /** 拍照点位备注落库（编辑框已挪进 PhotoSheetDialog 底部行，本层只写库）：备注不上图，重建叠加层刷新标注 */
  private savePhotoRemark(placemark: PhotoRecord, remark: string, ctx: common.UIAbilityContext): void {
    // updatePhotoRemark 内部已把新备注写回内存记录，此处不再赋值
    ProjectManager.get(ctx).updatePhotoRemark(placemark.id, remark).then((): void => {
      this.rebuildOverlays();
      Ui.toast('备注已保存');
    }, (e: Error): void => {
      AppLog.e('保存照片备注失败', `${e}`);
    });
  }

  /** 测量备注写库（编辑框已挪进 MeasureDetailDialog 底部行，本层只写库）：落库后重建叠加层 */
  private saveMeasureRemark(record: MeasureRecord, remark: string, ctx: common.UIAbilityContext): void {
    ProjectManager.get(ctx).updateMeasureRemark(record.id, remark).then((ok: boolean): void => {
      if (!ok) {
        AppLog.e('保存测量备注失败', `id=${record.id}`);
        return;
      }
      this.rebuildOverlays();
      Ui.toast('备注已保存');
    }, (e: Error): void => {
      AppLog.e('保存测量备注失败', `${e}`);
    });
  }

  /** 删除拍照点位确认（Android PhotoSheetDialog.confirmDeletePlacemark 等价）：点位及全部照片一并删除 */
  private confirmDeletePlacemark(placemark: PhotoRecord, ctx: common.UIAbilityContext): void {
    Ui.confirm('删除确认', `确定删除拍照点位：${placemark.name} ？删除后该点位及全部照片将一并删除。`,
      '删除').then((ok: boolean): void => {
        if (!ok) {
          return;
        }
        ProjectManager.get(ctx).removePhoto(placemark.id).then((): void => {
          this.rebuildOverlays();
          Ui.toast('已删除');
        }, (e: Error): void => {
          AppLog.e('删除拍照点位失败', `${e}`);
        });
      });
  }

  /** 「移动到」：初值优先定位 > 相机中心 > 兜底默认；确认后平移（保留缩放级别） */
  private showMoveToDialog(): void {
    const last: LocationPoint | null = LocationManager.getInstance().getLastLocation();
    let initLon: number = last === null ? Number.NaN : last.longitude;
    let initLat: number = last === null ? Number.NaN : last.latitude;
    const cam: Camera | undefined = this.view === undefined ? undefined : this.view.getCamera();
    if ((Number.isNaN(initLon) || Number.isNaN(initLat)) && cam !== undefined) {
      initLon = cam.longitude;
      initLat = cam.latitude;
    }
    if (Number.isNaN(initLon) || Number.isNaN(initLat)) {
      initLon = DEFAULT_LON;
      initLat = DEFAULT_LAT;
    }
    this.moveDialog = new CustomDialogController({
      builder: MoveToDialog({
        initLon: initLon,
        initLat: initLat,
        onConfirm: (lon: number, lat: number): void => {
          const nav: CameraNavigator | undefined = this.navigator;
          if (nav !== undefined) {
            nav.moveToLocation(lat, lon);
          }
        },
      }),
      customStyle: true,
      alignment: DialogAlignment.Center,
      autoCancel: true,
    });
    this.moveDialog.open();
  }

  /** 拍照键：拍照（进相机会话）/ 管理（点位管理页）——Android showPhotoMenu 等价 */
  private showPhotoMenu(): void {
    Ui.items('拍照', ['拍照', '管理']).then((which: number): void => {
      if (which === 0) {
        const capture: MediaCaptureHelper | undefined = this.capture;
        if (capture !== undefined) {
          capture.launchPhotoCapture();
        }
        return;
      }
      if (which === 1) {
        router.pushUrl({ url: 'pages/PhotoPage' });
      }
    });
  }

  private confirmExit(): void {
    Ui.confirm('退出确认', '是否退出应用？', '退出').then((ok: boolean): void => {
      if (!ok) {
        return;
      }
      const ctx: common.UIAbilityContext | undefined = this.appCtx;
      if (ctx !== undefined) {
        ctx.terminateSelf();
      }
    });
  }

  private rebuildOverlays(): void {
    const overlays: BusinessOverlayManager | undefined = this.overlays;
    if (overlays !== undefined) {
      overlays.rebuild();
    }
  }

  // ── 文档驱动与外部导入 ────────────────────────────────────────────

  /** 文档变更：图源/栅格结构变化需重建内核图层（native 无删除瓦片/栅格层能力），否则已就地同步 */
  private onDocumentChanged(doc: MapDocument): void {
    const layers: MapLayerController | undefined = this.layers;
    if (layers === undefined) {
      return;
    }
    this.showCross = doc.systemConfig.showCenterCross;
    if (!layers.onDocumentChanged(doc)) {
      return;
    }
    AppLog.i('文档图源/栅格结构变化，重建地图页');
    this.teardownMap();
    this.coldStart = false;
    this.splash = false;
    this.mapEpoch = this.mapEpoch + 1;
  }

  /** 消费添加图层页留下的导入路径：矢量层缩放到其四至（栅格层由文档变更通道自行装配） */
  private consumeImportedLayer(): void {
    const raw: Object | undefined = PageData.take(PageKeys.IMPORTED_LAYER_PATH);
    if (raw === undefined) {
      return;
    }
    const path: string = raw as string;
    const nav: CameraNavigator | undefined = this.navigator;
    const doc: MapDocument | null = DocumentManager.getInstance().getDocument();
    if (path.length === 0 || nav === undefined || doc === null) {
      return;
    }
    for (let i = doc.vectorLayers.length - 1; i >= 0; i--) {
      if (doc.vectorLayers[i].path === path) {
        nav.zoomToLayerExtent(path, doc.vectorLayers[i].layerName);
        return;
      }
    }
  }

  /**
   * 外部打开承接（对应 Android ExternalImportHandler.handleViewIntent）：
   * 文件管理等经 viewData 拉起的 URI 与选择器返回的同形（file://docs/... 临时授权），
   * 故直接复用矢量导入器——拷入沙箱 → zip/kmz 解压 → 写文档去重落盘 → 缩放到首个图层；
   * 落盘广播经文档监听器同步矢量层，此处不手动上图。
   */
  private async consumeExternalOpen(): Promise<void> {
    const raw: Object | undefined = PageData.take(PageKeys.EXTERNAL_OPEN_URI);
    if (raw === undefined) {
      return;
    }
    const uri: string = raw as string;
    const nav: CameraNavigator | undefined = this.navigator;
    const doc: MapDocument | null = DocumentManager.getInstance().getDocument();
    if (nav === undefined || doc === null) {
      AppLog.w(`${TAG} 外部打开时地图/文档未就绪，忽略 ${uri}`);
      return;
    }
    AppLog.i(`${TAG} 导入外部文件 ${uri}`);
    const results: ImportResult[] = await VectorFileImporter.importPicked([uri]);
    if (results.length === 0) {
      Ui.toastLong('外部文件导入失败（格式不支持或读取失败，详见日志）');
      return;
    }
    let added: number = 0;
    let firstPath: string = '';
    for (let i = 0; i < results.length; i++) {
      const r: ImportResult = results[i];
      let exists: boolean = false;
      for (let j = 0; j < doc.vectorLayers.length; j++) {
        if (doc.vectorLayers[j].path === r.path) {
          exists = true;
          break;
        }
      }
      if (exists) {
        continue;
      }
      doc.vectorLayers.push(new LayerInfo(r.name, r.path, LayerInfo.TYPE_VECTOR, true));
      added++;
      if (firstPath.length === 0) {
        firstPath = r.path;
      }
    }
    if (added === 0) {
      // 重复打开同一文件：图层已在图内，只缩放过去（与选择器导入的去重口径一致）
      nav.zoomToLayerExtent(results[0].path);
      Ui.toast('该图层已在当前工程内');
      return;
    }
    DocumentManager.getInstance().save();
    nav.zoomToLayerExtent(firstPath);
    Ui.toast(`已导入 ${added} 个图层`);
  }

  // ── 冷启动遮罩 ───────────────────────────────────────────────────

  /** 加载门控：矢量层加载完成且最少展示 3s 才淡出；超时兜底淡出（Android beginStartupLayerLoadGate 等价） */
  private beginSplashGate(): void {
    if (!this.coldStart) {
      this.splash = false;
      return;
    }
    this.coldStart = false;
    const startAt: number = Date.now();
    this.clearSplashPoll();
    this.splashPoll = setInterval((): void => {
      const elapsed: number = Date.now() - startAt;
      const view: NativeMapView | undefined = this.view;
      const loading: boolean = view !== undefined && view.isNativeReady() && view.hasVectorLoading();
      if ((loading || elapsed < STARTUP_MIN_DISPLAY_MS) && elapsed < STARTUP_MAX_MS) {
        return;
      }
      this.clearSplashPoll();
      this.splash = false;
    }, STARTUP_LOAD_POLL_MS);
  }

  private clearSplashPoll(): void {
    if (this.splashPoll >= 0) {
      clearInterval(this.splashPoll);
      this.splashPoll = -1;
    }
  }

  // ── 动作入口 ─────────────────────────────────────────────────────

  /**
   * 按系统配置应用视图模式（对应 Android MainActivity.applyViewMode）：装配时与 onPageShow 各调一次，
   * 从设置页返回即时生效、无需重建地图（两模式共用相机状态）。顺带刷一次状态文本，
   * 使指北针显隐跟随模式（2D 恒正北，不等下轮轮询）。
   */
  private applyViewMode(): void {
    const view: NativeMapView | undefined = this.view;
    if (view === undefined) {
      return;
    }
    view.setViewMode(DocumentManager.getInstance().getConfig().viewMode3d
      ? ViewMode.THREE_D : ViewMode.TWO_D);
    const nav: CameraNavigator | undefined = this.navigator;
    if (nav !== undefined) {
      nav.updateStatusText();
    }
  }

  private toggleAnnotation(): void {
    const layers: MapLayerController | undefined = this.layers;
    if (layers === undefined) {
      return;
    }
    this.annotationOn = layers.toggleAnnotation();
  }

  /**
   * 定位键：按记录态分流（0.3.0.4 对齐 Android）。
   * 非记录中一次性回到定位点、不锁定；记录中点击切换跟随锁定。
   */
  private focusLocation(): void {
    const location: LocationController | undefined = this.locationCtl;
    if (location !== undefined) {
      location.onLocateClicked(this.trackRecording);
    }
  }

  /** 定位详情：点底部定位坐标文本弹出（对齐 Android locationText → LocationDetailDialog；「移动到」入口挂中心坐标文本） */
  private showLocationDetail(): void {
    this.locDialog = new CustomDialogController({
      builder: LocationDetailDialog({}),
      customStyle: true,
      alignment: DialogAlignment.Center,
      autoCancel: true,
    });
    this.locDialog.open();
  }

  private openMeasureMenu(): void {
    const measure: MeasureController | undefined = this.measure;
    if (measure !== undefined) {
      measure.showMeasureMenu();
    }
  }

  private openTrackMenu(): void {
    const track: TrackController | undefined = this.track;
    if (track === undefined) {
      return;
    }
    track.onTrackButton((): void => {
      router.pushUrl({ url: 'pages/TrackPage' });
    });
  }

  private zoom(factorIn: boolean): void {
    const nav: CameraNavigator | undefined = this.navigator;
    if (nav === undefined) {
      return;
    }
    if (factorIn) {
      nav.zoomIn();
    } else {
      nav.zoomOut();
    }
  }

  /** 几何编辑提示文案（顶部胶囊）：按阶段与目标几何类型回显 */
  private geomHintText(): string {
    if (this.geomPhase === GeomEditPhase.SPLIT_LINE) {
      return `画分割线：已点 ${this.geomSplitPoints} 个点（至少 2 点后点「完成」）`;
    }
    if (this.geomPhase === GeomEditPhase.MERGE_PICK) {
      return '请点击要合并的另一个面图斑（同一图层）';
    }
    return this.geomIsPolygon ? `几何编辑：要素 #${this.geomFid}`
      : `几何编辑：要素 #${this.geomFid}（线/点仅支持删除）`;
  }

  // ── 界面 ─────────────────────────────────────────────────────────

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 键控重建：mapEpoch 变化即销毁重建内核视图（native 图层栈只能整体重建，对应 Android recreate）
      ForEach([this.mapEpoch], (epoch: number): void => {
        NativeMapView({
          density: this.density,
          onReady: (view: NativeMapView): void => {
            this.setupMap(view).then((): void => {
            }, (e: Error): void => {
              this.onSetupFailed(e);
            });
          },
        })
      }, (epoch: number): string => `map-${epoch}`)

      // 中心十字丝（Android jni_map_center_cross，30x30）
      if (this.showCross) {
        Stack() {
          Column()
            .width(1)
            .height(30)
            .backgroundColor(MapStyle.CENTER_CROSS_COLOR)
          Row()
            .width(30)
            .height(1)
            .backgroundColor(MapStyle.CENTER_CROSS_COLOR)
        }
        .width(30)
        .height(30)
        .position({ x: '50%', y: '50%' })
        .markAnchor({ x: '50%', y: '50%' })
        .hitTestBehavior(HitTestMode.None)
      }

      // ── HUD：左右两条通高竖栏，栏内空间全部按「比例」分配，横竖屏下按钮互不重叠 ──
      // 对齐 Android activity_main.xml 的约束：测量 / 拍照落在「父容器顶 → 同侧底部按钮群」区间
      // 的 vertical_bias 0.7 处。这里用 7:3 的弹性占位复现同一比例：占位随可用高度自动收放，
      // 不会出现「固定 70% 百分比」在小高度（尤其横屏）下与底部按钮群压盖的问题。
      // 命中口径：栏容器用 HitTestMode.None 使空白处不拦地图手势，但 None 同时「不阻挡兄弟/祖先」，
      // 会让 Stack 底层的 NativeMapView 一并进入命中（表现为点按键地图也跟着平移、还弹要素详情）；
      // 故栏内可点节点一律走 MapIconButton / chip，它们自带 HitTestMode.Block 吃掉事件。
      Row() {
        // 左栏：指北 → 测量 → 设置/定位/轨迹（2D/3D 切换键与 GO 键均已删，前者改由设置页控制、后者改挂中心坐标文本）
        Column() {
          Row({ space: 5 }) {
            if (this.compassVisible && this.geomPhase === GeomEditPhase.NONE) {
              MapIconButton({
                label: '北',
                action: (): void => {
                  const nav: CameraNavigator | undefined = this.navigator;
                  if (nav !== undefined) {
                    nav.resetHeading();
                  }
                },
              })
            }
          }
          Column()
            .layoutWeight(7)
            .hitTestBehavior(HitTestMode.None)
          if (this.geomPhase === GeomEditPhase.NONE) {
            MapIconButton({
              label: '测量',
              action: (): void => {
                this.openMeasureMenu();
              },
            })
          }
          Column()
            .layoutWeight(3)
            .hitTestBehavior(HitTestMode.None)
          if (this.hudLandscape) {
            Row({ space: 5 }) {
              this.hudLeftBottom()
            }
          } else {
            Column({ space: 5 }) {
              this.hudLeftBottom()
            }
          }
        }
        .height('100%')
        .alignItems(HorizontalAlign.Start)
        .hitTestBehavior(HitTestMode.None)

        // 中间整条留空给地图（不参与命中，手势可穿透到下层 NativeMapView）
        Column()
          .layoutWeight(1)
          .hitTestBehavior(HitTestMode.None)

        // 右栏：图层 → 工程 → 拍照 → 注记 / 缩放面板（几何编辑态隐藏图层/工程/拍照，保留注记与缩放）
        Column() {
          if (this.geomPhase === GeomEditPhase.NONE) {
            MapIconButton({
              label: '图层',
              action: (): void => {
                const params: LayerManageParams = new LayerManageParams();
                params.tab = 0;
                router.pushUrl({ url: 'pages/LayerManagePage', params: params });
              },
            })
            // 工程管理入口（0.4.0.0 工程模块，对齐 Android jni_map_project：右栏图层键正下方）
            MapIconButton({
              label: '工程',
              action: (): void => {
                router.pushUrl({ url: 'pages/ProjectManagePage' });
              },
            })
              .margin({ top: 5 })
          }
          Column()
            .layoutWeight(7)
            .hitTestBehavior(HitTestMode.None)
          if (this.geomPhase === GeomEditPhase.NONE) {
            MapIconButton({
              label: '拍照',
              action: (): void => {
                this.showPhotoMenu();
              },
            })
          }
          Column()
            .layoutWeight(3)
            .hitTestBehavior(HitTestMode.None)
          if (this.hudLandscape) {
            Row({ space: 5 }) {
              this.hudRightBottom()
            }
          } else {
            Column({ space: 5 }) {
              this.hudRightBottom()
            }
          }
        }
        .height('100%')
        .alignItems(HorizontalAlign.End)
        .hitTestBehavior(HitTestMode.None)
      }
      .width('100%')
      .height('100%')
      // 左右缩进由外层 padding 承载；底部以「信息条上沿」与「导航条上沿」二者中较高者为基准再留间隙
      // （信息条本身贴底不再避让，故手势导航时不必抬高一个导航条高度，按钮得以贴近信息条）
      .padding({
        left: SIDE_MARGIN,
        right: SIDE_MARGIN,
        top: TOP_MARGIN,
        bottom: Math.max(STATUS_HEIGHT, this.bottomInset) + SIDE_BOTTOM_GAP,
      })
      .hitTestBehavior(HitTestMode.None)

      // 底部居中：测量采集工具条（进入测量模式后出现）。本行不拦手势（空白处可继续选点），
      // 工具条内的文本胶囊走 chip、自带 Block 不会穿透到地图。
      if (this.measureCapturing) {
        Row({ space: 6 }) {
          this.chip('撤销', (): void => {
            const measure: MeasureController | undefined = this.measure;
            if (measure !== undefined) {
              measure.undo();
            }
          })
          this.chip('中心点', (): void => {
            const measure: MeasureController | undefined = this.measure;
            if (measure !== undefined) {
              measure.addCenterPoint();
            }
          })
          this.chip('结束', (): void => {
            const measure: MeasureController | undefined = this.measure;
            if (measure !== undefined) {
              measure.finish();
            }
          })
          this.chip('退出', (): void => {
            const measure: MeasureController | undefined = this.measure;
            if (measure !== undefined) {
              measure.exit();
            }
          })
        }
        .position({ x: '50%', y: '100%' })
        .markAnchor({ x: '50%', y: '100%' })
        .padding({ bottom: Math.max(STATUS_HEIGHT, this.bottomInset) + TOOL_BOTTOM_GAP })
        .hitTestBehavior(HitTestMode.None)
      }

      // 底部居中：几何编辑工具条（长按菜单「编辑」命中 gdb/shp 要素后出现）。
      // 待命=分割/删除/合并/退出（线/点层仅删除）；画线=撤销/完成/取消；选靶=取消。
      if (this.geomPhase === GeomEditPhase.EDIT) {
        Row({ space: 6 }) {
          if (this.geomIsPolygon) {
            this.chip('分割', (): void => {
              const ge: GeomEditController | undefined = this.geomEdit;
              if (ge !== undefined) {
                ge.startSplit();
              }
            })
          }
          this.chip('删除', (): void => {
            const ge: GeomEditController | undefined = this.geomEdit;
            if (ge !== undefined) {
              ge.requestDelete();
            }
          })
          if (this.geomIsPolygon) {
            this.chip('合并', (): void => {
              const ge: GeomEditController | undefined = this.geomEdit;
              if (ge !== undefined) {
                ge.startMergePick();
              }
            })
          }
          this.chip('退出', (): void => {
            const ge: GeomEditController | undefined = this.geomEdit;
            if (ge !== undefined) {
              ge.exit();
            }
          })
        }
        .position({ x: '50%', y: '100%' })
        .markAnchor({ x: '50%', y: '100%' })
        .padding({ bottom: Math.max(STATUS_HEIGHT, this.bottomInset) + TOOL_BOTTOM_GAP })
        .hitTestBehavior(HitTestMode.None)
      }
      if (this.geomPhase === GeomEditPhase.SPLIT_LINE) {
        Row({ space: 6 }) {
          this.chip('撤销', (): void => {
            const ge: GeomEditController | undefined = this.geomEdit;
            if (ge !== undefined) {
              ge.undoSplitPoint();
            }
          })
          this.chip('完成', (): void => {
            const ge: GeomEditController | undefined = this.geomEdit;
            if (ge !== undefined) {
              ge.finishSplit();
            }
          })
          this.chip('取消', (): void => {
            const ge: GeomEditController | undefined = this.geomEdit;
            if (ge !== undefined) {
              ge.cancelSplit();
            }
          })
        }
        .position({ x: '50%', y: '100%' })
        .markAnchor({ x: '50%', y: '100%' })
        .padding({ bottom: Math.max(STATUS_HEIGHT, this.bottomInset) + TOOL_BOTTOM_GAP })
        .hitTestBehavior(HitTestMode.None)
      }
      if (this.geomPhase === GeomEditPhase.MERGE_PICK) {
        Row({ space: 6 }) {
          this.chip('取消', (): void => {
            const ge: GeomEditController | undefined = this.geomEdit;
            if (ge !== undefined) {
              ge.cancelMergePick();
            }
          })
        }
        .position({ x: '50%', y: '100%' })
        .markAnchor({ x: '50%', y: '100%' })
        .padding({ bottom: Math.max(STATUS_HEIGHT, this.bottomInset) + TOOL_BOTTOM_GAP })
        .hitTestBehavior(HitTestMode.None)
      }

      // 顶部居中：几何编辑提示胶囊（下移一行避开「矢量加载中」胶囊；不拦截地图手势）
      if (this.geomPhase !== GeomEditPhase.NONE) {
        Row() {
          Text(this.geomHintText())
            .fontSize(Theme.FONT_SUB)
            .fontColor(Theme.TEXT_ON_DARK)
        }
        .padding({ left: 12, right: 12, top: 6, bottom: 6 })
        .backgroundColor(PILL_BG)
        .borderRadius(14)
        .position({ x: '50%', y: TOP_MARGIN + 34 })
        .markAnchor({ x: '50%', y: 0 })
        .hitTestBehavior(HitTestMode.None)
      }

      // 顶部居中：矢量加载提示胶囊（不拦截地图手势）
      if (this.vectorLoading) {
        Row({ space: 6 }) {
          LoadingProgress()
            .width(14)
            .height(14)
            .color(Theme.PRIMARY)
          Text('矢量数据加载中，请稍候…')
            .fontSize(Theme.FONT_SUB)
            .fontColor(Theme.TEXT_ON_DARK)
        }
        .padding({ left: 12, right: 12, top: 6, bottom: 6 })
        .backgroundColor(PILL_BG)
        .borderRadius(14)
        .position({ x: '50%', y: TOP_MARGIN })
        .markAnchor({ x: '50%', y: 0 })
        .hitTestBehavior(HitTestMode.None)
      }

      // 底部状态栏：定位坐标在前（左）+ 中心坐标在后（右）—— 次序与权重分配对齐 Android
      // activity_main.xml：定位 TextView wrap_content 优先完整显示（含海拔段），中心 TextView
      // 0dp+weight 占剩余宽度并尾部省略，空间不足时只截中心。
      // 点定位文本弹「定位详情」（对应 Android locationText → LocationDetailDialog），
      // 点中心文本弹「移动到」（对应 Android centerText → showMoveToDialog，原左下 GO 键入口在 Android 已删）。
      // 按需求保持贴住屏幕最底，不做导航条避让（指示条叠在半透明底色上，与 Android 贴底观感一致）
      Column() {
        Row() {
          Text(this.locationText)
            .fontSize(Theme.FONT_SUB)
            .fontColor(Theme.TEXT_ON_DARK)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .onClick((): void => {
              this.showLocationDetail();
            })
          Text(this.centerText)
            .fontSize(Theme.FONT_SUB)
            .fontColor(Theme.TEXT_ON_DARK)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .textAlign(TextAlign.End)
            .layoutWeight(1)
            .padding({ left: 8 })
            .onClick((): void => {
              this.showMoveToDialog();
            })
        }
        .width('100%')
        .height(STATUS_HEIGHT)
        .padding({ left: 8, right: 8 })
        .backgroundColor(STATUS_BG)
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .position({ x: 0, y: '100%' })
      .markAnchor({ x: 0, y: '100%' })

      // 长按圆菜单（对应 Android PieMenu 叠在 content 上）：空白与命中要素都弹，命中时多一项「编辑」
      // 浮层根节点为默认命中模式（自身+子节点参与、屏蔽兄弟地图），空白收起由浮层内的遮罩节点自理
      if (this.pieMenuOpen) {
        PieMenuLayer({
          spec: this.pieMenu,
          onDismiss: (): void => {
            this.pieMenuOpen = false;
          },
        })
      }

      // 启动遮罩：盖住 native/proj/文档初始化与首屏瓦片加载，装配完成后淡出
      if (this.splash) {
        Column() {
          Image($r('app.media.startIcon'))
            .width(88)
            .height(88)
            .borderRadius(18)
          Text(AppConfig.APP_NAME)
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FF131313')
            .margin({ top: 14 })
          Text(SPLASH_TEXT)
            .fontSize(14)
            .fontColor('#FF666666')
            .margin({ top: 10 })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor(Color.White)
        .transition(TransitionEffect.OPACITY.animation({ duration: 300 }))
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Black)
    .onAreaChange((oldValue: Area, newValue: Area): void => {
      const w: number = typeof newValue.width === 'number' ? newValue.width : this.vpWidth;
      const h: number = typeof newValue.height === 'number' ? newValue.height : this.vpHeight;
      this.vpWidth = w;
      this.vpHeight = h;
      // 横屏（宽>高）时底部按钮群改横排：竖排在横屏高度下会与测量键压盖
      this.hudLandscape = w > h;
      // 视口尺寸下发相机（屏幕四角反算）与测量（中心点取坐标）：两者最终喂 screenToGeo，
      // 那一路是引擎 px 口径（surfaceChanged 下发的就是 px），故此处按密度换算成 px
      const pxW: number = w * this.density;
      const pxH: number = h * this.density;
      const nav: CameraNavigator | undefined = this.navigator;
      if (nav !== undefined) {
        nav.setViewportSize(pxW, pxH);
      }
      const measure: MeasureController | undefined = this.measure;
      if (measure !== undefined) {
        measure.setViewportSize(pxW, pxH);
      }
    })
  }

  /** 方形图标按钮已抽为文件末尾的 MapIconButton 组件（理由见该组件注释），此处只剩文本动作胶囊 */

  /** 左下按钮群：设置 / 定位（跟随）/ 轨迹采集（暂停·停止）/ 轨迹 —— 竖屏竖排、横屏横排共用；
   *  几何编辑态整组隐藏（编辑期间不做定位/轨迹/设置操作） */
  @Builder
  hudLeftBottom() {
    if (this.geomPhase === GeomEditPhase.NONE) {
      MapIconButton({
        label: '设置',
        action: (): void => {
          router.pushUrl({ url: 'pages/SettingsPage' });
        },
      })
      MapIconButton({
        // 标签反映跟随锁定态（现由轨迹记录驱动）；点击按记录态分流（非记录单次定位、记录中切换锁定）
        label: this.following ? '跟随' : '定位',
        action: (): void => {
          this.focusLocation();
        },
      })
      if (this.trackRecording) {
        MapIconButton({
          label: this.trackPaused ? '继续' : '暂停',
          action: (): void => {
            const track: TrackController | undefined = this.track;
            if (track === undefined) {
              return;
            }
            if (track.isPaused()) {
              track.resume();
            } else {
              track.pause();
            }
          },
        })
        MapIconButton({
          label: '停止',
          action: (): void => {
            const track: TrackController | undefined = this.track;
            if (track !== undefined) {
              track.stop();
            }
          },
        })
      }
      // 「轨迹」入口键：记录中隐藏（改由上方暂停/停止键接管），停止/完成记录后随 trackRecording 转 false 复现
      if (!this.trackRecording) {
        MapIconButton({
          label: '轨迹',
          action: (): void => {
            this.openTrackMenu();
          },
        })
      }
      // 「移动到」不再占一枚键：Android 已删 jni_map_go，入口改为中心坐标文本点击（见底部状态栏）
    }
  }

  /** 右下按钮群：注记显隐 + 缩放面板（＋ / 级别 / －）—— 竖屏竖排、横屏横排共用 */
  @Builder
  hudRightBottom() {
    MapIconButton({
      label: '注记',
      action: (): void => {
        this.toggleAnnotation();
      },
    })
    // 缩放三件套单独成组：用比外群更小的内部间距收紧「放大 / 缩小」两键的距离，
    // 注记按钮与缩放面板之间仍走外层 space 间隔，方向随横竖屏切换
    if (this.hudLandscape) {
      Row({ space: ZOOM_GAP }) {
        MapIconButton({
          label: '＋',
          action: (): void => {
            this.zoom(true);
          },
        })
        Text(`${this.level}`)
          .fontSize(8)
          .fontColor(Theme.TEXT_ON_DARK)
          .textAlign(TextAlign.Center)
          .width(36)
          .height(10)
        MapIconButton({
          label: '－',
          action: (): void => {
            this.zoom(false);
          },
        })
      }
    } else {
      Column({ space: ZOOM_GAP }) {
        MapIconButton({
          label: '＋',
          action: (): void => {
            this.zoom(true);
          },
        })
        Text(`${this.level}`)
          .fontSize(8)
          .fontColor(Theme.TEXT_ON_DARK)
          .textAlign(TextAlign.Center)
          .width(36)
          .height(10)
        MapIconButton({
          label: '－',
          action: (): void => {
            this.zoom(false);
          },
        })
      }
    }
  }

  /** 文本动作胶囊（测量工具条）：Block 保证点胶囊不穿透到下层地图（否则会被 native 当成一次拾取/平移） */
  @Builder
  chip(label: string, onTap: () => void) {
    Text(label)
      .fontSize(Theme.FONT_SUB)
      .fontColor(Theme.TEXT_ON_DARK)
      .textAlign(TextAlign.Center)
      .height(30)
      .padding({ left: 12, right: 12 })
      .backgroundColor(Theme.BAR)
      .borderRadius(15)
      .hitTestBehavior(HitTestMode.Block)
      .onClick((): void => {
        onTap();
      })
  }
}

/**
 * 方形图标按钮（Android jni_map_* 的 32dp 底图按钮等价，文字标签即功能名）。
 *
 * 为何是独立组件而不是 Index 内的 @Builder：@Builder 的参数按值传递，外层 @State 变化时
 * 不会刷新 builder 内部的 Text，「定位/跟随」「暂停/继续」这类随状态变的标签会停在首次文案；
 * 改成子组件后 label 走 @Prop，父组件重渲时会自动同步新值。
 *
 * hitTestBehavior 必为 Block：所在 HUD 栏容器为 HitTestMode.None（使栏内空白不拦地图手势），
 * 而 None 的语义是「自身不响应且不阻挡子/兄弟/祖先」，按键自身的 Default 只能挡同级兄弟，
 * 无法阻止 Stack 底层的 NativeMapView 参与同一串触摸：会表现为「点放大/缩小没反应但地图飘移」、
 * 按键下方有要素时还会弹属性详情。Block 明确阻挡祖先，事件不再下发到地图。
 */
@Component
struct MapIconButton {
  /** 按钮文字（即功能名）；随外层状态变化刷新 */
  @Prop label: string = '';
  /** 点击回调 */
  action: () => void = (): void => {};

  build() {
    Text(this.label)
      .fontSize(ICON_FONT)
      .fontColor(ICON_TEXT)
      .textAlign(TextAlign.Center)
      .width(ICON_SIZE)
      .height(ICON_SIZE)
      .backgroundColor(ICON_BG)
      .borderRadius(6)
      .hitTestBehavior(HitTestMode.Block)
      .onClick((): void => {
        this.action();
      })
  }
}
