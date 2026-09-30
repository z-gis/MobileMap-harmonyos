// FeaturePickController.ets —— 矢量拾取与选中详情路由（对应 Android ui.map.FeaturePickController）。
//
// 单击地图的命中分发顺序（与 Android 完全一致）：
//   1) 测量采集拦截（MeasureController.handleTap 消费）；
//   2) native pickVector 命中业务叠加层 → 按 hitTest 分类路由到测量/轨迹/拍照/样地详情；
//   3) 命中文件矢量层 → 画黄色选中高亮层 + 弹要素详情（属性后台回取后就地回填）；
//   4) 未命中 → 取消选中高亮（点空白取消）。
// 查询高亮层与选中高亮层均置 noPick 不参与 native 拾取（其大面积几何会遮蔽业务叠加与源要素点击），
// 命中穿透分支仅作防护兜底。
//
// 与 Android 的差异：详情弹层改为「控制器组装请求对象 + 宿主渲染」，
// 因 ArkTS 对话框必须是 @CustomDialog 组件、无法在普通类中 show；属性回取仍在弹层之后进行
// （GDAL 打开 KML/DXF 可达秒级，阻塞会让弹窗迟迟不出现），经 setTimeout 让出一帧后回取并广播回填。

import { common } from '@kit.AbilityKit';
import { FeatureGeometry, NativeMapView, VectorStyle } from 'globecore';
import { AppLog } from '../common/AppLog';
import { ColorHex } from '../common/ColorHex';
import { GeoCalc, LatLng } from '../common/GeoCalc';
import { Ui } from '../common/Ui';
import { LayerInfo, StyleOverride } from '../doc/DocModels';
import { DocumentManager } from '../doc/DocumentManager';
import { MediaPlacemark, MediaStore } from '../media/MediaStore';
import { VectorFormats } from '../vector/VectorFormats';
import { GdalVectorReader } from '../vector/GdalVectorReader';
import { BusinessOverlayManager, OverlayHit, OverlayKind } from './BusinessOverlayManager';
import { MapLayerController } from './MapLayerController';
import { MapStyle } from './MapStyle';
import { MeasureController } from './MeasureController';
import { SqlQueryController } from './SqlQueryController';

const TAG: string = 'FeaturePickController';

/** 属性写回支持的格式（GDAL 驱动能力矩阵：dwg 只读） */
const WRITABLE_FORMATS: string[] = ['shp', 'dxf', 'gpkg', 'geojson', 'kml', 'kmz'];

/** 要素详情请求：控制器组装、宿主渲染；attributes 在组装后异步回填 */
export class FeatureDetailRequest {
  path: string = '';
  fid: number = -1;
  /** 所属图层名（文档未登记该路径时为空） */
  layerName: string = '';
  /** 几何类型：0 点 / 1 线 / 2 面 / -1 未知 */
  geomType: number = -1;
  /** 量算文本（面=面积+周长、线=长度；点为空表示不显示该行） */
  geometryText: string = '';
  /** 单要素样式覆盖（保存时写回 layerInfo.vectorStyle.featureStyles[fid]） */
  style: StyleOverride = new StyleOverride();
  /** 是否开放样式编辑（shp/gpkg） */
  styleEditable: boolean = false;
  /** 是否开放属性编辑（可写格式 + 有效 FID，且非 KML 系） */
  attrsEditable: boolean = false;
  /** 是否显示样地调查入口（shp 面要素） */
  surveyEntry: boolean = false;
  /** 无文档样式覆盖时的实际渲染色兜底（色块所见即所得） */
  fallbackFill: string = '';
  fallbackOutline: string = '';
  /** 属性表（异步回填；null = 仍在回取） */
  attributes: Map<string, string> | null = null;
  /** KML/KMZ 的 description 字段（HTML，宿主富文本渲染） */
  description: string = '';
  /**
   * 面要素外环坐标 [lat,lon] 列表（非面或取不到几何时为空）。
   * 供页面侧做「定位点是否落在图斑内」判定——页面拿不到 NativeMapView，几何只能随请求一并下发。
   */
  outerRingLatLon: number[][] = [];
  /**
   * 图层样式模式：由图层管理页进入，编辑的是整层默认样式而非单要素。
   * 此模式下无要素概念（隐藏要素ID/属性页签），fid 置 -1。
   */
  layerStyleMode: boolean = false;
}

