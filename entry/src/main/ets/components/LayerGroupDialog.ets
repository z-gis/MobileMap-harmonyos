// LayerGroupDialog.ets —— 图层移入分组对话框（照 MediaEditDialog 的分组段：Select + 内联新建）。
//
// 只做输入收集：下拉首项「未分组」，「＋」即时新建分组（新建名回填下拉并选中，尚未落库）；
// 落库交宿主一次 update 完成（新建组 + 写 groupId 同一次 save）。

import { Theme } from '../common/Theme';
import { Ui } from '../common/Ui';
import { LayerGroupRecord, LayerInfo } from '../doc/DocModels';

const GROUP_NONE: string = '未分组';
const UNGROUPED_ID: number = LayerInfo.UNGROUPED_ID;

@CustomDialog
export struct LayerGroupDialog {
  controller: CustomDialogController;
  /** 待分组图层名（只读回显） */
  layerName: string = '';
  /** 图层当前所属组 id */
  currentGroupId: number = UNGROUPED_ID;
  /** 现有分组（宿主下发） */
  @Prop groups: LayerGroupRecord[] = [];
  /** 确认回调：目标分组 id、需即时新建的分组名（空表示不新建） */
  onConfirmGroup: (groupId: number, newGroupName: string) => void = (): void => {};

  @State groupId: number = UNGROUPED_ID;
  @State showNewGroup: boolean = false;
  @State newGroupName: string = '';
  @State pendingGroupName: string = '';

  aboutToAppear(): void {
    this.groupId = this.currentGroupId;
  }

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

  private idOfIndex(index: number): number {
    if (index === 0) {
      return UNGROUPED_ID;
    }
    if (index <= this.groups.length) {
      return this.groups[index - 1].id;
    }
    return UNGROUPED_ID;
  }

  private indexOfGroup(): number {
    if (this.groupId === UNGROUPED_ID) {
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
    this.onConfirmGroup(this.groupId, this.pendingGroupName);
    this.controller.close();
  }

  build() {
    Column() {
      Text('图层分组')
        .fontSize(Theme.FONT_TITLE)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.TEXT)
        .margin({ bottom: 12 })

      Text(this.layerName)
        .fontSize(Theme.FONT_SUB)
        .fontColor(Theme.TEXT_SUB)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
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
              this.pendingGroupName = name;
              this.groupId = UNGROUPED_ID;
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