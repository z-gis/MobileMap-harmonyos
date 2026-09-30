// MeasureController.ets —— 测量采集控制器（对应 Android ui.map.MeasureCaptureController）。
//
// 点（位置）/ 距离 / 面积三模式的进入、点击加点、中心点加点、撤销、结束入库、退出；
// live 叠加层为三层结构（与 Android 完全一致）：
//  · 几何层      —— 点/折线/面本体；
//  · 测点圆点层  —— 每个已点击测点即时画圆点，给「点已加上」的反馈（几何层被线/面占用，单层单帧只能一种几何）；
//  · 纯文字标注层—— 距离=各测点累计距离、面积=各边中点边长 + 质心面积（pointRadiusDp=0 只画文字）。
// 采集态 capturing 由宿主组合进 BusinessOverlayManager.rebuild 门控；结束/退出经 rebuildOverlays 刷新已存测量。
// 公开 handleTap：测量态消费点击返回 true，宿主拾取分发据此优先于矢量拾取。

import { common } from '@kit.AbilityKit';
import { NativeMapView, VectorStyle } from 'globecore';
import { GeoCalc, LatLng } from '../common/GeoCalc';
import { AppLog } from '../common/AppLog';
import { Ui } from '../common/Ui';
import { MapDataStore, MeasurementRecord } from '../db/MapDataStore';
import { BusinessOverlayManager, MeasureLabelAnchors, MeasureLabels } from './BusinessOverlayManager';
import { MapStyle } from './MapStyle';

/** 测量采集模式 */
export enum MeasureMode {
  NONE = 0,
  POINT = 1,
  DISTANCE = 2,
  AREA = 3,
}

/** 采集态点串约定：[lat, lon, alt] */
type Point = number[];

export class MeasureController {
  private readonly view: NativeMapView;
  private readonly ctx: common.Context;
  /** 采集态变化（含控件显隐）与叠加层重建由宿主接线 */
  onCapturingChanged: (capturing: boolean, mode: MeasureMode) => void =
    (): void => {};
  rebuildOverlays: () => void = (): void => {};

  private mode: MeasureMode = MeasureMode.NONE;
  private points: Point[] = [];
  /** live 几何层 / 纯文字标注层 / 测点圆点层索引（-1 未建） */
  private liveIndex: number = -1;
  private labelLiveIndex: number = -1;
  private markerLiveIndex: number = -1;
  /**
   * 视口尺寸（vp）：宿主 onAreaChange 下发，中心点加点用（内核无宽度 getter）。
   * 与 CameraNavigator 同口径，也与 NativeMapView.screenToGeo 的入参命名一致。
   */
  private vpWidth: number = 0;
  private vpHeight: number = 0;

  constructor(view: NativeMapView, ctx: common.Context) {
    this.view = view;
    this.ctx = ctx;
  }

  /** 测量采集进行中（模式非 NONE） */
  capturing(): boolean {
    return this.mode !== MeasureMode.NONE;
  }

  /** 当前模式（宿主渲染采集工具条用） */
  currentMode(): MeasureMode {
    return this.mode;
  }

  /** 已采集点数（宿主「撤销/结束」键可用性判断用） */
  pointCount(): number {
    return this.points.length;
  }

  /** 宿主下发视口尺寸（vp，屏幕反算用） */
  setViewportSize(widthVp: number, heightVp: number): void {
    this.vpWidth = widthVp;
    this.vpHeight = heightVp;
  }

  /** 测量菜单入口：点（位置）/ 距离 / 面积三模式 */
  async showMeasureMenu(): Promise<void> {
    const which: number = await Ui.items('测量', ['点（位置）', '距离', '面积']);
    if (which === 0) {
      this.activate(MeasureMode.POINT, '点位测量：点击地图获取坐标');
    } else if (which === 1) {
      this.activate(MeasureMode.DISTANCE, '距离测量：连续点击地图添加测点');
    } else if (which === 2) {
      this.activate(MeasureMode.AREA, '面积测量：连续点击地图围成区域');
    }
  }

  /**
   * 进入测量模式：清空点串、按模式默认色新建三层 live 叠加层、通知宿主显示采集控件。
   * 进入后 capturing 转 true，BusinessOverlayManager.rebuild 期间被门控跳过以保护 live 层。
   */
  activate(mode: MeasureMode, tip: string): void {
    if (mode === MeasureMode.NONE) {
      return;
    }
    this.mode = mode;
    this.points = [];
    const color: number = MeasureController.defaultColorForMode(mode);
    const style: VectorStyle = MeasureController.liveStyle(color);
    this.liveIndex = this.view.addOverlayLayer(style);
    // 纯文字标注层（pointRadiusDp=0 → 不画圆点，仅渲染标注文字）
    const labelStyle: VectorStyle = MeasureController.liveStyle(color);
    labelStyle.pointRadiusDp = 0;
    this.labelLiveIndex = this.view.addOverlayLayer(labelStyle);
    // 测点圆点标记层：每次点击即在顶点画点，给出即时反馈
    this.markerLiveIndex = this.view.addOverlayLayer(style);
    AppLog.i(`测量进入 mode=${mode} live=${this.liveIndex} label=${this.labelLiveIndex} marker=${this.markerLiveIndex}`);
    this.onCapturingChanged(true, mode);
    Ui.toast(tip);
  }

