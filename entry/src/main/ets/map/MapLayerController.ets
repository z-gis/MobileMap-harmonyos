// MapLayerController.ets —— 图层栈管理（对应 Android ui.map.MapLayerManager）。
//
// 职责：瓦片底图/注记 + 矢量 + 栅格三类图层的常驻装配、可见性驱动、懒加入同步与结构签名判定。
// 内核约束决定了整体策略（与 Android 同一内核实现，故口径完全一致）：
//  · addTileLayer 返回 void 且无删除能力 → 底图源**一次装配常驻**，切底图只翻 setLayerVisible；
//  · addRasterLayer 返回 index 且与瓦片共享索引空间，同样无删除能力 → 结构变化须由宿主重建页面；
//  · addVectorLayer 有 removeVectorLayer（墓碑）→ 样式/增删变化可**就地换层**，不重建界面；
//  · 懒加入：不可见层不下发 native，避免无谓的 GDAL 读取与加载胶囊误亮，首次转可见时再补加入。
// 依赖单向：构造注入内核视图引用，非结构变化时的就地同步在此完成，需重建时返回 true 交宿主。

import { NativeMapView, VectorExtent } from 'globecore';
import { AppDirs } from '../common/AppDirs';
import { AppLog } from '../common/AppLog';
import { ColorHex } from '../common/ColorHex';
import { MapStyle } from './MapStyle';
import { StyleOverride, LayerInfo, MapDocument, MapSource } from '../doc/DocModels';
import { DocumentManager } from '../doc/DocumentManager';
import { FeatureIcons } from '../vector/FeatureIcons';
import { GdalVectorReader } from '../vector/GdalVectorReader';
import { VectorFormats, VectorReloadConfig } from '../vector/VectorFormats';

const TAG: string = 'MapLayerController';

/** 小数据全量渲染阈值：要素总数 < 此值一次性全量渲染、不参与相机静止重载（与 Android 同参数） */
const DIRECT_RENDER_LIMIT: number = 5000;
/** 单次加载要素预算：0 = 取内核硬上限（兜底防 OOM） */
const MAX_FEATURES_BUDGET: number = VectorReloadConfig.MAX_FEATURES_PER_LAYER;
/** 相机静止重载的范围变化阈值：边界位移超过屏幕跨度的此比例才触发重载（去抖小幅平移） */
const EXTENT_CHANGE_RATIO: number = 0.1;
/** 矢量加载提示：加载启动后延迟显示阈值（快速加载不超过此值则永不闪现） */
const VECTOR_LOADING_SHOW_DELAY_MS: number = 500;
/** 提示显示后的状态轮询间隔 */
const VECTOR_LOADING_POLL_MS: number = 250;

export class MapLayerController {
  private readonly view: NativeMapView;
  /** 常驻底图源（按文档顺序的非注记图源）：索引与 native 图层栈 0..N-1 对齐 */
  private baseLayers: MapSource[] = [];
  /** 注记图层在 native 渲染栈中的索引（= 底图源数量）；-1 表示无注记源 */
  private annotationLayerIndex: number = -1;
  /** 注记图层当前可见性（与文档 MapSource.visible 同步） */
  private annotationVisible: boolean = false;
  /** 构建图层栈时的图源结构签名；图源结构变化时据此判定需重建 */
  private builtSignature: string = '';

  /** 已加入 native 的矢量图层：vectorKey → native 索引（add-only，隐层只翻可见性） */
  private vectorLayerIndices: Map<string, number> = new Map<string, number>();
  /** 构建矢量层时的结构签名（各矢量层 path#styleVersion 有序拼接），仅用于日志与调试回显 */
  private builtVectorSignature: string = '';
  /** 小数据全量层键集合：整文件一次渲染，不参与相机静止重载（避免平移时要素数跳变闪烁） */
  private directVectorKeys: Set<string> = new Set<string>();
  /** 各重载层上次成功应用的屏幕范围（extent 无实质变化则去重） */
  private lastExtentByKey: Map<string, VectorExtent> = new Map<string, VectorExtent>();
  /** 屏外或级别不足而挂起的大数据矢量层键集合，相机静止后满足条件再补加入 */
  private pendingViewportKeys: Set<string> = new Set<string>();
  /** 各矢量层数据四至缓存：避免重复开文件；值为 undefined = 读取失败（不缓存成功语义，下次重试） */
  private dataExtentByKey: Map<string, VectorExtent | undefined> = new Map<string, VectorExtent | undefined>();

