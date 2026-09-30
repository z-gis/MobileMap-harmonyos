// GdalVectorReader.ets —— GDAL/OGR 矢量读取业务包装（对应 Android vector.GdalVectorReader）。
//
// native 调用经渲染内核 NativeVector 门面（实现见引擎 bridge/vector_io.cpp），本类只做 JSON 解析与业务包装。
// JNI/NAPI 返回契约（两端一致）：
//   {"features":[{"geom":"POINT","x":lon,"y":lat,"fid":1,"layer":"名","fields":{"k":"v"}},
//                {"geom":"LINE","parts":[[[lon,lat],…],…]},
//                {"geom":"POLYGON","outer":[[lon,lat],…],"holes":[[[lon,lat],…],…]}]}
//   失败额外返回 {"error":"…"}（CAD 无坐标系等，坐标不可信，调用方须终止加载并提示，不得按 WGS84 错位显示）。
// Android 侧的流式 JsonReader 分支（Phase 4 优化）不迁移：ArkTS 无对应流式读取器，
// 且该分支默认关闭（VectorReloadConfig.USE_STREAMING_JSON=false），树形解析即既有行为。

import { NativeLayerInfo, NativeVector } from '@zys/globecore';
import { AppLog } from '../common/AppLog';

const TAG: string = 'GdalVectorReader';

/** 要素几何类型（与 native 回传字符串一致） */
export class GeomType {
  static readonly POINT: string = 'POINT';
  static readonly LINE: string = 'LINE';
  static readonly POLYGON: string = 'POLYGON';
}

/** native JSON 结构（仅声明用到的字段，多余字段忽略） */
interface FeatureJson {
  geom?: string;
  x?: number;
  y?: number;
  fid?: number;
  layer?: string;
  fields?: Record<string, string>;
  /** 线：每条线为 [[lon,lat],…] */
  parts?: number[][][];
  /** 面外环：[[lon,lat],…] */
  outer?: number[][];
  /** 面内环（洞）列表 */
  holes?: number[][][];
}

interface ReadResultJson {
  features?: FeatureJson[];
  error?: string;
  /** 单要素属性回取（getFeatureAttributes）的顶层字段包，其余接口无此字段 */
  fields?: Record<string, string>;
}

/**
 * 单个矢量要素（坐标已统一 WGS84）：
 *  · POINT：x/y = 经度/纬度；
 *  · LINE：parts 为各线段，每条线段摊平为 [lon0,lat0,lon1,lat1,…]；
 *  · POLYGON：outer 外环、holes 内环，均摊平。
 * fid 为源数据要素标识（拾取后读属性/回写定位用），layerName 为 GDAL 子图层名。
 */
export class VectorFeature {
  geom: string;
  x: number;
  y: number;
  /** 线要素各段：摊平 [lon,lat,…] */
  parts: number[][];
  /** 面外环（摊平） */
  outer: number[];
  /** 面内环列表（每个摊平） */
  holes: number[][];
  fid: number;
  layerName: string;
  fields: Map<string, string>;

  constructor(geom: string = GeomType.POINT, x: number = Number.NaN, y: number = Number.NaN,
    parts: number[][] = [], outer: number[] = [], holes: number[][] = [],
    fid: number = -1, layerName: string = '', fields: Map<string, string> = new Map<string, string>()) {
    this.geom = geom;
    this.x = x;
    this.y = y;
    this.parts = parts;
    this.outer = outer;
    this.holes = holes;
    this.fid = fid;
    this.layerName = layerName;
    this.fields = fields;
  }

  /** 点要素的 [纬度, 经度]（非点要素返回 NaN 对） */
  latLon(): number[] {
    return [this.y, this.x];
  }
}

/** 读取/查询统一结果：features 为 null 表示失败，error 为可展示的提示文本 */
export class VectorResult {
  features: VectorFeature[] | null;
  error: string;

  constructor(features: VectorFeature[] | null, error: string = '') {
    this.features = features;
    this.error = error;
  }

  isSuccess(): boolean {
    return this.features !== null;
  }
}

export class GdalVectorReader {
  /**
   * 快速统计要素总数（遍历全部子图层求和），供上层判定小数据集是否直接全量渲染。
   * 打开失败返回 -1。
   */
  static countFeatures(path: string): number {
    try {
      return NativeVector.countVectorFeatures(path);
    } catch (e) {
      AppLog.e(`统计要素数失败: ${path}`, e);
      return -1;
    }
  }

