// BusinessOverlayManager.ets —— 业务叠加层显示与命中映射（对应 Android ui.map.BusinessOverlayManager）。
//
// 测量 / 轨迹 / 拍照 / 样地四类业务数据存于关系库（非 document.json），经内核动态叠加层渲染：
//  · 数据签名判定：仅当「记录摘要 + 可见性开关」变化才 clearOverlayLayers 重建，避免每次文档变更无谓重建；
//  · 命中映射：重建时记录「叠加层索引 → 业务主键」，拾取命中据此分流到对应详情（DB 读取交宿主）；
//  · 采集态门控：测量/轨迹采集中跳过重建（clearOverlayLayers 会清掉 live 层）。
// 内核索引口径：叠加层与文件矢量层共享索引空间，clearOverlayLayers 后叠加层索引重置，映射须随重建刷新。

import { common } from '@kit.AbilityKit';
import { NativeMapView, VectorStyle } from '@zys/globecore';
import { AppLog } from '../common/AppLog';
import { ColorHex } from '../common/ColorHex';
import { GeoCalc, LatLng } from '../common/GeoCalc';
import { MapDataStore, MeasurementRecord, TrackRecord } from '../db/MapDataStore';
import { DocumentManager } from '../doc/DocumentManager';
import { MediaPlacemark, MediaStore } from '../media/MediaStore';
import { MapStyle } from './MapStyle';
import { SampleSurveyStore } from '../survey/SampleSurveyStore';
import { SurveyPlot } from '../survey/SurveyModels';
import { FeatureIcons } from '../vector/FeatureIcons';

const TAG: string = 'BusinessOverlayManager';

/** 业务叠加命中类型 */
export class OverlayKind {
  static readonly NONE: string = 'none';
  static readonly MEASURE: string = 'measure';
  static readonly TRACK: string = 'track';
  static readonly MEDIA: string = 'media';
  static readonly SURVEY: string = 'survey';
}

/** 命中结果：仅分类 + 业务主键，不加载记录（详情读取交宿主，避免本层依赖各仓库） */
export class OverlayHit {
  kind: string;
  recordId: number;

  constructor(kind: string = OverlayKind.NONE, recordId: number = -1) {
    this.kind = kind;
    this.recordId = recordId;
  }

  isNone(): boolean {
    return this.kind === OverlayKind.NONE;
  }
}

/** 测量/轨迹业务点的统一坐标约定：[lat, lon, alt?]（与库内点串一致） */
type Point = number[];

export class BusinessOverlayManager {
  private readonly view: NativeMapView;
  private readonly ctx: common.Context;
  /** 采集态门控：测量/轨迹 live 层存在时跳过重建 */
  isCapturing: () => boolean = (): boolean => false;
  /** clearOverlayLayers 后重置查询/选中失效索引（接线 SqlQueryController / FeaturePickController） */
  onOverlayLayersCleared: () => void = (): void => {};
  /** 重建末尾按缓存要素恢复 SQL 查询高亮 */
  restoreQueryHighlight: () => void = (): void => {};

  /** 业务叠加层数据签名：仅当签名变化才重建 */
  private overlaySignature: string = '';
  private measureOverlayIds: Map<number, number> = new Map<number, number>();
  private trackOverlayIds: Map<number, number> = new Map<number, number>();
  private mediaOverlayIndex: number = -1;
  private surveyOverlayIndex: number = -1;

  constructor(view: NativeMapView, ctx: common.Context) {
    this.view = view;
    this.ctx = ctx;
  }

  /** 当前媒体点位叠加层索引（-1 无）；供「点击空白取消选中」等外部判定 */
  getMediaOverlayIndex(): number {
    return this.mediaOverlayIndex;
  }

  /** 当前样地点位叠加层索引（-1 无） */
  getSurveyOverlayIndex(): number {
    return this.surveyOverlayIndex;
  }

