// TrackController.ets —— 轨迹采集控制器（对应 Android ui.map.TrackCaptureController）。
//
// 开始/暂停/继续/停止记录、定位追加点、草稿实时落库与进程重启恢复、live 红线实时渲染，
// 以及轨迹详情/删除。采集态 capturing 由宿主组合进 BusinessOverlayManager.rebuild 门控。
//
// 与 Android 的差异：ArkTS 主线程即单线程事件循环，无需 Executor；但落库仍须「按提交顺序串行」
// （否则乱序写入会让 seq 与点序不一致），故用 Promise 链当作单线程队列，链尾再触发重建。

import { common } from '@kit.AbilityKit';
import { NativeMapView, VectorStyle } from '@zys/globecore';
import { AppLog } from '../common/AppLog';
import { GeoCalc, LatLng } from '../common/GeoCalc';
import { Ui } from '../common/Ui';
import { LocationManager, LocationPoint } from '../location/LocationManager';
import { MapDataStore, TrackRecord } from '../db/MapDataStore';
import { BusinessOverlayManager } from './BusinessOverlayManager';
import { CameraNavigator } from './CameraNavigator';
import { MapStyle } from './MapStyle';

/** 采集态点串约定：[lat, lon, alt] */
type Point = number[];

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
  private draftId: number = -1;
  private draftCreatedTime: number = 0;
  /** 落库串行链（等价 Android 单线程 Executor） */
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
    const store: MapDataStore = await MapDataStore.getInstance(this.ctx);
    const tracks: TrackRecord[] = await store.loadTracks();
    if (tracks.length === 0) {
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
   * 建立草稿轨迹并落起点。
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
    const created: number = this.draftCreatedTime;
    this.enqueue(async (): Promise<void> => {
      const store: MapDataStore = await MapDataStore.getInstance(this.ctx);
      this.draftId = await store.beginDraftTrack(TrackController.nameOf(created), created);
    });
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
   * 停止轨迹记录：采集点已实时落库，此处结束草稿（写最终名称 + 清 recording 标记）；点数不足则删草稿。
   * 先同步拆 live 层并置 recording=false（capturing 转 false），落库定型在串行链完成后触发重建。
   */
  stop(): void {
    if (!this.recording) {
      return;
    }
    this.recording = false;
    this.paused = false;
    const draftId: number = this.draftId;
    this.draftId = -1;
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
      if (draftId > 0) {
        this.enqueue(async (): Promise<void> => {
          const store: MapDataStore = await MapDataStore.getInstance(this.ctx);
          await store.deleteTrack(draftId);
        });
      }
      this.rebuildOverlays();
      Ui.toast('轨迹点不足，未生成轨迹线');
      return;
    }
    const name: string = TrackController.nameOf(created);
    if (draftId > 0) {
      // 与待写入的采集点同一串行链，定型后再重建，保证渲染含全部点
      this.enqueue(async (): Promise<void> => {
        const store: MapDataStore = await MapDataStore.getInstance(this.ctx);
        await store.finishDraftTrack(draftId, name);
      });
    } else {
      // 草稿建立失败的兜底：整串一次性保存
      this.enqueue(async (): Promise<void> => {
        const store: MapDataStore = await MapDataStore.getInstance(this.ctx);
        await store.addTrack(name, created, points);
      });
    }
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
   * 追加轨迹点：按最小间距过滤 GPS 抖动，实时写入草稿（串行链），并重绘 live 红线。
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
    const draftId: number = this.draftId;
    const seq: number = this.activePoints.length - 1;
    if (draftId > 0) {
      this.enqueue(async (): Promise<void> => {
        const store: MapDataStore = await MapDataStore.getInstance(this.ctx);
        await store.appendTrackPoint(draftId, seq, lat, lon, Number.isNaN(alt) ? 0 : alt);
      });
    }
    this.renderLive();
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
   * 恢复未结束的草稿轨迹（进程被回收/异常退出后）：读回已落库采集点重建 live 红线并恢复记录态。
   * 空草稿（刚开始就中断）直接清理。在宿主装配叠加层后调用。
   */
  async restoreDraftTrack(): Promise<boolean> {
    const store: MapDataStore = await MapDataStore.getInstance(this.ctx);
    const draft: TrackRecord | undefined = await store.loadDraftTrack();
    if (draft === undefined) {
      return false;
    }
    if (draft.points.length === 0) {
      await store.deleteTrack(draft.id);
      return false;
    }
    this.draftId = draft.id;
    this.draftCreatedTime = draft.createdTime;
    this.activePoints = [];
    for (let i = 0; i < draft.points.length; i++) {
      const p: Point = draft.points[i];
      this.activePoints.push([p[0], p[1], p.length > 2 ? p[2] : 0]);
    }
    this.recording = true;
    this.paused = false;
    this.ensureLiveLayer();
    this.renderLive();
    this.pushState();
    Ui.toastLong(`已恢复上次未完成的轨迹记录（${this.activePoints.length} 个点）`);
    return true;
  }

  private pushState(): void {
    this.onStateChanged(this.recording, this.paused);
  }

  /**
   * 串行落库链：把任务接到链尾，前一个完成后执行下一个（等价 Android 单线程 Executor）。
   * 单任务异常只记日志，不阻断后续（否则一次写失败会永久卡死队列）。
   */
  private enqueue(task: () => Promise<void>): void {
    this.chain = this.chain.then(async (): Promise<void> => {
      try {
        await task();
      } catch (e) {
        AppLog.e('轨迹落库任务失败', e);
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