  /**
   * 按 FID 就地写回属性字段到源文件（仅改现有字段值）。
   * dwg 等只读驱动、无写权限、字段名不存在时返回 false；attrs 为空直接返回 true。
   */
  static updateAttributes(path: string, featureId: number, attrs: Map<string, string>): boolean {
    if (attrs.size === 0) {
      return true;
    }
    if (featureId < 0) {
      return false;
    }
    const keys: string[] = [];
    const values: string[] = [];
    attrs.forEach((value: string, key: string) => {
      keys.push(key);
      values.push(value);
    });
    try {
      return NativeVector.updateFeatureAttributes(path, featureId, keys, values);
    } catch (e) {
      AppLog.e(`属性写回失败: ${path} fid=${featureId}`, e);
      return false;
    }
  }

  /**
   * 读取矢量要素列表。
   * @param extent WGS84 四至 [minLon,minLat,maxLon,maxLat]，传 undefined 读全部
   * @param includeAllFields false = 延迟属性读取（仅保留 labelField 字段，点击时经 getFeatureAttributes 回取）
   */
  static readFeatures(path: string, extent: number[] | undefined = undefined,
    includeAllFields: boolean = true, labelField: string = '',
    simplifyGeometry: boolean = false, simplifyTolerance: number = 0): VectorResult {
    let json: string | null = null;
    try {
      if (extent !== undefined && extent.length >= 4) {
        json = NativeVector.readVectorFeatures(path, extent[0], extent[1], extent[2], extent[3],
          includeAllFields, labelField, simplifyGeometry, simplifyTolerance);
      } else {
        json = NativeVector.readVectorFeatures(path, Number.NaN, Number.NaN, Number.NaN, Number.NaN,
          includeAllFields, labelField, simplifyGeometry, simplifyTolerance);
      }
    } catch (e) {
      AppLog.e(`readVectorFeatures 失败: ${path}`, e);
      return new VectorResult(null, '原生库未加载，无法读取要素');
    }
    if (json === null || json === undefined) {
      return new VectorResult(null, `无法打开数据文件：${path}`);
    }
    const err: string = GdalVectorReader.peekError(json);
    if (err.length > 0) {
      // CAD 无坐标系：坐标不可信，终止加载并由界面提示原因
      return new VectorResult(null, err);
    }
    const list: VectorFeature[] | null = GdalVectorReader.parseFeatures(json);
    return list === null ? new VectorResult(null, '要素数据解析失败') : new VectorResult(list, '');
  }

  /**
   * 按 FID 单要素属性回取（延迟属性读取配套）：shp/gpkg 索引 seek ~10-30ms。
   * 打开失败 / fid 未命中返回 null，由调用方回退已有缓存。
   */
  static getFeatureAttributes(path: string, featureId: number): Map<string, string> | null {
    if (featureId < 0) {
      return null;
    }
    let json: string | null = null;
    try {
      json = NativeVector.getFeatureAttributes(path, featureId);
    } catch (e) {
      AppLog.e(`属性回取失败: ${path} fid=${featureId}`, e);
      return null;
    }
    if (json === null || json === undefined) {
      return null;
    }
    try {
      const obj: ReadResultJson = JSON.parse(json) as ReadResultJson;
      return GdalVectorReader.toFieldMap(obj.fields);
    } catch (e) {
      AppLog.e(`解析属性 JSON 失败: ${path} fid=${featureId}`, e);
      return null;
    }
  }

  /** 对矢量数据执行属性 SQL 查询（坐标已重投影 WGS84），错误经 error 回传不抛异常 */
  static queryFeatures(path: string, sql: string): VectorResult {
    let json: string | null = null;
    try {
      json = NativeVector.queryVectorFeatures(path, sql);
    } catch (e) {
      AppLog.e(`queryVectorFeatures 失败: ${path}`, e);
      return new VectorResult(null, '原生库未加载，无法执行查询');
    }
    if (json === null || json === undefined) {
      return new VectorResult(null, '无法打开数据文件');
    }
    const error: string = GdalVectorReader.peekError(json);
    if (error.length > 0) {
      return new VectorResult(null, error);
    }
    const list: VectorFeature[] | null = GdalVectorReader.parseFeatures(json);
    return list === null ? new VectorResult(null, '查询结果解析失败') : new VectorResult(list, '');
  }

