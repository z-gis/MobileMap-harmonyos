// LocationManager.ets —— 系统定位单例（对应 Android location.LocationManager）。
//
// 与 Android 同构：进程内单例 + 最后已知位置缓存 + 多监听器广播，供地图定位标记、轨迹采集、
// 拍照打点三方共用；页面销毁只移除自己的监听器，不停止定位（定位由单例统一管理）。
//
// 鸿蒙差异（已在实现内消化）：
//  1) 无「多 provider 遍历」概念，改为 geoLocationManager 的 locationChange 订阅 + LocationRequest 参数；
//  2) 无 getLastKnownLocation(provider)，用同步的 getLastLocation() 预热缓存；
//  3) 后台定位需 backgroundTaskMode 声明，故 background=true 时仅延长间隔，不申请长时任务
//     ——外业主场景为前台作业，避免引入音频类长时任务的合规风险。
//  4) 卫星信息走 on('satelliteStatusChange')：鸿蒙只给可见星数与载噪比数组，
//     无 Android GnssStatus 的 usedInFix 逐星标志，故定位详情只展示「可见数 + 平均信噪比」。

import { geoLocationManager } from '@kit.LocationKit';
import { AppLog } from '../common/AppLog';

const TAG: string = 'LocationManager';

/** 最小更新间隔（秒），对齐 Android MIN_INTERVAL_MS = 2000 */
const MIN_INTERVAL_S: number = 2;
/** 最小更新距离（米），对齐 Android MIN_DISTANCE_M = 0 */
const MIN_DISTANCE_M: number = 0;
/** 后台模式下的放宽间隔（秒） */
const BACKGROUND_INTERVAL_S: number = 5;

/** 定位点（WGS84）：alt 为椭球高，无高程信息时 NaN */
export class LocationPoint {
  latitude: number = 0;
  longitude: number = 0;
  altitude: number = Number.NaN;
  /** 定位时间戳（毫秒） */
  time: number = 0;
  /** 水平精度（米），-1 未知 */
  accuracy: number = -1;
  /** 瞬时速度（米/秒），NaN 表示定位无该信息 */
  speed: number = Number.NaN;
  /** 方位角（度，顺时针自北），NaN 表示定位无该信息 */
  direction: number = Number.NaN;
  /** 数据源（geoLocationManager.LocationSourceType 数值），-1 未知 */
  sourceType: number = -1;

  constructor(latitude: number = 0, longitude: number = 0, altitude: number = Number.NaN,
    time: number = 0, accuracy: number = -1, speed: number = Number.NaN,
    direction: number = Number.NaN, sourceType: number = -1) {
    this.latitude = latitude;
    this.longitude = longitude;
    this.altitude = altitude;
    this.time = time;
    this.accuracy = accuracy;
    this.speed = speed;
    this.direction = direction;
    this.sourceType = sourceType;
  }
}

/**
 * GNSS 卫星状态快照（定位详情用）。
 * 鸿蒙 satelliteStatusChange 只上报可见卫星数与其载噪比数组，没有 Android GnssStatus
 * 的 usedInFix 逐星标志，故此处只给「可见数 + 平均信噪比」，参与定位数不报（显示侧省略）。
 */
export class SatelliteInfo {
  /** 可见卫星数 */
  visible: number = 0;
  /** 载噪比均值（dB·Hz），无有效信号为 NaN */
  avgCn0DbHz: number = Number.NaN;

  constructor(visible: number = 0, avgCn0DbHz: number = Number.NaN) {
    this.visible = visible;
    this.avgCn0DbHz = avgCn0DbHz;
  }
}

export type LocationChangedListener = (location: LocationPoint) => void;

export class LocationManager {
  private static inst: LocationManager | null = null;

