// LayerFileDeleter.ets —— 图层源文件删除（对应 Android com.zys.mobilemap.util.LayerFileDeleter）。
//
// 图层管理「移除」对话框勾选「同时删除图层文件」时调用。删除目标按路径形态推导：
//  · layer 根目录下的单文件：文件本身 + 同干附属文件（shp 族/栅格族/CAD .prj/gpkg WAL）；
//  · layer 根目录下的 .gdb 目录：整目录递归删除；
//  · layer 根的直接子目录内（zip/kmz/gdb.zip 导入产物）：整个导入子目录 + layer 根下同名原压缩包；
//  · 其余位置（工程 gpkg 在 projects/、用户原路径引用）：只删文件本身 + 附属文件，绝不删目录。
// 共享保护：文档中还有其他图层落在同一删除目标内（同 GDB 其他要素类、同 gpkg 其他层、
// 同压缩包其他 shp）时不提供删除选项（offerDelete 返回 false），避免删掉别的图层源。

import fs from '@ohos.file.fs';
import { AppDirs } from './AppDirs';
import { AppLog } from './AppLog';
import { VectorFormats } from '../vector/VectorFormats';

export class LayerFileDeleter {

  /**
   * 是否提供「同时删除图层文件」选项：路径存在且无其他图层共享删除目标。
   * otherLayerPaths 为文档中除本图层外全部图层路径（矢量+栅格）。
   */
  static offerDelete(path: string, otherLayerPaths: string[]): boolean {
    if (path.length === 0 || !AppDirs.exists(path)) {
      return false;
    }
    const layerRoot: string = AppDirs.dir(AppDirs.LAYER);
    const base: string = LayerFileDeleter.importDirOf(path, layerRoot);
    if (base.length > 0) {
      return !otherLayerPaths.some((p: string): boolean => LayerFileDeleter.under(p, base));
    }
    return !otherLayerPaths.some((p: string): boolean => p === path);
  }

  /** 删除图层源文件（尽力而为，单项失败仅记日志）；调用方须已确认无共享 */
  static deleteSource(path: string): void {
    if (path.length === 0 || !AppDirs.exists(path)) {
      return;
    }
    const layerRoot: string = AppDirs.dir(AppDirs.LAYER);
    const base: string = LayerFileDeleter.importDirOf(path, layerRoot);
    if (base.length > 0) {
      AppLog.i(`删除图层导入目录: ${base}`);
      AppDirs.removeTree(base);
      // 原压缩包（kmz/zip/gdb.zip）与导入目录同名，留在 layer 根
      const stem: string = base.substring(base.lastIndexOf('/') + 1);
      const exts: string[] = ['.kmz', '.zip'];
      for (let i = 0; i < exts.length; i++) {
        const archive: string = `${layerRoot}/${stem}${exts[i]}`;
        if (AppDirs.exists(archive)) {
          AppLog.i(`删除图层原压缩包: ${archive}`);
          AppDirs.removeFile(archive);
        }
      }
      return;
    }
    let isDir: boolean = false;
    try {
      isDir = fs.statSync(path).isDirectory();
    } catch (e) {
      return;
    }
    if (isDir) {
      AppLog.i(`删除图层数据集目录: ${path}`);
      AppDirs.removeTree(path);
      return;
    }
    const targets: string[] = LayerFileDeleter.fileTargets(path);
    for (let i = 0; i < targets.length; i++) {
      if (AppDirs.exists(targets[i])) {
        AppLog.i(`删除图层源文件: ${targets[i]}`);
        AppDirs.removeFile(targets[i]);
      }
    }
  }

  /**
   * 导入产物子目录判定：仅当路径位于 layer 根的**直接子目录**内才视为可整删的导入目录；
   * 工程 gpkg（projects/）或用户原路径引用一律不碰目录。返回 '' 表示非导入目录。
   */
  private static importDirOf(path: string, layerRoot: string): string {
    const slash: number = path.lastIndexOf('/');
    if (slash <= 0) {
      return '';
    }
    const parent: string = path.substring(0, slash);
    if (parent === layerRoot) {
      return '';
    }
    const gslash: number = parent.lastIndexOf('/');
    if (gslash > 0 && parent.substring(0, gslash) === layerRoot) {
      return parent;
    }
    return '';
  }

  /** 单文件删除目标：本身 + 按扩展名的同干附属文件 */
  private static fileTargets(path: string): string[] {
    const slash: number = path.lastIndexOf('/');
    const dir: string = slash > 0 ? path.substring(0, slash) : '';
    const name: string = path.substring(slash + 1);
    const dot: number = name.lastIndexOf('.');
    const stem: string = dot > 0 ? name.substring(0, dot) : name;
    const ext: string = dot > 0 ? name.substring(dot).toLowerCase() : '';
    const targets: string[] = [path];
    const prefix: string = dir.length > 0 ? `${dir}/${stem}` : stem;
    if (ext === '.shp') {
      const fam: string[] = VectorFormats.DELETE_SHP_EXTS;
      for (let i = 0; i < fam.length; i++) {
        if (fam[i] !== '.shp') {
          targets.push(`${prefix}${fam[i]}`);
        }
      }
    } else if (ext === '.tif' || ext === '.tiff') {
      const fam: string[] = VectorFormats.DELETE_RASTER_EXTS;
      for (let i = 0; i < fam.length; i++) {
        targets.push(`${prefix}${fam[i]}`);
      }
      targets.push(`${dir}/${name}.aux.xml`);
    } else if (VectorFormats.isCad(name)) {
      const fam: string[] = VectorFormats.DELETE_CAD_EXTS;
      for (let i = 0; i < fam.length; i++) {
        targets.push(`${prefix}${fam[i]}`);
      }
    } else if (ext === '.gpkg') {
      targets.push(`${path}-wal`);
      targets.push(`${path}-shm`);
    }
    return targets;
  }

  /** path 是否落在目录 dir 内（含目录本身） */
  private static under(path: string, dir: string): boolean {
    return path === dir || path.startsWith(`${dir}/`);
  }
}