// VectorMetaCache.ets —— 矢量图层元数据缓存（P1，对应 Android vector/VectorMetaCache.kt）。
//
// 把 native 读取链顺手产出的全量元数据（几何类型/要素总数/数据四至）持久化到 document.json 的 LayerInfo，
// 以源文件修改时间指纹判新鲜度——冷启动与图层管理逐行回显不再为元数据另开 GDAL；
// 源文件被外部修改/几何编辑/重导入（指纹变）自动失效回落直读。
//
// 口径：内核 VectorLayerMeta 给的是「数据全量」值（屏幕过滤重载也不会拿子集冒充），
// 未知项（featureCount=-1 / hasExtent=false）不写缓存、不覆盖既有好值，访问器逐项判有效后回落直读。
// 几何类型存 app 口径（0 点 / 1 线 / 2 面 / -1 未知或混合），与 GdalVectorReader.geomTypeOf 一致；
// KML/KMZ 不缓存几何类型（其层声明恒 wkbUnknown，样式分节走 geomMaskOf 采样，口径不变）。
// 指纹统一毫秒（OHOS stat mtime 为秒，×1000），与 Android 同口径，跨端文档可互认。

import fs from '@ohos.file.fs';
import { VectorLayerMeta } from '@zys/globecore';
import { LayerInfo, MapDocument } from '../doc/DocModels';
import { DocumentManager } from '../doc/DocumentManager';
import { GdalVectorReader } from './GdalVectorReader';
import { VectorFormats } from './VectorFormats';

/** shp 附属族：改属性只动 .dbf、改几何动 .shp/.shx，故指纹取族内最大 mtime（.qix 索引不算数据） */
const SHP_FAMILY: string[] = ['.shp', '.shx', '.dbf', '.prj', '.cpg'];

/** 指纹短 TTL（毫秒）：图层管理逐行回显与元数据收口轮询免重复递归扫 gdb 大目录 */
const MTIME_TTL_MS: number = 1000;

class MtimeEntry {
  mtime: number;
  at: number;

  constructor(mtime: number, at: number) {
    this.mtime = mtime;
    this.at = at;
  }
}

/** 标注样本缓存项：指纹 + 首条非空注记值（空串也缓存，免反复回落读） */
class LabelSampleEntry {
  mtime: number;
  value: string;

  constructor(mtime: number, value: string) {
    this.mtime = mtime;
    this.value = value;
  }
}

export class VectorMetaCache {
  private static mtimeCache: Map<string, MtimeEntry> = new Map<string, MtimeEntry>();
  private static labelSampleCache: Map<string, LabelSampleEntry> = new Map<string, LabelSampleEntry>();

  /**
   * 源文件修改时间指纹（毫秒）：gdb 目录递归扫内层文件取最大（要素类编辑不改目录 mtime）；
   * shp 取附属族最大；gpkg/kmz/其余单文件取自身。路径不存在或读不到返回 0（=无指纹，永不信缓存）。
   */
  static sourceMtime(path: string): number {
    if (path.length === 0) {
      return 0;
    }
    const now: number = Date.now();
    const hit: MtimeEntry | undefined = VectorMetaCache.mtimeCache.get(path);
    if (hit !== undefined && now - hit.at < MTIME_TTL_MS) {
      return hit.mtime;
    }
    const m: number = VectorMetaCache.computeMtime(path);
    VectorMetaCache.mtimeCache.set(path, new MtimeEntry(m, now));
    return m;
  }

  private static computeMtime(path: string): number {
    let st: fs.Stat | null = null;
    try {
      st = fs.statSync(path);
    } catch (e) {
      return 0;
    }
    if (st === null) {
      return 0;
    }
    if (st.isDirectory()) {
      return VectorMetaCache.dirMaxMtime(path, st.mtime * 1000);
    }
    if (VectorFormats.extOf(path) === 'shp') {
      const stem: string = path.substring(0, path.length - 4);
      let max: number = st.mtime * 1000;
      for (let i = 0; i < SHP_FAMILY.length; i++) {
        try {
          const sib: fs.Stat = fs.statSync(stem + SHP_FAMILY[i]);
          if (!sib.isDirectory()) {
            max = Math.max(max, sib.mtime * 1000);
          }
        } catch (e) {
          continue; // 附属文件可缺（.prj/.cpg 常无）
        }
      }
      return max;
    }
    return st.mtime * 1000;
  }

