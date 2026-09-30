// DocModels.ets —— 地图文档数据模型（对应 Android doc 包 SystemConfig / MapSource / LayerInfo /
// VectorStyle / MapDocument 五个类的合体，字段与 document.json 键名严格一致）。
//
// 之所以并置一文件：这些类互为序列化依赖（MapDocument 聚合其余四类），拆开会造成大量循环引用，
// 且它们是纯数据 + JSON 双向映射，无行为差异。
//
// 注意样式模型命名为 StyleOverride（文档层「样式覆盖」），与渲染内核 HAR 导出的 VectorStyle
// （native 渲染参数）是两个不同层次的对象：前者落 JSON 且字段可空（空 = 继承源文件样式），
// 后者是最终喂给 native 的完整样式。二者转换见 map/MapStyle.ets。

/** 填充透明度 0..1；颜色一律 #AARRGGBB 文本（与 Android document.json 兼容） */
export interface StyleOverrideJson {
  fillColor?: string;
  fillOpacity?: number;
  fillEnabled?: boolean;
  outlineColor?: string;
  outlineWidth?: number;
  labelField?: string;
  labelColor?: string;
  labelSize?: number;
  labelOutline?: boolean;
  labelOutlineColor?: string;
  iconKey?: string;
  featureStyles?: Record<string, StyleOverrideJson>;
}

export interface LayerInfoJson {
  name?: string;
  path?: string;
  visible?: boolean;
  type?: string;
  styleVersion?: number;
  autoMinDisplayLevel?: number;
  userMinDisplayLevel?: number;
  vectorStyle?: StyleOverrideJson;
}

export interface MapSourceJson {
  name?: string;
  url?: string;
  visible?: boolean;
  token1?: string;
  token2?: string;
  imageFormat?: string;
  maxLevel?: number;
  system?: boolean;
  annotation?: boolean;
}

export interface SystemConfigJson {
  showCenterCross?: boolean;
  photoAddWatermark?: boolean;
  backgroundLocation?: boolean;
  showMediaLayer?: boolean;
  showPhotoName?: boolean;
  showTrackLayer?: boolean;
  showMeasureLayer?: boolean;
  coordDisplayMeter?: boolean;
  showKmlLabel?: boolean;
  viewMode3d?: boolean;
}

export interface MapDocumentJson {
  version?: number;
  systemConfig?: SystemConfigJson;
  mapSources?: MapSourceJson[];
  rasterLayers?: LayerInfoJson[];
  vectorLayers?: LayerInfoJson[];
  camLatitude?: number;
  camLongitude?: number;
  camAltitude?: number;
  camHeading?: number;
  camTilt?: number;
  camRoll?: number;
  camAltitudeMode?: number;
}

/**
 * 矢量图层样式覆盖：全部字段可空，空 = 保持源文件/默认样式。
 * 优先级：单要素样式（featureStyles）> 整层样式 > 源文件自带样式。
 */
export class StyleOverride {
  fillColor: string | undefined = undefined;
  fillOpacity: number | undefined = undefined;
  /** false = 面仅描边不填充 */
  fillEnabled: boolean | undefined = undefined;
  outlineColor: string | undefined = undefined;
  outlineWidth: number | undefined = undefined;
  labelField: string | undefined = undefined;
  labelColor: string | undefined = undefined;
  labelSize: number | undefined = undefined;
  labelOutline: boolean | undefined = undefined;
  labelOutlineColor: string | undefined = undefined;
  /** 点要素图标 key（见 vector/FeatureIcons），缺省 = 默认图标 */
  iconKey: string | undefined = undefined;
  /** 单要素样式覆盖：键 = 要素 FID */
  featureStyles: Map<number, StyleOverride> = new Map<number, StyleOverride>();

  isEmpty(): boolean {
    return this.fillColor === undefined && this.fillOpacity === undefined
      && this.fillEnabled === undefined && this.outlineColor === undefined
      && this.outlineWidth === undefined && this.labelField === undefined
      && this.labelColor === undefined && this.labelSize === undefined
      && this.labelOutline === undefined && this.labelOutlineColor === undefined
      && this.iconKey === undefined && this.featureStyles.size === 0;
  }

