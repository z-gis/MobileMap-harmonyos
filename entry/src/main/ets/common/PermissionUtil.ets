// PermissionUtil.ets —— 运行时权限申请（对应 Android com.zys.mobilemap.util.PermissionUtil）。
//
// Android 侧权限门在启动时检查「所有文件访问」（MANAGE_EXTERNAL_STORAGE），未授予跳系统设置页并挂起初始化；
// 鸿蒙沙箱无该概念（外部数据统一经文件选择器导入沙箱），故权限门收敛为定位与拍照两类 user_grant 权限，
// 且改为「用到时申请」而非启动阻塞式，与 Android 的启动门在行为上等价但更轻。
import { abilityAccessCtrl, bundleManager, common, Permissions } from '@kit.AbilityKit';
import { AppLog } from './AppLog';

const TAG: string = 'PermissionUtil';

/** 定位权限组：粗略 + 精确（Android 的 COARSE/FINE 对应鸿蒙两级，须同批申请才能拿到精确坐标与海拔） */
const LOCATION_PERMISSIONS: Permissions[] = [
  'ohos.permission.APPROXIMATELY_LOCATION',
  'ohos.permission.LOCATION',
];

/** 拍照权限 */
const CAMERA_PERMISSIONS: Permissions[] = ['ohos.permission.CAMERA'];

export class PermissionUtil {
  /** 定位权限是否已全部授予 */
  static async hasLocation(ctx: common.UIAbilityContext): Promise<boolean> {
    return PermissionUtil.granted(ctx, LOCATION_PERMISSIONS);
  }

  /** 拍照权限是否已授予 */
  static async hasCamera(ctx: common.UIAbilityContext): Promise<boolean> {
    return PermissionUtil.granted(ctx, CAMERA_PERMISSIONS);
  }

  /** 申请定位权限；返回是否授予（拒绝由调用方提示，不弹系统跳转页） */
  static async requestLocation(ctx: common.UIAbilityContext): Promise<boolean> {
    return PermissionUtil.request(ctx, LOCATION_PERMISSIONS);
  }

  /** 申请拍照权限 */
  static async requestCamera(ctx: common.UIAbilityContext): Promise<boolean> {
    return PermissionUtil.request(ctx, CAMERA_PERMISSIONS);
  }

  private static async granted(ctx: common.UIAbilityContext,
    perms: Permissions[]): Promise<boolean> {
    try {
      const atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
      const tokenID: number = await PermissionUtil.selfTokenId();
      for (let i = 0; i < perms.length; i++) {
        const state: abilityAccessCtrl.GrantStatus =
          atManager.checkAccessTokenSync(tokenID, perms[i]);
        if (state !== abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
          return false;
        }
      }
      return true;
    } catch (e) {
      AppLog.e(`${TAG} checkAccessToken 失败`, e);
      return false;
    }
  }

  private static async request(ctx: common.UIAbilityContext,
    perms: Permissions[]): Promise<boolean> {
    try {
      const atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
      const result = await atManager.requestPermissionsFromUser(ctx, perms);
      const codes: number[] = result.authResults;
      for (let i = 0; i < codes.length; i++) {
        if (codes[i] !== 0) {
          AppLog.w(`${TAG} 权限被拒绝: ${perms[i]}`);
          return false;
        }
      }
      return codes.length > 0;
    } catch (e) {
      AppLog.e(`${TAG} requestPermissionsFromUser 失败`, e);
      return false;
    }
  }

  /** 本应用 accessTokenId：用于 checkAccessTokenSync 自查 */
  private static async selfTokenId(): Promise<number> {
    const info: bundleManager.BundleInfo = await bundleManager.getBundleInfoForSelf(
      bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
    return info.appInfo.accessTokenId;
  }
}
