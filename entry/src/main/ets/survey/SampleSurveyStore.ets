// SampleSurveyStore.ets —— 样地调查数据仓库（对应 Android survey.SampleSurveyStore）。
//
// 库名与表结构同 Android sample_survey.db：survey_plots / survey_rows / survey_plot_photos，
// 含 (source_path, source_fid, plot_no) 唯一索引 —— 同一图斑的样地编号不重复由此保证。
// 与 Android 的「每次开关库」写法不同：鸿蒙 RDB 建库成本高且全异步，这里改为常驻实例（DbKit 缓存），
// 写入统一走事务（明细行全量替换 + 主表写入必须原子，否则中断会留下孤儿行）。

import { common } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { AppLog } from '../common/AppLog';
import { DbKit } from '../db/DbKit';
import { SurveyPhoto, SurveyPlot, SurveyRow } from './SurveyModels';

const DB_NAME: string = 'sample_survey.db';
const TABLE_PLOTS: string = 'survey_plots';
const TABLE_ROWS: string = 'survey_rows';
const TABLE_PHOTOS: string = 'survey_plot_photos';

const DDL: string[] = [
  `CREATE TABLE IF NOT EXISTS ${TABLE_PLOTS} (`
    + '_id INTEGER PRIMARY KEY AUTOINCREMENT, '
    + 'source_path TEXT NOT NULL, '
    + 'source_fid INTEGER NOT NULL, '
    + 'compartment_no TEXT, '
    + 'plot_no INTEGER NOT NULL, '
    + 'average_tree_height TEXT, '
    + 'canopy_density REAL, '
    + 'corner_coordinates TEXT, '
    + 'center_lat REAL, '
    + 'center_lon REAL, '
    + 'created_at INTEGER NOT NULL, '
    + 'updated_at INTEGER NOT NULL)',
  `CREATE UNIQUE INDEX IF NOT EXISTS idx_survey_plots_source_plot ON ${TABLE_PLOTS}`
    + '(source_path, source_fid, plot_no)',
  `CREATE TABLE IF NOT EXISTS ${TABLE_ROWS} (`
    + '_id INTEGER PRIMARY KEY AUTOINCREMENT, '
    + 'plot_id INTEGER NOT NULL, '
    + 'sort_no INTEGER NOT NULL, '
    + 'tree_species TEXT, '
    + 'dbh TEXT, '
    + 'category TEXT, '
    + 'thinning_method TEXT, '
    + 'remark TEXT)',
  `CREATE INDEX IF NOT EXISTS idx_survey_rows_plot_id ON ${TABLE_ROWS}(plot_id)`,
  `CREATE TABLE IF NOT EXISTS ${TABLE_PHOTOS} (`
    + '_id INTEGER PRIMARY KEY AUTOINCREMENT, '
    + 'plot_id INTEGER NOT NULL, '
    + 'file_path TEXT NOT NULL, '
    + 'captured_at INTEGER NOT NULL)',
  `CREATE INDEX IF NOT EXISTS idx_survey_photos_plot_id ON ${TABLE_PHOTOS}(plot_id)`,
];

const PLOT_COLUMNS: string = '_id, source_path, source_fid, compartment_no, plot_no, '
  + 'average_tree_height, canopy_density, corner_coordinates, center_lat, center_lon, '
  + 'created_at, updated_at';

export class SampleSurveyStore {
  private static inst: SampleSurveyStore | null = null;
  private store: relationalStore.RdbStore | null = null;
  private opening: Promise<void> | null = null;

  static async getInstance(ctx: common.Context): Promise<SampleSurveyStore> {
    if (SampleSurveyStore.inst === null) {
      SampleSurveyStore.inst = new SampleSurveyStore();
    }
    const repo: SampleSurveyStore = SampleSurveyStore.inst;
    await repo.ensure(ctx);
    return repo;
  }

  private async ensure(ctx: common.Context): Promise<void> {
    if (this.store !== null) {
      return;
    }
    if (this.opening === null) {
      this.opening = (async (): Promise<void> => {
        this.store = await DbKit.open(ctx, DB_NAME, DDL);
        if (this.store === null) {
          this.opening = null;
        }
      })();
    }
    await this.opening;
  }