  /** 与整层样式合并：本对象（单要素）非空字段优先，空字段继承 base */
  mergedWith(base: StyleOverride | undefined): StyleOverride {
    const out: StyleOverride = StyleOverride.copy(this);
    if (base === undefined) {
      return out;
    }
    if (out.fillColor === undefined) {
      out.fillColor = base.fillColor;
    }
    if (out.fillOpacity === undefined) {
      out.fillOpacity = base.fillOpacity;
    }
    if (out.fillEnabled === undefined) {
      out.fillEnabled = base.fillEnabled;
    }
    if (out.outlineColor === undefined) {
      out.outlineColor = base.outlineColor;
    }
    if (out.outlineWidth === undefined) {
      out.outlineWidth = base.outlineWidth;
    }
    if (out.labelField === undefined) {
      out.labelField = base.labelField;
    }
    if (out.labelColor === undefined) {
      out.labelColor = base.labelColor;
    }
    if (out.labelSize === undefined) {
      out.labelSize = base.labelSize;
    }
    if (out.labelOutline === undefined) {
      out.labelOutline = base.labelOutline;
    }
    if (out.labelOutlineColor === undefined) {
      out.labelOutlineColor = base.labelOutlineColor;
    }
    if (out.iconKey === undefined) {
      out.iconKey = base.iconKey;
    }
    return out;
  }

  static copy(src: StyleOverride): StyleOverride {
    const out: StyleOverride = new StyleOverride();
    out.fillColor = src.fillColor;
    out.fillOpacity = src.fillOpacity;
    out.fillEnabled = src.fillEnabled;
    out.outlineColor = src.outlineColor;
    out.outlineWidth = src.outlineWidth;
    out.labelField = src.labelField;
    out.labelColor = src.labelColor;
    out.labelSize = src.labelSize;
    out.labelOutline = src.labelOutline;
    out.labelOutlineColor = src.labelOutlineColor;
    out.iconKey = src.iconKey;
    src.featureStyles.forEach((value: StyleOverride, key: number) => {
      out.featureStyles.set(key, StyleOverride.copy(value));
    });
    return out;
  }

  toJson(): StyleOverrideJson {
    const o: StyleOverrideJson = {};
    if (this.fillColor !== undefined) {
      o.fillColor = this.fillColor;
    }
    if (this.fillOpacity !== undefined) {
      o.fillOpacity = this.fillOpacity;
    }
    if (this.fillEnabled !== undefined) {
      o.fillEnabled = this.fillEnabled;
    }
    if (this.outlineColor !== undefined) {
      o.outlineColor = this.outlineColor;
    }
    if (this.outlineWidth !== undefined) {
      o.outlineWidth = this.outlineWidth;
    }
    if (this.labelField !== undefined) {
      o.labelField = this.labelField;
    }
    if (this.labelColor !== undefined) {
      o.labelColor = this.labelColor;
    }
    if (this.labelSize !== undefined) {
      o.labelSize = this.labelSize;
    }
    if (this.labelOutline !== undefined) {
      o.labelOutline = this.labelOutline;
    }
    if (this.labelOutlineColor !== undefined) {
      o.labelOutlineColor = this.labelOutlineColor;
    }
    if (this.iconKey !== undefined) {
      o.iconKey = this.iconKey;
    }
    if (this.featureStyles.size > 0) {
      const fs: Record<string, StyleOverrideJson> = {};
      this.featureStyles.forEach((value: StyleOverride, key: number) => {
        const so: StyleOverrideJson = value.toJson();
        if (StyleOverride.hasContent(so)) {
          fs[`${key}`] = so;
        }
      });
      if (Object.keys(fs).length > 0) {
        o.featureStyles = fs;
      }
    }
    return o;
  }

  static fromJson(o: StyleOverrideJson | undefined): StyleOverride {
    const s: StyleOverride = new StyleOverride();
    if (o === undefined || o === null) {
      return s;
    }
    s.fillColor = o.fillColor;
    s.fillOpacity = o.fillOpacity;
    s.fillEnabled = o.fillEnabled;
    s.outlineColor = o.outlineColor;
    s.outlineWidth = o.outlineWidth;
    s.labelField = o.labelField;
    s.labelColor = o.labelColor;
    s.labelSize = o.labelSize;
    s.labelOutline = o.labelOutline;
    s.labelOutlineColor = o.labelOutlineColor;
    s.iconKey = o.iconKey;
    const fs: Record<string, StyleOverrideJson> | undefined = o.featureStyles;
    if (fs !== undefined && fs !== null) {
      const keys: string[] = Object.keys(fs);
      for (let i = 0; i < keys.length; i++) {
        const fid: number = Number.parseInt(keys[i], 10);
        if (!Number.isNaN(fid)) {
          s.featureStyles.set(fid, StyleOverride.fromJson(fs[keys[i]]));
        }
      }
    }
    return s;
  }

