// ToolIcon.ets —— 工具条图标：18×18vp 矢量笔画，不依赖图片资源。
//
// 为什么自绘而不用 SymbolGlyph/图片：本模块没有图标资源目录，且 ArcMap 的放大镜/手形/黄加号
// 是特定形状，系统 symbol 库里没有对应项；Path 笔画在任意 DPI 下都清晰，改色只改 stroke。
// 数据驱动（name → 笔画数组）而不是 @Builder 传参：@Builder 的值参只在首次渲染快照，
// 工具切换时不会刷新（本项目已实测踩过），ForEach 直接读 this.name 则每次重算。
import { DeskTheme } from '../common/DeskTheme';

/** 一条笔画：SVG path 命令 + 填充/描边色 + 线宽（vp） */
class Stroke {
  d: string;
  fill: string;
  stroke: string;
  width: number;

  constructor(d: string, fill: string, stroke: string, width: number) {
    this.d = d;
    this.fill = fill;
    this.stroke = stroke;
    this.width = width;
  }
}

const NONE: string = 'rgba(0,0,0,0)';
const INK: string = '#2A2A2A';
const BLUE: string = '#1E6FBF';
const RULE: string = '#8A6D00';

/** 放大镜镜片 + 手柄（zoomIn/zoomOut 共用，符号另叠） */
const GLASS: Stroke[] = [
  new Stroke('M12.4 7.4 C12.4 10.16 10.16 12.4 7.4 12.4 C4.64 12.4 2.4 10.16 2.4 7.4 '
    + 'C2.4 4.64 4.64 2.4 7.4 2.4 C10.16 2.4 12.4 4.64 12.4 7.4 Z', '#FFFFFF', INK, 1.3),
  new Stroke('M11.1 11.1 L16.2 16.2', NONE, INK, 2.2)
];

