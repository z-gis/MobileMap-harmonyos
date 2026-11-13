// MapCanvas.ets —— 桌面工作台的地图视口：引擎视图 + 鼠标增强层 + 视图量算回抛。
//
// 为什么把滚轮缩放做在 ArkTS 上层而不是改引擎：
//  · 引擎（native）手势识别只吃 OH_NativeXComponent 的触摸事件，其鼠标回调没有滚轮通道；
//  · ArkUI 的滚轮/触控板滚动以 PanGesture 下发，event.axisVertical 为一档一档的滚动量；
//  · 覆盖层设 HitTestMode.Transparent：本层收滚轮与悬停，同时把按下/拖动透传给下层 SURFACE，
//    左键平移仍走引擎既有触摸手势通路（已实测正常，不再实现一遍以免双速）。
//
// 视图量算（比例尺、缩放至范围）需要「米/vp」：HAR 只透出 screenToGeo，故在视口中心横向取
// 相距 100vp 的两点反算地面距离。vp 物理恒为 1/160 英寸，比例尺口径见 DeskVector。
import { display } from '@kit.ArkUI';
import { Camera, NativeMapView, Position } from '@zys/globecore';
import { DeskTheme } from '../common/DeskTheme';
import { DeskLog } from '../common/DeskLog';
import { DeskVector } from '../common/DeskVector';

/** 滚轮一格 = 0.15 个缩放级别（海拔 ×2^0.15≈1.11）：约 7 格一级，内业精读的手感 */
const WHEEL_LEVEL_PER_NOTCH: number = 0.15;
/** 单次事件最多算几格：一次物理滚动的原始量随机型/鼠标而异，钳住以免跳跃 */
const WHEEL_MAX_NOTCH: number = 1;
/**
 * 同一格滚轮会以 start + update 连发（GestureEvent.timestamp 单位是纳秒，且 2in1 上标注不可用，
 * 不能拿它去重量级），故用宿主自己的毫秒时钟把一帧内的重复事件合成一格。25ms ≈ 1.5 帧。
 */
const WHEEL_DEDUPE_MS: number = 25;
/** 前若干次滚动打日志，便于按实测原始量调整上面三个常量 */
const WHEEL_LOG_BUDGET: number = 6;
/** 米/vp 采样基线（vp）：太短受坐标量化噪声影响，太长在三维倾斜下非线性误差大 */
const MPP_SAMPLE_VP: number = 100;

/** 回抛给宿主的视图状态（状态栏比例尺/坐标、历史栈、缩放至范围共用） */
export interface ViewInfo {
  centerLon: number;
  centerLat: number;
  altitude: number;
  heading: number;
  tilt: number;
  level: number;
  cursorLon: number;
  cursorLat: number;
  hasCursor: boolean;
  /** 米/vp（0 = 尚未就绪） */
  mpp: number;
  /** 视口尺寸（vp） */
  viewW: number;
  viewH: number;
}

@Component
export struct MapCanvas {
  /** 引擎视图就绪回调（回抛本组件，宿主经它驱动相机与图层） */
  onMapReady: ((canvas: MapCanvas) => void) | undefined = undefined;
  /** 视图状态变化回调 */
  onViewInfo: ((info: ViewInfo) => void) | undefined = undefined;
  /** 滚轮向上=放大（视图菜单可反转） */
  @Link wheelUpZoomsIn: boolean;
  @State private density: number = 1.0;

  private view: NativeMapView | undefined = undefined;
  private viewW: number = 0;
  private viewH: number = 0;
  /** 视口在窗口内的偏移（vp）：MouseEvent.windowX/Y 是窗口坐标，需减去才是视口本地坐标 */
  private originX: number = 0;
  private originY: number = 0;
  private lastWheelMs: number = 0;
  private wheelUnit: number = 0;
  private wheelLogLeft: number = WHEEL_LOG_BUDGET;
  /** 光标处经纬度与视口本地坐标（vp）：工具条放大/缩小以光标为锚 */
  private cursorLon: number = 0;
  private cursorLat: number = 0;
  private hasCursor: boolean = false;
  private cursorXVp: number = 0;
  private cursorYVp: number = 0;