  /** 已加入 native 的栅格图层：path → native 索引（与瓦片底图/注记共享索引空间） */
  private rasterLayerIndices: Map<string, number> = new Map<string, number>();
  /** 栅格层结构签名（各栅格层 path 有序拼接）；变化则需重建界面（native 无删除栅格层能力） */
  private builtRasterSignature: string = '';

  /** 加载提示回调（宿主显示/收起「矢量加载中」胶囊）；未接线则不通知 */
  onVectorLoadingChange: ((loading: boolean) => void) | undefined = undefined;
  /** 无可见底图源时的提示回调（宿主 Toast） */
  onNoBaseSource: (() => void) | undefined = undefined;
  /** 提供当前相机可见的 WGS84 屏幕范围（宿主接线 CameraNavigator.computeVisibleExtent） */
  extentProvider: (() => VectorExtent | undefined) | undefined = undefined;
  /** 文档可见性开关（测量/轨迹/照片层）变化时的叠加层重绘回调 */
  onRebuildOverlays: (() => void) | undefined = undefined;

  private showTimer: number = -1;
  private pollTimer: number = -1;

  constructor(view: NativeMapView) {
    this.view = view;
    // 矢量标注字体：内核默认探测系统 CJK 字体，此处显式留空走探测分支（与 demo 一致）
    this.view.setFontPath('');
  }

  /** 宿主销毁时取消一切挂起任务，避免定时器回调触碰已销毁组件 */
  dispose(): void {
    this.cancelLoadingTimers();
  }

  /**
   * 装配瓦片图层栈：文档中全部非注记底图源常驻加入（索引 0..N-1），可见性逐个翻转；
   * 注记源作为 overlay 置顶加入（索引 N）。记录结构签名供文档变更时判定是否需重建。
   * 只能调用一次（native 无删除瓦片层能力），宿主以页面重建对应图源结构变化。
   */
  buildLayers(doc: MapDocument | null): void {
    if (doc === null) {
      return;
    }
    let index: number = 0;
    const bases: MapSource[] = doc.baseSources();
    for (let i = 0; i < bases.length; i++) {
      const src: MapSource = bases[i];
      this.addTileSource(src, false);
      this.view.setLayerVisible(index, src.visible);
      this.baseLayers.push(src);
      index++;
    }
    const annot: MapSource | undefined = doc.annotationSource();
    if (annot !== undefined) {
      this.annotationLayerIndex = index;
      this.addTileSource(annot, true);
      this.view.setLayerVisible(index, annot.visible);
      this.annotationVisible = annot.visible;
      index++;
    }
    let anyVisible: boolean = false;
    for (let i = 0; i < bases.length; i++) {
      if (bases[i].visible) {
        anyVisible = true;
        break;
      }
    }
    if (!anyVisible) {
      AppLog.w('未找到可见底图图源，地图仅显示占位网格');
      if (this.onNoBaseSource !== undefined) {
        this.onNoBaseSource();
      }
    }
    this.builtSignature = MapLayerController.sourceSignature(doc);
    AppLog.i(`底图栈装配完成：${this.baseLayers.length} 源 + 注记=${this.annotationLayerIndex}`);
  }

  /**
   * 文档变更响应：
   *  · 图源/栅格结构变化 → 返回 true 交宿主重建页面（native 无删除瓦片/栅格层能力）；
   *  · 否则就地同步可见性/矢量层/栅格层并刷新叠加层，返回 false。
   */
  onDocumentChanged(document: MapDocument): boolean {
    if (MapLayerController.sourceSignature(document) !== this.builtSignature
      || MapLayerController.rasterSignature(document) !== this.builtRasterSignature) {
      return true;
    }
    this.applyVisibilities(document);
    this.syncRasterLayers(document);
    this.syncVectorLayers(document);
    // 测量/轨迹/拍照可见性开关随设置落盘经此到达：按数据签名刷新叠加层
    if (this.onRebuildOverlays !== undefined) {
      this.onRebuildOverlays();
    }
    return false;
  }

  /** 按文档可见性翻转常驻底图层（索引 0..N-1）与注记层 */
  applyVisibilities(doc: MapDocument): void {
    const bases: MapSource[] = doc.baseSources();
    for (let i = 0; i < bases.length; i++) {
      if (i < this.baseLayers.length) {
        this.view.setLayerVisible(i, bases[i].visible);
      }
    }
    const annot: MapSource | undefined = doc.annotationSource();
    if (annot !== undefined && this.annotationLayerIndex >= 0) {
      this.annotationVisible = annot.visible;
      this.view.setLayerVisible(this.annotationLayerIndex, this.annotationVisible);
    }
  }