function strokes(name: string): Stroke[] {
  switch (name) {
    case 'select':
      return [
        new Stroke('M3.6 1.6 L3.6 14.2 L6.9 11.1 L9.1 16 L11.3 15 L9.1 10.2 L13.7 9.9 Z',
          INK, '#FFFFFF', 0.7)
      ];
    case 'pan':
      return [
        new Stroke('M6 10 L6 5 C6 3.9 7.7 3.9 7.7 5 L7.7 9.2 L7.7 3.6 C7.7 2.5 9.4 2.5 9.4 3.6 '
          + 'L9.4 9.2 L9.4 4.3 C9.4 3.2 11.1 3.2 11.1 4.3 L11.1 9.6 L11.1 6.6 '
          + 'C11.1 5.5 12.8 5.5 12.8 6.6 L12.8 11.8 C12.8 14.6 11.1 16.2 8.6 16.2 '
          + 'L7.8 16.2 C6.2 16.2 5.1 15.4 4.3 14 L2.9 11.6 C2.3 10.5 3.7 9.5 4.5 10.3 Z',
          '#FFFFFF', INK, 1.1)
      ];
    case 'zoomIn':
      return GLASS.concat([new Stroke('M4.9 7.4 H9.9 M7.4 4.9 V9.9', NONE, BLUE, 1.5)]);
    case 'zoomOut':
      return GLASS.concat([new Stroke('M4.9 7.4 H9.9', NONE, BLUE, 1.5)]);
    case 'extent':
      return [
        new Stroke('M16 9 C16 12.87 12.87 16 9 16 C5.13 16 2 12.87 2 9 C2 5.13 5.13 2 9 2 '
          + 'C12.87 2 16 5.13 16 9 Z', '#DCEBFA', BLUE, 1.3),
        new Stroke('M2.4 9 H15.6 M9 2.2 C5.6 5.2 5.6 12.8 9 15.8 C12.4 12.8 12.4 5.2 9 2.2 Z',
          NONE, BLUE, 1)
      ];
    case 'identify':
      return [
        new Stroke('M16 9 C16 12.87 12.87 16 9 16 C5.13 16 2 12.87 2 9 C2 5.13 5.13 2 9 2 '
          + 'C12.87 2 16 5.13 16 9 Z', '#FFFFFF', BLUE, 1.4),
        new Stroke('M9 8 V13', NONE, BLUE, 1.8),
        new Stroke('M9 4.9 V6.3', NONE, BLUE, 1.8)
      ];
    case 'measure':
      return [
        new Stroke('M1.6 11.6 L11.6 1.6 L16.4 6.4 L6.4 16.4 Z', '#FFF3C4', RULE, 1.2),
        new Stroke('M4.4 11.6 L6 13.2 M6.9 9.1 L8.5 10.7 M9.4 6.6 L11 8.2 M11.9 4.1 L13.5 5.7',
          NONE, RULE, 1)
      ];
    case 'addData':
      return [
        new Stroke('M7 1.6 H11 V7 H16.4 V11 H11 V16.4 H7 V11 H1.6 V7 H7 Z', '#FFC000', '#7F6000', 1)
      ];
    case 'table':
      return [
        new Stroke('M2 3 H16 V15.4 H2 Z', '#FFFFFF', INK, 1.2),
        new Stroke('M2 3 H16 V6.6 H2 Z', '#CDE8FF', INK, 1.2),
        new Stroke('M2 9.6 H16 M2 12.5 H16 M6.6 6.6 V15.4 M11.3 6.6 V15.4', NONE, '#9A9A9A', 0.8)
      ];
    case 'toc':
      return [
        new Stroke('M2.4 3.4 H6.4 V7.4 H2.4 Z M2.4 10.6 H6.4 V14.6 H2.4 Z', '#CDE8FF', INK, 1),
        new Stroke('M8.6 5.4 H16 M8.6 12.6 H16', NONE, INK, 1.3)
      ];
    case 'back':
      return [
        new Stroke('M10.6 3.4 L5 9 L10.6 14.6', NONE, BLUE, 2),
        new Stroke('M5.4 9 H15', NONE, BLUE, 2)
      ];
    case 'forward':
      return [
        new Stroke('M7.4 3.4 L13 9 L7.4 14.6', NONE, BLUE, 2),
        new Stroke('M3 9 H12.6', NONE, BLUE, 2)
      ];
    case 'clearSel':
      return [
        new Stroke('M2.6 2.6 H15.4 V15.4 H2.6 Z', '#FFFFFF', '#6A6A6A', 1.2),
        new Stroke('M5.6 5.6 L12.4 12.4 M12.4 5.6 L5.6 12.4', NONE, '#C00000', 1.8)
      ];
    case 'save':
      return [
        new Stroke('M2.4 2.4 H13 L15.6 5 V15.6 H2.4 Z', '#4A7EBB', '#23496F', 1),
        new Stroke('M5.6 2.4 H11 V7 H5.6 Z', '#FFFFFF', '#23496F', 0.8),
        new Stroke('M5 10 H13 V15.6 H5 Z', '#FFFFFF', '#23496F', 0.8)
      ];
    case 'open':
      return [
        new Stroke('M1.6 4.4 H7 L8.6 6.4 H16.4 V14.6 H1.6 Z', '#FFD980', RULE, 1)
      ];
    case 'new':
      return [
        new Stroke('M4 1.6 H11 L14.4 5 V16.4 H4 Z', '#FFFFFF', INK, 1.2),
        new Stroke('M11 1.6 V5 H14.4', NONE, INK, 1)
      ];
    case 'props':
      return [
        new Stroke('M3.4 1.6 H11 L14.6 5.2 V16.4 H3.4 Z', '#FFFFFF', INK, 1.2),
        new Stroke('M5.8 8 H12.2 M5.8 10.6 H12.2 M5.8 13.2 H10', NONE, BLUE, 1.1)
      ];
    case 'refresh':
      return [
        new Stroke('M15 9 C15 5.7 12.3 3 9 3 C5.7 3 3 5.7 3 9 C3 12.3 5.7 15 9 15',
          NONE, BLUE, 1.6),
        new Stroke('M15 4.2 V9 H10.2', NONE, BLUE, 1.6)
      ];
    case 'remove':
      return [new Stroke('M4 4 L14 14 M14 4 L4 14', NONE, '#C00000', 2.2)];
    case 'gotoXY':
      return [
        new Stroke('M13.4 9 C13.4 11.43 11.43 13.4 9 13.4 C6.57 13.4 4.6 11.43 4.6 9 '
          + 'C4.6 6.57 6.57 4.6 9 4.6 C11.43 4.6 13.4 6.57 13.4 9 Z', NONE, INK, 1.2),
        new Stroke('M9 1.4 V5.4 M9 12.6 V16.6 M1.4 9 H5.4 M12.6 9 H16.6', NONE, INK, 1.2)
      ];
    case 'print':
      return [
        new Stroke('M4.6 1.8 H13.4 V6 H4.6 Z', '#FFFFFF', INK, 1),
        new Stroke('M2.4 6 H15.6 V12 H13.4 V16.2 H4.6 V12 H2.4 Z', '#DDDDDD', INK, 1),
        new Stroke('M4.6 10.4 H13.4 V16.2 H4.6 Z', '#FFFFFF', INK, 0.9)
      ];
    case 'undo':
      return [
        new Stroke('M4 8.4 H10.4 C13 8.4 14.6 10.2 14.6 12.2 C14.6 14.2 13 15.6 10.6 15.6',
          NONE, INK, 1.6),
        new Stroke('M7.2 4.8 L3.6 8.4 L7.2 12', NONE, INK, 1.6)
      ];
    case 'redo':
      return [
        new Stroke('M14 8.4 H7.6 C5 8.4 3.4 10.2 3.4 12.2 C3.4 14.2 5 15.6 7.4 15.6',
          NONE, INK, 1.6),
        new Stroke('M10.8 4.8 L14.4 8.4 L10.8 12', NONE, INK, 1.6)
      ];
    case 'dataFrame':
      return [
        new Stroke('M1.8 2.6 H16.2 V15.4 H1.8 Z', '#FFFFFF', INK, 1.1),
        new Stroke('M13.6 9 C13.6 11.54 11.54 13.6 9 13.6 C6.46 13.6 4.4 11.54 4.4 9 '
          + 'C4.4 6.46 6.46 4.4 9 4.4 C11.54 4.4 13.6 6.46 13.6 9 Z', '#DCEBFA', BLUE, 1),
        new Stroke('M4.6 9 H13.4 M9 4.5 C6.6 6.6 6.6 11.4 9 13.5 C11.4 11.4 11.4 6.6 9 4.5 Z',
          NONE, BLUE, 0.8)
      ];
    case 'folder':
      return [
        new Stroke('M2.2 4.4 H7 L8.6 6.2 H15.8 V14.4 H2.2 Z', '#F3D98B', INK, 1)
      ];
    default:
      return [new Stroke('M3 3 H15 V15 H3 Z', NONE, DeskTheme.TEXT_DISABLED, 1.2)];
  }
}

@Component
export struct ToolIcon {
  /** 图标名（strokes() 的 case）；@Prop 保证工具切换时重算笔画 */
  @Prop name: string = 'select';

  build() {
    Stack() {
      ForEach(strokes(this.name), (s: Stroke, i: number) => {
        Path()
          .commands(s.d)
          .width(DeskTheme.ICON)
          .height(DeskTheme.ICON)
          .fill(s.fill)
          .stroke(s.stroke)
          .strokeWidth(s.width)
          .antiAlias(true)
      }, (s: Stroke, i: number): string => `${this.name}-${i}`)
    }
    .width(DeskTheme.ICON)
    .height(DeskTheme.ICON)
  }
}