  private need(): relationalStore.RdbStore | null {
    return this.store;
  }

  /** 按源路径 + FID 加载样地列表（含明细行），按样地编号升序 */
  async loadPlots(sourcePath: string, sourceFid: number): Promise<SurveyPlot[]> {
    const store: relationalStore.RdbStore | null = this.need();
    if (store === null) {
      return [];
    }
    const plots: SurveyPlot[] = await DbKit.query<SurveyPlot>(store,
      `SELECT ${PLOT_COLUMNS} FROM ${TABLE_PLOTS} WHERE source_path = ? AND source_fid = ? `
        + 'ORDER BY plot_no ASC', [sourcePath.trim(), sourceFid],
      (rs: relationalStore.ResultSet): SurveyPlot => SampleSurveyStore.readPlot(rs));
    for (let i = 0; i < plots.length; i++) {
      plots[i].rows = await this.loadRows(plots[i].id);
    }
    return plots;
  }

  /** 加载全部样地（地图覆盖用，不含明细行），按更新时间降序 */
  async loadAllPlots(): Promise<SurveyPlot[]> {
    const store: relationalStore.RdbStore | null = this.need();
    if (store === null) {
      return [];
    }
    return await DbKit.query<SurveyPlot>(store,
      `SELECT ${PLOT_COLUMNS} FROM ${TABLE_PLOTS} ORDER BY updated_at DESC, plot_no ASC`, [],
      (rs: relationalStore.ResultSet): SurveyPlot => SampleSurveyStore.readPlot(rs));
  }

  /** 按 ID 加载单个样地（含明细行）；不存在返回 undefined */
  async loadPlot(plotId: number): Promise<SurveyPlot | undefined> {
    const store: relationalStore.RdbStore | null = this.need();
    if (store === null || plotId <= 0) {
      return undefined;
    }
    const list: SurveyPlot[] = await DbKit.query<SurveyPlot>(store,
      `SELECT ${PLOT_COLUMNS} FROM ${TABLE_PLOTS} WHERE _id = ? LIMIT 1`, [plotId],
      (rs: relationalStore.ResultSet): SurveyPlot => SampleSurveyStore.readPlot(rs));
    if (list.length === 0) {
      return undefined;
    }
    const plot: SurveyPlot = list[0];
    plot.rows = await this.loadRows(plot.id);
    return plot;
  }

  /** 同图斑下的下一个样地编号（无记录时从 1 起） */
  async nextPlotNo(sourcePath: string, sourceFid: number): Promise<number> {
    const store: relationalStore.RdbStore | null = this.need();
    if (store === null) {
      return 1;
    }
    const max: number = await DbKit.queryLong(store,
      `SELECT COALESCE(MAX(plot_no), 0) FROM ${TABLE_PLOTS} WHERE source_path = ? AND source_fid = ?`,
      [sourcePath.trim(), sourceFid]);
    return max + 1;
  }

  /**
   * 创建草稿样地（未持久化，id=0）：编号即时占位、时间戳落当前，
   * 界面据此先渲染，用户确认后再 savePlot 落库。
   */
  async createDraftPlot(sourcePath: string, sourceFid: number, compartmentNo: string,
    cornerCoordinates: string, centerLat: number = Number.NaN,
    centerLon: number = Number.NaN): Promise<SurveyPlot> {
    const now: number = Date.now();
    const plot: SurveyPlot = new SurveyPlot();
    plot.id = 0;
    plot.sourcePath = sourcePath.trim();
    plot.sourceFid = sourceFid;
    plot.compartmentNo = compartmentNo.trim();
    plot.plotNo = await this.nextPlotNo(sourcePath, sourceFid);
    plot.cornerCoordinates = cornerCoordinates.trim();
    plot.centerLatitude = centerLat;
    plot.centerLongitude = centerLon;
    plot.createdAt = now;
    plot.updatedAt = now;
    return plot;
  }

