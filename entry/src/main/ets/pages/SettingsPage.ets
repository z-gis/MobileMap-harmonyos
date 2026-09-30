// SettingsPage.ets —— 设置页（对应 Android ui.activity.SettingsActivity + activity_settings.xml）。
//
// 与 Android 一致：全部开关直接读写文档内的 SystemConfig，退出页面时落盘。
// 差异：鸿蒙无「Activity 销毁」的稳定时序保证（后台回收不回调 aboutToDisappear 的情况存在），
// 故改为「每次切换即刻保存」——语义更强（不会丢设置），代价是切换即触发一次文档变更广播；
// 主界面的文档监听只在结构签名变化时重建，显隐类开关走就地同步，不会引起地图重建。
// 「帮助 / 关于」在 Android 是两行入口按钮，此处同样保持为两行可点条目。

import { router } from '@kit.ArkUI';
import { Theme } from '../common/Theme';
import { MapDocument, SystemConfig } from '../doc/DocModels';
import { DocumentManager } from '../doc/DocumentManager';
import { SwitchRow } from '../components/SwitchRow';
import { TitleBar } from '../components/TitleBar';

@Entry
@Component
struct SettingsPage {
  /** 底部导航条避让高度（vp）：主窗口是全屏布局，页面内容要让开导航条 */
  @StorageProp('bottomInsetVp') bottomInset: number = 0;
  /** 十项开关的显示状态：进入时从文档回显，切换后与文档同步 */
  @State showCenterCross: boolean = true;
  @State showMediaLayer: boolean = true;
  @State showPhotoName: boolean = false;
  @State showTrackLayer: boolean = true;
  @State showMeasureLayer: boolean = true;
  @State coordDisplayMeter: boolean = false;
  @State showKmlLabel: boolean = false;
  @State viewMode3d: boolean = false;
  @State photoAddWatermark: boolean = true;
  @State backgroundLocation: boolean = false;

  aboutToAppear(): void {
    const config: SystemConfig = DocumentManager.getInstance().getConfig();
    this.showCenterCross = config.showCenterCross;
    this.showMediaLayer = config.showMediaLayer;
    this.showPhotoName = config.showPhotoName;
    this.showTrackLayer = config.showTrackLayer;
    this.showMeasureLayer = config.showMeasureLayer;
    this.coordDisplayMeter = config.coordDisplayMeter;
    this.showKmlLabel = config.showKmlLabel;
    this.viewMode3d = config.viewMode3d;
    this.photoAddWatermark = config.photoAddWatermark;
    this.backgroundLocation = config.backgroundLocation;
  }

  /**
   * 统一写通道：先改 @State（驱动 UI）再写文档（驱动地图）。
   * 文档未加载（异常场景）时只改显示，不静默创建文档，避免与主界面的加载时序竞争。
   */
  private applyConfig(mutate: (config: SystemConfig) => void): void {
    DocumentManager.getInstance().update((doc: MapDocument): void => {
      mutate(doc.systemConfig);
    });
  }

