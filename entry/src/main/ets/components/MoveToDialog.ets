// MoveToDialog.ets —— 「移动到」坐标定位对话框（对应 Android ui.dialog.MoveToDialog）。
//
// 两组输入互斥：经纬度（十进制度）与地理坐标（CGCS2000 3 度带平面坐标，米）。
// 与 Android 同口径的三处细节：
//   1) 切到平面坐标页签或换带号时，用当前经纬度输入换算回填东/北坐标（输入非法则保留原值不报错）；
//   2) 确认后统一以 WGS84 经纬度回调，投影坐标先经 CoordTransform 反算；
//   3) 换算失败/数字非法只提示不关闭对话框。
// 带号候选取 CoordTransform.zoneNumbers()（25..45 全覆盖），比 Android 的 34..45 更宽，
// 因鸿蒙端投影换算走同一 native 管道，多给带号不改变正确性、便于西部经度作业。

import { CoordTransform, PlaneCoord } from '../common/Coord';
import { NumField } from './NumField';
import { Theme } from '../common/Theme';
import { Ui } from '../common/Ui';

/** 页签索引：0 经纬度 / 1 平面坐标（与 Android TAB_LATLON / TAB_GEO 对应） */
const TAB_LATLON: number = 0;
const TAB_GEO: number = 1;

@CustomDialog
export struct MoveToDialog {
  controller: CustomDialogController;
  /** 初值：宿主按「定位 > 相机中心 > 兜底默认」给出 */
  initLon: number = 0;
  initLat: number = 0;
  onConfirm: (lon: number, lat: number) => void = (): void => {};

  @State tab: number = TAB_LATLON;
  @State lonText: string = '';
  @State latText: string = '';
  @State easting: string = '';
  @State northing: string = '';
  @State crsIndex: number = 0;
  /** 坐标系下拉选项（带号 + 中央经线 + EPSG），构造一次复用 */
  private readonly crsNames: string[] = MoveToDialog.buildNames();

  private static buildNames(): string[] {
    const zones: number[] = CoordTransform.zoneNumbers();
    const names: string[] = [];
    for (let i = 0; i < zones.length; i++) {
      names.push(`CGCS2000 3度带 ${zones[i] * 3} (${CoordTransform.epsgOfZone(zones[i])})`);
    }
    return names;
  }

  aboutToAppear(): void {
    this.lonText = Ui.fixed(this.initLon, 6);
    this.latText = Ui.fixed(this.initLat, 6);
    // 默认带号按初值经度选中（现场最常用的就是当前所在带）
    const lon: number = Number.parseFloat(this.lonText);
    if (Number.isFinite(lon)) {
      const zone: number = CoordTransform.zoneOf(lon);
      const zones: number[] = CoordTransform.zoneNumbers();
      const idx: number = zones.indexOf(zone);
      if (idx >= 0) {
        this.crsIndex = idx;
      }
    }
  }

  private selectedCrs(): string {
    return CoordTransform.epsgOfZone(CoordTransform.zoneNumbers()[
      Math.min(this.crsIndex, CoordTransform.zoneNumbers().length - 1)]);
  }

  /** 经纬度输入 → 平面坐标回填；输入尚非合法数字时静默保留原值（用户正在输入） */
  private refreshGeoFields(): void {
    const lon: number = Number.parseFloat(this.lonText.trim());
    const lat: number = Number.parseFloat(this.latText.trim());
    if (!Number.isFinite(lon) || !Number.isFinite(lat)) {
      return;
    }
    const res: PlaneCoord | null = CoordTransform.convert(lon, lat,
      CoordTransform.CRS_WGS84, this.selectedCrs());
    if (res === null) {
      return;
    }
    this.easting = res.easting.toFixed(3);
    this.northing = res.northing.toFixed(3);
  }

