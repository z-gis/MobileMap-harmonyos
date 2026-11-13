// DeskVector.ets —— 桌面端矢量数据业务包装：native JSON 解析、符号样式、地理量算与坐标格式化。
//
// native 契约（与手机端 entry/vector/GdalVectorReader 同源，两端一致）：
//   {"features":[{"geom":"POINT","x":lon,"y":lat,"fid":1,"layer":"名","fields":{"k":"v"}},
//                {"geom":"LINE","parts":[…]}, {"geom":"POLYGON","outer":[…],"holes":[…]}]}
//   失败额外带 {"error":"…"}；getFeatureAttributes 的字段包在顶层 {"fields":{…}}。
// 本类只做解析与纯计算，不碰 UI；比例尺/坐标单位换算集中在此，状态栏与工具条共用一套口径。
import { NativeLayerInfo, NativeVector, Position, VectorStyle } from '@zys/globecore';
import { AttrField, CoordUnit, DeskTheme, GeomKind, TablePage } from './DeskTheme';
import { DeskFormats } from './DeskImporter';
import { DeskLog } from './DeskLog';

/** native JSON 结构（只声明用到的字段） */
interface FeatureJson {
  geom?: string;
  fid?: number;
  x?: number;
  y?: number;
  layer?: string;
  fields?: Record<string, string>;
}

interface ResultJson {
  features?: FeatureJson[];
  error?: string;
  fields?: Record<string, string>;
}

/** 地球平均半径（m，IUGG）；量算用球面近似，内业读图精度足够 */
const EARTH_R_M: number = 6371008.8;
/** HarmonyOS 的 vp 物理定义恒为 1/160 英寸，故比例尺分母 = 米/vp × 160 / 0.0254 */
const VP_PER_INCH: number = 160;
const M_PER_INCH: number = 0.0254;

export class DeskVector {
  // ── JSON 解析 ──

  /** 错误串（空串 = 无错误）；解析失败也当无错误，交由上层按空结果处理 */
  static errorOf(json: string | null): string {
    if (json === null || json === undefined || json.length === 0) {
      return '无法打开数据文件';
    }
    try {
      const obj: ResultJson = JSON.parse(json) as ResultJson;
      return obj.error ?? '';
    } catch (e) {
      return '';
    }
  }

  /** 单要素属性回取 → 字段值对列表（保持 native 返回的字段顺序） */
  static attributesOf(json: string | null): AttrField[] {
    const out: AttrField[] = [];
    if (json === null || json === undefined) {
      return out;
    }
    try {
      const obj: ResultJson = JSON.parse(json) as ResultJson;
      DeskVector.pushFields(obj.fields, out);
    } catch (e) {
      DeskLog.w(`属性 JSON 解析失败: ${e}`);
    }
    return out;
  }

  /**
   * 要素 JSON → 属性表一页。headers 为字段名清单（不含 FID），本方法在最前插一列 FID。
   * total/offset 由调用方给（分页来自 SQL LIMIT/OFFSET 或全量切片）。
   */
  static tableOf(json: string | null, fieldNames: string[], total: number,
    offset: number): TablePage {
    const headers: string[] = ['FID'].concat(fieldNames);
    const page: TablePage = new TablePage(headers, [], [], total, offset, '');
    const err: string = DeskVector.errorOf(json);
    if (err.length > 0) {
      page.error = err;
      return page;
    }
    if (json === null || json === undefined) {
      return page;
    }
    try {
      const obj: ResultJson = JSON.parse(json) as ResultJson;
      const arr: FeatureJson[] = obj.features ?? [];
      for (let i = 0; i < arr.length; i++) {
        const f: FeatureJson = arr[i];
        const fid: number = f.fid ?? -1;
        const cells: string[] = [fid < 0 ? '' : `${fid}`];
        const rec: Record<string, string> | undefined = f.fields;
        for (let j = 0; j < fieldNames.length; j++) {
          const v: string | undefined = rec === undefined ? undefined : rec[fieldNames[j]];
          cells.push(v === undefined || v === null ? '' : `${v}`);
        }
        page.rows.push(cells);
        page.fids.push(fid);
      }
    } catch (e) {
      page.error = `要素数据解析失败：${e}`;
    }
    return page;
  }