  /** 字段名清单（SQL 查询字段列表用）；打开失败返回空数组 */
  static fieldNames(path: string): string[] {
    try {
      return NativeLayerInfo.getVectorFieldNames(path);
    } catch (e) {
      AppLog.e(`取字段名失败: ${path}`, e);
      return [];
    }
  }

  /** 图层四至 [minLon,minLat,maxLon,maxLat]（矢量优先、栅格兜底，非 WGS84 自动重投影）；失败 null */
  static layerExtent(path: string): number[] | null {
    try {
      return NativeLayerInfo.getLayerExtent(path);
    } catch (e) {
      AppLog.e(`取图层四至失败: ${path}`, e);
      return null;
    }
  }

  /** 图层坐标系描述文本（「名称\nproj4 定义」）；无法解析 null */
  static layerSrs(path: string): string | null {
    try {
      return NativeLayerInfo.getLayerSrs(path);
    } catch (e) {
      AppLog.e(`取图层坐标系失败: ${path}`, e);
      return null;
    }
  }

  private static peekError(json: string): string {
    try {
      const obj: ReadResultJson = JSON.parse(json) as ReadResultJson;
      return obj.error ?? '';
    } catch (e) {
      return '';
    }
  }

  private static toFieldMap(rec: Record<string, string> | undefined): Map<string, string> {
    const map: Map<string, string> = new Map<string, string>();
    if (rec === undefined || rec === null) {
      return map;
    }
    const keys: string[] = Object.keys(rec);
    for (let i = 0; i < keys.length; i++) {
      const value: string | undefined = rec[keys[i]];
      map.set(keys[i], value === undefined || value === null ? '' : `${value}`);
    }
    return map;
  }

  /** 解析要素 JSON（读取与查询共用），格式异常返回 null */
  private static parseFeatures(json: string): VectorFeature[] | null {
    try {
      const root: ReadResultJson = JSON.parse(json) as ReadResultJson;
      const arr: FeatureJson[] = root.features ?? [];
      const list: VectorFeature[] = [];
      for (let i = 0; i < arr.length; i++) {
        const f: FeatureJson = arr[i];
        const fields: Map<string, string> = GdalVectorReader.toFieldMap(f.fields);
        const fid: number = f.fid ?? -1;
        const layerName: string = f.layer ?? '';
        const geom: string = f.geom ?? '';
        if (geom === GeomType.POINT) {
          list.push(new VectorFeature(geom, f.x ?? Number.NaN, f.y ?? Number.NaN,
            [], [], [], fid, layerName, fields));
        } else if (geom === GeomType.LINE) {
          list.push(new VectorFeature(geom, Number.NaN, Number.NaN,
            GdalVectorReader.flattenParts(f.parts), [], [], fid, layerName, fields));
        } else if (geom === GeomType.POLYGON) {
          list.push(new VectorFeature(geom, Number.NaN, Number.NaN, [],
            GdalVectorReader.flattenRing(f.outer), GdalVectorReader.flattenParts(f.holes),
            fid, layerName, fields));
        }
      }
      return list;
    } catch (e) {
      AppLog.e('解析矢量要素 JSON 失败', e);
      return null;
    }
  }

  /** 环列表 → 摊平环列表：[[[lon,lat],…],…] -> [[lon,lat,…],…] */
  private static flattenParts(rings: number[][][] | undefined): number[][] {
    const out: number[][] = [];
    if (rings === undefined || rings === null) {
      return out;
    }
    for (let i = 0; i < rings.length; i++) {
      out.push(GdalVectorReader.flattenRing(rings[i]));
    }
    return out;
  }

  /** 单环 [[lon,lat],…] → [lon,lat,lon,lat,…] */
  private static flattenRing(ring: number[][] | undefined): number[] {
    const flat: number[] = [];
    if (ring === undefined || ring === null) {
      return flat;
    }
    for (let i = 0; i < ring.length; i++) {
      const pt: number[] = ring[i];
      flat.push(pt.length > 0 ? pt[0] : Number.NaN);
      flat.push(pt.length > 1 ? pt[1] : Number.NaN);
    }
    return flat;
  }
}
