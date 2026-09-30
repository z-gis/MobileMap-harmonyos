// LocationController.ets —— 定位展示与跟随（对应 Android ui.map.LocationFollowController）。
//
// 注册 LocationManager 监听、喂内核绘制罗盘定位标记（含方向箭头）、回调定位坐标文本、
// 跟随锁定时把相机平移到定位点；轨迹采集的定位追加点经 onTrackLocation 由宿主接线到 TrackController。
//
// 权限申请留在页面侧（鸿蒙 requestPermissionsFromUser 需 UIAbilityContext 且为异步弹窗），
// 授权结果回调转 startLocating()。

import { NativeMapView, Position } from 'globecore';
import { DocumentManager } from '../doc/DocumentManager';
import { CoordFormatter } from '../common/Coord';
import { GeoCalc } from '../common/GeoCalc';
import { Ui } from '../common/Ui';
import { LocationManager, LocationPoint } from '../location/LocationManager';
import { CameraNavigator } from './CameraNavigator';

/** 更新方位角所需的最小位移（米）：小于此值视为静止，不刷新箭头方向 */
const MIN_HEADING_DISTANCE_METERS: number = 1.5;

export class LocationController {
  private readonly view: NativeMapView;
  private readonly navigator: CameraNavigator;

  /** 定位跟随锁定：锁定后每次定位更新把相机平移到定位点 */
  private followEnabled: boolean = false;
  /** 锁定后等待首个定位点的待处理标记：拿到首点时对齐并提示 */
  private pendingLocate: boolean = false;
  /** 上一次定位点（用于计算移动方位角）；NaN 表示尚无历史点 */
  private lastMarkerLat: number = Number.NaN;
  private lastMarkerLon: number = Number.NaN;
  /** 最近一次有效移动方位角（度）：位移不足阈值时沿用，避免箭头抖动 */
  private lastHeading: number | undefined = undefined;

  /** 定位坐标文本变化（宿主 @State 刷新底部状态栏） */
  onLocationText: (text: string) => void = (): void => {};
  /** 跟随锁定态变化（宿主切换定位按钮图标） */
  onFollowChanged: (enabled: boolean) => void = (): void => {};
  /** 定位更新时的轨迹追加回调；由宿主接线到 TrackController.onLocation */
  onTrackLocation: (lat: number, lon: number, alt: number) => void = (): void => {};

  /** 监听器引用：off 时须传同一引用 */
  private readonly listener: (location: LocationPoint) => void =
    (location: LocationPoint): void => {
      this.onLocationChanged(location);
    };

  constructor(view: NativeMapView, navigator: CameraNavigator) {
    this.view = view;
    this.navigator = navigator;
  }

  isFollowing(): boolean {
    return this.followEnabled;
  }

  /** 注册定位监听并启动定位（复用 LocationManager 单例），并用最后已知位置立即刷新一次蓝点 */
  startLocating(): void {
    const lm: LocationManager = LocationManager.getInstance();
    lm.addLocationListener(this.listener);
    const doc = DocumentManager.getInstance().getDocument();
    const background: boolean = doc !== null && doc.systemConfig.backgroundLocation;
    lm.startLocation(background);
    const last: LocationPoint | null = lm.getLastLocation();
    if (last !== null) {
      this.onLocationChanged(last);
    }
  }

  /**
   * 定位更新：刷新定位坐标文本（经纬度/米制 + 海拔）+ 计算移动方位角 + 喂内核绘制定位蓝点（含方向箭头）。
   * 若处于跟随锁定，把相机平移到定位点（首点提示，其后静默跟随）。
   * 文本前缀对齐 Android LocationFollowController：GPS（随配置可切米制，带海拔时追加「 hN米」）。
   */
  onLocationChanged(location: LocationPoint): void {
    this.onLocationText(CoordFormatter.formatWithAlt('GPS', location.longitude,
      location.latitude, location.altitude));

    // 移动方位角：位移超过阈值才更新，避免静止/漂移时箭头抖动；无更新时沿用上次方位
    const heading: number | undefined = this.computeHeading(location.latitude, location.longitude);
    if (heading !== undefined) {
      this.lastHeading = heading;
    }
    this.view.setLocationMarker(new Position(location.latitude, location.longitude), true,
      this.lastHeading !== undefined ? this.lastHeading : -1);
    this.lastMarkerLat = location.latitude;
    this.lastMarkerLon = location.longitude;

    if (this.pendingLocate) {
      this.navigator.moveToLocation(location.latitude, location.longitude);
      this.pendingLocate = false;
    } else if (this.followEnabled) {
      this.navigator.moveToLocation(location.latitude, location.longitude);
    }

    // 轨迹采集：记录中且未暂停时把定位点追加为活动轨迹点
    this.onTrackLocation(location.latitude, location.longitude, location.altitude);
  }

  /**
   * 设置持续跟随锁定（对齐 Android LocationFollowController.setFollowEnabled）：
   * 由轨迹记录态驱动（开始/恢复记录→锁定，地图中心随定位移动；停止记录→解锁还原），
   * 定位键不再走这条路。同值重复调用直接返回（幂等）。
   */
  setFollowEnabled(enabled: boolean): void {
    if (this.followEnabled === enabled) {
      return;
    }
    this.followEnabled = enabled;
    // 宿主据此切换定位按钮为锁定样式（Android 换 nav_lock_location 图标）
    this.onFollowChanged(enabled);
    if (!enabled) {
      this.pendingLocate = false;
    }
  }

  /**
   * 定位键：单次把相机平移到当前定位点（保留缩放级别），不进入持续跟随锁定。
   * 无定位点时挂起等待标记，待首个定位到达时对齐并提示。
   */
  focusOnce(): void {
    const last: LocationPoint | null = LocationManager.getInstance().getLastLocation();
    if (last !== null) {
      this.navigator.moveToLocation(last.latitude, last.longitude);
      return;
    }
    this.pendingLocate = true;
    Ui.toast('等待定位...');
  }

  /**
   * 计算从上一次定位点到当前点的移动方位角（顺时针自北 0..360）；
   * 无历史点或位移小于阈值时返回 undefined（不更新方向）。
   */
  private computeHeading(toLat: number, toLon: number): number | undefined {
    if (Number.isNaN(this.lastMarkerLat) || Number.isNaN(this.lastMarkerLon)) {
      return undefined;
    }
    if (GeoCalc.distanceMeters(this.lastMarkerLat, this.lastMarkerLon, toLat, toLon)
      < MIN_HEADING_DISTANCE_METERS) {
      return undefined;
    }
    return GeoCalc.bearing(this.lastMarkerLat, this.lastMarkerLon, toLat, toLon);
  }

  /** 隐藏定位标记并注销监听（页面销毁 / 关闭定位时调用） */
  dispose(): void {
    LocationManager.getInstance().removeLocationListener(this.listener);
  }
}