/** 拾取分流路由：叠加层命中后的记录详情/编辑入口回宿主完成（对话框专属逻辑留页面） */
export class PickRouter {
  /** 测量叠加命中（含标注层） */
  onMeasureHit: (recordId: number) => void = (): void => {};
  /** 轨迹叠加命中 */
  onTrackHit: (recordId: number) => void = (): void => {};
  /** 拍照点位命中 */
  onMediaHit: (placemark: MediaPlacemark) => void = (): void => {};
  /** 样地点位命中 */
  onSurveyHit: (plotId: number) => void = (): void => {};
  /** 文件矢量要素命中：宿主弹详情层 */
  onFeatureDetail: (req: FeatureDetailRequest) => void = (): void => {};
  /** 属性回取完成：宿主就地回填已显示的详情层 */
  onFeatureAttributes: (req: FeatureDetailRequest) => void = (): void => {};
}

export class FeaturePickController {
  private readonly view: NativeMapView;
  private readonly ctx: common.Context;
  private readonly layerManager: MapLayerController;
  private readonly overlayManager: BusinessOverlayManager;
  private readonly queryController: SqlQueryController;
  private readonly measureController: MeasureController;
  private readonly router: PickRouter;

  /** 选中高亮层索引 + 源文件路径/FID（高亮层 noPick，缓存仅作穿透兜底） */
  private selectedHighlightIndex: number = -1;
  private selectedPath: string | undefined = undefined;
  private selectedFid: number = -1;

  constructor(view: NativeMapView, ctx: common.Context, layerManager: MapLayerController,
    overlayManager: BusinessOverlayManager, queryController: SqlQueryController,
    measureController: MeasureController, router: PickRouter) {
    this.view = view;
    this.ctx = ctx;
    this.layerManager = layerManager;
    this.overlayManager = overlayManager;
    this.queryController = queryController;
    this.measureController = measureController;
    this.router = router;
  }

  /**
   * 单击地图拾取矢量要素：native 命中检测（屏幕点 → 图层索引/FID），命中则按 FID 回取属性并弹详情层。
   * 未命中任何矢量要素时不弹窗（底图/注记不参与点选）。
   */
  onMapTap(x: number, y: number): void {
    // 测量采集模式：拦截点击用于加点（优先于拾取）
    if (this.measureController.handleTap(x, y)) {
      return;
    }
    const hit = this.view.pickVector(x, y);
    if (hit === undefined) {
      // 点击空白：取消要素选中高亮
      this.clearSelectedHighlight();
      return;
    }
    const layerIndex: number = hit.layerIndex;
    const fid: number = hit.fid;
    // 业务叠加命中（测量/轨迹/拍照/样地/查询高亮/选中高亮）：分流并消费点击
    if (this.handleOverlayHit(layerIndex, fid)) {
      return;
    }
    // 文件矢量命中：画黄色选中高亮 + 按 FID 回取属性并弹详情层
    const info: LayerInfo | undefined = this.layerManager.layerInfoByIndex(layerIndex);
    if (info === undefined) {
      // 异常态：native 回了层号但上层未登记（层表与 native 层序失同步），点击被静默吞掉
      AppLog.w(`${TAG} 命中未登记图层 index=${layerIndex} fid=${fid}，忽略本次拾取`);
      return;
    }
    const path: string = info.path ?? '';
    if (path.length === 0) {
      return;
    }
    this.highlightSelectedFeature(layerIndex, fid, path);
    this.showVectorFeatureDetail(path, fid);
  }

