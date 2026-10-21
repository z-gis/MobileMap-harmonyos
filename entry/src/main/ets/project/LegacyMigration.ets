// LegacyMigration.ets —— 旧工作库一次性迁移（对应 Android project/LegacyMigration.kt，0.4.0.0 单库版）。
//
// 旧版本采集数据存于三个 SQLite 工作库：map.db（轨迹/测量/记录中草稿）、media.db（拍照点位/
// 附件/分组）、sample_survey.db（样地调查）。单库切换后它们废弃：首启创建「默认工程」时由本类
// 把旧库数据一次性读入工程（旧文件保留不删），此后所有读写只走工程 gpkg，旧库不再触达。
//
// 三个旧 store 类（MapDataStore/MediaStore/SampleSurveyStore）保留仅作本迁移的读取器。
// 迁移前先判库文件存在性：鸿蒙 RDB 文件落在 <databaseDir>/rdb/<库名>，且 DbKit.open 会建空库，
// 必须先 fs 判存再取 store，避免误判「有旧库」并凭空建库。
// 迁移完成后 pref 标记（project_manager/legacy_migrated），防重迁。

import fs from '@ohos.file.fs';
import { common } from '@kit.AbilityKit';
import { AppLog } from '../common/AppLog';
import { AppDirs } from '../common/AppDirs';
import { Prefs } from '../common/Prefs';
import { MapDataStore, MeasurementRecord, TrackRecord as LegacyTrack } from '../db/MapDataStore';
import { MediaStore, MediaGroup, MediaPlacemark, MediaAttachment } from '../media/MediaStore';
import { SampleSurveyStore } from '../survey/SampleSurveyStore';
import { SurveyPlot as LegacyPlot, SurveyPhoto } from '../survey/SurveyModels';
import { GpkgDml } from './GpkgDml';
import {
  MeasureRecord, MediaGroupRecord, PhotoAttachment, PhotoRecord, Project,
  SurveyPlot, SurveyRow, TrackRecord
} from './ProjectModels';
import { ProjectManager } from './ProjectManager';

const TAG: string = 'LegacyMigration';
const PREFS_NAME: string = 'project_manager';
const KEY_LEGACY_MIGRATED: string = 'legacy_migrated';

export class LegacyMigration {
  /** 迁移是否已完成（pref 标记，防重迁） */
  static async isDone(ctx: common.Context): Promise<boolean> {
    return await Prefs.getBool(ctx, PREFS_NAME, KEY_LEGACY_MIGRATED, false);
  }

  /** 标记迁移完成 */
  static async markDone(ctx: common.Context): Promise<void> {
    await Prefs.putBool(ctx, PREFS_NAME, KEY_LEGACY_MIGRATED, true);
  }

  /**
   * 把存在的旧库数据迁入工程 p（仅限首启默认工程创建时调用一次）。
   * @return 是否迁入了任何数据
   */
  static async migrateInto(ctx: common.Context, p: Project): Promise<boolean> {
    let migrated: boolean = false;
    try {
      migrated = (await LegacyMigration.migrateMapStore(ctx, p)) || migrated;
    } catch (e) {
      AppLog.e(`${TAG} 迁移 map.db 失败`, e);
    }
    try {
      migrated = (await LegacyMigration.migrateMediaStore(ctx, p)) || migrated;
    } catch (e) {
      AppLog.e(`${TAG} 迁移 media.db 失败`, e);
    }
    try {
      migrated = (await LegacyMigration.migrateSurveyStore(ctx, p)) || migrated;
    } catch (e) {
      AppLog.e(`${TAG} 迁移 sample_survey.db 失败`, e);
    }
    if (migrated) {
      AppLog.i(`${TAG} 旧库迁移完成: tracks=${p.tracks.length} measures=${p.measures.length} `
        + `photos=${p.photos.length} groups=${p.mediaGroups.length} plots=${p.surveyPlots.length}`);
    }
    return migrated;
  }

  /** 旧三库（map.db / media.db / sample_survey.db）任一仍存在：启动期判定是否走迁移文案的依据 */
  static hasLegacyStores(ctx: common.Context): boolean {
    return LegacyMigration.dbExists(ctx, 'map.db')
      || LegacyMigration.dbExists(ctx, 'media.db')
      || LegacyMigration.dbExists(ctx, 'sample_survey.db');
  }

