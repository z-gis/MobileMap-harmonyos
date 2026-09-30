// UpdateInfo.ets —— 升级元数据模型（对应 Android update.UpdateInfo）。

/** update.json 的原始结构：字段全部可缺省，缺省口径与 Android JSONObject.optXxx 一致 */
export interface UpdateJson {
  versionCode?: number;
  versionName?: string;
  apkUrl?: string;
  changelog?: string;
  force?: boolean;
  apkSizeBytes?: number;
}

export class UpdateInfo {
  /** 服务端版本号（与安装包 versionCode 同一整数序列） */
  versionCode: number;
  versionName: string;
  /** 安装包下载地址（鸿蒙侧无法自装，仅作「打开下载页」用） */
  downloadUrl: string;
  changelog: string;
  /** 是否强制升级 */
  force: boolean;
  /** 安装包体积（字节），-1 表示服务端未提供 */
  sizeBytes: number;

  constructor(versionCode: number = 0, versionName: string = '', downloadUrl: string = '',
    changelog: string = '', force: boolean = false, sizeBytes: number = -1) {
    this.versionCode = versionCode;
    this.versionName = versionName;
    this.downloadUrl = downloadUrl;
    this.changelog = changelog;
    this.force = force;
    this.sizeBytes = sizeBytes;
  }

  /** 由 update.json 解析结果构造（缺省值与 Android optInt/optString/optBoolean/optLong 对齐） */
  static fromJson(json: UpdateJson): UpdateInfo {
    return new UpdateInfo(json.versionCode ?? 0, json.versionName ?? '', json.apkUrl ?? '',
      json.changelog ?? '', json.force ?? false, json.apkSizeBytes ?? -1);
  }

  /** 供 UI 展示：体积可读化，未提供时返回空串 */
  sizeText(): string {
    if (this.sizeBytes <= 0) {
      return '';
    }
    const mb: number = this.sizeBytes / (1024 * 1024);
    return mb >= 1 ? `${mb.toFixed(1)} MB` : `${Math.round(this.sizeBytes / 1024)} KB`;
  }
}
