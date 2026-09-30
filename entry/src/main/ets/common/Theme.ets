// Theme.ets —— 页面级视觉常量（对应 Android res/values/colors.xml + themes.xml 的应用侧取值）。
//
// Android 靠布局里的 style/@style 继承统一外观，ArkTS 无等价的样式级联，
// 故把颜色与圆角、间距抽成常量，各页面 @Builder 复用，保证 13 个页面同一观感且可单点改色。
// 地图渲染色不在此处（见 map/MapStyle），本文件只管界面 chrome。

/** 主题色与中性色（AARRGGBB 全不透明写法，避免与 MapStyle 的无 # 前缀混用） */
export class Theme {
  /** 主色：与启动页图标、选中态一致的天蓝 */
  static readonly PRIMARY: string = '#FF3DA5FF';
  /** 主色深一档：按钮按下、标题强调 */
  static readonly PRIMARY_DARK: string = '#FF1A73C8';
  /** 危险操作色（删除、退出） */
  static readonly DANGER: string = '#FFE64545';
  /** 成功/进行中提示色 */
  static readonly OK: string = '#FF2ECC71';
  /** 采集态橙红（轨迹录制、测量采集中） */
  static readonly CAPTURE: string = '#FFFF5933';

  /** 页面背景 */
  static readonly BG: string = '#FFF2F4F7';
  /** 卡片/栏背景 */
  static readonly CARD: string = '#FFFFFFFF';
  /** 分隔线 */
  static readonly DIVIDER: string = '#FFE5E8EC';
  /** 次级背景（输入框、未选中页签） */
  static readonly SUBTLE: string = '#FFF5F6F8';

  /** 主文本 */
  static readonly TEXT: string = '#FF1F2429';
  /** 次文本（说明、时间） */
  static readonly TEXT_SUB: string = '#FF707880';
  /** 占位/禁用文本 */
  static readonly TEXT_HINT: string = '#FFA8AFB6';
  /** 深色栏上的文本 */
  static readonly TEXT_ON_DARK: string = '#FFFFFFFF';

  /** 顶栏背景（与 Android ActionBar 同色系） */
  static readonly BAR: string = '#FF2B3A4A';
  /** 半透明遮罩（地图上的加载层） */
  static readonly SCRIM: string = '#99000000';

  /** 卡片圆角 */
  static readonly RADIUS: number = 10;
  /** 页面左右留白 */
  static readonly PAD: number = 16;
  /** 卡片纵向间距 */
  static readonly GAP: number = 8;
  /** 顶栏高度 */
  static readonly BAR_HEIGHT: number = 48;
  /** 悬浮圆形按钮直径 */
  static readonly FAB: number = 44;
  /** 正文字号 */
  static readonly FONT: number = 15;
  /** 说明文字字号 */
  static readonly FONT_SUB: number = 12;
  /** 标题字号 */
  static readonly FONT_TITLE: number = 17;
}

/** 常用控件尺寸与行为常量（多页共用，避免散落魔法数） */
export class Widget {
  /** 数字滚轮/级别选择范围（对齐 Android 显示级别 NumberPicker 0-20） */
  static readonly LEVEL_MIN: number = 0;
  static readonly LEVEL_MAX: number = 20;
  /** 自动级别哨兵值（对齐 LayerInfo.UNSET_LEVEL） */
  static readonly LEVEL_AUTO: number = -1;
  /** 透明度滑条档位（0-100 百分比） */
  static readonly OPACITY_MAX: number = 100;
}
