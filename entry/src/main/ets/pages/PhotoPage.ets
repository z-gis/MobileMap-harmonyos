// PhotoPage.ets —— 拍照点位管理页（对应 Android ui.dialog.MediaManageDialog）。
//
// 结构与 Android 一致：按分组分节展示（真实分组在前、未分组虚拟节在后），
// 节头可折叠 / 整组显隐 / 分享 / 重命名 / 删除，节内是点位行（显隐 / 缩放 / 照片 / 删除）。
// 与 Android 的差异只在承载形式：Android 是 BottomSheet，鸿蒙侧做成整页；
// 缩放经 MapServices 直接驱动主地图页相机，看照片改走独立浏览页 PhotoViewerPage。
//
// 每行都重建为 MediaRow 快照：MediaPlacemark/MediaGroup 的 visible/name 是普通字段，
// 改值不触发 ArkUI 刷新，故所有影响渲染的值都编进 ForEach 键。

import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { AppDirs } from '../common/AppDirs';
import { Theme } from '../common/Theme';
import { TimeText } from '../common/TimeText';
import { Ui } from '../common/Ui';
import { MapServices } from '../map/MapServices';
import { MediaAttachment, MediaGroup, MediaPlacemark, MediaStore } from '../media/MediaStore';
import { MediaPackage } from '../media/MediaPackage';
import { MediaEditDialog } from '../components/MediaEditDialog';
import { NameEditDialog } from '../components/NameEditDialog';
import { PhotoViewerParams } from './RouteParams';
import { TitleBar } from '../components/TitleBar';

/** 未分组虚拟节 id */
const UNGROUPED: number = MediaStore.UNGROUPED_ID;
/** 未分组节名（Android 同文案） */
const UNGROUPED_NAME: string = '未分组';

/** 列表行快照：节头与点位行共用一个模型（字段按 kind 取用） */
class MediaRow {
  header: boolean = false;
  /** 节头：分组主键（未分组节为 UNGROUPED） */
  groupId: number = UNGROUPED;
  groupName: string = '';
  /** 节头：该节点位数与照片总数 */
  count: number = 0;
  photoCount: number = 0;
  /** 节头：组内点位是否全部可见（整组开关回显） */
  allVisible: boolean = true;
  /** 节头：是否折叠 */
  collapsed: boolean = false;
  /** 行：点位字段 */
  placemarkId: number = 0;
  name: string = '';
  subtitle: string = '';
  visible: boolean = true;
  latitude: number = Number.NaN;
  longitude: number = Number.NaN;
  itemPhotos: number = 0;

  key(): string {
    if (this.header) {
      return `h|${this.groupId}|${this.groupName}|${this.count}|${this.photoCount}`
        + `|${this.allVisible}|${this.collapsed}`;
    }
    return `p|${this.placemarkId}|${this.name}|${this.visible}|${this.subtitle}|${this.itemPhotos}`;
  }
}

@Entry
@Component
struct PhotoPage {
  /** 底部导航条避让高度（vp）：主窗口是全屏布局，底部「返回地图」按钮要让开导航条 */
  @StorageProp('bottomInsetVp') bottomInset: number = 0;
  @State rows: MediaRow[] = [];
  @State loaded: boolean = false;
  /** 折叠的分组 id 集合（用数组而非 Set：@State 的 Set 变更不触发刷新） */
  @State collapsedIds: number[] = [];

  /** 原始记录：分享与编辑需要 attachments / 经纬度等完整字段 */
  private groups: MediaGroup[] = [];
  private placemarks: MediaPlacemark[] = [];
  private editDialog: CustomDialogController | undefined = undefined;
  private groupDialog: CustomDialogController | undefined = undefined;

  aboutToAppear(): void {
    this.reload();
  }

  onPageShow(): void {
    // 地图上新拍照/删除点位后返回本页需重新取库
    if (this.loaded) {
      this.reload();
    }
  }

