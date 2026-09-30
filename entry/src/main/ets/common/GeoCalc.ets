// GeoCalc.ets —— 球面几何量算工具（对应 Android com.zys.mobilemap.util.GeoCalc）。
//
// 距离/长度/周长走 Haversine，面积/质心/点到线段距离走局部等角平面近似（参考纬线取顶点平均纬度），
// 地球半径统一 6371000 米。测量模块、要素详情（面积/长度/周长展示）、样地调查（GPS 是否落在小班环内）共用。
// 点一律用 [纬度, 经度] 语义的 LatLng，避免与叠加层「经度在前」的摊平数组混淆。

/** 经纬度坐标对（十进制度）。lat=纬度、lng=经度，顺序与 Android 侧 DoubleArray[0]=lat 一致。 */
export class LatLng {
  lat: number = 0;
  lng: number = 0;

  constructor(lat: number = 0, lng: number = 0) {
    this.lat = lat;
    this.lng = lng;
  }
}

export class GeoCalc {
  private static readonly EARTH_RADIUS: number = 6371000.0;
  /** 面积退化判定阈值（平方米²量级）：顶点近共线时鞋带公式结果趋零，需回退算术平均 */
  private static readonly AREA_EPSILON: number = 1e-9;
  /** 亩换算系数：1 平方米 = 0.0015 亩 */
  private static readonly SQUARE_METER_TO_MU: number = 0.0015;

  /** 两点间球面距离（Haversine），单位米 */
  static distanceMeters(lat1: number, lon1: number, lat2: number, lon2: number): number {
    const p1: number = lat1 * Math.PI / 180;
    const p2: number = lat2 * Math.PI / 180;
    const dLat: number = p2 - p1;
    const dLon: number = (lon2 - lon1) * Math.PI / 180;
    const sinHalfDLat: number = Math.sin(dLat / 2);
    const sinHalfDLon: number = Math.sin(dLon / 2);
    const h: number = sinHalfDLat * sinHalfDLat
      + Math.cos(p1) * Math.cos(p2) * sinHalfDLon * sinHalfDLon;
    // min 兜底：浮点误差可能让 h 略大于 1，asin 返回 NaN
    return 2 * GeoCalc.EARTH_RADIUS * Math.asin(Math.min(1.0, Math.sqrt(h)));
  }

  static distance(a: LatLng, b: LatLng): number {
    return GeoCalc.distanceMeters(a.lat, a.lng, b.lat, b.lng);
  }

  /** 折线长度，单位米 */
  static polylineLengthMeters(points: LatLng[]): number {
    if (points.length < 2) {
      return 0;
    }
    let sum: number = 0;
    for (let i = 1; i < points.length; i++) {
      sum += GeoCalc.distance(points[i - 1], points[i]);
    }
    return sum;
  }

  /** 闭合环周长，单位米（首尾自动闭合） */
  static ringPerimeterMeters(ring: LatLng[]): number {
    if (ring.length < 2) {
      return 0;
    }
    let sum: number = 0;
    for (let i = 0; i < ring.length; i++) {
      const a: LatLng = ring[i];
      const b: LatLng = ring[(i + 1) % ring.length];
      sum += GeoCalc.distance(a, b);
    }
    return sum;
  }

  /** 多边形带符号面积（局部等角平面鞋带公式），单位平方米；逆时针为正 */
  static polygonSignedAreaSquareMeters(points: LatLng[]): number {
    if (points.length < 3) {
      return 0;
    }
    const cosLat0: number = Math.cos(GeoCalc.meanLatitudeRadians(points));
    let area2: number = 0;
    for (let i = 0; i < points.length; i++) {
      const a: LatLng = points[i];
      const b: LatLng = points[(i + 1) % points.length];
      const ax: number = GeoCalc.projectX(a.lng, cosLat0);
      const ay: number = GeoCalc.projectY(a.lat);
      const bx: number = GeoCalc.projectX(b.lng, cosLat0);
      const by: number = GeoCalc.projectY(b.lat);
      area2 += ax * by - bx * ay;
    }
    return area2 / 2.0;
  }

  /** 多边形面积，单位平方米（首尾无需闭合） */
  static polygonAreaSquareMeters(points: LatLng[]): number {
    return Math.abs(GeoCalc.polygonSignedAreaSquareMeters(points));
  }

  /**
   * 多边形质心（面积加权，局部等角平面近似）；面积退化时回退顶点算术平均。
   * 供面积标注落点使用。
   */
  static polygonCentroid(points: LatLng[]): LatLng {
    if (points.length < 3) {
      if (points.length === 0) {
        return new LatLng(0, 0);
      }
      return new LatLng(points[0].lat, points[0].lng);
    }
    const cosLat0: number = Math.cos(GeoCalc.meanLatitudeRadians(points));
    let area2: number = 0;
    let cx: number = 0;
    let cy: number = 0;
    for (let i = 0; i < points.length; i++) {
      const a: LatLng = points[i];
      const b: LatLng = points[(i + 1) % points.length];
      const ax: number = GeoCalc.projectX(a.lng, cosLat0);
      const ay: number = GeoCalc.projectY(a.lat);
      const bx: number = GeoCalc.projectX(b.lng, cosLat0);
      const by: number = GeoCalc.projectY(b.lat);
      const cross: number = ax * by - bx * ay;
      area2 += cross;
      cx += (ax + bx) * cross;
      cy += (ay + by) * cross;
    }
    if (Math.abs(area2) < GeoCalc.AREA_EPSILON) {
      let lat: number = 0;
      let lng: number = 0;
      for (let i = 0; i < points.length; i++) {
        lat += points[i].lat;
        lng += points[i].lng;
      }
      return new LatLng(lat / points.length, lng / points.length);
    }
    cx /= 3.0 * area2;
    cy /= 3.0 * area2;
    return new LatLng(cy / GeoCalc.EARTH_RADIUS * 180 / Math.PI,
      cx / (GeoCalc.EARTH_RADIUS * cosLat0) * 180 / Math.PI);
  }

