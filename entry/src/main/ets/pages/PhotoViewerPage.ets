// PhotoViewerPage.ets —— 拍照点位照片全屏浏览页（对应 Android PhotoViewerActivity）。
//
// 行为对齐 Android：取该点位 type=photo 的附件按拍摄顺序翻页浏览，底部显示「序号 / 总数」，
// 附件为空直接退出（等价 activity 的 finish()）。单张照片直传 filePath 时只浏览那一张。
// 与 Android 的差异：ViewPager2 → Swiper（不循环、指示器关掉，序号自绘），
// 全屏沉浸由「点画面切显隐」的信息栏承担，返回箭头随时可退出。

import { common } from '@kit.AbilityKit';
import { fileUri } from '@kit.CoreFileKit';
import { router } from '@kit.ArkUI';
import { AppDirs } from '../common/AppDirs';
import { AppLog } from '../common/AppLog';
import { Theme } from '../common/Theme';
import { Ui } from '../common/Ui';
import { MediaAttachment, MediaPlacemark, MediaStore } from '../media/MediaStore';
import { PhotoViewerParams } from './RouteParams';

/** 黑底沉浸浏览：信息栏半透明压黑，保证白字在任意照片上可读 */
const BAR_SCRIM: string = '#66000000';

@Entry
@Component
struct PhotoViewerPage {
  /** 照片绝对路径（按 attachment_time 升序，与库内查询顺序一致） */
  @State paths: string[] = [];
  @State loaded: boolean = false;
  @State title: string = '照片';
  /** 当前张序（0 基） */
  @State current: number = 0;
  /** 信息栏（顶部返回 + 底部序号）是否显示：点画面切换 */
  @State barVisible: boolean = true;
  /** Swiper 起始页（由入参决定，仅初始化用） */
  private startIndex: number = 0;
  /** 系统避让高度（vp）：本页全屏沉浸，顶栏要下移状态栏高度、底部序号要上移导航条高度 */
  @StorageProp('topInsetVp') topInset: number = 0;
  @StorageProp('bottomInsetVp') bottomInset: number = 0;

  aboutToAppear(): void {
    const raw: Object = router.getParams();
    const params: PhotoViewerParams | undefined =
      (raw === undefined || raw === null) ? undefined : (raw as PhotoViewerParams);
    const single: string = params !== undefined ? params.filePath : '';
    if (single.length > 0) {
      this.paths = [single];
      this.title = PhotoViewerPage.nameOfPath(single);
      this.loaded = true;
      return;
    }
    const placemarkId: number = params !== undefined ? params.placemarkId : -1;
    if (placemarkId <= 0) {
      Ui.toast('未指定拍照点位');
      router.back();
      return;
    }
    this.startIndex = Math.max(0, params !== undefined ? params.initialIndex : 0);
    const ctx: common.UIAbilityContext =
      this.getUIContext().getHostContext() as common.UIAbilityContext;
    MediaStore.getInstance(ctx).then(async (store: MediaStore): Promise<void> => {
      const placemark: MediaPlacemark | undefined = await store.findPlacemark(placemarkId);
      if (placemark === undefined) {
        AppLog.w('浏览照片时点位不存在', `${placemarkId}`);
        Ui.toast('该拍照标识已不存在');
        router.back();
        return;
      }
      const list: string[] = [];
      for (let i = 0; i < placemark.attachments.length; i++) {
        const a: MediaAttachment = placemark.attachments[i];
        if (a.type === MediaAttachment.TYPE_PHOTO && AppDirs.exists(a.path)) {
          list.push(a.path);
        }
      }
      this.title = placemark.displayName();
      this.paths = list;
      this.loaded = true;
      if (list.length === 0) {
        // 与 Android 同口径：没有照片就不开浏览页
        Ui.toast('该点位没有照片');
        router.back();
      }
    });
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

  private static nameOfPath(path: string): string {
    const idx: number = path.lastIndexOf('/');
    return idx >= 0 ? path.substring(idx + 1) : path;
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (!this.loaded) {
        Column() {
          LoadingProgress()
            .width(36)
            .height(36)
            .color(Theme.TEXT_ON_DARK)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      } else {
        Swiper() {
          ForEach(this.paths, (path: string): void => {
            Image(this.uriOf(path))
              .width('100%')
              .height('100%')
              .objectFit(ImageFit.Contain)
              .draggable(false)
          }, (path: string, index: number): string => `${index}|${path}`)
        }
        .width('100%')
        .height('100%')
        .index(this.startIndex)
        .loop(false)
        .indicator(false)
        .onChange((index: number): void => {
          this.current = index;
        })
        .onClick((): void => {
          this.barVisible = !this.barVisible;
        })

        if (this.barVisible) {
          Row() {
            SymbolGlyph($r('sys.symbol.chevron_left'))
              .fontSize(22)
              .fontColor([Theme.TEXT_ON_DARK])
              .onClick((): void => {
                router.back();
              })
            Text(this.title)
              .fontSize(Theme.FONT)
              .fontColor(Theme.TEXT_ON_DARK)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ left: 10 })
              .layoutWeight(1)
          }
          .width('100%')
          // 状态栏那一段也由 scrim 盖住（高度并入总高、内容靠 padding 下移），返回箭头才不会落在状态栏下
          .height(Theme.BAR_HEIGHT + this.topInset)
          .padding({ top: this.topInset, left: 12, right: 12 })
          .backgroundColor(BAR_SCRIM)
          .alignItems(VerticalAlign.Center)

          Text(`${this.current + 1} / ${this.paths.length}`)
            .fontSize(Theme.FONT)
            .fontColor(Theme.TEXT_ON_DARK)
            .padding({ left: 12, right: 12, top: 6, bottom: 6 + this.bottomInset })
            .backgroundColor(BAR_SCRIM)
            .borderRadius(Theme.RADIUS)
            .width('100%')
            .textAlign(TextAlign.Center)
            .position({ x: 0, y: '100%' })
            .markAnchor({ x: 0, y: '100%' })
            .hitTestBehavior(HitTestMode.None)
        }
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Black)
  }
}
