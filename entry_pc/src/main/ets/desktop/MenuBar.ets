// MenuBar.ets —— ArcMap 式菜单栏：文件 / 编辑 / 视图 / 插入 / 选择 / 地理处理 / 自定义 / 窗口 / 帮助。
//
// 系统没有 menu_bar 组件，桌面惯例做法是「一行文本 + bindMenu(MenuElement[])」：点击即弹出，
// 项内动作统一回抛命令字给宿主（Workbench 单点分发，后面接快捷键只改一处）。
// 未接后端的项 enabled:false——先把 ArcMap 的菜单骨架给全，避免接功能时再动结构。
// 菜单数组在 build 期按 @Prop 重算（而不是 aboutToAppear 建一次），否则可用态刷不进来。
import { DeskCmd, DeskTheme } from '../common/DeskTheme';

class MenuDef {
  label: string;
  items: MenuElement[];

  constructor(label: string, items: MenuElement[]) {
    this.label = label;
    this.items = items;
  }
}

@Component
export struct MenuBar {
  onCommand: ((cmd: string) => void) | undefined = undefined;
  @Prop canBack: boolean = false;
  @Prop canForward: boolean = false;
  @Prop hasSelection: boolean = false;
  @Prop busy: boolean = false;

  private emit(cmd: string): void {
    const cb = this.onCommand;
    if (cb !== undefined) {
      cb(cmd);
    }
  }

  private item(text: string, cmd: string, enabled: boolean = true): MenuElement {
    return {
      value: text,
      enabled: enabled,
      action: (): void => {
        this.emit(cmd);
      }
    };
  }

  private disabled(text: string): MenuElement {
    return { value: text, enabled: false, action: (): void => {} };
  }

  private menus(): MenuDef[] {
    const file: MenuElement[] = [
      this.disabled('新建地图文档…'),
      this.disabled('打开地图文档…'),
      this.disabled('保存地图文档'),
      this.item('添加数据…', DeskCmd.ADD_DATA, !this.busy),
      this.disabled('导出地图…'),
      this.item('退出', DeskCmd.EXIT)
    ];
    const edit: MenuElement[] = [
      this.disabled('撤销'),
      this.disabled('重做'),
      this.item('清除所选要素', DeskCmd.CLEAR_SELECTION, this.hasSelection)
    ];
    const view: MenuElement[] = [
      this.item('放大', DeskCmd.ZOOM_IN),
      this.item('缩小', DeskCmd.ZOOM_OUT),
      this.item('全图', DeskCmd.ZOOM_EXTENT),
      this.item('返回上一视图', DeskCmd.ZOOM_BACK, this.canBack),
      this.item('前进到下一视图', DeskCmd.ZOOM_FORWARD, this.canForward),
      this.item('二维 / 三维切换', DeskCmd.TOGGLE_3D),
      this.item('反转鼠标滚轮方向', DeskCmd.FLIP_WHEEL),
      this.item('内容表', DeskCmd.TOC_DOCK),
      this.item('属性表', DeskCmd.TABLE_DOCK),
      this.item('识别结果', DeskCmd.IDENTIFY_DOCK)
    ];
    const insert: MenuElement[] = [
      this.disabled('数据框'),
      this.disabled('图例'),
      this.disabled('指北针'),
      this.disabled('比例尺'),
      this.disabled('比例文本')
    ];
    const selection: MenuElement[] = [
      this.item('清除所选要素', DeskCmd.CLEAR_SELECTION, this.hasSelection),
      this.disabled('缩放至所选要素'),
      this.disabled('按属性选择…'),
      this.disabled('按位置选择…')
    ];
    const geoprocessing: MenuElement[] = [
      this.disabled('缓冲区…'),
      this.disabled('裁剪…'),
      this.disabled('融合…'),
      this.disabled('相交…')
    ];
    const customize: MenuElement[] = [
      this.disabled('工具条'),
      this.disabled('加载项…'),
      this.item('选项…', DeskCmd.TOOL_OPTIONS, false)
    ];
    const windows: MenuElement[] = [
      this.item('内容表', DeskCmd.TOC_DOCK),
      this.item('属性表', DeskCmd.TABLE_DOCK),
      this.item('识别结果', DeskCmd.IDENTIFY_DOCK)
    ];
    const help: MenuElement[] = [
      this.item('关于调查宝', DeskCmd.ABOUT)
    ];
    return [
      new MenuDef('文件(F)', file),
      new MenuDef('编辑(E)', edit),
      new MenuDef('视图(V)', view),
      new MenuDef('插入(I)', insert),
      new MenuDef('选择(S)', selection),
      new MenuDef('地理处理(G)', geoprocessing),
      new MenuDef('自定义(C)', customize),
      new MenuDef('窗口(W)', windows),
      new MenuDef('帮助(H)', help)
    ];
  }

  build() {
    Row() {
      ForEach(this.menus(), (menu: MenuDef) => {
        Text(menu.label)
          .fontSize(DeskTheme.FONT_MENU)
          .fontColor(DeskTheme.TEXT)
          .height('100%')
          .padding({ left: 9, right: 9 })
          .hoverEffect(HoverEffect.Highlight)
          .bindMenu(menu.items)
      }, (menu: MenuDef): string => menu.label)
      Blank()
    }
    .width('100%')
    .height(DeskTheme.H_MENU)
    .padding({ left: 2 })
    .backgroundColor(DeskTheme.CHROME)
    .border({ width: { bottom: 1 }, color: { bottom: DeskTheme.DIVIDER_SOFT } })
  }
}