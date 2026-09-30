// MapStyle.ets —— 地图样式常量与文档样式→渲染样式映射（对应 Android ui.map.MapStyleColors）。
//
// 全部色值为 #AARRGGBB 无符号数值，与渲染内核 VectorStyle 字段同语义；
// 业务叠加层（测量/轨迹/照片/样地/查询/选中）的配色集中在此，保证地图显示与对话框回显同源。

import { VectorStyle } from '@zys/globecore';
import { ColorHex } from '../common/ColorHex';
import { StyleOverride } from '../doc/DocModels';

export class MapStyle {
  // ── 矢量层默认样式（未设置样式覆盖时的取值，与内核默认一致）──────────────
  static readonly DEFAULT_FILL_COLOR: number = 0x664A8FE3;
  static readonly DEFAULT_POLYGON_OUTLINE_COLOR: number = 0xFFFFFFFF;
  static readonly DEFAULT_LINE_COLOR: number = 0xFFE66B33;
  static readonly DEFAULT_OUTLINE_WIDTH: number = 1.0;
  static readonly DEFAULT_LINE_WIDTH: number = 2.0;
  static readonly DEFAULT_POINT_RADIUS_DP: number = 5;
  static readonly DEFAULT_LABEL_COLOR: number = 0xFFFFFFFF;
  static readonly DEFAULT_LABEL_SIZE: number = 1.0;
  static readonly DEFAULT_LABEL_OUTLINE_COLOR: number = 0xFF000000;

  // ── 测量 ─────────────────────────────────────────────────────────
  static readonly MEASURE_COLOR_DISTANCE: number = 0xFF57ACFD;
  static readonly MEASURE_COLOR_AREA: number = 0xFF2ECC71;
  static readonly MEASURE_COLOR_POINT: number = 0xFFF1C40F;
  static readonly MEASURE_LIVE_WIDTH: number = 3;
  static readonly MEASURE_POINT_RADIUS_DP: number = 6;
  /** 面积实时预览填充透明度（0..1） */
  static readonly MEASURE_AREA_FILL_ALPHA: number = 0.22;

  // ── 轨迹 ─────────────────────────────────────────────────────────
  static readonly TRACK_ACTIVE_COLOR: number = 0xFFFF5933;
  static readonly TRACK_ACTIVE_WIDTH: number = 4;
  /** 轨迹采集最小间距（米）：小于该距离的定位点丢弃，抑制 GPS 抖动毛刺 */
  static readonly MIN_TRACK_POINT_DISTANCE_METERS: number = 5;

  // ── 业务点（照片 / 样地）──────────────────────────────────────────
  static readonly PHOTO_POINT_RADIUS_DP: number = 6;
  static readonly SURVEY_POINT_RADIUS_DP: number = 6;
  static readonly SURVEY_COLOR: number = 0xFF8E44AD;
  /** 照片点位图标着色（Android 侧为 ic_media 图标资源，鸿蒙侧程序化生成同形色） */
  static readonly PHOTO_ICON_COLOR: number = 0xFF1E88E5;
  /** 样地点位图标着色 */
  static readonly SURVEY_ICON_COLOR: number = 0xFF8E44AD;

  // ── SQL 查询高亮（洋红）───────────────────────────────────────────
  static readonly QUERY_FILL: number = 0x59FF00FF;
  static readonly QUERY_OUTLINE: number = 0xFFFF00FF;
  static readonly QUERY_LINE_WIDTH: number = 3;
  static readonly QUERY_POINT_RADIUS: number = 7;

  // ── 拾取选中高亮（黄）─────────────────────────────────────────────
  static readonly SELECT_FILL: number = 0x73FFFF00;
  static readonly SELECT_OUTLINE: number = 0xFFFFFF00;
  static readonly SELECT_LINE_WIDTH: number = 3.0;
  static readonly SELECT_POINT_RADIUS: number = 7.0;

  /** 中心十字线颜色（屏幕坐标绘制，非渲染内核对象） */
  static readonly CENTER_CROSS_COLOR: string = '#FF3DA5FF';

