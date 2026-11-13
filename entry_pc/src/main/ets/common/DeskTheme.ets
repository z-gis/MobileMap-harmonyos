// DeskTheme.ets —— 桌面壳的 ArcMap 经典视觉常量与共享模型。
//
// 视觉口径对齐 ArcMap 10.x（Windows 经典灰）：菜单/工具条 #F0F0F0 灰底、白色内容表与面板、
// #CDE8FF 蓝选中、1px #A8A8A8 硬边框；工具条为「图标按钮 + 分组竖线」，不用文字按钮。
// 尺度按桌面内业：菜单行 26vp、工具条 30vp、图标 18vp、按钮 26vp、状态栏 24vp。
//
// 引擎有三套互不相干的图层索引空间（HAR 各自计数，务必按 space 调对应 API）：
//   tile        —— addTileLayer / addRasterLayer：setLayerVisible / removeTileLayer
//   vector      —— addVectorLayer / addOverlayLayer：setVectorLayerVisible / removeVectorLayer
//   rasterImage —— addRasterImageLayer：setRasterImageVisible（无移除 API，只显隐）

/** 顶部工具条的活动工具（同一时刻只有一个，按下高亮） */
export enum DeskTool {
  /** 选择要素（点选高亮 + 属性表定位） */
  SELECT = 0,
  /** 平移（按住拖动；引擎既有手势，滚轮仍缩放） */
  PAN = 1,
  /** 放大（点一下以光标为锚放大一级） */
  ZOOM_IN = 2,
  /** 缩小 */
  ZOOM_OUT = 3,
  /** 识别（点要素出属性面板） */
  IDENTIFY = 4,
  /** 量测（距离/面积） */
  MEASURE = 5
}

/** 图层索引空间（见文件头注释） */
export class LayerSpace {
  static readonly TILE: string = 'tile';
  static readonly VECTOR: string = 'vector';
  static readonly RASTER_IMAGE: string = 'rasterImage';
}

/** 要素几何类别（TOC 符号色块形状用；POINT/LINE/POLYGON 与 native PickType 口径一致） */
export class GeomKind {
  static readonly POINT: string = 'POINT';
  static readonly LINE: string = 'LINE';
  static readonly POLYGON: string = 'POLYGON';
  static readonly MIXED: string = 'MIXED';
  static readonly RASTER: string = 'RASTER';
  static readonly TILE: string = 'TILE';
}

/** 命令字（菜单栏 / 工具条 / 右键菜单共用一套 id，宿主单点分发） */
export class DeskCmd {
  static readonly NEW_PROJECT: string = 'project.new';
  static readonly OPEN_PROJECT: string = 'project.open';
  static readonly SAVE_PROJECT: string = 'project.save';
  static readonly ADD_DATA: string = 'data.add';
  static readonly EXIT: string = 'app.exit';
  static readonly LAYER_PROPERTY: string = 'layer.property';
  static readonly LAYER_TABLE: string = 'layer.table';
  static readonly LAYER_ZOOM: string = 'layer.zoom';
  static readonly LAYER_REMOVE: string = 'layer.remove';
  static readonly LAYER_REFRESH: string = 'layer.refresh';
  static readonly LAYER_MOVE_GROUP: string = 'layer.moveGroup';
  static readonly GROUP_NEW: string = 'group.new';
  static readonly GROUP_RENAME: string = 'group.rename';
  static readonly GROUP_DELETE: string = 'group.delete';
  static readonly TOC_DOCK: string = 'dock.toc';
  static readonly TABLE_DOCK: string = 'dock.table';
  static readonly IDENTIFY_DOCK: string = 'dock.identify';
  static readonly ZOOM_EXTENT: string = 'view.zoomExtent';
  static readonly ZOOM_IN: string = 'view.zoomIn';
  static readonly ZOOM_OUT: string = 'view.zoomOut';
  static readonly ZOOM_BACK: string = 'view.zoomBack';
  static readonly ZOOM_FORWARD: string = 'view.zoomForward';
  static readonly CLEAR_SELECTION: string = 'view.clearSelection';
  static readonly TOGGLE_3D: string = 'view.toggle3d';
  static readonly FLIP_WHEEL: string = 'view.flipWheel';
  static readonly TOOL_MEASURE: string = 'tool.measure';
  static readonly TOOL_GOTO_XY: string = 'tool.gotoXY';
  static readonly TOOL_SRS: string = 'tool.srs';
  static readonly TOOL_OPTIONS: string = 'tool.options';
  static readonly ABOUT: string = 'help.about';
}

