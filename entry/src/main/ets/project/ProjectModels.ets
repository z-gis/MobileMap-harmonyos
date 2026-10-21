// ProjectModels.ets —— 工程数据模型（对应 Android project/Project.kt，0.4.0.0 单库版）。
//
// 工程 = 采集数据唯一本体（轨迹、测量、拍照、样地调查），存储为 GeoPackage (.gpkg)。
// 与文档（Document）分离：文档管配置/图层，工程管采集数据。
//
// 坐标序约定：内存与 UI 层统一 [lat, lon, alt]（与旧工作库一致）；
// 仅 toJson/fromJson 在与 native gpkg 读写边界换算为 [lon, lat, alt]（GeoPackage 轴序）。
//
// 序列化 JSON 键名与 Android Project.kt / native geopackage_io.cpp 严格对齐，改动须两侧同步。
// 照片记录不含 photoData：BLOB 不入 JSON，只经 GpkgDml.readPhotoBlob 单独取。

// ── JSON 解析辅助（Android org.json opt* 语义：缺键/NULL/类型不符一律回默认值）──

type JsonObject = Record<string, Object | null>;

function jObj(v: Object | undefined | null): JsonObject | null {
  if (v === null || v === undefined || typeof v !== 'object') {
    return null;
  }
  return v as JsonObject;
}

function jArr(v: Object | undefined | null): Object[] | null {
  if (v === null || v === undefined || !Array.isArray(v)) {
    return null;
  }
  return v as Object[];
}

/** 取字符串：缺键/NULL 回 def（等价 optString(key, def)） */
function jStr(o: JsonObject, key: string, def: string = ''): string {
  const v: Object | undefined | null = o[key];
  return typeof v === 'string' ? v : def;
}

/** 取可空字符串：缺键/NULL 回 null（等价 optString(key, null)，模型侧以 '' 表示 null） */
function jStrOrEmpty(o: JsonObject, key: string): string {
  return jStr(o, key, '');
}

function jNum(o: JsonObject, key: string, def: number = 0): number {
  const v: Object | undefined | null = o[key];
  return typeof v === 'number' ? v : def;
}

function jBool(o: JsonObject, key: string, def: boolean = false): boolean {
  const v: Object | undefined | null = o[key];
  return typeof v === 'boolean' ? v : def;
}

/** 空串 → null（对齐 Android JSONObject.NULL 写法，native 侧空串同样视为未设置） */
function nullIfEmpty(s: string): string | null {
  return s.length === 0 ? null : s;
}

/** 内存点串 [lat,lon,alt] → JSON 数组 [[lon,lat,alt],...]（native 轴序） */
function pointsToJson(points: number[][]): number[][] {
  const pts: number[][] = [];
  for (let i = 0; i < points.length; i++) {
    const p: number[] = points[i];
    pts.push([p[1], p[0], p.length > 2 ? p[2] : 0]);
  }
  return pts;
}

/** JSON 数组 [[lon,lat,alt],...]（native 轴序）→ 内存点串 [lat,lon,alt] */
function pointsFromJson(v: Object | undefined | null): number[][] {
  const points: number[][] = [];
  const arr: Object[] | null = jArr(v);
  if (arr === null) {
    return points;
  }
  for (let i = 0; i < arr.length; i++) {
    const pt: Object[] | null = jArr(arr[i]);
    if (pt === null || pt.length < 2) {
      continue;
    }
    const lon: number = typeof pt[0] === 'number' ? pt[0] as number : 0;
    const lat: number = typeof pt[1] === 'number' ? pt[1] as number : 0;
    const alt: number = pt.length > 2 && typeof pt[2] === 'number' ? pt[2] as number : 0;
    points.push([lat, lon, alt]);
  }
  return points;
}

/** 轨迹记录（线几何 + 属性）；points 内存序 [lat,lon,alt] */
export class TrackRecord {
  static readonly DEFAULT_COLOR_HEX: string = '#33CCFF';
  static readonly DEFAULT_LINE_WIDTH: number = 3;

