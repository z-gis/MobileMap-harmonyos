// MediaStore.ets —— 拍照点位与附件仓库（对应 Android media.MediaStore）。
//
// 表结构与 Android media.db 一致：placemark（点位）/ attachment（附件）/ media_group（分组）。
// 附件文件本体存沙箱 调查宝/Media/<点位名>/ 下，库内只记相对沙箱根的路径；
// 分组仅是一层组织关系（整组显隐经 setGroupPlacemarksVisible 落到各点位 visible，
// 渲染层只需判断点位自身 visible，无需耦合分组标志）。

import { common } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { DbKit } from '../db/DbKit';

/** 媒体附件记录（一个点位可挂多个附件） */
export class MediaAttachment {
  static readonly TYPE_PHOTO: string = 'photo';
  static readonly TYPE_VIDEO: string = 'video';
  static readonly TYPE_AUDIO: string = 'audio';

  id: number;
  placemarkId: number;
  type: string;
  name: string;
  path: string;
  time: number;

  constructor(id: number = 0, placemarkId: number = 0, type: string = MediaAttachment.TYPE_PHOTO,
    name: string = '', path: string = '', time: number = 0) {
    this.id = id;
    this.placemarkId = placemarkId;
    this.type = type;
    this.name = name;
    this.path = path;
    this.time = time;
  }

  static typeLabel(type: string): string {
    if (type === MediaAttachment.TYPE_VIDEO) {
      return '视频';
    }
    if (type === MediaAttachment.TYPE_AUDIO) {
      return '音频';
    }
    return '照片';
  }
}

/** 媒体分组记录 */
export class MediaGroup {
  id: number;
  name: string;
  createdTime: number;
  /** 分组整体可见性：隐藏后组内全部点位在地图不渲染 */
  visible: boolean;

  constructor(id: number = 0, name: string = '', createdTime: number = 0, visible: boolean = true) {
    this.id = id;
    this.name = name;
    this.createdTime = createdTime;
    this.visible = visible;
  }
}

/** 媒体点位记录：一个拍照点位对应一行 */
export class MediaPlacemark {
  id: number;
  name: string;
  latitude: number;
  longitude: number;
  createdTime: number;
  visible: boolean;
  /** 所属分组主键，UNGROUPED_ID 表示未分组 */
  groupId: number;
  attachments: MediaAttachment[];

  constructor(id: number = 0, name: string = '', latitude: number = 0, longitude: number = 0,
    createdTime: number = 0, visible: boolean = true, groupId: number = MediaStore.UNGROUPED_ID,
    attachments: MediaAttachment[] = []) {
    this.id = id;
    this.name = name;
    this.latitude = latitude;
    this.longitude = longitude;
    this.createdTime = createdTime;
    this.visible = visible;
    this.groupId = groupId;
    this.attachments = attachments;
  }

  /** 点位显示名：有名用名，空名回退「拍照(附件数)/拍照」（与 Android mediaDisplayName 同口径） */
  displayName(): string {
    if (this.name.trim().length > 0) {
      return this.name;
    }
    return this.attachments.length > 1 ? `拍照(${this.attachments.length})` : '拍照';
  }
}

const DB_NAME: string = 'media.db';

const DDL: string[] = [
  'CREATE TABLE IF NOT EXISTS placemark ('
    + 'id INTEGER PRIMARY KEY AUTOINCREMENT, '
    + 'name TEXT, '
    + 'latitude REAL, '
    + 'longitude REAL, '
    + 'created_time INTEGER, '
    + 'visible INTEGER DEFAULT 1, '
    + 'group_id INTEGER DEFAULT -1)',
  'CREATE TABLE IF NOT EXISTS attachment ('
    + 'id INTEGER PRIMARY KEY AUTOINCREMENT, '
    + 'placemark_id INTEGER, '
    + 'attachment_type TEXT, '
    + 'attachment_name TEXT, '
    + 'attachment_path TEXT, '
    + 'attachment_time DATETIME)',
  // group 为 SQL 关键字，表名用 media_group
  'CREATE TABLE IF NOT EXISTS media_group ('
    + 'id INTEGER PRIMARY KEY AUTOINCREMENT, '
    + 'name TEXT, '
    + 'created_time INTEGER, '
    + 'visible INTEGER DEFAULT 1)',
];

/** 附件查询列（两表列名带前缀，集中声明避免下标/拼写漂移） */
const ATTACH_COLUMNS: string =
  'id, placemark_id, attachment_type, attachment_name, attachment_path, attachment_time';

export class MediaStore {
  /** 未分组标识（placemark.group_id 默认值） */
  static readonly UNGROUPED_ID: number = -1;

  private static inst: MediaStore | null = null;
  private store: relationalStore.RdbStore | null = null;
  private migrating: Promise<void> | null = null;

