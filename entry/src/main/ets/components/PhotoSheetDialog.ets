// PhotoSheetDialog.ets —— 拍照点位详情弹层（对应 Android ui.dialog.PhotoSheetDialog）。
//
// 点击地图拍照标识先弹本层（不再直进浏览页）：标题栏 重命名/分享/删除/×，
// 中间照片缩略图网格，点某张进 PhotoViewerPage 全屏浏览（带起始张序）；无照片显示空提示。
// 底部「备注：内容」行整行可点，编辑框由本层自持（同 MeasureDetailDialog 的取色器），确认后就地刷新本行。
// 重命名/删除落库交宿主回调，分享与备注的写库也交宿主（本层不持 ctx）。
// 缩略图路径自解析（磁盘原件优先，缺失则从 gpkg BLOB 解出写缓存），与 PhotoViewerPage 同口径；
// 对话框不持 ctx，由宿主下发 gpkgPath / cacheDir 两个字符串（沿用本工程「弹层只收数据」约定）。
// 改名经 DetailTitleHandle 就地刷新标题，弹层不重建（同 MeasureDetailDialog）。

import { router } from '@kit.ArkUI';
import { fileUri } from '@kit.CoreFileKit';
import fs from '@ohos.file.fs';
import { AppDirs } from '../common/AppDirs';
import { AppLog } from '../common/AppLog';
import { Theme } from '../common/Theme';
import { GpkgDml } from '../project/GpkgDml';
import { PhotoAttachment, PhotoRecord } from '../project/ProjectModels';
import { PhotoViewerParams } from '../pages/RouteParams';
import { DetailTitleHandle } from './MeasureDetailDialog';
import { RemarkEditDialog } from './RemarkEditDialog';

/** 缩略图网格列数（同 Android GRID_SPAN_COUNT） */
const GRID_COLUMNS: number = 3;
/** 单行网格高度（vp） */
const GRID_ROW_HEIGHT: number = 96;
/** 网格高度上限（vp）：超出内部滚动，避免照片过多撑破弹层 */
const GRID_MAX_HEIGHT: number = 320;
/** 备注行空态占位（同 Android REMARK_EMPTY） */
const REMARK_PLACEHOLDER: string = '未填写';

@CustomDialog
export struct PhotoSheetDialog {
  controller: CustomDialogController;
  /** 待展示点位（只读，用于标题/附件/分享判空） */
  placemark: PhotoRecord | undefined = undefined;
  /** 当前工程 gpkg 路径（BLOB 回退取照片字节用） */
  gpkgPath: string = '';
  /** 缓存目录（BLOB 解出写此处供 Image 显示） */
  cacheDir: string = '';
  onRename: () => void = (): void => {};
  /** 备注保存回调（交宿主写库）：备注不上图，宿主无需重建叠加层 */
  onRemark: (remark: string) => void = (): void => {};
  onShare: () => void = (): void => {};
  onDelete: () => void = (): void => {};
  /** 标题就地刷新挂钩（宿主改名成功后 setTitle，弹层不重建） */
  titleHandle: DetailTitleHandle | undefined = undefined;

  @State currentTitle: string = '';
  /** 底部备注行当前内容（编辑确认后就地刷新） */
  @State remark: string = '';
  /** 已解析的可显示照片路径（按附件序，缺失附件跳过） */
  @State paths: string[] = [];
  @State loaded: boolean = false;
  /** 备注编辑弹层（叠在本层之上，本层不关闭） */
  private remarkEditor: CustomDialogController | undefined = undefined;

  aboutToAppear(): void {
    const p: PhotoRecord | undefined = this.placemark;
    this.currentTitle = p !== undefined ? p.name : '';
    this.remark = p !== undefined ? p.remark : '';
    const handle: DetailTitleHandle | undefined = this.titleHandle;
    if (handle !== undefined) {
      handle.bind((t: string): void => {
        this.currentTitle = t;
      });
    }
    this.resolvePaths();
  }

  aboutToDisappear(): void {
    const handle: DetailTitleHandle | undefined = this.titleHandle;
    if (handle !== undefined) {
      handle.unbind();
    }
  }

  private hasPhotos(): boolean {
    const p: PhotoRecord | undefined = this.placemark;
    return p !== undefined && p.attachments.length > 0;
  }

