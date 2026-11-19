// RemoveLayerDialog.ets —— 图层移除确认对话框（对应 Android LayerManageDialog.onRemoveLayer 的 AlertDialog）。
//
// 标题 + 确认文案 + 可选「同时删除图层文件」勾选 + 取消/移除。
// offerDelete 为 false（源文件被其他图层共享：同 GDB 要素类/同 gpkg 层/同压缩包 shp，
// 或路径无效）时隐藏勾选，文案沿用「仅从地图移除，不删除源文件」。

import { Theme } from '../common/Theme';

@CustomDialog
export struct RemoveLayerDialog {
  controller: CustomDialogController;
  /** 图层显示名 */
  layerName: string = '';
  /** 是否提供「同时删除图层文件」选项 */
  offerDelete: boolean = false;
  /** 确认回调：deleteFile=勾选且提供选项时为 true */
  onConfirm: (deleteFile: boolean) => void = (): void => {};

  @State deleteFile: boolean = false;

  build() {
    Column({ space: 10 }) {
      Text('移除确认')
        .fontSize(Theme.FONT_TITLE)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.TEXT)

      Text(this.offerDelete
        ? `确定移除图层：${this.layerName} ？`
        : `确定移除图层：${this.layerName} ？（仅从地图移除，不删除源文件）`)
        .fontSize(Theme.FONT)
        .fontColor(Theme.TEXT_SUB)
        .width('100%')

      if (this.offerDelete) {
        Row({ space: 6 }) {
          Checkbox()
            .select(this.deleteFile)
            .selectedColor(Theme.DANGER)
            .width(20)
            .height(20)
            .onChange((v: boolean): void => {
              this.deleteFile = v;
            })
          Text('同时删除图层文件（不可恢复）')
            .fontSize(Theme.FONT)
            .fontColor(Theme.TEXT)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }

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
        Button('移除')
          .layoutWeight(1)
          .height(38)
          .fontSize(Theme.FONT)
          .fontColor(Theme.TEXT_ON_DARK)
          .backgroundColor(Theme.DANGER)
          .onClick((): void => {
            this.onConfirm(this.offerDelete && this.deleteFile);
            this.controller.close();
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