  aboutToAppear(): void {
    try {
      this.density = display.getDefaultDisplaySync().densityPixels;
    } catch (e) {
      this.density = 1.0;
    }
  }

  /** 宿主取引擎视图（加/删图层、设可见性、拾取等直接调 HAR API） */
  engine(): NativeMapView | undefined {
    return this.view;
  }

  viewportWidth(): number {
    return this.viewW;
  }

  viewportHeight(): number {
    return this.viewH;
  }

  /** 相机搬到指定位置 */
  moveTo(latitude: number, longitude: number, altitude: number): void {
    const view = this.view;
    if (view === undefined || !view.isNativeReady()) {
      return;
    }
    view.setCamera(new Camera(latitude, longitude, altitude));
    this.report();
    // 首帧之前 getCamera() 可能还是零值：补两次延迟回读
    setTimeout((): void => { this.report(); }, 120);
    setTimeout((): void => { this.report(); }, 600);
  }

  /** 以视口中心为锚缩放（菜单放大/缩小） */
  zoomAtCenter(factor: number): void {
    this.zoomAt(factor, this.viewW * 0.5, this.viewH * 0.5);
  }

  /** 以光标为锚缩放（放大/缩小工具点击地图）；无光标历史则退中心 */
  zoomAtCursor(factor: number): void {
    if (this.hasCursor) {
      this.zoomAt(factor, this.cursorXVp, this.cursorYVp);
    } else {
      this.zoomAtCenter(factor);
    }
  }

  /** 以引擎屏幕像素点为锚缩放（onTapListener 回抛的即 surface px） */
  zoomAtScreenPx(factor: number, xPx: number, yPx: number): void {
    const ui = this.getUIContext();
    this.zoomAt(factor, ui.px2vp(xPx), ui.px2vp(yPx));
  }

  /**
   * 缩放至四至：按「地面跨度 ∝ 海拔」换算目标海拔（留 8% 边距），中心搬到四至中点。
   * 返回 false = 量算未就绪或四至无效，调用方据此提示。
   */
  zoomToExtent(extent: number[]): boolean {
    const view = this.view;
    if (view === undefined || !view.isNativeReady() || extent.length < 4) {
      return false;
    }
    const cam = view.getCamera();
    const mpp: number = this.sampleMpp();
    if (cam === undefined || mpp <= 0) {
      return false;
    }
    const alt: number = DeskVector.altitudeForExtent(extent, this.viewW, this.viewH,
      cam.altitude, mpp);
    if (alt <= 0) {
      return false;
    }
    const lat: number = (extent[1] + extent[3]) / 2;
    const lon: number = (extent[0] + extent[2]) / 2;
    view.setCamera(new Camera(lat, lon, alt, cam.heading, cam.tilt, cam.roll,
      cam.fieldOfView, cam.altitudeMode));
    this.report();
    setTimeout((): void => { this.report(); }, 150);
    return true;
  }

  /**
   * 转到指定经纬度（工具栏「转到 XY」）：只搬中心，海拔与姿态不动（ArcMap Go To 同口径，
   * 级别不变才能连续输入多个点）。返回 false = 引擎未就绪或取不到当前相机。
   */
  goTo(lat: number, lon: number): boolean {
    const view = this.view;
    if (view === undefined || !view.isNativeReady()) {
      return false;
    }
    const cam = view.getCamera();
    if (cam === undefined) {
      return false;
    }
    view.setCamera(new Camera(lat, lon, cam.altitude, cam.heading, cam.tilt, cam.roll,
      cam.fieldOfView, cam.altitudeMode));
    this.report();
    setTimeout((): void => { this.report(); }, 150);
    return true;
  }