  /**
   * 业务叠加命中分流：native pickVector 先叠加层后文件层，测量/轨迹/拍照/样地叠加恒优先于矢量要素。
   * @returns 是否命中并消费了该点击
   */
  private handleOverlayHit(layerIndex: number, fid: number): boolean {
    const h: OverlayHit = this.overlayManager.hitTest(layerIndex, fid);
    if (h.kind === OverlayKind.MEASURE) {
      this.router.onMeasureHit(h.recordId);
      return true;
    }
    if (h.kind === OverlayKind.TRACK) {
      this.router.onTrackHit(h.recordId);
      return true;
    }
    if (h.kind === OverlayKind.MEDIA) {
      MediaStore.getInstance(this.ctx).then(async (store: MediaStore): Promise<void> => {
        const placemark: MediaPlacemark | undefined = await store.findPlacemark(h.recordId);
        if (placemark !== undefined) {
          this.router.onMediaHit(placemark);
        }
      });
      return true;
    }
    if (h.kind === OverlayKind.SURVEY) {
      this.router.onSurveyHit(h.recordId);
      return true;
    }
    // SQL 查询高亮层命中：点击穿透到源要素（该层已置 noPick，正常不会命中于此）
    const queryPath: string | undefined = this.queryController.sourcePathIfHit(layerIndex);
    if (queryPath !== undefined) {
      this.showVectorFeatureDetail(queryPath, fid);
      return true;
    }
    // 点击选中高亮层命中：穿透回源要素详情（同上，仅作防护兜底）
    if (layerIndex === this.selectedHighlightIndex && this.selectedPath !== undefined) {
      this.showVectorFeatureDetail(this.selectedPath, this.selectedFid);
      return true;
    }
    return false;
  }

  /**
   * 画文件矢量要素的选中高亮：经 featureGeometry 取该要素经纬度几何（native 反投影，无文件 IO），
   * 用独立叠加层以黄色高亮样式覆盖渲染。切换选中先清旧高亮；高亮层置 noPick 不参与拾取。
   */
  highlightSelectedFeature(layerIndex: number, fid: number, path: string): void {
    this.clearSelectedHighlight();
    const fg: FeatureGeometry | undefined = this.view.featureGeometry(layerIndex, fid);
    if (fg === undefined) {
      return;
    }
    const idx: number = this.view.addOverlayLayer(FeaturePickController.selectStyle());
    if (idx < 0) {
      return;
    }
    this.view.setOverlayNoPick(idx, true);
    this.selectedHighlightIndex = idx;
    this.selectedPath = path;
    this.selectedFid = fid;
    if (fg.type === 0) {
      this.view.updateOverlayPoints(idx, fg.lonlat, [fid]);
    } else if (fg.type === 1) {
      const fids: number[] = FeaturePickController.repeat(fid, fg.ringCounts.length);
      this.view.updateOverlayLines(idx, fg.lonlat, fg.ringCounts, fids);
    } else if (fg.type === 2) {
      const fids: number[] = FeaturePickController.repeat(fid, fg.ringsPerFeature.length);
      this.view.updateOverlayPolygons(idx, fg.lonlat, fg.ringCounts, fg.ringsPerFeature, fids);
    }
  }

  /** 取消要素选中高亮（拆除高亮叠加层并清缓存，幂等）：点击空白或切换选中时调用 */
  clearSelectedHighlight(): void {
    if (this.selectedHighlightIndex >= 0) {
      this.view.removeOverlayLayer(this.selectedHighlightIndex);
    }
    this.selectedHighlightIndex = -1;
    this.selectedPath = undefined;
    this.selectedFid = -1;
  }

  /** 叠加层重建（clearOverlayLayers）后调用：选中为瞬态交互，重建后仅重置失效索引 */
  onOverlayLayersCleared(): void {
    this.selectedHighlightIndex = -1;
  }

