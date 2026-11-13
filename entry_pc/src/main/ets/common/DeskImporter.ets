// DeskImporter.ets —— 桌面端「添加数据」：系统选择器 URI → 沙箱 layer/ → 可被 GDAL 打开的真实路径。
//
// 为什么必须拷入沙箱：DocumentViewPicker 返回 file://docs/storage/... 形式的临时授权 URI，
// 只有本应用进程可读，GDAL/OGR 无法按该 URI 打开；且 shp 的 dbf/shx/prj/cpg 必须与主文件同目录。
// 口径与手机端 entry/vector/VectorFileImporter 一致（HAP 之间不能互引，故桌面端自持一份精简版）：
//  · 普通文件：主文件 + 同组附属文件一并拷入 layer/（同名覆盖）；
//  · zip：解压到 layer/<主名>/，递归返回包内全部 shp（附属文件天然同目录，不做搬平）；
//  · kmz：解压到 layer/<主名>/，返回内部 kml（优先 doc.kml）。
import fs from '@ohos.file.fs';
import zlib from '@ohos.zlib';
import { DeskDirs } from './DeskDirs';
import { DeskLog } from './DeskLog';

/** 桌面端可添加的数据格式（矢量 + 栅格；读取能力由内核静态链接的 GDAL 驱动决定） */
export class DeskFormats {
  static readonly VECTOR_EXTS: string[] = ['shp', 'gpkg', 'geojson', 'json', 'kml', 'kmz',
    'zip', 'dxf', 'dwg'];
  static readonly RASTER_EXTS: string[] = ['tif', 'tiff', 'img'];
  /** 同名前缀附属文件（选 shp 时一并勾选，或压缩包内自带） */
  static readonly SIDE_CAR_EXTS: string[] = ['dbf', 'shx', 'prj', 'cpg', 'sbn', 'sbx', 'qix',
    'xml', 'tfw', 'ovr', 'aux.xml', 'hdr'];

  /** 选择器过滤后缀（DocumentViewPicker 要求以 '.' 起始） */
  static filters(): string[] {
    const out: string[] = [];
    const all: string[] = DeskFormats.VECTOR_EXTS.concat(DeskFormats.RASTER_EXTS)
      .concat(DeskFormats.SIDE_CAR_EXTS);
    for (let i = 0; i < all.length; i++) {
      const f: string = `.${all[i]}`;
      if (out.indexOf(f) < 0) {
        out.push(f);
      }
    }
    return out;
  }

  static extOf(path: string): string {
    const slash: number = Math.max(path.lastIndexOf('/'), path.lastIndexOf('\\'));
    const name: string = slash >= 0 ? path.substring(slash + 1) : path;
    const dot: number = name.lastIndexOf('.');
    return dot > 0 ? name.substring(dot + 1).toLowerCase() : '';
  }

  static isRaster(path: string): boolean {
    return DeskFormats.RASTER_EXTS.indexOf(DeskFormats.extOf(path)) >= 0;
  }

  static isVector(path: string): boolean {
    return DeskFormats.VECTOR_EXTS.indexOf(DeskFormats.extOf(path)) >= 0;
  }

  static isArchive(path: string): boolean {
    const ext: string = DeskFormats.extOf(path);
    return ext === 'zip' || ext === 'kmz';
  }

  /** 去扩展名主名（图层显示名 / SQL 表名 / 分组键） */
  static stemOf(fileName: string): string {
    const dot: number = fileName.lastIndexOf('.');
    return dot > 0 ? fileName.substring(0, dot) : fileName;
  }

  /** 格式中文名（TOC「源」页签与图层属性用） */
  static labelOf(path: string): string {
    switch (DeskFormats.extOf(path)) {
      case 'shp': return 'Shapefile';
      case 'gpkg': return 'GeoPackage';
      case 'geojson': return 'GeoJSON';
      case 'json': return 'GeoJSON';
      case 'kml': return 'KML';
      case 'kmz': return 'KMZ';
      case 'zip': return 'ZIP（Shapefile 包）';
      case 'dxf': return 'AutoCAD DXF';
      case 'dwg': return 'AutoCAD DWG';
      case 'tif': return 'GeoTIFF';
      case 'tiff': return 'GeoTIFF';
      case 'img': return 'ERDAS Imagine';
      default: return '数据文件';
    }
  }
}