/** 工具中文名（状态栏用；ArkTS 枚举挂不了静态方法，故做自由函数） */
export function toolLabel(tool: DeskTool): string {
  switch (tool) {
    case DeskTool.SELECT: return '选择要素';
    case DeskTool.PAN: return '平移';
    case DeskTool.ZOOM_IN: return '放大';
    case DeskTool.ZOOM_OUT: return '缩小';
    case DeskTool.IDENTIFY: return '识别';
    case DeskTool.MEASURE: return '量测';
    default: return '选择要素';
  }
}

/** 活动工具 → 图标名（ToolIcon 的 name） */
export function toolIcon(tool: DeskTool): string {
  switch (tool) {
    case DeskTool.SELECT: return 'select';
    case DeskTool.PAN: return 'pan';
    case DeskTool.ZOOM_IN: return 'zoomIn';
    case DeskTool.ZOOM_OUT: return 'zoomOut';
    case DeskTool.IDENTIFY: return 'identify';
    case DeskTool.MEASURE: return 'measure';
    default: return 'select';
  }
}

/** 内容表（TOC）的一个图层行。class 而非 interface：@Prop 深拷贝与 @State 替换都按值语义走。 */
export class LayerRow {
  /** 未分组的哨兵 groupId */
  static readonly UNGROUPED_ID: number = -1;

  /** 显示名（数据文件主名 / 图源名） */
  name: string;
  /** 索引空间（LayerSpace 常量） */
  space: string;
  /** 引擎图层索引；-1 = 未上图的占位行 */
  engineIndex: number;
  /** 是否绘制 */
  visible: boolean;
  /** 沙箱内数据路径（在线底图为空串） */
  path: string;
  /** 几何类别（GeomKind 常量），决定符号色块形状 */
  geom: string;
  /** 符号主色 #AARRGGBB（TOC 色块与样式编辑共用） */
  color: number;
  /** 要素总数（-1 = 未知/不适用） */
  featureCount: number;
  /** 四至 [minLon,minLat,maxLon,maxLat]；空数组 = 未知 */
  extent: number[];
  /** 所属分组 id；-1 = 未分组（PC 端仅内存态，不落盘） */
  groupId: number;
  /** 已应用的标注字段（空串 = 不标注）；换层/刷新要按它重建样式，否则标注丢 */
  labelField: string;

  constructor(name: string, space: string, engineIndex: number, visible: boolean,
    path: string = '', geom: string = GeomKind.MIXED, color: number = 0xFF1F6FB2,
    featureCount: number = -1, extent: number[] = [], groupId: number = LayerRow.UNGROUPED_ID,
    labelField: string = '') {
    this.name = name;
    this.space = space;
    this.engineIndex = engineIndex;
    this.visible = visible;
    this.path = path;
    this.geom = geom;
    this.color = color;
    this.featureCount = featureCount;
    this.extent = extent;
    this.groupId = groupId;
    this.labelField = labelField;
  }

  /** 是否矢量数据层（可识别、可开属性表） */
  isVector(): boolean {
    return this.space === LayerSpace.VECTOR && this.path.length > 0;
  }

  /** 类型标注（TOC「源」页签与图层属性用） */
  kindLabel(): string {
    if (this.space === LayerSpace.TILE) {
      return this.path.length > 0 ? '栅格（瓦片）' : '在线底图';
    }
    return this.space === LayerSpace.RASTER_IMAGE ? '栅格（全幅）' : '矢量';
  }
}

/** TOC 的一个图层分组（PC 端仅内存态，无持久化）。 */
export class DeskLayerGroup {
  id: number;
  name: string;

  constructor(id: number = 0, name: string = '') {
    this.id = id;
    this.name = name;
  }
}

/** 识别结果 / 属性表的一个字段值对 */
export class AttrField {
  key: string;
  value: string;

  constructor(key: string, value: string) {
    this.key = key;
    this.value = value;
  }
}

