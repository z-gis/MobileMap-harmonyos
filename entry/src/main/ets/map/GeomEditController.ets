// GeomEditController.ets —— gdb/shp 几何编辑模式（分割/删除/合并）。
//
// 长按圆菜单「编辑」命中 gdb/shp 文件要素时经 enterAt 进入：选中高亮保持，宿主隐藏无关键、
// 底部出编辑工具条。三个操作全部落 native（bridge/vector_io.cpp，写前自动整份备份）：
//  · 分割：SPLIT_LINE 子模式点击地图画折线（live 线层 + 测点圆点层，口径同测量采集），
//    「完成」把折线作 WGS84 WKT 交 splitPolygonByLine（首末段自动延长贯穿、面积闭合门禁）；
//  · 删除：确认对话框后 deleteVectorFeature（shp 为标记删除，体积不减属预期）；
//  · 合并：MERGE_PICK 子模式点击同图层另一面图斑，确认后 mergeVectorFeatures（保留当前 FID/属性）。
// 操作成功后宿主层就地换层重载（reloadVectorLayer）并重画选中高亮；编辑态单击/长按由
// FeaturePickController 经 PickRouter.isGeomEditing/handleEditTap 整体屏蔽（不弹详情、不再弹圆菜单）。
// gpkg 工程数据不走本控制器（业务七表另有 DML 通道）。

import { common } from '@kit.AbilityKit';
import fs from '@ohos.file.fs';
import { FeatureGeometry, NativeMapView, PickResult, Position, VectorStyle } from '@zys/globecore';
import { AppLog } from '../common/AppLog';
import { Ui } from '../common/Ui';
import { LayerInfo } from '../doc/DocModels';
import { GdalVectorReader, GeomEditResult } from '../vector/GdalVectorReader';
import { VectorFormats } from '../vector/VectorFormats';
import { BusinessOverlayManager } from './BusinessOverlayManager';
import { FeaturePickController } from './FeaturePickController';
import { MapLayerController } from './MapLayerController';
import { MapStyle } from './MapStyle';

const TAG: string = 'GeomEditController';

/** 几何编辑阶段：NONE 未编辑 / EDIT 工具条待命 / SPLIT_LINE 画分割线 / MERGE_PICK 选合并目标 */
export enum GeomEditPhase {
  NONE = 0,
  EDIT = 1,
  SPLIT_LINE = 2,
  MERGE_PICK = 3,
}

/** 分割线颜色（橙，区别于测量蓝/选中黄） */
const SPLIT_LINE_COLOR: number = 0xFFFF6D00;

export class GeomEditController {
  private readonly view: NativeMapView;
  private readonly ctx: common.Context;
  private readonly layerManager: MapLayerController;
  private readonly pick: FeaturePickController;

  /** 阶段/点数变化通知宿主刷新工具条与提示（宿主随后读 pointCount/isPolygon/targetFid 回显） */
  onStateChanged: (phase: GeomEditPhase) => void = (): void => {};

  private currentPhase: GeomEditPhase = GeomEditPhase.NONE;
  private targetInfo: LayerInfo | undefined = undefined;
  private targetFidValue: number = -1;
  private targetIsPolygon: boolean = false;
  /** 分割线采集点 [lat, lon, 0]（口径同测量点串） */
  private splitPoints: number[][] = [];
  private splitLineIndex: number = -1;
  private splitMarkerIndex: number = -1;

  constructor(view: NativeMapView, ctx: common.Context, layerManager: MapLayerController,
    pick: FeaturePickController) {
    this.view = view;
    this.ctx = ctx;
    this.layerManager = layerManager;
    this.pick = pick;
  }

  phase(): GeomEditPhase {
    return this.currentPhase;
  }

  /** 编辑态整体门控（含工具条待命）：宿主据此屏蔽单击详情/长按菜单，并保护 live 层不被叠加层重建清掉 */
  capturing(): boolean {
    return this.currentPhase !== GeomEditPhase.NONE;
  }

  pointCount(): number {
    return this.splitPoints.length;
  }

  isPolygon(): boolean {
    return this.targetIsPolygon;
  }

  targetFid(): number {
    return this.targetFidValue;
  }

  /**
   * 圆菜单挂「编辑」项的判据：落点命中的是 gdb/shp 文件矢量要素（只探测，无副作用）。
   * 业务叠加（测量/轨迹/拍照/样地）与其他格式返回 false，菜单改挂「属性」走原详情分流。
   */
  editableHitAt(x: number, y: number): boolean {
    const hit: PickResult | undefined = this.view.pickVector(x, y);
    if (hit === undefined || hit.fid < 0) {
      return false;
    }
    const info: LayerInfo | undefined = this.layerManager.layerInfoByIndex(hit.layerIndex);
    if (info === undefined) {
      return false;
    }
    return VectorFormats.geomEditable(info.path ?? '');
  }