  /**
   * 文档样式覆盖 → 渲染样式。
   * 规则与 Android 侧一致：
   *  · 未设置项保持默认；
   *  · fillEnabled === false → 填充色 alpha 置 0（仅描边）；
   *  · fillOpacity 存在 → 覆盖填充色 alpha（0..1 映射到 0..255）。
   * @param override 图层样式覆盖（可为 undefined = 全默认）
   * @param labelFieldOverride 标注字段最终来源（showKmlLabel 等外部门控由调用方决定传空串）
   */
  static toVectorStyle(override: StyleOverride | undefined,
    labelFieldOverride: string | undefined = undefined): VectorStyle {
    const style: VectorStyle = new VectorStyle(
      MapStyle.DEFAULT_FILL_COLOR, MapStyle.DEFAULT_POLYGON_OUTLINE_COLOR,
      MapStyle.DEFAULT_OUTLINE_WIDTH, MapStyle.DEFAULT_LINE_COLOR, MapStyle.DEFAULT_LINE_WIDTH,
      MapStyle.DEFAULT_LINE_COLOR, MapStyle.DEFAULT_POINT_RADIUS_DP,
      '', MapStyle.DEFAULT_LABEL_COLOR, MapStyle.DEFAULT_LABEL_SIZE,
      false, MapStyle.DEFAULT_LABEL_OUTLINE_COLOR);
    const o: StyleOverride | undefined = override;
    if (o !== undefined && o !== null) {
      const outline: string | undefined = o.outlineColor;
      if (outline !== undefined) {
        const argb: number = ColorHex.parse(outline, MapStyle.DEFAULT_POLYGON_OUTLINE_COLOR);
        style.outlineColor = argb;
        style.lineColor = argb;
        style.pointColor = argb;
      }
      const outlineWidth: number | undefined = o.outlineWidth;
      if (outlineWidth !== undefined) {
        style.outlineWidth = outlineWidth;
        style.lineWidth = outlineWidth;
      }
      const fill: string | undefined = o.fillColor;
      if (fill !== undefined) {
        style.fillColor = MapStyle.resolveFillColor(fill, o.fillOpacity, o.fillEnabled);
      } else if (o.fillEnabled === false) {
        style.fillColor = 0;
      } else if (o.fillOpacity !== undefined) {
        style.fillColor = MapStyle.resolveFillColor(
          `${ColorHex.toHex(MapStyle.DEFAULT_FILL_COLOR)}`, o.fillOpacity, o.fillEnabled);
      }
      const labelColor: string | undefined = o.labelColor;
      if (labelColor !== undefined) {
        style.labelColor = ColorHex.parse(labelColor, MapStyle.DEFAULT_LABEL_COLOR);
      }
      const labelSize: number | undefined = o.labelSize;
      if (labelSize !== undefined) {
        style.labelSize = labelSize;
      }
      style.labelOutline = o.labelOutline ?? false;
      const labelOutlineColor: string | undefined = o.labelOutlineColor;
      if (labelOutlineColor !== undefined) {
        style.labelOutlineColor = ColorHex.parse(labelOutlineColor, MapStyle.DEFAULT_LABEL_OUTLINE_COLOR);
      }
    }
    const field: string | undefined = labelFieldOverride ?? (o === undefined ? undefined : o.labelField);
    style.labelField = field ?? '';
    return style;
  }

  /** 无覆盖时的纯默认样式 */
  static defaultStyle(): VectorStyle {
    return MapStyle.toVectorStyle(undefined);
  }

  /** 填充色解析：色值 + 透明度覆盖 + 填充开关 */
  static resolveFillColor(hex: string, opacity: number | undefined,
    enabled: boolean | undefined): number {
    if (enabled === false) {
      return 0;
    }
    const rgb: number = ColorHex.parse(hex, MapStyle.DEFAULT_FILL_COLOR);
    if (opacity === undefined) {
      return rgb;
    }
    const alpha: number = Math.max(0, Math.min(255, Math.round(opacity * 255)));
    return ColorHex.withAlpha(rgb, alpha);
  }

  /** ARGB → '#AARRGGBB'（样式对话框回显） */
  static argbToHex(argb: number): string {
    return `#${ColorHex.toHex(argb)}`;
  }

  /** 单层样式：仅线（测量/轨迹活动层） */
  static lineStyle(color: number, width: number): VectorStyle {
    const style: VectorStyle = MapStyle.defaultStyle();
    style.lineColor = color;
    style.lineWidth = width;
    style.fillColor = 0;
    style.labelField = '';
    return style;
  }

  /** 单层样式：仅点（测点标记层，半径即 dp） */
  static pointStyle(color: number, radiusDp: number): VectorStyle {
    const style: VectorStyle = MapStyle.defaultStyle();
    style.pointColor = color;
    style.pointRadiusDp = radiusDp;
    style.fillColor = 0;
    return style;
  }

  /** 单层样式：纯文字标注层（点半径 0 = 只画标注） */
  static labelStyle(labelColor: number, labelSize: number, outline: boolean,
    outlineColor: number): VectorStyle {
    const style: VectorStyle = MapStyle.defaultStyle();
    style.pointRadiusDp = 0;
    style.pointColor = 0;
    style.fillColor = 0;
    style.labelColor = labelColor;
    style.labelSize = labelSize;
    style.labelOutline = outline;
    style.labelOutlineColor = outlineColor;
    return style;
  }
}
