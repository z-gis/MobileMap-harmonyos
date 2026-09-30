// NameEditDialog.ets —— 单行名称编辑对话框（对应 Android TrackManageDialog.showRenameDialog /
// MediaEditDialog.promptGroupName 这类「只有一个输入框 + 确定/取消」的极简提示框）。
//
// Android 用 EditText 塞进 AlertDialog，这里同构：标题 + 单行输入 + 取消/确定。
// 空值不回调（Android「空名称不保存」口径），确定即关闭。

import { Theme } from '../common/Theme';
import { Ui } from '../common/Ui';

/** 名称长度上限（显示宽度与字段宽度约束下的保守值） */
const MAX_NAME_LENGTH: number = 60;

@CustomDialog
export struct NameEditDialog {
  controller: CustomDialogController;
  /** 标题（如「修改名称」「新建分组」） */
  title: string = '修改名称';
  /** 输入框标签（为空则不显示标签行） */
  label: string = '';
  placeholder: string = '请输入名称';
  initialValue: string = '';
  /** 确定回调（已 trim 且非空） */
  onConfirmName: (name: string) => void = (): void => {};

  @State text: string = '';

  aboutToAppear(): void {
    this.text = this.initialValue;
  }

  private confirm(): void {
    const name: string = this.text.trim();
    if (name.length === 0) {
      Ui.toast(this.placeholder);
      return;
    }
    this.onConfirmName(name);
    this.controller.close();
  }

  build() {
    Column({ space: 10 }) {
      Text(this.title)
        .fontSize(Theme.FONT_TITLE)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.TEXT)

      Row({ space: 8 }) {
        if (this.label.length > 0) {
          Text(this.label)
            .fontSize(Theme.FONT_SUB)
            .fontColor(Theme.TEXT_SUB)
            .width(44)
        }
        TextInput({ text: this.text, placeholder: this.placeholder })
          .layoutWeight(1)
          .height(38)
          .fontSize(Theme.FONT)
          .backgroundColor(Theme.SUBTLE)
          .maxLength(MAX_NAME_LENGTH)
          .onChange((v: string): void => {
            this.text = v;
          })
      }
      .width('100%')

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
