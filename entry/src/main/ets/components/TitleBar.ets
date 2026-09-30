// TitleBar.ets —— 各二级页面共用的顶部标题栏（对应 Android activity 布局里的 toolbar + iv_back）。
//
// Android 侧每个 Activity 布局都抄了一遍「返回箭头 + 标题 + 右侧动作」，这里收敛成一个组件：
// 右侧动作条数不固定，用 @BuilderParam 让宿主注入，避免为每种按钮组合再加布尔开关。

import { router } from '@kit.ArkUI';
import { Theme } from '../common/Theme';

/** 默认动作插槽：@BuilderParam 只能由 @Builder 函数初始化，故在文件级定义空实现 */
@Builder
function emptyTitleActions(): void {
}

@Component
export struct TitleBar {
  /** 标题文本 */
  title: string = '';
  /** 副标题（可空，如小班号、图层路径） */
  subtitle: string = '';
  /** 深色栏上的返回/标题色固定为白，无需配置 */
  /**
   * 右侧动作插槽。**宿主必须以箭头函数包裹传入**：
   * actions: (): void => { this.barActions(); }
   * 直接写 actions: this.barActions 传的是未绑定 this 的方法引用，本组件以 this.actions()
   * 调用时槽内 this 变成本组件，宿主 builder 里的 this.xxx() 会报 "undefined is not callable"。
   */
  @BuilderParam actions: () => void = emptyTitleActions;
  /** 返回动作：宿主可覆盖（如需先落盘再退出），默认直接路由返回 */
  onBack: () => void = (): void => {
    router.back();
  };
  /** 状态栏避让高度（vp）：主窗口开了全屏布局，标题栏要自己下移，由各二级页共用生效 */
  @StorageProp('topInsetVp') topInset: number = 0;

  build() {
    // 外层只负责让开状态栏：不让开时标题与右侧动作（导入 / 新增等）会落在状态栏下面、点了没反应。
    // 底色画在外层，状态栏那一条与标题栏同色，视觉上是一体延伸而不是被顶下去。
    Column() {
      Row() {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(22)
          .fontColor([Theme.TEXT_ON_DARK])
          .onClick((): void => {
            this.onBack();
          })
        Column() {
          Text(this.title)
            .fontSize(Theme.FONT_TITLE)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.TEXT_ON_DARK)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.subtitle.length > 0) {
            Text(this.subtitle)
              .fontSize(Theme.FONT_SUB)
              .fontColor('#B3FFFFFF')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 10 })

        this.actions()
      }
      .width('100%')
      .height(Theme.BAR_HEIGHT)
      .padding({ left: 12, right: 12 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding({ top: this.topInset })
    .backgroundColor(Theme.BAR)
  }
}
