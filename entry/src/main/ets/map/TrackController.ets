// TrackController.ets —— 轨迹采集控制器（对应 Android ui.map.TrackCaptureController，0.4.0.4 工程版）。
//
// 开始/暂停/继续/停止记录、定位追加点、草稿文件实时落盘与进程重启恢复、live 红线实时渲染。
// 采集态 capturing 由宿主组合进 BusinessOverlayManager.rebuild 门控。
//
// 与旧版差异：草稿不再走 map.db 草稿表，改 <projectsDir>/.track_draft.json
// （{name,createdTime,points:[[lat,lon,alt],...]}，tmp+rename 原子重写，串行链保序），
// 停表定型直写当前工程（ProjectManager.addTrack + saveNow 后再删草稿，防防抖窗口被杀丢整条轨迹）。
// 后台定位保活（Android BackgroundLocationController）为批次D 项，鸿蒙侧暂未接线。
//
// ArkTS 主线程即单线程事件循环，无需 Executor；但草稿重写仍须「按提交顺序串行」
// （否则乱序重写会让草稿点序与内存不一致），故用 Promise 链当作单线程队列。

import fs from '@ohos.file.fs';
import { util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import { NativeMapView, VectorStyle } from '@zys/globecore';
import { AppLog } from '../common/AppLog';
import { AppDirs } from '../common/AppDirs';
import { GeoCalc, LatLng } from '../common/GeoCalc';
import { Ui } from '../common/Ui';
import { LocationManager, LocationPoint } from '../location/LocationManager';
import { ProjectManager } from '../project/ProjectManager';
import { TrackRecord } from '../project/ProjectModels';
import { BusinessOverlayManager } from './BusinessOverlayManager';
import { CameraNavigator } from './CameraNavigator';
import { MapStyle } from './MapStyle';

/** 采集态点串约定：[lat, lon, alt] */
type Point = number[];

const TAG: string = 'TrackCapture';
/** 轨迹草稿文件名（崩溃恢复用，存于工程目录下，隐藏文件不参与工程列表） */
const DRAFT_FILE_NAME: string = '.track_draft.json';

export class TrackController {
  private readonly view: NativeMapView;
  private readonly ctx: common.Context;
  private readonly navigator: CameraNavigator;
  /** 采集态变化（记录/暂停）由宿主刷新工具条 */
  onStateChanged: (recording: boolean, paused: boolean) => void = (): void => {};
  rebuildOverlays: () => void = (): void => {};

  private recording: boolean = false;
  private paused: boolean = false;
  private activePoints: Point[] = [];
  private liveIndex: number = -1;
  private draftCreatedTime: number = 0;
  /** 草稿重写串行链（等价 Android 单线程 Executor） */
  private chain: Promise<void> = Promise.resolve();

  constructor(view: NativeMapView, ctx: common.Context, navigator: CameraNavigator) {
    this.view = view;
    this.ctx = ctx;
    this.navigator = navigator;
  }

  /** 轨迹记录进行中：宿主据此组合 capturing，保护 live 红线层不被 rebuild 清除 */
  capturing(): boolean {
    return this.recording;
  }

  isRecording(): boolean {
    return this.recording;
  }

  isPaused(): boolean {
    return this.paused;
  }

  pointCount(): number {
    return this.activePoints.length;
  }

  /** 轨迹按键入口：记录中提示；无历史轨迹直接开始；有历史轨迹弹菜单（开始轨迹 / 管理） */
  async onTrackButton(manageAction: () => void): Promise<void> {
    if (this.recording) {
      Ui.toast('轨迹记录进行中');
      return;
    }
    if (!ProjectManager.get(this.ctx).hasTracks()) {
      this.start();
      return;
    }
    const which: number = await Ui.items('轨迹', ['开始轨迹', '管理']);
    if (which === 0) {
      this.start();
    } else if (which === 1) {
      manageAction();
    }
  }

  /**
   * 开始轨迹记录：定位检查后清空活动点、建 live 红线层、置记录态（capturing 转 true）、
   * 建立草稿文件并落起点。
   */
  start(): void {
    if (this.recording) {
      Ui.toast('轨迹记录进行中');
      return;
    }
    const lm: LocationManager = LocationManager.getInstance();
    if (lm.getLastLocation() === null && !lm.isLocating()) {
      Ui.toast('尚未获取到定位信息，请先开启定位');
      return;
    }
    this.activePoints = [];
    this.recording = true;
    this.paused = false;
    this.ensureLiveLayer();
    this.draftCreatedTime = Date.now();
    this.writeDraft(); // 建立草稿文件（进程崩溃可恢复）
    const last: LocationPoint | null = lm.getLastLocation();
    if (last !== null) {
      this.appendPoint(last.latitude, last.longitude, last.altitude);
    }
    this.pushState();
    Ui.toast('开始记录轨迹');
  }

  /** 暂停轨迹记录：置暂停态（定位监听据此停止追加）并刷新控件 */
  pause(): void {
    if (!this.recording || this.paused) {
      return;
    }
    this.paused = true;
    this.pushState();
    Ui.toast('轨迹记录已暂停');
  }

  /** 继续轨迹记录：解除暂停并以当前定位为恢复后首点 */
  resume(): void {
    if (!this.recording || !this.paused) {
      return;
    }
    this.paused = false;
    const last: LocationPoint | null = LocationManager.getInstance().getLastLocation();
    if (last !== null) {
      this.appendPoint(last.latitude, last.longitude, last.altitude);
    }
    this.pushState();
    Ui.toast('轨迹记录继续');
  }

  /**
   * 停止轨迹记录：采集点已实时写入草稿文件，此处把整串定型进当前工程并删除草稿；点数不足则只删草稿。
   * 先同步拆 live 层并置 recording=false（capturing 转 false），落库定型在串行链完成后触发重建。
   */
  stop(): void {
    if (!this.recording) {
      return;
    }
    this.recording = false;
    this.paused = false;
    const created: number = this.draftCreatedTime;
    this.draftCreatedTime = 0;
    const insufficient: boolean = this.activePoints.length < 2;
    const points: Point[] = [];
    for (let i = 0; i < this.activePoints.length; i++) {
      points.push(this.activePoints[i]);
    }
    this.pushState();
    this.clearActiveTrack();

    if (insufficient) {
      this.deleteDraft();
      this.rebuildOverlays();
      Ui.toast('轨迹点不足，未生成轨迹线');
      return;
    }
    const name: string = TrackController.nameOf(created);
    const draftFile: string = this.draftPath();
    this.enqueue(async (): Promise<void> => {
      const t0: number = Date.now();
      const pm: ProjectManager = ProjectManager.get(this.ctx);
      await pm.addTrack(name, created, points);
      // 立即同步落盘后再删草稿：窗口内进程被杀不丢整条轨迹
      await pm.saveNow();
      AppDirs.removeFile(draftFile);
      AppLog.i(`${TAG} 轨迹入库耗时 addTrack+saveNow=${Date.now() - t0}ms points=${points.length}`);
    });
    this.enqueue(async (): Promise<void> => {
      this.rebuildOverlays();
      Ui.toast('轨迹记录已停止');
    });
  }

  /**
   * 定位更新转接：记录中且未暂停时把定位点追加为活动轨迹点
   * （宿主把 LocationController 的 location 回调接线到此）。
   */
  onLocation(lat: number, lon: number, alt: number): void {
    if (this.recording && !this.paused) {
      this.appendPoint(lat, lon, alt);
    }
  }

  /**
   * 追加轨迹点：按最小间距过滤 GPS 抖动，实时重写草稿文件（串行链），并重绘 live 红线。
   */
  private appendPoint(lat: number, lon: number, alt: number): void {
    const n: number = this.activePoints.length;
    if (n > 0) {
      const last: Point = this.activePoints[n - 1];
      if (GeoCalc.distanceMeters(last[0], last[1], lat, lon) < MapStyle.MIN_TRACK_POINT_DISTANCE_METERS) {
        return;
      }
    }
    this.activePoints.push([lat, lon, Number.isNaN(alt) ? 0 : alt]);
    this.writeDraft();
    this.renderLive();
  }

  // ── 草稿文件（崩溃恢复）：<projectsDir>/.track_draft.json，{name,createdTime,points:[[lat,lon,alt],...]} ──

  private draftPath(): string {
    return `${ProjectManager.get(this.ctx).projectsDir}/${DRAFT_FILE_NAME}`;
  }

  /** 把当前活动点串整体重写进草稿文件（串行链保序；先写临时文件再 rename，防半写文件） */
  private writeDraft(): void {
    const name: string = TrackController.nameOf(this.draftCreatedTime);
    const created: number = this.draftCreatedTime;
    const snapshot: Point[] = [];
    for (let i = 0; i < this.activePoints.length; i++) {
      snapshot.push(this.activePoints[i]);
    }
    const file: string = this.draftPath();
    this.enqueue(async (): Promise<void> => {
      const pts: number[][] = [];
      for (let i = 0; i < snapshot.length; i++) {
        const p: Point = snapshot[i];
        pts.push([p[0], p[1], p.length > 2 ? p[2] : 0]);
      }
      const o: Record<string, Object> = {
        'name': name,
        'createdTime': created,
        'points': pts,
      };
      TrackController.writeFileAtomic(file, JSON.stringify(o));
    });
  }

  /** 删除草稿文件（定型入库或丢弃时调用，串行链保证在全部草稿重写之后执行） */
  private deleteDraft(): void {
    const file: string = this.draftPath();
    this.enqueue(async (): Promise<void> => {
      AppDirs.removeFile(file);
    });
  }

  /** 原子写文本：先写 .tmp 再 rename，防半写（与 gpkg 整写同策略） */
  private static writeFileAtomic(path: string, content: string): void {
    const tmp: string = `${path}.tmp`;
    try {
      const f = fs.openSync(tmp, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(f.fd, content);
      } finally {
        fs.closeSync(f);
      }
      try {
        fs.renameSync(tmp, path);
      } catch (e) {
        AppDirs.removeFile(path);
        fs.renameSync(tmp, path);
      }
    } catch (e) {
      AppLog.e(`${TAG} 草稿写入失败 ${path}`, e);
    }
  }

  /** 读文件全部文本（utf-8） */
  private static readText(path: string): string {
    const f = fs.openSync(path, fs.OpenMode.READ_ONLY);
    try {
      const size: number = fs.statSync(path).size;
      const buf: ArrayBuffer = new ArrayBuffer(Math.max(1, size));
      const readLen: number = fs.readSync(f.fd, buf);
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
      return decoder.decodeToString(new Uint8Array(buf, 0, readLen));
    } finally {
      fs.closeSync(f);
    }
  }

  /** 实时重绘活动轨迹 live 红线层（≥2 点才成线，覆盖式更新） */
  private renderLive(): void {
    const idx: number = this.liveIndex;
    if (idx < 0 || this.activePoints.length < 2) {
      return;
    }
    this.view.updateOverlayLines(idx,
      BusinessOverlayManager.flattenLonLat(this.activePoints), [this.activePoints.length], [0]);
  }

  /** 确保活动轨迹 live 红线层已建（红色加粗，无标注），幂等 */
  private ensureLiveLayer(): void {
    if (this.liveIndex >= 0) {
      return;
    }
    const style: VectorStyle = MapStyle.lineStyle(MapStyle.TRACK_ACTIVE_COLOR,
      MapStyle.TRACK_ACTIVE_WIDTH);
    style.pointColor = MapStyle.TRACK_ACTIVE_COLOR;
    style.pointRadiusDp = MapStyle.MEASURE_POINT_RADIUS_DP;
    this.liveIndex = this.view.addOverlayLayer(style);
  }

  /** 清理活动轨迹：清活动点 + 拆 live 层（墓碑，GL 线程下帧回收） */
  private clearActiveTrack(): void {
    this.activePoints = [];
    if (this.liveIndex >= 0) {
      this.view.removeOverlayLayer(this.liveIndex);
      this.liveIndex = -1;
    }
  }

  /**
   * 恢复未结束的草稿轨迹（进程被回收/异常退出后）：读回草稿文件中的采集点重建 live 红线并恢复记录态。
   * 空草稿（刚开始就中断）直接清理。在宿主装配叠加层后调用。
   */
  async restoreDraftTrack(): Promise<boolean> {
    const file: string = this.draftPath();
    if (!AppDirs.exists(file)) {
      return false;
    }
    let jsonText: string = '';
    try {
      jsonText = TrackController.readText(file);
    } catch (e) {
      AppLog.w(`${TAG} 草稿读取失败 ${file}`);
      return false;
    }
    let created: number = Date.now();
    const pts: Point[] = [];
    try {
      const o: Record<string, Object | null> = JSON.parse(jsonText) as Record<string, Object | null>;
      const c: Object | undefined | null = o['createdTime'];
      if (typeof c === 'number') {
        created = c as number;
      }
      const arr: Object | undefined | null = o['points'];
      if (Array.isArray(arr)) {
        const items: Object[] = arr as Object[];
        for (let i = 0; i < items.length; i++) {
          const p: Object | undefined | null = items[i];
          if (!Array.isArray(p)) {
            continue;
          }
          const pa: Object[] = p as Object[];
          if (pa.length < 2 || typeof pa[0] !== 'number' || typeof pa[1] !== 'number') {
            continue;
          }
          const alt: number = pa.length > 2 && typeof pa[2] === 'number' ? pa[2] as number : 0;
          pts.push([pa[0] as number, pa[1] as number, alt]);
        }
      }
    } catch (e) {
      AppLog.w(`${TAG} 草稿解析失败 ${file}`);
      return false;
    }
    if (pts.length === 0) {
      AppDirs.removeFile(file);
      return false;
    }
    this.draftCreatedTime = created;
    this.activePoints = pts;
    this.recording = true;
    this.paused = false;
    this.ensureLiveLayer();
    this.renderLive();
    this.pushState();
    Ui.toastLong(`已恢复上次未完成的轨迹记录（${pts.length} 个点）`);
    return true;
  }

  private pushState(): void {
    this.onStateChanged(this.recording, this.paused);
  }

  /**
   * 串行落盘链：把任务接到链尾，前一个完成后执行下一个（等价 Android 单线程 Executor）。
   * 单任务异常只记日志，不阻断后续（否则一次写失败会永久卡死队列）。
   */
  private enqueue(task: () => Promise<void>): void {
    this.chain = this.chain.then(async (): Promise<void> => {
      try {
        await task();
      } catch (e) {
        AppLog.e(`${TAG} 落盘任务失败`, e);
      }
    });
  }

  /** 轨迹默认名称：轨迹 yyyy-MM-dd HH:mm:ss（取采集起始时间） */
  static nameOf(time: number): string {
    return Ui.stampName('轨迹', time);
  }

  /** 轨迹量算文本：总长 + 点数 */
  static geometryText(record: TrackRecord): string {
    const degrees: LatLng[] = [];
    for (let i = 0; i < record.points.length; i++) {
      const p: Point = record.points[i];
      degrees.push(new LatLng(p[0], p[1]));
    }
    return `距离: ${GeoCalc.formatDistance(GeoCalc.polylineLengthMeters(degrees))}`
      + `　·　${record.points.length}个点`;
  }

  /** 缩放至轨迹：按轨迹点四至计算中心与合适高度 */
  zoomToTrack(track: TrackRecord): void {
    if (track.points.length === 0) {
      return;
    }
    let minLat: number = Number.MAX_VALUE;
    let maxLat: number = -Number.MAX_VALUE;
    let minLon: number = Number.MAX_VALUE;
    let maxLon: number = -Number.MAX_VALUE;
    for (let i = 0; i < track.points.length; i++) {
      const p: Point = track.points[i];
      minLat = Math.min(minLat, p[0]);
      maxLat = Math.max(maxLat, p[0]);
      minLon = Math.min(minLon, p[1]);
      maxLon = Math.max(maxLon, p[1]);
    }
    this.navigator.zoomToExtent(minLon, minLat, maxLon, maxLat);
  }
}