  /** 序列化结果是否仍有实际内容（全空的对象不写盘，避免文档里出现无意义的空样式） */
  private static hasContent(j: StyleOverrideJson | undefined): boolean {
    return j !== undefined && j !== null && (j.fillColor !== undefined || j.fillOpacity !== undefined
      || j.fillEnabled !== undefined || j.outlineColor !== undefined || j.outlineWidth !== undefined
      || j.labelField !== undefined || j.labelColor !== undefined || j.labelSize !== undefined
      || j.labelOutline !== undefined || j.labelOutlineColor !== undefined || j.iconKey !== undefined
      || j.featureStyles !== undefined);
  }
}

/** 图层清单条目：矢量与栅格共用（type 区分） */
export class LayerInfo {
  static readonly TYPE_VECTOR: string = 'vector';
  static readonly TYPE_RASTER: string = 'raster';
  /** 首次加载写入的默认最小显示级别 */
  static readonly DEFAULT_MIN_DISPLAY_LEVEL: number = 5;
  /** 未初始化 / 未指定的哨兵值 */
  static readonly UNSET_LEVEL: number = -1;

  name: string | undefined = undefined;
  path: string | undefined = undefined;
  visible: boolean = true;
  type: string | undefined = undefined;
  vectorStyle: StyleOverride | undefined = undefined;
  /** 样式版本号：样式修改时递增，驱动已加载图层重载生效（图层同步缓存键之一） */
  styleVersion: number = 0;
  /** 级别可见性——自动值（-1 表示未初始化） */
  autoMinDisplayLevel: number = LayerInfo.UNSET_LEVEL;
  /** 级别可见性——用户值（-1 表示未指定，此时生效自动值） */
  userMinDisplayLevel: number = LayerInfo.UNSET_LEVEL;

  constructor(name: string | undefined = undefined, path: string | undefined = undefined,
    type: string | undefined = undefined, visible: boolean = true) {
    this.name = name;
    this.path = path;
    this.type = type;
    this.visible = visible;
  }

  /** 级别可见性生效值：用户指定（≥0）优先，否则自动值；两者皆 <0 表示不限制 */
  effectiveMinDisplayLevel(): number {
    return this.userMinDisplayLevel >= 0 ? this.userMinDisplayLevel : this.autoMinDisplayLevel;
  }

  isVector(): boolean {
    return this.type === LayerInfo.TYPE_VECTOR;
  }

  isRaster(): boolean {
    return this.type === LayerInfo.TYPE_RASTER;
  }

  /** 显示名：无 name 时回退文件名（与 Android 侧一致，保证列表不出现空条目） */
  displayName(): string {
    if (this.name !== undefined && this.name.length > 0) {
      return this.name;
    }
    const path: string = this.path ?? '';
    const slash: number = Math.max(path.lastIndexOf('/'), path.lastIndexOf('\\'));
    const name: string = slash >= 0 ? path.substring(slash + 1) : path;
    const dot: number = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  toJson(): LayerInfoJson {
    const o: LayerInfoJson = {
      name: this.name,
      path: this.path,
      visible: this.visible,
      type: this.type,
    };
    if (this.styleVersion !== 0) {
      o.styleVersion = this.styleVersion;
    }
    if (this.autoMinDisplayLevel !== LayerInfo.UNSET_LEVEL) {
      o.autoMinDisplayLevel = this.autoMinDisplayLevel;
    }
    if (this.userMinDisplayLevel !== LayerInfo.UNSET_LEVEL) {
      o.userMinDisplayLevel = this.userMinDisplayLevel;
    }
    const style: StyleOverride | undefined = this.vectorStyle;
    if (style !== undefined && !style.isEmpty()) {
      o.vectorStyle = style.toJson();
    }
    return o;
  }

  static fromJson(o: LayerInfoJson): LayerInfo {
    const l: LayerInfo = new LayerInfo(o.name, o.path, o.type, o.visible ?? true);
    l.styleVersion = o.styleVersion ?? 0;
    l.autoMinDisplayLevel = o.autoMinDisplayLevel ?? LayerInfo.UNSET_LEVEL;
    l.userMinDisplayLevel = o.userMinDisplayLevel ?? LayerInfo.UNSET_LEVEL;
    if (o.vectorStyle !== undefined) {
      l.vectorStyle = StyleOverride.fromJson(o.vectorStyle);
    }
    return l;
  }
}

/** 底图数据源（在线瓦片） */
export class MapSource {
  static readonly DEFAULT_MAX_LEVEL: number = 18;
  static readonly TOKEN1_PLACEHOLDER: string = '$tiandituToken';
  static readonly TOKEN2_PLACEHOLDER: string = '$tiandituToken2';
  static readonly TIANDITU_NAME_PREFIX: string = '天地图-';

