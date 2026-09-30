// TrackPage.ets —— 轨迹管理页（对应 Android ui.dialog.TrackManageDialog）。
//
// 行为与 Android 一致：列出库中全部已结束轨迹（记录中的草稿轨迹不作为历史出现），
// 支持重命名、可见性开关（隐藏后地图不渲染）、缩放至轨迹、删除（连同坐标点一并删除）。
// 与 Android 的差异只在承载形式：Android 是AlertDialog 内嵌列表，鸿蒙侧做成整页，
// 缩放动作经 MapServices 直接驱动主地图页相机，返回地图即见结果。
// 列表每行重建为 TrackRow 快照：TrackRecord 的 visible/name 是普通字段，改值不触发刷新。

import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { GeoCalc } from '../common/GeoCalc';
import { Theme } from '../common/Theme';
import { TimeText } from '../common/TimeText';
import { Ui } from '../common/Ui';
import { MapDataStore, TrackRecord } from '../db/MapDataStore';
import { MapServices } from '../map/MapServices';
import { NameEditDialog } from '../components/NameEditDialog';
import { TitleBar } from '../components/TitleBar';

/** 列表行快照（键含影响显示的全部字段，值变即重绘） */
class TrackRow {
  id: number = 0;
  name: string = '';
  subtitle: string = '';
  visible: boolean = true;

  key(): string {
    return `${this.id}|${this.name}|${this.visible}|${this.subtitle}`;
  }
}

@Entry
@Component
struct TrackPage {
  /** 底部导航条避让高度（vp）：主窗口是全屏布局，底部「返回地图」按钮要让开导航条 */
  @StorageProp('bottomInsetVp') bottomInset: number = 0;
  @State rows: TrackRow[] = [];
  @State loaded: boolean = false;
  /** 正在记录的轨迹名（非空表示顶部提示，避免外业中误删当前轨迹） */
  @State recordingTip: string = '';

  private nameDialog: CustomDialogController | undefined = undefined;
  /** 原始记录（缩放/删除需要 points 与 color 等字段，快照行里不带） */
  private records: TrackRecord[] = [];

  aboutToAppear(): void {
    this.reload();
  }

  onPageShow(): void {
    // 从地图端新记录/删除后返回时同步（记录状态也可能已变）
    if (this.loaded) {
      this.reload();
    }
  }

  private store(): Promise<MapDataStore> {
    const ctx: common.UIAbilityContext =
      this.getUIContext().getHostContext() as common.UIAbilityContext;
    return MapDataStore.getInstance(ctx);
  }

  private reload(): void {
    this.store().then(async (store: MapDataStore): Promise<void> => {
      const tracks: TrackRecord[] = await store.loadTracks();
      this.records = tracks;
      const rows: TrackRow[] = [];
      for (let i = 0; i < tracks.length; i++) {
        const t: TrackRecord = tracks[i];
        const row: TrackRow = new TrackRow();
        row.id = t.id;
        row.name = t.name;
        row.visible = t.visible;
        row.subtitle = `${TimeText.dateTime(t.createdTime)}　·　${t.points.length}个点`
          + `　·　${GeoCalc.formatDistance(t.lengthMeters())}`;
        rows.push(row);
      }
      this.rows = rows;
      // 草稿轨迹不在历史列表内，单独取一次作为顶部提示（外业中避免误认为「未记录」而重复开启）
      const draft: TrackRecord | undefined = await store.loadDraftTrack();
      this.recordingTip = draft === undefined ? '' : draft.name;
      this.loaded = true;
    });
  }

  private findRecord(id: number): TrackRecord | undefined {
    for (let i = 0; i < this.records.length; i++) {
      if (this.records[i].id === id) {
        return this.records[i];
      }
    }
    return undefined;
  }

  private openRename(row: TrackRow): void {
    this.nameDialog = new CustomDialogController({
      builder: NameEditDialog({
        title: '修改名称',
        label: '名称',
        initialValue: row.name,
        onConfirmName: (name: string): void => {
          this.store().then(async (store: MapDataStore): Promise<void> => {
            await store.updateTrackName(row.id, name);
            await this.reload();
            Ui.toast('已重命名');
          });
        },
      }),
      customStyle: true,
      alignment: DialogAlignment.Center,
      autoCancel: true,
    });
    this.nameDialog.open();
  }

