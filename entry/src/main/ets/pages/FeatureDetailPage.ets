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
// 与 Android 的有意差异：KML description 的 HTML 以去标签纯文本展示，不引 Web 组件（内容仅备注级）。

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
    const desc: string = this.req.description;
    this.descText = desc.length > 0 ? FeatureDetailPage.plainOf(desc) : '';
    const rows: AttrRow[] = [];
    const fields: string[] = [];
    if (attrs !== null) {
      attrs.forEach((value: string, key: string): void => {
        rows.push(new AttrRow(key, value));
        fields.push(key);
      });
    }
    this.rows = rows;
    if (!this.req.layerStyleMode) {
      this.labelFields = fields;
    }
  }

  /** HTML → 纯文本：换行标签转 \\n，其余标签剥除，常见实体还原（KML description 多为备注片段） */
  private static plainOf(html: string): string {
    let s: string = html.replace(/<br\s*\/?>/gi, '\n');
    s = s.replace(/<\/p>/gi, '\n');
    s = s.replace(/<[^>]*>/g, '');
    s = s.replace(/&nbsp;/gi, ' ');
    s = s.replace(/&lt;/gi, '<');
    s = s.replace(/&gt;/gi, '>');
    s = s.replace(/&quot;/gi, '"');
    s = s.replace(/&#39;/gi, "'");
    s = s.replace(/&amp;/gi, '&');
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

  /** 标注字段候选：首项固定「不标注」 */
  private fieldOptions(): SelectOption[] {
    const options: SelectOption[] = [{ value: LABEL_FIELD_NONE }];
    for (let i = 0; i < this.labelFields.length; i++) {
      options.push({ value: this.labelFields[i] });
    }
    return options;
  }

  private fieldIndex(): number {
    if (!this.labelEnabled) {
      return 0;
    }
    const at: number = this.labelFields.indexOf(this.labelField);
    return at < 0 ? 0 : at + 1;
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
            this.labelEnabled = v;
            if (!v) {
              this.labelField = LABEL_FIELD_NONE;
            }
          },
        })
        Row() {
          Text('标注字段')
            .fontSize(Theme.FONT)
            .fontColor(Theme.TEXT)
            .width(72)
          // 不加 .enabled(labelEnabled)：Android 的 Spinner 从不受标注开关限制，字段随时可选
          // （开关只决定保存时是否写 labelField）；置灰会使“未开标注”下点开看不到任何候选。
          // 选到真实字段即在 onSelect 里把开关同步打开，语义与 Android 一致。
          Select(this.fieldOptions())
            .selected(this.fieldIndex())
            .value(this.labelEnabled ? this.labelField : LABEL_FIELD_NONE)
            .layoutWeight(1)
            .backgroundColor(Theme.SUBTLE)
            .onSelect((index: number): void => {
              this.labelEnabled = index > 0;
              this.labelField = index > 0 && index - 1 < this.labelFields.length
                ? this.labelFields[index - 1] : LABEL_FIELD_NONE;
            })
        }
        .width('100%')
        .height(40)

        ColorRow({
          label: '字体色',
          color: this.labelColor,
          dim: !this.labelEnabled,
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
        // KML/KMZ 描述：去标签后整段展示（Android 用 WebView 渲染同一段 HTML）
        Text(this.descText)
          .fontSize(Theme.FONT)
          .fontColor(Theme.TEXT)
          .width('100%')
          .padding(4)
      } else if (this.rows.length === 0) {
        Text(this.attrsLoading ? '正在读取属性…' : '该要素暂无属性表')
          .fontSize(Theme.FONT_SUB)
          .fontColor(Theme.TEXT_SUB)
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding(24)
      } else {
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
