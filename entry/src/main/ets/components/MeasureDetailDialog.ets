// MeasureDetailDialog.ets —— 测量/轨迹详情对话框（对应 Android ui.dialog.MeasureDetailDialog）。
//
// 0.4.1.0 起 Android 把三个详情弹层的操作区统一为「标题栏操作键 + 底部备注行 + 保存」，
// 鸿蒙端同构照做：标题行 = 名称 + 重命名/分享/删除 + 关闭，底部「备注：内容」行下方仅「保存」。
// 操作键按调用方是否传回调显隐（Android 的 visibility=GONE 等价）：onRename 未传即不显重命名，
// onShare 未传即不显分享（分享仅轨迹详情传入）。鸿蒙无图标资源，操作键沿用本工程既定的文字键
// （FeatureDetailPage 同款式），不引入 emoji。
// 备注：编辑框由本弹层自持（嵌套 CustomDialogController，同 openPicker 取色器），确认后就地刷新
// 底部行并把文本交宿主写库；onRemark 未传（轨迹详情）即整行隐藏。
// 改名不再重建弹层：宿主经 DetailTitleHandle 就地刷新标题（对应 Android findFragmentByTag +
// updateTitle），用户已改的颜色/线宽不丢。
// 其余与 Android 一致：类型与量算文本、样式区（颜色色块 + 线宽步进）；点测量无连线，
// 故隐藏线宽步进（widthEditable=false 由宿主按 type 判定）。颜色选择复用 ColorPickerDialog。

import { ColorHex } from '../common/ColorHex';
import { Theme } from '../common/Theme';
import { AppColorPicker } from './ColorPickerDialog';
import { RemarkEditDialog } from './RemarkEditDialog';

/** 线宽限幅（与 Android MeasureDetailDialog.WIDTH_MIN/MAX 同值） */
const WIDTH_MIN: number = 1;
const WIDTH_MAX: number = 10;

/** 备注行空态占位（同 Android REMARK_EMPTY） */
const REMARK_PLACEHOLDER: string = '未填写';

/**
 * 详情弹层标题就地刷新句柄（对应 Android「按 tag 取回弹层实例调 updateTitle」）。
 * ArkTS 自定义对话框没有 FragmentManager 那样的实例检索，改由此句柄挂钩：弹层出现时绑自身的
 * setter，宿主改名落库后调 setTitle 即刷新标题；弹层销毁即解绑，此时 setTitle 落空忽略。
 */
export class DetailTitleHandle {
  private setter: (title: string) => void = (): void => {};

  bind(fn: (title: string) => void): void {
    this.setter = fn;
  }

  unbind(): void {
    this.setter = (): void => {};
  }

  setTitle(title: string): void {
    this.setter(title);
  }
}

@CustomDialog
export struct MeasureDetailDialog {
  controller: CustomDialogController;
  title: string = '';
  /** 类型显示名（点位测量/距离测量/面积测量/轨迹） */
  typeText: string = '';
  /** 量算文本，空表示不显示该行 */
  geometryText: string = '';
  /** 点测量无线要素 → 隐藏线宽步进 */
  widthEditable: boolean = true;
  initialColor: number = 0xFF57ACFD;
  initialLineWidth: number = 3;
  /** 备注行初值（空串显示占位）；与 onRemark 成对传入 */
  initialRemark: string = '';
  onSave: (color: number, lineWidth: number) => void = (): void => {};
  onDelete: () => void = (): void => {};
  /** 分享回调（仅轨迹详情传入；不传则分享键隐藏，同 Android onShare 可空口径） */
  onShare: (() => void) | undefined = undefined;
  /** 重命名回调（不传则重命名键隐藏，同 Android onRename 可空口径） */
  onRename: (() => void) | undefined = undefined;
  /** 备注保存回调（交宿主写库；不传则底部备注行隐藏，轨迹详情不传，仅测量传入） */
  onRemark: ((remark: string) => void) | undefined = undefined;
  /** 标题就地刷新挂钩（宿主改名成功后 setTitle，弹层不重建） */
  titleHandle: DetailTitleHandle | undefined = undefined;

