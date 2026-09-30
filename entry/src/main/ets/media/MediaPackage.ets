// MediaPackage.ets —— 拍照数据包（对应 Android media.MediaPackage，扩展名 .mphoto，本质 zip）。
//
// 包内结构与 Android 完全一致，两个平台可互发互读：
//   metadata.json                    格式标识 + 版本 + 导出时间 + 可选分组名 + 各点位（名称/经纬度/创建时间/照片相对路径）
//   <点位序号>/<照片文件名>           照片原文件（按点位分子目录，避免跨点位同名覆盖）
//
// 平台差异：
//   压缩 Android 手写 ZipOutputStream；鸿蒙只有 @ohos.zlib 的整包压缩/解压，故先「暂存目录 → 压缩 → 改名」，
//     解压侧同理（zlib.decompressFile 要求入参文件名以 .zip 结尾，故先复制为 package.zip 再解）。
//     注意 zlib 压缩目录时条目是否含顶层目录名未在文档明确：本端导入按「递归查找 metadata.json」兼容两种布局；
//     若 zlib 输出带顶层目录，本端生成的包在 Android 端将解析失败（Android 只查根目录），导出时可从日志核对。
//   分享 Android ACTION_SEND + FileProvider；鸿蒙用 @kit.ShareKit systemShare 分享面板（沙箱文件 URI）。
//   路径穿越 Android 用 canonicalPath 前缀校验；鸿蒙无 canonical 接口，改为条目名禁含 ../ 并校验落在解包根内。

import { common } from '@kit.AbilityKit';
import { systemShare } from '@kit.ShareKit';
import { fileUri } from '@kit.CoreFileKit';
import fs from '@ohos.file.fs';
import zlib from '@ohos.zlib';
import { AppDirs } from '../common/AppDirs';
import { AppLog } from '../common/AppLog';
import { Ui } from '../common/Ui';
import { MediaAttachment, MediaPlacemark, MediaStore } from './MediaStore';

/** 自定义扩展名（不含点）：数据实为 zip，接收方用本 app 打开触发导入 */
const EXT: string = 'mphoto';
/** 包内元数据文件名 */
const META_FILE: string = 'metadata.json';
/** 格式标识：导入时校验，避免把其它 zip 误当拍照数据包解析 */
const FORMAT_TAG: string = 'com.zys.mobilemap.media.package';
/** 当前格式版本 */
const FORMAT_VERSION: number = 1;
/** 导出包存放子目录（调查宝/share） */
const SHARE_DIR: string = 'share';
/** 打包/解包暂存子目录（调查宝/package_tmp、调查宝/package_import） */
const STAGE_DIR: string = 'package_tmp';
const IMPORT_DIR: string = 'package_import';
/** 旧导出包保留时长（毫秒）：超过则在下次导出时清理 */
const STALE_PACKAGE_MS: number = 24 * 60 * 60 * 1000;
/** 解包时查找 metadata.json 的最大层级（兼容 zlib 可能附加的顶层目录） */
const META_SEARCH_DEPTH: number = 3;
/** UDMF 统一数据类型：压缩包（分享面板据此匹配接收端） */
const UTD_COMPRESSED: string = 'general.compressed-data';

/** 包内单个点位描述 */
export interface PackagePlacemarkJson {
  name: string;
  latitude: number;
  longitude: number;
  createdTime: number;
  photos: string[];
}

/** 包内 metadata.json 结构 */
export interface PackageMetaJson {
  format: string;
  version: number;
  exportTime: number;
  groupName?: string;
  placemarks: PackagePlacemarkJson[];
}

/** 打包条目：点位 + 其有效照片附件 */
export class PackageEntry {
  placemark: MediaPlacemark;
  photos: MediaAttachment[];

  constructor(placemark: MediaPlacemark, photos: MediaAttachment[]) {
    this.placemark = placemark;
    this.photos = photos;
  }
}

const ZIP_OPTIONS: zlib.Options = { level: zlib.CompressLevel.COMPRESS_LEVEL_DEFAULT_COMPRESSION };

export class MediaPackage {
  /** 判定文件名/路径是否为本 app 拍照数据包 */
  static isPackageFile(nameOrPath: string | null): boolean {
    if (nameOrPath === null) {
      return false;
    }
    return nameOrPath.toLowerCase().endsWith(`.${EXT}`);
  }

  /** 分享单个拍照点位：打包其坐标/名称/全部照片后经系统分享面板发出 */
  static async sharePlacemark(ctx: common.UIAbilityContext, placemark: MediaPlacemark): Promise<void> {
    const subject: string = placemark.name.trim().length > 0 ? placemark.name : '拍照点位';
    const entries: PackageEntry[] = MediaPackage.collectEntries([placemark]);
    await MediaPackage.shareEntries(ctx, null, entries, subject);
  }