  id: number = 0;
  name: string = '';
  /** "yyyy-MM-dd HH:mm:ss" */
  date: string = '';
  points: number[][] = [];
  /** "#RRGGBB" 或空（空 = 未设置） */
  color: string = '';
  /** 隐藏后地图不渲染 */
  hidden: boolean = false;
  lineWidth: number = TrackRecord.DEFAULT_LINE_WIDTH;

  /** 逐条可见性（与旧工作库 visible 语义对齐，hidden 取反） */
  get visible(): boolean {
    return !this.hidden;
  }

  set visible(value: boolean) {
    this.hidden = !value;
  }

  toJsonObject(): JsonObject {
    const o: JsonObject = {
      'id': this.id,
      'name': this.name,
      'date': this.date,
      'color': nullIfEmpty(this.color),
      'hidden': this.hidden,
      'lineWidth': this.lineWidth,
      'points': pointsToJson(this.points),
    };
    return o;
  }

  toJson(): string {
    return JSON.stringify(this.toJsonObject());
  }

  static fromJson(o: JsonObject): TrackRecord {
    const t: TrackRecord = new TrackRecord();
    t.id = jNum(o, 'id');
    t.name = jStr(o, 'name');
    t.date = jStr(o, 'date');
    t.color = jStrOrEmpty(o, 'color');
    t.hidden = jBool(o, 'hidden', false);
    t.lineWidth = jNum(o, 'lineWidth', TrackRecord.DEFAULT_LINE_WIDTH);
    t.points = pointsFromJson(o['points']);
    return t;
  }
}

/** 测量记录（点/距离/面积 + 属性）；points 内存序 [lat,lon,alt] */
export class MeasureRecord {
  static readonly TYPE_POINT: string = 'point';
  static readonly TYPE_DISTANCE: string = 'distance';
  static readonly TYPE_AREA: string = 'area';
  static readonly DEFAULT_LINE_WIDTH: number = 3;

  id: number = 0;
  name: string = '';
  date: string = '';
  /** TYPE_POINT / TYPE_DISTANCE / TYPE_AREA */
  type: string = '';
  /** 测量结果文本（导出附属信息，几何为准） */
  result: string = '';
  points: number[][] = [];
  color: string = '';
  hidden: boolean = false;
  /** 面是否闭合 */
  closed: boolean = false;
  lineWidth: number = MeasureRecord.DEFAULT_LINE_WIDTH;

  toJsonObject(): JsonObject {
    const o: JsonObject = {
      'id': this.id,
      'name': this.name,
      'date': this.date,
      'type': this.type,
      'result': this.result,
      'color': nullIfEmpty(this.color),
      'hidden': this.hidden,
      'closed': this.closed,
      'lineWidth': this.lineWidth,
      'points': pointsToJson(this.points),
    };
    return o;
  }

  toJson(): string {
    return JSON.stringify(this.toJsonObject());
  }

  static fromJson(o: JsonObject): MeasureRecord {
    const m: MeasureRecord = new MeasureRecord();
    m.id = jNum(o, 'id');
    m.name = jStr(o, 'name');
    m.date = jStr(o, 'date');
    m.type = jStr(o, 'type');
    m.result = jStr(o, 'result');
    m.color = jStrOrEmpty(o, 'color');
    m.hidden = jBool(o, 'hidden', false);
    m.closed = jBool(o, 'closed', false);
    m.lineWidth = jNum(o, 'lineWidth', MeasureRecord.DEFAULT_LINE_WIDTH);
    m.points = pointsFromJson(o['points']);
    return m;
  }
}

/** 拍照附件（照片文件） */
export class PhotoAttachment {
  name: string = '';
  path: string = '';
  time: number = 0;

  constructor(name: string = '', path: string = '', time: number = 0) {
    this.name = name;
    this.path = path;
    this.time = time;
  }