  @State color: number = 0xFF57ACFD;
  @State lineWidth: number = 3;
  /** 弹层当前显示名：初值取 title，重命名后由 titleHandle 就地改写 */
  @State currentTitle: string = '';
  /** 底部备注行当前内容（编辑确认后就地刷新） */
  @State remark: string = '';
  private picker: CustomDialogController | undefined = undefined;
  /** 备注编辑弹层（叠在本层之上，本层不关闭） */
  private remarkEditor: CustomDialogController | undefined = undefined;

  aboutToAppear(): void {
    this.color = this.initialColor;
    this.lineWidth = Math.max(WIDTH_MIN, Math.min(WIDTH_MAX, this.initialLineWidth));
    this.currentTitle = this.title;
    this.remark = this.initialRemark;
    const handle: DetailTitleHandle | undefined = this.titleHandle;
    if (handle !== undefined) {
      handle.bind((t: string): void => {
        this.currentTitle = t;
        this.title = t;
      });
    }
  }

  aboutToDisappear(): void {
    // 视图销毁即解绑，防止宿主后续 setTitle 落到已销毁的弹层实例
    const handle: DetailTitleHandle | undefined = this.titleHandle;
    if (handle !== undefined) {
      handle.unbind();
    }
  }

  private openPicker(): void {
    this.picker = new CustomDialogController({
      builder: AppColorPicker({
        initialColor: this.color,
        onConfirmColor: (argb: number): void => {
          this.color = argb;
        },
      }),
      customStyle: true,
      alignment: DialogAlignment.Center,
    });
    this.picker.open();
  }

  /** 步进统一经此限幅并回显（与 Android applyWidth 同策略，避免加减两处各写一遍） */
  private applyWidth(value: number): void {
    this.lineWidth = Math.max(WIDTH_MIN, Math.min(WIDTH_MAX, value));
  }

  private colorText(): string {
    return `#${ColorHex.toHex(this.color)}`;
  }

  /** 备注编辑叠在本层之上：确认后就地刷新底部备注行，写库交宿主（嵌套弹层口径同 openPicker） */
  private openRemark(): void {
    this.remarkEditor = new CustomDialogController({
      builder: RemarkEditDialog({
        title: '测量备注',
        initialValue: this.remark,
        onConfirmRemark: (text: string): void => {
          this.remark = text;
          const fn: ((remark: string) => void) | undefined = this.onRemark;
          if (fn !== undefined) {
            fn(text);
          }
        },
      }),
      customStyle: true,
      alignment: DialogAlignment.Center,
    });
    this.remarkEditor.open();
  }

  /** 标题栏操作键统一分派（@Builder 参数不带回调，按键名取对应可空回调） */
  private onHeaderAction(label: string): void {
    if (label === '重命名') {
      // 重命名对话框叠在本弹层之上，改名成功后经 titleHandle 就地刷新标题，本弹层不关闭
      const fn: (() => void) | undefined = this.onRename;
      if (fn !== undefined) {
        fn();
      }
      return;
    }
    if (label === '分享') {
      const fn: (() => void) | undefined = this.onShare;
      if (fn !== undefined) {
        fn();
      }
      this.controller.close();
      return;
    }
    this.onDelete();
    this.controller.close();
  }

  @Builder
  headerAction(label: string) {
    Text(label)
      .fontSize(Theme.FONT_SUB)
      .fontColor(label === '删除' ? Theme.DANGER : Theme.PRIMARY_DARK)
      .padding({ left: 8, right: 8, top: 4, bottom: 4 })
      .onClick((): void => {
        this.onHeaderAction(label);
      })
  }