  /** 进入几何编辑：重新拾取落点 → 校验 gdb/shp → 选中高亮 → 工具条待命 */
  enterAt(x: number, y: number): void {
    const hit: PickResult | undefined = this.view.pickVector(x, y);
    if (hit === undefined || hit.fid < 0) {
      Ui.toast('落点未命中要素');
      return;
    }
    const info: LayerInfo | undefined = this.layerManager.layerInfoByIndex(hit.layerIndex);
    if (info === undefined) {
      Ui.toast('该要素不支持几何编辑');
      return;
    }
    const path: string = info.path ?? '';
    if (!VectorFormats.geomEditable(path)) {
      Ui.toast('几何编辑仅支持 gdb/shp 数据');
      return;
    }
    this.targetInfo = info;
    this.targetFidValue = hit.fid;
    this.targetIsPolygon = GdalVectorReader.geomTypeOf(path, info.layerName) === 2;
    this.pick.highlightSelectedFeature(hit.layerIndex, hit.fid, path, info.layerName);
    this.setPhase(GeomEditPhase.EDIT);
    AppLog.i(`${TAG} 进入几何编辑 path=${path} fid=${hit.fid} polygon=${this.targetIsPolygon}`);
    Ui.toast(this.targetIsPolygon ? '几何编辑：分割 / 删除 / 合并' : '几何编辑：该图层为线/点，仅支持删除');
  }

  /**
   * 编辑态单击拦截（宿主拾取分发前置）：画线子模式加点、选靶子模式拾取合并目标；
   * 工具条待命阶段单击无动作（不弹详情、不改选中）。恒返回 true 消费点击。
   */
  handleTap(x: number, y: number): boolean {
    if (this.currentPhase === GeomEditPhase.SPLIT_LINE) {
      const geo: Position | undefined = this.view.screenToGeo(x, y);
      if (geo === undefined) {
        Ui.toast('该点未命中地表，请点向地图区域');
        return true;
      }
      this.splitPoints.push([geo.latitude, geo.longitude, 0]);
      this.renderSplitLive();
      const n: number = this.splitPoints.length;
      Ui.toast(n < 2 ? '第 1 个点已画，再点一次连线' : `第 ${n} 个点，点「完成」按线分割`);
      this.notify();
      return true;
    }
    if (this.currentPhase === GeomEditPhase.MERGE_PICK) {
      this.pickMergeTarget(x, y);
      return true;
    }
    return true;
  }

  // ── 分割 ─────────────────────────────────────────────────────────

  /** 进入画分割线子模式：建 live 线层 + 测点圆点层（均 noPick，点击穿透到地图加点） */
  startSplit(): void {
    if (this.currentPhase !== GeomEditPhase.EDIT || !this.targetIsPolygon) {
      return;
    }
    this.splitPoints = [];
    const style: VectorStyle = MapStyle.defaultStyle();
    style.lineColor = SPLIT_LINE_COLOR;
    style.lineWidth = MapStyle.MEASURE_LIVE_WIDTH;
    style.pointColor = SPLIT_LINE_COLOR;
    style.pointRadiusDp = MapStyle.MEASURE_POINT_RADIUS_DP;
    style.labelField = '';
    this.splitLineIndex = this.view.addOverlayLayer(style);
    this.splitMarkerIndex = this.view.addOverlayLayer(style);
    if (this.splitLineIndex >= 0) {
      this.view.setOverlayNoPick(this.splitLineIndex, true);
    }
    if (this.splitMarkerIndex >= 0) {
      this.view.setOverlayNoPick(this.splitMarkerIndex, true);
    }
    this.setPhase(GeomEditPhase.SPLIT_LINE);
    Ui.toast('点击地图画分割线（至少 2 个点），完成后按线分割图斑');
  }

  /** 撤销上一个分割线点 */
  undoSplitPoint(): void {
    if (this.currentPhase !== GeomEditPhase.SPLIT_LINE || this.splitPoints.length === 0) {
      return;
    }
    this.splitPoints.pop();
    this.renderSplitLive();
    this.notify();
  }

