// ProjectManager.ets —— 工程管理器（对应 Android project/ProjectManager.kt，0.4.0.4 增量落盘版）。
//
// 工程 gpkg 是采集数据（轨迹/测量/拍照/样地）的唯一数据本体，旧工作库
// （map.db / media.db / sample_survey.db）已废弃，仅在首启由 LegacyMigration
// 一次性迁入「默认工程」（旧文件保留不删）。
//
// 与 Android 的平台差异：
//  - 工程文件存应用沙箱 <filesDir>/projects/（fs API 自由读写；Android 为公共目录 /调查宝/projects/）；
//  - 增量写是同步 NAPI 调用（引擎侧 SQLite 直写），无 Android 的后台串行队列，
//    故 saveNow 语义简化为「元数据 syncMeta 落盘」，保持同名便于与 Android 对照；
//  - 全异步风格与 db/DbKit.ets 一致（async/await，UI 侧 await）。
//
// 照片策略：照片本体增量写入 gpkg BLOB（主照片 photos.photo_data，其余附件 photo_att_data
// 附加表），源文件在入库成功后由 sweepPhotoFiles 退役，不再长期保留。
// 内存模型坐标序为 [lat,lon,alt]，gpkg 轴序 [lon,lat,alt] 转换在 ProjectModels 序列化边界完成。

import fs from '@ohos.file.fs';
import { common } from '@kit.AbilityKit';
import { AppLog } from '../common/AppLog';
import { AppDirs } from '../common/AppDirs';
import { Prefs } from '../common/Prefs';
import { GeoCalc, LatLng } from '../common/GeoCalc';
import { GpkgDml } from './GpkgDml';
import { MeasureRecord, MediaGroupRecord, PhotoAttachment, PhotoRecord, Project, SurveyPlot, TrackRecord } from './ProjectModels';
import { LegacyMigration } from './LegacyMigration';

const TAG: string = 'ProjectManager';
const PREFS_NAME: string = 'project_manager';
const KEY_LAST_PROJECT: string = 'last_project_path';
const DEFAULT_PROJECT_NAME: string = '默认工程';

/** 工程信息（列表展示用） */
export class ProjectInfo {
  fileName: string = '';
  filePath: string = '';
  fileSize: number = 0;
  lastModified: number = 0;
  displaySize: string = '';
  displayDate: string = '';
}

export class ProjectManager {
  private static inst: ProjectManager | null = null;

  private readonly ctx: common.Context;
  /** 工程目录（<filesDir>/projects/，沙箱内 fs 自由读写） */
  readonly projectsDir: string;

  private cur: Project | null = null;

  /** 进行中的装载（EntryAbility 预热与主地图页装配并发复用同一 Promise，防首启双重迁移） */
  private loading: Promise<void> | null = null;

  /** 当前工程（内存模型），未装载为 null */
  get currentProject(): Project | null {
    return this.cur;
  }

  /** 当前工程 gpkg 文件绝对路径（由 name 推导，与 saveNowProject 同规则）；无当前工程返回 '' */
  get currentProjectPath(): string {
    const p: Project | null = this.cur;
    return p === null ? '' : this.filePathFor(p.name.length > 0 ? p.name : '未命名工程');
  }

  private constructor(ctx: common.Context) {
    this.ctx = ctx;
    this.projectsDir = AppDirs.ensureDir(`${ctx.filesDir}/projects`);
  }

  /** 取单例（后续 UI 接线统一经此入口） */
  static get(ctx: common.Context): ProjectManager {
    if (ProjectManager.inst === null) {
      ProjectManager.inst = new ProjectManager(ctx);
    }
    return ProjectManager.inst;
  }

  // ── 启动装载 ──

  /**
   * 确保已装载工程（App 启动时调用一次，幂等）：
   * 上次打开的工程文件仍在 → 读入；pref 丢失但默认工程文件仍在 → 直接打开不重建
   * （避免重建触发旧库重迁并覆盖既有数据）；否则创建「默认工程」，并由 LegacyMigration
   * 把旧工作库（若存在）一次性迁入后落盘。
   */
  async ensureLoaded(): Promise<void> {
    if (this.cur !== null) {
      return;
    }
    if (this.loading !== null) {
      return this.loading;
    }
    this.loading = this.doEnsureLoaded();
    try {
      await this.loading;
    } finally {
      this.loading = null;
    }
  }