  /** 落到指定比例尺分母（工具条比例尺下拉）；中心不动 */
  setScaleDenominator(denominator: number): void {
    const view = this.view;
    if (view === undefined || !view.isNativeReady() || denominator <= 0) {
      return;
    }
    const cam = view.getCamera();
    const mpp: number = this.sampleMpp();
    if (cam === undefined || mpp <= 0) {
      return;
    }
    const targetMpp: number = denominator * 0.0254 / 160;
    view.setCamera(new Camera(cam.latitude, cam.longitude, cam.altitude * targetMpp / mpp,
      cam.heading, cam.tilt, cam.roll, cam.fieldOfView, cam.altitudeMode));
    this.report();
  }

  /** 直接设相机（历史栈前进/后退） */
  applyCamera(cam: Camera): void {
    const view = this.view;
    if (view === undefined || !view.isNativeReady()) {
      return;
    }
    view.setCamera(cam);
    this.report();
  }

  /**
   * 以视口内指定点（vp）为锚缩放。HAR 只把手势平移/缩放开放给内部 GestureSink，对宿主仅暴露
   * 「设/读相机」，故桌面端在宿主侧等价实现（不改引擎，手机端零回归）：
   *  1) 记锚点当前落地经纬度 before；2) 海拔 ÷f 即级别 +log2(f)；
   *  3) 回读是否真缩了（到级别上限时海拔被钳住，此时不能动中心，否则原地漂移）；
   *  4) 再读锚点落点 after，中心平移 (before-after)，锚点钉在光标下。
   * 二维墨卡托下精确；三维球面为近似（单帧残差亚像素级）。
   */
  private zoomAt(factor: number, anchorXVp: number, anchorYVp: number): void {
    const view = this.view;
    if (view === undefined || !view.isNativeReady() || factor <= 0) {
      return;
    }
    const cam = view.getCamera();
    if (cam === undefined) {
      return;
    }
    const ui = this.getUIContext();
    const ax: number = ui.vp2px(anchorXVp);
    const ay: number = ui.vp2px(anchorYVp);
    const before = view.screenToGeo(ax, ay);
    view.setCamera(new Camera(cam.latitude, cam.longitude, cam.altitude / factor,
      cam.heading, cam.tilt, cam.roll, cam.fieldOfView, cam.altitudeMode));
    const applied = view.getCamera();
    if (applied === undefined || Math.abs(applied.altitude - cam.altitude) < 1e-6
      || before === undefined) {
      return;
    }
    const after = view.screenToGeo(ax, ay);
    if (after === undefined) {
      return;
    }
    view.setCamera(new Camera(applied.latitude + (before.latitude - after.latitude),
      applied.longitude + (before.longitude - after.longitude), applied.altitude,
      applied.heading, applied.tilt, applied.roll, applied.fieldOfView, applied.altitudeMode));
    this.report();
  }

  /** 视口中心横向取两点反算米/vp；视口未就绪或反算无效返回 0 */
  private sampleMpp(): number {
    const view = this.view;
    if (view === undefined || !view.isNativeReady() || this.viewW <= 0 || this.viewH <= 0) {
      return 0;
    }
    const ui = this.getUIContext();
    const cx: number = this.viewW * 0.5;
    const cy: number = this.viewH * 0.5;
    const half: number = Math.min(MPP_SAMPLE_VP, this.viewW * 0.4) * 0.5;
    const a: Position | undefined = view.screenToGeo(ui.vp2px(cx - half), ui.vp2px(cy));
    const b: Position | undefined = view.screenToGeo(ui.vp2px(cx + half), ui.vp2px(cy));
    return DeskVector.metersPerVp(a, b, half * 2);
  }

  // ── 事件处理 ──

