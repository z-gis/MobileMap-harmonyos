// AppDirs.ets —— 应用目录布局与文件名工具（对应 Android com.zys.mobilemap.util.AppDirectories）。
//
// Android 侧根目录为外置存储 /调查宝/（用户可直接用文件管理器取出）；鸿蒙沙箱模型无外置可写根，
// 统一落到应用 filesDir 下的同名目录树，保持子目录划分与文件命名完全一致：
//   调查宝/layer   导入的矢量/栅格数据
//   调查宝/map     地图工程（document.json 关联的 kmz 等）
//   调查宝/Media   拍照与兴趣点附件（含 .nomedia 屏蔽系统相册扫描）
//   调查宝/sample  样地调查库
//   调查宝/config  document.json 等配置
//   调查宝/tiles   瓦片磁盘缓存（按图源缓存键分子目录）
//   调查宝/log     运行日志
import fs from '@ohos.file.fs';
import { AppLog } from './AppLog';

export class AppDirs {
  static readonly ROOT_NAME: string = '调查宝';
  static readonly LAYER: string = 'layer';
  static readonly MAP: string = 'map';
  static readonly MEDIA: string = 'Media';
  static readonly SAMPLE: string = 'sample';
  static readonly CONFIG: string = 'config';
  static readonly TILES: string = 'tiles';
  static readonly LOG: string = 'log';

  /** 沙箱根（filesDir），由 init() 赋值；未初始化前所有取路径方法返回 '' */
  private static base: string = '';

  /**
   * 初始化并确保全部子目录存在（幂等，须在任何路径访问前调用，见 EntryAbility）。
   * @param filesDir UIAbilityContext.filesDir
   */
  static init(filesDir: string): void {
    AppDirs.base = `${filesDir}/${AppDirs.ROOT_NAME}`;
    const subs: string[] = [AppDirs.LAYER, AppDirs.MAP, AppDirs.MEDIA, AppDirs.SAMPLE,
      AppDirs.CONFIG, AppDirs.TILES, AppDirs.LOG];
    for (let i = 0; i < subs.length; i++) {
      AppDirs.ensureDir(AppDirs.dir(subs[i]));
    }
    // Media 目录放 .nomedia：与 Android 同口径，避免系统相册把外业照片混入用户图库
    AppDirs.touchNoMedia(AppDirs.dir(AppDirs.MEDIA));
    AppLog.logFile = `${AppDirs.dir(AppDirs.LOG)}/app.log`;
  }

  static isReady(): boolean {
    return AppDirs.base.length > 0;
  }

  /** 根目录绝对路径 */
  static root(): string {
    return AppDirs.base;
  }

  /** 指定子目录绝对路径（sub 取本类常量） */
  static dir(sub: string): string {
    return `${AppDirs.base}/${sub}`;
  }

  /** 瓦片缓存子目录（按图源缓存键分目录，键已 sanitize） */
  static tileDir(cacheKey: string): string {
    const path = `${AppDirs.dir(AppDirs.TILES)}/${AppDirs.sanitizeFileName(cacheKey)}`;
    AppDirs.ensureDir(path);
    return path;
  }

  /** 数据文件绝对路径（layer 目录，导入的矢量/栅格统一落此） */
  static layerFile(name: string): string {
    return `${AppDirs.dir(AppDirs.LAYER)}/${name}`;
  }

  static mediaDir(): string {
    const path = AppDirs.dir(AppDirs.MEDIA);
    AppDirs.ensureDir(path);
    return path;
  }

  static configFile(name: string): string {
    return `${AppDirs.dir(AppDirs.CONFIG)}/${name}`;
  }

  static sampleFile(name: string): string {
    return `${AppDirs.dir(AppDirs.SAMPLE)}/${name}`;
  }

  /** 目录存在则直接返回，否则递归创建（异常仅记日志，不抛） */
  static ensureDir(path: string): string {
    if (path.length === 0) {
      return path;
    }
    try {
      if (!fs.accessSync(path)) {
        fs.mkdirSync(path, true);
      }
    } catch (e) {
      AppLog.e(`ensureDir 失败: ${path}`, e);
    }
    return path;
  }

  static exists(path: string): boolean {
    if (path.length === 0) {
      return false;
    }
    try {
      return fs.accessSync(path);
    } catch (e) {
      return false;
    }
  }