  /** 目录内层文件最大 mtime（递归，失败按已扫部分返回） */
  private static dirMaxMtime(dirPath: string, seed: number): number {
    let max: number = seed;
    let names: string[] = [];
    try {
      names = fs.listFileSync(dirPath, { recursion: false });
    } catch (e) {
      return max;
    }
    for (let i = 0; i < names.length; i++) {
      const child: string = `${dirPath}/${names[i]}`;
      try {
        const st: fs.Stat = fs.statSync(child);
        max = st.isDirectory()
          ? Math.max(max, VectorMetaCache.dirMaxMtime(child, st.mtime * 1000))
          : Math.max(max, st.mtime * 1000);
      } catch (e) {
        continue;
      }
    }
    return max;
  }

  /** 缓存是否新鲜：指纹有效且与当前源文件一致（0=无指纹，一律不信） */
  static isFresh(info: LayerInfo, mtime: number): boolean {
    return mtime > 0 && info.metaMtime === mtime;
  }

  /** 要素总数（全量）：缓存命中直接返回，否则开 GDAL 统计；未知 -1 */
  static featureCountOf(info: LayerInfo): number {
    const path: string = info.path ?? '';
    if (path.length === 0) {
      return -1;
    }
    if (VectorMetaCache.isFresh(info, VectorMetaCache.sourceMtime(path)) && info.featureCount >= 0) {
      return info.featureCount;
    }
    return GdalVectorReader.countFeatures(path, info.layerName);
  }

  /** 几何类型（app 口径 0 点 / 1 线 / 2 面 / -1 未知或混合）：缓存命中直接返回，否则直读 */
  static geomTypeOf(info: LayerInfo): number {
    const path: string = info.path ?? '';
    if (path.length === 0) {
      return -1;
    }
    if (VectorMetaCache.isFresh(info, VectorMetaCache.sourceMtime(path)) && info.geomType >= 0) {
      return info.geomType;
    }
    return GdalVectorReader.geomTypeOf(path, info.layerName);
  }

  /** 数据全量四至（WGS84 [minLon,minLat,maxLon,maxLat]）：缓存命中直接返回，否则直读；失败 null */
  static extentOf(info: LayerInfo): number[] | null {
    const path: string = info.path ?? '';
    if (path.length === 0) {
      return null;
    }
    if (VectorMetaCache.isFresh(info, VectorMetaCache.sourceMtime(path))) {
      const e: number[] | undefined = info.extent;
      if (e !== undefined && e.length === 4) {
        return e;
      }
    }
    return VectorMetaCache.readExtent(path, info.layerName);
  }

  /** 按路径查文档层后取四至（图层管理/缩放到图层等只持有路径的 UI 消费点用） */
  static extentOfPath(path: string, layerName: string = ''): number[] | null {
    const info: LayerInfo | undefined = VectorMetaCache.findInfo(path, layerName);
    if (info === undefined) {
      return VectorMetaCache.readExtent(path, layerName);
    }
    return VectorMetaCache.extentOf(info);
  }

  /** 按路径查文档层后取几何类型（同上，未加入文档的路径回落直读） */
  static geomTypeOfPath(path: string, layerName: string = ''): number {
    const info: LayerInfo | undefined = VectorMetaCache.findInfo(path, layerName);
    if (info === undefined) {
      return GdalVectorReader.geomTypeOf(path, layerName);
    }
    return VectorMetaCache.geomTypeOf(info);
  }