  name: string | undefined = undefined;
  url: string | undefined = undefined;
  visible: boolean = true;
  token1: string | undefined = undefined;
  token2: string | undefined = undefined;
  imageFormat: string | undefined = undefined;
  /** 图源数据最大级别：超出后末级瓦片纹理拉伸 */
  maxLevel: number = MapSource.DEFAULT_MAX_LEVEL;
  /** 系统自带地图源（名称不可修改） */
  isSystem: boolean = false;
  /** 注记图层：不在地图源列表显示，由主界面按钮控制，渲染压在所有图源之上 */
  isAnnotation: boolean = false;

  constructor(name: string | undefined = undefined, url: string | undefined = undefined,
    visible: boolean = true) {
    this.name = name;
    this.url = url;
    this.visible = visible;
  }

  isTiandituSource(): boolean {
    return (this.name ?? '').startsWith(MapSource.TIANDITU_NAME_PREFIX);
  }

  /** URL 占位符替换为实际 Token（无 Token 时替换为空串，与 Android resolveUrl 同口径） */
  resolveUrl(): string {
    let url: string = this.url ?? '';
    url = url.split(MapSource.TOKEN1_PLACEHOLDER).join(this.token1 ?? '');
    url = url.split(MapSource.TOKEN2_PLACEHOLDER).join(this.token2 ?? '');
    return url;
  }

  /** 图层同步缓存键：任一字段变化即触发底图重建 */
  sourceKey(): string {
    return `${this.name}|${this.url}|${this.imageFormat}|${this.token1}|${this.token2}|${this.maxLevel}`;
  }

  toJson(): MapSourceJson {
    const o: MapSourceJson = {
      name: this.name,
      url: this.url,
      visible: this.visible,
      token1: this.token1,
      token2: this.token2,
      imageFormat: this.imageFormat,
      maxLevel: this.maxLevel,
      system: this.isSystem,
      annotation: this.isAnnotation,
    };
    return o;
  }

  static fromJson(o: MapSourceJson): MapSource {
    const m: MapSource = new MapSource(o.name, o.url, o.visible ?? true);
    m.token1 = o.token1;
    m.token2 = o.token2;
    m.imageFormat = o.imageFormat;
    m.maxLevel = o.maxLevel ?? MapSource.DEFAULT_MAX_LEVEL;
    m.isSystem = o.system ?? false;
    m.isAnnotation = o.annotation ?? false;
    return m;
  }
}

/** 系统配置（设置页开关集合） */
export class SystemConfig {
  showCenterCross: boolean = true;
  photoAddWatermark: boolean = true;
  backgroundLocation: boolean = false;
  showMediaLayer: boolean = true;
  showPhotoName: boolean = false;
  showTrackLayer: boolean = true;
  showMeasureLayer: boolean = true;
  /** false = 十进制度；true = 米（CGCS2000 3 度带，带号按经度自动选取） */
  coordDisplayMeter: boolean = false;
  /** KML/KMZ 名称标注显示开关（默认关，地图更清爽） */
  showKmlLabel: boolean = false;
  /**
   * 3D 视图（球模式）：false = 2D 墨卡托（默认），true = 3D。
   * 原由主界面左上按键切换并随相机独立持久化；0.3.0.1 起改由设置页控制、随系统配置持久化，
   * 主界面回页读回此值即时生效。
   */
  viewMode3d: boolean = false;

  toJson(): SystemConfigJson {
    const o: SystemConfigJson = {
      showCenterCross: this.showCenterCross,
      photoAddWatermark: this.photoAddWatermark,
      backgroundLocation: this.backgroundLocation,
      showMediaLayer: this.showMediaLayer,
      showPhotoName: this.showPhotoName,
      showTrackLayer: this.showTrackLayer,
      showMeasureLayer: this.showMeasureLayer,
      coordDisplayMeter: this.coordDisplayMeter,
      showKmlLabel: this.showKmlLabel,
      viewMode3d: this.viewMode3d,
    };
    return o;
  }

  static fromJson(o: SystemConfigJson | undefined): SystemConfig {
    const c: SystemConfig = new SystemConfig();
    if (o === undefined || o === null) {
      return c;
    }
    c.showCenterCross = o.showCenterCross ?? true;
    c.photoAddWatermark = o.photoAddWatermark ?? true;
    c.backgroundLocation = o.backgroundLocation ?? false;
    c.showMediaLayer = o.showMediaLayer ?? true;
    c.showPhotoName = o.showPhotoName ?? false;
    c.showTrackLayer = o.showTrackLayer ?? true;
    c.showMeasureLayer = o.showMeasureLayer ?? true;
    c.coordDisplayMeter = o.coordDisplayMeter ?? false;
    c.showKmlLabel = o.showKmlLabel ?? false;
    c.viewMode3d = o.viewMode3d ?? false;
    return c;
  }
}

/** 地图文档：document.json 的完整内存表示 */
export class MapDocument {
  static readonly CURRENT_VERSION: number = 1;

