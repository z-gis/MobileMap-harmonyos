// LayerInfoDialog.ets —— 图层信息只读对话框（对应 Android 0.3.0.4 dialog_layer_info.xml）。
//
// 0.3.0.4 起图层信息由「整段文本」改为名称 / 类型 / 大小 / 坐标系 / 路径各项单独成行、每项独立控件。
// Android 的诉求是每项各占一个 TextView；鸿蒙等价为每行的值都是一个可选中、可长按复制的 Text——
// 路径这类长文本能被单独取走，而非整块弹窗文本一起复制（原 Ui.alert 单串 message 做不到逐行复制）。

import { Theme } from '../common/Theme';

/** 图层信息一条（标签 + 值），供逐项成行展示 */
export class LayerInfoItem {
  label: string;
  value: string;

  constructor(label: string, value: string) {
    this.label = label;
    this.value = value;
  }
}

@CustomDialog
export struct LayerInfoDialog {
  controller: CustomDialogController;
  title: string = '图层信息';
  items: LayerInfoItem[] = [];

  build() {
    Column({ space: 10 }) {
      Text(this.title)
        .fontSize(Theme.FONT_TITLE)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.TEXT)
        .width('100%')

      ForEach(this.items, (item: LayerInfoItem, index: number): void => {
        Column({ space: 2 }) {
          Text(item.label)
            .fontSize(Theme.FONT_SUB)
            .fontColor(Theme.TEXT_SUB)
            .width('100%')
          Text(item.value.length > 0 ? item.value : '—')
            .fontSize(Theme.FONT)
            .fontColor(Theme.TEXT)
            .width('100%')
            .copyOption(CopyOptions.LocalDevice)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ top: 6, bottom: 6 })
        .border({
          width: { bottom: index === this.items.length - 1 ? 0 : 1 },
          color: { bottom: Theme.DIVIDER },
        })
      }, (item: LayerInfoItem, index: number): string => `${index}:${item.label}`)

      Button('知道了')
        .height(36)
        .fontSize(Theme.FONT)
        .fontColor(Theme.TEXT_ON_DARK)
        .backgroundColor(Theme.PRIMARY)
        .width('100%')
        .margin({ top: 4 })
        .onClick((): void => {
          this.controller.close();
        })
    }
    .width('86%')
    .padding(Theme.PAD)
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(Theme.CARD)
    .borderRadius(Theme.RADIUS)
  }
}