  /** 当前注记可见性（界面按钮回显） */
  isAnnotationVisible(): boolean {
    return this.annotationVisible;
  }

  /** 注记图层索引；-1 = 文档无注记源，按钮应置灰 */
  getAnnotationIndex(): number {
    return this.annotationLayerIndex;
  }

  /**
   * 注记显隐开关：即时翻转 native 可见性保证跟手 → 写回文档落盘（落盘后经文档变更监听再次幂等应用）。
   * @returns 切换后的可见性；无注记源返回原值
   */
  toggleAnnotation(): boolean {
    if (this.annotationLayerIndex < 0) {
      AppLog.w('无注记图源，注记开关不可用');
      return this.annotationVisible;
    }
    this.annotationVisible = !this.annotationVisible;
    this.view.setLayerVisible(this.annotationLayerIndex, this.annotationVisible);
    DocumentManager.getInstance().setAnnotationVisible(this.annotationVisible);
    return this.annotationVisible;
  }

  /**
   * 切换唯一可见底图（天地图/高德等扩展底图入口）：文档落盘后由 onDocumentChanged
   * 的 applyVisibilities 即时生效，无需重建 native 图层。
   */
  setActiveBaseMap(name: string): boolean {
    const ok: boolean = DocumentManager.getInstance().setActiveBaseMap(name);
    if (ok) {
      const doc: MapDocument | null = DocumentManager.getInstance().getDocument();
      if (doc !== null) {
        this.applyVisibilities(doc);
      }
    }
    return ok;
  }

  /**
   * 同步文档矢量图层到 native（懒加入 + 可见性驱动）：
   *  · 旧键失效（样式版本变化 / 图层移除）→ removeVectorLayer 墓碑，就地换层不闪屏；
   *  · 新增：可见、文件存在、级别达标且未加入的层才下发 native；
   *  · 显隐：已加入层按文档可见性翻转，并同级别可见性下限。
   */
  syncVectorLayers(doc: MapDocument | null): void {
    if (doc === null) {
      return;
    }
    const infos: LayerInfo[] = doc.vectorLayers;
    // 旧键失效检测：样式改动或图层移除 → 墓碑旧层并清理其全部派生状态
    const currentKeys: Set<string> = new Set<string>();
    for (let i = 0; i < infos.length; i++) {
      const path: string = infos[i].path ?? '';
      if (path.length > 0) {
        currentKeys.add(MapLayerController.vectorKey(infos[i]));
      }
    }
    const staleKeys: string[] = [];
    this.vectorLayerIndices.forEach((idx: number, key: string) => {
      if (!currentKeys.has(key)) {
        staleKeys.push(key);
      }
    });
    for (let i = 0; i < staleKeys.length; i++) {
      const key: string = staleKeys[i];
      const idx: number | undefined = this.vectorLayerIndices.get(key);
      if (idx !== undefined) {
        AppLog.i(`矢量层旧键失效，就地换层: ${key} -> removeVectorLayer(${idx})`);
        this.view.removeVectorLayer(idx);
      }
      this.vectorLayerIndices.delete(key);
      this.directVectorKeys.delete(key);
      this.lastExtentByKey.delete(key);
      this.pendingViewportKeys.delete(key);
      this.dataExtentByKey.delete(key);
    }
    // 新增（懒加入）
    const camLevel: number = this.view.cameraZoomLevel();
    for (let i = 0; i < infos.length; i++) {
      const info: LayerInfo = infos[i];
      const path: string = info.path ?? '';
      if (path.length === 0 || !info.visible) {
        continue;
      }
      const key: string = MapLayerController.vectorKey(info);
      if (this.vectorLayerIndices.has(key)) {
        continue;
      }
      if (this.pendingViewportKeys.has(key)) {
        // 已挂起：级别仍不达标则继续等相机静止补加入；已达标则解除挂起照常加入
        if (info.effectiveMinDisplayLevel() > camLevel) {
          continue;
        }
        this.pendingViewportKeys.delete(key);
      }
      if (!AppDirs.exists(path)) {
        AppLog.w(`矢量文件不存在，跳过[${info.displayName()}]: ${path}`);
        continue;
      }
      if (info.effectiveMinDisplayLevel() > camLevel) {
        this.pendingViewportKeys.add(key);
        continue;
      }
      const idx: number = this.addVectorLayerNative(info, path);
      if (idx >= 0) {
        this.vectorLayerIndices.set(key, idx);
      }
    }
    // 显隐 + 级别下限同步（图层管理对话框改级别后即时生效）
    for (let i = 0; i < infos.length; i++) {
      const info: LayerInfo = infos[i];
      const path: string = info.path ?? '';
      if (path.length === 0) {
        continue;
      }
      const idx: number | undefined = this.vectorLayerIndices.get(MapLayerController.vectorKey(info));
      if (idx === undefined) {
        continue;
      }
      this.view.setVectorLayerVisible(idx, info.visible);
      this.view.setVectorMinLevel(idx, Math.max(0, info.effectiveMinDisplayLevel()));
    }
    this.builtVectorSignature = MapLayerController.vectorSignature(doc);
  }