  version: number = MapDocument.CURRENT_VERSION;
  vectorLayers: LayerInfo[] = [];
  rasterLayers: LayerInfo[] = [];
  mapSources: MapSource[] = [];
  systemConfig: SystemConfig = new SystemConfig();

  /** 相机完整姿态；NaN 表示未记录，序列化时跳过 */
  camLatitude: number = Number.NaN;
  camLongitude: number = Number.NaN;
  camAltitude: number = Number.NaN;
  camHeading: number = Number.NaN;
  camTilt: number = Number.NaN;
  camRoll: number = Number.NaN;
  camAltitudeMode: number = -1;

  /** 非注记的普通底图源（地图源管理列表用） */
  baseSources(): MapSource[] {
    return this.mapSources.filter((s: MapSource) => !s.isAnnotation);
  }

  annotationSource(): MapSource | undefined {
    return this.mapSources.find((s: MapSource) => s.isAnnotation);
  }

  findSource(name: string): MapSource | undefined {
    return this.mapSources.find((s: MapSource) => s.name === name);
  }

  findVectorLayer(path: string): LayerInfo | undefined {
    return this.vectorLayers.find((l: LayerInfo) => l.path === path);
  }

  toJson(): MapDocumentJson {
    const o: MapDocumentJson = {
      version: this.version,
      systemConfig: this.systemConfig.toJson(),
      mapSources: this.mapSources.map((s: MapSource) => s.toJson()),
      rasterLayers: this.rasterLayers.map((l: LayerInfo) => l.toJson()),
      vectorLayers: this.vectorLayers.map((l: LayerInfo) => l.toJson()),
    };
    if (!Number.isNaN(this.camLatitude)) {
      o.camLatitude = this.camLatitude;
    }
    if (!Number.isNaN(this.camLongitude)) {
      o.camLongitude = this.camLongitude;
    }
    if (!Number.isNaN(this.camAltitude)) {
      o.camAltitude = this.camAltitude;
    }
    if (!Number.isNaN(this.camHeading)) {
      o.camHeading = this.camHeading;
    }
    if (!Number.isNaN(this.camTilt)) {
      o.camTilt = this.camTilt;
    }
    if (!Number.isNaN(this.camRoll)) {
      o.camRoll = this.camRoll;
    }
    if (this.camAltitudeMode >= 0) {
      o.camAltitudeMode = this.camAltitudeMode;
    }
    return o;
  }

  /**
   * 反序列化。刻意保持宽松：单个条目结构损坏时跳过该条目而非整体重建——
   * 鸿蒙侧 JSON.parse 无类型保障，外业现场「图层莫名少一个」比「配置全丢」更可接受。
   */
  static fromJson(o: MapDocumentJson): MapDocument {
    const doc: MapDocument = new MapDocument();
    doc.version = o.version ?? MapDocument.CURRENT_VERSION;
    doc.systemConfig = SystemConfig.fromJson(o.systemConfig);
    const sources: MapSourceJson[] = o.mapSources ?? [];
    for (let i = 0; i < sources.length; i++) {
      doc.mapSources.push(MapSource.fromJson(sources[i]));
    }
    const rasters: LayerInfoJson[] = o.rasterLayers ?? [];
    for (let i = 0; i < rasters.length; i++) {
      doc.rasterLayers.push(LayerInfo.fromJson(rasters[i]));
    }
    const vectors: LayerInfoJson[] = o.vectorLayers ?? [];
    for (let i = 0; i < vectors.length; i++) {
      doc.vectorLayers.push(LayerInfo.fromJson(vectors[i]));
    }
    doc.camLatitude = o.camLatitude ?? Number.NaN;
    doc.camLongitude = o.camLongitude ?? Number.NaN;
    doc.camAltitude = o.camAltitude ?? Number.NaN;
    doc.camHeading = o.camHeading ?? Number.NaN;
    doc.camTilt = o.camTilt ?? Number.NaN;
    doc.camRoll = o.camRoll ?? Number.NaN;
    doc.camAltitudeMode = o.camAltitudeMode ?? -1;
    return doc;
  }
}
