// FeatureDetailPage.ets —— 矢量要素详情 / 图层样式编辑页（对应 Android ui.dialog.FeatureDetailDialog）。
//
// Android 是底部弹层，鸿蒙侧内容量大（样式页 + 属性页 + 双开关组 + 步进器 + 属性编辑），
// 弹层内滚在 ArkUI 里手势冲突多，故按已注册的 router 页承载；页签、门控与保存语义逐条对齐：
//  · 双页签：样式（仅 styleEditable 的 shp/gpkg）/ 属性（图层样式模式下无属性页签，与 Android removeTabAt 同）。
//  · 样式初值优先级：文档已有样式 > 要素实际渲染色（fallback）> 默认色，色块所见即所得。
//  · 点要素以图标单选代替面样式（面填充/描边/线宽对点无意义），标注区仍保留。
//  · 标注区对 kml/kmz 隐藏（标注随源文件，无文档覆盖意义）。
//  · 属性页「编辑」门控：attrsEditable 只是能力位，需点顶栏「编辑」后值行才可点改。
//  · 样地调查入口置于顶栏，始终可见（不受页签切换与编辑门控影响），对齐 surveyBypassEdit。
// 属性由主地图页异步回取（GDAL 开 KML/DXF 可达秒级），本页可能先于属性显示：
// 经 PageSignals 收到回填事件后就地重建属性表与标注字段候选（等价 pushAttributes）。
// 与 Android 的有意差异：KML description 不引 Web 组件。ArcGIS/MapInfo 导出的 KML 无 ExtendedData，
// 属性整份写在 description 的嵌套 HTML 表里，故先按名/值两列还原成属性表（等价 Android 的 WebView 观感），
// 还原不出成对行才退回备注级去标签纯文本。

import { router } from '@kit.ArkUI';
import { ColorHex } from '../common/ColorHex';
import { PageData, PageKeys, PageSignals } from '../common/PageData';
import { Theme } from '../common/Theme';
import { Ui } from '../common/Ui';
import { StyleOverride } from '../doc/DocModels';
import { FeatureDetailRequest, FeaturePickController } from '../map/FeaturePickController';
import { MapServices } from '../map/MapServices';
import { MapStyle } from '../map/MapStyle';
import { AttributeEditDialog } from '../components/AttributeEditDialog';
import { AppColorPicker } from '../components/ColorPickerDialog';
import { ColorRow } from '../components/ColorSwatch';
import { FeatureIcons } from '../vector/FeatureIcons';
import { StepField } from '../components/StepField';
import { SwitchRow } from '../components/SwitchRow';
import { TitleBar } from '../components/TitleBar';
import { VectorFormats } from '../vector/VectorFormats';
import { GdalVectorReader } from '../vector/GdalVectorReader';
import { SurveyEntryContext, SurveyListParams } from './RouteParams';

/** 页签下标（与 Android TAB_STYLE / TAB_ATTRS 对应） */
const TAB_STYLE: number = 0;
const TAB_ATTRS: number = 1;

const LABEL_FIELD_NONE: string = '不标注';
/** 字号显示基准：磅值 = labelSize 缩放系数 × 14 */
const LABEL_SIZE_BASE: number = 14;
const WIDTH_MIN: number = 1;
const WIDTH_MAX: number = 10;
const SIZE_MIN: number = 8;
const SIZE_MAX: number = 36;

const DEFAULT_FILL: string = '#FF4A90D9';
const DEFAULT_OUTLINE: string = '#FF1A4FA0';
const DEFAULT_LABEL: string = '#FF212121';
const DEFAULT_LABEL_OUTLINE: string = '#FF000000';

/** 色块用途（选色器回调回填到哪个状态字段） */
const TARGET_FILL: string = 'fill';
const TARGET_OUTLINE: string = 'outline';
const TARGET_LABEL: string = 'label';
const TARGET_LABEL_OUTLINE: string = 'labelOutline';

/** 属性表一行（用数组承载以便 ForEach 按 key+value 生成本体键，改值即刷新） */
class AttrRow {
  key: string;
  value: string;

  constructor(key: string, value: string) {
    this.key = key;
    this.value = value;
  }
}

