// Coord.ets —— 坐标转换与坐标文本格式化（对应 Android util.CoordTransform + util.CoordFormatter）。
//
// 转换口径：WGS84 经纬度 ↔ CGCS2000 3 度带高斯-克吕格平面坐标（米，东坐标含带号前缀），
// 经渲染内核 NativeSrs.convert（C++ 侧按「源|目标」缓存 PROJ 管道）执行，可承受状态栏逐帧刷新。
// 不可用（proj.db 未就绪 / 编码非法 / native 异常）时置 unavailable 并返回 null，
// 由 CoordFormatter 回退十进制度显示——坐标显示绝不能因转换失败而中断渲染。

import { NativeSrs } from 'globecore';
import { AppLog } from './AppLog';

/** 转换结果平面坐标（米）：easting=东坐标（含带号）、northing=北坐标 */
export class PlaneCoord {
  easting: number = 0;
  northing: number = 0;

  constructor(easting: number = 0, northing: number = 0) {
    this.easting = easting;
    this.northing = northing;
  }
}

export class CoordTransform {
  /** CGCS2000 3 度带（带号前缀假东偏移）EPSG 编码起点：25 带 → EPSG:4534 */
  private static readonly ZONE_MIN_EPSG: number = 4534;
  /** 3 度带带号范围（中央经线 75°E ~ 135°E，覆盖全国） */
  private static readonly ZONE_MIN: number = 25;
  private static readonly ZONE_MAX: number = 45;

  static readonly CRS_WGS84: string = 'EPSG:4326';
  static readonly CRS_CGCS2000: string = 'EPSG:4490';

  /** native 转换是否不可用：首次失败后置真，不再重复尝试（避免逐帧刷无效调用） */
  private static unavailable: boolean = false;

  /** 按经度取 3 度带带号（中央经线 = 带号 × 3） */
  static zoneOf(lon: number): number {
    const zone: number = Math.round(lon / 3.0);
    return Math.max(CoordTransform.ZONE_MIN, Math.min(CoordTransform.ZONE_MAX, zone));
  }

  /** 带号 → EPSG 编码（38 带 → EPSG:4547）；带号映射唯一来源，「移动到」对话框下拉由此推导 */
  static epsgOfZone(zone: number): string {
    return `EPSG:${CoordTransform.ZONE_MIN_EPSG + zone - CoordTransform.ZONE_MIN}`;
  }

  /** 全国 3 度带候选带号列表（25..45），与 zoneEpsgList 同序，供下拉展示中央经线 */
  static zoneNumbers(): number[] {
    const list: number[] = [];
    for (let z = CoordTransform.ZONE_MIN; z <= CoordTransform.ZONE_MAX; z++) {
      list.push(z);
    }
    return list;
  }

  /** 全国 3 度带候选 EPSG 列表（25..45 带），供「移动到」对话框坐标系下拉 */
  static zoneEpsgList(): string[] {
    const list: string[] = [];
    for (let z = CoordTransform.ZONE_MIN; z <= CoordTransform.ZONE_MAX; z++) {
      list.push(CoordTransform.epsgOfZone(z));
    }
    return list;
  }

  /** WGS84 经纬度 → CGCS2000 3 度带平面坐标（带号按经度自动选取）；不可用返回 null */
  static toCgcs2000Meters(lon: number, lat: number): PlaneCoord | null {
    if (CoordTransform.unavailable || Number.isNaN(lon) || Number.isNaN(lat)) {
      return null;
    }
    return CoordTransform.convert(lon, lat, CoordTransform.CRS_WGS84,
      CoordTransform.epsgOfZone(CoordTransform.zoneOf(lon)));
  }

  /** 任意坐标系互转，失败返回 null */
  static convert(x: number, y: number, srcCrs: string, tgtCrs: string): PlaneCoord | null {
    if (srcCrs === tgtCrs) {
      return new PlaneCoord(x, y);
    }
    try {
      const res: number[] | null = NativeSrs.convert(x, y, srcCrs, tgtCrs);
      if (res === null || res === undefined || res.length < 2) {
        return null;
      }
      return new PlaneCoord(res[0], res[1]);
    } catch (e) {
      // native 库未加载等：标记不可用，后续直接回退十进制度
      CoordTransform.unavailable = true;
      AppLog.w(`坐标转换不可用 ${srcCrs} -> ${tgtCrs}`, `${e}`);
      return null;
    }
  }
}

/**
 * 主界面坐标文本格式化：按 SystemConfig.coordDisplayMeter 在十进制度与米之间切换，
 * 中心坐标与定位坐标共用同一入口保证格式一致。
 * meterDisplay 由 DocumentManager 在文档加载/变更时同步（避免 common 反向依赖 doc）。
 */
export class CoordFormatter {
  /** 当前是否以米（CGCS2000 投影）显示坐标 */
  static meterDisplay: boolean = false;

  /** 「前缀: 值1 值2」；米制转换失败自动回退十进制度 */
  static format(prefix: string, lon: number, lat: number): string {
    if (CoordFormatter.meterDisplay) {
      const meters: PlaneCoord | null = CoordTransform.toCgcs2000Meters(lon, lat);
      if (meters !== null) {
        return `${prefix}: ${meters.easting.toFixed(3)} ${meters.northing.toFixed(3)}`;
      }
    }
    return `${prefix}: ${lon.toFixed(4)} ${lat.toFixed(4)}`;
  }

  /**
   * 强制十进制度格式化（无视「坐标以米显示」配置）：主界面底部中心坐标恒用十进制度，
   * 与定位文本（随配置可切米制）区分，避免米制长坐标挤压定位行显示（Android formatDecimalDegrees 同源）。
   */
  static formatDecimalDegrees(prefix: string, lon: number, lat: number): string {
    return `${prefix}: ${lon.toFixed(4)} ${lat.toFixed(4)}`;
  }

  /**
   * 带海拔的定位坐标文本：在 [format] 结果后追加「 hN米」（h = height 海拔）。
   * alt 为 WGS84 椭球高（米），NaN 表示定位无海拔信息，此时不追加、退化为 [format]。
   */
  static formatWithAlt(prefix: string, lon: number, lat: number, alt: number): string {
    const base: string = CoordFormatter.format(prefix, lon, lat);
    if (Number.isNaN(alt)) {
      return base;
    }
    return `${base} h${alt.toFixed(0)}米`;
  }
}