  /**
   * 全量 JSON → 指定子层自成一张表（gpkg 多表时属性表按子层呈现）。
   * layerName 空串时自动定目标：优先 fidHint 命中的子层（识别选中记录所在表），否则首子层。
   * 表头取该表字段键的并集（保持出现顺序），避免拿第 0 层字段套其它层导致整列空值。
   * total/offset 由调用方切片时再填；解析出的目标子层名回写 page.subLayer。
   */
  static layerTable(json: string | null, layerName: string, fidHint: number = -1): TablePage {
    const page: TablePage = new TablePage(['FID'], [], [], 0, 0, '');
    const err: string = DeskVector.errorOf(json);
    if (err.length > 0) {
      page.error = err;
      return page;
    }
    if (json === null || json === undefined) {
      return page;
    }
    try {
      const obj: ResultJson = JSON.parse(json) as ResultJson;
      const arr: FeatureJson[] = obj.features ?? [];
      let target: string = layerName;
      if (target.length === 0 && arr.length > 0) {
        target = arr[0].layer ?? '';
        if (fidHint >= 0) {
          for (let i = 0; i < arr.length; i++) {
            if ((arr[i].fid ?? -1) === fidHint) {
              target = arr[i].layer ?? '';
              break;
            }
          }
        }
      }
      page.subLayer = target;
      const keys: string[] = [];
      const picked: FeatureJson[] = [];
      for (let i = 0; i < arr.length; i++) {
        const f: FeatureJson = arr[i];
        if ((f.layer ?? '') !== target) {
          continue;
        }
        picked.push(f);
        const rec: Record<string, string> | undefined = f.fields;
        if (rec !== undefined) {
          const ks: string[] = Object.keys(rec);
          for (let k = 0; k < ks.length; k++) {
            if (keys.indexOf(ks[k]) < 0) {
              keys.push(ks[k]);
            }
          }
        }
      }
      page.headers = ['FID'].concat(keys);
      page.total = picked.length;
      for (let i = 0; i < picked.length; i++) {
        const f: FeatureJson = picked[i];
        const fid: number = f.fid ?? -1;
        const cells: string[] = [fid < 0 ? '' : `${fid}`];
        const rec: Record<string, string> | undefined = f.fields;
        for (let j = 0; j < keys.length; j++) {
          const v: string | undefined = rec === undefined ? undefined : rec[keys[j]];
          cells.push(v === undefined || v === null ? '' : `${v}`);
        }
        page.rows.push(cells);
        page.fids.push(fid);
      }
    } catch (e) {
      page.error = `要素数据解析失败：${e}`;
    }
    return page;
  }

  /** 全量 JSON 的子层名清单（出现顺序去重）；单表/失败回空数组或单元素 */
  static layerNamesOf(json: string | null): string[] {
    const names: string[] = [];
    if (json === null || json === undefined || DeskVector.errorOf(json).length > 0) {
      return names;
    }
    try {
      const obj: ResultJson = JSON.parse(json) as ResultJson;
      const arr: FeatureJson[] = obj.features ?? [];
      for (let i = 0; i < arr.length; i++) {
        const ln: string = arr[i].layer ?? '';
        if (ln.length > 0 && names.indexOf(ln) < 0) {
          names.push(ln);
        }
      }
    } catch (e) {
      DeskLog.w(`子层名解析失败: ${e}`);
    }
    return names;
  }

  /**
   * 加载前探针：取首要素即可判出「打得开吗 / 有坐标系吗」。
   * CAD（dwg/dxf）无坐标系时 native 回 error，坐标不可信，必须终止加载而不是按 WGS84 错位显示。
   * 返回空串 = 可加载。
   */
  static probeError(path: string): string {
    // 不能用「SELECT * FROM 文件主名」探针：gpkg 走 SQLite 方言，表名是库内表而非文件主名，
    // 会误报 no such table。改为先统计（打开失败 -1），再用零面积 box 读一次触发 CAD 无坐标系防线。
    if (DeskVector.countOf(path) < 0) {
      return 'GDAL 无法打开该文件（格式不支持或文件损坏）';
    }
    let json: string | null = null;
    try {
      json = NativeVector.readVectorFeatures(path, 0, 0, 0, 0, false, '', false, 0);
    } catch (e) {
      return `原生库未加载，无法读取：${e}`;
    }
    if (json === null || json.length === 0) {
      return 'GDAL 读取要素失败';
    }
    return DeskVector.errorOf(json);
  }

