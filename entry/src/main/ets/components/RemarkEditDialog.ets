// RemarkEditDialog.ets —— 多行备注编辑对话框（照片点位 / 测量共用，对应 Android ui.dialog.RemarkEditDialog）。
//
// 与 NameEditDialog 的区别：多行 TextArea、允许空（清空备注即存空串，不拦截）、上限更宽。
// 只做输入收集，落库交宿主：确定即回调（已 trim，可为空）并关闭。

import { Theme } from '../common/Theme';

/** 备注长度上限（gpkg remark 列 TEXT 无硬限，此处取保守显示宽度） */
const MAX_REMARK_LENGTH: number = 500;

@CustomDialog
export struct RemarkEditDialog {
  controller: CustomDialogController;
  /** 标题（如「照片备注」「测量备注」） */
  title: string = '备注';
  placeholder: string = '请输入备注（可留空）';
  initialValue: string = '';
  /** 确定回调（已 trim，允许空串） */
  onConfirmRemark: (remark: string) => void = (): void => {};

  @State text: string = '';

  aboutToAppear(): void {
    this.text = this.initialValue;
  }

  private confirm(): void {
    this.onConfirmRemark(this.text.trim());
    this.controller.close();
  }

  build() {
    Column({ space: 10 }) {
      Text(this.title)
        .fontSize(Theme.FONT_TITLE)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.TEXT)

      TextArea({ text: this.text, placeholder: this.placeholder })
        .width('100%')
        .height(120)
        .fontSize(Theme.FONT)
        .backgroundColor(Theme.SUBTLE)
        .maxLength(MAX_REMARK_LENGTH)
        .onChange((v: string): void => {
          this.text = v;
        })

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
      .margin({ top: 4 })
    }
    .width('86%')
    .padding(Theme.PAD)
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(Theme.CARD)
    .borderRadius(Theme.RADIUS)
  }
}