  toJsonObject(): JsonObject {
    const o: JsonObject = {
      'name': this.name,
      'path': this.path,
      'time': this.time,
    };
    return o;
  }

  static fromJson(o: JsonObject): PhotoAttachment {
    const a: PhotoAttachment = new PhotoAttachment();
    a.name = jStr(o, 'name', '');
    a.path = jStr(o, 'path', '');
    a.time = jNum(o, 'time', 0);
    return a;
  }
}

/** 拍照标识（点 + 多照片附件，对齐旧 media.db placemark+attachment 结构） */
export class PhotoRecord {
  /** 未分组标识（groupId 默认值） */
  static readonly UNGROUPED_ID: number = -1;

  id: number = 0;
  name: string = '';
  lon: number = 0;
  lat: number = 0;
  alt: number = 0;
  timestamp: number = 0;
  /** 隐藏后地图不渲染 */
  visible: boolean = true;
  /** 所属分组，UNGROUPED_ID 未分组 */
  groupId: number = PhotoRecord.UNGROUPED_ID;
  attachments: PhotoAttachment[] = [];

  /** 主照片路径（首个附件），无附件返回 '' */
  get photoPath(): string {
    return this.attachments.length > 0 ? this.attachments[0].path : '';
  }

  toJsonObject(): JsonObject {
    const arr: JsonObject[] = [];
    for (let i = 0; i < this.attachments.length; i++) {
      arr.push(this.attachments[i].toJsonObject());
    }
    const o: JsonObject = {
      'id': this.id,
      'name': this.name,
      'lon': this.lon,
      'lat': this.lat,
      'alt': this.alt,
      'timestamp': this.timestamp,
      'visible': this.visible,
      'groupId': this.groupId,
      'attachments': arr,
    };
    return o;
  }

  toJson(): string {
    return JSON.stringify(this.toJsonObject());
  }

  static fromJson(o: JsonObject): PhotoRecord {
    const p: PhotoRecord = new PhotoRecord();
    p.id = jNum(o, 'id');
    p.name = jStr(o, 'name');
    p.lon = jNum(o, 'lon');
    p.lat = jNum(o, 'lat');
    p.alt = jNum(o, 'alt', 0);
    p.timestamp = jNum(o, 'timestamp');
    p.visible = jBool(o, 'visible', true);
    p.groupId = jNum(o, 'groupId', PhotoRecord.UNGROUPED_ID);
    const arr: Object[] | null = jArr(o['attachments']);
    if (arr !== null) {
      for (let i = 0; i < arr.length; i++) {
        const item: JsonObject | null = jObj(arr[i]);
        if (item !== null) {
          p.attachments.push(PhotoAttachment.fromJson(item));
        }
      }
    }
    // 旧版 gpkg 兼容：无 attachments 但有 photoPath 时回退单附件
    if (p.attachments.length === 0) {
      const legacy: string = jStr(o, 'photoPath', '');
      if (legacy.length > 0) {
        const slash: number = Math.max(legacy.lastIndexOf('/'), legacy.lastIndexOf('\\'));
        const fname: string = slash >= 0 ? legacy.substring(slash + 1) : legacy;
        p.attachments.push(new PhotoAttachment(fname, legacy, p.timestamp));
      }
    }
    return p;
  }
}

/** 拍照分组（对齐旧 media_group 表）；组可见性通过批量写点位 visible 生效 */
export class MediaGroupRecord {
  id: number = 0;
  name: string = '';
  createdTime: number = 0;
  visible: boolean = true;

  toJsonObject(): JsonObject {
    const o: JsonObject = {
      'id': this.id,
      'name': this.name,
      'createdTime': this.createdTime,
      'visible': this.visible,
    };
    return o;
  }

  toJson(): string {
    return JSON.stringify(this.toJsonObject());
  }