  /**
   * 同步文档栅格图层到 native（懒加入 + 可见性驱动，与矢量层同口径）。
   * 栅格无删除能力，结构变化由 onDocumentChanged 判定并交宿主重建。
   */
  syncRasterLayers(doc: MapDocument | null): void {
    if (doc === null) {
      return;
    }
    const infos: LayerInfo[] = doc.rasterLayers;
    for (let i = 0; i < infos.length; i++) {
      const info: LayerInfo = infos[i];
      const path: string = info.path ?? '';
      if (path.length === 0 || !info.visible) {
        continue;
      }
      if (this.rasterLayerIndices.has(path)) {
        continue;
      }
      if (!AppDirs.exists(path)) {
        AppLog.w(`栅格文件不存在，跳过[${info.displayName()}]: ${path}`);
        continue;
      }
      const idx: number = this.view.addRasterLayer(AppDirs.rasterTileDir(path), path);
      if (idx >= 0) {
        this.rasterLayerIndices.set(path, idx);
      }
    }
    for (let i = 0; i < infos.length; i++) {
      const info: LayerInfo = infos[i];
      const path: string = info.path ?? '';
      if (path.length === 0) {
        continue;
      }
      const idx: number | undefined = this.rasterLayerIndices.get(path);
      if (idx === undefined) {
        continue;
      }
      this.view.setLayerVisible(idx, info.visible);
    }
    this.builtRasterSignature = MapLayerController.rasterSignature(doc);
  }

  /**
   * 相机静止回调（宿主接线 CameraNavigator.onCameraSettled）：按新屏幕范围重载可见的大数据矢量层。
   * 仅对非 direct（大数据）且已加入 native 的可见层生效；extent 相对上次无实质变化则跳过。
   */
  onCameraSettled(extent: VectorExtent): void {
    const doc: MapDocument | null = DocumentManager.getInstance().getDocument();
    if (doc === null) {
      return;
    }
    const camLevel: number = this.view.cameraZoomLevel();
    // 补加入：先前因屏外/级别挂起的大数据层，现满足条件则正常懒加入
    if (this.pendingViewportKeys.size > 0) {
      const keys: string[] = Array.from(this.pendingViewportKeys);
      for (let i = 0; i < keys.length; i++) {
        const key: string = keys[i];
        let info: LayerInfo | undefined = undefined;
        for (let j = 0; j < doc.vectorLayers.length; j++) {
          if (MapLayerController.vectorKey(doc.vectorLayers[j]) === key) {
            info = doc.vectorLayers[j];
            break;
          }
        }
        if (info === undefined) {
          this.pendingViewportKeys.delete(key); // 已从文档移除
          continue;
        }
        const path: string = info.path ?? '';
        if (path.length === 0 || !info.visible || !AppDirs.exists(path)
          || info.effectiveMinDisplayLevel() > camLevel) {
          continue; // 保持挂起：转可见/级别达标后再试
        }
        const bbox: VectorExtent | undefined = this.dataExtentOf(key, path);
        if (bbox !== undefined && !MapLayerController.extentIntersects(bbox, extent)) {
          continue; // 仍屏外，继续挂起
        }
        this.pendingViewportKeys.delete(key);
        const idx: number = this.addVectorLayerNative(info, path);
        if (idx >= 0) {
          this.vectorLayerIndices.set(key, idx);
          AppLog.i(`屏外挂起层补加入[${info.displayName()}] idx=${idx}`);
        }
      }
    }
    const layers: LayerInfo[] = doc.vectorLayers;
    for (let i = 0; i < layers.length; i++) {
      const info: LayerInfo = layers[i];
      const path: string = info.path ?? '';
      if (path.length === 0 || !info.visible) {
        continue;
      }
      if (info.effectiveMinDisplayLevel() > camLevel) {
        continue; // 级别不足隐藏中，不发无谓重载
      }
      const key: string = MapLayerController.vectorKey(info);
      if (this.directVectorKeys.has(key)) {
        continue; // 小数据全量层不重载
      }
      const idx: number | undefined = this.vectorLayerIndices.get(key);
      if (idx === undefined) {
        continue;
      }
      if (!MapLayerController.extentChanged(this.lastExtentByKey.get(key), extent)) {
        continue;
      }
      this.view.updateVectorExtent(idx, extent, MAX_FEATURES_BUDGET);
      this.lastExtentByKey.set(key, extent);
      this.notifyVectorLoadStarted();
    }
  }