@Entry
@Component
struct FeatureDetailPage {
  /** 底部导航条避让高度（vp）：主窗口是全屏布局，底部动作条要让开导航条，否则按钮下半部点不到 */
  @StorageProp('bottomInsetVp') bottomInset: number = 0;
  @State tab: number = TAB_STYLE;
  /** 样式编辑态（面样式 / 标注） */
  @State fillColor: string = DEFAULT_FILL;
  @State fillEnabled: boolean = true;
  // 注：字段名避开 CustomComponent 内置属性名（outlineColor / outlineWidth 作成员名会编译报错）
  @State strokeColor: string = DEFAULT_OUTLINE;
  @State strokeW: number = WIDTH_MIN;
  @State iconKey: string = FeatureIcons.DEFAULT_KEY;
  @State labelEnabled: boolean = false;
  @State labelField: string = LABEL_FIELD_NONE;
  @State labelColor: string = DEFAULT_LABEL;
  @State labelSizePt: number = LABEL_SIZE_BASE;
  @State labelOutlineEnabled: boolean = false;
  @State labelOutlineColor: string = DEFAULT_LABEL_OUTLINE;
  /** 属性页状态 */
  @State rows: AttrRow[] = [];
  @State attrsLoading: boolean = false;
  @State descText: string = '';
  /** description 的 HTML 表格被还原成属性表时的两个附属态：斑马纹开关、顶部显示字段值带 */
  @State descAsTable: boolean = false;
  @State descCaption: string = '';
  @State editing: boolean = false;
  @State attrsDirty: boolean = false;
  /** 标注字段候选：图层样式模式取整层字段，单要素模式取属性表字段（回填后刷新） */
  @State labelFields: string[] = [];

  private req: FeatureDetailRequest = new FeatureDetailRequest();
  /** 本次会话内改过的属性（仅这些写回源文件，对齐 Android pendingAttrs） */
  private pendingAttrs: Map<string, string> = new Map<string, string>();
  private colorPicker: CustomDialogController | undefined = undefined;
  private editDialog: CustomDialogController | undefined = undefined;
  private colorTarget: string = TARGET_FILL;

  aboutToAppear(): void {
    const raw: Object | undefined = PageData.take(PageKeys.FEATURE_DETAIL);
    if (raw === undefined) {
      // 直接访问本页（未从地图拾取）时无上下文，退出比显示空壳安全
      Ui.toast('未选择要素');
      router.back();
      return;
    }
    this.req = raw as FeatureDetailRequest;
    this.initStyle();
    if (this.req.layerStyleMode) {
      this.labelFields = GdalVectorReader.fieldNames(this.req.path);
    }
    this.refreshAttrs();
    // 图层样式模式只有样式页（Android 会 removeTabAt 掉属性页），故不考量 styleEditable 直接停在样式页
    this.tab = this.req.layerStyleMode || this.req.styleEditable ? TAB_STYLE : TAB_ATTRS;
    PageSignals.bind(PageKeys.FEATURE_DETAIL, (): void => {
      this.refreshAttrs();
    });
  }

  aboutToDisappear(): void {
    PageSignals.unbind(PageKeys.FEATURE_DETAIL);
    PageData.clear(PageKeys.FEATURE_DETAIL);
  }

  // ── 可见性判定（与 Android 的 removeTabAt / visibility 分支等价）──────────────

  private isPointFeature(): boolean {
    return !this.req.layerStyleMode && this.req.geomType === 0;
  }

  private showStyleTab(): boolean {
    return this.req.styleEditable;
  }

  private showAttrsTab(): boolean {
    return !this.req.layerStyleMode;
  }

  /** 标注区：kml/kmz 标注随源文件，文档覆盖无意义（Android labelSectionVisible=false） */
  private labelSectionVisible(): boolean {
    const ext: string = VectorFormats.extOf(this.req.path);
    return ext !== 'kml' && ext !== 'kmz';
  }

  private showStylePage(): boolean {
    return this.tab === TAB_STYLE && this.showStyleTab();
  }

  private editGateVisible(): boolean {
    return this.req.attrsEditable && !this.editing && this.tab === TAB_ATTRS;
  }

  private surveyEntryVisible(): boolean {
    return this.req.surveyEntry;
  }

  private titleText(): string {
    if (this.req.layerStyleMode) {
      return '图层样式';
    }
    return this.req.layerName.length > 0 ? this.req.layerName : '要素详情';
  }

  private subtitleText(): string {
    if (this.req.layerStyleMode) {
      return this.req.layerName;
    }
    return this.req.geometryText;
  }