  /** 底部备注行：整行可点，空态显示占位（同 Android measure_detail_ll_remark）；onRemark 未传即整行隐藏 */
  @Builder
  remarkRow() {
    if (this.onRemark !== undefined) {
      Row({ space: 4 }) {
        Text('备注：')
          .fontSize(Theme.FONT_SUB)
          .fontColor(Theme.TEXT_SUB)
        Text(this.remark.length > 0 ? this.remark : REMARK_PLACEHOLDER)
          .fontSize(Theme.FONT_SUB)
          .fontColor(this.remark.length > 0 ? Theme.TEXT : Theme.TEXT_HINT)
          .layoutWeight(1)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .padding({ top: 8, bottom: 8 })
      .margin({ top: 12 })
      .alignItems(VerticalAlign.Top)
      .onClick((): void => {
        this.openRemark();
      })
    }
  }

  build() {
    Column() {
      // 标题栏：名称 + 重命名/分享/删除 + 关闭（Android 0.4.1.0 统一后的操作区）
      Row({ space: 2 }) {
        Text(this.currentTitle.length > 0 ? this.currentTitle : '测量详情')
          .fontSize(Theme.FONT_TITLE)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.TEXT)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.onRename !== undefined) {
          this.headerAction('重命名')
        }
        if (this.onShare !== undefined) {
          this.headerAction('分享')
        }
        this.headerAction('删除')
        Text('×')
          .fontSize(20)
          .fontColor(Theme.TEXT_SUB)
          .padding({ left: 10, right: 4 })
          .onClick((): void => {
            this.controller.close();
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Text(this.typeText)
        .fontSize(Theme.FONT_SUB)
        .fontColor(Theme.TEXT_SUB)
        .alignSelf(ItemAlign.Start)
        .margin({ top: 4 })

      if (this.geometryText.length > 0) {
        Text(this.geometryText)
          .fontSize(Theme.FONT)
          .fontColor(Theme.TEXT)
          .alignSelf(ItemAlign.Start)
          .margin({ top: 6 })
      }

      Row() {
        Text('颜色')
          .fontSize(Theme.FONT_SUB)
          .fontColor(Theme.TEXT_SUB)
          .width(56)
        Column()
          .width(64)
          .height(28)
          .backgroundColor(this.colorText())
          .borderRadius(4)
          .borderWidth(1)
          .borderColor(Theme.DIVIDER)
          .onClick((): void => {
            this.openPicker();
          })
        Text(this.colorText())
          .fontSize(Theme.FONT_SUB)
          .fontColor(Theme.TEXT_SUB)
          .margin({ left: 10 })
      }
      .width('100%')
      .margin({ top: 14 })

      if (this.widthEditable) {
        Row() {
          Text('线宽')
            .fontSize(Theme.FONT_SUB)
            .fontColor(Theme.TEXT_SUB)
            .width(56)
          Text('−')
            .fontSize(18)
            .fontColor(Theme.PRIMARY_DARK)
            .width(32)
            .height(32)
            .textAlign(TextAlign.Center)
            .backgroundColor(Theme.SUBTLE)
            .borderRadius(6)
            .onClick((): void => {
              this.applyWidth(this.lineWidth - 1);
            })
          Text(`${this.lineWidth}`)
            .fontSize(Theme.FONT)
            .fontColor(Theme.TEXT)
            .width(40)
            .textAlign(TextAlign.Center)
          Text('＋')
            .fontSize(18)
            .fontColor(Theme.PRIMARY_DARK)
            .width(32)
            .height(32)
            .textAlign(TextAlign.Center)
            .backgroundColor(Theme.SUBTLE)
            .borderRadius(6)
            .onClick((): void => {
              this.applyWidth(this.lineWidth + 1);
            })
        }
        .width('100%')
        .margin({ top: 10 })
      }

      // 备注行 + 底部「保存」：删除/分享/重命名在标题栏，备注行紧贴保存上方（Android 同口径）
      this.remarkRow()

      Button('保存')
        .width('100%')
        .height(38)
        .fontSize(Theme.FONT)
        .fontColor(Theme.TEXT_ON_DARK)
        .backgroundColor(Theme.PRIMARY)
        .margin({ top: 16 })
        .onClick((): void => {
          this.onSave(this.color, this.lineWidth);
          this.controller.close();
        })
    }
    .width('100%')
    .padding(Theme.PAD)
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(Theme.CARD)
    .borderRadius(Theme.RADIUS)
  }
}