  private lastLocation: LocationPoint | null = null;
  private readonly listeners: LocationChangedListener[] = [];
  private locating: boolean = false;
  private backgroundMode: boolean = false;
  /** 已注册的回调引用：off 时必须传入同一引用，故缓存 */
  private boundCallback: ((location: object) => void) | null = null;
  /** 卫星状态回调引用（同上）；部分设备不支持该事件，注册失败则保持 null */
  private boundSatCallback: ((info: geoLocationManager.SatelliteStatusInfo) => void) | null = null;
  /** 最近一次卫星快照 */
  private lastSatInfo: SatelliteInfo | null = null;

  static getInstance(): LocationManager {
    if (LocationManager.inst === null) {
      LocationManager.inst = new LocationManager();
    }
    return LocationManager.inst;
  }

  /**
   * 开始定位更新。重复调用无副作用（已在定位中直接返回）。
   * @param background 后台宽松模式（延长上报间隔）
   */
  startLocation(background: boolean = false): void {
    if (this.locating) {
      return;
    }
    this.backgroundMode = background;
    this.locating = true;
    const request: geoLocationManager.LocationRequest = {
      priority: geoLocationManager.LocationRequestPriority.ACCURACY,
      scenario: geoLocationManager.LocationRequestScenario.NAVIGATION,
      timeInterval: background ? BACKGROUND_INTERVAL_S : MIN_INTERVAL_S,
      distanceInterval: MIN_DISTANCE_M,
    };
    const cb: (location: object) => void = (location: object): void => {
      this.dispatch(LocationManager.toPoint(location as geoLocationManager.Location));
    };
    this.boundCallback = cb;
    try {
      geoLocationManager.on('locationChange', request, cb);
    } catch (e) {
      AppLog.e('注册定位更新失败（可能未授权）', e);
      this.locating = false;
      this.boundCallback = null;
      return;
    }
    this.registerSatelliteListener();
    // 用系统缓存的最后一次定位预热：进图即可画蓝点，不等下一个 GPS 帧
    this.warmUpFromCache();
  }

  /**
   * 订阅 GNSS 卫星状态（定位详情的卫星项数据源）：需精确定位权限，
   * 设备不支持或注册失败时静默跳过（getSatelliteInfo 返回 null，显示侧给占位符）。
   */
  private registerSatelliteListener(): void {
    if (this.boundSatCallback !== null) {
      return;
    }
    const cb: (info: geoLocationManager.SatelliteStatusInfo) => void =
      (info: geoLocationManager.SatelliteStatusInfo): void => {
        this.lastSatInfo = LocationManager.toSatelliteInfo(info);
      };
    try {
      geoLocationManager.on('satelliteStatusChange', cb);
      this.boundSatCallback = cb;
    } catch (e) {
      AppLog.d(`卫星状态事件不可用: ${e}`);
    }
  }

  /** 快照可见星数与载噪比均值（仅统计有效正值，与 Android 同口径） */
  private static toSatelliteInfo(info: geoLocationManager.SatelliteStatusInfo): SatelliteInfo {
    const cn0: number[] | undefined = info.carrierToNoiseDensitys;
    let sum: number = 0;
    let cnt: number = 0;
    if (cn0 !== undefined && cn0 !== null) {
      for (let i = 0; i < cn0.length; i++) {
        if (Number.isFinite(cn0[i]) && cn0[i] > 0) {
          sum += cn0[i];
          cnt++;
        }
      }
    }
    return new SatelliteInfo(info.satellitesNumber, cnt > 0 ? sum / cnt : Number.NaN);
  }

  /** 读回系统缓存位置（同步 API，无则忽略） */
  private warmUpFromCache(): void {
    try {
      const cached: geoLocationManager.Location = geoLocationManager.getLastLocation();
      const point: LocationPoint = LocationManager.toPoint(cached);
      const cur: LocationPoint | null = this.lastLocation;
      if (cur === null || point.time > cur.time) {
        this.dispatch(point);
      }
    } catch (e) {
      AppLog.d(`无缓存定位: ${e}`);
    }
  }