  /**
   * 重建业务叠加层：读设置可见性开关 + 四类独立数据源，按数据签名判断是否需重建。
   * 在页面显示 / 文档变更（开关落盘）/ 采集退出时调用。
   */
  async rebuild(): Promise<void> {
    if (this.isCapturing()) {
      return;
    }
    const cfg = DocumentManager.getInstance().getConfig();
    const showMeasure: boolean = cfg.showMeasureLayer;
    const showTrack: boolean = cfg.showTrackLayer;
    const showMedia: boolean = cfg.showMediaLayer;
    const showPhotoName: boolean = cfg.showPhotoName;

    const measures: MeasurementRecord[] = showMeasure
      ? await (await MapDataStore.getInstance(this.ctx)).loadMeasurements() : [];
    const tracks: TrackRecord[] = showTrack
      ? await (await MapDataStore.getInstance(this.ctx)).loadTracks() : [];
    const photos: MediaPlacemark[] = showMedia
      ? await (await MediaStore.getInstance(this.ctx)).loadPlacemarks() : [];
    // 样地点位：无全局调查模式与显隐开关，常显
    const plots: SurveyPlot[] = await (await SampleSurveyStore.getInstance(this.ctx)).loadAllPlots();

    const sig: string = BusinessOverlayManager.overlayDataSignature(showMeasure, showTrack, showMedia,
      showPhotoName, measures, tracks, photos, plots);
    if (sig === this.overlaySignature) {
      return;
    }
    this.overlaySignature = sig;

    this.view.clearOverlayLayers();
    // 叠加层索引重置：映射须随重建重新记录 index → 业务主键
    this.measureOverlayIds.clear();
    this.trackOverlayIds.clear();
    this.mediaOverlayIndex = -1;
    this.surveyOverlayIndex = -1;
    this.onOverlayLayersCleared();

    for (let i = 0; i < measures.length; i++) {
      this.addMeasurementOverlay(measures[i]);
    }
    for (let i = 0; i < tracks.length; i++) {
      const t: TrackRecord = tracks[i];
      if (t.visible && t.points.length >= 2) {
        this.addTrackOverlay(t);
      }
    }
    this.addMediaOverlay(photos, showPhotoName);
    this.addSurveyOverlay(plots);
    this.restoreQueryHighlight();
    AppLog.i(`${TAG} 业务叠加层重建：测量${measures.length} 轨迹${tracks.length} `
      + `拍照${photos.length} 样地${plots.length}`);
  }

  /** 强制下次 rebuild 生效（数据已改动但需立即刷新时调用） */
  invalidate(): void {
    this.overlaySignature = '';
  }

  /**
   * 叠加数据签名：四个开关 + 各记录 id/样式/可见性/点数摘要拼接。
   * 测量/轨迹几何「写后不可变」（保存即定型），故点数足以捕获增删；样式/可见性变化亦纳入。
   */
  private static overlayDataSignature(showMeasure: boolean, showTrack: boolean, showMedia: boolean,
    showPhotoName: boolean, measures: MeasurementRecord[], tracks: TrackRecord[],
    photos: MediaPlacemark[], plots: SurveyPlot[]): string {
    const sb: string[] = [];
    sb.push(showMeasure ? 'M' : '-');
    sb.push(showTrack ? 'T' : '-');
    sb.push(showMedia ? 'P' : '-');
    sb.push(showPhotoName ? 'N' : '-');
    for (let i = 0; i < measures.length; i++) {
      const m: MeasurementRecord = measures[i];
      sb.push(`|m${m.id}:${m.type}:${m.color}:${m.lineWidth}:${m.points.length}`);
    }
    for (let i = 0; i < tracks.length; i++) {
      const t: TrackRecord = tracks[i];
      sb.push(`|t${t.id}:${t.visible ? 1 : 0}:${t.color}:${t.lineWidth}:${t.points.length}`);
    }
    for (let i = 0; i < photos.length; i++) {
      const p: MediaPlacemark = photos[i];
      sb.push(`|p${p.id}:${p.visible ? 1 : 0}:${p.name}:${p.latitude}:${p.longitude}`);
    }
    for (let i = 0; i < plots.length; i++) {
      const s: SurveyPlot = plots[i];
      sb.push(`|s${s.id}:${s.plotNo}:${s.centerLatitude}:${s.centerLongitude}:${s.updatedAt}`);
    }
    return sb.join('');
  }

