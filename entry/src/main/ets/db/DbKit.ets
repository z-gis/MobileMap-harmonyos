// DbKit.ets —— 关系型数据库底座（对应 Android SQLite 直开 + SqliteSchema 迁移工具）。
//
// 与 Android 的两点差异：
//  1. 鸿蒙 @kit.ArkData relationalStore 全异步（Promise），故所有仓库方法均为 async，UI 侧 await；
//     Android 侧主线程直查的写法不迁移（会阻塞 UI 线程）。
//  2. Android 把库文件放在 /调查宝/<子目录>/xxx.db 便于用户用文件管理器拷取；
//     relationalStore 的 StoreConfig 只接受库名（落在应用 RDB 目录），无自定义目录能力，
//     故沿用默认目录、保持同名（map.db / media.db / sample_survey.db），外业导出改由「工程文件」承担。
// 迁移口径与 Android SqliteSchema 一致：PRAGMA table_info 检测缺列 → ALTER TABLE ADD COLUMN，
// 非破坏式补列，不重建表、不丢既有数据。

import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { AppLog } from '../common/AppLog';

const TAG: string = 'DbKit';

export class DbKit {
  /** 库名 → 已打开 store 缓存（同库多处复用，避免重复 getRdbStore 的建表开销） */
  private static readonly stores: Map<string, relationalStore.RdbStore> =
    new Map<string, relationalStore.RdbStore>();
  /** 打开中的 Promise：并发首次访问时共享同一次建库过程，避免两路同时跑 CREATE TABLE */
  private static readonly opening: Map<string, Promise<relationalStore.RdbStore | null>> =
    new Map<string, Promise<relationalStore.RdbStore | null>>();

  /**
   * 取（必要时创建）数据库：S1 安全级（外业数据非机密，且低安全级免去设备锁屏依赖）。
   * 失败返回 null，调用方按「无数据」降级，不让异常冒泡打断界面。
   */
  static async open(ctx: common.Context, name: string, ddl: string[]): Promise<relationalStore.RdbStore | null> {
    const hit: relationalStore.RdbStore | undefined = DbKit.stores.get(name);
    if (hit !== undefined) {
      return hit;
    }
    const pending: Promise<relationalStore.RdbStore | null> | undefined = DbKit.opening.get(name);
    if (pending !== undefined) {
      return pending;
    }
    const task: Promise<relationalStore.RdbStore | null> = DbKit.create(ctx, name, ddl);
    DbKit.opening.set(name, task);
    return task;
  }

  private static async create(ctx: common.Context, name: string,
    ddl: string[]): Promise<relationalStore.RdbStore | null> {
    try {
      const config: relationalStore.StoreConfig = {
        name: name,
        securityLevel: relationalStore.SecurityLevel.S1,
      };
      const store: relationalStore.RdbStore = await relationalStore.getRdbStore(ctx, config);
      for (let i = 0; i < ddl.length; i++) {
        await store.executeSql(ddl[i]);
      }
      DbKit.stores.set(name, store);
      return store;
    } catch (e) {
      AppLog.e(`${TAG} 打开数据库失败: ${name}`, e);
      return null;
    }
  }

  /**
   * 非破坏式补列：表缺 column 时执行 alterSql。
   * PRAGMA 结果列名在不同系统版本上有差异（name / cid），故按下标 1 取列名（PRAGMA table_info 固定第二列为 name）。
   */
  static async ensureColumn(store: relationalStore.RdbStore, table: string, column: string,
    alterSql: string): Promise<void> {
    const has: boolean = await DbKit.hasColumn(store, table, column);
    if (!has) {
      await store.executeSql(alterSql);
      AppLog.i(`${TAG} 表 ${table} 补列 ${column}`);
    }
  }

  static async hasColumn(store: relationalStore.RdbStore, table: string, column: string): Promise<boolean> {
    let rs: relationalStore.ResultSet | null = null;
    try {
      rs = await store.querySql(`PRAGMA table_info(${table})`);
      while (rs.goToNextRow()) {
        const name: string = rs.getString(1);
        if (name === column) {
          return true;
        }
      }
      return false;
    } catch (e) {
      AppLog.w(`${TAG} PRAGMA ${table} 失败: ${e}`);
      return false;
    } finally {
      DbKit.close(rs);
    }
  }

  /** 单列整型查询（SUM/COUNT 等聚合常用），无结果或失败返回 0 */
  static async queryLong(store: relationalStore.RdbStore, sql: string,
    args: relationalStore.ValueType[] = []): Promise<number> {
    let rs: relationalStore.ResultSet | null = null;
    try {
      rs = await store.querySql(sql, args);
      if (rs.goToFirstRow()) {
        return rs.getLong(0);
      }
      return 0;
    } catch (e) {
      AppLog.e(`${TAG} queryLong 失败: ${sql}`, e);
      return 0;
    } finally {
      DbKit.close(rs);
    }
  }