  /**
   * 保存样地（新增或更新）+ 明细行全量替换，单事务。
   * @returns 保存后的样地（含 id 与 updatedAt）；失败返回 undefined
   */
  async savePlot(plot: SurveyPlot, rows: SurveyRow[]): Promise<SurveyPlot | undefined> {
    const store: relationalStore.RdbStore | null = this.need();
    if (store === null) {
      return undefined;
    }
    const now: number = Date.now();
    const isInsert: boolean = plot.id <= 0;
    const bucket: relationalStore.ValuesBucket = {
      'source_path': plot.sourcePath.trim(),
      'source_fid': plot.sourceFid,
      'compartment_no': plot.compartmentNo.trim(),
      'plot_no': plot.plotNo,
      'average_tree_height': plot.averageTreeHeight.trim(),
      'canopy_density': Number.isNaN(plot.canopyDensity) ? null : plot.canopyDensity,
      'corner_coordinates': plot.cornerCoordinates.trim(),
      'center_lat': Number.isNaN(plot.centerLatitude) ? null : plot.centerLatitude,
      'center_lon': Number.isNaN(plot.centerLongitude) ? null : plot.centerLongitude,
      'updated_at': now,
    };
    if (isInsert) {
      bucket['created_at'] = plot.createdAt > 0 ? plot.createdAt : now;
    }
    let plotId: number = plot.id;
    try {
      store.beginTransaction();
      if (isInsert) {
        const inserted: number = await DbKit.insert(store, TABLE_PLOTS, bucket);
        if (inserted < 0) {
          store.rollBack();
          return undefined;
        }
        plotId = inserted;
      } else {
        await DbKit.update(store, TABLE_PLOTS, bucket, '_id = ?', [plotId]);
      }
      // 明细行全量替换：先清后插，保证界面所见即库内所存（删行不会被残留）
      await DbKit.remove(store, TABLE_ROWS, 'plot_id = ?', [plotId]);
      for (let i = 0; i < rows.length; i++) {
        const row: SurveyRow = rows[i];
        row.sortNo = i;
        const rowId: number = await DbKit.insert(store, TABLE_ROWS, {
          'plot_id': plotId, 'sort_no': row.sortNo,
          'tree_species': row.treeSpecies.trim(), 'dbh': row.dbh.trim(),
          'category': row.category.trim(), 'thinning_method': row.thinningMethod.trim(),
          'remark': row.remark.trim(),
        });
        row.id = rowId;
        // 全量替换后数据库 id 会变，同步界面行标识，保证返回本页时 ForEach 不错位
        row.uid = rowId;
      }
      //  store 级事务无需 mark-successful：commit 即提交，异常路径统一 rollBack
      store.commit();
    } catch (e) {
      AppLog.e('savePlot 失败，回滚事务', e);
      try {
        store.rollBack();
      } catch (e2) {
        AppLog.w(`回滚异常: ${e2}`);
      }
      return undefined;
    }
    plot.id = plotId;
    plot.updatedAt = now;
    plot.rows = rows;
    return plot;
  }

  /** 删除样地（含明细行与照片记录） */
  async deletePlot(plotId: number): Promise<boolean> {
    const store: relationalStore.RdbStore | null = this.need();
    if (store === null || plotId <= 0) {
      return false;
    }
    try {
      store.beginTransaction();
      await DbKit.remove(store, TABLE_ROWS, 'plot_id = ?', [plotId]);
      await DbKit.remove(store, TABLE_PHOTOS, 'plot_id = ?', [plotId]);
      await DbKit.remove(store, TABLE_PLOTS, '_id = ?', [plotId]);
      store.commit();
      return true;
    } catch (e) {
      AppLog.e('deletePlot 失败', e);
      try {
        store.rollBack();
      } catch (e2) {
        AppLog.w(`回滚异常: ${e2}`);
      }
      return false;
    }
  }

  /** 添加样地照片记录（照片文件由调用方先落盘） */
  async addPhoto(plotId: number, filePath: string,
    capturedAt: number = Date.now()): Promise<SurveyPhoto | undefined> {
    const store: relationalStore.RdbStore | null = this.need();
    if (store === null || plotId <= 0 || filePath.trim().length === 0) {
      return undefined;
    }
    const id: number = await DbKit.insert(store, TABLE_PHOTOS, {
      'plot_id': plotId, 'file_path': filePath.trim(), 'captured_at': capturedAt,
    });
    if (id < 0) {
      return undefined;
    }
    const photo: SurveyPhoto = new SurveyPhoto();
    photo.id = id;
    photo.plotId = plotId;
    photo.filePath = filePath.trim();
    photo.capturedAt = capturedAt;
    return photo;
  }

