// ToolBar.ets —— ArcMap 式双工具条：上排「标准」（文件/添加数据/比例尺），下排「工具」（活动工具+导航）。
//
// 按钮做成子组件 ToolButton 而不是 @Builder 传参：@Builder 的值参只在首次渲染快照，
// 选中态/可用态后续变化刷不进来（本项目状态栏已实测踩过同一坑）。
// 悬停提示不走 bindPopup（那是点击触发），改由 onHover 把提示文案回抛宿主状态栏——
// 桌面内业软件的习惯是「指哪提示哪」，状态栏左侧常驻提示位正好承担。
import { DeskCmd, DeskTheme, DeskTool } from '../common/DeskTheme';
import { DeskVector } from '../common/DeskVector';
import { ToolIcon } from './ToolIcon';

/** 比例尺下拉预设（ArcMap 常用固定比例尺） */
const SCALE_PRESETS: number[] = [500, 1000, 2000, 5000, 10000, 25000, 50000, 100000,
  250000, 500000, 1000000, 5000000];

@Component
struct ToolButton {
  @Prop icon: string = 'select';
  @Prop tip: string = '';
  @Prop isEnabled: boolean = true;
  @Prop checked: boolean = false;
  onAct: (() => void) | undefined = undefined;
  onTip: ((tip: string) => void) | undefined = undefined;

  build() {
    Stack() {
      ToolIcon({ name: this.icon })
    }
    .width(DeskTheme.BTN)
    .height(DeskTheme.BTN)
    .borderRadius(2)
    .backgroundColor(this.checked ? DeskTheme.ACTIVE : 'rgba(0,0,0,0)')
    .border({ width: 1, color: this.checked ? DeskTheme.ACTIVE_BORDER : 'rgba(0,0,0,0)' })
    .opacity(this.isEnabled ? 1 : 0.35)
    .hoverEffect(this.isEnabled ? HoverEffect.Highlight : HoverEffect.None)
    .onHover((isHover: boolean): void => {
      const cb = this.onTip;
      if (cb !== undefined) {
        cb(isHover ? this.tip : '');
      }
    })
    .onClick((): void => {
      const cb = this.onAct;
      if (this.isEnabled && cb !== undefined) {
        cb();
      }
    })
  }
}

@Component
struct ToolSep {
  build() {
    Divider()
      .vertical(true)
      .height(18)
      .strokeWidth(1)
      .color(DeskTheme.DIVIDER)
      .margin({ left: 3, right: 3 })
  }
}

@Component
export struct ToolBar {
  /** 当前活动工具（与宿主双向同步：状态栏也要显示工具名） */
  @Link activeTool: DeskTool;
  /** 当前比例尺文本 1:N */
  @Prop scaleText: string = '--';
  /** 比例尺是否已可量算（首帧前禁用下拉） */
  @Prop scaleReady: boolean = false;
  @Prop canBack: boolean = false;
  @Prop canForward: boolean = false;
  @Prop tocOn: boolean = true;
  @Prop tableOn: boolean = false;
  /** 添加数据进行中：禁用按钮防重入 */
  @Prop busy: boolean = false;
  onCommand: ((cmd: string) => void) | undefined = undefined;
  onScale: ((denominator: number) => void) | undefined = undefined;
  onTip: ((tip: string) => void) | undefined = undefined;

  private emit(cmd: string): void {
    const cb = this.onCommand;
    if (cb !== undefined) {
      cb(cmd);
    }
  }

  private tip(t: string): void {
    const cb = this.onTip;
    if (cb !== undefined) {
      cb(t);
    }
  }

  private pickTool(t: DeskTool): void {
    this.activeTool = t;
  }

  private scaleMenu(): MenuElement[] {
    const out: MenuElement[] = [];
    for (let i = 0; i < SCALE_PRESETS.length; i++) {
      const d: number = SCALE_PRESETS[i];
      out.push({
        value: `1:${DeskVector.groupDigits(d)}`,
        action: (): void => {
          const cb = this.onScale;
          if (cb !== undefined) {
            cb(d);
          }
        }
      });
    }
    return out;
  }

