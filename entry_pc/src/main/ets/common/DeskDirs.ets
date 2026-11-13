// DeskDirs.ets —— 桌面模块的沙箱目录。
//
// 注意：同一 bundleName 下每个 HAP 模块有独立沙箱子目录
//   /data/app/el2/100/base/<bundle>/haps/<moduleName>/files
// 即 entry_pc 看到的是 haps/entry_pc/files，与手机端 entry 的 haps/entry/files **不是同一份**。
// 本模块的瓦片缓存、临时数据先落自己这里；跨端共用工程文件要走「导出/导入」或后续把数据根
// 收敛到应用级共享目录（待与手机端一起定 HSP 方案时处理）。
import fs from '@ohos.file.fs';
import { DeskLog } from './DeskLog';

export class DeskDirs {
  static readonly ROOT_NAME: string = '调查宝';
  static readonly TILES: string = 'tiles';
  static readonly LAYER: string = 'layer';
  static readonly PROJECTS: string = 'projects';
  static readonly CONFIG: string = 'config';

  private static base: string = '';

  /** 以 UIAbilityContext.filesDir 为根建目录树（幂等，须在取路径前调用） */
  static init(filesDir: string): void {
    DeskDirs.base = `${filesDir}/${DeskDirs.ROOT_NAME}`;
    const subs: string[] = [DeskDirs.TILES, DeskDirs.LAYER, DeskDirs.PROJECTS, DeskDirs.CONFIG];
    for (let i = 0; i < subs.length; i++) {
      DeskDirs.ensureDir(`${DeskDirs.base}/${subs[i]}`);
    }
  }

  static root(): string {
    return DeskDirs.base;
  }

  static dir(sub: string): string {
    return DeskDirs.base.length === 0 ? '' : `${DeskDirs.base}/${sub}`;
  }

  /** 某个底图的瓦片缓存目录（按图源名分目录，命中即免重复下载） */
  static tileDir(cacheKey: string): string {
    const path = `${DeskDirs.dir(DeskDirs.TILES)}/${DeskDirs.sanitize(cacheKey)}`;
    return DeskDirs.ensureDir(path);
  }

  static sanitize(name: string): string {
    return name.replace(/[\\/:*?"<>|\s]/g, '_');
  }

  static ensureDir(path: string): string {
    if (path.length === 0) {
      return path;
    }
    try {
      if (!fs.accessSync(path)) {
        fs.mkdirSync(path, true);
      }
    } catch (e) {
      DeskLog.e(`ensureDir 失败 ${path}: ${e}`);
    }
    return path;
  }
}
