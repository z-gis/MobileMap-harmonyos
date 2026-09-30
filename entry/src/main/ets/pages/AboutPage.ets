// AboutPage.ets —— 关于页（对应 Android ui.activity.AboutActivity + activity_about.xml）。
//
// 内容与 Android 相同：GDAL 版本（点击展开其矢量驱动清单）、PROJ 版本、本机版本名/号、
// 检查更新、项目主页。差异：
//  1) Android 的「安装未知应用」授权跳转在鸿蒙无对应物（应用不可自行安装 HAP），
//     检查更新直接交给 UpdateManager，其内部改为打开下载地址；
//  2) 版本号取 bundleManager（等价 PackageManager 读 versionCode/versionName），无需申请权限；
//  3) 项目主页经 startAbility(viewData) 交系统浏览器打开，并按 Android 口径固定在页面最下方
//     居中（Scroll 之外的尾元素），只显示 URL 本身、不带「项目主页」标签。
// GDAL/PROJ 版本经 native 同步可得，故 aboutToAppear 直接回显；驱动清单惰性加载（首次展开才取）。

import { common, Want } from '@kit.AbilityKit';
import { NativeLayerInfo, NativeSrs } from '@zys/globecore';
import { AppConfig } from '../common/AppConfig';
import { Theme } from '../common/Theme';
import { Ui } from '../common/Ui';
import { UpdateManager } from '../update/UpdateManager';
import { TitleBar } from '../components/TitleBar';

/** 折叠箭头字形（与 Android 的 ▸ / ▾ 一致） */
const ARROW_COLLAPSED: string = '▸';
const ARROW_EXPANDED: string = '▾';
/**
 * 箭头字号：▸/▾ 属数学符号块，同字号下绘制得比拉丁字母矮小一圈，
 * 与 gdal 版本行文本字号相同会看着「箭头偏小」。这里按字形视觉高度补偿 +3fp，
 * 使其与同行文本看起来等大。
 */
const ARROW_FONT_SIZE: number = Theme.FONT + 3;

@Entry
@Component
struct AboutPage {
  /** 底部导航条避让高度（vp）：主窗口是全屏布局，页面内容要让开导航条，由 SystemInsets 写入 AppStorage */
  @StorageProp('bottomInsetVp') bottomInset: number = 0;
  @State gdalVersion: string = '';
  @State projVersion: string = '';
  @State versionName: string = '';
  @State versionCode: string = '';
  @State driversExpanded: boolean = false;
  /** 驱动清单惰性文本：空表示尚未取过（展开时向后缀一次即可，之后复用） */
  @State driversText: string = '';
  @State checking: boolean = false;

  private updateManager: UpdateManager | undefined = undefined;

  aboutToAppear(): void {
    this.gdalVersion = NativeLayerInfo.getGdalVersion();
    this.projVersion = `${NativeSrs.getProjVersion()}`;
    this.updateManager = new UpdateManager(
      this.getUIContext().getHostContext() as common.UIAbilityContext);
    UpdateManager.localVersionName().then((name: string): void => {
      this.versionName = name;
    });
    UpdateManager.localVersionCode().then((code: number): void => {
      this.versionCode = `${code}`;
    });
  }

  /** 展开/收起驱动清单：首次展开时才向 native 取（驱动枚举有耗时，不该拖慢首屏） */
  private toggleDrivers(): void {
    if (!this.driversExpanded && this.driversText.length === 0) {
      this.driversText = NativeLayerInfo.getVectorDrivers();
    }
    this.driversExpanded = !this.driversExpanded;
  }

  private checkUpdate(): void {
    const manager: UpdateManager | undefined = this.updateManager;
    if (manager === undefined || this.checking) {
      return;
    }
    this.checking = true;
    manager.checkForUpdates(true).then((): void => {
      this.checking = false;
    }).catch((): void => {
      this.checking = false;
    });
  }

  private openHome(): void {
    const ctx: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const want: Want = {
      action: 'ohos.want.action.viewData',
      uri: AppConfig.HOME_URL,
    };
    ctx.startAbility(want).catch((): void => {
      Ui.toastLong(`无法打开：${AppConfig.HOME_URL}`);
    });
  }