  /**
   * 分享整个分组：打包组内全部点位后经系统分享面板发出。
   * groupName 非空时写入包内，导入据此重建同名分组；未分组分享传 null。
   */
  static async shareGroup(ctx: common.UIAbilityContext, groupName: string | null,
    placemarks: MediaPlacemark[]): Promise<void> {
    const subject: string = groupName !== null && groupName.trim().length > 0 ? groupName : '拍照分组';
    const entries: PackageEntry[] = MediaPackage.collectEntries(placemarks);
    await MediaPackage.shareEntries(ctx, groupName, entries, subject);
  }

  private static async shareEntries(ctx: common.UIAbilityContext, groupName: string | null,
    entries: PackageEntry[], subject: string): Promise<void> {
    if (entries.length === 0) {
      Ui.toast('没有可分享的照片');
      return;
    }
    const pkgPath: string = await MediaPackage.buildPackage(groupName, entries);
    if (pkgPath.length === 0) {
      Ui.toast('打包失败');
      return;
    }
    try {
      const uri: string = fileUri.getUriFromPath(pkgPath);
      const record: systemShare.SharedRecord = { utd: UTD_COMPRESSED, uri: uri, title: subject, label: 'FILE' };
      const data: systemShare.SharedData = new systemShare.SharedData(record);
      const controller: systemShare.ShareController = new systemShare.ShareController(data);
      const options: systemShare.ShareControllerOptions = {};
      await controller.show(ctx, options);
    } catch (e) {
      // 分享面板起不来不丢数据：包已落在导出目录，提示路径供文件管理器取用
      AppLog.e('拉起分享面板失败', e);
      Ui.toastLong(`分享面板启动失败，数据包已导出：${pkgPath}`);
    }
  }

  /**
   * 导入数据包：解包 metadata.json 与照片，按包内坐标/名称新建拍照点位
   * （照片复制到 调查宝/Media/<新点位ID>/），返回新建点位列表（失败或空包返回空列表）。
   * @param packagePath 数据包沙箱绝对路径（由调用方经文件选择器取回沙箱）
   */
  static async importPackage(ctx: common.UIAbilityContext, packagePath: string): Promise<MediaPlacemark[]> {
    if (!AppDirs.exists(packagePath)) {
      return [];
    }
    const stamp: number = Date.now();
    const tmpRoot: string = `${AppDirs.dir(IMPORT_DIR)}/${stamp}`;
    AppDirs.ensureDir(tmpRoot);
    try {
      // zlib 解压要求入参名以 .zip 结尾，故先复制一份改名
      const zipCopy: string = `${tmpRoot}/package.zip`;
      fs.copyFileSync(packagePath, zipCopy);
      const extractDir: string = `${tmpRoot}/extract`;
      AppDirs.ensureDir(extractDir);
      await zlib.decompressFile(zipCopy, extractDir, ZIP_OPTIONS);

      const metaPath: string = MediaPackage.findMetaFile(extractDir, 0);
      if (metaPath.length === 0) {
        AppLog.w('数据包缺少 metadata.json，非本 app 拍照数据包', packagePath);
        return [];
      }
      const meta: PackageMetaJson = JSON.parse(fs.readTextSync(metaPath)) as PackageMetaJson;
      if (meta.format !== FORMAT_TAG) {
        AppLog.w('数据包格式标识不匹配', meta.format ?? '');
        return [];
      }
      // 以 metadata.json 实际位置为包根，兼容 zlib 压缩目录时可能附加的顶层目录
      return await MediaPackage.createPlacemarks(ctx, MediaPackage.parentOf(metaPath), meta);
    } catch (e) {
      AppLog.e('导入拍照数据包失败', e);
      return [];
    } finally {
      MediaPackage.removeDir(tmpRoot);
    }
  }

  /** 仅保留有照片的点位（过滤非照片附件与失效文件） */
  private static collectEntries(placemarks: MediaPlacemark[]): PackageEntry[] {
    const entries: PackageEntry[] = [];
    for (let i = 0; i < placemarks.length; i++) {
      const p: MediaPlacemark = placemarks[i];
      const photos: MediaAttachment[] = p.attachments.filter((a: MediaAttachment): boolean => {
        return a.type === MediaAttachment.TYPE_PHOTO && AppDirs.exists(a.path)
          && fs.statSync(a.path).size > 0;
      });
      if (photos.length > 0) {
        entries.push(new PackageEntry(p, photos));
      }
    }
    return entries;
  }