  /** 滚轮/触控板滚动：axisVertical 非零即一档；按下拖动时恒 0，直接忽略 */
  private onWheelLike(event: GestureEvent): void {
    const view = this.view;
    if (view === undefined || !view.isNativeReady()) {
      return;
    }
    const axis: number = event.axisVertical ?? 0;
    const now: number = Date.now();
    if (axis === 0 || now - this.lastWheelMs < WHEEL_DEDUPE_MS) {
      return;
    }
    this.lastWheelMs = now;
    // 一次物理滚动的原始量随机型/鼠标驱动而异，用首个非零量把「一格」定标，不写死 axis 单位
    if (this.wheelUnit <= 0) {
      this.wheelUnit = Math.abs(axis);
    }
    if (this.wheelLogLeft > 0) {
      this.wheelLogLeft--;
      DeskLog.i(`滚轮 axis=${axis} 定标=${this.wheelUnit}`);
    }
    let notch: number = axis / this.wheelUnit;
    notch = Math.max(-WHEEL_MAX_NOTCH, Math.min(WHEEL_MAX_NOTCH, notch));
    const level: number = WHEEL_LEVEL_PER_NOTCH * notch * (this.wheelUpZoomsIn ? 1 : -1);
    const factor: number = Math.pow(2, level);
    const fingers = event.fingerList;
    const anchored: boolean = fingers.length > 0;
    const fx: number = anchored ? fingers[0].localX : this.viewW * 0.5;
    const fy: number = anchored ? fingers[0].localY : this.viewH * 0.5;
    this.zoomAt(factor, fx, fy);
  }

  /** 悬停/拖动中的光标：换算视口本地坐标问引擎取经纬度 */
  private onCursor(event: MouseEvent): void {
    const view = this.view;
    if (view === undefined || !view.isNativeReady()) {
      return;
    }
    const localX: number = event.windowX - this.originX;
    const localY: number = event.windowY - this.originY;
    if (localX < 0 || localY < 0 || localX > this.viewW || localY > this.viewH) {
      this.hasCursor = false;
      return;
    }
    this.cursorXVp = localX;
    this.cursorYVp = localY;
    const ui = this.getUIContext();
    const pos: Position | undefined = view.screenToGeo(ui.vp2px(localX), ui.vp2px(localY));
    if (pos === undefined) {
      this.hasCursor = false;
      return;
    }
    this.cursorLon = pos.longitude;
    this.cursorLat = pos.latitude;
    this.hasCursor = true;
    this.report();
  }

  /** 把相机、级别、光标、米/vp、视口尺寸一并回抛宿主 */
  private report(): void {
    const cb = this.onViewInfo;
    const view = this.view;
    if (cb === undefined || view === undefined || !view.isNativeReady()) {
      return;
    }
    const cam = view.getCamera();
    if (cam === undefined) {
      return;
    }
    const info: ViewInfo = {
      centerLon: cam.longitude,
      centerLat: cam.latitude,
      altitude: cam.altitude,
      heading: cam.heading,
      tilt: cam.tilt,
      level: view.cameraZoomLevel(),
      cursorLon: this.cursorLon,
      cursorLat: this.cursorLat,
      hasCursor: this.hasCursor,
      mpp: this.sampleMpp(),
      viewW: this.viewW,
      viewH: this.viewH
    };
    cb(info);
  }

  private attachView(view: NativeMapView): void {
    this.view = view;
    const cb = this.onMapReady;
    if (cb !== undefined) {
      cb(this);
    }
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      NativeMapView({
        density: this.density,
        onReady: (view: NativeMapView): void => {
          this.attachView(view);
        }
      })

      // 鼠标增强层：透明命中，否则会吞掉下层 SURFACE 的按下/拖动（左键平移就废了）
      Column()
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.Transparent)
        .onMouse((event: MouseEvent): void => {
          this.onCursor(event);
        })
        .priorityGesture(
          PanGesture({ direction: PanDirection.All, distance: 1, fingers: 1 })
            .onActionStart((event: GestureEvent): void => {
              this.onWheelLike(event);
            })
            .onActionUpdate((event: GestureEvent): void => {
              this.onWheelLike(event);
            })
        )
    }
    .width('100%')
    .height('100%')
    .backgroundColor(DeskTheme.MAP_BG)
    .onAreaChange((oldValue: Area, newValue: Area): void => {
      this.viewW = typeof newValue.width === 'number' ? newValue.width : this.viewW;
      this.viewH = typeof newValue.height === 'number' ? newValue.height : this.viewH;
      const gp = newValue.globalPosition;
      this.originX = typeof gp.x === 'number' ? gp.x : 0;
      this.originY = typeof gp.y === 'number' ? gp.y : 0;
      this.report();
    })
  }
}