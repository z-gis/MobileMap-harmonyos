// MapSourceEditDialog.ets —— 添加/编辑地图源对话框（对应 Android ui.dialog.MapSourceEditDialog + dialog_map_source.xml）。
//
// 字段与校验与 Android 一致：名称、网址、类型（image/png | image/jpeg）、Token1、Token2；
// 名称与网址必填，其余可空。系统自带图源名称不可改（nameEditable=false）。
// 本对话框只收集输入并回传，落库交宿主（宿主还需处理「天地图 Token 全局同步」与「唯一可见」语义）。

import { Theme } from '../common/Theme';
import { Ui } from '../common/Ui';
import { MapSource } from '../doc/DocModels';

/** 可选瓦片格式（与 Android IMAGE_FORMATS 同序同值） */
const IMAGE_FORMATS: string[] = ['image/png', 'image/jpeg'];

@CustomDialog
export struct MapSourceEditDialog {
  controller: CustomDialogController;
  /** 待编辑图源；undefined 表示新增 */
  source: MapSource | undefined = undefined;
  /** 系统内置图源名称锁定（Android: etName.isEnabled = nameEditable） */
  nameEditable: boolean = true;
  onConfirmSource: (name: string, url: string, imageFormat: string,
    token1: string, token2: string) => void = (): void => {};

  @State nameText: string = '';
  @State urlText: string = '';
  @State token1Text: string = '';
  @State token2Text: string = '';
  @State formatIndex: number = 0;

  aboutToAppear(): void {
    const src: MapSource | undefined = this.source;
    if (src === undefined) {
      return;
    }
    this.nameText = src.name ?? '';
    this.urlText = src.url ?? '';
    this.token1Text = src.token1 ?? '';
    this.token2Text = src.token2 ?? '';
    const idx: number = IMAGE_FORMATS.indexOf(src.imageFormat ?? '');
    if (idx >= 0) {
      this.formatIndex = idx;
    }
  }

  private confirm(): void {
    const name: string = this.nameText.trim();
    const url: string = this.urlText.trim();
    if (name.length === 0) {
      Ui.toast('地图源名称不能为空');
      return;
    }
    if (url.length === 0) {
      Ui.toast('地图源网址不能为空');
      return;
    }
    this.onConfirmSource(name, url, IMAGE_FORMATS[this.formatIndex],
      this.token1Text.trim(), this.token2Text.trim());
    this.controller.close();
  }

  /** 名称锁定时的视觉降级：仍可显示内容，但不接受输入（与 Android setEnabled(false) 同义） */
  @Builder
  field(label: string, placeholder: string, value: string, editable: boolean,
    onChange: (v: string) => void) {
    Row() {
      Text(label)
        .fontSize(Theme.FONT_SUB)
        .fontColor(Theme.TEXT_SUB)
        .width(64)
      TextInput({ text: value, placeholder: placeholder })
        .layoutWeight(1)
        .height(36)
        .fontSize(Theme.FONT_SUB)
        .backgroundColor(editable ? Theme.SUBTLE : Theme.BG)
        .fontColor(editable ? Theme.TEXT : Theme.TEXT_HINT)
        .enabled(editable)
        .onChange((v: string): void => {
          onChange(v);
        })
    }
    .width('100%')
    .margin({ bottom: 8 })
  }

  build() {
    Column() {
      Text(this.source === undefined ? '添加地图源' : '编辑地图源')
        .fontSize(Theme.FONT_TITLE)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.TEXT)
        .margin({ bottom: 12 })

      this.field('名称', '地图源名称', this.nameText, this.nameEditable,
        (v: string): void => {
          this.nameText = v;
        })
      this.field('网址', '含 {z}/{x}/{y} 占位符的瓦片地址', this.urlText, true,
        (v: string): void => {
          this.urlText = v;
        })

      Row() {
        Text('类型')
          .fontSize(Theme.FONT_SUB)
          .fontColor(Theme.TEXT_SUB)
          .width(64)
        Select(IMAGE_FORMATS.map((f: string): SelectOption => {
          const opt: SelectOption = { value: f };
          return opt;
        }))
          .selected(this.formatIndex)
          .value(IMAGE_FORMATS[this.formatIndex])
          .font({ size: Theme.FONT_SUB })
          .fontColor(Theme.TEXT)
          .layoutWeight(1)
          .onSelect((index: number): void => {
            this.formatIndex = index;
          })
      }
      .width('100%')
      .margin({ bottom: 8 })

      this.field('Token1', '选填', this.token1Text, true,
        (v: string): void => {
          this.token1Text = v;
        })
      this.field('Token2', '选填', this.token2Text, true,
        (v: string): void => {
          this.token2Text = v;
        })

      Text('天地图系列图源共用 Token，修改后会自动同步到全部天地图图层。')
        .fontSize(Theme.FONT_SUB)
        .fontColor(Theme.TEXT_HINT)
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
      .margin({ top: 14 })
    }
    .width('100%')
    .padding(Theme.PAD)
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(Theme.CARD)
    .borderRadius(Theme.RADIUS)
  }
}