  /** 逐附件解析可显示路径：磁盘原件仍在→直接用；已清扫→gpkg BLOB 解出写缓存（同 PhotoViewerPage） */
  private async resolvePaths(): Promise<void> {
    const p: PhotoRecord | undefined = this.placemark;
    if (p === undefined) {
      this.loaded = true;
      return;
    }
    const list: string[] = [];
    for (let i = 0; i < p.attachments.length; i++) {
      const a: PhotoAttachment = p.attachments[i];
      if (a.path.length > 0 && AppDirs.exists(a.path)) {
        list.push(a.path);
        continue;
      }
      const data: ArrayBuffer | null = await GpkgDml.readPhotoBlob(this.gpkgPath, p.id, i);
      if (data === null || data.byteLength === 0) {
        continue;
      }
      const name: string = a.name.length > 0 ? a.name : `${i}.jpg`;
      const dir: string = AppDirs.ensureDir(`${this.cacheDir}/photo_blob`);
      const target: string = `${dir}/${p.id}_${i}_${name}`;
      try {
        const f = fs.openSync(target, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
        try {
          fs.writeSync(f.fd, data);
        } finally {
          fs.closeSync(f);
        }
        list.push(target);
      } catch (e) {
        AppLog.e('照片 BLOB 写缓存失败', `${target} ${e}`);
      }
    }
    this.paths = list;
    this.loaded = true;
  }

  /** 沙箱绝对路径 → Image 可识别的 file:// URI */
  private uriOf(path: string): string {
    try {
      return fileUri.getUriFromPath(path);
    } catch (e) {
      AppLog.w('照片路径转 URI 失败', path);
      return path;
    }
  }

  private gridHeight(): number {
    const rows: number = Math.ceil(this.paths.length / GRID_COLUMNS);
    return Math.min(rows * GRID_ROW_HEIGHT, GRID_MAX_HEIGHT);
  }

  private openViewer(index: number): void {
    const p: PhotoRecord | undefined = this.placemark;
    if (p === undefined) {
      return;
    }
    const params: PhotoViewerParams = new PhotoViewerParams();
    params.placemarkId = p.id;
    params.initialIndex = index;
    router.pushUrl({ url: 'pages/PhotoViewerPage', params: params });
  }

  /** 备注编辑叠在本层之上：确认后就地刷新底部备注行，写库交宿主（嵌套弹层口径同 MeasureDetailDialog.openPicker） */
  private openRemark(): void {
    this.remarkEditor = new CustomDialogController({
      builder: RemarkEditDialog({
        title: '照片备注',
        initialValue: this.remark,
        onConfirmRemark: (text: string): void => {
          this.remark = text;
          this.onRemark(text);
        },
      }),
      customStyle: true,
      alignment: DialogAlignment.Center,
    });
    this.remarkEditor.open();
  }

  /** 标题栏操作键统一分派（重命名叠在本层之上不关闭；删除交宿主确认后关闭） */
  private onHeaderAction(label: string): void {
    if (label === '重命名') {
      this.onRename();
      return;
    }
    if (label === '分享') {
      this.onShare();
      return;
    }
    this.onDelete();
    this.controller.close();
  }

  @Builder
  headerAction(label: string) {
    Text(label)
      .fontSize(Theme.FONT_SUB)
      .fontColor(label === '删除' ? Theme.DANGER : Theme.PRIMARY_DARK)
      .padding({ left: 8, right: 8, top: 4, bottom: 4 })
      .onClick((): void => {
        this.onHeaderAction(label);
      })
  }

  /** 底部备注行：整行可点，空态显示占位（同 Android photo_sheet_ll_remark）；无点位时整行隐藏 */
  @Builder
  remarkRow() {
    if (this.placemark !== undefined) {
      Row({ space: 4 }) {
        Text('备注：')
          .fontSize(Theme.FONT_SUB)
          .fontColor(Theme.TEXT_SUB)
        Text(this.remark.length > 0 ? this.remark : REMARK_PLACEHOLDER)
          .fontSize(Theme.FONT_SUB)
          .fontColor(this.remark.length > 0 ? Theme.TEXT : Theme.TEXT_HINT)
          .layoutWeight(1)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .padding({ top: 8, bottom: 8 })
      .margin({ top: 8 })
      .alignItems(VerticalAlign.Top)
      .onClick((): void => {
        this.openRemark();
      })
    }
  }

  build() {
    Column() {
      Row({ space: 2 }) {
        Text(this.currentTitle.length > 0 ? this.currentTitle : '照片')
          .fontSize(Theme.FONT_TITLE)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.TEXT)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        this.headerAction('重命名')
        if (this.hasPhotos()) {
          this.headerAction('分享')
        }
        this.headerAction('删除')
        Text('×')
          .fontSize(20)
          .fontColor(Theme.TEXT_SUB)
          .padding({ left: 10, right: 4 })
          .onClick((): void => {
            this.controller.close();
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (!this.loaded) {
        LoadingProgress()
          .width(32)
          .height(32)
          .color(Theme.PRIMARY)
          .margin({ top: 20, bottom: 20 })
          .alignSelf(ItemAlign.Center)
      } else if (this.paths.length === 0) {
        Text('该点位没有照片')
          .fontSize(Theme.FONT_SUB)
          .fontColor(Theme.TEXT_HINT)
          .margin({ top: 20, bottom: 12 })
          .alignSelf(ItemAlign.Center)
      } else {
        Grid() {
          ForEach(this.paths, (path: string, index: number): void => {
            GridItem() {
              Image(this.uriOf(path))
                .width('100%')
                .height('100%')
                .objectFit(ImageFit.Cover)
                .borderRadius(6)
                .onClick((): void => {
                  this.openViewer(index);
                })
            }
          }, (path: string, index: number): string => `${index}|${path}`)
        }
        .columnsTemplate('1fr 1fr 1fr')
        .columnsGap(8)
        .rowsGap(8)
        .width('100%')
        .height(this.gridHeight())
        .margin({ top: 12 })
      }

      this.remarkRow()
    }
    .width('100%')
    .padding(Theme.PAD)
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(Theme.CARD)
    .borderRadius(Theme.RADIUS)
  }
}