  static fromJson(o: JsonObject): MediaGroupRecord {
    const g: MediaGroupRecord = new MediaGroupRecord();
    g.id = jNum(o, 'id');
    g.name = jStr(o, 'name');
    g.createdTime = jNum(o, 'createdTime');
    g.visible = jBool(o, 'visible', true);
    return g;
  }
}

/** 样地调查明细行（序列化进 SurveyPlot attributes JSON） */
export class SurveyRow {
  id: number = 0;
  sortNo: number = 0;
  treeSpecies: string = '';
  dbh: string = '';
  category: string = '';
  thinningMethod: string = '';
  remark: string = '';

  toJsonObject(): JsonObject {
    const o: JsonObject = {
      'sortNo': this.sortNo,
      'treeSpecies': nullIfEmpty(this.treeSpecies),
      'dbh': nullIfEmpty(this.dbh),
      'category': nullIfEmpty(this.category),
      'thinningMethod': nullIfEmpty(this.thinningMethod),
      'remark': nullIfEmpty(this.remark),
    };
    // 行 id 落盘保留（仅有效 id 写入，避免噪声）
    if (this.id > 0) {
      o['id'] = this.id;
    }
    return o;
  }

  static fromJson(o: JsonObject): SurveyRow {
    const r: SurveyRow = new SurveyRow();
    r.id = jNum(o, 'id', 0);
    r.sortNo = jNum(o, 'sortNo');
    r.treeSpecies = jStrOrEmpty(o, 'treeSpecies');
    r.dbh = jStrOrEmpty(o, 'dbh');
    r.category = jStrOrEmpty(o, 'category');
    r.thinningMethod = jStrOrEmpty(o, 'thinningMethod');
    r.remark = jStrOrEmpty(o, 'remark');
    return r;
  }
}

/**
 * 样地调查（中心点 + 富表单）：表单字段与明细行/照片在内存为强类型字段，
 * 序列化时整体打包进 attributes JSON 列（gpkg schema 不变）。
 * points 内存序 [lat,lon,alt]，首点即样地中心。
 */
export class SurveyPlot {
  id: number = 0;
  name: string = '';
  plotType: string = 'point';
  points: number[][] = [];

  // ── 表单字段（对齐旧 sample_survey.db survey_plots 表）──
  sourcePath: string = '';
  sourceFid: number = 0;
  compartmentNo: string = '';
  plotNo: number = 1;
  averageTreeHeight: string = '';
  canopyDensity: number = Number.NaN;
  cornerCoordinates: string = '';
  createdAt: number = 0;
  updatedAt: number = 0;
  rows: SurveyRow[] = [];
  photoPaths: string[] = [];

  get centerLatitude(): number {
    return this.points.length > 0 ? this.points[0][0] : Number.NaN;
  }

  get centerLongitude(): number {
    return this.points.length > 0 ? this.points[0][1] : Number.NaN;
  }

  setCenter(lat: number, lon: number): void {
    if (this.points.length === 0) {
      this.points.push([lat, lon, 0]);
    } else {
      this.points[0] = [lat, lon, 0];
    }
  }

  attributesToJsonObject(): JsonObject {
    const rowsArr: JsonObject[] = [];
    for (let i = 0; i < this.rows.length; i++) {
      rowsArr.push(this.rows[i].toJsonObject());
    }
    const photosArr: string[] = [];
    for (let i = 0; i < this.photoPaths.length; i++) {
      photosArr.push(this.photoPaths[i]);
    }
    const a: JsonObject = {
      'sourcePath': this.sourcePath,
      'sourceFid': this.sourceFid,
      'compartmentNo': nullIfEmpty(this.compartmentNo),
      'plotNo': this.plotNo,
      'averageTreeHeight': nullIfEmpty(this.averageTreeHeight),
      'canopyDensity': Number.isNaN(this.canopyDensity) ? null : this.canopyDensity,
      'cornerCoordinates': nullIfEmpty(this.cornerCoordinates),
      'createdAt': this.createdAt,
      'updatedAt': this.updatedAt,
      'rows': rowsArr,
      'photos': photosArr,
    };
    return a;
  }

