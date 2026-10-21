// TileCacheMigration.ets —— 旧目录式瓦片缓存 → 单文件 MBTiles 迁移门面
// （对应 Android MapLayerManager.migrateLegacyTileDir(Static) + migrateBaseTileCaches）。
//
// 语义：`<dir>/<z>/<x>_<y>.tile` → <mbtiles>（INSERT OR REPLACE 幂等、TMS y 翻转、schema 与引擎
// TileCache 单文件后端逐字一致）；全部迁完才删旧目录，失败回滚保留旧目录下次重试。
// 鸿蒙 ArkTS 无任意路径 SQLite API（relationalStore 只能开 RDB 目录库），迁移由引擎 NAPI 完成。
// native 调用本身同步阻塞，本封装先同步跑完迁移再返回已解决 Promise——同步上下文直接调用即
// 顺序生效（加层前迁移必须先行完成），异步上下文亦可 await。
import { NativeTiles } from '@zys/globecore';
import { AppDirs } from '../common/AppDirs';
import { AppLog } from '../common/AppLog';
import { MapDocument, MapSource } from '../doc/DocModels';

const TAG: string = 'TileCacheMigration';

export class TileCacheMigration {

  /**
   * 旧目录瓦片缓存一次性迁入单文件 MBTiles（薄封装 NativeTiles.nativeMigrateTileDir）。
   * 同步执行完毕才返回；返回值仅为可 await 形态。n<0 失败时旧目录保留、下次启动重迁。
   */
  static migrateLegacyTileDir(dir: string, mbtiles: string): Promise<void> {
    try {
      const n: number = NativeTiles.nativeMigrateTileDir(dir, mbtiles);
      if (n > 0) {
        AppLog.i(`${TAG} 瓦片缓存迁移完成: ${dir} → ${mbtiles} 共${n}块`);
      } else if (n < 0) {
        AppLog.w(`${TAG} 瓦片缓存迁移失败（保留旧目录，下次重试）: ${dir}`);
      }
    } catch (e) {
      AppLog.e(`${TAG} 瓦片缓存迁移异常（保留旧目录）: ${dir}`, e);
    }
    return Promise.resolve();
  }

  /** 底图/注记图源迁移：旧目录 tiles/<净化名> → tiles/<净化名>.mbtiles */
  static migrateBaseTile(sourceName: string): Promise<void> {
    return TileCacheMigration.migrateLegacyTileDir(
      AppDirs.baseTileDir(sourceName), AppDirs.baseTileMbtiles(sourceName));
  }

  /** 栅格图层迁移：旧目录 tiles/raster-jni/<hash> → tiles/raster/<净化栅格名>.mbtiles */
  static migrateRasterTile(path: string): Promise<void> {
    return TileCacheMigration.migrateLegacyTileDir(
      AppDirs.rasterTileDir(path), AppDirs.rasterTileMbtiles(path));
  }

  /**
   * 启动期批量迁移底图/注记图源旧瓦片目录（对齐 Android migrateBaseTileCaches）：
   * 图层装配前对文档全部 mapSources 先跑一遍，避免逐层首启卡顿；加层点迁移保留作兜底。
   */
  static migrateBaseTileCaches(doc: MapDocument | null): Promise<void> {
    if (doc === null) {
      return Promise.resolve();
    }
    const sources: MapSource[] = doc.mapSources;
    for (let i = 0; i < sources.length; i++) {
      TileCacheMigration.migrateBaseTile(sources[i].name ?? '');
    }
    return Promise.resolve();
  }
}
