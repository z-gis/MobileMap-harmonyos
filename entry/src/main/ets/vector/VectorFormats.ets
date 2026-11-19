// VectorFormats.ets —— 数据格式按扩展名分类（对应 Android 散落在 LayerManageDialog /
// VectorFileImporter 里的扩展名常量表，集中一处便于增删格式）。
//
// 读取能力由内核静态链接的 GDAL/OGR 驱动决定：
//  · 矢量：shp（依赖同目录 dbf/shx/prj/cpg）、kml、kmz（zip 内含 kml）、zip（shp 压缩包）、
//          dwg/dxf（libopencad + DXF 驱动，只读）、gpkg（单文件 SQLite + R-tree 索引）；
//  · 栅格：tif/tiff（GeoTIFF）、img（ERDAS HFA）；
//  · 可回写属性：shp/gpkg/geojson/kml/kmz（dwg 等只读驱动写回必失败，界面据此隐藏「编辑属性」）。

/** 图层类型常量（与 LayerInfo.type / document.json 取值一致） */
export class LayerType {
  static readonly VECTOR: string = 'vector';
  static readonly RASTER: string = 'raster';
}

export class VectorFormats {
  /** 矢量页签导入筛选 */
  static readonly VECTOR_EXTS: string[] = ['shp', 'kml', 'kmz', 'zip', 'dwg', 'dxf', 'gpkg',
    'geojson', 'json', 'gdb'];
  /** 栅格页签导入筛选 */
  static readonly RASTER_EXTS: string[] = ['tif', 'tiff', 'img'];
  /** 同名前缀附属文件（选 shp 时一并勾选，或压缩包内自带）；与 entry_pc DeskFormats 同口径 */
  static readonly SIDE_CAR_EXTS: string[] = ['dbf', 'shx', 'prj', 'cpg', 'sbn', 'sbx', 'qix',
    'xml', 'tfw', 'ovr', 'aux.xml', 'hdr'];
  /** 压缩包（导入时先解压再找主文件） */
  static readonly ARCHIVE_EXTS: string[] = ['zip', 'kmz'];
  /** 属性可写回源文件的格式 */
  static readonly WRITABLE_EXTS: string[] = ['shp', 'gpkg', 'geojson', 'json', 'kml', 'kmz', 'dxf', 'gdb'];
  /** 支持整层样式覆盖编辑的格式（kml 自带样式，改文档样式意义有限，故不列入） */
  static readonly STYLE_EDITABLE_EXTS: string[] = ['shp', 'gpkg', 'dxf', 'geojson', 'json', 'gdb'];
  /** 支持单要素样式覆盖的格式（GDAL 索引矢量、有稳定 FID；较整层表更窄） */
  static readonly FEATURE_STYLE_EXTS: string[] = ['shp', 'gpkg', 'gdb'];
  /** 支持 SQL 属性查询的格式 */
  static readonly SQL_QUERYABLE_EXTS: string[] = ['shp', 'gpkg', 'gdb'];
  /** 支持几何编辑（分割/删除/合并，写前自动备份）的格式 */
  static readonly GEOM_EDITABLE_EXTS: string[] = ['gdb', 'shp'];
  /** CAD 类格式：无坐标系信息时坐标不可信（内核回 error，须终止加载而非按 WGS84 错位显示） */
  static readonly CAD_EXTS: string[] = ['dwg', 'dxf'];
  /** KML 系：名称标注受 systemConfig.showKmlLabel 额外门控 */
  static readonly KML_EXTS: string[] = ['kml', 'kmz'];
  /**
   * 删除附属族（LayerFileDeleter 用，与 Android DELETE_* 同值）。
   * 是 SIDE_CAR_EXTS 的刻意超集：多删索引/元数据残件（.fbn/.fbx/.ain/.aih/.atx/.ixs/.mxs/.shp.xml/.rrd），
   * 不与 SIDE_CAR_EXTS（选择器放行）或 VectorMetaCache.SHP_FAMILY（mtime 指纹，数据文件子集）混用。
   */
  static readonly DELETE_SHP_EXTS: string[] = ['.shp', '.shx', '.dbf', '.prj', '.cpg', '.sbn', '.sbx',
    '.fbn', '.fbx', '.ain', '.aih', '.atx', '.ixs', '.mxs', '.qix', '.shp.xml', '.xml'];
  static readonly DELETE_RASTER_EXTS: string[] = ['.tfw', '.prj', '.ovr', '.rrd', '.aux.xml'];
  static readonly DELETE_CAD_EXTS: string[] = ['.prj'];

  /** 取小写扩展名（无扩展名返回空串）；入参可为路径或文件名 */
  static extOf(path: string): string {
    const slash: number = Math.max(path.lastIndexOf('/'), path.lastIndexOf('\\'));
    const name: string = slash >= 0 ? path.substring(slash + 1) : path;
    const dot: number = name.lastIndexOf('.');
    return dot > 0 ? name.substring(dot + 1).toLowerCase() : '';
  }