  private async doEnsureLoaded(): Promise<void> {
    if (this.cur !== null) {
      return;
    }
    const last: string = await Prefs.getString(this.ctx, PREFS_NAME, KEY_LAST_PROJECT, '');
    if (last.length > 0 && AppDirs.exists(last)) {
      const p: Project | null = await this.readProject(last);
      if (p !== null) {
        this.cur = p;
        AppLog.i(`${TAG} ensureLoaded: 恢复上次工程 ${p.name}`);
        await this.ensureProjectReady(p, last);
        return;
      }
      AppLog.w(`${TAG} ensureLoaded: 上次工程读取失败，重建默认工程 ${last}`);
    }
    if (last.length === 0) {
      const defaultFile: string = `${this.projectsDir}/${DEFAULT_PROJECT_NAME}.gpkg`;
      if (AppDirs.exists(defaultFile)) {
        const p: Project | null = await this.readProject(defaultFile);
        if (p !== null) {
          this.cur = p;
          await this.rememberCurrent(defaultFile);
          await this.ensureProjectReady(p, defaultFile);
          AppLog.i(`${TAG} ensureLoaded: 默认工程文件已存在，直接打开`);
          return;
        }
      }
    }
    const p: Project | null = await this.createProject(DEFAULT_PROJECT_NAME, '自动创建，收纳现有采集数据');
    if (p === null) {
      AppLog.e(`${TAG} ensureLoaded: 默认工程创建失败`);
      return;
    }
    const filePath: string = this.currentProjectPath;
    let migrated: boolean = false;
    if (!(await LegacyMigration.isDone(this.ctx))) {
      migrated = await LegacyMigration.migrateInto(this.ctx, p);
      if (migrated) {
        // 迁移数据随模型整写落盘（此时照片 BLOB 尚未入库，attachments 只记路径）
        await this.writeProjectFile(p, filePath);
      }
      // 磁盘照片文件收 BLOB：读文件字节经 addPhotoAttachment 入库；
      // 文件本体删除交 ensureProjectReady 的 sweepPhotoFiles 统一退役
      await LegacyMigration.ingestPhotoBlobs(filePath, p);
      await LegacyMigration.markDone(this.ctx);
    }
    await this.ensureProjectReady(p, filePath);
    AppLog.i(`${TAG} ensureLoaded: 已创建默认工程（旧库迁移 ${migrated ? '有' : '无'}数据）`);
  }

  /** 当前工程文件名（列表高亮用），无工程返回 '' */
  currentFileName(): string {
    const p: Project | null = this.cur;
    return p === null ? '' : `${ProjectManager.sanitizeFileName(p.name)}.gpkg`;
  }

  // ── 工程 CRUD ──

  /**
   * 创建新工程并落盘、切换为当前工程，返回新工程（写盘失败返回 null）。
   * 重名自动带序号（name.gpkg 已存在时取 name_1、name_2…），绝不覆盖既有工程文件。
   */
  async createProject(name: string, description: string): Promise<Project | null> {
    const cur: Project | null = this.cur;
    if (cur !== null) {
      await this.saveNowProject(cur);
    }
    let finalName: string = name;
    let seq: number = 1;
    while (AppDirs.exists(this.filePathFor(finalName))) {
      finalName = `${name}_${seq}`;
      seq++;
    }
    if (finalName !== name) {
      AppLog.i(`${TAG} createProject: 重名带序号 ${name} -> ${finalName}`);
    }
    const p: Project = new Project();
    p.name = finalName;
    p.description = description;
    this.cur = p;
    const filePath: string = this.filePathFor(finalName);
    const ok: boolean = await this.writeProjectFile(p, filePath);
    if (!ok) {
      AppLog.e(`${TAG} createProject: 写盘失败 ${filePath}`);
      return null;
    }
    await this.rememberCurrent(filePath);
    await this.ensureProjectReady(p, filePath);
    AppLog.i(`${TAG} createProject: ${finalName}`);
    return p;
  }

  /** 检查是否有打开的工程 */
  hasProject(): boolean {
    return this.cur !== null;
  }

  /** 关闭当前工程（落盘后置空，防止 close 后立即重开读到半成品/丢数据） */
  async closeProject(): Promise<void> {
    const p: Project | null = this.cur;
    if (p === null) {
      return;
    }
    this.cur = null;
    await Prefs.deleteKey(this.ctx, PREFS_NAME, KEY_LAST_PROJECT);
    await this.saveNowProject(p);
    AppLog.i(`${TAG} closeProject`);
  }

  /** 列出所有工程文件（按最后修改时间倒序） */
  async listProjects(): Promise<ProjectInfo[]> {
    const list: ProjectInfo[] = [];
    let names: string[] = [];
    try {
      names = fs.listFileSync(this.projectsDir, { recursion: false });
    } catch (e) {
      AppLog.e(`${TAG} listProjects: 目录不可列举 ${this.projectsDir}`, e);
      return list;
    }
    for (let i = 0; i < names.length; i++) {
      const name: string = names[i];
      if (!name.endsWith('.gpkg')) {
        continue;
      }
      const path: string = `${this.projectsDir}/${name}`;
      try {
        const st = fs.statSync(path);
        const info: ProjectInfo = new ProjectInfo();
        info.fileName = name;
        info.filePath = path;
        info.fileSize = st.size;
        info.lastModified = st.mtime * 1000; // stat mtime 为秒，统一毫秒
        info.displayDate = ProjectManager.formatTime(info.lastModified).substring(0, 16);
        info.displaySize = ProjectManager.formatFileSize(st.size);
        list.push(info);
      } catch (e) {
        AppLog.w(`${TAG} listProjects: stat 失败 ${path}`);
      }
    }
    list.sort((a: ProjectInfo, b: ProjectInfo): number => b.lastModified - a.lastModified);
    return list;
  }

