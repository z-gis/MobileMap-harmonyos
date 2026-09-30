// DocumentManager.ets —— 地图文档单例（对应 Android doc.DocumentManager）。
//
// 在沙箱 调查宝/config/document.json 上读写 MapDocument，加载/保存成功后向监听者广播变更
// （底图切换、图层增删、样式修改的地图同步均由此驱动）。读写宽容失败：读不出即建默认文档并落盘，
// 写不下只记日志，不抛异常中断宿主流程。
//
// 与 Android 的差异：
//  1) 默认文档在原有天地图系列之外追加「高德」系列底图源（用户要求的底图扩展），
//     高德 URL 无 tk 概念，故 token 占位符仅天地图源持有；
//  2) 底图切换语义收敛为「非注记图源中同时仅一个可见」，由 setActiveBaseMap 统一维护，
//     对应 Android 侧在地图源管理页手动勾选的行为（鸿蒙侧提供一键切换 + 仍可在管理页多选叠加）。

import fs from '@ohos.file.fs';
import util from '@ohos.util';
import { common } from '@kit.AbilityKit';
import { AppDirs } from '../common/AppDirs';
import { AppLog } from '../common/AppLog';
import { CoordFormatter } from '../common/Coord';
import { LayerInfo, MapDocument, MapDocumentJson, MapSource, SystemConfig } from './DocModels';

/** 文档变更监听回调（保存成功后在主线程触发） */
export type DocumentListener = (doc: MapDocument) => void;

const DOCUMENT_FILE: string = 'document.json';
const TAG: string = 'DocumentManager';

/** 天地图公共 tk（与 Android 侧同一份，属应用内置演示令牌） */
export const TIANDITU_TOKEN: string = '2c9be3116bec8e3f7be8d0c88298ff06';

export const SOURCE_TIANDITU_IMG: string = '天地图-影像';
export const SOURCE_TIANDITU_VEC: string = '天地图-电子';
export const SOURCE_TIANDITU_TER: string = '天地图-地形';
export const SOURCE_TIANDITU_CIA: string = '天地图-注记';
export const SOURCE_GAODE_VEC: string = '高德-矢量';
export const SOURCE_GAODE_IMG: string = '高德-影像';

const TIANDITU_IMG_URL: string =
  'https://t{rand=0,1,2,3,4,5,6,7}.tianditu.gov.cn/img_w/wmts?SERVICE=WMTS&REQUEST=GetTile&VERSION=1.0.0'
    + '&LAYER=img&STYLE=default&TILEMATRIXSET=w&FORMAT=tiles&TILECOL={x}&TILEROW={y}&TILEMATRIX={z}'
    + '&tk=$tiandituToken';
const TIANDITU_VEC_URL: string =
  'https://t{rand=0,1,2,3,4,5,6,7}.tianditu.gov.cn/vec_w/wmts?SERVICE=WMTS&REQUEST=GetTile&VERSION=1.0.0'
    + '&LAYER=vec&STYLE=default&TILEMATRIXSET=w&FORMAT=tiles&TILECOL={x}&TILEROW={y}&TILEMATRIX={z}'
    + '&tk=$tiandituToken';
const TIANDITU_TER_URL: string =
  'https://t{rand=0,1,2,3,4,5,6,7}.tianditu.gov.cn/ter_w/wmts?SERVICE=WMTS&REQUEST=GetTile&VERSION=1.0.0'
    + '&LAYER=ter&STYLE=default&TILEMATRIXSET=w&FORMAT=tiles&TILECOL={x}&TILEROW={y}&TILEMATRIX={z}'
    + '&tk=$tiandituToken';
const TIANDITU_CIA_URL: string =
  'https://t{rand=0,1,2,3,4,5,6,7}.tianditu.gov.cn/cia_w/wmts?SERVICE=WMTS&REQUEST=GetTile&VERSION=1.0.0'
    + '&LAYER=cia&STYLE=default&TILEMATRIXSET=w&FORMAT=tiles&TILECOL={x}&TILEROW={y}&TILEMATRIX={z}'
    + '&tk=$tiandituToken';