  toJsonObject(): JsonObject {
    const o: JsonObject = {
      'id': this.id,
      'name': this.name,
      'plotType': this.plotType,
      'points': pointsToJson(this.points),
      'attributes': this.attributesToJsonObject(),
    };
    return o;
  }

  toJson(): string {
    return JSON.stringify(this.toJsonObject());
  }

  static fromJson(o: JsonObject): SurveyPlot {
    const s: SurveyPlot = new SurveyPlot();
    s.id = jNum(o, 'id');
    s.name = jStr(o, 'name');
    s.plotType = jStr(o, 'plotType', 'point');
    s.points = pointsFromJson(o['points']);
    // attributes 兼容两种形态：JSON 对象（native 解析后）或 JSON 字符串（列原文）
    let attr: JsonObject | null = jObj(o['attributes']);
    if (attr === null) {
      const raw: Object | undefined | null = o['attributes'];
      if (typeof raw === 'string' && raw.startsWith('{')) {
        try {
          attr = JSON.parse(raw) as JsonObject;
        } catch (e) {
          attr = null;
        }
      }
    }
    if (attr !== null) {
      s.sourcePath = jStr(attr, 'sourcePath', '');
      s.sourceFid = jNum(attr, 'sourceFid', 0);
      s.compartmentNo = jStrOrEmpty(attr, 'compartmentNo');
      s.plotNo = jNum(attr, 'plotNo', 1);
      s.averageTreeHeight = jStrOrEmpty(attr, 'averageTreeHeight');
      const cd: Object | undefined | null = attr['canopyDensity'];
      s.canopyDensity = typeof cd === 'number' ? cd : Number.NaN;
      s.cornerCoordinates = jStrOrEmpty(attr, 'cornerCoordinates');
      s.createdAt = jNum(attr, 'createdAt', 0);
      s.updatedAt = jNum(attr, 'updatedAt', 0);
      const rowsArr: Object[] | null = jArr(attr['rows']);
      if (rowsArr !== null) {
        for (let i = 0; i < rowsArr.length; i++) {
          const item: JsonObject | null = jObj(rowsArr[i]);
          if (item !== null) {
            s.rows.push(SurveyRow.fromJson(item));
          }
        }
      }
      const photosArr: Object[] | null = jArr(attr['photos']);
      if (photosArr !== null) {
        for (let i = 0; i < photosArr.length; i++) {
          const v: Object = photosArr[i];
          if (typeof v === 'string' && v.length > 0) {
            s.photoPaths.push(v);
          }
        }
      }
    }
    return s;
  }
}

/**
 * 工程（采集数据唯一本体）。toJson 轴序为 [lon,lat,alt]，供 native 写 gpkg；
 * 读取侧 fromJson 与 native geopackage_io.cpp 输出结构兼容。
 */
export class Project {
  // ── 元数据 ──
  name: string = '';
  description: string = '';
  createTime: number = Date.now();
  updateTime: number = Date.now();
  /** 空间参考（默认 EPSG:4326） */
  srs: string = 'EPSG:4326';

  // ── 空间数据集合 ──
  tracks: TrackRecord[] = [];
  measures: MeasureRecord[] = [];
  photos: PhotoRecord[] = [];
  mediaGroups: MediaGroupRecord[] = [];
  surveyPlots: SurveyPlot[] = [];

  // ── 图层引用（与 Document 关联）──
  /** 引用的图层绝对路径 */
  layerRefs: string[] = [];