  /** 首要素几何类别（TOC 符号形状用）；取不到回 MIXED */
  static geomKindOf(path: string): string {
    const sql: string = `SELECT * FROM "${DeskVector.tableName(path)}" LIMIT 1`;
    let json: string | null = null;
    try {
      json = NativeVector.queryVectorFeatures(path, sql);
    } catch (e) {
      DeskLog.w(`取几何类别失败 ${path}: ${e}`);
      json = null;
    }
    let kind: string = DeskVector.geomOfJson(json);
    if (kind.length > 0) {
      return kind;
    }
    // gpkg 等 SQLite 方言驱动按文件主名查不到表：小数据集按四至全读一次取首要素几何
    const count: number = DeskVector.countOf(path);
    if (count < 0 || count > 20000) {
      return GeomKind.MIXED;
    }
    const ext: number[] | null = DeskVector.extentOf(path);
    if (ext === null || ext.length < 4) {
      return GeomKind.MIXED;
    }
    try {
      json = NativeVector.readVectorFeatures(path, ext[0], ext[1], ext[2], ext[3], false, '', false, 0);
    } catch (e) {
      return GeomKind.MIXED;
    }
    kind = DeskVector.geomOfJson(json);
    return kind.length > 0 ? kind : GeomKind.MIXED;
  }

  private static geomOfJson(json: string | null): string {
    if (json === null || DeskVector.errorOf(json).length > 0) {
      return '';
    }
    try {
      const obj: ResultJson = JSON.parse(json) as ResultJson;
      const arr: FeatureJson[] = obj.features ?? [];
      if (arr.length === 0) {
        return '';
      }
      const g: string = arr[0].geom ?? '';
      if (g === GeomKind.POINT || g === GeomKind.LINE || g === GeomKind.POLYGON) {
        return g;
      }
    } catch (e) {
      DeskLog.w(`几何类别 JSON 解析失败: ${e}`);
    }
    return '';
  }

  /** 字段名清单（打开失败空数组） */
  static fieldNames(path: string): string[] {
    try {
      return NativeLayerInfo.getVectorFieldNames(path);
    } catch (e) {
      DeskLog.w(`取字段名失败 ${path}: ${e}`);
      return [];
    }
  }

  /** 四至 [minLon,minLat,maxLon,maxLat]；失败 null */
  static extentOf(path: string): number[] | null {
    try {
      const src: number[] | null = NativeLayerInfo.getLayerExtent(path);
      if (src === null || src.length < 4) {
        return null;
      }
      // native 运行时回 Float64Array；@Prop 深拷贝会造出无内部槽的同原型壳对象（读 .length 即崩），
      // 故在边界逐元素拷成普通数组再进状态。
      const out: number[] = [];
      for (let i = 0; i < 4; i++) {
        out.push(src[i]);
      }
      return out;
    } catch (e) {
      DeskLog.w(`取四至失败 ${path}: ${e}`);
      return null;
    }
  }

  /** 要素总数；失败 -1 */
  static countOf(path: string): number {
    try {
      return NativeVector.countVectorFeatures(path);
    } catch (e) {
      DeskLog.w(`统计要素失败 ${path}: ${e}`);
      return -1;
    }
  }

  /** 坐标系描述（「名称\nproj4」）；失败空串 */
  static srsOf(path: string): string {
    try {
      const s: string | null = NativeLayerInfo.getLayerSrs(path);
      return s === null ? '' : s;
    } catch (e) {
      return '';
    }
  }

  /** OGR 图层名：shp 即文件主名（gpkg 亦按主名预填，多子层时用户可在 SQL 里改） */
  static tableName(path: string): string {
    const slash: number = Math.max(path.lastIndexOf('/'), path.lastIndexOf('\\'));
    const name: string = slash >= 0 ? path.substring(slash + 1) : path;
    return DeskFormats.stemOf(name).split('"').join('""');
  }

  /** 属性表分页查询；SQL 失败返回 null，调用方回退全量读取 */
  static queryPage(path: string, limit: number, offset: number): string | null {
    const sql: string = `SELECT * FROM "${DeskVector.tableName(path)}" LIMIT ${limit} OFFSET ${offset}`;
    try {
      const json: string | null = NativeVector.queryVectorFeatures(path, sql);
      if (json === null || DeskVector.errorOf(json).length > 0) {
        return null;
      }
      return json;
    } catch (e) {
      DeskLog.w(`属性表查询失败 ${path}: ${e}`);
      return null;
    }
  }

  /** 全量读取（SQL 不可用时的回退；native 侧有要素数上限防 OOM） */
  static readAll(path: string): string | null {
    try {
      return NativeVector.readVectorFeatures(path, Number.NaN, Number.NaN, Number.NaN, Number.NaN,
        true, '', false, 0);
    } catch (e) {
      DeskLog.w(`全量读取失败 ${path}: ${e}`);
      return null;
    }
  }

