// CameraNavigator.ets —— 相机导航与状态栏（对应 Android ui.map.CameraNavigator）。
//
// 职责：缩放/四至定位/移动相机、级别与中心坐标轮询刷新、相机静止检测（驱动大数据矢量层重载）、
// 相机视角独立持久化（仅视角：视图模式 0.3.0.1 起改存 SystemConfig.viewMode3d，不再随相机落盘）。
//
// 相机优先级口径与 Android 一致：上次保存的独立视角 > 文档相机 > 兜底默认（北京上空 20km）。
// 内核暂无相机变更回调，故按 250ms 轮询读回相机快照（getCamera 仅取回标量，开销可忽略）；
// 页面 onPause/隐藏时须 stopPolling，避免后台空转与销毁后回调。

import { common } from '@kit.AbilityKit';
import { Camera, NativeMapView, VectorExtent } from '@zys/globecore';
import { AppLog } from '../common/AppLog';
import { CoordFormatter } from '../common/Coord';
import { MercatorZoom } from '../common/MercatorZoom';
import { Prefs } from '../common/Prefs';
import { GdalVectorReader } from '../vector/GdalVectorReader';

const TAG: string = 'CameraNavigator';

/** 文档无有效视角时的兜底相机（北京上空 20km） */
export const DEFAULT_LON: number = 116.391;
export const DEFAULT_LAT: number = 39.907;
export const DEFAULT_ALTITUDE: number = 20000.0;
/** 缩放步进系数：每次点击把相机高度乘/除约 1.25 倍 */
const ZOOM_IN_FACTOR: number = 0.8;
const ZOOM_OUT_FACTOR: number = 1.2;
/** 级别/中心文本轮询刷新间隔（毫秒） */
const STATUS_POLL_MS: number = 250;
/** 相机静止判定阈值（毫秒）：位姿连续不变达此值即判「停下」，触发一次屏幕范围重载 */
const SETTLE_MS: number = 500;
/** 「移到定位点」时相机高度无效的兜底观察高度（米） */
export const GOTO_ALTITUDE: number = 1200.0;

const PREFS_NAME: string = 'jni_map_camera';
const KEY_LON: string = 'lon';
const KEY_LAT: string = 'lat';
const KEY_ALT: string = 'alt';
const KEY_HEADING: string = 'heading';
const KEY_TILT: string = 'tilt';

export class CameraNavigator {
  private readonly view: NativeMapView;
  private readonly ctx: common.UIAbilityContext;
  /** 视口尺寸（px）：宿主 onAreaChange 按屏幕密度换算后下发，供屏幕四角反算；未下发时按等距估算回退 */
  private pxWidth: number = 0;
  private pxHeight: number = 0;

  /** 相机静止回调：宿主接线 MapLayerController.onCameraSettled（按新屏幕范围重载可见层） */
  onCameraSettled: ((camera: Camera, extent: VectorExtent) => void) | undefined = undefined;
  /** 相机方位角变化回调：宿主控制指北针复位按键显隐 */
  onHeadingChanged: ((heading: number) => void) | undefined = undefined;
  /** 状态文本变化回调：宿主 @State 刷新级别与中心坐标显示 */
  onStatusChanged: ((level: number, centerText: string) => void) | undefined = undefined;

  private timer: number = -1;
  private lastPose: number[] | null = null;
  private stableSinceMs: number = 0;
  private settledFired: boolean = false;

  constructor(view: NativeMapView, ctx: common.UIAbilityContext) {
    this.view = view;
    this.ctx = ctx;
  }

  /** 宿主 onAreaChange 下发视口尺寸（px，须与 screenToGeo 的 px 口径一致） */
  setViewportSize(widthPx: number, heightPx: number): void {
    this.pxWidth = widthPx;
    this.pxHeight = heightPx;
  }

  /** 启动级别/中心文本轮询刷新（页面 onPageShow / aboutToAppear） */
  startPolling(): void {
    this.stopPolling();
    this.timer = setInterval((): void => {
      this.updateStatusText();
      this.detectCameraSettled();
    }, STATUS_POLL_MS);
  }

