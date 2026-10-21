// SurveyEditPage.ets —— 样地调查录入页（对应 Android survey/SampleSurveyActivity）。
//
// 与 Android 的结构差异：ListView + BaseAdapter 手工同步（syncRowsFromViews）在 ArkUI 不需要 ——
// 明细行直接 ForEach 到 List，控件值改动即时写回 SurveyRow 模型，保存时整体落库。
// 口径保持一致的三处：
//   1) plotId>0 走 ProjectManager.findSurveyPlot，否则新建本地草稿（编号占位、不入库）；
//   2) GPS 行优先取实时定位，且仅在草稿中心为 NaN 时回填（已有记录不覆盖历史中心）；
//   3) 删除明细行后重排序号。
// 角点坐标 cornerCoordinates 与 Android 同样保留为空串（该字段由四角仪手工录入的业务另做处理，界面无输入项）。

import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { Theme } from '../common/Theme';
import { Ui } from '../common/Ui';
import { LocationChangedListener, LocationManager, LocationPoint } from '../location/LocationManager';
import { SampleSurveyConfig } from '../survey/SurveyModels';
import { ProjectManager } from '../project/ProjectManager';
import { SurveyPlot, SurveyRow } from '../project/ProjectModels';
import { TitleBar } from '../components/TitleBar';
import { SurveyEditParams } from './RouteParams';

/**
 * 新增行的界面标识递减负数（与已入库行的正数 id 天然区分）。
 * ProjectModels.SurveyRow 无 uid 字段：ForEach 键由页内与 rows 平行的 rowKeys 数组承载。
 */
const NEW_ROW_UID_START: number = -1;
/** 郁闭度合法区间（超出仅提示不强改，允许现场录入习惯差异） */
const DENSITY_MAX: number = 1.0;

@Entry
@Component
struct SurveyEditPage {
  /** 底部导航条避让高度（vp）：主窗口是全屏布局，表单末尾要让开导航条 */
  @StorageProp('bottomInsetVp') bottomInset: number = 0;
  @State plotNo: number = 1;
  @State compartmentNo: string = '未命名小班';
  @State gpsText: string = '-';
  @State treeHeight: string = '';
  @State canopyDensity: string = '';
  @State rows: SurveyRow[] = [];
  @State saving: boolean = false;
  /** 当前样地（草稿或已存在），保存后回填 id */
  private plot: SurveyPlot | undefined = undefined;
  private sourcePath: string = '';
  private sourceFid: number = -1;
  private centerLat: number = Number.NaN;
  private centerLon: number = Number.NaN;
  private plotId: number = -1;
  private newRowUid: number = NEW_ROW_UID_START;
  /** 与 rows 平行的 ForEach 键（已入库行用正 id，新增行用递减负数） */
  private rowKeys: number[] = [];
  private readonly onLocation: LocationChangedListener = (loc: LocationPoint): void => {
    this.applyLocation(loc);
  };

  aboutToAppear(): void {
    const raw: Object = router.getParams();
    if (raw !== undefined && raw !== null) {
      const p: SurveyEditParams = raw as SurveyEditParams;
      this.sourcePath = p.sourcePath;
      this.sourceFid = p.sourceFid;
      this.compartmentNo = p.compartmentNo.trim().length > 0 ? p.compartmentNo.trim() : '未命名小班';
      this.centerLat = p.centerLat;
      this.centerLon = p.centerLon;
      this.plotId = p.plotId;
    }
    this.loadPlot();
    // 实时定位优先于跳转时传入的中心：进页后继续走到样地中心也能拿到准确坐标
    LocationManager.getInstance().addLocationListener(this.onLocation);
    this.applyLocation(LocationManager.getInstance().getLastLocation());
  }

  aboutToDisappear(): void {
    LocationManager.getInstance().removeLocationListener(this.onLocation);
  }