  /**
   * 测量态点击拦截：模式非 NONE 时把点击用于加点并返回 true（消费），
   * 否则返回 false 交宿主继续矢量拾取（优先于拾取）。
   */
  handleTap(x: number, y: number): boolean {
    if (this.mode === MeasureMode.NONE) {
      return false;
    }
    const geo = this.view.screenToGeo(x, y);
    if (geo === undefined) {
      // 3D 下射线指向天空（或未命中椭球）不加点：不能静默吞掉点击，否则看起来像「点了没反应」
      AppLog.w('测量加点未命中地表', `x=${x} y=${y} mode=${this.mode}`);
      Ui.toast('该点未命中地表，请点向地图区域');
      return true;
    }
    this.addPoint(geo.latitude, geo.longitude);
    return true;
  }

  /** 以屏幕中心（十字丝）作为测量点：中心像素 → 经纬度 → 加点 */
  addCenterPoint(): void {
    if (this.mode === MeasureMode.NONE) {
      return;
    }
    if (this.vpWidth <= 0 || this.vpHeight <= 0) {
      return;
    }
    const geo = this.view.screenToGeo(this.vpWidth * 0.5, this.vpHeight * 0.5);
    if (geo === undefined) {
      Ui.toast('中心点未命中地表');
      return;
    }
    this.addPoint(geo.latitude, geo.longitude);
  }

  /** 撤销上一个测量点（点模式仅一点，撤销即清空），并实时重绘 live 层 */
  undo(): void {
    if (this.mode === MeasureMode.NONE || this.points.length === 0) {
      return;
    }
    this.points.pop();
    this.renderLive();
    this.onCapturingChanged(true, this.mode);
  }

  /**
   * 追加测量点（[lat,lon]）：点模式覆盖为单点，距离/面积模式累加；
   * 每次加点后实时重绘 live 层并**必给一条文字反馈**（Android 仅在达阈时提示，这里把
   * 首点/次点的阶段语义也说出来：第 1 点=已画点、第 2 点=已连线、第 3 点起=已成面）。
   */
  private addPoint(lat: number, lon: number): void {
    if (this.mode === MeasureMode.POINT) {
      // 点模式语义为「取当前位置」：始终覆盖为单点，重复点击即改点而非累加
      this.points = [[lat, lon, 0]];
      this.renderLive();
      Ui.toast(`位置: ${lat.toFixed(6)}, ${lon.toFixed(6)}`);
      this.onCapturingChanged(true, this.mode);
      return;
    }
    this.points.push([lat, lon, 0]);
    this.renderLive();
    const n: number = this.points.length;
    AppLog.i(`测量加点 mode=${this.mode} n=${n}`, `${lat.toFixed(6)},${lon.toFixed(6)}`);
    const degrees: LatLng[] = MeasureController.toLatLng(this.points);
    if (this.mode === MeasureMode.DISTANCE) {
      Ui.toast(n < 2 ? '第 1 个点已画，再点一次连线'
        : `第 ${n} 个点　距离: ${GeoCalc.formatDistance(GeoCalc.polylineLengthMeters(degrees))}`);
    } else if (this.mode === MeasureMode.AREA) {
      if (n < 2) {
        Ui.toast('第 1 个点已画，再点一次连线');
      } else if (n < 3) {
        Ui.toast('第 2 个点已连线，再点第 3 点成面');
      } else {
        Ui.toast(`第 ${n} 个点　面积: ${GeoCalc.formatArea(GeoCalc.polygonAreaSquareMeters(degrees))}`);
      }
    }
    this.onCapturingChanged(true, this.mode);
  }

