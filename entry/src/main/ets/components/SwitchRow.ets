// SwitchRow.ets —— 「标题 + 说明 + 开关」设置行（各设置类页面复用）。
//
// 用 @Component + @Prop 而非 @Builder：@Builder 的按值入参在父状态变化时不会重新下发，
// 开关被程序回显（如从文档重新载入配置）时需要能跟随父状态刷新。
// onChange 仅在值确有变化时触发，避免父级回显同一值时形成写盘回环。

import { Theme } from '../common/Theme';

@Component
export struct SwitchRow {
  title: string = '';
  subtitle: string = '';
  /** 当前开关态：由父状态单向同步 */
  @Prop isOn: boolean = false;
  onSwitchChange: (v: boolean) => void = (): void => {};

  build() {
    Row() {
      Column() {
        Text(this.title)
          .fontSize(Theme.FONT)
          .fontColor(Theme.TEXT)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.subtitle.length > 0) {
          Text(this.subtitle)
            .fontSize(Theme.FONT_SUB)
            .fontColor(Theme.TEXT_SUB)
            .margin({ top: 2 })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Toggle({ type: ToggleType.Switch, isOn: this.isOn })
        .selectedColor(Theme.PRIMARY)
        .onChange((v: boolean): void => {
          if (v !== this.isOn) {
            this.onSwitchChange(v);
          }
        })
    }
    .width('100%')
    .padding(12)
    .alignItems(VerticalAlign.Center)
    .backgroundColor(Theme.CARD)
    .borderRadius(Theme.RADIUS)
  }
}