  /** 停止轮询（页面 onPageHide / aboutToDisappear） */
  stopPolling(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  /**
   * 当前屏幕的实际可见 WGS84 矩形：把视口四角经 screenToGeo 反算后取经纬度极值，
   * 即真实屏幕范围（不按高度近似、也不向外扩大）。视口未就绪时回退按相机高度等距估算。
   */
  computeVisibleExtent(camera: Camera): VectorExtent {
    const pts: Camera[] = [];
    if (this.pxWidth > 0 && this.pxHeight > 0) {
      const xs: number[] = [0, this.pxWidth, 0, this.pxWidth];
      const ys: number[] = [0, 0, this.pxHeight, this.pxHeight];
      for (let i = 0; i < 4; i++) {
        const pos = this.view.screenToGeo(xs[i], ys[i]);
        if (pos !== undefined) {
          pts.push(new Camera(pos.latitude, pos.longitude, 0));
        }
      }
    }
    if (pts.length === 0) {
      // 回退：纬度半跨 = 高度/111320（约 1 度 = 111.32km），经度半跨按 cos(lat) 放大到等距
      const dLat: number = Math.abs(camera.altitude) / 111320.0;
      const cosLat: number = Math.max(Math.cos(camera.latitude * Math.PI / 180.0), 1e-6);
      const dLon: number = dLat / cosLat;
      return new VectorExtent(camera.longitude - dLon, camera.latitude - dLat,
        camera.longitude + dLon, camera.latitude + dLat);
    }
    let minLon: number = pts[0].longitude;
    let maxLon: number = pts[0].longitude;
    let minLat: number = pts[0].latitude;
    let maxLat: number = pts[0].latitude;
    for (let i = 1; i < pts.length; i++) {
      minLon = Math.min(minLon, pts[i].longitude);
      maxLon = Math.max(maxLon, pts[i].longitude);
      minLat = Math.min(minLat, pts[i].latitude);
      maxLat = Math.max(maxLat, pts[i].latitude);
    }
    return new VectorExtent(minLon, minLat, maxLon, maxLat);
  }

  /**
   * 装配初期相机恢复：独立 prefs 视角 > 文档相机 > 兜底默认。
   * prefs 中缺 heading/tilt 键时保持正北/水平（兼容早期版本存的视角）。
   */
  async initialCamera(docCamLongitude: number, docCamLatitude: number, docCamAltitude: number): Promise<Camera> {
    let lon: number = DEFAULT_LON;
    let lat: number = DEFAULT_LAT;
    let alt: number = DEFAULT_ALTITUDE;
    let heading: number = 0;
    let tilt: number = 0;
    const stored: number = await Prefs.getNumber(this.ctx, PREFS_NAME, KEY_LON, Number.NaN);
    if (!Number.isNaN(stored)) {
      lon = stored;
      lat = await Prefs.getNumber(this.ctx, PREFS_NAME, KEY_LAT, lat);
      alt = await Prefs.getNumber(this.ctx, PREFS_NAME, KEY_ALT, alt);
      heading = await Prefs.getNumber(this.ctx, PREFS_NAME, KEY_HEADING, 0);
      tilt = await Prefs.getNumber(this.ctx, PREFS_NAME, KEY_TILT, 0);
    } else if (!Number.isNaN(docCamLongitude) && !Number.isNaN(docCamLatitude)
      && !Number.isNaN(docCamAltitude)) {
      lon = docCamLongitude;
      lat = docCamLatitude;
      alt = docCamAltitude;
    }
    return new Camera(lat, lon, alt, heading, tilt);
  }

  /** 把当前相机（经纬度 + 高度 + 方位角 + 仰角）存独立 prefs，下次进入恢复 */
  saveCameraState(): void {
    const cam: Camera | undefined = this.view.getCamera();
    if (cam === undefined) {
      return;
    }
    Prefs.putNumber(this.ctx, PREFS_NAME, KEY_LON, cam.longitude);
    Prefs.putNumber(this.ctx, PREFS_NAME, KEY_LAT, cam.latitude);
    Prefs.putNumber(this.ctx, PREFS_NAME, KEY_ALT, cam.altitude);
    Prefs.putNumber(this.ctx, PREFS_NAME, KEY_HEADING, cam.heading);
    Prefs.putNumber(this.ctx, PREFS_NAME, KEY_TILT, cam.tilt);
  }

  zoomIn(): void {
    this.zoomBy(ZOOM_IN_FACTOR);
  }

  zoomOut(): void {
    this.zoomBy(ZOOM_OUT_FACTOR);
  }

  /**
   * 缩放：读回相机高度按系数缩放（<1 拉近、>1 拉远），并限幅到 MIN_CAMERA_ALTITUDE
   * （对应 20 级地面高度）防止超级别放大致末级瓦片撕裂/黑屏。
   */
  zoomBy(factor: number): void {
    const cam: Camera | undefined = this.view.getCamera();
    if (cam === undefined) {
      return;
    }
    cam.altitude = Math.max(cam.altitude * factor, MercatorZoom.MIN_CAMERA_ALTITUDE);
    this.view.setCamera(cam);
    this.updateStatusText();
  }

  /**
   * 缩放到四至范围：按经纬度跨度估算合适相机高度（span × 111320 × 1.5 留边）并移到范围中心。
   * 内核无相机动画能力，故即时定位。供「缩放到图层」、轨迹「缩放至」与查询结果定位复用。
   */
  zoomToExtent(minLon: number, minLat: number, maxLon: number, maxLat: number): void {
    const span: number = Math.max(Math.max(maxLon - minLon, maxLat - minLat), 0.01);
    const altitude: number = Math.max(span * 111320.0 * 1.5, MercatorZoom.MIN_CAMERA_ALTITUDE);
    this.view.setCamera(new Camera((minLat + maxLat) / 2.0, (minLon + maxLon) / 2.0, altitude));
    this.updateStatusText();
  }

  /** 缩放到图层四至（GDAL 读取，kmz 走 /vsizip/ 虚拟文件）；读不到范围则不动作 */
  zoomToLayerExtent(path: string): void {
    const openPath: string = path.toLowerCase().endsWith('.kmz') ? `/vsizip/${path}` : path;
    const extent: number[] | null = GdalVectorReader.layerExtent(openPath);
    if (extent !== null && extent.length === 4) {
      this.zoomToExtent(extent[0], extent[1], extent[2], extent[3]);
    } else {
      AppLog.w(`图层四至不可用，跳过缩放到图层: ${path}`);
    }
  }

  /** 平移至指定点：保留当前缩放级别（高度无效时才回退 GOTO_ALTITUDE） */
  moveToLocation(lat: number, lon: number): void {
    const cam: Camera | undefined = this.view.getCamera();
    const alt: number = (cam !== undefined && cam.altitude > 0.0) ? cam.altitude : GOTO_ALTITUDE;
    this.view.setCamera(new Camera(lat, lon, alt));
    this.updateStatusText();
  }

  /** 指北针复位：相机 heading 归零（2D 恒正北不受影响，留存值一并归零） */
  resetHeading(): void {
    const cam: Camera | undefined = this.view.getCamera();
    if (cam === undefined || cam.heading === 0.0) {
      return;
    }
    cam.heading = 0.0;
    this.view.setCamera(cam);
  }

  /** 当前相机方位角（度）；无相机返回 0 */
  heading(): number {
    const cam: Camera | undefined = this.view.getCamera();
    return cam === undefined ? 0 : cam.heading;
  }

  /** 当前相机；未就绪 undefined */
  camera(): Camera | undefined {
    return this.view.getCamera();
  }

  /**
   * 读回 native 相机刷新级别数字与中心坐标文本（换算与原主界面同源）。
   * 中心文本对齐 Android CameraNavigator：前缀 Center、恒用十进制度（formatDecimalDegrees），
   * 不受「坐标以米显示」配置影响——避免米制长坐标挤压左侧定位文本。
   */
  updateStatusText(): void {
    const cam: Camera | undefined = this.view.getCamera();
    if (cam === undefined) {
      return;
    }
    const level: number = MercatorZoom.altitudeToLevel(cam.altitude);
    if (this.onStatusChanged !== undefined) {
      this.onStatusChanged(level,
        CoordFormatter.formatDecimalDegrees('Center', cam.longitude, cam.latitude));
    }
    if (this.onHeadingChanged !== undefined) {
      this.onHeadingChanged(cam.heading);
    }
  }

  /**
   * 每轮询比对相机位姿签名（经/纬/高/方位）：变化则重置稳定计时；连续不变达 SETTLE_MS
   * 且本签名未触发过 → 回调一次。同一视角不重复触发（heading 计入：3D 旋转后视口四至改变需重载）。
   */
  private detectCameraSettled(): void {
    const cam: Camera | undefined = this.view.getCamera();
    if (cam === undefined) {
      return;
    }
    const now: number = Date.now();
    const sig: number[] = [cam.longitude, cam.latitude, cam.altitude, cam.heading];
    if (!CameraNavigator.samePose(this.lastPose, sig)) {
      this.lastPose = sig;
      this.stableSinceMs = now;
      this.settledFired = false;
      return;
    }
    if (!this.settledFired && now - this.stableSinceMs >= SETTLE_MS) {
      this.settledFired = true;
      AppLog.i(`相机静止触发: lon=${cam.longitude} lat=${cam.latitude} alt=${cam.altitude}`);
      if (this.onCameraSettled !== undefined) {
        this.onCameraSettled(cam, this.computeVisibleExtent(cam));
      }
    }
  }

  private static samePose(a: number[] | null, b: number[]): boolean {
    if (a === null || a.length !== b.length) {
      return false;
    }
    for (let i = 0; i < a.length; i++) {
      if (a[i] !== b[i]) {
        return false;
      }
    }
    return true;
  }
}