/** 高德矢量（style=8：中文注记已内嵌，故不再另配注记源） */
const GAODE_VEC_URL: string =
  'https://webrd0{rand=1,2,3,4}.is.autonavi.com/appmaptile?lang=zh_cn&size=1&scale=1&style=8'
    + '&x={x}&y={y}&z={z}';
/** 高德影像 + 路网注记（style=6 卫星、style=8 注记叠加） */
const GAODE_IMG_URL: string =
  'https://webst0{rand=1,2,3,4}.is.autonavi.com/appmaptile?style=6&x={x}&y={y}&z={z}';

export class DocumentManager {
  private static instance: DocumentManager | null = null;

  private document: MapDocument | null = null;
  private readonly listeners: DocumentListener[] = [];
  /** 写盘串行队列：保证后发起的保存覆盖先发起的，且不打断宿主流程 */
  private saveChain: Promise<void> = Promise.resolve();
  private context: common.Context | null = null;

  static getInstance(): DocumentManager {
    if (DocumentManager.instance === null) {
      DocumentManager.instance = new DocumentManager();
    }
    return DocumentManager.instance;
  }

  getDocument(): MapDocument | null {
    return this.document;
  }

  /** 便捷取配置：文档未加载时返回默认实例（只读判开关用） */
  getConfig(): SystemConfig {
    const doc: MapDocument | null = this.document;
    return doc === null ? new SystemConfig() : doc.systemConfig;
  }

  registerListener(l: DocumentListener | undefined | null): void {
    if (l !== undefined && l !== null && this.listeners.indexOf(l) < 0) {
      this.listeners.push(l);
    }
  }

  unregisterListener(l: DocumentListener | undefined | null): void {
    const i: number = this.listeners.indexOf(l as DocumentListener);
    if (i >= 0) {
      this.listeners.splice(i, 1);
    }
  }

  /** 从 config 目录加载文档；不存在或解析失败时创建默认文档并立即落盘 */
  loadOrCreate(context: common.Context): void {
    this.context = context;
    const path: string = AppDirs.configFile(DOCUMENT_FILE);
    let loaded: MapDocument | null = null;
    if (AppDirs.exists(path)) {
      try {
        const content: string = DocumentManager.readText(path);
        loaded = MapDocument.fromJson(JSON.parse(content) as MapDocumentJson);
      } catch (e) {
        AppLog.w('读取 document.json 失败，将创建默认文档', `${e}`);
        loaded = null;
      }
    }
    if (loaded === null) {
      loaded = DocumentManager.createDefaultDocument();
    }
    DocumentManager.migrateAnnotationSource(loaded);
    DocumentManager.unifyTiandituTokens(loaded);
    this.document = loaded;
    // 坐标显示格式全局开关同步（CoordFormatter 读取）
    // 先通知再落盘：首屏渲染不必等 IO；默认文档额外同步写一次，保证后续检查能读到磁盘文件
    DocumentManager.applyGlobalConfig(loaded);
    this.notifyListeners();
    if (!AppDirs.exists(path)) {
      try {
        DocumentManager.writeText(path, JSON.stringify(loaded.toJson(), null, 2));
      } catch (e) {
        AppLog.w('同步写 document.json 失败，转为异步保存', `${e}`);
        this.save();
      }
    }
  }

  /** 异步保存当前文档（写成功后广播变更） */
  save(): void {
    const doc: MapDocument | null = this.document;
    const ctx: common.Context | null = this.context;
    if (doc === null) {
      AppLog.w('文档尚未加载，忽略本次保存');
      return;
    }
    DocumentManager.applyGlobalConfig(doc);
    const text: string = JSON.stringify(doc.toJson(), null, 2);
    this.saveChain = this.saveChain.then((): void => {
      try {
        DocumentManager.writeText(AppDirs.configFile(DOCUMENT_FILE), text);
        this.notifyListeners();
      } catch (e) {
        AppLog.e('保存 document.json 失败', e);
      }
      if (ctx === null) {
        AppLog.d('保存链路 context 未记录');
      }
    });
  }

  /** 修改后立即生效：保存并同步广播（设置页开关、图层显隐共用入口） */
  update(mutate: (doc: MapDocument) => void): void {
    const doc: MapDocument | null = this.document;
    if (doc === null) {
      return;
    }
    mutate(doc);
    this.save();
  }

  // ── 底图扩展能力（天地图 + 高德）────────────────────────────────────