  /** 只读读取工程（不切换当前工程，供导出/复制非当前工程用） */
  async readProject(filePath: string): Promise<Project | null> {
    const json: string | null = await GpkgDml.readGeoPackage(filePath);
    if (json === null) {
      AppLog.e(`${TAG} readProject: ${filePath} 读取失败或为空`);
      return null;
    }
    const p: Project | null = Project.parse(json);
    if (p === null) {
      AppLog.e(`${TAG} readProject: ${filePath} JSON 解析失败`);
    }
    return p;
  }

  /**
   * 打开工程：当前工程先落盘 → 读 gpkg 切换 currentProject → 记为最近工程 → 就绪检查。
   * 工程名以文件名为准：gpkg 内 name 与文件名不一致（外部拷贝/改名所致）时回填文件名，
   * 否则按内部 name 落盘会另生成新文件，同名数据分叉成两份。
   */
  async openProject(filePath: string): Promise<Project | null> {
    const cur: Project | null = this.cur;
    if (cur !== null) {
      await this.saveNowProject(cur);
    }
    const p: Project | null = await this.readProject(filePath);
    if (p !== null) {
      const fileBase: string = ProjectManager.baseNameNoExt(filePath);
      if (p.name !== fileBase) {
        AppLog.i(`${TAG} openProject: 工程名回填 '${p.name}' -> '${fileBase}'（与文件名对齐）`);
        p.name = fileBase;
      }
      this.cur = p;
      await this.rememberCurrent(filePath);
      await this.ensureProjectReady(p, filePath);
      AppLog.i(`${TAG} openProject: ${filePath} -> ${p.name}`);
    } else {
      AppLog.e(`${TAG} openProject: 读取失败 ${filePath}`);
    }
    return p;
  }

  /**
   * 同步工程元数据（name/description/srs/createTime/updateTime + layerRefs）到 gpkg。
   * 业务数据已由各 mutation 增量落盘，此处仅元数据；需确定性落盘用 saveNow。
   */
  async saveProject(project: Project | null): Promise<boolean> {
    return await this.saveNowProject(project);
  }

  /**
   * 同步落盘指定工程：鸿蒙端增量写本是同步 NAPI 调用（无 Android 的队列栅栏），
   * 故语义 = 元数据 syncMeta 落盘。目标文件不存在（新建流程外异常缺失）时退回整文件重建。
   */
  async saveNowProject(project: Project | null): Promise<boolean> {
    if (project === null) {
      return false;
    }
    project.updateTime = Date.now();
    const filePath: string = this.filePathFor(project.name.length > 0 ? project.name : '未命名工程');
    if (!AppDirs.exists(filePath)) {
      return await this.writeProjectFile(project, filePath);
    }
    const ok: boolean = await GpkgDml.syncMeta(filePath, ProjectManager.buildMetaJson(project));
    if (!ok) {
      AppLog.e(`${TAG} saveNowProject: 元数据同步失败 ${filePath}`);
    }
    return ok;
  }

  /**
   * 立即同步落盘当前工程（定型类关键写入：轨迹停表入库、拍照入库、退出前兜底）。
   * 鸿蒙端语义 = 元数据落盘（增量写同步即时在盘，无队列可排）。
   */
  async saveNow(): Promise<boolean> {
    return await this.saveNowProject(this.cur);
  }

  /** 删除工程（API 层防线：当前工程禁止删除，防调用方绕过 UI 的隐藏逻辑） */
  async deleteProject(fileName: string): Promise<boolean> {
    const cur: Project | null = this.cur;
    if (cur !== null && fileName === `${ProjectManager.sanitizeFileName(cur.name)}.gpkg`) {
      AppLog.w(`${TAG} deleteProject: 拒绝删除当前工程 ${fileName}`);
      return false;
    }
    let ok: boolean = false;
    try {
      fs.unlinkSync(`${this.projectsDir}/${fileName}`);
      ok = true;
    } catch (e) {
      AppLog.e(`${TAG} deleteProject: 删除失败 ${fileName}`, e);
    }
    if (ok) {
      await Prefs.deleteKey(this.ctx, PREFS_NAME, KEY_LAST_PROJECT);
    }
    AppLog.i(`${TAG} deleteProject: ${fileName} -> ${ok}`);
    return ok;
  }

  /**
   * 重命名工程文件（同名冲突拒绝；若重命名的是当前工程，同步改工程名并落元数据）。
   */
  async renameProject(oldFileName: string, newName: string): Promise<boolean> {
    const oldPath: string = `${this.projectsDir}/${oldFileName}`;
    const newPath: string = this.filePathFor(newName);
    if (AppDirs.exists(newPath)) {
      AppLog.w(`${TAG} renameProject: 同名冲突拒绝 ${newName}`);
      return false;
    }
    let ok: boolean = false;
    try {
      fs.renameSync(oldPath, newPath);
      ok = true;
    } catch (e) {
      AppLog.e(`${TAG} renameProject: ${oldFileName} -> ${newName} 失败`, e);
    }
    const cur: Project | null = this.cur;
    if (ok && cur !== null &&
      ProjectManager.sanitizeFileName(cur.name) === oldFileName.replace(/\.gpkg$/, '')) {
      cur.name = newName;
      await this.saveProject(cur); // project_meta.name 随文件名对齐
      await this.rememberCurrent(newPath);
    }
    AppLog.i(`${TAG} renameProject: ${oldFileName} -> ${newName} ${ok}`);
    return ok;
  }

