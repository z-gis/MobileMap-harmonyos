// MapDataStore.ets —— 轨迹与测量数据仓库（对应 Android db.MapDataStore）。
//
// 表结构与 Android map.db 完全一致（track / track_point / measurement），点串同样以
// 「[[lat,lon,alt],…]」JSON 存 measurement.points，便于两端库文件互拷核对；
// 旧库非破坏式迁移经 DbKit.ensureColumn 补列（line_width / visible / color / recording）。
// 全部方法 async：鸿蒙 RDB 无同步 API，UI 侧一律 await（见 DbKit 文件头说明）。

import { common } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { DbKit } from './DbKit';

/** 轨迹记录：基本信息 + 坐标点序列 [lat,lon,alt] */
export class TrackRecord {
  /** 新建轨迹默认颜色（历史轨迹蓝 #FF33CCFF） */
  static readonly DEFAULT_COLOR: number = 0xFF33CCFF;
  static readonly DEFAULT_LINE_WIDTH: number = 3;

  id: number;
  name: string;
  createdTime: number;
  points: number[][];
  /** 逐条轨迹可见性：隐藏后地图不渲染（管理界面开关） */
  visible: boolean;
  /** 轨迹线颜色（ARGB 无符号，与 track.color 一致） */
  color: number;
  /** 轨迹线宽（像素，与 track.line_width 一致） */
  lineWidth: number;

  constructor(id: number = 0, name: string = '', createdTime: number = 0, points: number[][] = [],
    visible: boolean = true, color: number = TrackRecord.DEFAULT_COLOR,
    lineWidth: number = TrackRecord.DEFAULT_LINE_WIDTH) {
    this.id = id;
    this.name = name;
    this.createdTime = createdTime;
    this.points = points;
    this.visible = visible;
    this.color = color;
    this.lineWidth = lineWidth;
  }

  /** 轨迹长度（米）：相邻点大圆距离求和 */
  lengthMeters(): number {
    let sum: number = 0;
    for (let i = 1; i < this.points.length; i++) {
      const a: number[] = this.points[i - 1];
      const b: number[] = this.points[i];
      sum += MapDataStore.distanceMeters(a[0], a[1], b[0], b[1]);
    }
    return sum;
  }
}

/** 测量记录：点（位置）/距离/面积，点串以 JSON 存储 */
export class MeasurementRecord {
  static readonly TYPE_POINT: string = 'point';
  static readonly TYPE_DISTANCE: string = 'distance';
  static readonly TYPE_AREA: string = 'area';
  static readonly DEFAULT_LINE_WIDTH: number = 3;

  id: number;
  name: string;
  type: string;
  color: number;
  createdTime: number;
  points: number[][];
  lineWidth: number;

  constructor(id: number = 0, name: string = '', type: string = MeasurementRecord.TYPE_POINT,
    color: number = 0xFF57ACFD, createdTime: number = 0, points: number[][] = [],
    lineWidth: number = MeasurementRecord.DEFAULT_LINE_WIDTH) {
    this.id = id;
    this.name = name;
    this.type = type;
    this.color = color;
    this.createdTime = createdTime;
    this.points = points;
    this.lineWidth = lineWidth;
  }

  /** 类型中文名（列表/详情标题） */
  static typeLabel(type: string): string {
    if (type === MeasurementRecord.TYPE_DISTANCE) {
      return '距离';
    }
    if (type === MeasurementRecord.TYPE_AREA) {
      return '面积';
    }
    return '点';
  }
}

/** 建表语句（与 Android MapDataStore.init 逐字对应） */
const DDL: string[] = [
  'CREATE TABLE IF NOT EXISTS track ('
    + 'id INTEGER PRIMARY KEY AUTOINCREMENT, '
    + 'name TEXT, '
    + 'created_time INTEGER, '
    + 'visible INTEGER DEFAULT 1, '
    + 'color INTEGER DEFAULT -13382401, '
    + 'line_width INTEGER DEFAULT 3, '
    + 'recording INTEGER DEFAULT 0)',
  'CREATE TABLE IF NOT EXISTS track_point ('
    + 'id INTEGER PRIMARY KEY AUTOINCREMENT, '
    + 'track_id INTEGER, '
    + 'seq INTEGER, '
    + 'latitude REAL, '
    + 'longitude REAL, '
    + 'altitude REAL)',
  'CREATE TABLE IF NOT EXISTS measurement ('
    + 'id INTEGER PRIMARY KEY AUTOINCREMENT, '
    + 'name TEXT, '
    + 'type TEXT, '
    + 'color INTEGER, '
    + 'created_time INTEGER, '
    + 'points TEXT)',
];