  /**
   * 通用查询：逐行交给 reader 转换为业务对象。
   * reader 内用 columnIndex 取列（列名常量在调用方声明，避免下标漂移）。
   */
  static async query<T>(store: relationalStore.RdbStore, sql: string,
    args: relationalStore.ValueType[], reader: (rs: relationalStore.ResultSet) => T | null): Promise<T[]> {
    const out: T[] = [];
    let rs: relationalStore.ResultSet | null = null;
    try {
      rs = await store.querySql(sql, args);
      while (rs.goToNextRow()) {
        const item: T | null = reader(rs);
        if (item !== null) {
          out.push(item);
        }
      }
    } catch (e) {
      AppLog.e(`${TAG} 查询失败: ${sql}`, e);
    } finally {
      DbKit.close(rs);
    }
    return out;
  }

  /** 插入一行并回自增主键；失败返回 -1（等价 Android db.insert） */
  static async insert(store: relationalStore.RdbStore, table: string,
    bucket: relationalStore.ValuesBucket): Promise<number> {
    try {
      const rowId: number = await store.insert(table, bucket);
      return rowId;
    } catch (e) {
      AppLog.e(`${TAG} insert ${table} 失败`, e);
      return -1;
    }
  }

  /** 按 WHERE 更新，返回受影响行数（等价 Android db.update） */
  static async update(store: relationalStore.RdbStore, table: string, bucket: relationalStore.ValuesBucket,
    where: string, args: relationalStore.ValueType[]): Promise<number> {
    try {
      return await store.update(bucket, DbKit.predicates(table, where, args));
    } catch (e) {
      AppLog.e(`${TAG} update ${table} 失败`, e);
      return 0;
    }
  }

  /** 按 WHERE 删除，返回受影响行数（等价 Android db.delete） */
  static async remove(store: relationalStore.RdbStore, table: string,
    where: string, args: relationalStore.ValueType[]): Promise<number> {
    try {
      return await store.delete(DbKit.predicates(table, where, args));
    } catch (e) {
      AppLog.e(`${TAG} delete ${table} 失败`, e);
      return 0;
    }
  }

  /**
   * 「col = ? AND col2 = ?」形式的等值条件构造：Android 侧大量使用 `id = ?` 单条件，
   * 这里按分段数还原为 RdbPredicates，避免各处手写谓词带来的口径分歧。
   */
  static predicates(table: string, where: string, args: relationalStore.ValueType[]): relationalStore.RdbPredicates {
    const p: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(table);
    const parts: string[] = where.split(/\s+and\s+/i);
    for (let i = 0; i < parts.length; i++) {
      const seg: string[] = parts[i].split('=');
      if (seg.length < 2) {
        continue;
      }
      const col: string = seg[0].trim();
      const value: relationalStore.ValueType | undefined = args[i];
      if (col.length > 0 && value !== undefined) {
        p.equalTo(col, value);
      }
    }
    return p;
  }

  /** 结果集列名 → 下标缓存：同一次遍历内多次取值时省去重复 getColumnIndex 开销 */
  static idx(rs: relationalStore.ResultSet, column: string): number {
    return rs.getColumnIndex(column);
  }

  /** 安全取字符串（NULL 列 getColumnIndex 后 getString 会抛，先判 isColumnNull） */
  static str(rs: relationalStore.ResultSet, column: string): string {
    const i: number = rs.getColumnIndex(column);
    try {
      return rs.isColumnNull(i) ? '' : rs.getString(i);
    } catch (e) {
      return '';
    }
  }

  static num(rs: relationalStore.ResultSet, column: string, def: number = 0): number {
    const i: number = rs.getColumnIndex(column);
    try {
      return rs.isColumnNull(i) ? def : rs.getDouble(i);
    } catch (e) {
      return def;
    }
  }

  static int(rs: relationalStore.ResultSet, column: string, def: number = 0): number {
    const i: number = rs.getColumnIndex(column);
    try {
      return rs.isColumnNull(i) ? def : rs.getLong(i);
    } catch (e) {
      return def;
    }
  }

  /** 无符号 32 位 ARGB 颜色读取：老库以有符号 INTEGER 存（Android Int 溢出），统一还原为无符号 */
  static color(rs: relationalStore.ResultSet, column: string, def: number): number {
    const raw: number = DbKit.num(rs, column, 0);
    return raw === 0 ? def : (raw >>> 0);
  }

  static close(rs: relationalStore.ResultSet | null): void {
    if (rs === null) {
      return;
    }
    try {
      rs.close();
    } catch (e) {
      AppLog.w(`${TAG} 结果集关闭异常: ${e}`);
    }
  }
}
