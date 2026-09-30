// NumField.ets —— 「标签 + 数值输入框」行控件（多页复用的数值录入行）。
//
// 用 @Component + @Prop 而非 @Builder：@Builder 的按值入参在父组件状态变化时不会重新下发，
// 而本控件的值常常由程序回填（「移动到」切换坐标系时重算东/北坐标、属性编辑带入原值），
// 必须能随父状态刷新；@Prop 正好提供这条自上而下的同步。

import { Theme } from '../common/Theme';

@Component
export struct NumField {
  /** 左侧标签（空串表示无标签，输入框占满） */
  label: string = '';
  placeholder: string = '';
  /** 标签列宽：同一表单内保持一致才能对齐（各页取值 56~72） */
  labelWidth: number = 56;
  /** 是否为数值输入（小数键盘） */
  numeric: boolean = true;
  @Prop value: string = '';
  onValueChange: (v: string) => void = (): void => {};

  build() {
    Row() {
      if (this.label.length > 0) {
        Text(this.label)
          .fontSize(Theme.FONT_SUB)
          .fontColor(Theme.TEXT_SUB)
          .width(this.labelWidth)
      }
      TextInput({ text: this.value, placeholder: this.placeholder })
        .layoutWeight(1)
        .fontSize(Theme.FONT)
        .type(this.numeric ? InputType.NUMBER_DECIMAL : InputType.Normal)
        .backgroundColor(Theme.SUBTLE)
        .height(36)
        .onChange((v: string): void => {
          this.onValueChange(v);
        })
    }
    .width('100%')
    .margin({ bottom: 8 })
  }
}