const DB_NAME: string = 'map.db';

export class MapDataStore {
  private static inst: MapDataStore | null = null;
  private store: relationalStore.RdbStore | null = null;
  private migrating: Promise<void> | null = null;

  /** 取仓库实例（首次调用建库 + 迁移；并发共享同一次迁移过程） */
  static async getInstance(ctx: common.Context): Promise<MapDataStore> {
    if (MapDataStore.inst === null) {
      MapDataStore.inst = new MapDataStore();
    }
    const repo: MapDataStore = MapDataStore.inst;
    await repo.ensure(ctx);
    return repo;
  }

  private async ensure(ctx: common.Context): Promise<void> {
    if (this.store !== null) {
      return;
    }
    if (this.migrating === null) {
      this.migrating = this.openAndMigrate(ctx);
    }
    await this.migrating;
  }

  private async openAndMigrate(ctx: common.Context): Promise<void> {
    const store: relationalStore.RdbStore | null = await DbKit.open(ctx, DB_NAME, DDL);
    if (store === null) {
      this.migrating = null;
      return;
    }
    this.store = store;
    // 旧库平滑迁移：缺列补列，不重建表不丢数据
    await DbKit.ensureColumn(store, 'measurement', 'line_width',
      'ALTER TABLE measurement ADD COLUMN line_width INTEGER DEFAULT 3');
    await DbKit.ensureColumn(store, 'track', 'visible',
      'ALTER TABLE track ADD COLUMN visible INTEGER DEFAULT 1');
    await DbKit.ensureColumn(store, 'track', 'color',
      'ALTER TABLE track ADD COLUMN color INTEGER DEFAULT -13382401');
    await DbKit.ensureColumn(store, 'track', 'line_width',
      'ALTER TABLE track ADD COLUMN line_width INTEGER DEFAULT 3');
    await DbKit.ensureColumn(store, 'track', 'recording',
      'ALTER TABLE track ADD COLUMN recording INTEGER DEFAULT 0');
  }

  /** 库不可用时统一告警（界面按空数据降级，不让异常打断外业） */
  private need(): relationalStore.RdbStore | null {
    return this.store;
  }

  // ── 轨迹 ────────────────────────────────────────────────────────

  /** 保存一条轨迹及其坐标点，返回轨迹主键（失败 -1） */
  async addTrack(name: string, createdTime: number, points: number[][],
    color: number = TrackRecord.DEFAULT_COLOR,
    lineWidth: number = TrackRecord.DEFAULT_LINE_WIDTH): Promise<number> {
    const store: relationalStore.RdbStore | null = this.need();
    if (store === null) {
      return -1;
    }
    const trackId: number = await DbKit.insert(store, 'track', {
      'name': name, 'created_time': createdTime, 'visible': 1, 'recording': 0,
      'color': color, 'line_width': lineWidth,
    });
    if (trackId < 0) {
      return -1;
    }
    for (let i = 0; i < points.length; i++) {
      const p: number[] = points[i];
      await DbKit.insert(store, 'track_point', {
        'track_id': trackId, 'seq': i,
        'latitude': p[0], 'longitude': p[1], 'altitude': p.length > 2 ? p[2] : 0,
      });
    }
    return trackId;
  }