  /** 当前选中的源路径（-1/undefined 表示无选中） */
  currentSelection(): string | undefined {
    return this.selectedHighlightIndex >= 0 ? this.selectedPath : undefined;
  }

  /**
   * 弹文件矢量要素详情：弹层先行（几何/样式经 native 同步取，无文件 IO），全字段属性后台回取后就地回填
   * ——KML/DXF 等格式首次回取需重开文件解析可达秒级，故不让弹窗等待。
   * 样式编辑限 shp/gpkg；属性编辑限可写格式且非 KML 系；样地调查入口限 shp 面要素。
   */
  showVectorFeatureDetail(path: string, fid: number): void {
    if (path.length === 0 || fid < 0) {
      return;
    }
    const doc = DocumentManager.getInstance().getDocument();
    let layerInfo: LayerInfo | undefined = undefined;
    if (doc !== null) {
      for (let i = 0; i < doc.vectorLayers.length; i++) {
        if (doc.vectorLayers[i].path === path) {
          layerInfo = doc.vectorLayers[i];
          break;
        }
      }
    }
    const ext: string = VectorFormats.extOf(path);
    // native 矢量层索引：供 featureGeometry 取几何类型（点/线/面）与量算
    const layerIndex: number = layerInfo === undefined ? -1 : this.layerManager.nativeIndexOf(layerInfo);
    // shp/gpkg 均为 GDAL 索引矢量，支持整层/单要素样式覆盖；kml/kmz 无 fid、dwg/dxf 只读
    const styleEditable: boolean = (ext === 'shp' || ext === 'gpkg') && fid >= 0;
    // 属性可编辑：可写格式 + 有效 FID（编辑权限由页面「编辑」按键门控，此处只判定能力）
    const attrsEditable: boolean = fid >= 0 && WRITABLE_FORMATS.indexOf(ext) >= 0
      && ext !== 'kml' && ext !== 'kmz';
    const fg: FeatureGeometry | undefined = layerIndex >= 0 ? this.view.featureGeometry(layerIndex, fid) : undefined;
    const req: FeatureDetailRequest = new FeatureDetailRequest();
    req.path = path;
    req.fid = fid;
    req.layerName = layerInfo === undefined ? '' : (layerInfo.name ?? '');
    req.geomType = fg === undefined ? -1 : fg.type;
    req.geometryText = FeaturePickController.geometryText(fg);
    req.style = FeaturePickController.mergedStyle(layerInfo, fid);
    req.styleEditable = styleEditable;
    req.attrsEditable = attrsEditable;
    // 样地调查入口：shp 面要素（不再依赖全局调查模式）
    req.surveyEntry = ext === 'shp' && req.geomType === 2 && fid >= 0;
    const colors: string[] = this.layerManager.layerRenderColorsOf(path);
    req.fallbackFill = colors.length > 0 ? colors[0] : '';
    req.fallbackOutline = colors.length > 1 ? colors[1] : '';
    req.outerRingLatLon = FeaturePickController.outerRing(fg);
    this.router.onFeatureDetail(req);
    // 属性异步回取 + 就地回填（让出一帧保证弹窗先显示）
    setTimeout((): void => {
      const t0: number = Date.now();
      const attrs: Map<string, string> | null = GdalVectorReader.getFeatureAttributes(path, fid);
      req.attributes = attrs;
      if (attrs !== null) {
        const desc: string | undefined = FeaturePickController.descriptionOf(attrs);
        req.description = desc === undefined ? '' : desc;
      }
      AppLog.i(`${TAG} 属性回取 fid=${fid} fields=${attrs === null ? 0 : attrs.size} 耗时${Date.now() - t0}ms`);
      this.router.onFeatureAttributes(req);
    }, 0);
  }