  /** 可切换的底图源清单（不含注记层） */
  baseSources(): MapSource[] {
    const doc: MapDocument | null = this.document;
    return doc === null ? [] : doc.baseSources();
  }

  /** 当前生效底图名称：首个可见的非注记源；全不可见返回空串 */
  activeBaseMap(): string {
    const list: MapSource[] = this.baseSources();
    for (let i = 0; i < list.length; i++) {
      if (list[i].visible) {
        return list[i].name ?? '';
      }
    }
    return '';
  }

  /**
   * 切换唯一可见底图：非注记源中仅目标源可见，注记层可见性不受影响。
   * 目标源不在清单内时不做修改，返回是否成功。
   */
  setActiveBaseMap(name: string): boolean {
    const doc: MapDocument | null = this.document;
    if (doc === null) {
      return false;
    }
    let found: boolean = false;
    doc.mapSources.forEach((s: MapSource) => {
      if (s.isAnnotation) {
        return;
      }
      const hit: boolean = s.name === name;
      s.visible = hit;
      if (hit) {
        found = true;
      }
    });
    if (found) {
      this.save();
    }
    return found;
  }

  /** 注记层开关（主界面注记按钮） */
  setAnnotationVisible(visible: boolean): void {
    const doc: MapDocument | null = this.document;
    if (doc === null) {
      return;
    }
    const annotation: MapSource | undefined = doc.annotationSource();
    if (annotation !== undefined) {
      annotation.visible = visible;
      this.save();
    }
  }

  isAnnotationVisible(): boolean {
    const doc: MapDocument | null = this.document;
    if (doc === null) {
      return false;
    }
    const annotation: MapSource | undefined = doc.annotationSource();
    return annotation !== undefined ? annotation.visible : false;
  }

  /** 天地图 Token 共用：改任一天地图源 Token 后同步到全部天地图图层（含注记层） */
  syncTiandituTokens(source: MapSource): void {
    const doc: MapDocument | null = this.document;
    if (doc === null || !source.isTiandituSource()) {
      return;
    }
    doc.mapSources.forEach((s: MapSource) => {
      if (s.isTiandituSource()) {
        s.token1 = source.token1;
        s.token2 = source.token2;
      }
    });
  }

  // ── 内部 ──────────────────────────────────────────────────────────

  private notifyListeners(): void {
    const doc: MapDocument | null = this.document;
    if (doc === null) {
      return;
    }
    // 逐个 try：单个监听器抛异常（页面已销毁等）不得影响其余监听器
    for (let i = 0; i < this.listeners.length; i++) {
      try {
        this.listeners[i](doc);
      } catch (e) {
        AppLog.e('文档监听器执行异常', e);
      }
    }
  }

  /** 把文档里的全局显示开关同步到 common 层的静态门控（避免 common 反向依赖 doc） */
  private static applyGlobalConfig(doc: MapDocument): void {
    CoordFormatter.meterDisplay = doc.systemConfig.coordDisplayMeter;
  }

  private static createDefaultDocument(): MapDocument {
    const doc: MapDocument = new MapDocument();
    // 天地图系列：影像默认可见，电子/地形按需开启（与 Android 默认文档一致）
    doc.mapSources.push(DocumentManager.createTiandituSource(SOURCE_TIANDITU_IMG, TIANDITU_IMG_URL, true, 'image/jpeg'));
    doc.mapSources.push(DocumentManager.createTiandituSource(SOURCE_TIANDITU_VEC, TIANDITU_VEC_URL, false, 'image/png'));
    doc.mapSources.push(DocumentManager.createTiandituSource(SOURCE_TIANDITU_TER, TIANDITU_TER_URL, false, 'image/png'));
    // 底图扩展：高德矢量 / 高德影像（默认不可见，由主界面底图切换条与地图源页按需开启）
    doc.mapSources.push(DocumentManager.createPlainSource(SOURCE_GAODE_VEC, GAODE_VEC_URL, false, 19));
    doc.mapSources.push(DocumentManager.createPlainSource(SOURCE_GAODE_IMG, GAODE_IMG_URL, false, 18));
    // 注记层：不在地图源列表显示，由主界面按钮控制，渲染压在所有图源之上
    doc.mapSources.push(DocumentManager.createAnnotationSource(true));
    doc.systemConfig.showCenterCross = true;
    doc.systemConfig.photoAddWatermark = true;
    return doc;
  }

