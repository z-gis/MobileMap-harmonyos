// MediaEditDialog.ets —— 拍照点位编辑对话框（对应 Android ui.dialog.MediaEditDialog）。
//
// 语义与 Android 相同：改点位名称 + 改所属分组，分组下拉首项为「未分组」，
// 「+」用于即时新建分组（新建名回填到下拉并选中，尚未落库）。
// 本对话框只做输入收集与校验，落库交宿主：新建分组要先拿 groupId 再改点位，
// 编排（含未分组哨兵值）留在宿主更清楚，也便于宿主一次刷新叠加层。

import { Theme } from '../common/Theme';
import { Ui } from '../common/Ui';
import { MediaGroup, MediaPlacemark, MediaStore } from '../media/MediaStore';

/** 分组下拉首项文本（对应 Android 的「未分组」，选中即 groupId = UNGROUPED_ID） */
const GROUP_NONE: string = '未分组';

@CustomDialog
export struct MediaEditDialog {
  controller: CustomDialogController;
  /** 待编辑点位（只读，用于回显名称与当前分组） */
  placemark: MediaPlacemark | undefined = undefined;
  /** 现有分组（宿主加载后下发） */
  @Prop groups: MediaGroup[] = [];
  /** 确认回调：新名称、目标分组、需即时新建的分组名（空表示不新建） */
  onConfirmEdit: (name: string, groupId: number, newGroupName: string) => void =
    (): void => {};

  @State nameText: string = '';
  @State groupId: number = MediaStore.UNGROUPED_ID;
  @State showNewGroup: boolean = false;
  @State newGroupName: string = '';
  /** 新建分组的临时项：下拉需立刻可选到它，故并入选项列表（不落库，由宿主创建） */
  @State pendingGroupName: string = '';

  aboutToAppear(): void {
    const p: MediaPlacemark | undefined = this.placemark;
    if (p !== undefined) {
      this.nameText = p.name;
      this.groupId = p.groupId;
    }
  }

  /** 下拉选项：未分组 + 既有分组（+ 本次新建未落库的分组） */
  private options(): SelectOption[] {
    const out: SelectOption[] = [{ value: GROUP_NONE }];
    for (let i = 0; i < this.groups.length; i++) {
      out.push({ value: this.groups[i].name });
    }
    if (this.pendingGroupName.length > 0) {
      out.push({ value: this.pendingGroupName });
    }
    return out;
  }

  /** 选项序号 → 分组主键（0 为未分组，末位可能是本次新建名） */
  private idOfIndex(index: number): number {
    if (index === 0) {
      return MediaStore.UNGROUPED_ID;
    }
    if (index <= this.groups.length) {
      return this.groups[index - 1].id;
    }
    return MediaStore.UNGROUPED_ID;
  }

  /** 当前分组主键对应的选项序号（找不到即未分组） */
  private indexOfGroup(): number {
    if (this.groupId === MediaStore.UNGROUPED_ID) {
      return 0;
    }
    for (let i = 0; i < this.groups.length; i++) {
      if (this.groups[i].id === this.groupId) {
        return i + 1;
      }
    }
    return 0;
  }

  private currentGroupLabel(): string {
    const idx: number = this.indexOfGroup();
    if (this.pendingGroupName.length > 0 && idx === this.groups.length + 1) {
      return this.pendingGroupName;
    }
    if (idx === 0) {
      return GROUP_NONE;
    }
    return this.groups[idx - 1].name;
  }

  private confirm(): void {
    const name: string = this.nameText.trim();
    if (name.length === 0) {
      Ui.toast('请输入点位名称');
      return;
    }
    if (this.pendingGroupName.length > 0) {
      this.onConfirmEdit(name, this.groupId, this.pendingGroupName);
    } else {
      this.onConfirmEdit(name, this.groupId, '');
    }
    this.controller.close();
  }

  build() {
    Column() {
      Text('拍照点位')
        .fontSize(Theme.FONT_TITLE)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.TEXT)
        .margin({ bottom: 12 })

      Row() {
        Text('名称')
          .fontSize(Theme.FONT_SUB)
          .fontColor(Theme.TEXT_SUB)
          .width(56)
        TextInput({ text: this.nameText })
          .layoutWeight(1)
          .fontSize(Theme.FONT)
          .backgroundColor(Theme.SUBTLE)
          .height(36)
          .onChange((v: string): void => {
            this.nameText = v;
          })
      }
      .width('100%')
      .margin({ bottom: 8 })

      Row() {
        Text('分组')
          .fontSize(Theme.FONT_SUB)
          .fontColor(Theme.TEXT_SUB)
          .width(56)
        Select(this.options())
          .selected(this.indexOfGroup())
          .value(this.currentGroupLabel())
          .font({ size: Theme.FONT_SUB })
          .fontColor(Theme.TEXT)
          .layoutWeight(1)
          .onSelect((index: number): void => {
            this.groupId = this.idOfIndex(index);
          })
        Text('＋')
          .fontSize(18)
          .fontColor(Theme.PRIMARY_DARK)
          .width(30)
          .height(30)
          .textAlign(TextAlign.Center)
          .backgroundColor(Theme.SUBTLE)
          .borderRadius(6)
          .margin({ left: 6 })
          .onClick((): void => {
            this.showNewGroup = !this.showNewGroup;
          })
      }
      .width('100%')

      if (this.showNewGroup) {
        Row() {
          Text('新分组')
            .fontSize(Theme.FONT_SUB)
            .fontColor(Theme.TEXT_SUB)
            .width(56)
          TextInput({ text: this.newGroupName, placeholder: '输入分组名后点右侧√' })
            .layoutWeight(1)
            .fontSize(Theme.FONT_SUB)
            .backgroundColor(Theme.SUBTLE)
            .height(34)
            .onChange((v: string): void => {
              this.newGroupName = v;
            })
          Text('√')
            .fontSize(18)
            .fontColor(Theme.OK)
            .width(30)
            .height(30)
            .textAlign(TextAlign.Center)
            .onClick((): void => {
              const name: string = this.newGroupName.trim();
              if (name.length === 0) {
                Ui.toast('分组名不能为空');
                return;
              }
              // 新建分组先作为临时项进下拉并选中，落库延后到「确定」由宿主一并完成
              this.pendingGroupName = name;
              this.groupId = MediaStore.UNGROUPED_ID;
              this.showNewGroup = false;
            })
        }
        .width('100%')
        .margin({ top: 6 })
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