  toJsonObject(): JsonObject {
    const tracksArr: JsonObject[] = [];
    for (let i = 0; i < this.tracks.length; i++) {
      tracksArr.push(this.tracks[i].toJsonObject());
    }
    const measuresArr: JsonObject[] = [];
    for (let i = 0; i < this.measures.length; i++) {
      measuresArr.push(this.measures[i].toJsonObject());
    }
    const photosArr: JsonObject[] = [];
    for (let i = 0; i < this.photos.length; i++) {
      photosArr.push(this.photos[i].toJsonObject());
    }
    const groupsArr: JsonObject[] = [];
    for (let i = 0; i < this.mediaGroups.length; i++) {
      groupsArr.push(this.mediaGroups[i].toJsonObject());
    }
    const plotsArr: JsonObject[] = [];
    for (let i = 0; i < this.surveyPlots.length; i++) {
      plotsArr.push(this.surveyPlots[i].toJsonObject());
    }
    const layersArr: string[] = [];
    for (let i = 0; i < this.layerRefs.length; i++) {
      layersArr.push(this.layerRefs[i]);
    }
    const o: JsonObject = {
      'name': this.name,
      'description': this.description,
      'createTime': this.createTime,
      'updateTime': this.updateTime,
      'srs': this.srs,
      'tracks': tracksArr,
      'measures': measuresArr,
      'photos': photosArr,
      'mediaGroups': groupsArr,
      'surveyPlots': plotsArr,
      'layerRefs': layersArr,
    };
    return o;
  }

  toJson(): string {
    return JSON.stringify(this.toJsonObject());
  }

  static fromJson(o: JsonObject): Project {
    const p: Project = new Project();
    p.name = jStr(o, 'name', '未命名工程');
    p.description = jStr(o, 'description', '');
    p.createTime = jNum(o, 'createTime', Date.now());
    p.updateTime = jNum(o, 'updateTime', Date.now());
    p.srs = jStr(o, 'srs', 'EPSG:4326');

    const tracksArr: Object[] | null = jArr(o['tracks']);
    if (tracksArr !== null) {
      for (let i = 0; i < tracksArr.length; i++) {
        const item: JsonObject | null = jObj(tracksArr[i]);
        if (item !== null) {
          p.tracks.push(TrackRecord.fromJson(item));
        }
      }
    }
    const measuresArr: Object[] | null = jArr(o['measures']);
    if (measuresArr !== null) {
      for (let i = 0; i < measuresArr.length; i++) {
        const item: JsonObject | null = jObj(measuresArr[i]);
        if (item !== null) {
          p.measures.push(MeasureRecord.fromJson(item));
        }
      }
    }
    const photosArr: Object[] | null = jArr(o['photos']);
    if (photosArr !== null) {
      for (let i = 0; i < photosArr.length; i++) {
        const item: JsonObject | null = jObj(photosArr[i]);
        if (item !== null) {
          p.photos.push(PhotoRecord.fromJson(item));
        }
      }
    }
    const groupsArr: Object[] | null = jArr(o['mediaGroups']);
    if (groupsArr !== null) {
      for (let i = 0; i < groupsArr.length; i++) {
        const item: JsonObject | null = jObj(groupsArr[i]);
        if (item !== null) {
          p.mediaGroups.push(MediaGroupRecord.fromJson(item));
        }
      }
    }
    const plotsArr: Object[] | null = jArr(o['surveyPlots']);
    if (plotsArr !== null) {
      for (let i = 0; i < plotsArr.length; i++) {
        const item: JsonObject | null = jObj(plotsArr[i]);
        if (item !== null) {
          p.surveyPlots.push(SurveyPlot.fromJson(item));
        }
      }
    }
    const layersArr: Object[] | null = jArr(o['layerRefs']);
    if (layersArr !== null) {
      for (let i = 0; i < layersArr.length; i++) {
        const v: Object = layersArr[i];
        if (typeof v === 'string') {
          p.layerRefs.push(v);
        }
      }
    }
    return p;
  }

  /** 从 native 整读 JSON 串解析工程；解析失败返回 null */
  static parse(json: string): Project | null {
    try {
      return Project.fromJson(JSON.parse(json) as JsonObject);
    } catch (e) {
      return null;
    }
  }
}