  // ── 记录 ID 分配（gpkg 落表为 fid，须 >0 且集合内唯一）──

  private static nextId(ids: number[]): number {
    let max: number = 0;
    for (let i = 0; i < ids.length; i++) {
      if (ids[i] > max) {
        max = ids[i];
      }
    }
    return max + 1;
  }

  // ── 轨迹 ──

  hasTracks(): boolean {
    const p: Project | null = this.cur;
    return p !== null && p.tracks.length > 0;
  }

  findTrack(id: number): TrackRecord | null {
    const p: Project | null = this.cur;
    if (p === null) {
      return null;
    }
    for (let i = 0; i < p.tracks.length; i++) {
      if (p.tracks[i].id === id) {
        return p.tracks[i];
      }
    }
    return null;
  }

  /** 新增轨迹（points 内存序 [lat,lon,alt]），返回分配的记录 id，无当前工程返回 -1 */
  async addTrack(name: string, createdTime: number, points: number[][],
    colorHex: string = TrackRecord.DEFAULT_COLOR_HEX,
    lineWidth: number = TrackRecord.DEFAULT_LINE_WIDTH): Promise<number> {
    const p: Project | null = this.cur;
    if (p === null) {
      return -1;
    }
    const r: TrackRecord = new TrackRecord();
    r.id = ProjectManager.nextId(p.tracks.map((t: TrackRecord): number => t.id));
    r.name = name;
    r.date = ProjectManager.formatTime(createdTime);
    r.color = colorHex;
    r.lineWidth = lineWidth;
    r.points = points;
    p.tracks.push(r);
    const fid: number = await GpkgDml.insertTrack(this.currentProjectPath, r.toJson());
    if (fid <= 0) {
      AppLog.e(`${TAG} addTrack: 增量插入失败 ${r.name}`);
    }
    return r.id;
  }

  /** 轨迹属性增量更新（可见性/样式/改名共用整行属性更新） */
  private async pushTrackUpdate(t: TrackRecord): Promise<void> {
    const o: Record<string, Object | null> = {
      'name': t.name,
      'color': t.color.length > 0 ? t.color : null,
      'hidden': t.hidden,
      'lineWidth': t.lineWidth,
    };
    const ok: boolean = await GpkgDml.updateTrack(this.currentProjectPath, t.id, JSON.stringify(o));
    if (!ok) {
      AppLog.e(`${TAG} pushTrackUpdate: 增量更新失败 id=${t.id}`);
    }
  }

  async removeTrack(id: number): Promise<void> {
    const p: Project | null = this.cur;
    if (p === null) {
      return;
    }
    for (let i = 0; i < p.tracks.length; i++) {
      if (p.tracks[i].id === id) {
        p.tracks.splice(i, 1);
        await GpkgDml.deleteTrack(this.currentProjectPath, id);
        return;
      }
    }
  }

  async updateTrackName(id: number, name: string): Promise<void> {
    const t: TrackRecord | null = this.findTrack(id);
    if (t !== null) {
      t.name = name;
      await this.pushTrackUpdate(t);
    }
  }

  async updateTrackVisible(id: number, visible: boolean): Promise<void> {
    const t: TrackRecord | null = this.findTrack(id);
    if (t !== null) {
      t.hidden = !visible;
      await this.pushTrackUpdate(t);
    }
  }

  async updateTrackStyle(id: number, colorInt: number, lineWidth: number): Promise<void> {
    const t: TrackRecord | null = this.findTrack(id);
    if (t !== null) {
      t.color = ProjectManager.colorToHex(colorInt);
      t.lineWidth = lineWidth;
      await this.pushTrackUpdate(t);
    }
  }

  // ── 测量 ──

  findMeasure(id: number): MeasureRecord | null {
    const p: Project | null = this.cur;
    if (p === null) {
      return null;
    }
    for (let i = 0; i < p.measures.length; i++) {
      if (p.measures[i].id === id) {
        return p.measures[i];
      }
    }
    return null;
  }

  /** 新增测量（points 内存序 [lat,lon,alt]；result 文本按几何自动计算），返回记录 id，无工程 -1 */
  async addMeasure(name: string, type: string, colorInt: number, createdTime: number, points: number[][],
    lineWidth: number = MeasureRecord.DEFAULT_LINE_WIDTH): Promise<number> {
    const p: Project | null = this.cur;
    if (p === null) {
      return -1;
    }
    const r: MeasureRecord = new MeasureRecord();
    r.id = ProjectManager.nextId(p.measures.map((m: MeasureRecord): number => m.id));
    r.name = name;
    r.date = ProjectManager.formatTime(createdTime);
    r.type = type;
    r.result = ProjectManager.measureResultText(type, points);
    r.color = ProjectManager.colorToHex(colorInt);
    r.closed = type === MeasureRecord.TYPE_AREA;
    r.lineWidth = lineWidth;
    r.points = points;
    p.measures.push(r);
    const fid: number = await GpkgDml.insertMeasure(this.currentProjectPath, r.toJson());
    if (fid <= 0) {
      AppLog.e(`${TAG} addMeasure: 增量插入失败 ${r.name}`);
    }
    return r.id;
  }

