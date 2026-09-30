// MapSourceList.ets —— 地图源列表面板（对应 Android LayerManageDialog 的「地图源」页签内容）。
//
// 抽成组件而非页面内联：LayerManagePage 的地图源页签与 AppSourcePage（独立地图源管理页）共用同一份
// 列表与同一套动作（单选切换底图 / 编辑 / 新增），行为必须完全一致，复制两份会很快走样。
// 语义与 Android 同：
//  · 列表不含注记层（isAnnotation 由主界面注记按钮控制）；
//  · 选中即「非注记源中仅这一个可见」，保存后由主界面的文档监听换底图；
//  · 编辑走 MapSourceEditDialog，系统内置源名称锁定；新增源立即置为唯一可见。
// 数据直接读 DocumentManager 单例，不接收入参——它是文档的视图，而非父组件的状态。

import { Theme } from '../common/Theme';
import { Ui } from '../common/Ui';
import { MapDocument, MapSource } from '../doc/DocModels';
import { DocumentManager } from '../doc/DocumentManager';
import { MapSourceEditDialog } from './MapSourceEditDialog';

@Component
export struct MapSourceList {
  /** 列表快照：仅在显式 reload 时重建（文档变更由宿主调用 reload 驱动，避免自建监听造成回环） */
  @State sources: MapSource[] = [];
  /** 宿主用 @Prop 触发刷新：值本身无意义，变化即重载 */
  @Prop @Watch('onRefreshTokenChange') refreshToken: number = 0;
  /** 无头图时的提示行（主界面「未配置底图」场景复用此面板） */
  emptyText: string = '暂无地图源';
  /** 底图变化回调：宿主据此刷新副标题（列表内部完成单选/新增/删除后都会上报） */
  onActiveChanged: (name: string) => void = (): void => {};

  private picker: CustomDialogController | undefined = undefined;

  aboutToAppear(): void {
    this.reload();
  }

  /** @Prop 变化时同步重载（父页面从图层页签切回、或文档保存后刷新） */
  onRefreshTokenChange(): void {
    this.reload();
  }

  private reload(): void {
    const doc: MapDocument | null = DocumentManager.getInstance().getDocument();
    if (doc === null) {
      this.sources = [];
      return;
    }
    const out: MapSource[] = [];
    for (let i = 0; i < doc.mapSources.length; i++) {
      if (!doc.mapSources[i].isAnnotation) {
        out.push(doc.mapSources[i]);
      }
    }
    this.sources = out;
    // 快照刷新即代表底图可能已变，把当前生效底图上报宿主（无可见源时为空串）
    let active: string = '';
    for (let i = 0; i < out.length; i++) {
      if (out[i].visible) {
        active = out[i].name ?? '';
        break;
      }
    }
    this.onActiveChanged(active);
  }

  /**
   * 单选切换：非注记源全部置隐、目标置显（与 Android onSelectMapSource 一致）。
   * 已是当前底图时不做写盘，避免无意义的文档广播与图层重建。
   */
  private select(target: MapSource): void {
    if (target.visible) {
      return;
    }
    DocumentManager.getInstance().update((doc: MapDocument): void => {
      for (let i = 0; i < doc.mapSources.length; i++) {
        const s: MapSource = doc.mapSources[i];
        if (!s.isAnnotation) {
          s.visible = s === target;
        }
      }
    });
    this.reload();
  }

  /** 新增：直接以「唯一可见」入文档（Android 同序：先把其余非注记源置隐） */
  private add(): void {
    this.openEditor(undefined, (name: string, url: string, imageFormat: string,
      token1: string, token2: string): void => {
      DocumentManager.getInstance().update((doc: MapDocument): void => {
        for (let i = 0; i < doc.mapSources.length; i++) {
          const s: MapSource = doc.mapSources[i];
          if (!s.isAnnotation) {
            s.visible = false;
          }
        }
        const created: MapSource = new MapSource(name, url, true);
        created.imageFormat = imageFormat;
        created.token1 = token1;
        created.token2 = token2;
        doc.mapSources.push(created);
      });
      this.reload();
      Ui.toast(`已添加地图源 ${name}`);
    });
  }