  /**
   * 实时重绘三层 live（均覆盖式）：点模式=点、距离=逐点圆点 + 折线（≥2 点连线）、
   * 面积=逐点圆点 + 开链折线（2 点）/闭环面（≥3 点）。点数不足时推送空几何清除上一帧残留
   * （撤销后回退到阈值以下）；标注由纯文字层承载，几何本体不挂整体标注。
   */
  private renderLive(): void {
    const idx: number = this.liveIndex;
    if (idx < 0) {
      return;
    }
    this.renderLiveMarkers();
    if (this.mode === MeasureMode.POINT) {
      if (this.points.length === 0) {
        this.view.updateOverlayPoints(idx, [], [], []);
      } else {
        this.view.updateOverlayPoints(idx,
          BusinessOverlayManager.flattenLonLat(this.points), [0], ['测量点']);
      }
      this.clearLiveLabels();
      return;
    }
    if (this.mode === MeasureMode.DISTANCE) {
      if (this.points.length < 2) {
        // 仅 1 点：暂不连线（圆点标记已给出反馈），清线 + 清标注
        this.view.updateOverlayLines(idx, [], [], [], []);
        this.clearLiveLabels();
        return;
      }
      this.view.updateOverlayLines(idx, BusinessOverlayManager.flattenLonLat(this.points),
        [this.points.length], [0], []);
      this.updateLiveLabels(MeasurementRecord.TYPE_DISTANCE, this.points);
      return;
    }
    if (this.mode === MeasureMode.AREA) {
      if (this.points.length < 2) {
        this.view.updateOverlayPolygons(idx, [], [], [], [], []);
        this.clearLiveLabels();
        return;
      }
      if (this.points.length === 2) {
        // 2 点：先画开链折线给出「连线」反馈，标注层显示该边边长
        this.view.updateOverlayLines(idx, BusinessOverlayManager.flattenLonLat(this.points),
          [2], [0], []);
        this.updateLiveLabels(MeasurementRecord.TYPE_AREA, this.points);
        return;
      }
      const ring: Point[] = [];
      for (let i = 0; i < this.points.length; i++) {
        ring.push(this.points[i]);
      }
      ring.push(this.points[0]);
      this.view.updateOverlayPolygons(idx, BusinessOverlayManager.flattenLonLat(ring),
        [ring.length], [1], [0], []);
      this.updateLiveLabels(MeasurementRecord.TYPE_AREA, this.points);
    }
  }

  /** 测点圆点标记层：DISTANCE/AREA 采集态把每个已点击测点画圆点；点模式由几何层画点，此处清空 */
  private renderLiveMarkers(): void {
    const idx: number = this.markerLiveIndex;
    if (idx < 0) {
      return;
    }
    const showDots: boolean = (this.mode === MeasureMode.DISTANCE || this.mode === MeasureMode.AREA)
      && this.points.length > 0;
    if (showDots) {
      this.view.updateOverlayPoints(idx, BusinessOverlayManager.flattenLonLat(this.points));
    } else {
      this.view.updateOverlayPoints(idx, [], [], []);
    }
  }

  /** 用测量多标注刷新 live 纯文字标注层（采集态 fid 统一 0：点击用于加点、不参与拾取分流） */
  private updateLiveLabels(type: string, pts: Point[]): void {
    const idx: number = this.labelLiveIndex;
    if (idx < 0) {
      return;
    }
    const anchors: MeasureLabelAnchors = MeasureLabels.anchors(type, pts);
    if (anchors.lonlat.length === 0) {
      this.view.updateOverlayPoints(idx, [], [], []);
      return;
    }
    const fids: number[] = [];
    for (let i = 0; i < anchors.labels.length; i++) {
      fids.push(0);
    }
    this.view.updateOverlayPoints(idx, anchors.lonlat, fids, anchors.labels);
  }

  /** 清空 live 纯文字标注层（点数不足/点模式时调用，避免残留标注） */
  private clearLiveLabels(): void {
    if (this.labelLiveIndex >= 0) {
      this.view.updateOverlayPoints(this.labelLiveIndex, [], [], []);
    }
  }

  /**
   * 结束当前测量：校验点数（距离≥2 / 面积≥3）后入库，退出测量模式（拆 live 层 + 重建叠加层显示新测量）。
   * @returns 是否已保存
   */
  async finish(): Promise<boolean> {
    if (this.mode === MeasureMode.NONE || this.points.length === 0) {
      this.exit();
      return false;
    }
    if (this.mode === MeasureMode.DISTANCE && this.points.length < 2) {
      Ui.toast('至少需要两个点');
      return false;
    }
    if (this.mode === MeasureMode.AREA && this.points.length < 3) {
      Ui.toast('至少需要三个点');
      return false;
    }
    const type: string = this.mode === MeasureMode.POINT ? MeasurementRecord.TYPE_POINT
      : (this.mode === MeasureMode.AREA ? MeasurementRecord.TYPE_AREA
        : MeasurementRecord.TYPE_DISTANCE);
    const now: number = Date.now();
    const name: string = Ui.stampName(MeasureController.modeDisplayName(this.mode), now);
    const points: Point[] = [];
    for (let i = 0; i < this.points.length; i++) {
      const p: Point = this.points[i];
      points.push([p[0], p[1], p.length > 2 ? p[2] : 0]);
    }
    const store: MapDataStore = await MapDataStore.getInstance(this.ctx);
    const id: number = await store.addMeasurement(name, type,
      MeasureController.defaultColorForMode(this.mode), now, points);
    if (id >= 0) {
      Ui.toast('测量已保存');
    }
    this.exit();
    return id >= 0;
  }