  /** 加载样地照片列表（拍摄时间降序） */
  async loadPhotos(plotId: number): Promise<SurveyPhoto[]> {
    const store: relationalStore.RdbStore | null = this.need();
    if (store === null || plotId <= 0) {
      return [];
    }
    return await DbKit.query<SurveyPhoto>(store,
      'SELECT _id, plot_id, file_path, captured_at FROM ' + TABLE_PHOTOS
        + ' WHERE plot_id = ? ORDER BY captured_at DESC, _id DESC', [plotId],
      (rs: relationalStore.ResultSet): SurveyPhoto => {
        const photo: SurveyPhoto = new SurveyPhoto();
        photo.id = DbKit.int(rs, '_id');
        photo.plotId = DbKit.int(rs, 'plot_id');
        photo.filePath = DbKit.str(rs, 'file_path');
        photo.capturedAt = DbKit.num(rs, 'captured_at');
        return photo;
      });
  }

  /** 删除单条照片记录（文件由调用方删除） */
  async deletePhoto(photoId: number): Promise<void> {
    const store: relationalStore.RdbStore | null = this.need();
    if (store === null) {
      return;
    }
    await DbKit.remove(store, TABLE_PHOTOS, '_id = ?', [photoId]);
  }

  private async loadRows(plotId: number): Promise<SurveyRow[]> {
    const store: relationalStore.RdbStore | null = this.need();
    if (store === null) {
      return [];
    }
    return await DbKit.query<SurveyRow>(store,
      'SELECT _id, sort_no, tree_species, dbh, category, thinning_method, remark FROM '
        + TABLE_ROWS + ' WHERE plot_id = ? ORDER BY sort_no ASC, _id ASC', [plotId],
      (rs: relationalStore.ResultSet): SurveyRow => {
        const row: SurveyRow = new SurveyRow();
        row.id = DbKit.int(rs, '_id');
        row.uid = row.id;
        row.sortNo = DbKit.int(rs, 'sort_no');
        row.treeSpecies = DbKit.str(rs, 'tree_species');
        row.dbh = DbKit.str(rs, 'dbh');
        row.category = DbKit.str(rs, 'category');
        row.thinningMethod = DbKit.str(rs, 'thinning_method');
        row.remark = DbKit.str(rs, 'remark');
        return row;
      });
  }

  /** 结果行 → SurveyPlot；可空列（NULL）统一按缺省值处理（数值列空即 NaN） */
  private static readPlot(rs: relationalStore.ResultSet): SurveyPlot {
    const plot: SurveyPlot = new SurveyPlot();
    plot.id = DbKit.int(rs, '_id');
    plot.sourcePath = DbKit.str(rs, 'source_path');
    plot.sourceFid = DbKit.int(rs, 'source_fid');
    plot.compartmentNo = DbKit.str(rs, 'compartment_no');
    plot.plotNo = DbKit.int(rs, 'plot_no');
    plot.averageTreeHeight = DbKit.str(rs, 'average_tree_height');
    plot.canopyDensity = rs.isColumnNull(rs.getColumnIndex('canopy_density'))
      ? Number.NaN : DbKit.num(rs, 'canopy_density');
    plot.cornerCoordinates = DbKit.str(rs, 'corner_coordinates');
    plot.centerLatitude = rs.isColumnNull(rs.getColumnIndex('center_lat'))
      ? Number.NaN : DbKit.num(rs, 'center_lat');
    plot.centerLongitude = rs.isColumnNull(rs.getColumnIndex('center_lon'))
      ? Number.NaN : DbKit.num(rs, 'center_lon');
    plot.createdAt = DbKit.num(rs, 'created_at');
    plot.updatedAt = DbKit.num(rs, 'updated_at');
    return plot;
  }
}