  /** 保存单要素样式覆盖：写回 layerInfo.vectorStyle.featureStyles[fid] 并递增样式版本驱动换层 */
  saveFeatureStyle(path: string, fid: number, style: StyleOverride): void {
    const doc = DocumentManager.getInstance().getDocument();
    if (doc === null) {
      return;
    }
    let layerInfo: LayerInfo | undefined = undefined;
    for (let i = 0; i < doc.vectorLayers.length; i++) {
      if (doc.vectorLayers[i].path === path) {
        layerInfo = doc.vectorLayers[i];
        break;
      }
    }
    if (layerInfo === undefined) {
      return;
    }
    const layerStyle: StyleOverride = layerInfo.vectorStyle ?? new StyleOverride();
    layerInfo.vectorStyle = layerStyle;
    if (style.isEmpty()) {
      layerStyle.featureStyles.delete(fid);
    } else {
      layerStyle.featureStyles.set(fid, style);
    }
    layerInfo.styleVersion += 1;
    // 保存后文档变更触发就地换层（样式版本入缓存键），旧选中高亮随层失效，先取消选中态
    this.clearSelectedHighlight();
    DocumentManager.getInstance().save();
  }

  /**
   * 保存整层默认样式（图层管理页）：覆盖 vectorStyle 但保留已有的单要素覆盖，同样递增样式版本驱动换层。
   * 传入空样式 = 恢复默认（清除整层覆盖字段，单要素覆盖仍在，与原 Android 图层样式模式一致）。
   */
  saveLayerStyle(path: string, style: StyleOverride): void {
    const doc = DocumentManager.getInstance().getDocument();
    if (doc === null) {
      return;
    }
    let layerInfo: LayerInfo | undefined = undefined;
    for (let i = 0; i < doc.vectorLayers.length; i++) {
      if (doc.vectorLayers[i].path === path) {
        layerInfo = doc.vectorLayers[i];
        break;
      }
    }
    if (layerInfo === undefined) {
      return;
    }
    const prev: StyleOverride | undefined = layerInfo.vectorStyle;
    const next: StyleOverride = StyleOverride.copy(style);
    // featureStyles 不参与整层编辑，原样搬运（copy 已带入，此处仅在传入空样式时保住旧覆盖）
    if (prev !== undefined && style.featureStyles.size === 0) {
      prev.featureStyles.forEach((value: StyleOverride, key: number): void => {
        next.featureStyles.set(key, value);
      });
    }
    layerInfo.vectorStyle = next;
    layerInfo.styleVersion += 1;
    DocumentManager.getInstance().save();
  }

  /**
   * 属性写回（调查编辑）：调 GDAL 写回源文件。
   * 本侧无 gc renderable 属性缓存，故仅写回源文件（下次拾取/重载即取到新值）。
   */
  persistAttributes(path: string, fid: number, pending: Map<string, string>): boolean {
    if (pending.size === 0) {
      return true;
    }
    let success: boolean = false;
    try {
      success = GdalVectorReader.updateAttributes(path, fid, pending);
    } catch (e) {
      AppLog.e('属性写回异常', e);
    }
    Ui.toast(success ? '属性已保存' : '属性保存失败');
    return success;
  }

  /**
   * 面要素外环（ringCounts[0]）→ [lat,lon] 列表；非面或顶点不足 3 个返回空数组。
   * lonlat 为 [lon,lat,…] 摊平，故换序输出。
   */
  static outerRing(fg: FeatureGeometry | undefined): number[][] {
    const out: number[][] = [];
    if (fg === undefined || fg.type !== 2 || fg.ringCounts.length === 0) {
      return out;
    }
    const count: number = fg.ringCounts[0];
    if (count < 3 || count * 2 > fg.lonlat.length) {
      return out;
    }
    for (let k = 0; k < count; k++) {
      out.push([fg.lonlat[k * 2 + 1], fg.lonlat[k * 2]]);
    }
    return out;
  }