  build() {
    Column() {
      TitleBar({ title: '关于' })
      Scroll() {
        Column({ space: Theme.GAP }) {
          // 版本卡：应用名 + 版本名 + 版本号（Android 上分散在三行，此处同序同义）
          Column() {
            Text(AppConfig.APP_NAME)
              .fontSize(20)
              .fontWeight(FontWeight.Medium)
              .fontColor(Theme.TEXT)
            Text(`当前版本 V${this.versionName.length > 0 ? this.versionName : '-'}`)
              .fontSize(Theme.FONT)
              .fontColor(Theme.PRIMARY_DARK)
              .margin({ top: 8 })
            Text(`VersionCode: ${this.versionCode}`)
              .fontSize(Theme.FONT_SUB)
              .fontColor(Theme.TEXT_SUB)
              .margin({ top: 4 })
            Text('Copyright © 2026 MobileMap')
              .fontSize(Theme.FONT_SUB)
              .fontColor(Theme.TEXT_HINT)
              .margin({ top: 10 })
          }
          .width('100%')
          .padding(16)
          .alignItems(HorizontalAlign.Center)
          .backgroundColor(Theme.CARD)
          .borderRadius(Theme.RADIUS)

          // GDAL 版本行：可点折叠/展开驱动清单
          Column() {
            Row() {
              Text(`gdal Version: ${this.gdalVersion}`)
                .fontSize(Theme.FONT)
                .fontColor(Theme.TEXT)
                .layoutWeight(1)
              Text(this.driversExpanded ? ARROW_EXPANDED : ARROW_COLLAPSED)
                .fontSize(ARROW_FONT_SIZE)
                .fontColor(Theme.TEXT_SUB)
            }
            .width('100%')
            .onClick((): void => {
              this.toggleDrivers();
            })

            if (this.driversExpanded) {
              Text(this.driversText.length > 0 ? this.driversText : '（无）')
                .fontSize(Theme.FONT_SUB)
                .fontColor(Theme.TEXT_SUB)
                .width('100%')
                .margin({ top: 6 })
            }
          }
          .width('100%')
          .padding(12)
          .alignItems(HorizontalAlign.Start)
          .backgroundColor(Theme.CARD)
          .borderRadius(Theme.RADIUS)

          Text(`proj Version: ${this.projVersion}`)
            .fontSize(Theme.FONT)
            .fontColor(Theme.TEXT)
            .width('100%')
            .padding(12)
            .backgroundColor(Theme.CARD)
            .borderRadius(Theme.RADIUS)

          Button(this.checking ? '正在检查更新…' : '检查更新')
            .width('100%')
            .height(42)
            .fontSize(Theme.FONT)
            .fontColor(Theme.TEXT_ON_DARK)
            .backgroundColor(Theme.PRIMARY)
            .borderRadius(Theme.RADIUS)
            .enabled(!this.checking)
            .onClick((): void => {
              this.checkUpdate();
            })
        }
        .width('100%')
        .padding({ left: Theme.PAD, right: Theme.PAD, top: Theme.GAP, bottom: Theme.PAD })
      }
      .layoutWeight(1)
      .align(Alignment.Top)
      .scrollBar(BarState.Off)

      // 项目主页：页最下方居中的纯链接（对齐 Android activity_about.xml 的 about_git_link ——
      // match_parent + gravity=center、只写 URL 不加「项目主页」标签），点击交系统浏览器打开。
      Text(AppConfig.HOME_URL)
        .width('100%')
        .textAlign(TextAlign.Center)
        .fontSize(Theme.FONT_SUB)
        .fontColor(Theme.PRIMARY_DARK)
        .padding({ top: Theme.GAP, bottom: Theme.GAP, left: Theme.PAD, right: Theme.PAD })
        .onClick((): void => {
          this.openHome();
        })
    }
    .width('100%')
    .height('100%')
    .padding({ bottom: this.bottomInset })
    .backgroundColor(Theme.BG)
  }
}