  private confirm(): void {
    if (this.tab === TAB_GEO) {
      const e: number = Number.parseFloat(this.easting.trim());
      const n: number = Number.parseFloat(this.northing.trim());
      if (!Number.isFinite(e) || !Number.isFinite(n)) {
        Ui.toast('请输入有效的坐标数值');
        return;
      }
      const wgs: PlaneCoord | null = CoordTransform.convert(e, n, this.selectedCrs(),
        CoordTransform.CRS_WGS84);
      if (wgs === null) {
        Ui.toast('坐标转换失败，请检查输入');
        return;
      }
      this.onConfirm(wgs.easting, wgs.northing);
      this.controller.close();
      return;
    }
    const lon: number = Number.parseFloat(this.lonText.trim());
    const lat: number = Number.parseFloat(this.latText.trim());
    if (!Number.isFinite(lon) || !Number.isFinite(lat)) {
      Ui.toast('请输入有效的坐标数值');
      return;
    }
    this.onConfirm(lon, lat);
    this.controller.close();
  }

  build() {
    Column() {
      Text('移动到')
        .fontSize(Theme.FONT_TITLE)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.TEXT)
        .margin({ bottom: 10 })
      Row({ space: 8 }) {
        this.tabItem('经纬度', TAB_LATLON)
        this.tabItem('地理坐标', TAB_GEO)
      }
      .width('100%')
      .margin({ bottom: 12 })

      if (this.tab === TAB_LATLON) {
        NumField({
          label: '经度', placeholder: '116.391325', value: this.lonText,
          onValueChange: (v: string): void => {
            this.lonText = v;
          },
        })
        NumField({
          label: '纬度', placeholder: '39.907230', value: this.latText,
          onValueChange: (v: string): void => {
            this.latText = v;
          },
        })
      } else {
        Row() {
          Text('坐标系')
            .fontSize(Theme.FONT_SUB)
            .fontColor(Theme.TEXT_SUB)
            .width(56)
          Select(MoveToDialog.selectOptions(this.crsNames))
            .selected(this.crsIndex)
            .value(this.crsNames[Math.min(this.crsIndex, this.crsNames.length - 1)])
            .font({ size: Theme.FONT_SUB })
            .fontColor(Theme.TEXT)
            .layoutWeight(1)
            .onSelect((index: number): void => {
              this.crsIndex = index;
              this.refreshGeoFields();
            })
        }
        .width('100%')
        .margin({ bottom: 8 })
        NumField({
          label: '东坐标', value: this.easting,
          onValueChange: (v: string): void => {
            this.easting = v;
          },
        })
        NumField({
          label: '北坐标', value: this.northing,
          onValueChange: (v: string): void => {
            this.northing = v;
          },
        })
      }

      Row({ space: 10 }) {
        Button('取消')
          .layoutWeight(1)
          .height(38)
          .fontSize(Theme.FONT)
          .fontColor(Theme.TEXT_SUB)
          .backgroundColor(Theme.SUBTLE)
          .onClick((): void => {
            this.controller.close();
          })
        Button('确定')
          .layoutWeight(1)
          .height(38)
          .fontSize(Theme.FONT)
          .fontColor(Theme.TEXT_ON_DARK)
          .backgroundColor(Theme.PRIMARY)
          .onClick((): void => {
            this.confirm();
          })
      }
      .width('100%')
      .margin({ top: 14 })
    }
    .width('100%')
    .padding(Theme.PAD)
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(Theme.CARD)
    .borderRadius(Theme.RADIUS)
  }

  @Builder
  tabItem(label: string, index: number) {
    Text(label)
      .fontSize(Theme.FONT)
      .fontColor(this.tab === index ? Theme.TEXT_ON_DARK : Theme.TEXT_SUB)
      .backgroundColor(this.tab === index ? Theme.PRIMARY : Theme.SUBTLE)
      .padding({ left: 18, right: 18, top: 6, bottom: 6 })
      .borderRadius(16)
      .onClick((): void => {
        this.tab = index;
        if (index === TAB_GEO) {
          this.refreshGeoFields();
        }
      })
  }

  private static selectOptions(names: string[]): SelectOption[] {
    const out: SelectOption[] = [];
    for (let i = 0; i < names.length; i++) {
      const item: SelectOption = { value: names[i] };
      out.push(item);
    }
    return out;
  }
}