  /**
   * 矢量加载启动入口：延迟 VECTOR_LOADING_SHOW_DELAY_MS 后仍在加载才通知显示，
   * 显示后按 VECTOR_LOADING_POLL_MS 轮询至完成收起。幂等可重复调用。
   */
  notifyVectorLoadStarted(): void {
    if (this.onVectorLoadingChange === undefined) {
      return;
    }
    this.cancelLoadingTimers();
    this.showTimer = setTimeout((): void => {
      this.showTimer = -1;
      if (!this.view.isNativeReady() || !this.view.hasVectorLoading()) {
        return;
      }
      const cb: ((loading: boolean) => void) | undefined = this.onVectorLoadingChange;
      if (cb !== undefined) {
        cb(true);
      }
      this.pollTimer = setInterval((): void => {
        if (!this.view.hasVectorLoading()) {
          this.cancelLoadingTimers();
          const done: ((loading: boolean) => void) | undefined = this.onVectorLoadingChange;
          if (done !== undefined) {
            done(false);
          }
        }
      }, VECTOR_LOADING_POLL_MS);
    }, VECTOR_LOADING_SHOW_DELAY_MS);
  }

  /**
   * 加入一个矢量图层到 native：文档样式覆盖映射为内核渲染参数 + 点图标位图 + 大小数据分流。
   * 返回 native 索引（<0 失败 / 挂起）。
   */
  private addVectorLayerNative(info: LayerInfo, path: string): number {
    const override: StyleOverride | undefined = info.vectorStyle;
    const effective: StyleOverride | undefined =
      (override !== undefined && !override.isEmpty()) ? override : undefined;
    // 标注门控：KML/KMZ 额外受 showKmlLabel 开关控制（复刻 Android suppressLabels 口径）
    const doc: MapDocument | null = DocumentManager.getInstance().getDocument();
    const showKmlLabel: boolean = doc === null ? false : doc.systemConfig.showKmlLabel;
    const suppressLabel: boolean = VectorFormats.isKml(path) && !showKmlLabel;
    const labelField: string = suppressLabel ? '' : ((effective !== undefined
      && effective.labelField !== undefined ? effective.labelField.trim() : ''));
    const style = MapStyle.toVectorStyle(effective, labelField);

    // 点要素图标：按 iconKey 程序化生成 ARGB 位图（内核侧作 billboard 纹理，无法自行解码图片资源）
    const iconArgb: number[] = FeatureIcons.pixels(FeatureIcons.keyOf(effective),
      MapStyle.resolveFillColor(
        effective !== undefined && effective.outlineColor !== undefined
          ? effective.outlineColor : MapStyle.argbToHex(MapStyle.DEFAULT_LINE_COLOR),
        1, true));

    // 大小数据分流：< DIRECT_RENDER_LIMIT 走整文件全量（不参与相机重载）；否则按屏幕范围相交加载
    const key: string = MapLayerController.vectorKey(info);
    const count: number = GdalVectorReader.countFeatures(path);
    const direct: boolean = count < 0 || count < DIRECT_RENDER_LIMIT;
    let extent: VectorExtent | undefined = undefined;
    if (!direct && this.extentProvider !== undefined) {
      extent = this.extentProvider();
    }
    // 屏外预判：大数据层四至与屏幕范围确定不相交 → 挂起（免无谓 GDAL 读取与胶囊误亮）
    if (!direct && extent !== undefined) {
      const bbox: VectorExtent | undefined = this.dataExtentOf(key, path);
      if (bbox !== undefined && !MapLayerController.extentIntersects(bbox, extent)) {
        this.pendingViewportKeys.add(key);
        AppLog.i(`矢量层[${info.displayName()}]四至与屏幕范围不相交，挂起待进入视口再加入`);
        return -1;
      }
    }
    const idx: number = this.view.addVectorLayer(path, style, iconArgb,
      MapStyle.DEFAULT_POINT_RADIUS_DP * 2, MapStyle.DEFAULT_POINT_RADIUS_DP * 2,
      extent, MAX_FEATURES_BUDGET);
    if (idx >= 0) {
      this.view.setVectorMinLevel(idx, Math.max(0, info.effectiveMinDisplayLevel()));
      if (direct) {
        this.directVectorKeys.add(key);
        this.lastExtentByKey.delete(key);
      } else {
        this.directVectorKeys.delete(key);
        if (extent !== undefined) {
          this.lastExtentByKey.set(key, extent);
        }
      }
      this.notifyVectorLoadStarted();
    }
    AppLog.i(`矢量层[${info.displayName()}] index=${idx} direct=${direct} count=${count} path=${path}`);
    return idx;
  }

