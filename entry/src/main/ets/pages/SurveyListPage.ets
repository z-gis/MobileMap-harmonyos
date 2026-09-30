// SurveyListPage.ets —— 图斑的样地列表与调查入口（对应 Android FeaturePickController.showSurveyEntryDialog）。
//
// Android 用单选列表对话框承载，但鸿蒙侧 loadPlots 是全异步、且列表项数不受 Ui.items 的 6 项限制，
// 故独立成页：进入即完成「定位门控 → 环内提示 → 查已有样地」，无样地时直接替换为录入页（等价 Android 的直接新建）。
// 入口上下文（属性表 + 图斑外环）含 Map，经 PageData 交接；路径与 FID 走 router params。

import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { GeoCalc, LatLng } from '../common/GeoCalc';
import { PageData, PageKeys } from '../common/PageData';
import { Theme } from '../common/Theme';
import { TimeText } from '../common/TimeText';
import { Ui } from '../common/Ui';
import { LocationManager, LocationPoint } from '../location/LocationManager';
import { SampleSurveyStore } from '../survey/SampleSurveyStore';
import { SurveyPlot } from '../survey/SurveyModels';
import { TitleBar } from '../components/TitleBar';
import { SurveyEditParams, SurveyEntryContext, SurveyListParams } from './RouteParams';

/** 小班号候选字段名（与 Android 顺序一致，首个命中即取） */
const COMPARTMENT_FIELDS: string[] = ['小班号', 'XBH', '小班'];
const DEFAULT_COMPARTMENT: string = '未命名小班';

@Entry
@Component
struct SurveyListPage {
  /** 底部导航条避让高度（vp）：主窗口是全屏布局，底部「新建样地调查」按钮要让开导航条 */
  @StorageProp('bottomInsetVp') bottomInset: number = 0;
  @State plots: SurveyPlot[] = [];
  @State loaded: boolean = false;
  @State compartmentNo: string = DEFAULT_COMPARTMENT;
  /** 定位点：进入时快照，供列表副标题与新建样地的中心坐标使用 */
  private lat: number = Number.NaN;
  private lon: number = Number.NaN;
  private sourcePath: string = '';
  private sourceFid: number = -1;
  /** 首次加载才自动转新建（删除掉最后一个样地后回到空列表不弹录入页） */
  private firstLoad: boolean = true;

  aboutToAppear(): void {
    const params: SurveyListParams | undefined = SurveyListPage.readParams();
    if (params !== undefined) {
      this.sourcePath = params.sourcePath;
      this.sourceFid = params.sourceFid;
    }
    const ctx: SurveyEntryContext | undefined = SurveyListPage.readContext();
    if (ctx !== undefined) {
      this.compartmentNo = SurveyListPage.compartmentOf(ctx.attributes);
      this.checkInside(ctx.outerRing);
    }
    const loc: LocationPoint | null = LocationManager.getInstance().getLastLocation();
    if (loc === null) {
      // 与 Android 同口径：无定位不给进（样地中心坐标无从取得）
      Ui.toast('未定位，无法开始样地调查');
      router.back();
      return;
    }
    this.lat = loc.latitude;
    this.lon = loc.longitude;
    this.reload();
  }

  onPageShow(): void {
    // 从录入页返回时刷新列表（保存/删除都可能改变条数与摘要）；首帧由 aboutToAppear 驱动
    if (this.loaded && !this.firstLoad) {
      this.reload();
    }
  }

  aboutToDisappear(): void {
    PageData.clear(PageKeys.SURVEY_ENTRY);
  }

  private static readParams(): SurveyListParams | undefined {
    const raw: Object = router.getParams();
    if (raw === undefined || raw === null) {
      return undefined;
    }
    return raw as SurveyListParams;
  }

  private static readContext(): SurveyEntryContext | undefined {
    const raw: Object | undefined = PageData.peek(PageKeys.SURVEY_ENTRY);
    if (raw === undefined) {
      return undefined;
    }
    return raw as SurveyEntryContext;
  }

  /** 属性表 → 小班号：Map 取值需按候选键顺序试探，全未命中回退默认名 */
  private static compartmentOf(attrs: Map<string, string> | null): string {
    if (attrs === null) {
      return DEFAULT_COMPARTMENT;
    }
    for (let i = 0; i < COMPARTMENT_FIELDS.length; i++) {
      const value: string | undefined = attrs.get(COMPARTMENT_FIELDS[i]);
      if (value !== undefined && value.trim().length > 0) {
        return value.trim();
      }
    }
    return DEFAULT_COMPARTMENT;
  }

