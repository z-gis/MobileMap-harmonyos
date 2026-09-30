// AddLayerPage.ets —— 导入本地图层页（对应 Android ui.activity.OpenFileActivity）。
//
// Android 自研了一套文件管理器（沙箱外真直连路径，可原地引用）；鸿蒙沙箱不允许应用遍历公共目录，
// 标准做法是调起系统文件选择器（DocumentViewPicker）拿授权 URI，再由 VectorFileImporter 拷入沙箱
// 调查宝/layer/ 后引用。因此本页不承担「浏览目录」，只承担 Android OpenFileActivity 的其余职责：
//  · 按类型限定可选扩展名（矢量白名单 / 栅格白名单，与 Android EXTRA_FILE_TYPES 同集）；
//  · 支持一次多选（shp 需连同 .dbf/.shx/.prj 一起选中，分组导入由导入器负责）；
//  · 导入成功即写入文档并落盘，主界面的文档监听把图层加进地图。
// 入口参数 tab 决定初始类型；导入完成后写入 PageData 供主界面缩放到新图层四至（等价 Android 行为）。

import { picker } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { PageData, PageKeys } from '../common/PageData';
import { Theme } from '../common/Theme';
import { Ui } from '../common/Ui';
import { LayerInfo } from '../doc/DocModels';
import { DocumentManager } from '../doc/DocumentManager';
import { ImportResult, VectorFileImporter } from '../vector/VectorFileImporter';
import { LayerType, VectorFormats } from '../vector/VectorFormats';
import { TitleBar } from '../components/TitleBar';

/** 单次最多可选文件数（shp 家族一次 4~5 个，留出批量图层导入余量） */
const MAX_SELECT_NUMBER: number = 64;

@Entry
@Component
struct AddLayerPage {
  /** 底部导航条避让高度（vp）：主窗口是全屏布局，页面内容要让开导航条 */
  @StorageProp('bottomInsetVp') bottomInset: number = 0;
  @State isVector: boolean = true;
  @State busy: boolean = false;
  /** 已成功导入的图层名（本页内的即时反馈清单，离开页面即失） */
  @State imported: string[] = [];

  aboutToAppear(): void {
    const raw: Object = router.getParams();
    if (raw === undefined || raw === null) {
      return;
    }
    // LayerManageParams.tab：0 矢量 / 1 栅格 / 2 地图源（地图源不会进本页，按矢量处理）
    const tab: number = (raw as Record<string, number>).tab ?? 0;
    this.isVector = tab !== 1;
  }

  private typeLabel(): string {
    return this.isVector ? '矢量图层' : '栅格图层';
  }

  private supportedExts(): string[] {
    return VectorFormats.pickFilter(this.isVector ? LayerType.VECTOR : LayerType.RASTER);
  }

  /** 选择器扩展名过滤：DocumentViewPicker 要求以 '.' 起始的后缀数组 */
  private suffixFilters(): string[] {
    const out: string[] = [];
    const exts: string[] = this.supportedExts();
    for (let i = 0; i < exts.length; i++) {
      out.push(`.${exts[i]}`);
    }
    return out;
  }

  private switchType(toVector: boolean): void {
    if (toVector === this.isVector) {
      return;
    }
    this.isVector = toVector;
  }