  /** 图层四至缓存读取（WGS84）；未缓存则开文件取一次，失败不写缓存（下次重试） */
  private dataExtentOf(key: string, path: string): VectorExtent | undefined {
    if (this.dataExtentByKey.has(key)) {
      return this.dataExtentByKey.get(key);
    }
    const openPath: string = path.toLowerCase().endsWith('.kmz') ? `/vsizip/${path}` : path;
    const raw: number[] | null = GdalVectorReader.layerExtent(openPath);
    let ext: VectorExtent | undefined = undefined;
    if (raw !== null && raw.length >= 4) {
      ext = new VectorExtent(raw[0], raw[1], raw[2], raw[3]);
    }
    this.dataExtentByKey.set(key, ext);
    return ext;
  }

  /** 由 native 矢量层索引反查文档 LayerInfo（拾取回查用） */
  layerInfoByIndex(index: number): LayerInfo | undefined {
    const doc: MapDocument | null = DocumentManager.getInstance().getDocument();
    if (doc === null) {
      return undefined;
    }
    const layers: LayerInfo[] = doc.vectorLayers;
    for (let i = 0; i < layers.length; i++) {
      const idx: number | undefined = this.vectorLayerIndices.get(MapLayerController.vectorKey(layers[i]));
      if (idx !== undefined && idx === index) {
        return layers[i];
      }
    }
    return undefined;
  }

  /** 文档矢量层对应的 native 层索引（拾取/详情按 FID 回取几何与属性）；未加入返回 -1 */
  nativeIndexOf(info: LayerInfo): number {
    const idx: number | undefined = this.vectorLayerIndices.get(MapLayerController.vectorKey(info));
    return idx === undefined ? -1 : idx;
  }

  /**
   * 矢量图层回显色（填充/描边 hex）：供图层管理预览与样式对话框所见即所得回显。
   * 本侧矢量层完全文档驱动（无源文件内嵌样式），故即「文档样式 ?: 默认色」。
   */
  layerRenderColorsOf(path: string): string[] {
    const doc: MapDocument | null = DocumentManager.getInstance().getDocument();
    if (doc === null) {
      return ['', ''];
    }
    const info: LayerInfo | undefined = doc.findVectorLayer(path);
    if (info === undefined) {
      return ['', ''];
    }
    const override: StyleOverride | undefined = info.vectorStyle;
    const effective: StyleOverride | undefined =
      (override !== undefined && !override.isEmpty()) ? override : undefined;
    // 回显取「文档本色」、**不经填充开关归零**（对齐 Android MapLayerManager.layerRenderColorsOf 用
    // MapStyleColors.resolveFillColor / resolveArgb）：开关关闭只让渲染层 alpha 置 0，
    // 样式页色块仍应显示原色（压淡由 ColorRow.dim 表达）。若改走 toVectorStyle 会得到
    // '#00000000'，表现为「关闭过填充的图层回显颜色为空」。
    const fillHex: string = MapLayerController.colorOr(effective, true,
      `#${ColorHex.toHex(MapStyle.DEFAULT_FILL_COLOR)}`);
    const fill: number = MapStyle.resolveFillColor(fillHex,
      effective === undefined ? undefined : effective.fillOpacity, undefined);
    const outline: number = ColorHex.parse(
      MapLayerController.colorOr(effective, false, ''), MapStyle.DEFAULT_POLYGON_OUTLINE_COLOR);
    return [MapStyle.argbToHex(fill), MapStyle.argbToHex(outline)];
  }