  /** 定位点是否在图斑外环内：不在则长提示但仍允许继续（外业常在边界附近开始调查） */
  private checkInside(outerRing: number[][]): void {
    if (outerRing.length < 3) {
      return;
    }
    const loc: LocationPoint | null = LocationManager.getInstance().getLastLocation();
    if (loc === null) {
      return;
    }
    const ring: LatLng[] = [];
    for (let i = 0; i < outerRing.length; i++) {
      ring.push(new LatLng(outerRing[i][0], outerRing[i][1]));
    }
    if (!GeoCalc.containsPoint(ring, loc.latitude, loc.longitude)) {
      Ui.toastLong('当前坐标不在当前小班内');
    }
  }

  private reload(): void {
    const ctx: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    SampleSurveyStore.getInstance(ctx).then(async (store: SampleSurveyStore): Promise<void> => {
      const plots: SurveyPlot[] = await store.loadPlots(this.sourcePath, this.sourceFid);
      this.plots = plots;
      this.loaded = true;
      if (plots.length === 0 && this.firstLoad) {
        // 无任何样地：不进空列表页，直接替为录入页（返回键回到要素详情，与 Android 一致）
        this.toEdit(-1);
      }
      this.firstLoad = false;
    });
  }

  private toEdit(plotId: number): void {
    const p: SurveyEditParams = new SurveyEditParams();
    p.sourcePath = this.sourcePath;
    p.sourceFid = this.sourceFid;
    p.compartmentNo = this.compartmentNo;
    p.centerLat = this.lat;
    p.centerLon = this.lon;
    p.plotId = plotId;
    if (plotId > 0) {
      router.pushUrl({ url: 'pages/SurveyEditPage', params: p });
    } else {
      router.replaceUrl({ url: 'pages/SurveyEditPage', params: p });
    }
  }

  private async removePlot(plot: SurveyPlot): Promise<void> {
    const ok: boolean = await Ui.confirm('删除样地', `确定删除「${plot.title()}」及其全部调查明细？`, '删除');
    if (!ok) {
      return;
    }
    const ctx: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const store: SampleSurveyStore = await SampleSurveyStore.getInstance(ctx);
    const done: boolean = await store.deletePlot(plot.id);
    Ui.toast(done ? '已删除' : '删除失败');
    if (done) {
      this.reload();
    }
  }

  build() {
    Column() {
      TitleBar({
        title: '样地调查',
        subtitle: `${this.compartmentNo}　${Ui.fixed(this.lon, 6)}, ${Ui.fixed(this.lat, 6)}`,
      })
      if (!this.loaded) {
        Column() {
          LoadingProgress().width(36).height(36).color(Theme.PRIMARY)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: Theme.GAP }) {
          ForEach(this.plots, (plot: SurveyPlot): void => {
            ListItem() {
              this.plotCard(plot)
            }
            .onClick((): void => {
              this.toEdit(plot.id);
            })
            .gesture(LongPressGesture().onAction((): void => {
              this.removePlot(plot);
            }))
          }, (plot: SurveyPlot): string => `${plot.id}`)
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .padding({ left: Theme.PAD, right: Theme.PAD, top: Theme.GAP })
      }
      Button('新建样地调查')
        .width('100%')
        .height(44)
        .fontSize(Theme.FONT)
        .fontColor(Theme.TEXT_ON_DARK)
        .backgroundColor(Theme.PRIMARY)
        .borderRadius(Theme.RADIUS)
        .margin({ left: Theme.PAD, right: Theme.PAD, top: Theme.GAP, bottom: Theme.PAD })
    }
    .width('100%')
    .height('100%')
    .padding({ bottom: this.bottomInset })
    .backgroundColor(Theme.BG)
  }

  @Builder
  plotCard(plot: SurveyPlot) {
    Column() {
      Row() {
        Text(plot.title())
          .fontSize(Theme.FONT)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.TEXT)
        Blank()
        Text(`第 ${plot.plotNo} 号`)
          .fontSize(Theme.FONT_SUB)
          .fontColor(Theme.TEXT_SUB)
      }
      .width('100%')

      Text(SurveyListPage.summaryOf(plot))
        .fontSize(Theme.FONT_SUB)
        .fontColor(Theme.TEXT_SUB)
        .width('100%')
        .margin({ top: 4 })
    }
    .width('100%')
    .padding(12)
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(Theme.CARD)
    .borderRadius(Theme.RADIUS)
  }

  /** 列表副标题：树高 / 郁闭度 / 明细数 / 更新时间（缺项省略，与录入页字段同序） */
  private static summaryOf(plot: SurveyPlot): string {
    const parts: string[] = [];
    if (plot.averageTreeHeight.trim().length > 0) {
      parts.push(`树高 ${plot.averageTreeHeight}`);
    }
    if (!Number.isNaN(plot.canopyDensity)) {
      parts.push(`郁闭度 ${Ui.num(plot.canopyDensity, 2)}`);
    }
    parts.push(`${plot.rows.length} 条明细`);
    parts.push(`更新 ${TimeText.dateTime(plot.updatedAt)}`);
    return parts.join('　');
  }
}