  async removeMeasure(id: number): Promise<void> {
    const p: Project | null = this.cur;
    if (p === null) {
      return;
    }
    for (let i = 0; i < p.measures.length; i++) {
      if (p.measures[i].id === id) {
        p.measures.splice(i, 1);
        await GpkgDml.deleteMeasure(this.currentProjectPath, id);
        return;
      }
    }
  }

  async updateMeasureStyle(id: number, colorInt: number, lineWidth: number): Promise<void> {
    const m: MeasureRecord | null = this.findMeasure(id);
    if (m !== null) {
      m.color = ProjectManager.colorToHex(colorInt);
      m.lineWidth = lineWidth;
      const o: Record<string, Object | null> = {
        'color': m.color,
        'lineWidth': m.lineWidth,
      };
      const ok: boolean = await GpkgDml.updateMeasure(this.currentProjectPath, id, JSON.stringify(o));
      if (!ok) {
        AppLog.e(`${TAG} updateMeasureStyle: 增量更新失败 id=${id}`);
      }
    }
  }

  // ── 拍照标识 ──

  findPhoto(id: number): PhotoRecord | null {
    const p: Project | null = this.cur;
    if (p === null) {
      return null;
    }
    for (let i = 0; i < p.photos.length; i++) {
      if (p.photos[i].id === id) {
        return p.photos[i];
      }
    }
    return null;
  }

  /** 新增拍照点位（首张照片前建会话点位），返回记录 id，无工程 -1 */
  async addPhoto(name: string, lat: number, lon: number, timestamp: number): Promise<number> {
    const p: Project | null = this.cur;
    if (p === null) {
      return -1;
    }
    const r: PhotoRecord = new PhotoRecord();
    r.id = ProjectManager.nextId(p.photos.map((ph: PhotoRecord): number => ph.id));
    r.name = name;
    r.lat = lat;
    r.lon = lon;
    r.timestamp = timestamp;
    p.photos.push(r);
    const fid: number = await GpkgDml.insertPhoto(this.currentProjectPath, r.toJson());
    if (fid <= 0) {
      AppLog.e(`${TAG} addPhoto: 增量插入失败 ${r.name}`);
    }
    return r.id;
  }

  /**
   * 为拍照点位追加一个照片附件：内存追加 → 照片本体读入 gpkg BLOB
   * （idx=0 主照片 photo_data，>=1 附件附加表）→ 附件整行重写（attachments JSON + photo_path），
   * 全部落库成功后删除源文件（照片不再长期保留文件）。
   */
  async addPhotoAttachment(photoId: number, name: string, path: string, time: number): Promise<boolean> {
    const photo: PhotoRecord | null = this.findPhoto(photoId);
    if (photo === null) {
      return false;
    }
    photo.attachments.push(new PhotoAttachment(name, path, time));
    const idx: number = photo.attachments.length - 1;
    const gpkgPath: string = this.currentProjectPath;
    let data: ArrayBuffer | null = null;
    try {
      const st = fs.statSync(path);
      const buf: ArrayBuffer = new ArrayBuffer(st.size);
      const f = fs.openSync(path, fs.OpenMode.READ_ONLY);
      try {
        fs.readSync(f.fd, buf);
      } finally {
        fs.closeSync(f);
      }
      data = buf;
    } catch (e) {
      AppLog.e(`${TAG} addPhotoAttachment: 读取照片失败 ${path}`, e);
    }
    if (data === null) {
      return false;
    }
    const okBlob: boolean = await GpkgDml.addPhotoAttachment(gpkgPath, photoId, idx, data);
    const arr: Object[] = [];
    for (let i = 0; i < photo.attachments.length; i++) {
      arr.push(photo.attachments[i].toJsonObject());
    }
    const o: Record<string, Object | null> = {
      'attachments': arr,
      'photo_path': photo.photoPath,
    };
    const okCols: boolean = await GpkgDml.updatePhoto(gpkgPath, photoId, JSON.stringify(o));
    if (!okBlob || !okCols) {
      AppLog.e(`${TAG} addPhotoAttachment: 落库失败 photoId=${photoId} idx=${idx} blob=${okBlob} cols=${okCols}`);
      return false;
    }
    try {
      fs.unlinkSync(path);
    } catch (e) {
      AppLog.w(`${TAG} addPhotoAttachment: 源文件删除失败 ${path}`);
    }
    return true;
  }

