// AppConfig.ets —— 应用级常量（对应 Android BuildConfig 中与业务相关的字段 + 应用身份信息）。
//
// Android 侧这些值由 build.gradle.kts 注入 BuildConfig；鸿蒙无等价构建字段注入，
// 故集中在此声明，版本比对仍由 bundleManager 读 AppScope/app.json5 的 versionCode，保证与安装包一致。

export class AppConfig {
  /** 应用显示名（与 AppScope/resources app_name 一致） */
  static readonly APP_NAME: string = '调查宝';

  /** 包名（与 AppScope/app.json5 bundleName 一致） */
  static readonly BUNDLE_NAME: string = 'com.zys.MobileMap';

  /**
   * 升级元数据地址：与 Android BuildConfig.UPDATE_METADATA_URL 同一份 update.json，
   * 两端共用可使版本序列单一（versionCode 采用 yyyymmddnn 形态的整数）。
   */
  static readonly UPDATE_METADATA_URL: string =
    'https://gitee.com/z-gis/MobileMap/raw/master/update.json';

  /** 项目主页（update.json 缺失或链接失效时的兜底入口） */
  static readonly HOME_URL: string = 'https://gitee.com/z-gis/MobileMap';
}