  /** 加载全部已结束的历史轨迹（含坐标点），按创建时间降序；记录中的草稿轨迹不作为历史返回 */
  async loadTracks(): Promise<TrackRecord[]> {
    const store: relationalStore.RdbStore | null = this.need();
    if (store === null) {
      return [];
    }
    const tracks: TrackRecord[] = await DbKit.query<TrackRecord>(store,
      'SELECT id, name, created_time, visible, color, line_width FROM track '
        + 'WHERE recording = 0 ORDER BY created_time DESC', [],
      (rs: relationalStore.ResultSet): TrackRecord => {
        const record: TrackRecord = new TrackRecord(DbKit.int(rs, 'id'), DbKit.str(rs, 'name'),
          DbKit.num(rs, 'created_time'), [], DbKit.int(rs, 'visible') !== 0,
          DbKit.color(rs, 'color', TrackRecord.DEFAULT_COLOR),
          DbKit.int(rs, 'line_width') > 0 ? DbKit.int(rs, 'line_width') : TrackRecord.DEFAULT_LINE_WIDTH);
        return record;
      });
    if (tracks.length === 0) {
      return [];
    }
    // 点串单独一次全表扫描按 track_id 归位（与 Android 同策略：避免 N 次按轨道查询）
    const points: Map<number, number[][]> = new Map<number, number[][]>();
    const rows: number[][] = await DbKit.query<number[]>(store,
      'SELECT track_id, latitude, longitude, altitude FROM track_point ORDER BY seq ASC', [],
      (rs: relationalStore.ResultSet): number[] => {
        return [DbKit.num(rs, 'track_id'), DbKit.num(rs, 'latitude'),
          DbKit.num(rs, 'longitude'), DbKit.num(rs, 'altitude')];
      });
    for (let i = 0; i < rows.length; i++) {
      const row: number[] = rows[i];
      const key: number = row[0];
      const bucket: number[][] | undefined = points.get(key);
      const point: number[] = [row[1], row[2], row[3]];
      if (bucket === undefined) {
        points.set(key, [point]);
      } else {
        bucket.push(point);
      }
    }
    const out: TrackRecord[] = [];
    for (let i = 0; i < tracks.length; i++) {
      const t: TrackRecord = tracks[i];
      const got: number[][] | undefined = points.get(t.id);
      t.points = got === undefined ? [] : got;
      if (t.points.length >= 2) {
        out.push(t);
      }
    }
    return out;
  }

  /** 按主键读单条轨迹（含点）；不存在返回 undefined */
  async findTrack(trackId: number): Promise<TrackRecord | undefined> {
    const store: relationalStore.RdbStore | null = this.need();
    if (store === null) {
      return undefined;
    }
    const list: TrackRecord[] = await DbKit.query<TrackRecord>(store,
      'SELECT id, name, created_time, visible, color, line_width FROM track WHERE id = ?', [trackId],
      (rs: relationalStore.ResultSet): TrackRecord => {
        return new TrackRecord(DbKit.int(rs, 'id'), DbKit.str(rs, 'name'), DbKit.num(rs, 'created_time'),
          [], DbKit.int(rs, 'visible') !== 0, DbKit.color(rs, 'color', TrackRecord.DEFAULT_COLOR),
          DbKit.int(rs, 'line_width') > 0 ? DbKit.int(rs, 'line_width') : TrackRecord.DEFAULT_LINE_WIDTH);
      });
    if (list.length === 0) {
      return undefined;
    }
    const record: TrackRecord = list[0];
    record.points = await DbKit.query<number[]>(store,
      'SELECT latitude, longitude, altitude FROM track_point WHERE track_id = ? ORDER BY seq ASC', [trackId],
      (rs: relationalStore.ResultSet): number[] => {
        return [DbKit.num(rs, 'latitude'), DbKit.num(rs, 'longitude'), DbKit.num(rs, 'altitude')];
      });
    return record;
  }

  /**
   * 新建一条「记录中」的草稿轨迹并返回主键（失败 -1）。
   * 采集开始后即落库、点随采集实时追加：进程被系统回收后可经 loadDraftTrack 恢复未保存轨迹。
   */
  async beginDraftTrack(name: string, createdTime: number): Promise<number> {
    const store: relationalStore.RdbStore | null = this.need();
    if (store === null) {
      return -1;
    }
    return await DbKit.insert(store, 'track', {
      'name': name, 'created_time': createdTime, 'visible': 1, 'recording': 1,
      'color': TrackRecord.DEFAULT_COLOR, 'line_width': TrackRecord.DEFAULT_LINE_WIDTH,
    });
  }

  /** 追加一个轨迹坐标点（采集过程中实时落库） */
  async appendTrackPoint(trackId: number, seq: number, lat: number, lon: number, alt: number): Promise<void> {
    const store: relationalStore.RdbStore | null = this.need();
    if (store === null) {
      return;
    }
    await DbKit.insert(store, 'track_point', {
      'track_id': trackId, 'seq': seq, 'latitude': lat, 'longitude': lon, 'altitude': alt,
    });
  }