/** 属性表一页数据（表头 + 行 + 每行 FID，行点击据此定位要素） */
export class TablePage {
  headers: string[];
  rows: string[][];
  fids: number[];
  /** 数据总要素数（分页用） */
  total: number;
  /** 当前页起始行号（0 起） */
  offset: number;
  /** 出错时的中文原因；空串 = 正常 */
  error: string;
  /** 多子层数据源（gpkg）中本页所属子层名；单表为空串 */
  subLayer: string = '';

  constructor(headers: string[] = [], rows: string[][] = [], fids: number[] = [],
    total: number = 0, offset: number = 0, error: string = '') {
    this.headers = headers;
    this.rows = rows;
    this.fids = fids;
    this.total = total;
    this.offset = offset;
    this.error = error;
  }
}

/** 坐标显示单位（状态栏下拉，ArcMap 同款三档） */
export enum CoordUnit {
  /** 十进制度 */
  DEG = 0,
  /** 度分秒 */
  DMS = 1,
  /** 度分 */
  DM = 2
}

export class DeskTheme {
  // ── ArcMap 经典灰外壳 ──
  static readonly WINDOW: string = '#E4E4E4';
  static readonly CHROME: string = '#F0F0F0';
  static readonly TOOLBAR: string = '#F4F4F4';
  static readonly PANEL: string = '#FFFFFF';
  static readonly MAP_BG: string = '#D6DADF';
  static readonly HOVER: string = '#E5F1FB';
  static readonly ACTIVE: string = '#CDE8FF';
  static readonly ACTIVE_BORDER: string = '#7EB4EA';
  static readonly SELECT_ROW: string = '#DCE9F7';
  static readonly DIVIDER: string = '#A8A8A8';
  static readonly DIVIDER_SOFT: string = '#D8D8D8';
  static readonly GRID_LINE: string = '#E6E6E6';

  // ── 文字 ──
  static readonly TEXT: string = '#1A1A1A';
  static readonly TEXT_SUB: string = '#4A4A4A';
  static readonly TEXT_DISABLED: string = '#9A9A9A';
  static readonly ACCENT: string = '#1E6FBF';
  /** ArcMap 选中要素高亮：青色 */
  static readonly HILIGHT: string = '#00E5EE';
  static readonly HILIGHT_ARGB: number = 0xFF00E5EE;

  // ── 尺度（vp）──
  static readonly H_MENU: number = 26;
  static readonly H_TOOLBAR: number = 30;
  static readonly H_STATUS: number = 24;
  static readonly BTN: number = 26;
  static readonly ICON: number = 18;
  static readonly DOCK_MIN_W: number = 220;
  static readonly DOCK_MIN_H: number = 120;
  static readonly ROW_H: number = 24;
  static readonly PAD: number = 8;

  static readonly FONT_MENU: number = 12;
  static readonly FONT_CAPTION: number = 11;
  static readonly FONT_BODY: number = 12;
  static readonly FONT_STATUS: number = 11;

  /** 符号系统预设色板（#AARRGGBB，ArcMap 调色板常见色） */
  static readonly PALETTE: number[] = [
    0xFFFF0000, 0xFFFF8C00, 0xFFFFFF00, 0xFF7CFC00, 0xFF008000, 0xFF00CED1,
    0xFF1E90FF, 0xFF0000CD, 0xFF8A2BE2, 0xFFFF1493, 0xFF8B4513, 0xFF000000,
    0xFF808080, 0xFFFFFFFF
  ];

  /** #AARRGGBB → CSS #RRGGBB（ArkUI 色块用；alpha 另经 rgba() 表达） */
  static css(argb: number): string {
    const hex: string = (argb & 0xFFFFFF).toString(16).toUpperCase();
    return `#${'000000'.substring(0, 6 - hex.length)}${hex}`;
  }

  /** #AARRGGBB → CSS rgba()（色块要显示半透明填充） */
  static rgba(argb: number): string {
    const a: number = (argb >>> 24) & 0xFF;
    const r: number = (argb >>> 16) & 0xFF;
    const g: number = (argb >>> 8) & 0xFF;
    const b: number = argb & 0xFF;
    return `rgba(${r},${g},${b},${(a / 255).toFixed(3)})`;
  }
}