  /**
   * 磁盘照片文件收 BLOB：整写落盘后逐附件读文件字节经 addPhotoAttachment 入库
   * （idx=0 主照片 photos.photo_data，>=1 photo_att_data 附加表）。
   * 文件本体此处不删——删除交 ProjectManager.ensureProjectReady 的 sweepPhotoFiles 统一退役
   * （入库失败保留文件，下次打开工程 sweep 幂等重试）。
   * @return 入库成功的附件数
   */
  static async ingestPhotoBlobs(gpkgPath: string, p: Project): Promise<number> {
    let ingested: number = 0;
    for (let i = 0; i < p.photos.length; i++) {
      const photo: PhotoRecord = p.photos[i];
      for (let idx = 0; idx < photo.attachments.length; idx++) {
        const att: PhotoAttachment = photo.attachments[idx];
        if (att.path.length === 0 || !AppDirs.exists(att.path)) {
          continue;
        }
        const data: ArrayBuffer | null = LegacyMigration.readFileBytes(att.path);
        if (data === null) {
          continue;
        }
        if (await GpkgDml.addPhotoAttachment(gpkgPath, photo.id, idx, data)) {
          ingested++;
        } else {
          AppLog.w(`${TAG} 照片 BLOB 入库失败 fid=${photo.id} idx=${idx} ${att.path}`);
        }
      }
    }
    if (ingested > 0) {
      AppLog.i(`${TAG} 照片 BLOB 入库完成: ${ingested} 张`);
    }
    return ingested;
  }

  // ── map.db（轨迹 + 测量 + 记录中草稿）──

  private static async migrateMapStore(ctx: common.Context, p: Project): Promise<boolean> {
    if (!LegacyMigration.dbExists(ctx, 'map.db')) {
      return false;
    }
    const store: MapDataStore = await MapDataStore.getInstance(ctx);
    let migrated: boolean = false;

    const tracks: LegacyTrack[] = await store.loadTracks();
    for (let i = 0; i < tracks.length; i++) {
      const t: LegacyTrack = tracks[i];
      const r: TrackRecord = new TrackRecord();
      r.id = t.id;
      r.name = t.name;
      r.date = ProjectManager.formatTime(t.createdTime);
      r.color = ProjectManager.colorToHex(t.color);
      r.hidden = !t.visible;
      r.lineWidth = t.lineWidth;
      r.points = t.points; // 旧库点串同为 [lat,lon,alt] 内存序，直接搬
      p.tracks.push(r);
      migrated = true;
    }

    const measures: MeasurementRecord[] = await store.loadMeasurements();
    for (let i = 0; i < measures.length; i++) {
      const m: MeasurementRecord = measures[i];
      const r: MeasureRecord = new MeasureRecord();
      r.id = m.id;
      r.name = m.name;
      r.date = ProjectManager.formatTime(m.createdTime);
      r.type = m.type;
      r.result = ProjectManager.measureResultText(m.type, m.points);
      r.color = ProjectManager.colorToHex(m.color);
      r.closed = m.type === MeasureRecord.TYPE_AREA;
      r.lineWidth = m.lineWidth;
      r.points = m.points;
      p.measures.push(r);
      migrated = true;
    }

    // 「记录中」草稿轨迹：loadDraftTrack 不受 recording=0 过滤，写入新方案的草稿文件，
    // 升级后恢复记录会话（restoreDraftTrack 读回），避免升级瞬间进行中的轨迹滞留旧库丢失
    const draft: LegacyTrack | undefined = await store.loadDraftTrack();
    if (draft !== undefined && draft.points.length > 0) {
      const draftFile: string = `${ProjectManager.get(ctx).projectsDir}/.track_draft.json`;
      if (!AppDirs.exists(draftFile)) {
        const pts: number[][] = [];
        for (let i = 0; i < draft.points.length; i++) {
          const pt: number[] = draft.points[i];
          pts.push([pt[0], pt[1], pt.length > 2 ? pt[2] : 0]);
        }
        const o: Record<string, Object> = {
          'name': draft.name,
          'createdTime': draft.createdTime,
          'points': pts,
        };
        LegacyMigration.writeFileAtomic(draftFile, JSON.stringify(o));
        migrated = true;
        AppLog.i(`${TAG} 迁移「记录中」草稿轨迹: ${draft.points.length} 点`);
      }
    }
    return migrated;
  }

  // ── media.db（拍照点位 + 附件 + 分组）──