  /**
   * 递归删除目录及其内容（fs.rmdirSync 要求目录为空，故先清文件再清子目录）。
   * 用于删除点位移除后的附件目录；单个条目失败只记日志并继续，不抛。
   */
  static removeTree(path: string): void {
    if (path.length === 0) {
      return;
    }
    let isDir: boolean = false;
    try {
      if (!fs.accessSync(path)) {
        return;
      }
      isDir = fs.statSync(path).isDirectory();
    } catch (e) {
      return;
    }
    if (!isDir) {
      AppDirs.removeFile(path);
      return;
    }
    let names: string[] = [];
    try {
      names = fs.listFileSync(path, { recursion: false });
    } catch (e) {
      AppLog.w('目录不可列举，跳过递归删除', path);
      return;
    }
    for (let i = 0; i < names.length; i++) {
      AppDirs.removeTree(`${path}/${names[i]}`);
    }
    try {
      fs.rmdirSync(path);
    } catch (e) {
      AppLog.w('删除目录失败', path);
    }
  }

  /** 删除单个文件；不存在或占用忽略 */
  static removeFile(path: string): void {
    if (path.length === 0) {
      return;
    }
    try {
      fs.unlinkSync(path);
    } catch (e) {
      AppLog.w('删除文件失败', path);
    }
  }

  private static touchNoMedia(dirPath: string): void {
    try {
      const marker = `${dirPath}/.nomedia`;
      if (!fs.accessSync(marker)) {
        const file = fs.openSync(marker, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE);
        fs.closeSync(file);
      }
    } catch (e) {
      AppLog.e('.nomedia 创建失败', e);
    }
  }

  /**
   * 由数据文件名派生工程/缓存基础名（去扩展名并截断到安全长度）。
   * 与 Android deriveBaseName 一致：'图斑.shp' → '图斑'。
   */
  static deriveBaseName(fileName: string): string {
    const dot = fileName.lastIndexOf('.');
    const stem = dot > 0 ? fileName.substring(0, dot) : fileName;
    return stem.length > 60 ? stem.substring(0, 60) : stem;
  }

  /**
   * 文件名安全化：替换文件系统保留字符与首尾空白，避免用户命名的数据文件建目录失败。
   * 保留中文与常见可见字符（外业数据多为中文名）。
   */
  static sanitizeFileName(name: string): string {
    let out = '';
    const forbidden: string = '\\/:*?"<>|';
    for (let i = 0; i < name.length; i++) {
      const c = name.charAt(i);
      out += forbidden.indexOf(c) >= 0 ? '_' : c;
    }
    out = out.trim();
    return out.length === 0 ? 'unnamed' : out;
  }

  /**
   * 栅格图层切片缓存子目录：tiles/raster-jni/<路径哈希十六进制>。
   * 与瓦片底图缓存分目录——两者瓦片命名格式不同，不可共享（同 Android MapLayerManager 口径）。
   */
  static rasterTileDir(path: string): string {
    const out = `${AppDirs.dir(AppDirs.TILES)}/raster-jni/${AppDirs.toHexString(AppDirs.hashCode(path))}`;
    return AppDirs.ensureDir(out);
  }

  /**
   * 底图缓存子目录：tiles/<图源名净化>（图源改名会换缓存，与 Android sanitizeDirName 同口径）。
   */
  static baseTileDir(sourceName: string): string {
    const clean: string = AppDirs.sanitizeFileName(sourceName);
    const out = `${AppDirs.dir(AppDirs.TILES)}/${clean === 'unnamed' ? 'unknown' : clean}`;
    return AppDirs.ensureDir(out);
  }

  /** Java String.hashCode（32 位有符号），保证与 Android 端缓存目录名可互认 */
  static hashCode(text: string): number {
    let h: number = 0;
    for (let i = 0; i < text.length; i++) {
      h = Math.imul(31, h) + text.charCodeAt(i);
      h = h | 0; // 截断为 32 位有符号
    }
    return h;
  }

  /** 32 位有符号整数 → 无符号十六进制串（等价 Integer.toHexString） */
  static toHexString(value: number): string {
    return (value >>> 0).toString(16);
  }

  /** 时间戳文件名片段：yyyy-MM-dd_HH-mm-ss（照片/轨迹命名用） */
  static stamp(ts: number): string {
    const d = new Date(ts);
    return `${d.getFullYear()}-${AppDirs.pad(d.getMonth() + 1)}-${AppDirs.pad(d.getDate())}`
      + `_${AppDirs.pad(d.getHours())}-${AppDirs.pad(d.getMinutes())}-${AppDirs.pad(d.getSeconds())}`;
  }

  static pad(n: number): string {
    return n < 10 ? `0${n}` : `${n}`;
  }
}