  /** 完成画线并执行分割：成功回工具条待命（最大块留原 FID，重画高亮）；失败留在画线态可调整 */
  finishSplit(): void {
    if (this.currentPhase !== GeomEditPhase.SPLIT_LINE) {
      return;
    }
    if (this.splitPoints.length < 2) {
      Ui.toast('分割线至少需要两个点');
      return;
    }
    const info: LayerInfo | undefined = this.targetInfo;
    if (info === undefined) {
      return;
    }
    let wkt: string = 'LINESTRING(';
    for (let i = 0; i < this.splitPoints.length; i++) {
      if (i > 0) {
        wkt += ', ';
      }
      wkt += `${this.splitPoints[i][1]} ${this.splitPoints[i][0]}`;
    }
    wkt += ')';
    const res: GeomEditResult = GdalVectorReader.splitByLine(info.path ?? '', this.targetFidValue,
      wkt, info.layerName, this.backupDir());
    if (!res.ok) {
      Ui.toastLong(`分割失败：${res.error}`);
      return;
    }
    AppLog.i(`${TAG} 分割成功 fid=${this.targetFidValue} count=${res.count} newFids=${res.newFids}`);
    this.teardownSplitLive();
    this.setPhase(GeomEditPhase.EDIT);
    this.reloadAndRehighlight(this.targetFidValue);
    Ui.toast(`分割完成，共 ${res.count} 块`);
  }

  /** 取消画线回工具条待命（不执行分割） */
  cancelSplit(): void {
    if (this.currentPhase !== GeomEditPhase.SPLIT_LINE) {
      return;
    }
    this.teardownSplitLive();
    this.setPhase(GeomEditPhase.EDIT);
  }

  // ── 删除 ─────────────────────────────────────────────────────────

  /** 删除当前选中要素：先确认，成功后退出编辑态（要素已不存在） */
  async requestDelete(): Promise<void> {
    if (this.currentPhase !== GeomEditPhase.EDIT) {
      return;
    }
    const info: LayerInfo | undefined = this.targetInfo;
    if (info === undefined) {
      return;
    }
    const ok: boolean = await Ui.confirm('删除要素',
      `确定删除要素 #${this.targetFidValue}？删除前会自动备份数据。`, '删除');
    if (!ok || this.currentPhase !== GeomEditPhase.EDIT) {
      return;
    }
    const res: GeomEditResult = GdalVectorReader.deleteFeature(info.path ?? '', this.targetFidValue,
      info.layerName, this.backupDir());
    if (!res.ok) {
      Ui.toastLong(`删除失败：${res.error}`);
      return;
    }
    AppLog.i(`${TAG} 删除成功 fid=${this.targetFidValue} path=${info.path}`);
    this.pick.clearSelectedHighlight();
    this.layerManager.reloadVectorLayer(info.path ?? '', info.layerName);
    this.targetInfo = undefined;
    this.targetFidValue = -1;
    this.setPhase(GeomEditPhase.NONE);
    Ui.toast('要素已删除');
  }

  // ── 合并 ─────────────────────────────────────────────────────────

  /** 进入选合并目标子模式：点击同图层另一面图斑后确认合并 */
  startMergePick(): void {
    if (this.currentPhase !== GeomEditPhase.EDIT || !this.targetIsPolygon) {
      return;
    }
    this.setPhase(GeomEditPhase.MERGE_PICK);
    Ui.toast('请点击要合并的另一个面图斑（同一图层）');
  }

  /** 取消选靶回工具条待命 */
  cancelMergePick(): void {
    if (this.currentPhase === GeomEditPhase.MERGE_PICK) {
      this.setPhase(GeomEditPhase.EDIT);
    }
  }

  /** 返回键分级退出：子模式先回工具条，工具条再整体退出 */
  cancelSubMode(): void {
    if (this.currentPhase === GeomEditPhase.SPLIT_LINE) {
      this.cancelSplit();
    } else if (this.currentPhase === GeomEditPhase.MERGE_PICK) {
      this.cancelMergePick();
    }
  }

  /** 退出几何编辑：拆 live 层、取消选中高亮、回常规界面 */
  exit(): void {
    this.teardownSplitLive();
    this.pick.clearSelectedHighlight();
    this.targetInfo = undefined;
    this.targetFidValue = -1;
    this.targetIsPolygon = false;
    this.setPhase(GeomEditPhase.NONE);
  }

  // ── 内部 ─────────────────────────────────────────────────────────