  /** 结束草稿轨迹：写入最终名称并清除「记录中」标记，此后作为历史轨迹显示 */
  async finishDraftTrack(trackId: number, name: string): Promise<void> {
    const store: relationalStore.RdbStore | null = this.need();
    if (store === null) {
      return;
    }
    await DbKit.update(store, 'track', { 'name': name, 'recording': 0 }, 'id = ?', [trackId]);
  }

  /** 放弃草稿轨迹（连同已采集点一并删除） */
  async discardDraftTrack(trackId: number): Promise<void> {
    await this.deleteTrack(trackId);
  }

  /** 读取最近一条未结束的草稿轨迹（含已采集坐标点），无则 undefined */
  async loadDraftTrack(): Promise<TrackRecord | undefined> {
    const store: relationalStore.RdbStore | null = this.need();
    if (store === null) {
      return undefined;
    }
    const list: TrackRecord[] = await DbKit.query<TrackRecord>(store,
      'SELECT id, name, created_time, visible, color, line_width FROM track '
        + 'WHERE recording = 1 ORDER BY created_time DESC LIMIT 1', [],
      (rs: relationalStore.ResultSet): TrackRecord => {
        return new TrackRecord(DbKit.int(rs, 'id'), DbKit.str(rs, 'name'), DbKit.num(rs, 'created_time'),
          [], DbKit.int(rs, 'visible') !== 0, DbKit.color(rs, 'color', TrackRecord.DEFAULT_COLOR),
          DbKit.int(rs, 'line_width') > 0 ? DbKit.int(rs, 'line_width') : TrackRecord.DEFAULT_LINE_WIDTH);
      });
    if (list.length === 0) {
      return undefined;
    }
    const record: TrackRecord = list[0];
    record.points = await DbKit.query<number[]>(store,
      'SELECT latitude, longitude, altitude FROM track_point WHERE track_id = ? ORDER BY seq ASC',
      [record.id],
      (rs: relationalStore.ResultSet): number[] => {
        return [DbKit.num(rs, 'latitude'), DbKit.num(rs, 'longitude'), DbKit.num(rs, 'altitude')];
      });
    return record;
  }

  /** 删除轨迹及其坐标点 */
  async deleteTrack(trackId: number): Promise<void> {
    const store: relationalStore.RdbStore | null = this.need();
    if (store === null) {
      return;
    }
    await DbKit.remove(store, 'track_point', 'track_id = ?', [trackId]);
    await DbKit.remove(store, 'track', 'id = ?', [trackId]);
  }

  async updateTrackName(trackId: number, name: string): Promise<void> {
    const store: relationalStore.RdbStore | null = this.need();
    if (store === null) {
      return;
    }
    await DbKit.update(store, 'track', { 'name': name }, 'id = ?', [trackId]);
  }

  /** 更新轨迹逐条可见性（隐藏后地图不渲染） */
  async updateTrackVisible(trackId: number, visible: boolean): Promise<void> {
    const store: relationalStore.RdbStore | null = this.need();
    if (store === null) {
      return;
    }
    await DbKit.update(store, 'track', { 'visible': visible ? 1 : 0 }, 'id = ?', [trackId]);
  }

  /** 更新轨迹样式（颜色 + 线宽），轨迹详情「保存」调用 */
  async updateTrackStyle(trackId: number, color: number, lineWidth: number): Promise<void> {
    const store: relationalStore.RdbStore | null = this.need();
    if (store === null) {
      return;
    }
    await DbKit.update(store, 'track', { 'color': color, 'line_width': lineWidth }, 'id = ?', [trackId]);
  }

  // ── 测量 ────────────────────────────────────────────────────────

  /** 保存一条测量记录，返回主键（失败 -1） */
  async addMeasurement(name: string, type: string, color: number, createdTime: number,
    points: number[][], lineWidth: number = MeasurementRecord.DEFAULT_LINE_WIDTH): Promise<number> {
    const store: relationalStore.RdbStore | null = this.need();
    if (store === null) {
      return -1;
    }
    return await DbKit.insert(store, 'measurement', {
      'name': name, 'type': type, 'color': color, 'created_time': createdTime,
      'points': MapDataStore.pointsToJson(points), 'line_width': lineWidth,
    });
  }