  private toggleVisible(row: TrackRow, visible: boolean): void {
    this.store().then(async (store: MapDataStore): Promise<void> => {
      await store.updateTrackVisible(row.id, visible);
      await this.reload();
    });
  }

  private zoomTo(row: TrackRow): void {
    const track: TrackRecord | undefined = this.findRecord(row.id);
    const ctl = MapServices.instance.track;
    if (track === undefined || ctl === undefined) {
      Ui.toast('地图未就绪，无法缩放');
      return;
    }
    ctl.zoomToTrack(track);
    Ui.toast('已缩放，返回地图查看');
  }

  private async removeTrack(row: TrackRow): Promise<void> {
    const ok: boolean = await Ui.confirm('删除轨迹',
      `确定删除轨迹：${row.name} ？删除后该轨迹及其全部坐标点将一并删除。`, '删除');
    if (!ok) {
      return;
    }
    const store: MapDataStore = await this.store();
    await store.deleteTrack(row.id);
    await this.reload();
    Ui.toast('已删除轨迹');
  }

  build() {
    Column() {
      TitleBar({
        title: '轨迹管理',
        subtitle: this.rows.length > 0 ? `共 ${this.rows.length} 条历史轨迹` : '暂无历史轨迹',
      })

      if (this.recordingTip.length > 0) {
        Text(`正在记录：${this.recordingTip}`)
          .fontSize(Theme.FONT_SUB)
          .fontColor(Theme.CAPTURE)
          .width('100%')
          .padding({ left: Theme.PAD, right: Theme.PAD, top: Theme.GAP })
      }

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
      } else if (this.rows.length === 0) {
        Column() {
          Text('暂无历史轨迹')
            .fontSize(Theme.FONT)
            .fontColor(Theme.TEXT_SUB)
          Text('在地图上点「轨迹」开始记录，结束后即出现在此列表')
            .fontSize(Theme.FONT_SUB)
            .fontColor(Theme.TEXT_HINT)
            .margin({ top: Theme.GAP })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: Theme.GAP }) {
          ForEach(this.rows, (row: TrackRow): void => {
            ListItem() {
              this.trackCard(row)
            }
          }, (row: TrackRow): string => row.key())
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
  trackCard(row: TrackRow) {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        Text(row.name)
          .fontSize(Theme.FONT)
          .fontColor(Theme.TEXT)
          .fontWeight(FontWeight.Medium)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
          .onClick((): void => {
            this.openRename(row);
          })

        Text('重命名')
          .fontSize(Theme.FONT_SUB)
          .fontColor(Theme.PRIMARY_DARK)
          .onClick((): void => {
            this.openRename(row);
          })

        Toggle({ type: ToggleType.Switch, isOn: row.visible })
          .selectedColor(Theme.PRIMARY)
          .onChange((v: boolean): void => {
            // 行重建时 Toggle 会按初值回调一次，与当前值相同不写库
            if (v !== row.visible) {
              this.toggleVisible(row, v);
            }
          })
      }
      .width('100%')

      Text(row.subtitle)
        .fontSize(Theme.FONT_SUB)
        .fontColor(Theme.TEXT_SUB)
        .width('100%')

      Row({ space: 6 }) {
        Blank()
        this.actionChip('缩放至', Theme.TEXT_SUB, (): void => {
          this.zoomTo(row);
        })
        this.actionChip('删除', Theme.DANGER, (): void => {
          this.removeTrack(row);
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
  actionChip(label: string, color: string, onTap: () => void) {
    Text(label)
      .fontSize(Theme.FONT_SUB)
      .fontColor(color)
      .textAlign(TextAlign.Center)
      .height(26)
      .padding({ left: 10, right: 10 })
      .backgroundColor(Theme.SUBTLE)
      .borderRadius(6)
      .onClick((): void => {
        onTap();
      })
  }
}