  static isVector(path: string): boolean {
    return VectorFormats.VECTOR_EXTS.indexOf(VectorFormats.extOf(path)) >= 0;
  }

  static isRaster(path: string): boolean {
    return VectorFormats.RASTER_EXTS.indexOf(VectorFormats.extOf(path)) >= 0;
  }

  static isArchive(path: string): boolean {
    return VectorFormats.ARCHIVE_EXTS.indexOf(VectorFormats.extOf(path)) >= 0;
  }

  static isKml(path: string): boolean {
    return VectorFormats.KML_EXTS.indexOf(VectorFormats.extOf(path)) >= 0;
  }

  static isCad(path: string): boolean {
    return VectorFormats.CAD_EXTS.indexOf(VectorFormats.extOf(path)) >= 0;
  }

  /** 是否 File Geodatabase 数据集目录（.gdb，path 为目录而非单文件） */
  static isGdb(path: string): boolean {
    return VectorFormats.extOf(path) === 'gdb';
  }

  /** 属性写回是否可能成功（仅按扩展名预判，真正成败仍以内核返回为准） */
  static attributeWritable(path: string): boolean {
    return VectorFormats.WRITABLE_EXTS.indexOf(VectorFormats.extOf(path)) >= 0;
  }

  /** 是否允许整层样式覆盖编辑 */
  static styleEditable(path: string): boolean {
    return VectorFormats.STYLE_EDITABLE_EXTS.indexOf(VectorFormats.extOf(path)) >= 0;
  }

  /** 是否支持单要素样式覆盖（须配合有效 FID 使用） */
  static featureStyleEditable(path: string): boolean {
    return VectorFormats.FEATURE_STYLE_EXTS.indexOf(VectorFormats.extOf(path)) >= 0;
  }

  /** 是否支持 SQL 属性查询 */
  static sqlQueryable(path: string): boolean {
    return VectorFormats.SQL_QUERYABLE_EXTS.indexOf(VectorFormats.extOf(path)) >= 0;
  }

  /** 是否支持几何编辑（分割/删除/合并） */
  static geomEditable(path: string): boolean {
    return VectorFormats.GEOM_EDITABLE_EXTS.indexOf(VectorFormats.extOf(path)) >= 0;
  }

  /**
   * kmz 是 zip 容器，GDAL 须走 /vsizip/ 虚拟文件系统打开内部 kml；其余格式原样返回。
   * 全工程凡需把路径交 GDAL 打开处统一经此函数，禁止再散落拼前缀。
   */
  static virtualPathOf(path: string): string {
    return VectorFormats.extOf(path) === 'kmz' ? `/vsizip/${path}` : path;
  }

  /** 由类型标记导出导入筛选扩展名（页签 → 文件选择器 filter） */
  static pickFilter(type: string): string[] {
    // 选择器必须放行伴随文件，否则 shp 族在系统选择器里根本选不中（只剩孤 .shp，GDAL 缺 shx 打开即失败）
    const base: string[] = type === LayerType.RASTER ? VectorFormats.RASTER_EXTS : VectorFormats.VECTOR_EXTS;
    return base.concat(VectorFormats.SIDE_CAR_EXTS);
  }

  /** 扩展名 → 中文格式名（图层列表副标题） */
  static labelOf(path: string): string {
    switch (VectorFormats.extOf(path)) {
      case 'shp':
        return 'Shapefile';
      case 'kml':
        return 'KML';
      case 'kmz':
        return 'KMZ';
      case 'zip':
        return 'Shapefile 压缩包';
      case 'gpkg':
        return 'GeoPackage';
      case 'gdb':
        return 'File Geodatabase';
      case 'dwg':
        return 'AutoCAD DWG';
      case 'dxf':
        return 'AutoCAD DXF';
      case 'geojson':
      case 'json':
        return 'GeoJSON';
      case 'tif':
      case 'tiff':
        return 'GeoTIFF';
      case 'img':
        return 'ERDAS IMG';
      default:
        return VectorFormats.extOf(path).toUpperCase();
    }
  }
}

/**
 * 矢量重载优化全局参数（对应 Android VectorReloadConfig）。
 * 鸿蒙侧保留同语义开关，便于与 Android 端同步调参；默认策略与 Android 一致：
 * Swap-on-ready 由内核实现（应用侧无需开关），其余保守关闭。
 */
export class VectorReloadConfig {
  /** 单图层要素上限截断：0 = 取内核硬上限兜底 */
  static readonly MAX_FEATURES_PER_LAYER: number = 0;
  /** computeVisibleExtent 的缓冲系数：1.0 = 无额外缓冲 */
  static readonly EXTENT_BUFFER_FACTOR: number = 1.0;
  /** 几何简化（内核 OGRGeometry::Simplify）：默认关，保留原始精度 */
  static readonly SIMPLIFY_GEOMETRY: boolean = false;
  /** 简化容差（WGS84 度），仅 SIMPLIFY_GEOMETRY 为 true 时生效 */
  static readonly SIMPLIFY_TOLERANCE_DEGREES: number = 1e-5;
}