  // ── 样式初值与保存 ──────────────────────────────────────────────

  /** 样式初值：文档覆盖优先，其次实际渲染色（fallback），再默认色 */
  private initStyle(): void {
    const s: StyleOverride = this.req.style;
    // 色串统一走 firstOf：Android 侧字段是 String?，null 天然不进 `?:` 右分支；
    // 本端文档里可能存下空串（早期写入 / 跨端文档），`??` 兑不住空串会直接给出色块画成无色的值。
    this.fillColor = this.firstOf(s.fillColor,
      this.req.fallbackFill.length > 0 ? this.req.fallbackFill : DEFAULT_FILL);
    this.fillEnabled = s.fillEnabled ?? true;
    this.strokeColor = this.firstOf(s.outlineColor,
      this.req.fallbackOutline.length > 0 ? this.req.fallbackOutline : DEFAULT_OUTLINE);
    const width: number | undefined = s.outlineWidth;
    if (width !== undefined) {
      this.strokeW = Math.max(WIDTH_MIN, Math.min(WIDTH_MAX, Math.round(width)));
    }
    this.iconKey = FeatureIcons.keyOf(s);
    this.labelColor = this.firstOf(s.labelColor, DEFAULT_LABEL);
    this.labelEnabled = s.labelField !== undefined && (s.labelField ?? '').length > 0;
    this.labelField = this.labelEnabled ? (s.labelField ?? LABEL_FIELD_NONE) : LABEL_FIELD_NONE;
    const size: number | undefined = s.labelSize;
    if (size !== undefined) {
      this.labelSizePt = Math.max(SIZE_MIN, Math.min(SIZE_MAX, Math.round(size * LABEL_SIZE_BASE)));
    }
    this.labelOutlineEnabled = s.labelOutline === true;
    this.labelOutlineColor = this.firstOf(s.labelOutlineColor, DEFAULT_LABEL_OUTLINE);
  }

  /** 首个非空色串：空串视同未设置，继续往后回退（与 LayerManagePage.firstOf 同一取向） */
  private firstOf(primary: string | undefined, fallback: string): string {
    return primary !== undefined && primary.length > 0 ? primary : fallback;
  }

  /** 汇总控件状态为样式覆盖：点要素只写图标，关闭态才落盘（避免无谓的样式版本变化） */
  private buildStyle(): StyleOverride {
    const s: StyleOverride = new StyleOverride();
    if (this.isPointFeature()) {
      s.iconKey = this.iconKey;
    } else {
      s.fillColor = this.fillColor;
      if (!this.fillEnabled) {
        s.fillEnabled = false;
      }
      s.outlineColor = this.strokeColor;
      s.outlineWidth = this.strokeW;
    }
    if (this.labelSectionVisible()) {
      s.labelField = this.labelEnabled && this.labelField !== LABEL_FIELD_NONE
        ? this.labelField : undefined;
      s.labelColor = this.labelColor;
      s.labelSize = this.labelSizePt / LABEL_SIZE_BASE;
      s.labelOutline = this.labelOutlineEnabled;
      if (this.labelOutlineEnabled) {
        s.labelOutlineColor = this.labelOutlineColor;
      }
    }
    return s;
  }

  private saveStyle(): void {
    this.writeStyle(this.buildStyle());
  }

  /** 恢复默认：保存空样式（单要素模式移除该要素覆盖，图层模式清除整层覆盖字段） */
  private resetStyle(): void {
    this.writeStyle(new StyleOverride());
  }

  private writeStyle(style: StyleOverride): void {
    const pick: FeaturePickController | undefined = MapServices.instance.pick;
    if (pick === undefined) {
      Ui.toast('地图未就绪，稍后再试');
      return;
    }
    if (this.req.layerStyleMode) {
      pick.saveLayerStyle(this.req.path, style);
    } else {
      pick.saveFeatureStyle(this.req.path, this.req.fid, style);
    }
    Ui.toast('样式已保存');
    router.back();
  }

  // ── 选色 ────────────────────────────────────────────────────────

  private colorOf(target: string): string {
    if (target === TARGET_OUTLINE) {
      return this.strokeColor;
    }
    if (target === TARGET_LABEL) {
      return this.labelColor;
    }
    if (target === TARGET_LABEL_OUTLINE) {
      return this.labelOutlineColor;
    }
    return this.fillColor;
  }