  /**
   * 测量记录 → 叠加层：点位 = 彩心圆点 + 名称标注；距离 = 折线 + 各测点累计距离（纯文字标注层）；
   * 面积 = 半透明填充 + 描边 + 各边中点边长与质心面积（纯文字标注层）。样式取记录自身颜色/线宽。
   */
  private addMeasurementOverlay(record: MeasurementRecord): void {
    const pts: Point[] = record.points;
    if (pts.length === 0) {
      return;
    }
    const color: number = record.color;
    const lineW: number = record.lineWidth;
    if (record.type === MeasurementRecord.TYPE_POINT) {
      const idx: number = this.view.addOverlayLayer(BusinessOverlayManager.measureStyle(color, lineW, color));
      if (idx < 0) {
        return;
      }
      this.measureOverlayIds.set(idx, record.id);
      const p: Point = pts[0];
      this.view.updateOverlayPoints(idx, BusinessOverlayManager.flattenLonLat(pts), [record.id], [record.name]);
    } else if (record.type === MeasurementRecord.TYPE_DISTANCE) {
      if (pts.length < 2) {
        return;
      }
      const idx: number = this.view.addOverlayLayer(BusinessOverlayManager.measureStyle(color, lineW, color));
      if (idx < 0) {
        return;
      }
      this.measureOverlayIds.set(idx, record.id);
      // 折线本体不挂整体标注；逐点累计距离由纯文字标注层承载
      this.view.updateOverlayLines(idx, BusinessOverlayManager.flattenLonLat(pts), [pts.length],
        [record.id], []);
      this.addMeasureLabelOverlay(record.id, record.type, pts);
    } else if (record.type === MeasurementRecord.TYPE_AREA) {
      if (pts.length < 3) {
        return;
      }
      const fill: number = ColorHex.withAlpha(color,
        Math.round(MapStyle.MEASURE_AREA_FILL_ALPHA * 255));
      const idx: number = this.view.addOverlayLayer(BusinessOverlayManager.measureStyle(fill, lineW, color));
      if (idx < 0) {
        return;
      }
      this.measureOverlayIds.set(idx, record.id);
      // 面环须闭合（首点补末尾）：内核仅对首尾重合的环封口，开环缺「末→首」描边
      const ring: Point[] = [];
      for (let i = 0; i < pts.length; i++) {
        ring.push(pts[i]);
      }
      ring.push(pts[0]);
      this.view.updateOverlayPolygons(idx, BusinessOverlayManager.flattenLonLat(ring),
        [ring.length], [1], [record.id], []);
      this.addMeasureLabelOverlay(record.id, record.type, pts);
    }
  }

  /**
   * 已保存测量的「纯文字多标注层」（点半径 0 → 内核不画圆点，仅渲染标注文字）：
   * 与几何层同映射到 recordId，点击标注亦打开该测量详情。点测量无附加标注。
   */
  private addMeasureLabelOverlay(recordId: number, type: string, pts: Point[]): void {
    const anchors: MeasureLabelAnchors = MeasureLabels.anchors(type, pts);
    if (anchors.lonlat.length === 0) {
      return;
    }
    // 存图后面积填充转为半透明、距离仅有细线，白字无描边会看不清；与采集态一致加黑描边。
    const idx: number = this.view.addOverlayLayer(MapStyle.labelStyle(
      MapStyle.DEFAULT_LABEL_COLOR, MapStyle.DEFAULT_LABEL_SIZE, true,
      MapStyle.DEFAULT_LABEL_OUTLINE_COLOR));
    if (idx < 0) {
      return;
    }
    this.measureOverlayIds.set(idx, recordId);
    const fids: number[] = [];
    for (let i = 0; i < anchors.labels.length; i++) {
      fids.push(recordId);
    }
    this.view.updateOverlayPoints(idx, anchors.lonlat, fids, anchors.labels);
  }

  /** 轨迹记录 → 一条折线叠加层：颜色/线宽取记录自身，无标注 */
  private addTrackOverlay(record: TrackRecord): void {
    const style: VectorStyle = MapStyle.lineStyle(record.color, record.lineWidth);
    const idx: number = this.view.addOverlayLayer(style);
    if (idx < 0) {
      return;
    }
    this.trackOverlayIds.set(idx, record.id);
    this.view.updateOverlayLines(idx, BusinessOverlayManager.flattenLonLat(record.points),
      [record.points.length], [record.id], []);
  }

