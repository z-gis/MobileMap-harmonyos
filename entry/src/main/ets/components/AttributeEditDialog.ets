// AttributeEditDialog.ets —— 单字段属性值编辑框（对应 Android ui.dialog.AttributeEditDialog）。
//
// Android 用 AlertDialog + 动态 EditText，标题即「编辑 <字段名>」；鸿蒙侧等价物是 @CustomDialog。
// 多行输入（备注类字段常有长文本），确定时原样回传（空串合法：Android 亦允许把属性值清空）。

import { Theme } from '../common/Theme';

@CustomDialog
export struct AttributeEditDialog {
  controller: CustomDialogController;
  /** 字段名（作标题与占位）；不能用 key 作成员名（与内置通用属性重名） */
  fieldKey: string = '';
  initialValue: string = '';
  onConfirmValue: (value: string) => void = (): void => {};

  @State text: string = '';

  aboutToAppear(): void {
    this.text = this.initialValue;
  }

  build() {
    Column() {
      Text(`编辑 ${this.fieldKey}`)
        .fontSize(Theme.FONT_TITLE)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.TEXT)
        .margin({ bottom: 10 })

      TextArea({ text: this.text, placeholder: this.fieldKey })
        .width('100%')
        .height(96)
        .fontSize(Theme.FONT)
        .backgroundColor(Theme.SUBTLE)
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
        Button('保存')
          .layoutWeight(1)
          .height(38)
          .fontSize(Theme.FONT)
          .fontColor(Theme.TEXT_ON_DARK)
          .backgroundColor(Theme.PRIMARY)
          .onClick((): void => {
            this.onConfirmValue(this.text);
            this.controller.close();
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
}