  /** 取覆盖里的颜色串（fill=true 取填充色）：未设置或空串回退默认 hex */
  private static colorOr(o: StyleOverride | undefined, fill: boolean, fallback: string): string {
    if (o === undefined) {
      return fallback;
    }
    const hex: string | undefined = fill ? o.fillColor : o.outlineColor;
    return hex === undefined || hex.length === 0 ? fallback : hex;
  }

  /** 装配一个瓦片图源：解析 URL 模板（Token 占位符替换）+ 磁盘缓存目录，按 overlay 标志加入 */
  private addTileSource(src: MapSource, overlay: boolean): void {
    const urlTemplate: string = src.resolveUrl();
    this.view.addTileLayer(AppDirs.baseTileDir(src.name ?? ''), urlTemplate, src.maxLevel, overlay);
    AppLog.i(`图层[${src.name}] overlay=${overlay} 联网=${urlTemplate.length > 0} maxLevel=${src.maxLevel}`);
  }

  /** 图源结构签名：各图源 sourceKey 有序拼接，任一图源增删改即变 */
  static sourceSignature(doc: MapDocument | null): string {
    if (doc === null) {
      return '';
    }
    const parts: string[] = [];
    const list: MapSource[] = doc.mapSources;
    for (let i = 0; i < list.length; i++) {
      parts.push(list[i].sourceKey());
    }
    return parts.join(';');
  }

  /** 矢量层结构签名：各矢量层 path#styleVersion 有序拼接（样式改动递增 styleVersion） */
  static vectorSignature(doc: MapDocument | null): string {
    if (doc === null) {
      return '';
    }
    const parts: string[] = [];
    const list: LayerInfo[] = doc.vectorLayers;
    for (let i = 0; i < list.length; i++) {
      parts.push(`${list[i].path ?? ''}#${list[i].styleVersion}`);
    }
    return parts.join(';');
  }

  /** 栅格层结构签名：各栅格层 path 有序拼接 */
  static rasterSignature(doc: MapDocument | null): string {
    if (doc === null) {
      return '';
    }
    const parts: string[] = [];
    const list: LayerInfo[] = doc.rasterLayers;
    for (let i = 0; i < list.length; i++) {
      parts.push(list[i].path ?? '');
    }
    return parts.join(';');
  }

  /** 矢量层缓存键：路径 + 样式版本 */
  static vectorKey(info: LayerInfo): string {
    return `${info.path ?? ''}|${info.styleVersion}`;
  }

  /** 两 WGS84 矩形是否相交（边界接触算相交，与内核整层跳过判定同口径） */
  static extentIntersects(a: VectorExtent, b: VectorExtent): boolean {
    return !(a.maxLon < b.minLon || a.minLon > b.maxLon || a.maxLat < b.minLat || a.minLat > b.maxLat);
  }

  /** 屏幕范围是否相对上次有实质变化：任一边界位移超过跨度 EXTENT_CHANGE_RATIO 视为变化。上次为空视为变化 */
  static extentChanged(last: VectorExtent | undefined, next: VectorExtent): boolean {
    if (last === undefined || last === null) {
      return true;
    }
    const lonTol: number = Math.max(Math.abs(last.maxLon - last.minLon),
      Math.abs(next.maxLon - next.minLon)) * EXTENT_CHANGE_RATIO;
    const latTol: number = Math.max(Math.abs(last.maxLat - last.minLat),
      Math.abs(next.maxLat - next.minLat)) * EXTENT_CHANGE_RATIO;
    return Math.abs(last.minLon - next.minLon) > lonTol
      || Math.abs(last.maxLon - next.maxLon) > lonTol
      || Math.abs(last.minLat - next.minLat) > latTol
      || Math.abs(last.maxLat - next.maxLat) > latTol;
  }

  private cancelLoadingTimers(): void {
    if (this.showTimer >= 0) {
      clearTimeout(this.showTimer);
      this.showTimer = -1;
    }
    if (this.pollTimer >= 0) {
      clearInterval(this.pollTimer);
      this.pollTimer = -1;
    }
  }
}
