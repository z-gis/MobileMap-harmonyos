// UpdateManager.ets —— 应用内升级编排（对应 Android update.AppUpdateManager + UpdateUiNotifier）。
//
// Android 流程：检查元数据 → 提示升级 → 后台下载 APK（带进度框）→ 拉起安装。
// 鸿蒙沙箱模型下**应用不可自行安装安装包**（无 REQUEST_PACKAGE_INSTALLS 权限，也无 FileProvider/DownloadManager 等价物），
// 故本类收敛为「检查 + 提示 + 打开下载地址」：
//   · 检查与版本比对规则与 Android 完全一致（UpdateChecker / UpdateVersionPolicy）；
//   · force 升级在 Android 上是不可取消对话框，这里仍列出「以后再说」但再次进入会重新提示（平台无法阻塞式强更）；
//   · 「立即更新」经 startAbility(viewData) 打开 apkUrl 对应的网页/HAP 下载地址，由用户在系统侧完成安装；
//   · Android 的下载进度框、前台服务、APK 缓存清理等子步骤在鸿蒙侧无对应物，一并省去。

import { bundleManager, common, Want } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { AppConfig } from '../common/AppConfig';
import { AppLog } from '../common/AppLog';
import { Ui } from '../common/Ui';
import { UpdateChecker } from './UpdateChecker';
import { UpdateInfo } from './UpdateInfo';
import { UpdateVersionPolicy } from './UpdateVersionPolicy';

export class UpdateManager {
  private readonly ctx: common.UIAbilityContext;
  /** 防止「自动检查 + 手动检查」并发拉取 */
  private checking: boolean = false;

  constructor(ctx: common.UIAbilityContext) {
    this.ctx = ctx;
  }

  /** 本机 versionCode（AppScope/app.json5）；取不到返回 0（任何有效元数据都会提示升级） */
  static async localVersionCode(): Promise<number> {
    try {
      const info: bundleManager.BundleInfo = await bundleManager.getBundleInfoForSelf(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      return info.versionCode;
    } catch (e) {
      AppLog.e('读取本机版本号失败', e);
      return 0;
    }
  }

  /** 本机 versionName；取不到返回空串 */
  static async localVersionName(): Promise<string> {
    try {
      const info: bundleManager.BundleInfo = await bundleManager.getBundleInfoForSelf(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      return info.versionName ?? '';
    } catch (e) {
      AppLog.e('读取本机版本名失败', e);
      return '';
    }
  }

  /**
   * 检查更新。
   * @param userInitiated 是否用户主动触发（关于页/设置页）：主动触发才提示「已最新」「检查失败」
   */
  async checkForUpdates(userInitiated: boolean): Promise<void> {
    if (this.checking) {
      return;
    }
    const metadataUrl: string = AppConfig.UPDATE_METADATA_URL;
    if (metadataUrl.trim().length === 0) {
      if (userInitiated) {
        Ui.toast('未配置升级检查地址');
      }
      return;
    }
    if (userInitiated) {
      Ui.toast('正在检查更新...');
    }
    this.checking = true;
    try {
      const info: UpdateInfo = await UpdateChecker.check(metadataUrl);
      const current: number = await UpdateManager.localVersionCode();
      if (!UpdateVersionPolicy.shouldPrompt(info, current)) {
        if (userInitiated) {
          const name: string = await UpdateManager.localVersionName();
          Ui.toast(`已是最新版本${name.length > 0 ? `（${name}）` : ''}`);
        }
        return;
      }
      await this.showUpdateDialog(info);
    } catch (e) {
      // 检查失败只给笼统提示，详情落日志（与 Android 一致）
      AppLog.e('检查更新失败', e);
      if (userInitiated) {
        Ui.toast('检查更新失败，请检查网络');
      }
    } finally {
      this.checking = false;
    }
  }

  /** 升级提示对话框：force 时只给「立即更新」；取消/失败均视为稍后再说 */
  private async showUpdateDialog(info: UpdateInfo): Promise<void> {
    const buttons: promptAction.Button[] = [];
    if (!info.force) {
      buttons.push({ text: '以后再说', color: '#FF888888' });
    }
    buttons.push({ text: '立即更新', color: '#FFE64545' });

    const changelog: string = info.changelog.trim().length > 0 ? info.changelog : '暂无更新说明';
    const sizeText: string = info.sizeText();
    let message: string = `新版本 ${info.versionName}（${info.versionCode}）`;
    if (sizeText.length > 0) {
      message += `\n安装包大小：${sizeText}`;
    }
    if (info.force) {
      message += '\n\n本次更新为强制更新，请升级后继续使用。';
    }
    message += `\n\n更新内容：\n${changelog}`;

    let agreed: boolean = false;
    try {
      const res: promptAction.ShowDialogSuccessResponse = await promptAction.showDialog({
        title: '发现新版本',
        message: message,
        buttons: buttons,
      });
      // 按钮顺序固定：非强制时下标 1 为「立即更新」，强制时只有 0
      agreed = info.force ? res.index === 0 : res.index === 1;
    } catch (e) {
      AppLog.w('升级对话框显示失败', `${e}`);
      return;
    }
    if (agreed) {
      await this.openDownload(info);
    }
  }

  /** 打开下载地址：由系统浏览器/下载页接管（鸿蒙无法在应用内安装安装包） */
  private async openDownload(info: UpdateInfo): Promise<void> {
    const want: Want = {
      action: 'ohos.want.action.viewData',
      uri: info.downloadUrl,
    };
    try {
      await this.ctx.startAbility(want);
      Ui.toastLong('已打开下载地址，请按页面提示完成安装');
    } catch (e) {
      AppLog.e('打开下载地址失败', e);
      Ui.toastLong(`无法打开下载地址：${info.downloadUrl}`);
    }
  }
}