  /**
   * 标注样本值（图层管理预览用）：取首条非空要素的字段值作示例文本，与地图实际渲染内容同口径
   * （内核逐要素渲染字段值）。顺读前 3 个 FID（shp/gdb 0 起、gpkg 1 起），经 getFeatureAttributes
   * 复用句柄 LRU；按源文件指纹缓存（指纹变自动失效），空结果也缓存免反复读。
   * 取不到返回空串（调用方回退显示字段名）。
   */
  static labelSampleOf(path: string, layerName: string, field: string): string {
    if (path.length === 0 || field.length === 0) {
      return '';
    }
    const key: string = `${path}|${layerName}|${field}`;
    const mtime: number = VectorMetaCache.sourceMtime(path);
    const hit: LabelSampleEntry | undefined = VectorMetaCache.labelSampleCache.get(key);
    if (hit !== undefined && mtime > 0 && hit.mtime === mtime) {
      return hit.value;
    }
    let value: string = '';
    const openPath: string = VectorFormats.virtualPathOf(path);
    const lower: string = field.toLowerCase();
    for (let fid = 0; fid < 3 && value.length === 0; fid++) {
      const attrs: Map<string, string> | null =
        GdalVectorReader.getFeatureAttributes(openPath, fid, layerName);
      if (attrs === null) {
        continue;
      }
      attrs.forEach((v: string, k: string) => {
        if (value.length === 0 && k.toLowerCase() === lower && v.trim().length > 0) {
          value = v.trim();
        }
      });
    }
    VectorMetaCache.labelSampleCache.set(key, new LabelSampleEntry(mtime, value));
    return value;
  }

  /**
   * 把一次 native 元数据写回文档层（只写已知项，绝不以未知覆盖既有好值）。
   * 返回是否有字段变化（供宿主决定要不要 save 一次）。mtime=0（stat 失败）时不写指纹。
   */
  static applyMeta(info: LayerInfo, meta: VectorLayerMeta, mtime: number): boolean {
    let changed: boolean = false;
    const path: string = info.path ?? '';
    if (!VectorFormats.isKml(path)) {
      // native 码 1 点/2 线/3 面/4 混合 → app 码 0/1/2，混合与未知一律 -1（回落采样口径）
      const appGeom: number = meta.geomType === 1 ? 0 : (meta.geomType === 2 ? 1 : (meta.geomType === 3 ? 2 : -1));
      if (appGeom >= 0 && info.geomType !== appGeom) {
        info.geomType = appGeom;
        changed = true;
      }
    }
    if (meta.featureCount >= 0 && info.featureCount !== meta.featureCount) {
      info.featureCount = meta.featureCount;
      changed = true;
    }
    if (meta.hasExtent && meta.extent.length === 4) {
      const old: number[] | undefined = info.extent;
      let same: boolean = old !== undefined && old.length === 4;
      if (same && old !== undefined) {
        for (let i = 0; i < 4; i++) {
          if (old[i] !== meta.extent[i]) {
            same = false;
            break;
          }
        }
      }
      if (!same) {
        info.extent = [meta.extent[0], meta.extent[1], meta.extent[2], meta.extent[3]];
        changed = true;
      }
    }
    if (mtime > 0 && info.metaMtime !== mtime) {
      info.metaMtime = mtime;
      changed = true;
    }
    return changed;
  }

  /** 直读四至（kmz 走 /vsizip/ 虚拟文件，与既有消费点同口径） */
  private static readExtent(path: string, layerName: string): number[] | null {
    const openPath: string = VectorFormats.virtualPathOf(path);
    const e: number[] | null = GdalVectorReader.layerExtent(openPath, layerName);
    if (e === null || e.length < 4) {
      return null;
    }
    return [e[0], e[1], e[2], e[3]];
  }

  private static findInfo(path: string, layerName: string): LayerInfo | undefined {
    if (path.length === 0) {
      return undefined;
    }
    const doc: MapDocument | null = DocumentManager.getInstance().getDocument();
    if (doc === null) {
      return undefined;
    }
    // 精确匹配 path+layerName（与 Android 同口径）：gdb 多要素类共路径时不拿别层的缓存冒充
    const layers: LayerInfo[] = doc.vectorLayers;
    for (let i = 0; i < layers.length; i++) {
      if (layers[i].path === path && layers[i].layerName === layerName) {
        return layers[i];
      }
    }
    return undefined;
  }
}