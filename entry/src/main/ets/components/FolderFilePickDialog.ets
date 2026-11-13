// FolderFilePickDialog.ets —— 授权文件夹内的主数据文件选择列表。
//
// 手机系统选择器只授权「点中的那个文件」，无法直读未选中的同名附属（.dbf/.shx/.prj…），
// 故改走 FOLDER 目录授权：用户先选文件夹，本列表只列其中的主数据文件（shp/kml/zip/tif…），
// 勾选后由 VectorFileImporter 在已授权目录下自动收齐同名附属整族拷入。
// 等价 Android 自研文件管理器「只列主文件、点选即整族导入」的交互。

import { Theme } from '../common/Theme';
import { VectorFileImporter } from '../vector/VectorFileImporter';

@CustomDialog
export struct FolderFilePickDialog {
  controller: CustomDialogController;
  /** 文件夹显示名（标题用） */
  folderName: string = '';
  /** 主数据文件完整 URI 列表（已按矢量/栅格白名单过滤） */
  files: string[] = [];
  /** 确定回调：回传勾选的 URI（空数组视为取消） */
  onPick: (uris: string[]) => void = (): void => {};
  onCancel: () => void = (): void => {};

  @State toggled: boolean[] = [];

  aboutToAppear(): void {
    const init: boolean[] = [];
    for (let i = 0; i < this.files.length; i++) {
      // 仅一个主文件时默认勾选，省去一次点击
      init.push(this.files.length === 1);
    }
    this.toggled = init;
  }

  private displayName(u: string): string {
    return VectorFileImporter.fileNameOfUri(u);
  }

  private confirm(): void {
    const picked: string[] = [];
    for (let i = 0; i < this.files.length; i++) {
      if (this.toggled[i]) {
        picked.push(this.files[i]);
      }
    }
    // 不在此 close：本弹窗 this.controller 注入不可靠，统一由宿主用自身控制器关闭
    this.onPick(picked);
  }

  build() {
    Column({ space: 10 }) {
      Text(`选择要导入的数据（${this.folderName}）`)
        .fontSize(Theme.FONT_TITLE)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.TEXT)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')

      Text('只列主数据文件，勾选后自动收齐同名附属（.dbf/.shx/.prj 等）')
        .fontSize(Theme.FONT_SUB)
        .fontColor(Theme.TEXT_SUB)
        .width('100%')

      List({ space: 6 }) {
        ForEach(this.files, (u: string, index: number): void => {
          ListItem() {
            Row({ space: 8 }) {
              Checkbox()
                .select(this.toggled[index])
                .selectedColor(Theme.PRIMARY)
                .onChange((v: boolean): void => {
                  const next: boolean[] = this.toggled.slice();
                  next[index] = v;
                  this.toggled = next;
                })
              Text(this.displayName(u))
                .fontSize(Theme.FONT)
                .fontColor(Theme.TEXT)
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .width('100%')
            .padding(10)
            .backgroundColor(Theme.SUBTLE)
            .borderRadius(Theme.RADIUS)
            .onClick((): void => {
              const next: boolean[] = this.toggled.slice();
              next[index] = !next[index];
              this.toggled = next;
            })
          }
        }, (u: string): string => u)
      }
      .width('100%')
      .height(280)
      .scrollBar(BarState.Auto)

      Row({ space: 10 }) {
        Button('取消')
          .layoutWeight(1)
          .height(38)
          .fontSize(Theme.FONT)
          .fontColor(Theme.TEXT_SUB)
          .backgroundColor(Theme.SUBTLE)
          .onClick((): void => {
            this.onCancel();
          })
        Button('导入')
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
    .width('88%')
    .padding(Theme.PAD)
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(Theme.CARD)
    .borderRadius(Theme.RADIUS)
  }
}