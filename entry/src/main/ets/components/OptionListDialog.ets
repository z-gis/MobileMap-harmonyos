// OptionListDialog.ets —— 可滚动的列表选择对话框（对应 Android AlertDialog.setItems）。
//
// Ui.items 走 promptAction.showDialog，按钮数固定上限 6；工程合并源候选这类「条数不定」的列表
// 放不下，故单独成组件：标题 + 可选说明 + 单选列表（超高滚动）+ 取消。点项即回下标并关闭。

import { Theme } from '../common/Theme';

/** 列表可视高度上限（vp）：超出内部滚动，避免对话框顶满屏 */
const MAX_LIST_HEIGHT: number = 300;

@CustomDialog
export struct OptionListDialog {
  /** @CustomDialog 要求必须声明 controller；本组件不自关，统一由持有者关闭 */
  controller: CustomDialogController;
  title: string = '';
  /** 说明文案（为空不显示） */
  hint: string = '';
  /** 候选项文本（顺序即回调下标） */
  options: string[] = [];
  /** 候选为空时的提示 */
  emptyText: string = '没有可选项';
  /** 选中回调（参数为 options 下标） */
  onPick: (index: number) => void = (): void => {};
  /** 取消回调（点「取消」或返回键关闭时触发） */
  onCancel: () => void = (): void => {};

  build() {
    Column({ space: 10 }) {
      Text(this.title)
        .fontSize(Theme.FONT_TITLE)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.TEXT)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      if (this.hint.length > 0) {
        Text(this.hint)
          .fontSize(Theme.FONT_SUB)
          .fontColor(Theme.TEXT_SUB)
      }

      if (this.options.length === 0) {
        Text(this.emptyText)
          .fontSize(Theme.FONT)
          .fontColor(Theme.TEXT_HINT)
          .padding({ top: 12, bottom: 12 })
      } else {
        List({ space: 4 }) {
          ForEach(this.options, (name: string, index: number): void => {
            ListItem() {
              Text(name)
                .fontSize(Theme.FONT)
                .fontColor(Theme.TEXT)
                .width('100%')
                .height(40)
                .padding({ left: 10, right: 10 })
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .backgroundColor(Theme.SUBTLE)
                .borderRadius(6)
                .onClick((): void => {
                  this.onPick(index);
                })
            }
          }, (name: string, index: number): string => `${index}|${name}`)
        }
        .width('100%')
        .constraintSize({ maxHeight: MAX_LIST_HEIGHT })
        .scrollBar(BarState.Auto)
      }

      Button('取消')
        .width('100%')
        .height(38)
        .fontSize(Theme.FONT)
        .fontColor(Theme.TEXT_SUB)
        .backgroundColor(Theme.SUBTLE)
        .onClick((): void => {
          this.onCancel();
        })
    }
    .width('86%')
    .padding(Theme.PAD)
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(Theme.CARD)
    .borderRadius(Theme.RADIUS)
  }
}