  /** 从属性表提取 KML/KMZ 的 description（大小写不敏感），空值视为无 */
  private static descriptionOf(attrs: Map<string, string>): string | undefined {
    let out: string | undefined = undefined;
    attrs.forEach((value: string, key: string): void => {
      if (out === undefined && key.toLowerCase() === 'description' && value.trim().length > 0) {
        out = value;
      }
    });
    return out;
  }

  /** 单要素样式初值：覆盖优先、缺省继承整层样式（供控件回显） */
  private static mergedStyle(layerInfo: LayerInfo | undefined, fid: number): StyleOverride {
    const layerStyle: StyleOverride | undefined = layerInfo === undefined ? undefined : layerInfo.vectorStyle;
    const featureStyle: StyleOverride | undefined =
      layerStyle === undefined ? undefined : layerStyle.featureStyles.get(fid);
    if (featureStyle !== undefined) {
      return featureStyle.mergedWith(layerStyle);
    }
    if (layerStyle !== undefined) {
      return StyleOverride.copy(layerStyle);
    }
    return new StyleOverride();
  }

  /**
   * 要素几何量算（基于 native featureGeometry 返回的经纬度几何）：
   * 面=面积+周长（带洞按各环带符号面积代数和）、线=长度、点/无几何返回空串（详情层隐藏该行）。
   * lonlat 为 [lon,lat,…] 摊平，按 ringCounts 拆环后换序喂 GeoCalc。
   */
  static geometryText(fg: FeatureGeometry | undefined): string {
    if (fg === undefined) {
      return '';
    }
    const lonlat: number[] = fg.lonlat;
    if (fg.type === 2) {
      let signedArea: number = 0;
      let perimeter: number = 0;
      let hasRing: boolean = false;
      let offset: number = 0;
      for (let i = 0; i < fg.ringCounts.length; i++) {
        const count: number = fg.ringCounts[i];
        if (count >= 3 && offset + count * 2 <= lonlat.length) {
          const ring: LatLng[] = [];
          for (let k = 0; k < count; k++) {
            ring.push(new LatLng(lonlat[offset + k * 2 + 1], lonlat[offset + k * 2]));
          }
          signedArea += GeoCalc.polygonSignedAreaSquareMeters(ring);
          perimeter += GeoCalc.ringPerimeterMeters(ring);
          hasRing = true;
        }
        offset += count * 2;
      }
      if (!hasRing) {
        return '';
      }
      return `面积：${GeoCalc.formatArea(Math.abs(signedArea))}`
        + `    周长：${GeoCalc.formatDistance(perimeter)}`;
    }
    if (fg.type === 1) {
      const n: number = Math.floor(lonlat.length / 2);
      if (n < 2) {
        return '';
      }
      const degrees: LatLng[] = [];
      for (let i = 0; i < n; i++) {
        degrees.push(new LatLng(lonlat[i * 2 + 1], lonlat[i * 2]));
      }
      return `长度：${GeoCalc.formatDistance(GeoCalc.polylineLengthMeters(degrees))}`;
    }
    return '';
  }

  /** 选中高亮样式（黄色） */
  private static selectStyle(): VectorStyle {
    const style = MapStyle.defaultStyle();
    style.fillColor = MapStyle.SELECT_FILL;
    style.outlineColor = MapStyle.SELECT_OUTLINE;
    style.outlineWidth = MapStyle.SELECT_LINE_WIDTH;
    style.lineColor = MapStyle.SELECT_OUTLINE;
    style.lineWidth = MapStyle.SELECT_LINE_WIDTH;
    style.pointColor = MapStyle.SELECT_OUTLINE;
    style.pointRadiusDp = MapStyle.SELECT_POINT_RADIUS;
    style.labelField = '';
    return style;
  }

  private static repeat(fid: number, times: number): number[] {
    const out: number[] = [];
    for (let i = 0; i < times; i++) {
      out.push(fid);
    }
    return out;
  }

  /** 十六进制色文本（详情色块回显） */
  static hexOf(argb: number): string {
    return `#${ColorHex.toHex(argb)}`;
  }
}