  /** 编辑：改完同步天地图 Token（任一图层改 Token，全系列跟随） */
  private edit(src: MapSource): void {
    this.openEditor(src, (name: string, url: string, imageFormat: string,
      token1: string, token2: string): void => {
      src.name = name;
      src.url = url;
      src.imageFormat = imageFormat;
      src.token1 = token1;
      src.token2 = token2;
      DocumentManager.getInstance().update((doc: MapDocument): void => {
        // 回调内不用 doc 参数：Token 同步按源对象在文档 mapSources 上遍历（src 即文档内实例）
        DocumentManager.getInstance().syncTiandituTokens(src);
      });
      this.reload();
    });
  }

  /**
   * 删除自定义图源：系统内置源不给删（保证底图永远可切回去）。
   * 删掉的是当前底图时，把清单内首个非注记源置为可见，避免地图变成无底图。
   */
  private remove(src: MapSource): void {
    DocumentManager.getInstance().update((doc: MapDocument): void => {
      const idx: number = doc.mapSources.indexOf(src);
      if (idx >= 0) {
        doc.mapSources.splice(idx, 1);
      }
      let anyVisible: boolean = false;
      for (let i = 0; i < doc.mapSources.length; i++) {
        const s: MapSource = doc.mapSources[i];
        if (!s.isAnnotation && s.visible) {
          anyVisible = true;
          break;
        }
      }
      if (!anyVisible) {
        for (let i = 0; i < doc.mapSources.length; i++) {
          const s: MapSource = doc.mapSources[i];
          if (!s.isAnnotation) {
            s.visible = true;
            break;
          }
        }
      }
    });
    this.reload();
    Ui.toast('已移除地图源');
  }

  /** 弹编辑对话框：新增与编辑共用一个 controller，区别只在初值与名称是否可改 */
  private openEditor(src: MapSource | undefined,
    onOk: (name: string, url: string, imageFormat: string,
      token1: string, token2: string) => void): void {
    this.picker = new CustomDialogController({
      builder: MapSourceEditDialog({
        source: src,
        nameEditable: src === undefined || !src.isSystem,
        onConfirmSource: onOk,
      }),
      customStyle: true,
      alignment: DialogAlignment.Center,
      autoCancel: true,
    });
    this.picker.open();
  }

  build() {
    Column() {
      if (this.sources.length === 0) {
        Text(this.emptyText)
          .fontSize(Theme.FONT_SUB)
          .fontColor(Theme.TEXT_SUB)
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding(24)
      } else {
        List({ space: Theme.GAP }) {
          ForEach(this.sources, (src: MapSource): void => {
            ListItem() {
              Row() {
                Radio({ value: src.name ?? '', group: 'mapSourceGroup' })
                  .checked(src.visible)
                  .onChange((checked: boolean): void => {
                    if (checked) {
                      this.select(src);
                    }
                  })
                Column() {
                  Text(src.name ?? '')
                    .fontSize(Theme.FONT)
                    .fontColor(Theme.TEXT)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(src.isSystem ? '内置' : '自定义')
                    .fontSize(Theme.FONT_SUB)
                    .fontColor(src.isSystem ? Theme.TEXT_HINT : Theme.PRIMARY_DARK)
                    .margin({ top: 2 })
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
                .onClick((): void => {
                  this.select(src);
                })

                SymbolGlyph($r('sys.symbol.square_and_pencil'))
                  .fontSize(20)
                  .fontColor([Theme.TEXT_SUB])
                  .margin({ right: 14 })
                  .onClick((): void => {
                    this.edit(src);
                  })
                if (!src.isSystem) {
                  SymbolGlyph($r('sys.symbol.trash'))
                    .fontSize(20)
                    .fontColor([Theme.DANGER])
                    .onClick((): void => {
                      this.remove(src);
                    })
                }
              }
              .width('100%')
              .padding(12)
              .backgroundColor(Theme.CARD)
              .borderRadius(Theme.RADIUS)
              .alignItems(VerticalAlign.Center)
            }
          }, (src: MapSource, index: number): string => `${src.name ?? ''}_${index}`)
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
      }

      Button('添加地图源')
        .width('100%')
        .height(42)
        .fontSize(Theme.FONT)
        .fontColor(Theme.TEXT_ON_DARK)
        .backgroundColor(Theme.PRIMARY)
        .borderRadius(Theme.RADIUS)
        .margin({ top: Theme.GAP })
        .onClick((): void => {
          this.add();
        })
    }
    .width('100%')
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
  }
}
