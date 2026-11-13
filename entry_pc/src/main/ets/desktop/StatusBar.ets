// StatusBar.ets —— ArcMap 式状态栏：左侧提示/光标坐标（可切单位），右侧比例尺与视图信息。
//
// 每格做成子组件而不是 @Builder 传参：@Builder 值传递参数只在首次渲染时快照，状态变量后续
// 变化不会刷进 UI（实测「中心/级别」会永远停在 0.00000）。
// 坐标单位点击即弹菜单（十进制度 / 度分秒 / 度分），与 ArcMap 状态栏左下角的单位下拉同位。
import { CoordUnit, DeskTheme } from '../common/DeskTheme';

@Component
struct StatusCell {
  @Prop label: string = '';
  @Prop value: string = '';
  @Prop cellWidth: number = 80;

  build() {
    Row({ space: 4 }) {
      if (this.label.length > 0) {
        Text(this.label)
          .fontSize(DeskTheme.FONT_STATUS)
          .fontColor(DeskTheme.TEXT_DISABLED)
      }
      Text(this.value)
        .fontSize(DeskTheme.FONT_STATUS)
        .fontColor(DeskTheme.TEXT)
        .fontFeature('"tnum" on')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .height('100%')
    .width(this.cellWidth)
    .padding({ left: 7, right: 7 })
    .border({ width: { left: 1 }, color: { left: DeskTheme.DIVIDER_SOFT } })
  }
}

@Component
export struct StatusBar {
  /** 光标处坐标文本（已按单位格式化） */
  @Prop coordText: string = '--';
  @Prop unitText: string = '十进制度';
  /** 比例尺 1:N */
  @Prop scaleText: string = '--';
  @Prop level: number = 0;
  @Prop modeText: string = '二维';
  @Prop toolText: string = '选择要素';
  /** 常驻操作提示 */
  @Prop message: string = '就绪';
  /** 工具条悬停提示（非空时优先显示，离开即回落 message） */
  @Prop hint: string = '';
  onUnit: ((unit: number) => void) | undefined = undefined;

  private unitMenu(): MenuElement[] {
    const labels: string[] = ['十进制度', '度分秒', '度分'];
    const out: MenuElement[] = [];
    for (let i = 0; i < labels.length; i++) {
      const u: number = i;
      out.push({
        value: labels[i],
        action: (): void => {
          const cb = this.onUnit;
          if (cb !== undefined) {
            cb(u);
          }
        }
      });
    }
    return out;
  }

  build() {
    Row() {
      Text(this.hint.length > 0 ? this.hint : this.message)
        .fontSize(DeskTheme.FONT_STATUS)
        .fontColor(this.hint.length > 0 ? DeskTheme.ACCENT : DeskTheme.TEXT_SUB)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
        .padding({ left: 8, right: 8 })

      // 坐标 + 单位（点击切单位，ArcMap 同位）
      Row({ space: 5 }) {
        Text(this.coordText)
          .fontSize(DeskTheme.FONT_STATUS)
          .fontColor(DeskTheme.TEXT)
          .fontFeature('"tnum" on')
          .maxLines(1)
        Text(this.unitText)
          .fontSize(9)
          .fontColor(DeskTheme.TEXT_SUB)
        Text('▾')
          .fontSize(8)
          .fontColor(DeskTheme.TEXT_SUB)
      }
      .height('100%')
      .padding({ left: 8, right: 6 })
      .border({ width: { left: 1 }, color: { left: DeskTheme.DIVIDER_SOFT } })
      .hoverEffect(HoverEffect.Highlight)
      .bindMenu(this.unitMenu())

      StatusCell({ value: this.scaleText, cellWidth: 110 })
      StatusCell({ label: '级别', value: this.level.toFixed(1), cellWidth: 74 })
      StatusCell({ value: this.modeText, cellWidth: 48 })
      StatusCell({ value: this.toolText, cellWidth: 80 })
    }
    .width('100%')
    .height(DeskTheme.H_STATUS)
    .backgroundColor(DeskTheme.CHROME)
    .border({ width: { top: 1 }, color: { top: DeskTheme.DIVIDER } })
  }
}