  /**
   * 拍照点位 → 一点叠加层（全部可见点合一层）：图标程序化生成 camera 形状 billboard，
   * fid = 点位主键（供交互查附件）；名称标注受 showPhotoName 控制。
   * 分组可见性已由管理界面写入各点 visible，故此处仅过滤 visible。
   */
  private addMediaOverlay(photos: MediaPlacemark[], showName: boolean): void {
    const visible: MediaPlacemark[] = photos.filter((p: MediaPlacemark): boolean => p.visible);
    if (visible.length === 0) {
      return;
    }
    const style: VectorStyle = MapStyle.pointStyle(MapStyle.DEFAULT_LINE_COLOR, MapStyle.PHOTO_POINT_RADIUS_DP);
    const icon: number[] = FeatureIcons.pixels(FeatureIcons.DEFAULT_KEY, MapStyle.PHOTO_ICON_COLOR);
    const idx: number = this.view.addOverlayLayer(style, icon,
      MapStyle.PHOTO_POINT_RADIUS_DP * 2, MapStyle.PHOTO_POINT_RADIUS_DP * 2);
    if (idx < 0) {
      return;
    }
    this.mediaOverlayIndex = idx;
    const lonlat: number[] = [];
    const fids: number[] = [];
    const labels: string[] = [];
    for (let i = 0; i < visible.length; i++) {
      const p: MediaPlacemark = visible[i];
      lonlat.push(p.longitude);
      lonlat.push(p.latitude);
      fids.push(p.id);
      labels.push(showName ? p.displayName() : '');
    }
    this.view.updateOverlayPoints(idx, lonlat, fids, labels);
  }

  /**
   * 样地点位 → 一点叠加层（全部样地合一层）：fid = 样地主键（供命中编辑），标注「样地#编号」。
   * 无有效中心坐标的样地跳过（新建未定位的草稿不显示）。
   */
  private addSurveyOverlay(plots: SurveyPlot[]): void {
    const valid: SurveyPlot[] = plots.filter((p: SurveyPlot): boolean => p.hasCenter());
    if (valid.length === 0) {
      return;
    }
    const style: VectorStyle = MapStyle.pointStyle(MapStyle.SURVEY_COLOR, MapStyle.SURVEY_POINT_RADIUS_DP);
    const icon: number[] = FeatureIcons.pixels(FeatureIcons.SQUARE, MapStyle.SURVEY_COLOR);
    const idx: number = this.view.addOverlayLayer(style, icon,
      MapStyle.SURVEY_POINT_RADIUS_DP * 2, MapStyle.SURVEY_POINT_RADIUS_DP * 2);
    if (idx < 0) {
      return;
    }
    this.surveyOverlayIndex = idx;
    const lonlat: number[] = [];
    const fids: number[] = [];
    const labels: string[] = [];
    for (let i = 0; i < valid.length; i++) {
      const p: SurveyPlot = valid[i];
      lonlat.push(p.centerLongitude);
      lonlat.push(p.centerLatitude);
      fids.push(p.id);
      labels.push(`样地#${p.plotNo}`);
    }
    this.view.updateOverlayPoints(idx, lonlat, fids, labels);
  }

  /**
   * 业务叠加命中分类：内核逆序遍历使后加入的叠加层优先命中（测量/轨迹/拍照优先于文件矢量）。
   * 查询高亮层/选中高亮层的穿透不参与本分类（由 FeaturePickController 结合 SqlQueryController 处理）。
   */
  hitTest(layerIndex: number, fid: number): OverlayHit {
    const measureId: number | undefined = this.measureOverlayIds.get(layerIndex);
    if (measureId !== undefined) {
      return new OverlayHit(OverlayKind.MEASURE, measureId);
    }
    const trackId: number | undefined = this.trackOverlayIds.get(layerIndex);
    if (trackId !== undefined) {
      return new OverlayHit(OverlayKind.TRACK, trackId);
    }
    if (layerIndex === this.mediaOverlayIndex && fid >= 0) {
      return new OverlayHit(OverlayKind.MEDIA, fid);
    }
    if (layerIndex === this.surveyOverlayIndex && fid >= 0) {
      return new OverlayHit(OverlayKind.SURVEY, fid);
    }
    return new OverlayHit();
  }

