// LocationDetailDialog.ets —— 定位详情对话框（对应 Android ui.dialog.LocationDetailDialog + dialog_location_detail.xml）。
//
// 主界面底部「定位坐标文本」点击后弹出：当前位置 / 海拔 / 定位精度 / 速度 / 方位角 / 卫星 / 数据源 / 定位时间
// 八行文本，分隔线下接「后台定位」开关（与设置页同源、改动即刻落盘），底部「复制坐标」与「确定」。
// 数据在打开瞬间取 LocationManager 的最近定位与卫星快照，对话框存活期间不随新定位刷新（与 Android 一致）。
//
// 与 Android 的平台差异（只是信息量不同，交互一致）：
//  · 卫星：鸿蒙只有 satelliteStatusChange 的「可见卫星数 + 载噪比数组」，没有 GnssStatus 的 usedInFix 逐星标志，
//    故显示「可见 N，平均信噪比 X dB·Hz」，不报「参与定位」；
//  · 数据源：Android 取 Location.provider 字符串，鸿蒙取 LocationSourceType 枚举（映射见 LocationManager.sourceTypeName）；
//  · 「无该项信息」判定：Android 用 hasAltitude()/hasAccuracy() 等，鸿蒙侧已由 LocationManager 归一为 NaN / 负值。

import { pasteboard } from '@kit.BasicServicesKit';
import { CoordFormatter } from '../common/Coord';
import { AppLog } from '../common/AppLog';
import { Theme } from '../common/Theme';
import { TimeText } from '../common/TimeText';
import { Ui } from '../common/Ui';
import { MapDocument, SystemConfig } from '../doc/DocModels';
import { DocumentManager } from '../doc/DocumentManager';
import { LocationManager, LocationPoint, SatelliteInfo } from '../location/LocationManager';

/** 无信息占位符（Android LocationDetailDialog.NONE 同值） */
const NONE: string = '—';
/** 无定位时坐标行的提示文本（Android location_detail_no_loc） */
const NO_LOCATION: string = '尚未获取到定位信息';
/** 正文行距（Android 每行 TextView 上下 padding 6dp） */
const ROW_PADDING_V: number = 6;

@CustomDialog
export struct LocationDetailDialog {
  controller: CustomDialogController;

  /** 打开瞬间的定位快照：null 表示尚未定位，此时不出「复制坐标」键 */
  private loc: LocationPoint | null = null;
  // 八行文本在 aboutToAppear 一次性算好（build 只负责排版，不参与格式化判断）
  private coordText: string = '';
  private altText: string = '';
  private accText: string = '';
  private speedText: string = '';
  private bearingText: string = '';
  private satText: string = '';
  private providerText: string = '';
  private timeText: string = '';
  /** 后台定位开关态：与 SystemConfig.backgroundLocation 双向绑定 */
  @State bgLocation: boolean = false;

  aboutToAppear(): void {
    const lm: LocationManager = LocationManager.getInstance();
    const loc: LocationPoint | null = lm.getLastLocation();
    this.loc = loc;
    // 坐标行沿用底栏同一格式化入口（随「坐标以米显示」在十进制度/米之间切换），Android 同口径
    this.coordText = loc === null ? NO_LOCATION
      : CoordFormatter.format('当前位置', loc.longitude, loc.latitude);
    this.altText = `海拔：${LocationDetailDialog.altValue(loc)}`;
    this.accText = `定位精度：${LocationDetailDialog.accValue(loc)}`;
    this.speedText = `速度：${LocationDetailDialog.speedValue(loc)}`;
    this.bearingText = `方位角：${LocationDetailDialog.bearingValue(loc)}`;
    this.satText = `卫星：${LocationDetailDialog.satValue(lm.getSatelliteInfo())}`;
    this.providerText = `数据源：${LocationDetailDialog.providerValue(loc)}`;
    this.timeText = `定位时间：${LocationDetailDialog.timeValue(loc)}`;
    this.bgLocation = DocumentManager.getInstance().getConfig().backgroundLocation;
  }

  /** 海拔：NaN 表示定位无高程信息（部分芯片/室内定位不给高程），不显示不可信值 */
  private static altValue(loc: LocationPoint | null): string {
    if (loc === null || Number.isNaN(loc.altitude)) {
      return NONE;
    }
    return `${loc.altitude.toFixed(1)} 米`;
  }

  /** 水平精度：Android 用 hasAccuracy()，鸿蒙以 accuracy<=0 当无信息 */
  private static accValue(loc: LocationPoint | null): string {
    if (loc === null || !(loc.accuracy > 0)) {
      return NONE;
    }
    return `±${loc.accuracy.toFixed(1)} 米`;
  }

  /** 瞬时速度：米/秒为主、括注 km/h（外业判断步行/车行） */
  private static speedValue(loc: LocationPoint | null): string {
    if (loc === null || Number.isNaN(loc.speed)) {
      return NONE;
    }
    return `${loc.speed.toFixed(1)} 米/秒（${(loc.speed * 3.6).toFixed(1)} km/h）`;
  }

