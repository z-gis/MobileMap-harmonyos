// UpdateVersionPolicy.ets —— 版本比对策略（对应 Android update.UpdateVersionPolicy）。
//
// 与 Android 完全同规则：元数据完整（版本号 > 0 且下载地址非空）且服务端版本号高于本机才提示，
// 两端共用一份 update.json 时行为一致。

import { UpdateInfo } from './UpdateInfo';

export class UpdateVersionPolicy {
  /** 升级元数据是否完整可用（版本号 > 0 且下载地址非空） */
  static isValidMetadata(info: UpdateInfo | null): boolean {
    if (info === null) {
      return false;
    }
    return info.versionCode > 0 && info.downloadUrl.trim().length > 0;
  }

  /** 是否应提示升级：元数据完整且服务端版本号高于当前版本 */
  static shouldPrompt(info: UpdateInfo | null, currentVersionCode: number): boolean {
    if (info === null) {
      return false;
    }
    return UpdateVersionPolicy.isValidMetadata(info) && info.versionCode > currentVersionCode;
  }
}