  /** 加载全部测量记录，按创建时间降序；点串为空的脏记录跳过 */
  async loadMeasurements(): Promise<MeasurementRecord[]> {
    const store: relationalStore.RdbStore | null = this.need();
    if (store === null) {
      return [];
    }
    const rows: (MeasurementRecord | null)[] = await DbKit.query<MeasurementRecord | null>(store,
      'SELECT id, name, type, color, created_time, points, line_width FROM measurement '
        + 'ORDER BY created_time DESC', [],
      (rs: relationalStore.ResultSet): MeasurementRecord | null => {
        const points: number[][] = MapDataStore.jsonToPoints(DbKit.str(rs, 'points'));
        if (points.length === 0) {
          return null;
        }
        return new MeasurementRecord(DbKit.int(rs, 'id'), DbKit.str(rs, 'name'), DbKit.str(rs, 'type'),
          DbKit.color(rs, 'color', 0xFF57ACFD), DbKit.num(rs, 'created_time'), points,
          DbKit.int(rs, 'line_width') > 0 ? DbKit.int(rs, 'line_width') : MeasurementRecord.DEFAULT_LINE_WIDTH);
      });
    const out: MeasurementRecord[] = [];
    for (let i = 0; i < rows.length; i++) {
      const r: MeasurementRecord | null = rows[i];
      if (r !== null) {
        out.push(r);
      }
    }
    return out;
  }

  /** 更新测量记录样式（颜色 + 线宽），测量详情「保存」调用 */
  async updateMeasurementStyle(measurementId: number, color: number, lineWidth: number): Promise<void> {
    const store: relationalStore.RdbStore | null = this.need();
    if (store === null) {
      return;
    }
    await DbKit.update(store, 'measurement', { 'color': color, 'line_width': lineWidth },
      'id = ?', [measurementId]);
  }

  /** 重命名测量记录 */
  async updateMeasurementName(measurementId: number, name: string): Promise<void> {
    const store: relationalStore.RdbStore | null = this.need();
    if (store === null) {
      return;
    }
    await DbKit.update(store, 'measurement', { 'name': name }, 'id = ?', [measurementId]);
  }

  async deleteMeasurement(measurementId: number): Promise<void> {
    const store: relationalStore.RdbStore | null = this.need();
    if (store === null) {
      return;
    }
    await DbKit.remove(store, 'measurement', 'id = ?', [measurementId]);
  }

  // ── 点串 JSON 编解码（格式与 Android 一致，[[lat,lon,alt],…]）──

  static pointsToJson(points: number[][]): string {
    const parts: string[] = [];
    for (let i = 0; i < points.length; i++) {
      const p: number[] = points[i];
      parts.push(`[${p[0]},${p[1]},${p.length > 2 ? p[2] : 0}]`);
    }
    return `[${parts.join(',')}]`;
  }

  static jsonToPoints(json: string): number[][] {
    const out: number[][] = [];
    if (json.length === 0) {
      return out;
    }
    try {
      const arr = JSON.parse(json) as number[][];
      for (let i = 0; i < arr.length; i++) {
        const item: number[] = arr[i];
        if (item.length >= 2) {
          out.push([item[0], item[1], item.length > 2 ? item[2] : 0]);
        }
      }
    } catch (e) {
      // JSON 格式错误时返回空列表（与 Android 静默降级一致）
    }
    return out;
  }

  /**
   * 两点大圆距离（米）：仓库内自包含实现，避免 db 层反向依赖 common/GeoCalc 之外的层次。
   * 与 GeoCalc.distanceMeters 同一公式（Haversine，R=6371000）。
   */
  static distanceMeters(lat1: number, lon1: number, lat2: number, lon2: number): number {
    const R: number = 6371000;
    const dLat: number = (lat2 - lat1) * Math.PI / 180.0;
    const dLon: number = (lon2 - lon1) * Math.PI / 180.0;
    const a: number = Math.sin(dLat / 2) * Math.sin(dLat / 2)
      + Math.cos(lat1 * Math.PI / 180.0) * Math.cos(lat2 * Math.PI / 180.0)
      * Math.sin(dLon / 2) * Math.sin(dLon / 2);
    return 2 * R * Math.asin(Math.sqrt(a));
  }
}