  async removePhoto(id: number): Promise<void> {
    const p: Project | null = this.cur;
    if (p === null) {
      return;
    }
    for (let i = 0; i < p.photos.length; i++) {
      if (p.photos[i].id === id) {
        p.photos.splice(i, 1);
        await GpkgDml.deletePhoto(this.currentProjectPath, id);
        return;
      }
    }
  }

  /** 拍照点位稀疏列更新（name/groupId/visible 单键包，对齐 updatePhotoColumns 可空语义） */
  private async pushPhotoColumns(id: number, o: Record<string, Object | null>): Promise<void> {
    const ok: boolean = await GpkgDml.updatePhoto(this.currentProjectPath, id, JSON.stringify(o));
    if (!ok) {
      AppLog.e(`${TAG} pushPhotoColumns: 增量更新失败 id=${id}`);
    }
  }

  async updatePhotoName(id: number, name: string): Promise<void> {
    const ph: PhotoRecord | null = this.findPhoto(id);
    if (ph !== null) {
      ph.name = name;
      const o: Record<string, Object | null> = { 'name': name };
      await this.pushPhotoColumns(id, o);
    }
  }

  async updatePhotoGroup(id: number, groupId: number): Promise<void> {
    const ph: PhotoRecord | null = this.findPhoto(id);
    if (ph !== null) {
      ph.groupId = groupId;
      const o: Record<string, Object | null> = { 'groupId': groupId };
      await this.pushPhotoColumns(id, o);
    }
  }

  async updatePhotoVisible(id: number, visible: boolean): Promise<void> {
    const ph: PhotoRecord | null = this.findPhoto(id);
    if (ph !== null) {
      ph.visible = visible;
      const o: Record<string, Object | null> = { 'visible': visible };
      await this.pushPhotoColumns(id, o);
    }
  }

  // ── 拍照分组 ──

  listGroups(): MediaGroupRecord[] {
    const p: Project | null = this.cur;
    return p === null ? [] : p.mediaGroups;
  }

  findGroupByName(name: string): MediaGroupRecord | null {
    const p: Project | null = this.cur;
    if (p === null) {
      return null;
    }
    for (let i = 0; i < p.mediaGroups.length; i++) {
      if (p.mediaGroups[i].name === name) {
        return p.mediaGroups[i];
      }
    }
    return null;
  }

  async addGroup(name: string, createdTime: number): Promise<number> {
    const p: Project | null = this.cur;
    if (p === null) {
      return -1;
    }
    const g: MediaGroupRecord = new MediaGroupRecord();
    g.id = ProjectManager.nextId(p.mediaGroups.map((it: MediaGroupRecord): number => it.id));
    g.name = name;
    g.createdTime = createdTime;
    p.mediaGroups.push(g);
    const ok: boolean = await GpkgDml.insertGroup(this.currentProjectPath, g.toJson());
    if (!ok) {
      AppLog.e(`${TAG} addGroup: 增量插入失败 ${name}`);
    }
    return g.id;
  }

  async renameGroup(id: number, name: string): Promise<void> {
    const p: Project | null = this.cur;
    if (p === null) {
      return;
    }
    for (let i = 0; i < p.mediaGroups.length; i++) {
      if (p.mediaGroups[i].id === id) {
        p.mediaGroups[i].name = name;
        const o: Record<string, Object | null> = { 'id': id, 'name': name };
        await GpkgDml.updateGroup(this.currentProjectPath, JSON.stringify(o));
        return;
      }
    }
  }

  /** 删除分组：组内点位不删除，移到未分组 */
  async removeGroup(id: number): Promise<void> {
    const p: Project | null = this.cur;
    if (p === null) {
      return;
    }
    for (let i = 0; i < p.mediaGroups.length; i++) {
      if (p.mediaGroups[i].id === id) {
        p.mediaGroups.splice(i, 1);
        for (let j = 0; j < p.photos.length; j++) {
          if (p.photos[j].groupId === id) {
            p.photos[j].groupId = PhotoRecord.UNGROUPED_ID;
          }
        }
        await GpkgDml.deleteGroup(this.currentProjectPath, id);
        return;
      }
    }
  }

  /** 批量设置分组内全部点位可见性（组开关直接作用于组内各点位） */
  async setGroupPhotosVisible(groupId: number, visible: boolean): Promise<void> {
    const p: Project | null = this.cur;
    if (p === null) {
      return;
    }
    let changed: boolean = false;
    for (let i = 0; i < p.photos.length; i++) {
      if (p.photos[i].groupId === groupId && p.photos[i].visible !== visible) {
        p.photos[i].visible = visible;
        changed = true;
      }
    }
    if (changed) {
      await GpkgDml.setGroupPhotosVisible(this.currentProjectPath, groupId, visible);
    }
  }

  // ── 样地调查 ──

  findSurveyPlot(id: number): SurveyPlot | null {
    const p: Project | null = this.cur;
    if (p === null) {
      return null;
    }
    for (let i = 0; i < p.surveyPlots.length; i++) {
      if (p.surveyPlots[i].id === id) {
        return p.surveyPlots[i];
      }
    }
    return null;
  }