  private pickColor(target: string): void {
    this.colorTarget = target;
    this.colorPicker = new CustomDialogController({
      builder: AppColorPicker({
        initialColor: ColorHex.parse(this.colorOf(target), 0xFF000000),
        onConfirmColor: (argb: number): void => {
          this.applyColor(MapStyle.argbToHex(argb));
        },
      }),
      customStyle: true,
      alignment: DialogAlignment.Center,
      autoCancel: true,
    });
    this.colorPicker.open();
  }

  private applyColor(hex: string): void {
    if (this.colorTarget === TARGET_OUTLINE) {
      this.strokeColor = hex;
    } else if (this.colorTarget === TARGET_LABEL) {
      this.labelColor = hex;
    } else if (this.colorTarget === TARGET_LABEL_OUTLINE) {
      this.labelOutlineColor = hex;
    } else {
      this.fillColor = hex;
    }
  }

  // ── 属性表 ──────────────────────────────────────────────────────

  /** 属性回填（含首帧与异步回填）：重建行 + 标注字段候选；单要素模式随属性字段走 */
  private refreshAttrs(): void {
    const attrs: Map<string, string> | null = this.req.attributes;
    this.attrsLoading = attrs === null;
    // 仅 kml/kmz 的 description 是富内容（HTML）；shp/gpkg 里同名列就是普通可编辑字段
    const desc: string = VectorFormats.isKml(this.req.path) ? this.req.description : '';
    // OGR 的 KML 驱动恒给 Name/altitudeMode/tessellate/extrude/visibility/snippet/description 七个字段，
    // 导出件的 83 个真属性只在 description HTML 里 —— 还原成功就整表顶上（Android WebView 同为整表替换）
    const realRows: AttrRow[] = [];
    if (attrs !== null) {
      attrs.forEach((value: string, key: string): void => {
        if (desc.length > 0 && key.toLowerCase() === 'description') {
          // description 已单独取走；留在表里会把整段 HTML 铺成一行
          return;
        }
        realRows.push(new AttrRow(key, value));
      });
    }
    const descRows: AttrRow[] = desc.length > 0 ? FeatureDetailPage.descTableOf(desc) : [];
    const descPairs: AttrRow[] = [];
    let caption: string = '';
    for (let i = 0; i < descRows.length; i++) {
      if (descRows[i].key.length === 0) {
        if (caption.length === 0) {
          caption = descRows[i].value;
        }
      } else {
        descPairs.push(descRows[i]);
      }
    }
    const asTable: boolean = descPairs.length > 0;
    const rows: AttrRow[] = asTable ? descPairs : realRows;
    this.descAsTable = asTable;
    this.descCaption = asTable ? caption : '';
    // 还原成表时备注不叠加；解不出成对行才把 description 当备注整段展示在表上方
    this.descText = asTable || desc.length === 0 ? '' : FeatureDetailPage.plainOf(desc);
    const fields: string[] = [];
    for (let i = 0; i < rows.length; i++) {
      fields.push(rows[i].key);
    }
    this.rows = rows;
    if (!this.req.layerStyleMode) {
      this.labelFields = fields;
    }
  }