  static async getInstance(ctx: common.Context): Promise<MediaStore> {
    if (MediaStore.inst === null) {
      MediaStore.inst = new MediaStore();
    }
    const repo: MediaStore = MediaStore.inst;
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
    // 旧库平滑迁移：placemark 缺 group_id 列时补列（默认未分组），不丢弃既有数据
    await DbKit.ensureColumn(store, 'placemark', 'group_id',
      'ALTER TABLE placemark ADD COLUMN group_id INTEGER DEFAULT -1');
  }

  private need(): relationalStore.RdbStore | null {
    return this.store;
  }

  /** 新建一个媒体点位，返回自增主键（失败 -1） */
  async insertPlacemark(name: string, latitude: number, longitude: number, createdTime: number,
    groupId: number = MediaStore.UNGROUPED_ID): Promise<number> {
    const store: relationalStore.RdbStore | null = this.need();
    if (store === null) {
      return -1;
    }
    return await DbKit.insert(store, 'placemark', {
      'name': name, 'latitude': latitude, 'longitude': longitude,
      'created_time': createdTime, 'visible': 1, 'group_id': groupId,
    });
  }

  /** 为点位追加一条附件记录，返回附件主键（失败 -1） */
  async insertAttachment(placemarkId: number, type: string, name: string, path: string,
    time: number): Promise<number> {
    const store: relationalStore.RdbStore | null = this.need();
    if (store === null) {
      return -1;
    }
    return await DbKit.insert(store, 'attachment', {
      'placemark_id': placemarkId, 'attachment_type': type, 'attachment_name': name,
      'attachment_path': path, 'attachment_time': time,
    });
  }

  /** 加载全部点位（含各自附件），按创建时间降序 */
  async loadPlacemarks(): Promise<MediaPlacemark[]> {
    const store: relationalStore.RdbStore | null = this.need();
    if (store === null) {
      return [];
    }
    const placemarks: MediaPlacemark[] = await DbKit.query<MediaPlacemark>(store,
      'SELECT id, name, latitude, longitude, created_time, visible, group_id FROM placemark '
        + 'ORDER BY created_time DESC', [],
      (rs: relationalStore.ResultSet): MediaPlacemark => {
        return new MediaPlacemark(DbKit.int(rs, 'id'), DbKit.str(rs, 'name'),
          DbKit.num(rs, 'latitude'), DbKit.num(rs, 'longitude'), DbKit.num(rs, 'created_time'),
          DbKit.int(rs, 'visible') !== 0, DbKit.int(rs, 'group_id', MediaStore.UNGROUPED_ID), []);
      });
    if (placemarks.length === 0) {
      return [];
    }
    const byId: Map<number, MediaPlacemark> = new Map<number, MediaPlacemark>();
    for (let i = 0; i < placemarks.length; i++) {
      byId.set(placemarks[i].id, placemarks[i]);
    }
    const attachments: MediaAttachment[] = await DbKit.query<MediaAttachment>(store,
      `SELECT ${ATTACH_COLUMNS} FROM attachment ORDER BY attachment_time ASC`, [],
      (rs: relationalStore.ResultSet): MediaAttachment => {
        return new MediaAttachment(DbKit.int(rs, 'id'), DbKit.int(rs, 'placemark_id'),
          DbKit.str(rs, 'attachment_type'), DbKit.str(rs, 'attachment_name'),
          DbKit.str(rs, 'attachment_path'), DbKit.num(rs, 'attachment_time'));
      });
    for (let i = 0; i < attachments.length; i++) {
      const a: MediaAttachment = attachments[i];
      const owner: MediaPlacemark | undefined = byId.get(a.placemarkId);
      if (owner !== undefined) {
        owner.attachments.push(a);
      }
    }
    return placemarks;
  }

  /**
   * 按主键加载单个点位（含其附件），不存在返回 undefined。
   * 拍照流程与点位详情只需一条记录，用 WHERE id=? 精确查询，避开全表读入内存再过滤。
   */
  async findPlacemark(placemarkId: number): Promise<MediaPlacemark | undefined> {
    const store: relationalStore.RdbStore | null = this.need();
    if (store === null) {
      return undefined;
    }
    const list: MediaPlacemark[] = await DbKit.query<MediaPlacemark>(store,
      'SELECT id, name, latitude, longitude, created_time, visible, group_id FROM placemark WHERE id = ?',
      [placemarkId],
      (rs: relationalStore.ResultSet): MediaPlacemark => {
        return new MediaPlacemark(DbKit.int(rs, 'id'), DbKit.str(rs, 'name'),
          DbKit.num(rs, 'latitude'), DbKit.num(rs, 'longitude'), DbKit.num(rs, 'created_time'),
          DbKit.int(rs, 'visible') !== 0, DbKit.int(rs, 'group_id', MediaStore.UNGROUPED_ID), []);
      });
    if (list.length === 0) {
      return undefined;
    }
    const placemark: MediaPlacemark = list[0];
    placemark.attachments = await DbKit.query<MediaAttachment>(store,
      `SELECT ${ATTACH_COLUMNS} FROM attachment WHERE placemark_id = ? ORDER BY attachment_time ASC`,
      [placemarkId],
      (rs: relationalStore.ResultSet): MediaAttachment => {
        return new MediaAttachment(DbKit.int(rs, 'id'), DbKit.int(rs, 'placemark_id'),
          DbKit.str(rs, 'attachment_type'), DbKit.str(rs, 'attachment_name'),
          DbKit.str(rs, 'attachment_path'), DbKit.num(rs, 'attachment_time'));
      });
    return placemark;
  }