  findSurveyPlots(sourcePath: string, sourceFid: number): SurveyPlot[] {
    const p: Project | null = this.cur;
    if (p === null) {
      return [];
    }
    const out: SurveyPlot[] = [];
    for (let i = 0; i < p.surveyPlots.length; i++) {
      const s: SurveyPlot = p.surveyPlots[i];
      if (s.sourcePath === sourcePath && s.sourceFid === sourceFid) {
        out.push(s);
      }
    }
    out.sort((a: SurveyPlot, b: SurveyPlot): number => a.plotNo - b.plotNo);
    return out;
  }

  /** 获取下一个样地编号（同小班内最大编号 +1） */
  nextSurveyPlotNo(sourcePath: string, sourceFid: number): number {
    const plots: SurveyPlot[] = this.findSurveyPlots(sourcePath, sourceFid);
    let max: number = 0;
    for (let i = 0; i < plots.length; i++) {
      if (plots[i].plotNo > max) {
        max = plots[i].plotNo;
      }
    }
    return max + 1;
  }

  /**
   * 保存样地（新增或更新）：id<=0 分配新 id 插入，否则按 id 原位更新（INSERT OR REPLACE 增量落盘）。
   * 返回保存后的样地（含 id），无当前工程返回 null。
   */
  async saveSurveyPlot(plot: SurveyPlot): Promise<SurveyPlot | null> {
    const p: Project | null = this.cur;
    if (p === null) {
      return null;
    }
    const now: number = Date.now();
    plot.updatedAt = now;
    if (plot.id <= 0) {
      plot.id = ProjectManager.nextId(p.surveyPlots.map((s: SurveyPlot): number => s.id));
      if (plot.createdAt <= 0) {
        plot.createdAt = now;
      }
      // 取号冲突复核：两个未保存草稿可能在表单装载时取到同一编号，插入前重排
      if (plot.plotNo > 0) {
        let conflict: boolean = false;
        for (let i = 0; i < p.surveyPlots.length; i++) {
          const s: SurveyPlot = p.surveyPlots[i];
          if (s.sourcePath === plot.sourcePath && s.sourceFid === plot.sourceFid && s.plotNo === plot.plotNo) {
            conflict = true;
            break;
          }
        }
        if (conflict) {
          plot.plotNo = this.nextSurveyPlotNo(plot.sourcePath, plot.sourceFid);
        }
      }
      p.surveyPlots.push(plot);
    } else {
      let found: boolean = false;
      for (let i = 0; i < p.surveyPlots.length; i++) {
        if (p.surveyPlots[i].id === plot.id) {
          found = true;
          break;
        }
      }
      if (!found) {
        p.surveyPlots.push(plot);
      }
    }
    const ok: boolean = await GpkgDml.upsertSurveyPlot(this.currentProjectPath, plot.toJson());
    if (!ok) {
      AppLog.e(`${TAG} saveSurveyPlot: 增量落盘失败 id=${plot.id}`);
    }
    return plot;
  }

  /** 删除样地（内存移除 + 增量 DeleteFeature） */
  async removeSurveyPlot(id: number): Promise<void> {
    const p: Project | null = this.cur;
    if (p === null) {
      return;
    }
    for (let i = 0; i < p.surveyPlots.length; i++) {
      if (p.surveyPlots[i].id === id) {
        p.surveyPlots.splice(i, 1);
        await GpkgDml.deleteSurveyPlot(this.currentProjectPath, id);
        return;
      }
    }
  }

  // ── 内部工具 ──

  /**
   * 工程打开/新建后的就绪流程（幂等）：
   *  1. schema 检查——老库缺列时整文件重建升级；
   *  2. 移除 RTree 触发器/索引表（GDAL 专属 ST_* 函数纯 SQLite 不可执行）并补建附件 BLOB 附加表；
   *  3. 照片文件清扫——BLOB 已入库的磁盘原件退役，BLOB 缺失的从文件补收后删原件。
   */
  private async ensureProjectReady(project: Project, filePath: string): Promise<void> {
    if (!(await GpkgDml.schemaCurrent(filePath))) {
      const ok: boolean = await this.writeProjectFile(project, filePath);
      AppLog.i(`${TAG} ensureProjectReady: 老库 schema 升级重建 ${filePath} -> ${ok}`);
    }
    await GpkgDml.prepareSchema(filePath);
    await GpkgDml.sweepPhotoFiles(filePath, AppDirs.mediaDir());
  }

  /** 整文件重建（GDAL）：仅用于新建工程文件、老库 schema 升级 */
  private async writeProjectFile(project: Project, filePath: string): Promise<boolean> {
    project.updateTime = Date.now();
    const ok: boolean = await GpkgDml.writeGeoPackage(filePath, project.toJson());
    if (!ok) {
      AppLog.e(`${TAG} writeProjectFile: ${filePath} 写入失败`);
    }
    return ok;
  }

  private async rememberCurrent(openedPath: string = ''): Promise<void> {
    let path: string = openedPath;
    if (path.length === 0) {
      const p: Project | null = this.cur;
      if (p !== null) {
        path = this.filePathFor(p.name);
      }
    }
    if (path.length > 0) {
      await Prefs.putString(this.ctx, PREFS_NAME, KEY_LAST_PROJECT, path);
    }
  }

