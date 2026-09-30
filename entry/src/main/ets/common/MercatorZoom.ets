// MercatorZoom.ets —— Web Mercator 层级/相机高度换算（对应 Android com.zys.mobilemap.location.MercatorZoom）。
//
// 纯数学，不依赖渲染栈。层级显示文本、图层最小可见级别判定、缩放限幅均以此为唯一口径。
// 注意赤道半径（6378137，Web Mercator 金字塔口径）与 GeoCalc 的平均半径（6371000，量算口径）不同源，勿混用。
export class MercatorZoom {
  /** WGS84 赤道半径（米） */
  private static readonly WGS84_EQUATORIAL_RADIUS: number = 6378137.0;

  /** 层级显示上限（超出后底图走祖先瓦片拉伸，层级号不再增长） */
  static readonly MAX_LEVEL: number = 20;

  /**
   * 相机高度下限（米）：对应 MAX_LEVEL 级的地面高度，手势/按键放大到此高度后不再拉近。
   * 防止相机高度趋近 0 时末级瓦片过度拉伸乃至黑屏。2πR / 2^20 ≈ 38.2m。
   */
  static readonly MIN_CAMERA_ALTITUDE: number =
    2.0 * Math.PI * MercatorZoom.WGS84_EQUATORIAL_RADIUS / Math.pow(2.0, MercatorZoom.MAX_LEVEL);

  /** 相机高度（米）→ 瓦片层级：level = log2(赤道周长 / 高度)，限幅 0..MAX_LEVEL */
  static altitudeToLevel(altitude: number): number {
    if (altitude <= 0) {
      return 0;
    }
    const circumference: number = 2.0 * Math.PI * MercatorZoom.WGS84_EQUATORIAL_RADIUS;
    const level: number = Math.floor(Math.log(circumference / altitude) / Math.LN2);
    return Math.max(0, Math.min(MercatorZoom.MAX_LEVEL, level));
  }

  /** 层级 → 相机高度（米），altitudeToLevel 的逆运算 */
  static levelToAltitude(level: number): number {
    const clamped: number = Math.max(0, Math.min(MercatorZoom.MAX_LEVEL, level));
    return 2.0 * Math.PI * MercatorZoom.WGS84_EQUATORIAL_RADIUS / Math.pow(2.0, clamped);
  }
}