  private static async migrateMediaStore(ctx: common.Context, p: Project): Promise<boolean> {
    if (!LegacyMigration.dbExists(ctx, 'media.db')) {
      return false;
    }
    const store: MediaStore = await MediaStore.getInstance(ctx);
    let migrated: boolean = false;

    const groups: MediaGroup[] = await store.loadGroups();
    for (let i = 0; i < groups.length; i++) {
      const g: MediaGroup = groups[i];
      const r: MediaGroupRecord = new MediaGroupRecord();
      r.id = g.id;
      r.name = g.name;
      r.createdTime = g.createdTime;
      r.visible = g.visible;
      p.mediaGroups.push(r);
      migrated = true;
    }

    const placemarks: MediaPlacemark[] = await store.loadPlacemarks();
    for (let i = 0; i < placemarks.length; i++) {
      const pm: MediaPlacemark = placemarks[i];
      const r: PhotoRecord = new PhotoRecord();
      r.id = pm.id;
      r.name = pm.name;
      r.lat = pm.latitude;
      r.lon = pm.longitude;
      r.timestamp = pm.createdTime;
      r.visible = pm.visible;
      r.groupId = pm.groupId;
      for (let j = 0; j < pm.attachments.length; j++) {
        const a: MediaAttachment = pm.attachments[j];
        r.attachments.push(new PhotoAttachment(a.name, a.path, a.time));
      }
      p.photos.push(r);
      migrated = true;
    }
    return migrated;
  }

  // ── sample_survey.db（样地调查，含明细行与照片记录）──

  private static async migrateSurveyStore(ctx: common.Context, p: Project): Promise<boolean> {
    if (!LegacyMigration.dbExists(ctx, 'sample_survey.db')) {
      return false;
    }
    const store: SampleSurveyStore = await SampleSurveyStore.getInstance(ctx);
    let migrated: boolean = false;
    const briefs: LegacyPlot[] = await store.loadAllPlots();
    for (let i = 0; i < briefs.length; i++) {
      // loadAllPlots 不含明细行，按 id 重读完整样地（含 rows）
      const s: LegacyPlot | undefined = await store.loadPlot(briefs[i].id);
      if (s === undefined) {
        continue;
      }
      const r: SurveyPlot = new SurveyPlot();
      r.id = s.id;
      r.name = `样地#${s.plotNo}`;
      r.plotType = 'point';
      if (!Number.isNaN(s.centerLatitude) && !Number.isNaN(s.centerLongitude)) {
        r.points.push([s.centerLatitude, s.centerLongitude, 0]);
      }
      r.sourcePath = s.sourcePath;
      r.sourceFid = s.sourceFid;
      r.compartmentNo = s.compartmentNo;
      r.plotNo = s.plotNo;
      r.averageTreeHeight = s.averageTreeHeight;
      r.canopyDensity = s.canopyDensity;
      r.cornerCoordinates = s.cornerCoordinates;
      r.createdAt = s.createdAt;
      r.updatedAt = s.updatedAt;
      for (let j = 0; j < s.rows.length; j++) {
        const row = s.rows[j];
        const nr: SurveyRow = new SurveyRow();
        nr.sortNo = row.sortNo;
        nr.treeSpecies = row.treeSpecies;
        nr.dbh = row.dbh;
        nr.category = row.category;
        nr.thinningMethod = row.thinningMethod;
        nr.remark = row.remark;
        r.rows.push(nr);
      }
      const photos: SurveyPhoto[] = await store.loadPhotos(s.id);
      for (let j = 0; j < photos.length; j++) {
        r.photoPaths.push(photos[j].filePath);
      }
      p.surveyPlots.push(r);
      migrated = true;
    }
    return migrated;
  }

  // ── 工具 ──

  /**
   * 旧库文件存在性判定（RDB 落盘路径 <databaseDir>/rdb/<库名>）：
   * 必须先判存再取 store——DbKit.open 会 openOrCreate 建空库，误建后本判定永真。
   */
  private static dbExists(ctx: common.Context, name: string): boolean {
    return AppDirs.exists(`${ctx.databaseDir}/rdb/${name}`);
  }

  /** 读文件全部字节；不存在/读失败/空文件返回 null */
  private static readFileBytes(path: string): ArrayBuffer | null {
    try {
      const size: number = fs.statSync(path).size;
      if (size <= 0) {
        return null;
      }
      const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      const buf: ArrayBuffer = new ArrayBuffer(size);
      fs.readSync(file.fd, buf);
      fs.closeSync(file);
      return buf;
    } catch (e) {
      AppLog.w(`${TAG} 读文件失败: ${path}`);
      return null;
    }
  }

  /** 原子写文本：先写 .tmp 再 rename，防半写（与 gpkg 整写同策略） */
  private static writeFileAtomic(path: string, content: string): boolean {
    const tmp: string = `${path}.tmp`;
    try {
      const file = fs.openSync(tmp, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, content);
      fs.closeSync(file);
      fs.renameSync(tmp, path);
      return true;
    } catch (e) {
      AppLog.e(`${TAG} 写文件失败: ${path}`, e);
      return false;
    }
  }
}
