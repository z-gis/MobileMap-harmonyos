// TrackSharePackage.ets —— 轨迹分享包（对应 Android track/TrackSharePackage）。
//
// 把一条轨迹导出为标准 Shapefile（折线 + WGS84 投影 + 属性表，见 track/ShapefileWriter），
// 打包成单个 .zip 文件（shp 为多文件构成的数据集，必须整组分发才能被接收端识别），
// 经系统分享面板发出（@kit.ShareKit systemShare，与 media/MediaPackage 同一套沙箱 URI 分享路径）。
//
// 接收端（QGIS/ArcGIS/本 app 外部导入入口）解压后即可作为普通 shp 图层加载，
// 属性表含名称/采集时间/长度/点数四项。
//
// 平台差异（同 MediaPackage）：压缩 Android 手写 ZipOutputStream；鸿蒙用 @ohos.zlib 整包压缩，
// 故先「暂存目录 → 压缩」；zlib 压缩目录可能附带顶层目录名，接收端递归查找 shp 即可兼容
// （本端与 Android 的导入器均按递归查找实现）。

import { common } from '@kit.AbilityKit';
import { systemShare } from '@kit.ShareKit';
import { fileUri } from '@kit.CoreFileKit';
import fs from '@ohos.file.fs';
import zlib from '@ohos.zlib';
import { AppDirs } from '../common/AppDirs';
import { AppLog } from '../common/AppLog';
import { GeoCalc, LatLng } from '../common/GeoCalc';
import { TimeText } from '../common/TimeText';
import { Ui } from '../common/Ui';
import { ProjectManager } from '../project/ProjectManager';
import { TrackRecord } from '../project/ProjectModels';
import { DbfField, ShapefileWriter } from './ShapefileWriter';

/** 分享 ZIP 扩展名：标准 zip，接收端无需本 app 也能解压使用 */
const EXT: string = 'zip';
/** 导出包存放子目录（调查宝/share，与 MediaPackage 同目录共用清理策略） */
const SHARE_DIR: string = 'share';
/** 打包暂存子目录（调查宝/package_tmp，与 MediaPackage 同目录） */
const STAGE_DIR: string = 'package_tmp';
/** 旧导出包保留时长（毫秒）：超过则在下次导出时清理 */
const STALE_PACKAGE_MS: number = 24 * 60 * 60 * 1000;
/** UDMF 统一数据类型：压缩包（分享面板据此匹配接收端） */
const UTD_COMPRESSED: string = 'general.compressed-data';

const ZIP_OPTIONS: zlib.Options = { level: zlib.CompressLevel.COMPRESS_LEVEL_DEFAULT_COMPRESSION };

export class TrackSharePackage {
  /**
   * 分享一条轨迹：打包 shp 文件组为 zip 后经系统分享面板发出；
   * 失败（点数不足/写盘异常/分享面板不可用）Toast 提示，不抛出。
   */
  static async shareTrack(ctx: common.UIAbilityContext, track: TrackRecord): Promise<void> {
    if (track.points.length < 2) {
      Ui.toast('轨迹点数不足，无法分享');
      return;
    }
    const pkgPath: string = await TrackSharePackage.buildPackage(track);
    const subject: string = track.name.trim().length > 0 ? track.name : '轨迹';
    if (pkgPath.length === 0) {
      Ui.toast('分享失败');
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
   * 构建分享包：写出 shp 文件组到暂存目录，压成单个 .zip；写盘失败或文件组缺失返回空串。
   * 暂存目录打包后即删除，只留最终 zip 文件。
   */
  private static async buildPackage(track: TrackRecord): Promise<string> {
    const shareDir: string = AppDirs.ensureDir(`${AppDirs.root()}/${SHARE_DIR}`);
    TrackSharePackage.cleanStalePackages(shareDir);

    const stamp: number = Date.now();
    const base: string = TrackSharePackage.sanitize(track.name.trim().length > 0 ? track.name : '轨迹');
    const packagePath: string = `${shareDir}/${base}_${stamp}.${EXT}`;

    // 内部存储点串为 [纬度, 经度, 高程]，Shapefile 轴序 x=经度、y=纬度，需换轴
    const lonLatPoints: number[][] = [];
    const latLngs: LatLng[] = [];
    for (let i = 0; i < track.points.length; i++) {
      const p: number[] = track.points[i];
      lonLatPoints.push([p[1], p[0]]);
      latLngs.push(new LatLng(p[0], p[1]));
    }
    const lengthMeters: number = GeoCalc.polylineLengthMeters(latLngs);
    const fields: DbfField[] = [
      new DbfField('NAME', 100, track.name.length > 0 ? track.name : '轨迹'),
      new DbfField('CREATED', 20, TimeText.dateTimeSec(ProjectManager.parseTime(track.date))),
      new DbfField('LENGTH_M', 20, lengthMeters.toFixed(1)),
      new DbfField('POINTS', 10, `${track.points.length}`),
    ];

    const stageDir: string = AppDirs.ensureDir(`${AppDirs.dir(STAGE_DIR)}/${stamp}`);
    const zipPath: string = `${AppDirs.dir(STAGE_DIR)}/${stamp}.zip`;
    try {
      const shpFiles: string[] = ShapefileWriter.writePolyline(`${stageDir}/${base}`, lonLatPoints, fields);
      if (shpFiles.length === 0) {
        return '';
      }
      await zlib.compressFile(stageDir, zipPath, ZIP_OPTIONS);
      if (!AppDirs.exists(zipPath)) {
        AppLog.w('压缩未产出轨迹分享包', zipPath);
        return '';
      }
      if (AppDirs.exists(packagePath)) {
        fs.unlinkSync(packagePath);
      }
      fs.renameSync(zipPath, packagePath);
      return packagePath;
    } catch (e) {
      AppLog.e('轨迹打包分享失败', e);
      try {
        fs.unlinkSync(packagePath);
      } catch (e2) {
        // 未生成忽略
      }
      return '';
    } finally {
      AppDirs.removeTree(stageDir);
    }
  }

  /** 清理超过一天未动的旧导出包与打包中途被杀遗留的暂存目录 */
  private static cleanStalePackages(shareDir: string): void {
    const cutoff: number = Date.now() - STALE_PACKAGE_MS;
    try {
      const names: string[] = fs.listFileSync(shareDir);
      for (let i = 0; i < names.length; i++) {
        const full: string = `${shareDir}/${names[i]}`;
        if (!names[i].toLowerCase().endsWith(`.${EXT}`)) {
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
      AppLog.w('清理旧轨迹分享包失败', shareDir);
    }
  }

  /** 过滤文件名字符：反斜杠/斜杠/冒号等非法字符与空白统一替换为下划线（同 Android sanitize） */
  private static sanitize(name: string): string {
    const clean: string = name.trim().replace(/[\\/:*?"<>|\s]/g, '_');
    return clean.length === 0 ? 'track' : clean;
  }
}