/** 导入结果：沙箱内实际路径 + 显示名 + 是否栅格 */
export class DeskImportResult {
  path: string;
  name: string;
  raster: boolean;

  constructor(path: string, name: string, raster: boolean) {
    this.path = path;
    this.name = name;
    this.raster = raster;
  }
}

export class DeskImporter {
  /** 一次选择最多几个文件（shp 主文件 + 附属文件成组勾选） */
  static readonly MAX_SELECT: number = 30;

  /** 批量导入：按主名分组，组内挑主文件，附属文件随组拷入 */
  static async importPicked(uris: string[]): Promise<DeskImportResult[]> {
    const out: DeskImportResult[] = [];
    if (uris === undefined || uris.length === 0) {
      return out;
    }
    const groups: Map<string, string[]> = new Map<string, string[]>();
    for (let i = 0; i < uris.length; i++) {
      const key: string = DeskFormats.stemOf(DeskImporter.fileNameOfUri(uris[i]));
      const list: string[] | undefined = groups.get(key);
      if (list === undefined) {
        groups.set(key, [uris[i]]);
      } else {
        list.push(uris[i]);
      }
    }
    const keys: string[] = Array.from(groups.keys());
    for (let i = 0; i < keys.length; i++) {
      const members: string[] = groups.get(keys[i]) ?? [];
      const main: string = DeskImporter.findMain(members);
      if (main.length === 0) {
        DeskLog.w(`分组[${keys[i]}]只有附属文件，跳过`);
        continue;
      }
      const side: string[] = members.filter((u: string): boolean => u !== main);
      const ones: DeskImportResult[] = await DeskImporter.importOne(main, side, keys[i]);
      for (let j = 0; j < ones.length; j++) {
        out.push(ones[j]);
      }
    }
    return out;
  }

  /** 单个主文件（+附属）导入；失败返回空数组，异常内部消化 */
  static async importOne(uri: string, sideCars: string[],
    displayName: string): Promise<DeskImportResult[]> {
    const fileName: string = DeskImporter.fileNameOfUri(uri);
    const layerDir: string = DeskDirs.ensureDir(DeskDirs.dir(DeskDirs.LAYER));
    if (layerDir.length === 0) {
      DeskLog.e('沙箱目录未初始化（DeskDirs.init 未调用）');
      return [];
    }
    const dest: string = `${layerDir}/${DeskDirs.sanitize(fileName)}`;
    try {
      if (!DeskImporter.copyTo(uri, dest)) {
        return [];
      }
      for (let i = 0; i < sideCars.length; i++) {
        const sideName: string = DeskImporter.fileNameOfUri(sideCars[i]);
        DeskImporter.copyTo(sideCars[i], `${layerDir}/${DeskDirs.sanitize(sideName)}`);
      }
      if (DeskFormats.isArchive(dest)) {
        return await DeskImporter.unpack(dest, `${layerDir}/${DeskDirs.sanitize(displayName)}`);
      }
      const raster: boolean = DeskFormats.isRaster(dest);
      if (!raster && !DeskFormats.isVector(dest)) {
        DeskLog.w(`非 supported 格式，跳过: ${fileName}`);
        return [];
      }
      return [new DeskImportResult(dest, displayName, raster)];
    } catch (e) {
      DeskLog.e(`导入失败 ${fileName}: ${e}`);
      return [];
    }
  }

