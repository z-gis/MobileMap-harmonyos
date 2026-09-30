// VectorFileImporter.ets —— 数据文件导入器（对应 Android vector.VectorFileImporter）。
//
// 与 Android 的关键差异在「文件来源」：Android 用自研文件管理器 Activity 直接给出真实路径，
// 可原地引用；鸿蒙沙箱下系统文件选择器（DocumentViewPicker）返回的是 file://docs/... 形式的
// 授权 URI，只有本应用临时可读，GDAL 更无法按该 URI 打开 —— 故一律**先拷入沙箱 调查宝/layer/**
// 再把沙箱路径写入文档，这同时天然满足了 shp 的附属文件（dbf/shx/prj/cpg…）需求。
//
// 分发规则（与 Android 一致）：
//  · shp/kml/dwg/dxf/gpkg/geojson：拷入 layer 目录后直接引用（shp 附属文件同批拷入同名前缀子目录）；
//  · zip：shp 压缩包 → 解压到 layer/<压缩包名>/ 后查找内部 shp；
//  · kmz：解压后查找内部 kml（优先 doc.kml），显示名用压缩包本身文件名。
// 解压：@ohos.zlib.decompressFile 支持 zip 族（kmz 即 zip），内部为 UTF-8 条目名，
// 无需 Android 侧的 GBK 回退探测（鸿蒙 zlib 实现按 UTF-8 处理）。

import fs from '@ohos.file.fs';
import zlib from '@ohos.zlib';
import { promptAction } from '@kit.ArkUI';
import { AppDirs } from '../common/AppDirs';
import { AppLog } from '../common/AppLog';
import { VectorFormats } from './VectorFormats';

const TAG: string = 'VectorFileImporter';

/** 导入结果：加载/渲染使用的实际文件路径与显示名称 */
export class ImportResult {
  path: string;
  name: string;

  constructor(path: string, name: string) {
    this.path = path;
    this.name = name;
  }
}

/**
 * 同名前缀附属文件后缀（shp 家族 + GeoTIFF 家族 + gpkg 无附属）：
 * 主文件决定图层，附属文件与主文件同前缀，必须一起拷入同一目录 GDAL 才能打开。
 */
const SIDE_CAR_SUFFIXES: string[] =
  ['.dbf', '.shx', '.prj', '.cpg', '.sbn', '.sbx', '.fbn', '.fbx', '.ain', '.aih',
    '.ixs', '.mxs', '.atx', '.shp.xml', '.xml', '.qml', '.tfw', '.tzw', '.twx', '.ovr', '.rrd',
    '.aux.xml', '.hdr', '.xml'];

export class VectorFileImporter {
  /**
   * 批量导入选择器返回的 URI 列表，返回成功导入的图层清单（失败的逐个 Toast 提示后跳过）。
   * 一次调用的意义在于 shp 附属文件成组选择：按「去扩展名基础名」分组，组内有主文件才导入。
   */
  static async importPicked(uris: string[]): Promise<ImportResult[]> {
    const results: ImportResult[] = [];
    if (uris === undefined || uris.length === 0) {
      return results;
    }
    // 分组：同一逻辑数据文件的主文件与附属文件归为一组
    const groups: Map<string, string[]> = new Map<string, string[]>();
    for (let i = 0; i < uris.length; i++) {
      const name: string = VectorFileImporter.baseNameOfUri(uris[i]);
      const list: string[] | undefined = groups.get(name);
      if (list === undefined) {
        groups.set(name, [uris[i]]);
      } else {
        list.push(uris[i]);
      }
    }
    const names: string[] = Array.from(groups.keys());
    for (let i = 0; i < names.length; i++) {
      const members: string[] = groups.get(names[i]) ?? [];
      const main: string | undefined = VectorFileImporter.findMainFile(members);
      if (main === undefined) {
        AppLog.w(`分组[${names[i]}]无主数据文件（仅附属文件），跳过`);
        continue;
      }
      const rest: string[] = members.filter((u: string) => u !== main);
      const one: ImportResult | null = await VectorFileImporter.importOne(main, rest);
      if (one === null) {
        promptAction.showToast({ message: `导入失败：${names[i]}` });
        continue;
      }
      results.push(one);
    }
    return results;
  }