  private context(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  private loadPlot(): void {
    const pm: ProjectManager = ProjectManager.get(this.context());
    let plot: SurveyPlot | null = null;
    if (this.plotId > 0) {
      plot = pm.findSurveyPlot(this.plotId);
    }
    if (plot === null) {
      // 新建本地草稿（对齐 Android：未持久化 id=0，编号取同小班内下一个，保存时才入库）
      const draft: SurveyPlot = new SurveyPlot();
      draft.sourcePath = this.sourcePath.trim();
      draft.sourceFid = this.sourceFid;
      draft.compartmentNo = this.compartmentNo.trim();
      draft.plotNo = pm.nextSurveyPlotNo(this.sourcePath, this.sourceFid);
      draft.cornerCoordinates = '';
      const now: number = Date.now();
      draft.createdAt = now;
      draft.updatedAt = now;
      if (Number.isFinite(this.centerLat) && Number.isFinite(this.centerLon)) {
        draft.setCenter(this.centerLat, this.centerLon);
      }
      plot = draft;
    }
    this.plot = plot;
    this.plotNo = plot.plotNo;
    this.treeHeight = plot.averageTreeHeight;
    this.canopyDensity = Number.isNaN(plot.canopyDensity) ? '' : Ui.num(plot.canopyDensity, 2);
    this.rows = plot.rows;
    // ForEach 键初始化：已入库行用正 id，无 id 行用递减负数
    this.rowKeys = [];
    for (let i = 0; i < this.rows.length; i++) {
      const key: number = this.rows[i].id > 0 ? this.rows[i].id : this.newRowUid;
      if (this.rows[i].id <= 0) {
        this.newRowUid -= 1;
      }
      this.rowKeys.push(key);
    }
    this.applyLocation(LocationManager.getInstance().getLastLocation());
  }

  /** 定位 → GPS 行文本 + 草稿中心回填（仅当中心未知时，已有记录保留历史中心） */
  private applyLocation(loc: LocationPoint | null): void {
    if (loc !== null) {
      this.gpsText = `${Ui.fixed(loc.longitude, 6)}, ${Ui.fixed(loc.latitude, 6)}`;
      const plot: SurveyPlot | undefined = this.plot;
      if (plot !== undefined && (Number.isNaN(plot.centerLatitude) || Number.isNaN(plot.centerLongitude))) {
        // centerLatitude/centerLongitude 为只读 getter，回填统一走 setCenter
        plot.setCenter(loc.latitude, loc.longitude);
      }
      return;
    }
    if (Number.isFinite(this.centerLat) && Number.isFinite(this.centerLon)) {
      this.gpsText = `${Ui.fixed(this.centerLon, 6)}, ${Ui.fixed(this.centerLat, 6)}`;
    }
  }

  private addRow(): void {
    const row: SurveyRow = new SurveyRow();
    row.sortNo = this.rows.length;
    row.treeSpecies = SampleSurveyConfig.TREE_SPECIES[0];
    row.category = SampleSurveyConfig.CATEGORIES[0];
    row.thinningMethod = SampleSurveyConfig.THINNING_METHODS[0];
    this.rowKeys.push(this.newRowUid);
    this.newRowUid -= 1;
    // 重新赋值数组触发 ForEach 增量渲染（行内字段改动无需渲染，控件自持文本态）
    this.rows = this.rows.concat([row]);
  }

  private removeRow(index: number): void {
    if (index < 0 || index >= this.rows.length) {
      return;
    }
    const next: SurveyRow[] = this.rows.slice();
    next.splice(index, 1);
    this.rowKeys.splice(index, 1);
    // 删行后序号连续（与 Android rows.forEachIndexed { idx, r -> r.sortNo = idx + 1 } 同口径）
    for (let i = 0; i < next.length; i++) {
      next[i].sortNo = i;
    }
    this.rows = next;
  }

  private async save(): Promise<void> {
    const plot: SurveyPlot | undefined = this.plot;
    if (plot === undefined || this.saving) {
      return;
    }
    plot.averageTreeHeight = this.treeHeight.trim();
    const density: number = Number.parseFloat(this.canopyDensity.trim());
    plot.canopyDensity = Number.isNaN(density) ? Number.NaN : density;
    if (!Number.isNaN(density) && (density < 0 || density > DENSITY_MAX)) {
      Ui.toastLong(`郁闭度通常在 0~${DENSITY_MAX} 之间，已按 ${Ui.num(density, 2)} 保存`);
    }
    this.saving = true;
    // 明细行全量替换后整体保存（对齐 Android saveSurvey 语义）
    plot.rows = this.rows;
    const saved: SurveyPlot | null = await ProjectManager.get(this.context()).saveSurveyPlot(plot);
    this.saving = false;
    if (saved === null) {
      Ui.toast('保存失败');
      return;
    }
    this.plot = saved;
    Ui.toast('样地调查已保存');
    router.back();
  }

  build() {
    Column() {
      TitleBar({
        title: '样地调查',
        subtitle: this.compartmentNo,
        // 箭头函数包裹传入：直传 this.saveAction 会丢失宿主 this 绑定，点「保存」时
        // 槽内 this 指向 TitleBar，this.save()/this.saving 就成 undefined
        actions: (): void => {
          this.saveAction();
        },
      })
      Scroll() {
        Column({ space: Theme.GAP }) {
          this.infoCard()
          this.rowHeader()
          ForEach(this.rows, (row: SurveyRow, index: number): void => {
            this.rowCard(row, index)
          }, (row: SurveyRow, index: number): string => `${this.rowKeys[index]}`)
          Button('+ 添加一行')
            .width('100%')
            .height(40)
            .fontSize(Theme.FONT)
            .fontColor(Theme.PRIMARY_DARK)
            .backgroundColor(Theme.CARD)
            .borderRadius(Theme.RADIUS)
            .borderWidth(1)
            .borderColor(Theme.DIVIDER)
            .onClick((): void => {
              this.addRow();
            })
        }
        .width('100%')
        .padding(Theme.PAD)
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .padding({ bottom: this.bottomInset })
    .backgroundColor(Theme.BG)
  }

  @Builder
  saveAction() {
    Button(this.saving ? '保存中' : '保存')
      .height(32)
      .fontSize(Theme.FONT_SUB)
      .fontColor(Theme.TEXT_ON_DARK)
      .backgroundColor(Theme.PRIMARY)
      .borderRadius(16)
      .padding({ left: 16, right: 16 })
      .enabled(!this.saving)
      .onClick((): void => {
        this.save();
      })
  }

  @Builder
  infoCard() {
    Column({ space: 6 }) {
      Row() {
        Text('样地')
          .fontSize(Theme.FONT_SUB)
          .fontColor(Theme.TEXT_SUB)
          .width(56)
        Text(`第 ${this.plotNo} 号样地`)
          .fontSize(Theme.FONT)
          .fontColor(Theme.TEXT)
      }
      .width('100%')

      Row() {
        Text('GPS')
          .fontSize(Theme.FONT_SUB)
          .fontColor(Theme.TEXT_SUB)
          .width(56)
        Text(this.gpsText)
          .fontSize(Theme.FONT_SUB)
          .fontColor(Theme.TEXT_SUB)
      }
      .width('100%')

      Row() {
        Text('树高')
          .fontSize(Theme.FONT_SUB)
          .fontColor(Theme.TEXT_SUB)
          .width(56)
        TextInput({ text: this.treeHeight, placeholder: '平均树高（m），可填区间' })
          .layoutWeight(1)
          .fontSize(Theme.FONT)
          .backgroundColor(Theme.SUBTLE)
          .height(36)
          .onChange((v: string): void => {
            this.treeHeight = v;
          })
      }
      .width('100%')

      Row() {
        Text('郁闭度')
          .fontSize(Theme.FONT_SUB)
          .fontColor(Theme.TEXT_SUB)
          .width(56)
        TextInput({ text: this.canopyDensity, placeholder: '0~1' })
          .layoutWeight(1)
          .type(InputType.NUMBER_DECIMAL)
          .fontSize(Theme.FONT)
          .backgroundColor(Theme.SUBTLE)
          .height(36)
          .onChange((v: string): void => {
            this.canopyDensity = v;
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding(12)
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(Theme.CARD)
    .borderRadius(Theme.RADIUS)
  }

  @Builder
  rowHeader() {
    Row() {
      Text(SampleSurveyConfig.ROW_COLUMNS[0])
        .layoutWeight(2)
        .fontSize(Theme.FONT_SUB)
        .fontColor(Theme.TEXT_SUB)
      Text(SampleSurveyConfig.ROW_COLUMNS[1])
        .layoutWeight(1)
        .fontSize(Theme.FONT_SUB)
        .fontColor(Theme.TEXT_SUB)
      Text(SampleSurveyConfig.ROW_COLUMNS[2])
        .layoutWeight(2)
        .fontSize(Theme.FONT_SUB)
        .fontColor(Theme.TEXT_SUB)
      Text(SampleSurveyConfig.ROW_COLUMNS[3])
        .layoutWeight(2)
        .fontSize(Theme.FONT_SUB)
        .fontColor(Theme.TEXT_SUB)
      Text(SampleSurveyConfig.ROW_COLUMNS[4])
        .layoutWeight(2)
        .fontSize(Theme.FONT_SUB)
        .fontColor(Theme.TEXT_SUB)
      Text('')
        .width(28)
    }
    .width('100%')
    .padding({ left: Theme.PAD, right: Theme.PAD, top: 6, bottom: 2 })
  }

  @Builder
  rowCard(row: SurveyRow, index: number) {
    Row({ space: 4 }) {
      Text(`${index + 1}`)
        .width(18)
        .fontSize(Theme.FONT_SUB)
        .fontColor(Theme.TEXT_SUB)
        .textAlign(TextAlign.Center)
      Select(SurveyEditPage.options(SampleSurveyConfig.TREE_SPECIES))
        .selected(SurveyEditPage.indexOfOption(SampleSurveyConfig.TREE_SPECIES, row.treeSpecies))
        .value(row.treeSpecies.length > 0 ? row.treeSpecies : SampleSurveyConfig.TREE_SPECIES[0])
        .font({ size: Theme.FONT_SUB })
        .fontColor(Theme.TEXT)
        .selectedOptionFont({ size: Theme.FONT_SUB })
        .layoutWeight(2)
        .onSelect((i: number, value: string): void => {
          row.treeSpecies = value;
        })
      TextInput({ text: row.dbh, placeholder: 'cm' })
        .layoutWeight(1)
        .fontSize(Theme.FONT_SUB)
        .type(InputType.NUMBER_DECIMAL)
        .backgroundColor(Theme.SUBTLE)
        .padding({ left: 6, right: 6 })
        .height(36)
        .onChange((v: string): void => {
          row.dbh = v;
        })
      Select(SurveyEditPage.options(SampleSurveyConfig.CATEGORIES))
        .selected(SurveyEditPage.indexOfOption(SampleSurveyConfig.CATEGORIES, row.category))
        .value(row.category.length > 0 ? row.category : SampleSurveyConfig.CATEGORIES[0])
        .font({ size: Theme.FONT_SUB })
        .fontColor(Theme.TEXT)
        .selectedOptionFont({ size: Theme.FONT_SUB })
        .layoutWeight(2)
        .onSelect((i: number, value: string): void => {
          row.category = value;
        })
      Select(SurveyEditPage.options(SampleSurveyConfig.THINNING_METHODS))
        .selected(SurveyEditPage.indexOfOption(SampleSurveyConfig.THINNING_METHODS, row.thinningMethod))
        .value(row.thinningMethod.length > 0 ? row.thinningMethod : SampleSurveyConfig.THINNING_METHODS[0])
        .font({ size: Theme.FONT_SUB })
        .fontColor(Theme.TEXT)
        .selectedOptionFont({ size: Theme.FONT_SUB })
        .layoutWeight(2)
        .onSelect((i: number, value: string): void => {
          row.thinningMethod = value;
        })
      TextInput({ text: row.remark, placeholder: '备注' })
        .layoutWeight(2)
        .fontSize(Theme.FONT_SUB)
        .backgroundColor(Theme.SUBTLE)
        .padding({ left: 6, right: 6 })
        .height(36)
        .onChange((v: string): void => {
          row.remark = v;
        })
      SymbolGlyph($r('sys.symbol.trash'))
        .fontSize(18)
        .fontColor([Theme.DANGER])
        .width(28)
        .onClick((): void => {
          this.removeRow(index);
        })
    }
    .width('100%')
    .padding(8)
    .alignItems(VerticalAlign.Center)
    .backgroundColor(Theme.CARD)
    .borderRadius(Theme.RADIUS)
  }

  /** string[] → Select 需要的选项数组（ArkTS 不接受裸字符串列表） */
  private static options(list: string[]): SelectOption[] {
    const out: SelectOption[] = [];
    for (let i = 0; i < list.length; i++) {
      const item: SelectOption = { value: list[i] };
      out.push(item);
    }
    return out;
  }

  /** 当前值 → 下拉索引；未命中（含空值）回退首项，与 Android setSelection(idx<0 ? 0) 一致 */
  private static indexOfOption(list: string[], value: string): number {
    const idx: number = list.indexOf(value);
    return idx >= 0 ? idx : 0;
  }
}