  private static createTiandituSource(name: string, url: string, visible: boolean,
    imageFormat: string): MapSource {
    const s: MapSource = new MapSource(name, url, visible);
    s.token1 = TIANDITU_TOKEN;
    s.imageFormat = imageFormat;
    s.isSystem = true;
    return s;
  }

  /** 无 Token 的公共图源（高德等） */
  private static createPlainSource(name: string, url: string, visible: boolean,
    maxLevel: number): MapSource {
    const s: MapSource = new MapSource(name, url, visible);
    s.imageFormat = 'image/png';
    s.isSystem = true;
    s.maxLevel = maxLevel;
    return s;
  }

  private static createAnnotationSource(visible: boolean): MapSource {
    const s: MapSource = DocumentManager.createTiandituSource(SOURCE_TIANDITU_CIA, TIANDITU_CIA_URL,
      visible, 'image/png');
    s.isAnnotation = true;
    return s;
  }

  /** 旧文档迁移：把「天地图-注记」标记为注记图层；缺失时补默认注记层 */
  private static migrateAnnotationSource(doc: MapDocument): void {
    let annotation: MapSource | undefined = undefined;
    for (let i = 0; i < doc.mapSources.length; i++) {
      const s: MapSource = doc.mapSources[i];
      if (s.isAnnotation) {
        annotation = s;
        break;
      }
      if (s.name === SOURCE_TIANDITU_CIA) {
        annotation = s;
      }
    }
    if (annotation === undefined) {
      doc.mapSources.push(DocumentManager.createAnnotationSource(true));
    } else {
      annotation.isAnnotation = true;
    }
    // 高德系列缺失时补齐（老文档升级即得底图扩展，不动可见性）
    if (doc.findSource(SOURCE_GAODE_VEC) === undefined) {
      doc.mapSources.splice(DocumentManager.insertPointBeforeAnnotation(doc), 0,
        DocumentManager.createPlainSource(SOURCE_GAODE_VEC, GAODE_VEC_URL, false, 19));
    }
    if (doc.findSource(SOURCE_GAODE_IMG) === undefined) {
      doc.mapSources.splice(DocumentManager.insertPointBeforeAnnotation(doc), 0,
        DocumentManager.createPlainSource(SOURCE_GAODE_IMG, GAODE_IMG_URL, false, 18));
    }
  }

  /** 高德源插入位置：注记层之前（保证注记始终渲染在最上层） */
  private static insertPointBeforeAnnotation(doc: MapDocument): number {
    for (let i = 0; i < doc.mapSources.length; i++) {
      if (doc.mapSources[i].isAnnotation) {
        return i;
      }
    }
    return doc.mapSources.length;
  }

  /** 旧文档迁移：各天地图图层 Token 统一为第一个含 Token 的天地图图层 */
  private static unifyTiandituTokens(doc: MapDocument): void {
    let ref: MapSource | undefined = undefined;
    for (let i = 0; i < doc.mapSources.length; i++) {
      const s: MapSource = doc.mapSources[i];
      if (s.isTiandituSource() && (s.token1 ?? '').length > 0) {
        ref = s;
        break;
      }
    }
    if (ref === undefined) {
      return;
    }
    doc.mapSources.forEach((s: MapSource) => {
      if (s.isTiandituSource()) {
        s.token1 = ref?.token1;
        s.token2 = ref?.token2;
      }
    });
  }

  static readText(path: string): string {
    const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
    try {
      const stat: fs.Stat = fs.statSync(file.fd);
      const buffer = new ArrayBuffer(Math.max(1, stat.size));
      const readLen: number = fs.readSync(file.fd, buffer);
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
      return decoder.decodeToString(new Uint8Array(buffer, 0, readLen));
    } finally {
      fs.closeSync(file);
    }
  }

  static writeText(path: string, text: string): void {
    const dir: string = path.substring(0, path.lastIndexOf('/'));
    if (dir.length > 0) {
      AppDirs.ensureDir(dir);
    }
    const file = fs.openSync(path,
      fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, text);
    } finally {
      fs.closeSync(file);
    }
  }
}