  /**
   * 导入单个文件（主文件 + 可选附属文件 URI 列表）。失败返回 null，异常全部内部消化并记日志。
   */
  static async importOne(uri: string, sideCars: string[] = []): Promise<ImportResult | null> {
    const fileName: string = VectorFileImporter.fileNameOfUri(uri);
    if (fileName.length === 0) {
      return null;
    }
    const ext: string = VectorFormats.extOf(fileName);
    const stem: string = AppDirs.deriveBaseName(fileName);
    // 目标目录：压缩包解到 layer/<名>/，普通数据直接进 layer（与 Android 目录布局一致）
    try {
      if (VectorFormats.isArchive(uri)) {
        return await VectorFileImporter.importArchive(uri, stem, ext);
      }
      return await VectorFileImporter.importPlain(uri, sideCars, fileName, stem);
    } catch (e) {
      AppLog.e(`导入失败: ${fileName}`, e);
      return null;
    }
  }

  /** 沙箱内已有路径导入（如「地图工程」解包后直接引用 layer 目录内文件），不再拷贝 */
  static importFromSandboxPath(path: string): ImportResult | null {
    if (!AppDirs.exists(path)) {
      AppLog.w(`沙箱路径不存在: ${path}`);
      return null;
    }
    const slash: number = Math.max(path.lastIndexOf('/'), path.lastIndexOf('\\'));
    const fileName: string = slash >= 0 ? path.substring(slash + 1) : path;
    const ext: string = VectorFormats.extOf(fileName);
    if (!VectorFormats.isVector(fileName) && !VectorFormats.isRaster(fileName)) {
      return null;
    }
    if (ext === 'zip') {
      const found: string | null = VectorFileImporter.findInDir(AppDirs.dir('layer'), ['shp']);
      return found === null ? null : new ImportResult(found, AppDirs.deriveBaseName(fileName));
    }
    return new ImportResult(path, AppDirs.deriveBaseName(fileName));
  }

  /** 普通数据文件：拷入 layer 目录（同名覆盖），附属文件一并拷入 */
  private static async importPlain(uri: string, sideCars: string[], fileName: string,
    stem: string): Promise<ImportResult | null> {
    const destDir: string = AppDirs.ensureDir(AppDirs.dir(AppDirs.LAYER));
    const dest: string = `${destDir}/${AppDirs.sanitizeFileName(fileName)}`;
    if (!VectorFileImporter.copyTo(uri, dest)) {
      return null;
    }
    for (let i = 0; i < sideCars.length; i++) {
      const sideName: string = VectorFileImporter.fileNameOfUri(sideCars[i]);
      VectorFileImporter.copyTo(sideCars[i], `${destDir}/${AppDirs.sanitizeFileName(sideName)}`);
    }
    return new ImportResult(dest, stem);
  }

  /** 压缩包：拷入 layer 目录 → 解压到 layer/<名>/ → 找主文件 */
  private static async importArchive(uri: string, stem: string,
    ext: string): Promise<ImportResult | null> {
    const destDir: string = AppDirs.ensureDir(AppDirs.dir(AppDirs.LAYER));
    const archivePath: string = `${destDir}/${AppDirs.sanitizeFileName(VectorFileImporter.fileNameOfUri(uri))}`;
    if (!VectorFileImporter.copyTo(uri, archivePath)) {
      return null;
    }
    const outDir: string = `${destDir}/${AppDirs.sanitizeFileName(stem)}`;
    if (!AppDirs.exists(outDir)) {
      await zlib.decompressFile(archivePath, outDir);
    }
    const wantExts: string[] = ext === 'kmz' ? ['kml'] : ['shp'];
    const target: string | null = VectorFileImporter.findInDir(outDir, wantExts);
    if (target === null) {
      AppLog.w(`压缩包内未找到 ${wantExts.join('/')}：${archivePath}`);
      return null;
    }
    // kmz 显示名用压缩包本身文件名，而非内部 doc.kml 的名称（与 Android 一致）
    return new ImportResult(target, stem);
  }