  /** 压缩包：zip 收全部 shp，kmz 收内部 kml（优先 doc.kml）；解压结果复用（目录已有目标文件则不再解） */
  private static async unpack(archive: string, outDir: string): Promise<DeskImportResult[]> {
    const kmz: boolean = DeskFormats.extOf(archive) === 'kmz';
    const exts: string[] = kmz ? ['kml'] : ['shp'];
    let found: string[] = DeskImporter.collectByExt(outDir, exts);
    if (found.length === 0) {
      DeskImporter.removeDir(outDir);
      // zlib.decompressFile 要求目标目录已存在（缺目录报 900002），清残留后必须重建
      DeskDirs.ensureDir(outDir);
      await zlib.decompressFile(archive, outDir);
      found = DeskImporter.collectByExt(outDir, exts);
    }
    const out: DeskImportResult[] = [];
    if (found.length === 0) {
      DeskLog.w(`压缩包内未找到 ${exts[0]}: ${archive}`);
      return out;
    }
    if (kmz) {
      let target: string = found[0];
      for (let i = 0; i < found.length; i++) {
        if (DeskImporter.fileNameOfUri(found[i]).toLowerCase() === 'doc.kml') {
          target = found[i];
          break;
        }
      }
      out.push(new DeskImportResult(target, DeskFormats.stemOf(
        DeskImporter.fileNameOfUri(archive)), false));
      return out;
    }
    const single: boolean = found.length === 1;
    for (let i = 0; i < found.length; i++) {
      const name: string = single
        ? DeskFormats.stemOf(DeskImporter.fileNameOfUri(archive))
        : DeskFormats.stemOf(DeskImporter.fileNameOfUri(found[i]));
      out.push(new DeskImportResult(found[i], name, false));
    }
    return out;
  }

  /** 组内挑主文件：附属扩展名不作主文件，其余按白名单命中 */
  private static findMain(uris: string[]): string {
    for (let i = 0; i < uris.length; i++) {
      const name: string = DeskImporter.fileNameOfUri(uris[i]);
      const ext: string = DeskFormats.extOf(name);
      if (DeskFormats.SIDE_CAR_EXTS.indexOf(ext) >= 0) {
        continue;
      }
      if (DeskFormats.isVector(name) || DeskFormats.isRaster(name)) {
        return uris[i];
      }
    }
    return '';
  }

  /** URI → 沙箱拷贝（覆盖式）；失败记日志返回 false */
  static copyTo(uri: string, dest: string): boolean {
    let src: fs.File | null = null;
    try {
      if (fs.accessSync(dest)) {
        fs.unlinkSync(dest);
      }
      src = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      fs.copyFileSync(src.fd, dest);
      return true;
    } catch (e) {
      DeskLog.e(`拷贝失败 ${uri} -> ${dest}: ${e}`);
      return false;
    } finally {
      if (src !== null) {
        try {
          fs.closeSync(src);
        } catch (e) {
          DeskLog.w(`关闭源描述符异常: ${e}`);
        }
      }
    }
  }

  /** 递归收集指定扩展名文件（跳过 __MACOSX/隐藏项，深度上限 6） */
  private static collectByExt(dir: string, exts: string[]): string[] {
    const out: string[] = [];
    DeskImporter.walk(dir, exts, out, 0);
    if (exts.length === 1 && exts[0] === 'shp') {
      out.sort();
    }
    return out;
  }

  private static walk(dir: string, exts: string[], out: string[], depth: number): void {
    if (depth > 6 || dir.length === 0) {
      return;
    }
    let names: string[] = [];
    try {
      names = fs.listFileSync(dir, { recursion: false });
    } catch (e) {
      return;
    }
    for (let i = 0; i < names.length; i++) {
      const n: string = names[i];
      if (n === '__MACOSX' || n.startsWith('.')) {
        continue;
      }
      const full: string = `${dir}/${n}`;
      try {
        const stat: fs.Stat = fs.statSync(full);
        if (stat.isDirectory()) {
          DeskImporter.walk(full, exts, out, depth + 1);
        } else if (stat.isFile() && exts.indexOf(DeskFormats.extOf(n)) >= 0) {
          out.push(full);
        }
      } catch (e) {
        DeskLog.w(`stat 失败，跳过 ${full}`);
      }
    }
  }

  private static removeDir(dir: string): void {
    try {
      if (dir.length > 0 && fs.accessSync(dir)) {
        fs.rmdirSync(dir);
      }
    } catch (e) {
      DeskLog.w(`清理临时目录失败 ${dir}: ${e}`);
    }
  }

  /** URI 末段文件名（兼容 file://docs/... 与纯路径，带查询串与百分号编码） */
  static fileNameOfUri(uri: string): string {
    let s: string = uri;
    const query: number = s.indexOf('?');
    if (query > 0) {
      s = s.substring(0, query);
    }
    const slash: number = s.lastIndexOf('/');
    const name: string = slash >= 0 ? s.substring(slash + 1) : s;
    try {
      return decodeURIComponent(name);
    } catch (e) {
      return name;
    }
  }
}