  /** HTML → 纯文本：换行标签转 \\n，其余标签剥除，常见实体还原（KML description 多为备注片段） */
  private static plainOf(html: string): string {
    let s: string = html.replace(/<!\[CDATA\[([\s\S]*?)\]\]>/gi, '$1');
    s = s.replace(/<br\s*\/?>/gi, '\n');
    s = s.replace(/<\/p>/gi, '\n');
    s = s.replace(/<[^>]*>/g, '');
    s = s.replace(/&nbsp;/gi, ' ');
    s = s.replace(/&lt;/gi, '<');
    s = s.replace(/&gt;/gi, '>');
    s = s.replace(/&quot;/gi, '"');
    s = s.replace(/&#39;/gi, "'");
    s = s.replace(/&amp;/gi, '&');
    s = s.replace(/\n{2,}/g, '\n');
    return s.trim();
  }

  /**
   * KML description 的 HTML 表格 → 属性行，对齐 Android 的 WebView 观感。
   * 只认最内层 <tr>：ArcGIS/MapInfo 把真表格嵌在外层单格 <tr> 里，外层行没有名值语义。
   * 行内 2 格=名/值；>2 格=首格作名其余拼接；1 格=显示字段值，key 留空由调用方另作表头带。
   */
  private static descTableOf(html: string): AttrRow[] {
    const rows: AttrRow[] = [];
    const body: string = html.replace(/<!\[CDATA\[([\s\S]*?)\]\]>/gi, '$1');
    // <tr>/</tr> 配对扫描：starts 记每行正文起点，hasChild 标记该行是否套了子表
    const starts: number[] = [];
    const hasChild: boolean[] = [];
    let sp: number = 0;
    const tagRe: RegExp = /<(\/?)tr\b[^>]*>/gi;
    let tag: RegExpExecArray | null = tagRe.exec(body);
    while (tag !== null) {
      if (tag[1] === '/') {
        if (sp === 0) {
          return [];
        }
        sp--;
        if (!hasChild[sp]) {
          const cells: string[] = FeatureDetailPage.cellTextsOf(body.substring(starts[sp], tag.index));
          if (cells.length === 2) {
            rows.push(new AttrRow(cells[0], cells[1]));
          } else if (cells.length === 1 && cells[0].length > 0) {
            // 单格行是导出器放的显示字段值：无名，key 置空由调用方当表头带用
            rows.push(new AttrRow('', cells[0]));
          } else if (cells.length > 2) {
            let value: string = cells[1];
            for (let i = 2; i < cells.length; i++) {
              value = `${value}  ${cells[i]}`;
            }
            rows.push(new AttrRow(cells[0], value));
          }
        }
        if (sp > 0) {
          hasChild[sp - 1] = true;
        }
      } else {
        starts[sp] = tag.index + tag[0].length;
        hasChild[sp] = false;
        sp++;
      }
      tag = tagRe.exec(body);
    }
    return rows;
  }

  /** 最内层行正文 → 单元格文本（<td>/<th>，容忍大小写与属性） */
  private static cellTextsOf(trBody: string): string[] {
    const cells: string[] = [];
    const cellRe: RegExp = /<t[dh]\b[^>]*>([\s\S]*?)<\/t[dh]>/gi;
    let m: RegExpExecArray | null = cellRe.exec(trBody);
    while (m !== null) {
      cells.push(FeatureDetailPage.cellTextOf(m[1]));
      m = cellRe.exec(trBody);
    }
    return cells;
  }

  /** 单元格文本：剥内联标签 + 实体还原 + 折叠空白（导出 HTML 标签间全是换行，不折叠会撑成多行） */
  private static cellTextOf(raw: string): string {
    let s: string = raw.replace(/<[^>]*>/g, ' ');
    s = s.replace(/&nbsp;/gi, ' ');
    s = s.replace(/&lt;/gi, '<');
    s = s.replace(/&gt;/gi, '>');
    s = s.replace(/&quot;/gi, '"');
    s = s.replace(/&#39;/gi, "'");
    s = s.replace(/&amp;/gi, '&');
    s = s.replace(/\s+/g, ' ');
    return s.trim();
  }

  /** 值列点击：编辑门控未开时忽略（与 Android 一致，避免误改属性） */
  private editRow(index: number): void {
    if (!this.req.attrsEditable || !this.editing) {
      return;
    }
    const row: AttrRow | undefined = this.rows[index];
    if (row === undefined) {
      return;
    }
    const pending: string | undefined = this.pendingAttrs.get(row.key);
    const current: string = pending === undefined ? row.value : pending;
    this.editDialog = new CustomDialogController({
      builder: AttributeEditDialog({
        fieldKey: row.key,
        initialValue: current,
        onConfirmValue: (value: string): void => {
          this.applyAttr(row.key, index, value);
        },
      }),
      customStyle: true,
      alignment: DialogAlignment.Center,
      autoCancel: true,
    });
    this.editDialog.open();
  }

  private applyAttr(key: string, index: number, value: string): void {
    this.pendingAttrs.set(key, value);
    const rows: AttrRow[] = [];
    for (let i = 0; i < this.rows.length; i++) {
      const src: AttrRow = this.rows[i];
      rows.push(new AttrRow(src.key, i === index ? value : src.value));
    }
    this.rows = rows;
    this.attrsDirty = true;
  }

  private saveAttrs(): void {
    const pick: FeaturePickController | undefined = MapServices.instance.pick;
    if (pick === undefined) {
      Ui.toast('地图未就绪，稍后再试');
      return;
    }
    if (pick.persistAttributes(this.req.path, this.req.fid, this.pendingAttrs)) {
      router.back();
    }
  }

  /** 样地调查入口：上下文（属性 + 图斑外环）经 PageData 交给样地列表页 */
  private openSurveyEntry(): void {
    const ctx: SurveyEntryContext = new SurveyEntryContext();
    ctx.attributes = this.req.attributes;
    ctx.outerRing = this.req.outerRingLatLon;
    PageData.put(PageKeys.SURVEY_ENTRY, ctx);
    const params: SurveyListParams = new SurveyListParams();
    params.sourcePath = this.req.path;
    params.sourceFid = this.req.fid;
    router.pushUrl({ url: 'pages/SurveyListPage', params: params });
  }

  /** 标注字段候选：仅真实字段（标注启停统一由「显示标注」开关控制，不再有「不标注」项，对齐 Android 0.3.0.4） */
  private fieldOptions(): SelectOption[] {
    const options: SelectOption[] = [];
    for (let i = 0; i < this.labelFields.length; i++) {
      options.push({ value: this.labelFields[i] });
    }
    return options;
  }

  private fieldIndex(): number {
    const at: number = this.labelFields.indexOf(this.labelField);
    return at < 0 ? 0 : at;
  }

  // ── 界面 ────────────────────────────────────────────────────────

  build() {
    Column() {
      TitleBar({
        title: this.titleText(),
        subtitle: this.subtitleText(),
        // 箭头函数包裹传入：直传 this.barActions 会丢失宿主 this 绑定，
        // 槽内 surveyEntryVisible()/editing 等会指向 TitleBar 而抛 undefined
        actions: (): void => {
          this.barActions();
        },
      })

      Scroll() {
        Column({ space: Theme.GAP }) {
          this.infoCard()
          Row({ space: 8 }) {
            if (this.showStyleTab()) {
              this.tabItem('样式', TAB_STYLE)
            }
            if (this.showAttrsTab()) {
              this.tabItem('属性', TAB_ATTRS)
            }
          }
          .width('100%')
          .padding({ left: Theme.PAD, right: Theme.PAD })

          if (this.showStylePage()) {
            this.stylePage()
          } else {
            this.attrsPage()
          }
        }
        .width('100%')
        .padding({ top: Theme.GAP, bottom: Theme.PAD })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.Top)

      this.bottomBar()
    }
    .width('100%')
    .height('100%')
    .padding({ bottom: this.bottomInset })
    .backgroundColor(Theme.BG)
  }

  @Builder
  barActions() {
    Row({ space: 14 }) {
      if (this.surveyEntryVisible()) {
        Text('样地调查')
          .fontSize(Theme.FONT)
          .fontColor(Theme.TEXT_ON_DARK)
          .onClick((): void => {
            this.openSurveyEntry();
          })
      }
      if (this.editGateVisible()) {
        Text('编辑')
          .fontSize(Theme.FONT)
          .fontColor(Theme.TEXT_ON_DARK)
          .onClick((): void => {
            this.editing = true;
          })
      }
    }
  }

  /** 基本信息卡：图层名 / 几何量算 / 要素ID（图层样式模式无要素概念，只留图层名） */
  @Builder
  infoCard() {
    Column({ space: 4 }) {
      if (!this.req.layerStyleMode) {
        this.infoRow('图层', this.req.layerName.length > 0 ? this.req.layerName : '（未知图层）')
      }
      if (this.req.geometryText.length > 0) {
        this.infoRow('量算', this.req.geometryText)
      }
      if (!this.req.layerStyleMode) {
        this.infoRow('要素ID', this.req.fid >= 0 ? `${this.req.fid}` : '无')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(12)
    .margin({ left: Theme.PAD, right: Theme.PAD })
    .backgroundColor(Theme.CARD)
    .borderRadius(Theme.RADIUS)
  }

  @Builder
  infoRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(Theme.FONT_SUB)
        .fontColor(Theme.TEXT_SUB)
        .width(52)
      Text(value)
        .fontSize(Theme.FONT_SUB)
        .fontColor(Theme.TEXT)
        .layoutWeight(1)
    }
    .width('100%')
  }

  @Builder
  tabItem(label: string, index: number) {
    Text(label)
      .fontSize(Theme.FONT)
      .fontColor(this.tab === index ? Theme.TEXT_ON_DARK : Theme.TEXT_SUB)
      .textAlign(TextAlign.Center)
      .height(34)
      .layoutWeight(1)
      .backgroundColor(this.tab === index ? Theme.PRIMARY : Theme.SUBTLE)
      .borderRadius(Theme.RADIUS)
      .onClick((): void => {
        this.tab = index;
      })
  }

  /** 分组小标题 */
  @Builder
  sectionTitle(text: string) {
    Text(text)
      .fontSize(Theme.FONT)
      .fontWeight(FontWeight.Medium)
      .fontColor(Theme.TEXT)
      .width('100%')
      .margin({ top: 6 })
  }

  @Builder
  stylePage() {
    Column({ space: 4 }) {
      if (this.isPointFeature()) {
        this.sectionTitle('标识图标')
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(FeatureIcons.keys(), (key: string): void => {
            Text(FeatureIcons.labelOf(key))
              .fontSize(Theme.FONT)
              .fontColor(this.iconKey === key ? Theme.TEXT_ON_DARK : Theme.TEXT_SUB)
              .textAlign(TextAlign.Center)
              .width(64)
              .height(32)
              .margin({ right: 8, bottom: 8 })
              .backgroundColor(this.iconKey === key ? Theme.PRIMARY : Theme.SUBTLE)
              .borderRadius(Theme.RADIUS)
              .onClick((): void => {
                this.iconKey = key;
              })
          }, (key: string): string => key)
        }
        .width('100%')
        .margin({ top: 4 })
      } else {
        this.sectionTitle('面样式')
        SwitchRow({
          title: '填充',
          isOn: this.fillEnabled,
          onSwitchChange: (v: boolean): void => {
            this.fillEnabled = v;
          },
        })
        ColorRow({
          label: '填充色',
          color: this.fillColor,
          dim: !this.fillEnabled,
          onTap: (): void => {
            this.pickColor(TARGET_FILL);
          },
        })
        ColorRow({
          label: '描边色',
          color: this.strokeColor,
          onTap: (): void => {
            this.pickColor(TARGET_OUTLINE);
          },
        })
        StepField({
          label: '线宽',
          min: WIDTH_MIN,
          max: WIDTH_MAX,
          value: this.strokeW,
          onValueChange: (v: number): void => {
            this.strokeW = v;
          },
        })
      }

      if (this.labelSectionVisible()) {
        this.sectionTitle('字体设置')
        SwitchRow({
          title: '显示标注',
          isOn: this.labelEnabled,
          onSwitchChange: (v: boolean): void => {
            // 仅切换下方控件显隐，不清空已选字段/颜色（关闭重开恢复原选择，对齐 Android 0.3.0.4）；
            // 首次开启且尚未选字段时默认落到首个候选，保证下拉有合法选中项
            this.labelEnabled = v;
            if (v && this.labelField === LABEL_FIELD_NONE && this.labelFields.length > 0) {
              this.labelField = this.labelFields[0];
            }
          },
        })
        // 关闭标注时隐藏字段/颜色/轮廓/大小控件（仅隐藏、状态保留），重新打开即恢复原选择
        if (this.labelEnabled) {
          Row() {
            Text('标注字段')
              .fontSize(Theme.FONT)
              .fontColor(Theme.TEXT)
              .width(72)
            Select(this.fieldOptions())
              .selected(this.fieldIndex())
              .value(this.labelField === LABEL_FIELD_NONE ? '' : this.labelField)
              .layoutWeight(1)
              .backgroundColor(Theme.SUBTLE)
              .onSelect((index: number): void => {
                if (index >= 0 && index < this.labelFields.length) {
                  this.labelField = this.labelFields[index];
                }
              })
          }
          .width('100%')
          .height(40)

          ColorRow({
            label: '字体色',
            color: this.labelColor,
            onTap: (): void => {
              this.pickColor(TARGET_LABEL);
            },
          })
          SwitchRow({
            title: '字体轮廓',
            isOn: this.labelOutlineEnabled,
            onSwitchChange: (v: boolean): void => {
              this.labelOutlineEnabled = v;
            },
          })
          ColorRow({
            label: '轮廓色',
            color: this.labelOutlineColor,
            dim: !this.labelOutlineEnabled,
            onTap: (): void => {
              this.pickColor(TARGET_LABEL_OUTLINE);
            },
          })
          StepField({
            label: '字号',
            suffix: '磅',
            min: SIZE_MIN,
            max: SIZE_MAX,
            value: this.labelSizePt,
            onValueChange: (v: number): void => {
              this.labelSizePt = v;
            },
          })
        }
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(12)
    .margin({ left: Theme.PAD, right: Theme.PAD })
    .backgroundColor(Theme.CARD)
    .borderRadius(Theme.RADIUS)
  }

  @Builder
  attrsPage() {
    Column() {
      if (this.descText.length > 0) {
        // 备注型 description（解不出名值对的那类）：去标签后整段展示，表格照常在其下方
        Text(this.descText)
          .fontSize(Theme.FONT)
          .fontColor(Theme.TEXT)
          .width('100%')
          .padding(4)
      }
      if (this.rows.length === 0 && this.descText.length === 0) {
        Text(this.attrsLoading ? '正在读取属性…' : '该要素暂无属性表')
          .fontSize(Theme.FONT_SUB)
          .fontColor(Theme.TEXT_SUB)
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding(24)
      } else if (this.rows.length > 0) {
        // 导出件 KML 的显示字段值带（Android WebView 里那条蓝底居中行）
        if (this.descCaption.length > 0) {
          Text(this.descCaption)
            .fontSize(Theme.FONT)
            .fontWeight(FontWeight.Bold)
            .fontColor(Theme.TEXT)
            .textAlign(TextAlign.Center)
            .width('100%')
            .padding({ top: 6, bottom: 6 })
            .backgroundColor(Theme.SUBTLE)
        }
        // 键值表头：Android 在 WebView 模式下同样隐藏，还原件 KML 有值带就够了
        if (!this.descAsTable) {
          Row() {
            Text('属性名')
              .fontSize(Theme.FONT_SUB)
              .fontColor(Theme.TEXT_SUB)
              .layoutWeight(1)
            Text('属性值')
              .fontSize(Theme.FONT_SUB)
              .fontColor(Theme.TEXT_SUB)
              .layoutWeight(2)
          }
          .width('100%')
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .backgroundColor(Theme.SUBTLE)
        }

        ForEach(this.rows, (row: AttrRow, index: number): void => {
          Row() {
            Text(row.key)
              .fontSize(Theme.FONT)
              .fontColor(Theme.TEXT_SUB)
              .layoutWeight(1)
            Text(row.value.length > 0 ? row.value : '<空>')
              .fontSize(Theme.FONT)
              .fontColor(this.req.attrsEditable && this.editing ? Theme.PRIMARY_DARK : Theme.TEXT)
              .layoutWeight(2)
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
          .padding({ left: 10, right: 10, top: 8, bottom: 8 })
          .backgroundColor(this.descAsTable && index % 2 === 1 ? Theme.SUBTLE : Color.Transparent)
          .border({ width: { bottom: 1 }, color: { bottom: Theme.DIVIDER } })
          .onClick((): void => {
            this.editRow(index);
          })
        }, (row: AttrRow, index: number): string => `${index}:${row.key}=${row.value}`)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(12)
    .margin({ left: Theme.PAD, right: Theme.PAD })
    .backgroundColor(Theme.CARD)
    .borderRadius(Theme.RADIUS)
  }

  @Builder
  bottomBar() {
    Row({ space: 10 }) {
      if (this.showStylePage()) {
        Button('恢复默认')
          .layoutWeight(1)
          .height(42)
          .fontSize(Theme.FONT)
          .fontColor(Theme.TEXT_SUB)
          .backgroundColor(Theme.SUBTLE)
          .borderRadius(Theme.RADIUS)
          .onClick((): void => {
            this.resetStyle();
          })
        Button('保存样式')
          .layoutWeight(1)
          .height(42)
          .fontSize(Theme.FONT)
          .fontColor(Theme.TEXT_ON_DARK)
          .backgroundColor(Theme.PRIMARY)
          .borderRadius(Theme.RADIUS)
          .onClick((): void => {
            this.saveStyle();
          })
      } else if (this.req.attrsEditable && this.attrsDirty) {
        Button('保存属性')
          .width('100%')
          .height(42)
          .fontSize(Theme.FONT)
          .fontColor(Theme.TEXT_ON_DARK)
          .backgroundColor(Theme.PRIMARY)
          .borderRadius(Theme.RADIUS)
          .onClick((): void => {
            this.saveAttrs();
          })
      }
    }
    .width('100%')
    .padding({ left: Theme.PAD, right: Theme.PAD, top: Theme.GAP, bottom: Theme.PAD })
  }
}