  build() {
    Column() {
      TitleBar({ title: '设置' })
      Scroll() {
        Column({ space: Theme.GAP }) {
          this.groupTitle('显示')
          SwitchRow({
            title: '中心十字准星',
            subtitle: '在地图中心显示十字，便于以屏幕中心取点/测量',
            isOn: this.showCenterCross,
            onSwitchChange: (v: boolean): void => {
              this.showCenterCross = v;
              this.applyConfig((c: SystemConfig): void => {
                c.showCenterCross = v;
              });
            },
          })
          SwitchRow({
            title: '照片点位图层',
            subtitle: '在地图上显示已拍摄的拍照点位',
            isOn: this.showMediaLayer,
            onSwitchChange: (v: boolean): void => {
              this.showMediaLayer = v;
              this.applyConfig((c: SystemConfig): void => {
                c.showMediaLayer = v;
              });
            },
          })
          SwitchRow({
            title: '照片名称标注',
            subtitle: '拍照点位旁显示点位名称',
            isOn: this.showPhotoName,
            onSwitchChange: (v: boolean): void => {
              this.showPhotoName = v;
              this.applyConfig((c: SystemConfig): void => {
                c.showPhotoName = v;
              });
            },
          })
          SwitchRow({
            title: '轨迹图层',
            subtitle: '在地图上显示已记录的轨迹线',
            isOn: this.showTrackLayer,
            onSwitchChange: (v: boolean): void => {
              this.showTrackLayer = v;
              this.applyConfig((c: SystemConfig): void => {
                c.showTrackLayer = v;
              });
            },
          })
          SwitchRow({
            title: '测量图层',
            subtitle: '在地图上显示已保存的距离/面积/点位测量',
            isOn: this.showMeasureLayer,
            onSwitchChange: (v: boolean): void => {
              this.showMeasureLayer = v;
              this.applyConfig((c: SystemConfig): void => {
                c.showMeasureLayer = v;
              });
            },
          })
          SwitchRow({
            title: '坐标以米显示',
            subtitle: '开启后坐标按 CGCS2000 3 度带平面坐标（米）显示，关闭为十进制度',
            isOn: this.coordDisplayMeter,
            onSwitchChange: (v: boolean): void => {
              this.coordDisplayMeter = v;
              this.applyConfig((c: SystemConfig): void => {
                c.coordDisplayMeter = v;
              });
            },
          })
          SwitchRow({
            title: 'KML/KMZ 名称标注',
            subtitle: '开启后 KML/KMZ 图层显示要素名称标注',
            isOn: this.showKmlLabel,
            onSwitchChange: (v: boolean): void => {
              this.showKmlLabel = v;
              this.applyConfig((c: SystemConfig): void => {
                c.showKmlLabel = v;
              });
            },
          })
          // 3D 视图（球模式）：原主界面左上 2D/3D 切换键已取消，改由本开关控制系统配置；
          // 主界面 onPageShow 读回即时生效，无需重建地图
          SwitchRow({
            title: '3D 视图（球模式）',
            subtitle: '关闭为 2D 墨卡托（默认），开启后地图以 3D 球模式渲染',
            isOn: this.viewMode3d,
            onSwitchChange: (v: boolean): void => {
              this.viewMode3d = v;
              this.applyConfig((c: SystemConfig): void => {
                c.viewMode3d = v;
              });
            },
          })

          this.groupTitle('采集')
          SwitchRow({
            title: '照片坐标水印',
            subtitle: '拍照后在照片左下角写入经纬度与时间水印',
            isOn: this.photoAddWatermark,
            onSwitchChange: (v: boolean): void => {
              this.photoAddWatermark = v;
              this.applyConfig((c: SystemConfig): void => {
                c.photoAddWatermark = v;
              });
            },
          })
          SwitchRow({
            title: '后台定位',
            subtitle: '允许退到后台后继续采集定位（轨迹不中断）',
            isOn: this.backgroundLocation,
            onSwitchChange: (v: boolean): void => {
              this.backgroundLocation = v;
              this.applyConfig((c: SystemConfig): void => {
                c.backgroundLocation = v;
              });
            },
          })

          this.groupTitle('关于')
          this.entryRow('使用说明', '界面按键分布、本地图层与自定义地图源的添加步骤', (): void => {
            router.pushUrl({ url: 'pages/HelpPage' });
          })
          this.entryRow('关于', 'GDAL / PROJ 版本、本机版本号与检查更新', (): void => {
            router.pushUrl({ url: 'pages/AboutPage' });
          })
        }
        .width('100%')
        .padding({ left: Theme.PAD, right: Theme.PAD, top: Theme.GAP, bottom: Theme.PAD })
      }
      .layoutWeight(1)
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .padding({ bottom: this.bottomInset })
    .backgroundColor(Theme.BG)
  }

  @Builder
  groupTitle(text: string) {
    Text(text)
      .fontSize(Theme.FONT_SUB)
      .fontColor(Theme.TEXT_SUB)
      .width('100%')
      .margin({ top: 8, left: 2 })
  }

  @Builder
  entryRow(title: string, subtitle: string, onClick: () => void) {
    Row() {
      Column() {
        Text(title)
          .fontSize(Theme.FONT)
          .fontColor(Theme.TEXT)
        Text(subtitle)
          .fontSize(Theme.FONT_SUB)
          .fontColor(Theme.TEXT_SUB)
          .margin({ top: 2 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(18)
        .fontColor([Theme.TEXT_HINT])
    }
    .width('100%')
    .padding(12)
    .alignItems(VerticalAlign.Center)
    .backgroundColor(Theme.CARD)
    .borderRadius(Theme.RADIUS)
    .onClick((): void => {
      onClick();
    })
  }
}
