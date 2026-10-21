// PhotoViewerPage.ets —— 拍照点位照片全屏浏览页（对应 Android PhotoViewerActivity）。
//
// 行为对齐 Android：取该点位 type=photo 的附件按拍摄顺序翻页浏览，底部显示「序号 / 总数」，
// 附件为空直接退出（等价 activity 的 finish()）。单张照片直传 filePath 时只浏览那一张。
// 与 Android 的差异：ViewPager2 → Swiper（不循环、指示器关掉，序号自绘），
// 全屏沉浸由「点画面切显隐」的信息栏承担，返回箭头随时可退出。

import { common } from '@kit.AbilityKit';
import { fileUri } from '@kit.CoreFileKit';
import { router } from '@kit.ArkUI';
import fs from '@ohos.file.fs';
import { AppDirs } from '../common/AppDirs';
import { AppLog } from '../common/AppLog';
import { Theme } from '../common/Theme';
import { Ui } from '../common/Ui';
import { GpkgDml } from '../project/GpkgDml';
import { ProjectManager } from '../project/ProjectManager';
import { PhotoAttachment, PhotoRecord } from '../project/ProjectModels';
import { PhotoViewerParams } from './RouteParams';

/** 黑底沉浸浏览：信息栏半透明压黑，保证白字在任意照片上可读 */
const BAR_SCRIM: string = '#66000000';
/** 最小缩放倍率：1 = 适配视图原始大小，不允许缩得更小（同 Android ZoomableImageView.MIN_SCALE） */
const MIN_SCALE: number = 1;
/** 最大缩放倍率（同 Android ZoomableImageView.MAX_SCALE） */
const MAX_SCALE: number = 8;
/** 双击放大目标倍率（同 Android ZoomableImageView.DOUBLE_TAP_SCALE） */
const DOUBLE_TAP_SCALE: number = 2.5;

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
  /** 当前页缩放倍率（1 = 适配视图原始大小）；翻页即复位（同 Android 换图 resetZoom） */
  @State zoomScale: number = 1;
  /** 当前页平移量（vp，夹取后保证边缘不缩进视图内） */
  @State offsetX: number = 0;
  @State offsetY: number = 0;
  /** 捏合/拖动开始时的基准值 */
  private baseScale: number = 1;
  private baseOffsetX: number = 0;
  private baseOffsetY: number = 0;
  /** 当前页适配视图后的内容尺寸与视图尺寸（vp）：平移夹取依据 */
  private contentW: number = 0;
  private contentH: number = 0;
  private viewW: number = 0;
  private viewH: number = 0;
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
    const pm: ProjectManager = ProjectManager.get(ctx);
    const placemark: PhotoRecord | null = pm.findPhoto(placemarkId);
    if (placemark === null) {
      AppLog.w('浏览照片时点位不存在', `${placemarkId}`);
      Ui.toast('该拍照标识已不存在');
      router.back();
      return;
    }
    this.resolvePaths(ctx, pm.currentProjectPath, placemark).then((list: string[]): void => {
      this.title = placemark.name;
      this.paths = list;
      this.loaded = true;
      if (list.length === 0) {
        // 与 Android 同口径：没有照片就不开浏览页
        Ui.toast('该点位没有照片');
        router.back();
      }
    });
  }

  /**
   * 逐附件解析可显示路径（对应 Android MediaPackage 的 BLOB 回退）：
   * 磁盘原件仍在 → 直接用原路径；已被 BLOB 清扫 → 从 gpkg 解出字节写缓存文件后浏览。
   */
  private async resolvePaths(ctx: common.UIAbilityContext, gpkgPath: string,
    placemark: PhotoRecord): Promise<string[]> {
    const list: string[] = [];
    for (let i = 0; i < placemark.attachments.length; i++) {
      const a: PhotoAttachment = placemark.attachments[i];
      if (a.path.length > 0 && AppDirs.exists(a.path)) {
        list.push(a.path);
        continue;
      }
      const data: ArrayBuffer | null = await GpkgDml.readPhotoBlob(gpkgPath, placemark.id, i);
      if (data === null || data.byteLength === 0) {
        continue;
      }
      const name: string = a.name.length > 0 ? a.name : `${i}.jpg`;
      const dir: string = AppDirs.ensureDir(`${ctx.cacheDir}/photo_blob`);
      const target: string = `${dir}/${placemark.id}_${i}_${name}`;
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
    return list;
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

  /** 缩放/平移复位（翻页与双击还原共用） */
  private resetZoom(): void {
    this.zoomScale = MIN_SCALE;
    this.offsetX = 0;
    this.offsetY = 0;
  }

  /**
   * 平移量夹取（同 Android clampTranslation）：内容某轴放大后超出视图的量即该轴可平移上限，
   * 图小于视图的轴居中（平移归零）。
   */
  private clampOffset(x: number, y: number): number[] {
    const maxX: number = Math.max(0, (this.contentW * this.zoomScale - this.viewW) / 2);
    const maxY: number = Math.max(0, (this.contentH * this.zoomScale - this.viewH) / 2);
    return [Math.min(maxX, Math.max(-maxX, x)), Math.min(maxY, Math.max(-maxY, y))];
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
              .scale({ x: this.zoomScale, y: this.zoomScale })
              .translate({ x: this.offsetX, y: this.offsetY })
              .onComplete((info): void => {
                // 适配视图后的内容尺寸（vp），供平移夹取
                if (info !== undefined) {
                  this.contentW = info.contentWidth;
                  this.contentH = info.contentHeight;
                }
              })
              // 双击：已放大还原，未放大 2.5 倍（同 Android onDoubleTap）
              .priorityGesture(TapGesture({ count: 2 })
                .onAction((): void => {
                  if (this.zoomScale > MIN_SCALE) {
                    this.resetZoom();
                  } else {
                    this.zoomScale = DOUBLE_TAP_SCALE;
                    const c: number[] = this.clampOffset(this.offsetX, this.offsetY);
                    this.offsetX = c[0];
                    this.offsetY = c[1];
                  }
                }))
              .gesture(TapGesture({ count: 1 })
                .onAction((): void => {
                  this.barVisible = !this.barVisible;
                }))
              // 双指捏合缩放（1~8 倍夹取）
              .parallelGesture(PinchGesture({ fingers: 2 })
                .onActionStart((): void => {
                  this.baseScale = this.zoomScale;
                })
                .onActionUpdate((e: GestureEvent): void => {
                  const target: number = Math.min(MAX_SCALE, Math.max(MIN_SCALE, this.baseScale * e.scale));
                  this.zoomScale = target;
                  const c: number[] = this.clampOffset(this.offsetX, this.offsetY);
                  this.offsetX = c[0];
                  this.offsetY = c[1];
                }))
              // 单指拖动：仅放大后平移；未放大时缩放态为 1，夹取结果恒 0 故天然不动
              .parallelGesture(PanGesture({ fingers: 1 })
                .onActionStart((): void => {
                  this.baseOffsetX = this.offsetX;
                  this.baseOffsetY = this.offsetY;
                })
                .onActionUpdate((e: GestureEvent): void => {
                  if (this.zoomScale <= MIN_SCALE) {
                    return;
                  }
                  const c: number[] = this.clampOffset(
                    this.baseOffsetX + e.offsetX, this.baseOffsetY + e.offsetY);
                  this.offsetX = c[0];
                  this.offsetY = c[1];
                }))
          }, (path: string, index: number): string => `${index}|${path}`)
        }
        .width('100%')
        .height('100%')
        .index(this.startIndex)
        .loop(false)
        .indicator(false)
        // 放大后禁用翻页（等价 Android requestDisallowInterceptTouchEvent：翻页/平移二选一）
        .disableSwipe(this.zoomScale > MIN_SCALE)
        .onAreaChange((_old: Area, area: Area): void => {
          this.viewW = this.getUIContext().px2vp(area.width as number);
          this.viewH = this.getUIContext().px2vp(area.height as number);
        })
        .onChange((index: number): void => {
          this.current = index;
          // 翻页复位缩放（同 Android RecyclerView 页复用换图 resetZoom）
          this.resetZoom();
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