  /** 退出测量模式：清状态、拆 live 层、隐藏采集控件，并重建叠加层（此时 capturing 转 false） */
  exit(): void {
    this.mode = MeasureMode.NONE;
    this.points = [];
    if (this.liveIndex >= 0) {
      this.view.removeOverlayLayer(this.liveIndex);
      this.liveIndex = -1;
    }
    if (this.labelLiveIndex >= 0) {
      this.view.removeOverlayLayer(this.labelLiveIndex);
      this.labelLiveIndex = -1;
    }
    if (this.markerLiveIndex >= 0) {
      this.view.removeOverlayLayer(this.markerLiveIndex);
      this.markerLiveIndex = -1;
    }
    this.onCapturingChanged(false, MeasureMode.NONE);
    this.rebuildOverlays();
  }

  // ── 详情展示辅助（页面对话框复用）──────────────────────────────────

  static typeDisplayName(type: string): string {
    if (type === MeasurementRecord.TYPE_POINT) {
      return '点位测量';
    }
    if (type === MeasurementRecord.TYPE_DISTANCE) {
      return '距离测量';
    }
    if (type === MeasurementRecord.TYPE_AREA) {
      return '面积测量';
    }
    return '测量';
  }

  static modeDisplayName(mode: MeasureMode): string {
    if (mode === MeasureMode.POINT) {
      return '点位测量';
    }
    if (mode === MeasureMode.DISTANCE) {
      return '距离测量';
    }
    if (mode === MeasureMode.AREA) {
      return '面积测量';
    }
    return '测量';
  }

  /** 几何量算文本：点=坐标，距离=总长，面积=面积 + 周长 */
  static geometryText(record: MeasurementRecord): string {
    const pts: Point[] = record.points;
    if (pts.length === 0) {
      return '';
    }
    if (record.type === MeasurementRecord.TYPE_POINT) {
      return `坐标: ${pts[0][0].toFixed(6)}, ${pts[0][1].toFixed(6)}`;
    }
    const degrees: LatLng[] = MeasureController.toLatLng(pts);
    if (record.type === MeasurementRecord.TYPE_DISTANCE) {
      return `距离: ${GeoCalc.formatDistance(GeoCalc.polylineLengthMeters(degrees))}`;
    }
    if (pts.length < 3) {
      return '';
    }
    const closed: LatLng[] = [];
    for (let i = 0; i < degrees.length; i++) {
      closed.push(degrees[i]);
    }
    closed.push(degrees[0]);
    return `面积: ${GeoCalc.formatArea(GeoCalc.polygonAreaSquareMeters(degrees))}`
      + `  周长: ${GeoCalc.formatDistance(GeoCalc.polylineLengthMeters(closed))}`;
  }

  /** 测量模式默认色：距离=蓝、面积=绿、点位=黄 */
  static defaultColorForMode(mode: MeasureMode): number {
    if (mode === MeasureMode.AREA) {
      return MapStyle.MEASURE_COLOR_AREA;
    }
    if (mode === MeasureMode.POINT) {
      return MapStyle.MEASURE_COLOR_POINT;
    }
    return MapStyle.MEASURE_COLOR_DISTANCE;
  }

  /** live 层样式：几何/标注/圆点三层共用（标注层由调用方把点半径改 0） */
  private static liveStyle(color: number): VectorStyle {
    const style: VectorStyle = MapStyle.defaultStyle();
    style.fillColor = color;
    style.outlineColor = color;
    style.outlineWidth = MapStyle.MEASURE_LIVE_WIDTH;
    style.lineColor = color;
    style.lineWidth = MapStyle.MEASURE_LIVE_WIDTH;
    style.pointColor = color;
    style.pointRadiusDp = MapStyle.MEASURE_POINT_RADIUS_DP;
    style.labelColor = MapStyle.DEFAULT_LABEL_COLOR;
    style.labelSize = MapStyle.DEFAULT_LABEL_SIZE;
    style.labelField = '';
    // 标注为白字：无描边时压在蓝细线/圆点或浅色底图上会看不清（距离全程、面积存图后均如此），
    // 统一加黑色描边，使任何背景都可读（对齐地图标注惯例）。
    style.labelOutline = true;
    style.labelOutlineColor = MapStyle.DEFAULT_LABEL_OUTLINE_COLOR;
    return style;
  }

  private static toLatLng(points: Point[]): LatLng[] {
    const out: LatLng[] = [];
    for (let i = 0; i < points.length; i++) {
      out.push(new LatLng(points[i][0], points[i][1]));
    }
    return out;
  }
}
