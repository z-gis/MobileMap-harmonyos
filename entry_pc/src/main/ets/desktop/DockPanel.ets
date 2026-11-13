// DockPanel.ets —— 停靠面板外壳（标题条 + 关闭 + 内容槽）。
//
// 左侧「图层/样式」与底部「属性表」共用这个外壳：外壳只管标题、计数徽标与关闭动作，
// 内容由宿主以 @BuilderParam 注入——面板的排布（挂在 RowSplit / ColumnSplit 的哪一格）
// 与面板的语义解耦，后面若要改成可拖出的悬浮窗，只动宿主。
import { DeskTheme } from '../common/DeskTheme';

@Component
export struct DockPanel {
  /** 面板标题（@Prop：宿主状态变化时要能刷进已建好的面板） */
  @Prop title: string = '';
  /** 标题右侧的计数/状态提示（如「3 层」） */
  @Prop badge: string = '';
  /** true=左侧停靠（描右边框）；false=底部停靠（描上边框） */
  @Prop isLeft: boolean = true;
  /** 关闭（收起）回调；未提供则不画关闭按钮 */
  onClose: (() => void) | undefined = undefined;
  /** 内容槽 */
  @BuilderParam content: () => void = this.emptyContent;

  @Builder
  emptyContent() {
    Column()
      .width('100%')
      .height('100%')
  }

  build() {
    Column() {
      Row({ space: 6 }) {
        Text(this.title)
          .fontSize(DeskTheme.FONT_BODY)
          .fontWeight(FontWeight.Medium)
          .fontColor(DeskTheme.TEXT)
        Blank()
        if (this.badge.length > 0) {
          Text(this.badge)
            .fontSize(DeskTheme.FONT_CAPTION)
            .fontColor(DeskTheme.TEXT_SUB)
        }
        if (this.onClose !== undefined) {
          Text('×')
            .fontSize(15)
            .fontColor(DeskTheme.TEXT_SUB)
            .width(20)
            .height(20)
            .textAlign(TextAlign.Center)
            .borderRadius(3)
            .hoverEffect(HoverEffect.Highlight)
            .onClick((): void => {
              const cb = this.onClose;
              if (cb !== undefined) {
                cb();
              }
            })
        }
      }
      .width('100%')
      .height(28)
      .padding({ left: 10, right: 6 })
      .backgroundColor(DeskTheme.CHROME)

      Divider()
        .color(DeskTheme.DIVIDER)
        .strokeWidth(1)

      Column() {
        this.content()
      }
      .width('100%')
      .layoutWeight(1)
      .backgroundColor(DeskTheme.PANEL)
    }
    .width('100%')
    .height('100%')
    .border({
      width: { top: this.isLeft ? 0 : 1, right: this.isLeft ? 1 : 0 },
      color: { top: DeskTheme.DIVIDER, right: DeskTheme.DIVIDER }
    })
  }
}
