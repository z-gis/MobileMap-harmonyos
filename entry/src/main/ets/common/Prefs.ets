// Prefs.ets —— 轻量键值持久化（对应 Android 侧的 SharedPreferences 用法）。
//
// 用于「与文档无关」的设备级状态：相机独立视角与 2D/3D 模式（prefs 名 jni_map_camera，
// 沿用 Android 命名以便理解）、图层对话框展开态、升级跳过版本号等。
// 业务数据（图层/轨迹/照片/样地）不走本类，分别落 document.json 与 relationalStore。
// Preferences 实例按 name 缓存复用，写操作统一 put + flush（与 Android commit 语义一致）。
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { AppLog } from './AppLog';

const TAG: string = 'Prefs';

export class Prefs {
  private static readonly cache: Map<string, preferences.Preferences> = new Map<string, preferences.Preferences>();

  private static async store(ctx: common.Context, name: string): Promise<preferences.Preferences | null> {
    const hit: preferences.Preferences | undefined = Prefs.cache.get(name);
    if (hit !== undefined) {
      return hit;
    }
    try {
      const created: preferences.Preferences = await preferences.getPreferences(ctx, name);
      Prefs.cache.set(name, created);
      return created;
    } catch (e) {
      AppLog.e(`${TAG} 打开 preferences 失败: ${name}`, e);
      return null;
    }
  }

  static async getNumber(ctx: common.Context, name: string, key: string, def: number): Promise<number> {
    const sp: preferences.Preferences | null = await Prefs.store(ctx, name);
    if (sp === null) {
      return def;
    }
    try {
      return await sp.get(key, def) as number;
    } catch (e) {
      AppLog.e(`${TAG} get ${key} 失败`, e);
      return def;
    }
  }

  static async putNumber(ctx: common.Context, name: string, key: string, value: number): Promise<void> {
    Prefs.write(ctx, name, key, value);
  }

  static async getBool(ctx: common.Context, name: string, key: string, def: boolean): Promise<boolean> {
    const sp: preferences.Preferences | null = await Prefs.store(ctx, name);
    if (sp === null) {
      return def;
    }
    try {
      return await sp.get(key, def) as boolean;
    } catch (e) {
      AppLog.e(`${TAG} get ${key} 失败`, e);
      return def;
    }
  }

  static async putBool(ctx: common.Context, name: string, key: string, value: boolean): Promise<void> {
    Prefs.write(ctx, name, key, value);
  }

  static async getString(ctx: common.Context, name: string, key: string, def: string): Promise<string> {
    const sp: preferences.Preferences | null = await Prefs.store(ctx, name);
    if (sp === null) {
      return def;
    }
    try {
      return await sp.get(key, def) as string;
    } catch (e) {
      AppLog.e(`${TAG} get ${key} 失败`, e);
      return def;
    }
  }

  static async putString(ctx: common.Context, name: string, key: string, value: string): Promise<void> {
    Prefs.write(ctx, name, key, value);
  }

  static async deleteKey(ctx: common.Context, name: string, key: string): Promise<void> {
    const sp: preferences.Preferences | null = await Prefs.store(ctx, name);
    if (sp === null) {
      return;
    }
    try {
      await sp.delete(key);
      await sp.flush();
    } catch (e) {
      AppLog.e(`${TAG} delete ${key} 失败`, e);
    }
  }

  private static async write(ctx: common.Context, name: string, key: string,
    value: preferences.ValueType): Promise<void> {
    const sp: preferences.Preferences | null = await Prefs.store(ctx, name);
    if (sp === null) {
      return;
    }
    try {
      await sp.put(key, value);
      await sp.flush();
    } catch (e) {
      AppLog.e(`${TAG} put ${key} 失败`, e);
    }
  }
}