  private async choose(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      const ctx: common.UIAbilityContext =
        this.getUIContext().getHostContext() as common.UIAbilityContext;
      const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      options.maxSelectNumber = MAX_SELECT_NUMBER;
      options.fileSuffixFilters = this.suffixFilters();
      const uris: string[] = await new picker.DocumentViewPicker(ctx).select(options);
      if (uris === undefined || uris.length === 0) {
        return;
      }
      await this.doImport(uris);
    } catch (e) {
      Ui.toast(`选择文件失败：${e}`);
    } finally {
      this.busy = false;
    }
  }

  /** 导入 → 写文档 → 落盘；同类型重复导入按路径去重（同 Android：已存在则不再追加） */
  private async doImport(uris: string[]): Promise<void> {
    const results: ImportResult[] = await VectorFileImporter.importPicked(uris);
    if (results.length === 0) {
      Ui.toast('未导入任何图层');
      return;
    }
    const doc = DocumentManager.getInstance().getDocument();
    if (doc === null) {
      Ui.toast('地图文档未就绪');
      return;
    }
    const target: LayerInfo[] = this.isVector ? doc.vectorLayers : doc.rasterLayers;
    const type: string = this.isVector ? LayerInfo.TYPE_VECTOR : LayerInfo.TYPE_RASTER;
    const names: string[] = [];
    let lastPath: string = '';
    for (let i = 0; i < results.length; i++) {
      const r: ImportResult = results[i];
      let exists: boolean = false;
      for (let j = 0; j < target.length; j++) {
        if (target[j].path === r.path) {
          exists = true;
          break;
        }
      }
      if (exists) {
        // 已在本工程内：只更新显示名，不重复加层（避免同一文件产生两个渲染层）
        continue;
      }
      target.push(new LayerInfo(r.name, r.path, type, true));
      names.push(r.name);
      lastPath = r.path;
    }
    DocumentManager.getInstance().save();
    if (names.length === 0) {
      Ui.toast('这些图层已存在');
      return;
    }
    PageData.put(PageKeys.IMPORTED_LAYER_PATH, lastPath);
    const merged: string[] = [];
    for (let i = 0; i < this.imported.length; i++) {
      merged.push(this.imported[i]);
    }
    for (let i = 0; i < names.length; i++) {
      merged.push(names[i]);
    }
    this.imported = merged;
    Ui.toast(`已导入 ${names.length} 个图层`);
  }

  build() {
    Column() {
      TitleBar({ title: '导入本地图层', subtitle: this.typeLabel() })

      Row({ space: 8 }) {
        this.tabItem('矢量图层', true)
        this.tabItem('栅格图层', false)
      }
      .width('100%')
      .padding({ left: Theme.PAD, right: Theme.PAD, top: Theme.GAP })

      Text(`支持格式：${this.supportedExts().join('、')}`)
        .fontSize(Theme.FONT_SUB)
        .fontColor(Theme.TEXT_SUB)
        .width('100%')
        .padding({ left: Theme.PAD, right: Theme.PAD, top: 10 })

      Text(this.isVector
        ? '提示：shp 请同时选中 .shp/.dbf/.shx/.prj（可一次多选），压缩包 zip/kmz 会自动解压。\n'
          + '导入后的文件会复制到应用数据目录「调查宝/layer」，与原文件不再关联。'
        : '提示：tif/tiff/img 需与同名投影/金字塔文件（.tfw/.ovr 等）一起选中。')
        .fontSize(Theme.FONT_SUB)
        .fontColor(Theme.TEXT_HINT)
        .width('100%')
        .padding({ left: Theme.PAD, right: Theme.PAD, top: 6 })

      Button(this.busy ? '正在导入…' : '选择文件')
        .width('100%')
        .height(44)
        .fontSize(Theme.FONT)
        .fontColor(Theme.TEXT_ON_DARK)
        .backgroundColor(Theme.PRIMARY)
        .borderRadius(Theme.RADIUS)
        .enabled(!this.busy)
        .margin({ left: Theme.PAD, right: Theme.PAD, top: 14 })
        .onClick((): void => {
          this.choose();
        })

      List({ space: Theme.GAP }) {
        ForEach(this.imported, (name: string): void => {
          ListItem() {
            Row() {
              SymbolGlyph($r('sys.symbol.checkmark'))
                .fontSize(16)
                .fontColor([Theme.OK])
                .margin({ right: 8 })
              Text(name)
                .fontSize(Theme.FONT)
                .fontColor(Theme.TEXT)
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .width('100%')
            .padding(12)
            .backgroundColor(Theme.CARD)
            .borderRadius(Theme.RADIUS)
          }
        }, (name: string, index: number): string => `${name}_${index}`)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .padding({ left: Theme.PAD, right: Theme.PAD, top: Theme.GAP, bottom: Theme.PAD })
    }
    .width('100%')
    .height('100%')
    .padding({ bottom: this.bottomInset })
    .backgroundColor(Theme.BG)
  }

  /**
   * 类型页签。
   * 选中态用 @State isVector 直接判定（非 @Builder 入参），保证切换后两枚页签同时刷新。
   */
  @Builder
  tabItem(label: string, toVector: boolean) {
    Text(label)
      .fontSize(Theme.FONT)
      .fontColor(this.isVector === toVector ? Theme.TEXT_ON_DARK : Theme.TEXT_SUB)
      .textAlign(TextAlign.Center)
      .height(34)
      .layoutWeight(1)
      .backgroundColor(this.isVector === toVector ? Theme.PRIMARY : Theme.SUBTLE)
      .borderRadius(Theme.RADIUS)
      .onClick((): void => {
        this.switchType(toVector);
      })
  }
}