  private static bearingValue(loc: LocationPoint | null): string {
    if (loc === null || Number.isNaN(loc.direction)) {
      return NONE;
    }
    return `${loc.direction.toFixed(0)}°`;
  }

  /** 卫星：鸿蒙只有可见数与载噪比均值（无「参与定位」计数），两者都缺时给占位符 */
  private static satValue(sat: SatelliteInfo | null): string {
    if (sat === null || (sat.visible === 0 && Number.isNaN(sat.avgCn0DbHz))) {
      return NONE;
    }
    const cn0: string = Number.isNaN(sat.avgCn0DbHz) ? NONE : `${sat.avgCn0DbHz.toFixed(0)} dB·Hz`;
    return `可见 ${sat.visible}，平均信噪比 ${cn0}`;
  }

  private static providerValue(loc: LocationPoint | null): string {
    if (loc === null) {
      return NONE;
    }
    const name: string = LocationManager.sourceTypeName(loc.sourceType);
    return name.length === 0 ? NONE : name;
  }

  private static timeValue(loc: LocationPoint | null): string {
    if (loc === null || loc.time <= 0) {
      return NONE;
    }
    return TimeText.dateTimeSec(loc.time);
  }

  /** 后台定位开关：写文档即刻落盘（非结构变更，不触发地图重建），与设置页同一写通道 */
  private onBgLocationChange(v: boolean): void {
    this.bgLocation = v;
    DocumentManager.getInstance().update((doc: MapDocument): void => {
      const config: SystemConfig = doc.systemConfig;
      config.backgroundLocation = v;
    });
  }

  /** 复制 WGS84 经纬度（十进制度 6 位小数，经度在前）到系统剪贴板 */
  private copyCoordinate(): void {
    const loc: LocationPoint | null = this.loc;
    if (loc === null) {
      return;
    }
    const text: string = `${loc.longitude.toFixed(6)},${loc.latitude.toFixed(6)}`;
    try {
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      pasteboard.getSystemPasteboard().setData(data).then((): void => {
        Ui.toast('坐标已复制');
      }, (e: Error): void => {
        AppLog.e('写剪贴板失败', `${e}`);
        Ui.toast('复制失败');
      });
    } catch (e) {
      AppLog.e('写剪贴板失败', `${e}`);
      Ui.toast('复制失败');
    }
  }

  build() {
    Column() {
      Text('定位详情')
        .fontSize(Theme.FONT_TITLE)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.TEXT)
        .width('100%')
        .margin({ bottom: 6 })
      // 内容区可滚动：小屏/横屏下八行 + 开关足以超高，按钮区固定在下方不被顶走
      Scroll() {
        Column() {
          this.row(this.coordText)
          this.row(this.altText)
          this.row(this.accText)
          this.row(this.speedText)
          this.row(this.bearingText)
          this.row(this.satText)
          this.row(this.providerText)
          this.row(this.timeText)
          Divider()
            .color(Theme.DIVIDER)
            .margin({ top: ROW_PADDING_V, bottom: ROW_PADDING_V })
          Row() {
            Text('后台定位')
              .fontSize(Theme.FONT)
              .fontColor(Theme.TEXT)
              .layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.bgLocation })
              .selectedColor(Theme.PRIMARY)
              .onChange((v: boolean): void => {
                if (v !== this.bgLocation) {
                  this.onBgLocationChange(v);
                }
              })
          }
          .width('100%')
          .padding({ top: 8, bottom: 8 })
          .alignItems(VerticalAlign.Center)
        }
        .width('100%')
      }
      .width('100%')
      .constraintSize({ maxHeight: 300 })
      .align(Alignment.Top)
      .scrollBar(BarState.Off)

      Row({ space: 10 }) {
        // 无定位时不提供复制（Android 只在 loc != null 时才挂 neutral 按钮）
        if (this.loc !== null) {
          Button('复制坐标')
            .layoutWeight(1)
            .height(38)
            .fontSize(Theme.FONT)
            .fontColor(Theme.PRIMARY_DARK)
            .backgroundColor(Theme.SUBTLE)
            .onClick((): void => {
              this.copyCoordinate();
            })
        }
        Button('确定')
          .layoutWeight(1)
          .height(38)
          .fontSize(Theme.FONT)
          .fontColor(Theme.TEXT_ON_DARK)
          .backgroundColor(Theme.PRIMARY)
          .onClick((): void => {
            this.controller.close();
          })
      }
      .width('100%')
      .margin({ top: 10 })
    }
    .width('100%')
    .padding(Theme.PAD)
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(Theme.CARD)
    .borderRadius(Theme.RADIUS)
  }

  /** 单行信息文本（Android dialog_location_detail.xml 里每行一个 TextView，整行文本代码回填） */
  @Builder
  row(text: string) {
    Text(text)
      .fontSize(Theme.FONT)
      .fontColor(Theme.TEXT)
      .width('100%')
      .padding({ top: ROW_PADDING_V, bottom: ROW_PADDING_V })
  }
}