  /** URI → 沙箱文件拷贝（覆盖式）；失败记日志返回 false */
  static copyTo(uri: string, dest: string): boolean {
    let srcFile: fs.File | null = null;
    try {
      const dir: string = dest.substring(0, Math.max(0, dest.lastIndexOf('/')));
      if (dir.length > 0) {
        AppDirs.ensureDir(dir);
      }
      if (AppDirs.exists(dest)) {
        fs.unlinkSync(dest);
      }
      srcFile = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      fs.copyFileSync(srcFile.fd, dest);
      return true;
    } catch (e) {
      AppLog.e(`拷贝失败 ${uri} -> ${dest}`, e);
      return false;
    } finally {
      if (srcFile !== null) {
        try {
          fs.closeSync(srcFile);
        } catch (e) {
          AppLog.w(`关闭源文件描述符异常: ${e}`);
        }
      }
    }
  }

  /** 取 URI 末段文件名（兼容 file://docs/storage/... 与纯路径两种形态） */
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

  /** 去扩展名基础名（分组键） */
  private static baseNameOfUri(uri: string): string {
    return AppDirs.deriveBaseName(VectorFileImporter.fileNameOfUri(uri));
  }

  /**
   * 组内挑主文件：优先矢量/栅格白名单扩展名，附属文件（.dbf/.prj 等）不作主文件。
   * 多个主文件时按白名单顺序取第一个（与 Android findFirst 的 exts 顺序语义一致）。
   */
  private static findMainFile(uris: string[]): string | undefined {
    const candidates: string[] = uris.filter((u: string) => {
      const name: string = VectorFileImporter.fileNameOfUri(u);
      const lower: string = name.toLowerCase();
      for (let i = 0; i < SIDE_CAR_SUFFIXES.length; i++) {
        if (lower.endsWith(SIDE_CAR_SUFFIXES[i])) {
          return false;
        }
      }
      return VectorFormats.isVector(name) || VectorFormats.isRaster(name);
    });
    return candidates.length === 0 ? undefined : candidates[0];
  }

  /**
   * 目录递归查首个目标扩展名文件；kmz 约定入口 doc.kml 优先。
   * 鸿蒙 fs 无 walk API，自行做深度优先遍历（层数与条目数有限，压缩包内通常 <2 层）。
   */
  private static findInDir(dir: string, exts: string[]): string | null {
    const all: string[] = [];
    VectorFileImporter.collectFiles(dir, all, 0);
    if (exts.length === 1 && exts[0] === 'kml') {
      for (let i = 0; i < all.length; i++) {
        if (VectorFileImporter.fileNameOfUri(all[i]).toLowerCase() === 'doc.kml') {
          return all[i];
        }
      }
    }
    for (let e = 0; e < exts.length; e++) {
      for (let i = 0; i < all.length; i++) {
        if (VectorFormats.extOf(all[i]) === exts[e]) {
          return all[i];
        }
      }
    }
    return null;
  }

  private static collectFiles(dir: string, out: string[], depth: number): void {
    if (depth > 6) {
      return;
    }
    let names: string[] = [];
    try {
      names = fs.listFileSync(dir, { recursion: false });
    } catch (e) {
      AppLog.e(`列目录失败: ${dir}`, e);
      return;
    }
    for (let i = 0; i < names.length; i++) {
      const full: string = `${dir}/${names[i]}`;
      try {
        const stat: fs.Stat = fs.statSync(full);
        if (stat.isDirectory()) {
          VectorFileImporter.collectFiles(full, out, depth + 1);
        } else if (stat.isFile()) {
          out.push(full);
        }
      } catch (e) {
        AppLog.w(`stat 失败，跳过 ${full}: ${e}`);
      }
    }
  }
}