  /**
   * 构建数据包：写 metadata.json 与各点位照片到暂存目录，压缩为 zip 后改名为 .mphoto。
   * @returns 数据包绝对路径；失败返回空串
   */
  private static async buildPackage(groupName: string | null,
    entries: PackageEntry[]): Promise<string> {
    if (entries.length === 0) {
      return '';
    }
    const shareDir: string = AppDirs.ensureDir(`${AppDirs.root()}/${SHARE_DIR}`);
    MediaPackage.cleanStalePackages(shareDir);

    const stamp: number = Date.now();
    const first: MediaPlacemark = entries[0].placemark;
    const fallback: string = first.name.trim().length > 0 ? first.name : '拍照数据包';
    const base: string = MediaPackage.sanitize(groupName !== null && groupName.trim().length > 0
      ? groupName : fallback);
    const packagePath: string = `${shareDir}/${base}_${stamp}.${EXT}`;

    const stageDir: string = AppDirs.ensureDir(`${AppDirs.dir(STAGE_DIR)}/${stamp}`);
    const zipPath: string = `${AppDirs.dir(STAGE_DIR)}/${stamp}.zip`;
    try {
      MediaPackage.writeText(`${stageDir}/${META_FILE}`,
        JSON.stringify(MediaPackage.buildMeta(groupName, entries, stamp), null, 2));

      for (let i = 0; i < entries.length; i++) {
        const photos: MediaAttachment[] = entries[i].photos;
        const subDir: string = AppDirs.ensureDir(`${stageDir}/${i}`);
        for (let j = 0; j < photos.length; j++) {
          const src: string = photos[j].path;
          fs.copyFileSync(src, `${subDir}/${MediaPackage.nameOfPath(src)}`);
        }
      }

      await zlib.compressFile(stageDir, zipPath, ZIP_OPTIONS);
      if (!AppDirs.exists(zipPath)) {
        AppLog.w('压缩未产出数据包', zipPath);
        return '';
      }
      fs.renameSync(zipPath, packagePath);
      return packagePath;
    } catch (e) {
      AppLog.e('打包拍照数据失败', e);
      MediaPackage.removeFile(zipPath);
      MediaPackage.removeFile(packagePath);
      return '';
    } finally {
      MediaPackage.removeDir(stageDir);
    }
  }

  /** 组装 metadata.json 数据：格式标识/版本/导出时间 + 可选分组名 + 各点位与其照片相对路径 */
  private static buildMeta(groupName: string | null, entries: PackageEntry[],
    stamp: number): PackageMetaJson {
    const placemarks: PackagePlacemarkJson[] = [];
    for (let i = 0; i < entries.length; i++) {
      const p: MediaPlacemark = entries[i].placemark;
      const photos: string[] = [];
      const list: MediaAttachment[] = entries[i].photos;
      for (let j = 0; j < list.length; j++) {
        photos.push(`${i}/${MediaPackage.nameOfPath(list[j].path)}`);
      }
      const item: PackagePlacemarkJson = {
        name: p.name,
        latitude: p.latitude,
        longitude: p.longitude,
        createdTime: p.createdTime,
        photos: photos,
      };
      placemarks.push(item);
    }
    const meta: PackageMetaJson = {
      format: FORMAT_TAG,
      version: FORMAT_VERSION,
      exportTime: stamp,
      placemarks: placemarks,
    };
    if (groupName !== null && groupName.trim().length > 0) {
      meta.groupName = groupName;
    }
    return meta;
  }

  /** 按元数据在库中新建点位并复制照片（分组包先建同名分组承接） */
  private static async createPlacemarks(ctx: common.UIAbilityContext, rootDir: string,
    meta: PackageMetaJson): Promise<MediaPlacemark[]> {
    const store: MediaStore = await MediaStore.getInstance(ctx);
    const mediaDir: string = AppDirs.mediaDir();
    const groupName: string = meta.groupName ?? '';
    const groupId: number = groupName.trim().length > 0
      ? await store.insertGroup(groupName, Date.now()) : MediaStore.UNGROUPED_ID;

    const created: MediaPlacemark[] = [];
    const list: PackagePlacemarkJson[] = meta.placemarks ?? [];
    for (let i = 0; i < list.length; i++) {
      const po: PackagePlacemarkJson = list[i];
      const lat: number = po.latitude;
      const lon: number = po.longitude;
      if (isNaN(lat) || isNaN(lon)) {
        continue;
      }
      const name: string = po.name ?? '';
      const createdTime: number = po.createdTime ?? Date.now();
      const newId: number = await store.insertPlacemark(name, lat, lon, createdTime, groupId);
      if (newId < 0) {
        continue;
      }
      const destDir: string = AppDirs.ensureDir(`${mediaDir}/${newId}`);
      const result: MediaPlacemark = new MediaPlacemark(newId, name, lat, lon, createdTime, true, groupId, []);

      const photos: string[] = po.photos ?? [];
      for (let j = 0; j < photos.length; j++) {
        const rel: string = photos[j];
        const src: string = MediaPackage.resolveInside(rootDir, rel);
        if (src.length === 0 || !AppDirs.exists(src)) {
          continue;
        }
        const target: string = MediaPackage.uniqueFile(destDir, MediaPackage.nameOfPath(src));
        fs.copyFileSync(src, target);
        // 附件时间按序递增，保证导入后照片顺序与打包时一致
        const attTime: number = createdTime + j;
        const attId: number = await store.insertAttachment(newId, MediaAttachment.TYPE_PHOTO,
          MediaPackage.nameOfPath(target), target, attTime);
        result.attachments.push(new MediaAttachment(attId, newId, MediaAttachment.TYPE_PHOTO,
          MediaPackage.nameOfPath(target), target, attTime));
      }
      created.push(result);
    }
    return created;
  }