  /** 单要素全字段回取（识别用） */
  static featureAttributes(path: string, fid: number): string | null {
    try {
      return NativeVector.getFeatureAttributes(path, fid);
    } catch (e) {
      DeskLog.w(`属性回取失败 ${path} fid=${fid}: ${e}`);
      return null;
    }
  }

  // ── 符号样式 ──

  /**
   * 按几何类别与主色造整层样式。面填充取主色 40% alpha（ArcMap 默认半透明填充），
   * 描边/线/点取主色实色；fillExplicit/lineExplicit 置 true 以覆盖 KML 逐要素原色，
   * 保证 TOC 色块与地图所见一致。
   */
  static styleFor(geom: string, color: number, labelField: string = ''): VectorStyle {
    const solid: number = (color & 0x00FFFFFF) | 0xFF000000;
    const fill: number = (color & 0x00FFFFFF) | 0x66000000;
    const style: VectorStyle = new VectorStyle(fill, solid, 1.2, solid, 2.0, solid, 5.0,
      labelField, 0xFFFFFFFF, 1.0, true, 0xFF000000);
    style.fillExplicit = true;
    style.lineExplicit = true;
    if (geom === GeomKind.LINE) {
      style.lineWidth = 2.2;
    } else if (geom === GeomKind.POINT) {
      style.pointRadiusDp = 5.5;
    }
    return style;
  }

  /** 选中高亮样式（ArcMap 青色，面近透明只留粗边） */
  static highlightStyle(): VectorStyle {
    const c: number = DeskTheme.HILIGHT_ARGB;
    const style: VectorStyle = new VectorStyle((c & 0x00FFFFFF) | 0x33000000, c, 2.6,
      c, 3.0, c, 7.0, '', c, 1.0, false, 0xFF000000);
    style.fillExplicit = true;
    style.lineExplicit = true;
    return style;
  }

  // ── 地理量算 ──