  async updatePlacemarkName(placemarkId: number, name: string): Promise<void> {
    const store: relationalStore.RdbStore | null = this.need();
    if (store === null) {
      return;
    }
    await DbKit.update(store, 'placemark', { 'name': name }, 'id = ?', [placemarkId]);
  }

  /** 修改点位可见性（隐藏后地图不渲染该点位） */
  async updatePlacemarkVisible(placemarkId: number, visible: boolean): Promise<void> {
    const store: relationalStore.RdbStore | null = this.need();
    if (store === null) {
      return;
    }
    await DbKit.update(store, 'placemark', { 'visible': visible ? 1 : 0 }, 'id = ?', [placemarkId]);
  }

  /** 修改点位所属分组（UNGROUPED_ID 表示移出到未分组） */
  async updatePlacemarkGroup(placemarkId: number, groupId: number): Promise<void> {
    const store: relationalStore.RdbStore | null = this.need();
    if (store === null) {
      return;
    }
    await DbKit.update(store, 'placemark', { 'group_id': groupId }, 'id = ?', [placemarkId]);
  }

  /** 删除点位及其附件记录（附件文件由调用方删除） */
  async deletePlacemark(placemarkId: number): Promise<void> {
    const store: relationalStore.RdbStore | null = this.need();
    if (store === null) {
      return;
    }
    await DbKit.remove(store, 'attachment', 'placemark_id = ?', [placemarkId]);
    await DbKit.remove(store, 'placemark', 'id = ?', [placemarkId]);
  }

  /** 删除单条附件记录（文件由调用方删除） */
  async deleteAttachment(attachmentId: number): Promise<void> {
    const store: relationalStore.RdbStore | null = this.need();
    if (store === null) {
      return;
    }
    await DbKit.remove(store, 'attachment', 'id = ?', [attachmentId]);
  }

  // ── 分组 ────────────────────────────────────────────────────────

  async insertGroup(name: string, createdTime: number): Promise<number> {
    const store: relationalStore.RdbStore | null = this.need();
    if (store === null) {
      return -1;
    }
    return await DbKit.insert(store, 'media_group', {
      'name': name, 'created_time': createdTime, 'visible': 1,
    });
  }

  /** 加载全部分组，按创建时间升序 */
  async loadGroups(): Promise<MediaGroup[]> {
    const store: relationalStore.RdbStore | null = this.need();
    if (store === null) {
      return [];
    }
    return await DbKit.query<MediaGroup>(store,
      'SELECT id, name, created_time, visible FROM media_group ORDER BY created_time ASC', [],
      (rs: relationalStore.ResultSet): MediaGroup => {
        return new MediaGroup(DbKit.int(rs, 'id'), DbKit.str(rs, 'name'),
          DbKit.num(rs, 'created_time'), DbKit.int(rs, 'visible') !== 0);
      });
  }

  async updateGroupName(groupId: number, name: string): Promise<void> {
    const store: relationalStore.RdbStore | null = this.need();
    if (store === null) {
      return;
    }
    await DbKit.update(store, 'media_group', { 'name': name }, 'id = ?', [groupId]);
  }

  /**
   * 批量设置分组内全部点位的可见性：渲染层只需判断点位自身 visible，
   * 故分组开关直接落库到组内各点位，不做二次耦合。
   */
  async setGroupPlacemarksVisible(groupId: number, visible: boolean): Promise<void> {
    const store: relationalStore.RdbStore | null = this.need();
    if (store === null) {
      return;
    }
    await DbKit.update(store, 'placemark', { 'visible': visible ? 1 : 0 }, 'group_id = ?', [groupId]);
  }

  /** 删除分组：仅删分组本身，组内点位改为未分组 */
  async deleteGroup(groupId: number): Promise<void> {
    const store: relationalStore.RdbStore | null = this.need();
    if (store === null) {
      return;
    }
    await DbKit.update(store, 'placemark', { 'group_id': MediaStore.UNGROUPED_ID },
      'group_id = ?', [groupId]);
    await DbKit.remove(store, 'media_group', 'id = ?', [groupId]);
  }
}