  /** 业务点串 [lat,lon,(alt)] → 叠加层摊平 [lon,lat,…]（换序：内核经度在前，业务库纬度在前） */
  static flattenLonLat(points: Point[]): number[] {
    const out: number[] = [];
    for (let i = 0; i < points.length; i++) {
      out.push(points[i][1]);
      out.push(points[i][0]);
    }
    return out;
  }

  /** 测量叠加样式：填充/描边/线/点同色，点半径固定测点半径 */
  private static measureStyle(fill: number, lineWidth: number, stroke: number): VectorStyle {
    const style: VectorStyle = MapStyle.defaultStyle();
    style.fillColor = fill;
    style.outlineColor = stroke;
    style.outlineWidth = lineWidth;
    style.lineColor = stroke;
    style.lineWidth = lineWidth;
    style.pointColor = stroke;
    style.pointRadiusDp = MapStyle.MEASURE_POINT_RADIUS_DP;
    style.labelColor = MapStyle.DEFAULT_LABEL_COLOR;
    style.labelSize = MapStyle.DEFAULT_LABEL_SIZE;
    style.labelField = '';
    return style;
  }
}

/** 测量标注锚点结果：摊平经纬度 + 一一对应的标注文本 */
export class MeasureLabelAnchors {
  lonlat: number[];
  labels: string[];

  constructor(lonlat: number[] = [], labels: string[] = []) {
    this.lonlat = lonlat;
    this.labels = labels;
  }
}

/**
 * 测量标注锚点计算（业务叠加显示与测量采集 live 标注共用）：
 *  · 距离：各测点处标注从起点累计的距离（首点为 0）；
 *  · 面积：各边中点标注该边长（含末→首闭合边）+ 质心标注总面积。
 */
export class MeasureLabels {
  static anchors(type: string, pts: Point[]): MeasureLabelAnchors {
    const lonlat: number[] = [];
    const labels: string[] = [];
    if (type === MeasurementRecord.TYPE_DISTANCE) {
      let cumulative: number = 0;
      for (let i = 0; i < pts.length; i++) {
        if (i > 0) {
          cumulative += GeoCalc.distanceMeters(pts[i - 1][0], pts[i - 1][1], pts[i][0], pts[i][1]);
        }
        lonlat.push(pts[i][1]);
        lonlat.push(pts[i][0]);
        labels.push(GeoCalc.formatDistance(cumulative));
      }
    } else if (type === MeasurementRecord.TYPE_AREA) {
      if (pts.length >= 2) {
        for (let i = 1; i < pts.length; i++) {
          MeasureLabels.putEdge(pts[i - 1], pts[i], lonlat, labels);
        }
        if (pts.length >= 3) {
          // 闭合边（末→首）
          MeasureLabels.putEdge(pts[pts.length - 1], pts[0], lonlat, labels);
        }
      }
      if (pts.length >= 3) {
        const degrees: LatLng[] = [];
        for (let i = 0; i < pts.length; i++) {
          degrees.push(new LatLng(pts[i][0], pts[i][1]));
        }
        const c: LatLng = GeoCalc.polygonCentroid(degrees);
        const area: number = GeoCalc.polygonAreaSquareMeters(degrees);
        lonlat.push(c.lng);
        lonlat.push(c.lat);
        labels.push(GeoCalc.formatArea(area));
      }
    }
    return new MeasureLabelAnchors(lonlat, labels);
  }

  /** 边中点标注边长 */
  private static putEdge(a: Point, b: Point, lonlat: number[], labels: string[]): void {
    const len: number = GeoCalc.distanceMeters(a[0], a[1], b[0], b[1]);
    lonlat.push((a[1] + b[1]) * 0.5);
    lonlat.push((a[0] + b[0]) * 0.5);
    labels.push(GeoCalc.formatDistance(len));
  }
}