  /** 点到线段的最短距离（局部等角平面近似），单位米 */
  static distanceToSegmentMeters(lat: number, lon: number, a: LatLng, b: LatLng): number {
    // 参考纬线取点与线段两端平均纬度，使投影在三者之间近似等角
    const cosLat0: number = Math.cos((a.lat + b.lat + lat) / 3.0 * Math.PI / 180);
    const px: number = GeoCalc.projectX(lon, cosLat0);
    const py: number = GeoCalc.projectY(lat);
    const ax: number = GeoCalc.projectX(a.lng, cosLat0);
    const ay: number = GeoCalc.projectY(a.lat);
    const bx: number = GeoCalc.projectX(b.lng, cosLat0);
    const by: number = GeoCalc.projectY(b.lat);
    const dx: number = bx - ax;
    const dy: number = by - ay;
    if (dx === 0 && dy === 0) {
      const sx: number = px - ax;
      const sy: number = py - ay;
      return Math.sqrt(sx * sx + sy * sy);
    }
    let t: number = ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy);
    t = Math.max(0, Math.min(1, t));
    const ex: number = px - (ax + t * dx);
    const ey: number = py - (ay + t * dy);
    return Math.sqrt(ex * ex + ey * ey);
  }

  /**
   * 点到折线各段的最小距离，单位米；closed 为真时额外计入末点到首点的闭合边（面要素）。
   * 少于两点返回 Number.MAX_VALUE（视为不命中）。
   */
  static minEdgeDistanceMeters(points: LatLng[], lat: number, lon: number,
    closed: boolean = false): number {
    if (points.length < 2) {
      return Number.MAX_VALUE;
    }
    let min: number = Number.MAX_VALUE;
    for (let i = 1; i < points.length; i++) {
      min = Math.min(min, GeoCalc.distanceToSegmentMeters(lat, lon, points[i - 1], points[i]));
    }
    if (closed && points.length >= 3) {
      min = Math.min(min,
        GeoCalc.distanceToSegmentMeters(lat, lon, points[points.length - 1], points[0]));
    }
    return min;
  }

  /** 射线法判定点是否在多边形环内（经纬度平面近似），供样地调查判定 GPS 是否落在小班范围内 */
  static containsPoint(ring: LatLng[], lat: number, lon: number): boolean {
    if (ring.length < 3) {
      return false;
    }
    let inside: boolean = false;
    let j: number = ring.length - 1;
    for (let i = 0; i < ring.length; i++) {
      const yi: number = ring[i].lat;
      const xi: number = ring[i].lng;
      const yj: number = ring[j].lat;
      const xj: number = ring[j].lng;
      if ((yi > lat) !== (yj > lat)) {
        const intersectLon: number = (xj - xi) * (lat - yi) / (yj - yi) + xi;
        if (lon < intersectLon) {
          inside = !inside;
        }
      }
      j = i;
    }
    return inside;
  }

  /** 球面方位角（度，0=正北，顺时针）：定位标记罗盘箭头朝向与跟随模式使用 */
  static bearing(lat1: number, lon1: number, lat2: number, lon2: number): number {
    const p1: number = lat1 * Math.PI / 180;
    const p2: number = lat2 * Math.PI / 180;
    const dLon: number = (lon2 - lon1) * Math.PI / 180;
    const y: number = Math.sin(dLon) * Math.cos(p2);
    const x: number = Math.cos(p1) * Math.sin(p2) - Math.sin(p1) * Math.cos(p2) * Math.cos(dLon);
    return (Math.atan2(y, x) * 180 / Math.PI + 360) % 360;
  }

  /** 距离格式化：<1km 显示米，否则显示千米 */
  static formatDistance(meters: number): string {
    return meters < 1000.0 ? `${meters.toFixed(1)} m` : `${(meters / 1000.0).toFixed(3)} km`;
  }

  /** 面积格式化：平方米 +（亩），均保留 1 位小数 */
  static formatArea(squareMeters: number): string {
    return `${squareMeters.toFixed(1)} m²（${(squareMeters * GeoCalc.SQUARE_METER_TO_MU).toFixed(1)}亩）`;
  }

  /** 平方米 → 亩 */
  static toMu(squareMeters: number): number {
    return squareMeters * GeoCalc.SQUARE_METER_TO_MU;
  }

  /** 各顶点纬度的算术平均（弧度），作为局部等角投影参考纬线 */
  private static meanLatitudeRadians(points: LatLng[]): number {
    let sum: number = 0;
    for (let i = 0; i < points.length; i++) {
      sum += points[i].lat * Math.PI / 180;
    }
    return sum / points.length;
  }

  /** 经度投影到局部等角平面（米）：乘以参考纬线余弦压缩 */
  private static projectX(lonDegrees: number, cosLat0: number): number {
    return lonDegrees * Math.PI / 180 * GeoCalc.EARTH_RADIUS * cosLat0;
  }

  /** 纬度投影到局部等角平面（米） */
  private static projectY(latDegrees: number): number {
    return latDegrees * Math.PI / 180 * GeoCalc.EARTH_RADIUS;
  }
}