  /** 主动拉取一次当前位置（权限已授予时用于单次定位/拍照打点），失败返回 null */
  async once(): Promise<LocationPoint | null> {
    try {
      const request: geoLocationManager.SingleLocationRequest = {
        locatingPriority: geoLocationManager.LocatingPriority.PRIORITY_LOCATING_SPEED,
        locatingTimeoutMs: 5,
      };
      const location: geoLocationManager.Location = await geoLocationManager.getCurrentLocation(request);
      const point: LocationPoint = LocationManager.toPoint(location);
      const cur: LocationPoint | null = this.lastLocation;
      if (cur === null || point.time >= cur.time) {
        this.lastLocation = point;
      }
      return point;
    } catch (e) {
      AppLog.w('getCurrentLocation 失败', `${e}`);
      return this.lastLocation;
    }
  }

  stopLocation(): void {
    if (!this.locating) {
      return;
    }
    this.locating = false;
    this.backgroundMode = false;
    try {
      if (this.boundCallback !== null) {
        geoLocationManager.off('locationChange', this.boundCallback);
      }
    } catch (e) {
      AppLog.w('取消定位更新失败', `${e}`);
    }
    this.boundCallback = null;
    if (this.boundSatCallback !== null) {
      try {
        geoLocationManager.off('satelliteStatusChange', this.boundSatCallback);
      } catch (e) {
        AppLog.w('取消卫星状态订阅失败', `${e}`);
      }
      this.boundSatCallback = null;
    }
  }

  isLocating(): boolean {
    return this.locating;
  }

  isBackgroundMode(): boolean {
    return this.backgroundMode;
  }

  getLastLocation(): LocationPoint | null {
    return this.lastLocation;
  }

  /** 最近一次 GNSS 卫星快照；设备不支持或未上报时为 null */
  getSatelliteInfo(): SatelliteInfo | null {
    return this.lastSatInfo;
  }

  /**
   * 数据源显示名：Android 侧直接给 Location.provider 字符串（gps/network/passive），
   * 鸿蒙侧只有 LocationSourceType 枚举，此处映射成同样的简短中文口径供定位详情显示。
   */
  static sourceTypeName(sourceType: number): string {
    switch (sourceType) {
      case 1:
        return 'GNSS（卫星）';
      case 2:
        return '网络';
      case 3:
        return '室内';
      case 4:
        return 'GNSS RTK';
      default:
        return '';
    }
  }

  addLocationListener(listener: LocationChangedListener | undefined | null): void {
    if (listener !== undefined && listener !== null && this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  removeLocationListener(listener: LocationChangedListener | undefined | null): void {
    const i: number = this.listeners.indexOf(listener as LocationChangedListener);
    if (i >= 0) {
      this.listeners.splice(i, 1);
    }
  }

  /** 缓存最新位置并广播；单个监听器异常不影响其余 */
  private dispatch(point: LocationPoint): void {
    this.lastLocation = point;
    for (let i = 0; i < this.listeners.length; i++) {
      try {
        this.listeners[i](point);
      } catch (e) {
        AppLog.e('定位监听器异常', e);
      }
    }
  }

  /**
   * 系统定位对象 → 业务定位点。
   * altitudeType 为 SURFACE_ALTPROVIDER 等无高程来源时 altitude 不可信，置 NaN 由显示侧省略海拔段。
   */
  private static toPoint(location: geoLocationManager.Location): LocationPoint {
    let alt: number = Number.NaN;
    if (location.altitude !== undefined && location.altitude !== null
      && !Number.isNaN(location.altitude)) {
      alt = location.altitude;
    }
    // timeStamp 为「距 1970 的秒数」（部分设备返回 0 表示未填充）
    const seconds: number = location.timeStamp;
    const time: number = seconds > 100000 ? seconds * 1000 : Date.now();
    // speed/direction 部分设备（尤其网络定位）不填，给 0/非法值时统一当无信息处理
    const speed: number = Number.isFinite(location.speed) ? location.speed : Number.NaN;
    const direction: number = Number.isFinite(location.direction) ? location.direction : Number.NaN;
    const source: number = location.sourceType !== undefined ? location.sourceType : -1;
    return new LocationPoint(location.latitude, location.longitude, alt, time,
      location.accuracy ?? -1, speed, direction, source);
  }
}