  build() {
    Column() {
      // ── 标准工具条 ──
      Row() {
        ToolButton({ icon: 'new', tip: '新建地图文档', isEnabled: false,
          onAct: (): void => { this.emit(DeskCmd.NEW_PROJECT); }, onTip: (t: string): void => { this.tip(t); } })
        ToolButton({ icon: 'open', tip: '打开地图文档', isEnabled: false,
          onAct: (): void => { this.emit(DeskCmd.OPEN_PROJECT); }, onTip: (t: string): void => { this.tip(t); } })
        ToolButton({ icon: 'save', tip: '保存地图文档', isEnabled: false,
          onAct: (): void => { this.emit(DeskCmd.SAVE_PROJECT); }, onTip: (t: string): void => { this.tip(t); } })
        ToolSep()
        ToolButton({ icon: 'undo', tip: '撤销', isEnabled: false, onTip: (t: string): void => { this.tip(t); } })
        ToolButton({ icon: 'redo', tip: '重做', isEnabled: false, onTip: (t: string): void => { this.tip(t); } })
        ToolSep()
        ToolButton({ icon: 'print', tip: '打印地图', isEnabled: false, onTip: (t: string): void => { this.tip(t); } })
        ToolSep()
        ToolButton({ icon: 'addData', tip: this.busy ? '正在添加数据…' : '添加数据（SHP / GPKG / KML / GeoTIFF）',
          isEnabled: !this.busy,
          onAct: (): void => { this.emit(DeskCmd.ADD_DATA); }, onTip: (t: string): void => { this.tip(t); } })
        ToolSep()

        // 比例尺框（ArcMap 标准工具条上的可编辑比例尺位）
        Row({ space: 4 }) {
          Text(this.scaleText)
            .fontSize(DeskTheme.FONT_STATUS)
            .fontColor(this.scaleReady ? DeskTheme.TEXT : DeskTheme.TEXT_DISABLED)
            .fontFeature('"tnum" on')
            .layoutWeight(1)
            .textAlign(TextAlign.Center)
            .maxLines(1)
          Text('▾')
            .fontSize(9)
            .fontColor(DeskTheme.TEXT_SUB)
        }
        .width(116)
        .height(22)
        .padding({ left: 6, right: 5 })
        .backgroundColor(DeskTheme.PANEL)
        .border({ width: 1, color: DeskTheme.DIVIDER })
        .borderRadius(1)
        .opacity(this.scaleReady ? 1 : 0.5)
        .bindMenu(this.scaleMenu())
        .onHover((isHover: boolean): void => {
          this.tip(isHover ? '地图比例尺（点击选择固定比例尺）' : '');
        })

        Blank()
        Text('标准')
          .fontSize(9)
          .fontColor(DeskTheme.TEXT_DISABLED)
          .margin({ right: 4 })
      }
      .width('100%')
      .height(DeskTheme.H_TOOLBAR)
      .padding({ left: 4, right: 4 })
      .backgroundColor(DeskTheme.TOOLBAR)

      Divider().color(DeskTheme.DIVIDER_SOFT).strokeWidth(1)

      // ── 工具工具条 ──
      Row() {
        ToolButton({ icon: 'select', tip: '选择要素', checked: this.activeTool === DeskTool.SELECT,
          onAct: (): void => { this.pickTool(DeskTool.SELECT); }, onTip: (t: string): void => { this.tip(t); } })
        ToolButton({ icon: 'pan', tip: '平移（按住拖动地图）', checked: this.activeTool === DeskTool.PAN,
          onAct: (): void => { this.pickTool(DeskTool.PAN); }, onTip: (t: string): void => { this.tip(t); } })
        ToolButton({ icon: 'zoomIn', tip: '放大（点击地图以光标为锚）', checked: this.activeTool === DeskTool.ZOOM_IN,
          onAct: (): void => { this.pickTool(DeskTool.ZOOM_IN); }, onTip: (t: string): void => { this.tip(t); } })
        ToolButton({ icon: 'zoomOut', tip: '缩小（点击地图以光标为锚）', checked: this.activeTool === DeskTool.ZOOM_OUT,
          onAct: (): void => { this.pickTool(DeskTool.ZOOM_OUT); }, onTip: (t: string): void => { this.tip(t); } })
        ToolSep()
        ToolButton({ icon: 'extent', tip: '全图（缩放至所有可见图层范围）',
          onAct: (): void => { this.emit(DeskCmd.ZOOM_EXTENT); }, onTip: (t: string): void => { this.tip(t); } })
        ToolButton({ icon: 'back', tip: '返回上一视图', isEnabled: this.canBack,
          onAct: (): void => { this.emit(DeskCmd.ZOOM_BACK); }, onTip: (t: string): void => { this.tip(t); } })
        ToolButton({ icon: 'forward', tip: '前进到下一视图', isEnabled: this.canForward,
          onAct: (): void => { this.emit(DeskCmd.ZOOM_FORWARD); }, onTip: (t: string): void => { this.tip(t); } })
        ToolSep()
        ToolButton({ icon: 'identify', tip: '识别（点击要素查看属性）', checked: this.activeTool === DeskTool.IDENTIFY,
          onAct: (): void => { this.pickTool(DeskTool.IDENTIFY); }, onTip: (t: string): void => { this.tip(t); } })
        ToolButton({ icon: 'measure', tip: '量测（距离 / 面积）', checked: this.activeTool === DeskTool.MEASURE,
          isEnabled: false,
          onAct: (): void => { this.pickTool(DeskTool.MEASURE); }, onTip: (t: string): void => { this.tip(t); } })
        ToolButton({ icon: 'gotoXY', tip: '转到 XY 坐标', isEnabled: false,
          onAct: (): void => { this.emit(DeskCmd.TOOL_GOTO_XY); }, onTip: (t: string): void => { this.tip(t); } })
        ToolButton({ icon: 'clearSel', tip: '清除所选要素',
          onAct: (): void => { this.emit(DeskCmd.CLEAR_SELECTION); }, onTip: (t: string): void => { this.tip(t); } })
        ToolSep()
        Blank()
        ToolButton({ icon: 'toc', tip: '内容表（TOC）', checked: this.tocOn,
          onAct: (): void => { this.emit(DeskCmd.TOC_DOCK); }, onTip: (t: string): void => { this.tip(t); } })
        ToolButton({ icon: 'table', tip: '打开属性表', checked: this.tableOn,
          onAct: (): void => { this.emit(DeskCmd.TABLE_DOCK); }, onTip: (t: string): void => { this.tip(t); } })
        Text('工具')
          .fontSize(9)
          .fontColor(DeskTheme.TEXT_DISABLED)
          .margin({ left: 4, right: 4 })
      }
      .width('100%')
      .height(DeskTheme.H_TOOLBAR)
      .padding({ left: 4, right: 4 })
      .backgroundColor(DeskTheme.TOOLBAR)
    }
    .width('100%')
    .border({ width: { bottom: 1 }, color: { bottom: DeskTheme.DIVIDER } })
  }
}