  /** 工程名 → gpkg 文件绝对路径（文件名安全化与 Android sanitizeFileName 同口径） */
  private filePathFor(name: string): string {
    return `${this.projectsDir}/${ProjectManager.sanitizeFileName(name)}.gpkg`;
  }

  /** syncMeta 的 JSON 包：{"meta":{...},"layerRefs":[...]}（键名约定见 GpkgDml 文件头） */
  private static buildMetaJson(project: Project): string {
    const meta: Record<string, Object> = {
      'name': project.name,
      'description': project.description,
      'srs': project.srs,
      'createTime': project.createTime,
      'updateTime': project.updateTime,
    };
    const layers: string[] = [];
    for (let i = 0; i < project.layerRefs.length; i++) {
      layers.push(project.layerRefs[i]);
    }
    const o: Record<string, Object> = {
      'meta': meta,
      'layerRefs': layers,
    };
    return JSON.stringify(o);
  }

  /** 文件名安全化：非法字符 → '_'（与 Android sanitizeFileName 逐字一致，不做 trim/空名兜底） */
  static sanitizeFileName(name: string): string {
    return name.replace(/[\\/:*?"<>|]/g, '_');
  }

  /** 文件名（含路径）→ 去目录去扩展名的基础名 */
  private static baseNameNoExt(filePath: string): string {
    const slash: number = Math.max(filePath.lastIndexOf('/'), filePath.lastIndexOf('\\'));
    const name: string = slash >= 0 ? filePath.substring(slash + 1) : filePath;
    const dot: number = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  static formatFileSize(bytes: number): string {
    if (bytes < 1024) {
      return `${bytes} B`;
    }
    if (bytes < 1024 * 1024) {
      return `${(bytes / 1024.0).toFixed(1)} KB`;
    }
    return `${(bytes / (1024.0 * 1024)).toFixed(1)} MB`;
  }

  /** 工程记录 date 字段格式："yyyy-MM-dd HH:mm:ss"（人读友好，QGIS 中直接可读） */
  static formatTime(millis: number): string {
    if (millis <= 0) {
      return '';
    }
    const d = new Date(millis);
    const pad = (n: number): string => n < 10 ? `0${n}` : `${n}`;
    return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`
      + ` ${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
  }

  /** formatTime 逆运算；解析失败回当前时间（与 Android parseTime 同口径） */
  static parseTime(text: string): number {
    const m = /^(\d{4})-(\d{1,2})-(\d{1,2})\s+(\d{1,2}):(\d{1,2}):(\d{1,2})/.exec(text);
    if (m !== null) {
      const t: number = new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3]),
        Number(m[4]), Number(m[5]), Number(m[6])).getTime();
      if (t > 0) {
        return t;
      }
    }
    return Date.now();
  }

  /** ARGB Int → "#RRGGBB"（去 alpha，工程交换格式不含透明度） */
  static colorToHex(color: number): string {
    const hex: string = (color & 0xFFFFFF).toString(16).toUpperCase();
    return `#${'000000'.substring(hex.length)}${hex}`;
  }

  /** "#RRGGBB"/"#AARRGGBB" → 无符号 ARGB Int，解析失败回默认 */
  static parseColor(hex: string, def: number): number {
    if (hex.length === 0) {
      return def;
    }
    try {
      let s: string = hex.startsWith('#') ? hex.substring(1) : hex;
      if (s.length === 6) {
        s = `FF${s}`;
      }
      if (s.length !== 8) {
        return def;
      }
      return parseInt(s, 16) >>> 0;
    } catch (e) {
      return def;
    }
  }

  /** 测量结果文本（导出附属信息，几何为准）：距离=累计长度，面积=总面积，点=坐标；pts 内存序 [lat,lon] */
  static measureResultText(type: string, pts: number[][]): string {
    try {
      if (type === MeasureRecord.TYPE_AREA) {
        const ring: LatLng[] = [];
        for (let i = 0; i < pts.length; i++) {
          ring.push(new LatLng(pts[i][0], pts[i][1]));
        }
        return GeoCalc.formatArea(GeoCalc.polygonAreaSquareMeters(ring));
      }
      if (type === MeasureRecord.TYPE_POINT) {
        return pts.length > 0 ? `${pts[0][0].toFixed(6)}, ${pts[0][1].toFixed(6)}` : '';
      }
      let total: number = 0;
      for (let i = 1; i < pts.length; i++) {
        total += GeoCalc.distanceMeters(pts[i - 1][0], pts[i - 1][1], pts[i][0], pts[i][1]);
      }
      return GeoCalc.formatDistance(total);
    } catch (e) {
      return '';
    }
  }

  /** 未分组标识转发（便于调用方不引模型也能用，对齐 Android PhotoRecord.UNGROUPED_ID） */
  static readonly UNGROUPED_ID: number = PhotoRecord.UNGROUPED_ID;
}
