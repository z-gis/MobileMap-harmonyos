// LayerLevelDialog.ets —— 矢量图层「级别可见性」设置对话框（对应 Android LayerManageDialog.onLevelClick）。
//
// Android 用 NumberPicker(0..20) + AlertDialog 的三个按钮；鸿蒙侧无 NumberPicker，改用 Select 下拉
// （21 个级别，下拉比滚动选择器在窄屏上更好点）。语义与提示文本逐条照搬：
//  · 低于设定级别时隐藏该图层——整层入屏、要素密集成片时没有辨识意义；
//  · 同时回显「自动计算级别」与「当前生效级别」，让用户知道自己设的值与算法值的差距；
//  · 「恢复自动」把 userMinDisplayLevel 置回 -1，生效值回退自动值（Android setNeutralButton）。
// 自动值未知（图层尚未按四至算出级别，如新导入未渲染）时显示「未知」，与 Android layer_info_size_unknown 同义。

import { Theme, Widget } from '../common/Theme';
import { Ui } from '../common/Ui';

/** 不限制级别（LayerInfo.UNSET_LEVEL） */
const UNSET_LEVEL: number = -1;

@CustomDialog
export struct LayerLevelDialog {
  controller: CustomDialogController;
  /** 图层名（标题副信息，避免误设到别的图层） */
  layerName: string = '';
  /** 自动计算级别，-1 表示未知 */
  autoLevel: number = UNSET_LEVEL;
  /** 当前生效级别，-1 表示不限制 */
  effectiveLevel: number = UNSET_LEVEL;
  /** 打开时定位的级别：用户值 > 自动值 > 0（与 Android init 同序） */
  initialLevel: number = 0;
  onConfirmLevel: (level: number) => void = (): void => {};
  onResetAuto: () => void = (): void => {};

  @State level: number = 0;

  aboutToAppear(): void {
    this.level = Math.max(Widget.LEVEL_MIN, Math.min(Widget.LEVEL_MAX, this.initialLevel));
  }

  private levelOptions(): SelectOption[] {
    const options: SelectOption[] = [];
    for (let i = Widget.LEVEL_MIN; i <= Widget.LEVEL_MAX; i++) {
      options.push({ value: `${i} 级` });
    }
    return options;
  }

  private autoText(): string {
    return this.autoLevel >= 0 ? `${this.autoLevel}` : '未知';
  }

  private effectiveText(): string {
    return this.effectiveLevel >= 0 ? `${this.effectiveLevel}` : '不限制';
  }

  build() {
    Column({ space: 10 }) {
      Text('级别可见性')
        .fontSize(Theme.FONT_TITLE)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.TEXT)

      if (this.layerName.length > 0) {
        Text(this.layerName)
          .fontSize(Theme.FONT_SUB)
          .fontColor(Theme.TEXT_SUB)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }

      Text('低于设定级别时隐藏该图层（整层入屏、要素密集成片无辨识意义）。')
        .fontSize(Theme.FONT_SUB)
        .fontColor(Theme.TEXT_SUB)
        .width('100%')

      Row() {
        Text(`自动计算级别：${this.autoText()}`)
          .fontSize(Theme.FONT_SUB)
          .fontColor(Theme.TEXT_HINT)
          .layoutWeight(1)
        Text(`当前生效级别：${this.effectiveText()}`)
          .fontSize(Theme.FONT_SUB)
          .fontColor(Theme.TEXT_HINT)
      }
      .width('100%')

      Select(this.levelOptions())
        .selected(this.level - Widget.LEVEL_MIN)
        .value(`${this.level} 级`)
        .width('100%')
        .font({ size: Theme.FONT })
        .backgroundColor(Theme.SUBTLE)
        .onSelect((index: number): void => {
          this.level = Widget.LEVEL_MIN + index;
        })

      Row({ space: 8 }) {
        Button('恢复自动')
          .height(36)
          .fontSize(Theme.FONT_SUB)
          .fontColor(Theme.PRIMARY_DARK)
          .backgroundColor(Theme.SUBTLE)
          .layoutWeight(1)
          .onClick((): void => {
            this.onResetAuto();
            this.controller.close();
          })

        Button('取消')
          .height(36)
          .fontSize(Theme.FONT_SUB)
          .fontColor(Theme.TEXT_SUB)
          .backgroundColor(Theme.SUBTLE)
          .onClick((): void => {
            this.controller.close();
          })

        Button('确定')
          .height(36)
          .fontSize(Theme.FONT)
          .fontColor(Theme.TEXT_ON_DARK)
          .backgroundColor(Theme.PRIMARY)
          .onClick((): void => {
            this.onConfirmLevel(this.level);
            Ui.toast(`已设为低于 ${this.level} 级时隐藏`);
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