  private pickMergeTarget(x: number, y: number): void {
    const info: LayerInfo | undefined = this.targetInfo;
    if (info === undefined) {
      return;
    }
    const hit: PickResult | undefined = this.view.pickVector(x, y);
    if (hit === undefined || hit.fid < 0) {
      Ui.toast('未命中要素，请点击要合并的面图斑');
      return;
    }
    const hitInfo: LayerInfo | undefined = this.layerManager.layerInfoByIndex(hit.layerIndex);
    if (hitInfo === undefined || hitInfo.path !== info.path || hitInfo.layerName !== info.layerName) {
      Ui.toast('请选择同一图层的面图斑');
      return;
    }
    if (hit.fid === this.targetFidValue) {
      Ui.toast('这是当前图斑本身，请点另一个面图斑');
      return;
    }
    const fg: FeatureGeometry | undefined = this.view.featureGeometry(hit.layerIndex, hit.fid);
    if (fg === undefined || fg.type !== 2) {
      Ui.toast('合并目标必须是面图斑');
      return;
    }
    const keepFid: number = this.targetFidValue;
    const removeFid: number = hit.fid;
    const path: string = info.path ?? '';
    const layerName: string = info.layerName;
    Ui.confirm('合并图斑',
      `将 #${keepFid} 与 #${removeFid} 合并为一个图斑？保留 #${keepFid} 的属性，合并前自动备份。`,
      '合并').then((ok: boolean): void => {
      if (!ok || this.currentPhase !== GeomEditPhase.MERGE_PICK) {
        return;
      }
      const res: GeomEditResult = GdalVectorReader.mergeFeatures(path, keepFid, removeFid,
        layerName, this.backupDir());
      if (!res.ok) {
        Ui.toastLong(`合并失败：${res.error}`);
        this.setPhase(GeomEditPhase.EDIT);
        return;
      }
      AppLog.i(`${TAG} 合并成功 keep=${keepFid} remove=${removeFid}`);
      this.setPhase(GeomEditPhase.EDIT);
      this.reloadAndRehighlight(keepFid);
      Ui.toast('合并完成');
    }, (e: Error): void => {
      AppLog.e('合并确认对话框失败', `${e}`);
    });
  }

  /** 操作成功后：源层就地换层重载（native 缓存几何已失效），再按新层索引重画选中高亮 */
  private reloadAndRehighlight(fid: number): void {
    const info: LayerInfo | undefined = this.targetInfo;
    if (info === undefined) {
      return;
    }
    this.pick.clearSelectedHighlight();
    this.layerManager.reloadVectorLayer(info.path ?? '', info.layerName);
    const path: string = info.path ?? '';
    const layerName: string = info.layerName;
    // 重载层几何可能异步就位：featureGeometry 取不到时延迟重试一次
    const attempt: (delay: number) => void = (delay: number): void => {
      setTimeout((): void => {
        if (this.currentPhase === GeomEditPhase.NONE || this.targetInfo !== info) {
          return;
        }
        const idx: number = this.layerManager.nativeIndexOf(info);
        if (idx < 0) {
          return;
        }
        const fg: FeatureGeometry | undefined = this.view.featureGeometry(idx, fid);
        if (fg === undefined) {
          if (delay === 0) {
            attempt(600);
          }
          return;
        }
        this.pick.highlightSelectedFeature(idx, fid, path, layerName);
      }, delay);
    };
    attempt(0);
  }

  /** 分割线 live 重绘：≥2 点连线，测点逐点画圆点；点数不足清空上一帧残留 */
  private renderSplitLive(): void {
    if (this.splitLineIndex < 0) {
      return;
    }
    if (this.splitPoints.length >= 2) {
      this.view.updateOverlayLines(this.splitLineIndex,
        BusinessOverlayManager.flattenLonLat(this.splitPoints), [this.splitPoints.length], [0], []);
    } else {
      this.view.updateOverlayLines(this.splitLineIndex, [], [], [], []);
    }
    if (this.splitMarkerIndex >= 0) {
      if (this.splitPoints.length > 0) {
        this.view.updateOverlayPoints(this.splitMarkerIndex,
          BusinessOverlayManager.flattenLonLat(this.splitPoints));
      } else {
        this.view.updateOverlayPoints(this.splitMarkerIndex, [], [], []);
      }
    }
  }

  private teardownSplitLive(): void {
    this.splitPoints = [];
    if (this.splitLineIndex >= 0) {
      this.view.removeOverlayLayer(this.splitLineIndex);
      this.splitLineIndex = -1;
    }
    if (this.splitMarkerIndex >= 0) {
      this.view.removeOverlayLayer(this.splitMarkerIndex);
      this.splitMarkerIndex = -1;
    }
  }

  /** 几何写前备份目录（应用沙箱）：native 首次写前整份备份 gdb 目录/shp 文件族，滚动保留一份 */
  private backupDir(): string {
    const dir: string = `${this.ctx.filesDir}/geom_backup`;
    try {
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir);
      }
    } catch (e) {
      AppLog.e('创建几何备份目录失败', `${e}`);
    }
    return dir;
  }

  private setPhase(phase: GeomEditPhase): void {
    this.currentPhase = phase;
    this.notify();
  }

  private notify(): void {
    this.onStateChanged(this.currentPhase);
  }
}