  /** 球面大圆距离（m） */
  static distanceM(lon1: number, lat1: number, lon2: number, lat2: number): number {
    const p1: number = lat1 * Math.PI / 180;
    const p2: number = lat2 * Math.PI / 180;
    const dp: number = (lat2 - lat1) * Math.PI / 180;
    const dl: number = (lon2 - lon1) * Math.PI / 180;
    const a: number = Math.sin(dp / 2) * Math.sin(dp / 2)
      + Math.cos(p1) * Math.cos(p2) * Math.sin(dl / 2) * Math.sin(dl / 2);
    const c: number = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(Math.max(0, 1 - a)));
    return EARTH_R_M * c;
  }

  /** 两个采样点（相距 vpDistance 个 vp）→ 米/vp；采样无效返回 0 */
  static metersPerVp(a: Position | undefined, b: Position | undefined, vpDistance: number): number {
    if (a === undefined || b === undefined || vpDistance <= 0) {
      return 0;
    }
    const d: number = DeskVector.distanceM(a.longitude, a.latitude, b.longitude, b.latitude);
    return d <= 0 || !isFinite(d) ? 0 : d / vpDistance;
  }

  /** 比例尺分母（1:N 的 N）；米/vp ≤0 返回 0 */
  static scaleDenominator(mppVp: number): number {
    if (mppVp <= 0 || !isFinite(mppVp)) {
      return 0;
    }
    return mppVp * VP_PER_INCH / M_PER_INCH;
  }

  /** 比例尺文本 1:24,000（ArcMap 口径；无效返回 --） */
  static scaleText(mppVp: number): string {
    const d: number = DeskVector.scaleDenominator(mppVp);
    if (d <= 0) {
      return '--';
    }
    return `1:${DeskVector.groupDigits(Math.round(d))}`;
  }

  /** 四至的东西向地面宽（m，按中纬圈算）与南北向高（m） */
  static extentWidthM(extent: number[]): number {
    if (extent.length < 4) {
      return 0;
    }
    const midLat: number = (extent[1] + extent[3]) / 2;
    return DeskVector.distanceM(extent[0], midLat, extent[2], midLat);
  }

  static extentHeightM(extent: number[]): number {
    if (extent.length < 4) {
      return 0;
    }
    const midLon: number = (extent[0] + extent[2]) / 2;
    return DeskVector.distanceM(midLon, extent[1], midLon, extent[3]);
  }

  /** 摊平经纬度数组 [lon,lat,…] → 四至；空数组返回 [] */
  static extentOfLonLat(lonlat: number[]): number[] {
    if (lonlat.length < 2) {
      return [];
    }
    let minLon: number = lonlat[0];
    let maxLon: number = lonlat[0];
    let minLat: number = lonlat[1];
    let maxLat: number = lonlat[1];
    for (let i = 2; i + 1 < lonlat.length; i += 2) {
      const lon: number = lonlat[i];
      const lat: number = lonlat[i + 1];
      if (lon < minLon) { minLon = lon; }
      if (lon > maxLon) { maxLon = lon; }
      if (lat < minLat) { minLat = lat; }
      if (lat > maxLat) { maxLat = lat; }
    }
    return [minLon, minLat, maxLon, maxLat];
  }

  /**
   * 让四至适配视口所需的海拔：地面跨度与海拔成正比（固定 FOV + 视口高），
   * 故 新海拔 = 当前海拔 × 目标米每vp / 当前米每vp。留 8% 边距，避免要素贴边。
   * 当前米每vp 未知（首帧前）时返回 0，调用方沿用默认视野。
   */
  static altitudeForExtent(extent: number[], viewWVp: number, viewHVp: number,
    currentAlt: number, currentMpp: number): number {
    if (extent.length < 4 || viewWVp <= 0 || viewHVp <= 0 || currentMpp <= 0 || currentAlt <= 0) {
      return 0;
    }
    const wM: number = DeskVector.extentWidthM(extent);
    const hM: number = DeskVector.extentHeightM(extent);
    const target: number = Math.max(wM / (viewWVp * 0.92), hM / (viewHVp * 0.92));
    if (target <= 0 || !isFinite(target)) {
      return 0;
    }
    return currentAlt * target / currentMpp;
  }

  // ── 坐标格式化 ──

  /** 光标/中心坐标文本（按单位切换）；无效返回 -- */
  static coordText(lon: number, lat: number, unit: CoordUnit): string {
    if (!isFinite(lon) || !isFinite(lat)) {
      return '--';
    }
    if (unit === CoordUnit.DMS) {
      return `${DeskVector.dms(lon, 'E', 'W')} ${DeskVector.dms(lat, 'N', 'S')}`;
    }
    if (unit === CoordUnit.DM) {
      return `${DeskVector.dm(lon, 'E', 'W')} ${DeskVector.dm(lat, 'N', 'S')}`;
    }
    const lonH: string = lon >= 0 ? 'E' : 'W';
    const latH: string = lat >= 0 ? 'N' : 'S';
    return `${Math.abs(lon).toFixed(6)}°${lonH} ${Math.abs(lat).toFixed(6)}°${latH}`;
  }

  static unitLabel(unit: CoordUnit): string {
    switch (unit) {
      case CoordUnit.DMS: return '度分秒';
      case CoordUnit.DM: return '度分';
      default: return '十进制度';
    }
  }

  private static dms(v: number, pos: string, neg: string): string {
    const hemi: string = v >= 0 ? pos : neg;
    const a: number = Math.abs(v);
    let d: number = Math.floor(a);
    const mFull: number = (a - d) * 60;
    let m: number = Math.floor(mFull);
    let s: number = (mFull - m) * 60;
    if (s >= 59.995) { s = 0; m++; }
    if (m >= 60) { m = 0; d++; }
    return `${d}°${DeskVector.pad2(m)}'${s.toFixed(2)}"${hemi}`;
  }

  private static dm(v: number, pos: string, neg: string): string {
    const hemi: string = v >= 0 ? pos : neg;
    const a: number = Math.abs(v);
    const d: number = Math.floor(a);
    let m: number = (a - d) * 60;
    if (m >= 59.9995) { m = 0; }
    return `${d}°${m.toFixed(3)}'${hemi}`;
  }

  private static pad2(n: number): string {
    return n < 10 ? `0${n}` : `${n}`;
  }

  /** 整数千分位（比例尺/要素数显示） */
  static groupDigits(n: number): string {
    const s: string = `${Math.round(n)}`;
    let out: string = '';
    for (let i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 === 0) {
        out += ',';
      }
      out += s.charAt(i);
    }
    return out;
  }

  private static pushFields(rec: Record<string, string> | undefined, out: AttrField[]): void {
    if (rec === undefined || rec === null) {
      return;
    }
    const keys: string[] = Object.keys(rec);
    for (let i = 0; i < keys.length; i++) {
      const v: string | undefined = rec[keys[i]];
      out.push(new AttrField(keys[i], v === undefined || v === null ? '' : `${v}`));
    }
  }
}