  private store(): Promise<MediaStore> {
    const ctx: common.UIAbilityContext =
      this.getUIContext().getHostContext() as common.UIAbilityContext;
    return MediaStore.getInstance(ctx);
  }

  private context(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  private reload(): void {
    this.store().then(async (store: MediaStore): Promise<void> => {
      this.groups = await store.loadGroups();
      this.placemarks = await store.loadPlacemarks();
      this.rows = this.buildRows();
      this.loaded = true;
    });
  }

  /** 真实分组在前（按建组顺序），未分组虚拟节在最后 */
  private buildRows(): MediaRow[] {
    const rows: MediaRow[] = [];
    for (let i = 0; i < this.groups.length; i++) {
      const g: MediaGroup = this.groups[i];
      const members: MediaPlacemark[] = this.inGroup(g.id);
      rows.push(this.headerRow(g.id, g.name, members));
      if (!this.isCollapsed(g.id)) {
        this.appendPlacemarks(rows, members);
      }
    }
    const rest: MediaPlacemark[] = this.inGroup(UNGROUPED);
    rows.push(this.headerRow(UNGROUPED, UNGROUPED_NAME, rest));
    if (!this.isCollapsed(UNGROUPED)) {
      this.appendPlacemarks(rows, rest);
    }
    return rows;
  }

  private headerRow(groupId: number, name: string, members: MediaPlacemark[]): MediaRow {
    const row: MediaRow = new MediaRow();
    row.header = true;
    row.groupId = groupId;
    row.groupName = name;
    row.count = members.length;
    row.collapsed = this.isCollapsed(groupId);
    let photos: number = 0;
    let allVisible: boolean = members.length > 0;
    for (let i = 0; i < members.length; i++) {
      photos += this.photoCount(members[i]);
      allVisible = allVisible && members[i].visible;
    }
    row.photoCount = photos;
    row.allVisible = allVisible;
    return row;
  }

  private appendPlacemarks(rows: MediaRow[], members: MediaPlacemark[]): void {
    for (let i = 0; i < members.length; i++) {
      const p: MediaPlacemark = members[i];
      const photos: number = this.photoCount(p);
      const row: MediaRow = new MediaRow();
      row.header = false;
      row.placemarkId = p.id;
      row.name = p.displayName();
      row.visible = p.visible;
      row.latitude = p.latitude;
      row.longitude = p.longitude;
      row.itemPhotos = photos;
      row.subtitle = `${TimeText.dateTime(p.createdTime)}　·　`
        + `${photos > 0 ? `${photos}张照片` : '无照片'}`;
      rows.push(row);
    }
  }

  private inGroup(groupId: number): MediaPlacemark[] {
    const out: MediaPlacemark[] = [];
    for (let i = 0; i < this.placemarks.length; i++) {
      if (this.placemarks[i].groupId === groupId) {
        out.push(this.placemarks[i]);
      }
    }
    return out;
  }

  private findPlacemark(id: number): MediaPlacemark | undefined {
    for (let i = 0; i < this.placemarks.length; i++) {
      if (this.placemarks[i].id === id) {
        return this.placemarks[i];
      }
    }
    return undefined;
  }

  private photoCount(p: MediaPlacemark): number {
    let n: number = 0;
    for (let i = 0; i < p.attachments.length; i++) {
      if (p.attachments[i].type === MediaAttachment.TYPE_PHOTO) {
        n++;
      }
    }
    return n;
  }

  private isCollapsed(groupId: number): boolean {
    return this.collapsedIds.indexOf(groupId) >= 0;
  }

  private toggleCollapse(groupId: number): void {
    const idx: number = this.collapsedIds.indexOf(groupId);
    if (idx >= 0) {
      this.collapsedIds.splice(idx, 1);
    } else {
      this.collapsedIds.push(groupId);
    }
    this.collapsedIds = this.collapsedIds.slice();
    this.rows = this.buildRows();
  }

  // ── 分组动作 ────────────────────────────────────────────────────

  private openNewGroup(): void {
    this.groupDialog = new CustomDialogController({
      builder: NameEditDialog({
        title: '新建分组',
        label: '分组',
        placeholder: '请输入分组名称',
        onConfirmName: (name: string): void => {
          this.store().then(async (store: MediaStore): Promise<void> => {
            const id: number = await store.insertGroup(name, Date.now());
            if (id < 0) {
              Ui.toast('新建分组失败');
              return;
            }
            await this.reload();
            Ui.toast(`已新建分组：${name}`);
          });
        },
      }),
      customStyle: true,
      alignment: DialogAlignment.Center,
      autoCancel: true,
    });
    this.groupDialog.open();
  }

  private openRenameGroup(row: MediaRow): void {
    this.groupDialog = new CustomDialogController({
      builder: NameEditDialog({
        title: '重命名分组',
        label: '分组',
        initialValue: row.groupName,
        placeholder: '请输入分组名称',
        onConfirmName: (name: string): void => {
          this.store().then(async (store: MediaStore): Promise<void> => {
            await store.updateGroupName(row.groupId, name);
            await this.reload();
            Ui.toast('已重命名分组');
          });
        },
      }),
      customStyle: true,
      alignment: DialogAlignment.Center,
      autoCancel: true,
    });
    this.groupDialog.open();
  }

  private async removeGroup(row: MediaRow): Promise<void> {
    const ok: boolean = await Ui.confirm('删除分组',
      `删除分组“${row.groupName}”后，组内拍照标识不会被删除，将移到“${UNGROUPED_NAME}”。是否继续？`, '删除');
    if (!ok) {
      return;
    }
    const store: MediaStore = await this.store();
    await store.deleteGroup(row.groupId);
    await this.reload();
    Ui.toast('已删除分组');
  }

  private toggleGroupVisible(row: MediaRow, visible: boolean): void {
    this.store().then(async (store: MediaStore): Promise<void> => {
      await store.setGroupPlacemarksVisible(row.groupId, visible);
      await this.reload();
    });
  }

  private shareGroup(row: MediaRow): void {
    const members: MediaPlacemark[] = this.inGroup(row.groupId);
    if (members.length === 0) {
      Ui.toast('该分组没有拍照标识');
      return;
    }
    const name: string | null = row.groupId === UNGROUPED ? null : row.groupName;
    MediaPackage.shareGroup(this.context(), name, members).then((): void => {
      Ui.toast('已生成分组数据包');
    });
  }

  // ── 点位动作 ────────────────────────────────────────────────────

  private openEdit(row: MediaRow): void {
    const placemark: MediaPlacemark | undefined = this.findPlacemark(row.placemarkId);
    if (placemark === undefined) {
      return;
    }
    this.editDialog = new CustomDialogController({
      builder: MediaEditDialog({
        placemark: placemark,
        groups: this.groups,
        onConfirmEdit: (name: string, groupId: number, newGroupName: string): void => {
          this.applyEdit(placemark.id, name, groupId, newGroupName);
        },
      }),
      customStyle: true,
      alignment: DialogAlignment.Center,
      autoCancel: true,
    });
    this.editDialog.open();
  }

  /** 新建分组要先落库拿到主键，再把点位改到该组（对话框内的临时组名尚未入库） */
  private applyEdit(placemarkId: number, name: string, groupId: number, newGroupName: string): void {
    this.store().then(async (store: MediaStore): Promise<void> => {
      let target: number = groupId;
      if (newGroupName.length > 0) {
        const created: number = await store.insertGroup(newGroupName, Date.now());
        if (created < 0) {
          Ui.toast('新建分组失败');
          return;
        }
        target = created;
      }
      await store.updatePlacemarkName(placemarkId, name);
      await store.updatePlacemarkGroup(placemarkId, target);
      await this.reload();
      Ui.toast('已保存');
    });
  }

  private togglePlacemarkVisible(row: MediaRow, visible: boolean): void {
    this.store().then(async (store: MediaStore): Promise<void> => {
      await store.updatePlacemarkVisible(row.placemarkId, visible);
      await this.reload();
    });
  }

  private zoomTo(row: MediaRow): void {
    const camera = MapServices.instance.camera;
    if (camera === undefined || !Number.isFinite(row.latitude) || !Number.isFinite(row.longitude)) {
      Ui.toast('地图未就绪，无法缩放');
      return;
    }
    camera.moveToLocation(row.latitude, row.longitude);
    Ui.toast('已缩放，返回地图查看');
  }

  private openPhotos(row: MediaRow): void {
    const params: PhotoViewerParams = new PhotoViewerParams();
    params.placemarkId = row.placemarkId;
    params.initialIndex = 0;
    router.pushUrl({ url: 'pages/PhotoViewerPage', params: params });
  }

  private async removePlacemark(row: MediaRow): Promise<void> {
    const ok: boolean = await Ui.confirm('删除拍照标识',
      `删除“${row.name}”后该点位及其全部照片文件将一并删除，是否继续？`, '删除');
    if (!ok) {
      return;
    }
    const store: MediaStore = await this.store();
    await store.deletePlacemark(row.placemarkId);
    // 附件目录随点位删除（库内只记路径，文件归调用方清理，与 Android 同口径）
    AppDirs.removeTree(`${AppDirs.mediaDir()}/${row.placemarkId}`);
    await this.reload();
    Ui.toast('已删除');
  }

  build() {
    Column() {
      TitleBar({
        title: '拍照管理',
        subtitle: this.placemarks.length > 0 ? `共 ${this.placemarks.length} 个拍照标识` : '暂无拍照标识',
        // 箭头函数包裹传入：直传 this.barActions 会丢失宿主 this 绑定，点「新建分组」时
        // 槽内 this 指向 TitleBar，this.openNewGroup() 就成 undefined
        actions: (): void => {
          this.barActions();
        },
      })

      if (!this.loaded) {
        Column() {
          LoadingProgress()
            .width(36)
            .height(36)
            .color(Theme.PRIMARY)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.placemarks.length === 0 && this.groups.length === 0) {
        Column() {
          Text('暂无拍照标识')
            .fontSize(Theme.FONT)
            .fontColor(Theme.TEXT_SUB)
          Text('在地图上点「拍照」定位拍照，照片即出现在此列表')
            .fontSize(Theme.FONT_SUB)
            .fontColor(Theme.TEXT_HINT)
            .margin({ top: Theme.GAP })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: Theme.GAP }) {
          ForEach(this.rows, (row: MediaRow): void => {
            ListItem() {
              if (row.header) {
                this.groupCard(row)
              } else {
                this.placemarkCard(row)
              }
            }
          }, (row: MediaRow): string => row.key())
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .padding({ left: Theme.PAD, right: Theme.PAD, top: Theme.GAP, bottom: Theme.PAD })
      }

      Button('返回地图')
        .width('100%')
        .height(44)
        .fontSize(Theme.FONT)
        .fontColor(Theme.TEXT_ON_DARK)
        .backgroundColor(Theme.PRIMARY)
        .borderRadius(Theme.RADIUS)
        .margin({ left: Theme.PAD, right: Theme.PAD, top: Theme.GAP, bottom: Theme.PAD })
        .onClick((): void => {
          router.back();
        })
    }
    .width('100%')
    .height('100%')
    .padding({ bottom: this.bottomInset })
    .backgroundColor(Theme.BG)
  }

  @Builder
  barActions() {
    Text('新建分组')
      .fontSize(Theme.FONT_SUB)
      .fontColor(Theme.TEXT_ON_DARK)
      .height(28)
      .padding({ left: 10, right: 10 })
      .backgroundColor('#33FFFFFF')
      .borderRadius(6)
      .onClick((): void => {
        this.openNewGroup();
      })
  }

  @Builder
  groupCard(row: MediaRow) {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(16)
          .fontColor([Theme.TEXT_SUB])
          .rotate({ angle: row.collapsed ? 0 : 90 })

        Column({ space: 2 }) {
          Text(row.groupName)
            .fontSize(Theme.FONT)
            .fontColor(Theme.TEXT)
            .fontWeight(FontWeight.Medium)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(row.count > 0 ? `${row.count}个拍照标识　·　${row.photoCount}张照片` : '无拍照标识')
            .fontSize(Theme.FONT_SUB)
            .fontColor(Theme.TEXT_SUB)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Toggle({ type: ToggleType.Switch, isOn: row.allVisible })
          .selectedColor(Theme.PRIMARY)
          .enabled(row.count > 0)
          .onChange((v: boolean): void => {
            // 节重建时 Toggle 会按初值回调一次，与当前值相同不写库
            if (v !== row.allVisible) {
              this.toggleGroupVisible(row, v);
            }
          })
      }
      .width('100%')
      .onClick((): void => {
        this.toggleCollapse(row.groupId);
      })

      Flex({ wrap: FlexWrap.Wrap }) {
        this.chip('分享', Theme.PRIMARY_DARK, Theme.CARD, (): void => {
          this.shareGroup(row);
        })
        if (row.groupId !== UNGROUPED) {
          this.chip('重命名', Theme.PRIMARY_DARK, Theme.CARD, (): void => {
            this.openRenameGroup(row);
          })
          this.chip('删除分组', Theme.DANGER, Theme.CARD, (): void => {
            this.removeGroup(row);
          })
        }
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(10)
    .backgroundColor(Theme.SUBTLE)
    .borderRadius(Theme.RADIUS)
  }

  @Builder
  placemarkCard(row: MediaRow) {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        Text(row.name)
          .fontSize(Theme.FONT)
          .fontColor(row.visible ? Theme.TEXT : Theme.TEXT_HINT)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
          .onClick((): void => {
            this.openEdit(row);
          })

        Toggle({ type: ToggleType.Switch, isOn: row.visible })
          .selectedColor(Theme.PRIMARY)
          .onChange((v: boolean): void => {
            if (v !== row.visible) {
              this.togglePlacemarkVisible(row, v);
            }
          })
      }
      .width('100%')

      Text(row.subtitle)
        .fontSize(Theme.FONT_SUB)
        .fontColor(Theme.TEXT_SUB)
        .width('100%')

      Flex({ wrap: FlexWrap.Wrap }) {
        if (row.itemPhotos > 0) {
          this.chip(`照片(${row.itemPhotos})`, Theme.PRIMARY_DARK, Theme.SUBTLE, (): void => {
            this.openPhotos(row);
          })
        }
        this.chip('编辑', Theme.TEXT_SUB, Theme.SUBTLE, (): void => {
          this.openEdit(row);
        })
        this.chip('缩放', Theme.TEXT_SUB, Theme.SUBTLE, (): void => {
          this.zoomTo(row);
        })
        this.chip('删除', Theme.DANGER, Theme.SUBTLE, (): void => {
          this.removePlacemark(row);
        })
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(12)
    .backgroundColor(Theme.CARD)
    .borderRadius(Theme.RADIUS)
  }

  @Builder
  chip(label: string, color: string, bg: string, onTap: () => void) {
    Text(label)
      .fontSize(Theme.FONT_SUB)
      .fontColor(color)
      .textAlign(TextAlign.Center)
      .height(26)
      .padding({ left: 10, right: 10 })
      .backgroundColor(bg)
      .borderRadius(6)
      .margin({ right: 6, top: 2 })
      .onClick((): void => {
        onTap();
      })
  }
}