  /** 清理超过一天未动的旧导出包，避免私有目录里累积占用空间（不影响刚生成/在途的包） */
  private static cleanStalePackages(shareDir: string): void {
    const cutoff: number = Date.now() - STALE_PACKAGE_MS;
    try {
      const names: string[] = fs.listFileSync(shareDir);
      for (let i = 0; i < names.length; i++) {
        const full: string = `${shareDir}/${names[i]}`;
        if (!MediaPackage.isPackageFile(names[i])) {
          continue;
        }
        try {
          const st = fs.statSync(full);
          if (!st.isDirectory() && st.mtime * 1000 < cutoff) {
            fs.unlinkSync(full);
          }
        } catch (e) {
          // 单个旧包清理失败不影响本次导出
        }
      }
    } catch (e) {
      AppLog.w('清理旧数据包失败', shareDir);
    }
  }

  /** 递归（限深）查找 metadata.json，返回其绝对路径；未找到返回空串 */
  private static findMetaFile(dir: string, depth: number): string {
    const direct: string = `${dir}/${META_FILE}`;
    if (AppDirs.exists(direct)) {
      return direct;
    }
    if (depth >= META_SEARCH_DEPTH) {
      return '';
    }
    let names: string[] = [];
    try {
      names = fs.listFileSync(dir);
    } catch (e) {
      return '';
    }
    for (let i = 0; i < names.length; i++) {
      const full: string = `${dir}/${names[i]}`;
      try {
        if (fs.statSync(full).isDirectory()) {
          const found: string = MediaPackage.findMetaFile(full, depth + 1);
          if (found.length > 0) {
            return found;
          }
        }
      } catch (e) {
        // 条目不可 stat：跳过
      }
    }
    return '';
  }

  /**
   * 把包内相对路径安全解析到解包根目录内（防路径穿越）：
   * 禁含 ../ 与绝对路径，且结果必须以 rootDir/ 开头；非法返回空串。
   */
  private static resolveInside(rootDir: string, rel: string): string {
    if (rel.length === 0 || rel.indexOf('..') >= 0 || rel.startsWith('/')) {
      return '';
    }
    const full: string = `${rootDir}/${rel}`;
    return full.startsWith(`${rootDir}/`) ? full : '';
  }

  /** 目标目录下取不冲突的文件名：同名时在扩展名前追加 _序号 */
  private static uniqueFile(dir: string, name: string): string {
    let target: string = `${dir}/${name}`;
    if (!AppDirs.exists(target)) {
      return target;
    }
    const dot: number = name.lastIndexOf('.');
    const stem: string = dot > 0 ? name.substring(0, dot) : name;
    const ext: string = dot > 0 ? name.substring(dot) : '';
    let k: number = 1;
    while (AppDirs.exists(target)) {
      target = `${dir}/${stem}_${k}${ext}`;
      k++;
    }
    return target;
  }

  /** 过滤文件名字符：反斜杠/斜杠/冒号等非法字符与空白统一替换为下划线 */
  private static sanitize(name: string): string {
    const clean: string = name.trim().replace(/[\\/:*?"<>|\s]/g, '_');
    return clean.length === 0 ? 'package' : clean;
  }

  private static nameOfPath(path: string): string {
    const idx: number = path.lastIndexOf('/');
    return idx >= 0 ? path.substring(idx + 1) : path;
  }

  private static parentOf(path: string): string {
    const idx: number = path.lastIndexOf('/');
    return idx > 0 ? path.substring(0, idx) : path;
  }

  private static writeText(path: string, content: string): void {
    const file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    fs.writeSync(file.fd, content);
    fs.closeSync(file);
  }

  private static removeFile(path: string): void {
    if (path.length === 0) {
      return;
    }
    try {
      fs.unlinkSync(path);
    } catch (e) {
      // 不存在或占用：忽略
    }
  }

  /** 暂存/解包目录可含子目录（zlib 可能附顶层目录），统一递归清理 */
  private static removeDir(path: string): void {
    AppDirs.removeTree(path);
  }
}
