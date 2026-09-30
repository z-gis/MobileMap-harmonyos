// MeasureDetailDialog.ets —— 测量详情/样式编辑对话框（对应 Android ui.dialog.MeasureDetailDialog）。
//
// 与 Android 一致的结构：标题=测量名称、类型与量算文本、样式区（颜色色块 + 线宽步进）、底部删除/保存。
// 点测量无连线，故隐藏线宽步进（widthEditable=false 由宿主按 type 判定）。
// 颜色选择复用 ColorPickerDialog；Android 的 BottomSheet 在鸿蒙对应 CustomDialog（居中卡片），
// 交互语义（改样式即写库 + 重建叠加层 + 轻提示）保持相同。

import { ColorHex } from '../common/ColorHex';
import { Theme } from '../common/Theme';
import { AppColorPicker } from './ColorPickerDialog';

/** 线宽限幅（与 Android MeasureDetailDialog.WIDTH_MIN/MAX 同值） */
const WIDTH_MIN: number = 1;
const WIDTH_MAX: number = 10;

@CustomDialog
export struct MeasureDetailDialog {
  controller: CustomDialogController;
  title: string = '';
  /** 类型显示名（点位测量/距离测量/面积测量） */
  typeText: string = '';
  /** 量算文本，空表示不显示该行 */
  geometryText: string = '';
  /** 点测量无线要素 → 隐藏线宽步进 */
  widthEditable: boolean = true;
  initialColor: number = 0xFF57ACFD;
  initialLineWidth: number = 3;
  onSave: (color: number, lineWidth: number) => void = (): void => {};
  onDelete: () => void = (): void => {};

  @State color: number = 0xFF57ACFD;
  @State lineWidth: number = 3;
  private picker: CustomDialogController | undefined = undefined;

  aboutToAppear(): void {
    this.color = this.initialColor;
    this.lineWidth = Math.max(WIDTH_MIN, Math.min(WIDTH_MAX, this.initialLineWidth));
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

  build() {
    Column() {
      Row() {
        Text(this.title.length > 0 ? this.title : '测量详情')
          .fontSize(Theme.FONT_TITLE)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.TEXT)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text('×')
          .fontSize(20)
          .fontColor(Theme.TEXT_SUB)
          .padding({ left: 10, right: 4 })
          .onClick((): void => {
            this.controller.close();
          })
      }
      .width('100%')

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

      Row({ space: 10 }) {
        Button('删除')
          .layoutWeight(1)
          .height(38)
          .fontSize(Theme.FONT)
          .fontColor(Theme.TEXT_ON_DARK)
          .backgroundColor(Theme.DANGER)
          .onClick((): void => {
            this.onDelete();
            this.controller.close();
          })
        Button('保存')
          .layoutWeight(1)
          .height(38)
          .fontSize(Theme.FONT)
          .fontColor(Theme.TEXT_ON_DARK)
          .backgroundColor(Theme.PRIMARY)
          .onClick((): void => {
            this.onSave(this.color, this.lineWidth);
            this.controller.close();
          })
      }
      .width('100%')
      .margin({ top: 16 })
    }
    .width('100%')
    .padding(Theme.PAD)
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(Theme.CARD)
    .borderRadius(Theme.RADIUS)
  }
}
