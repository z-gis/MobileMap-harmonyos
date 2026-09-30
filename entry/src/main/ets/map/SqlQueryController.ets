// SqlQueryController.ets —— SQL 可视化查询高亮（对应 Android ui.map.SqlQueryController）。
//
// 图层管理页 shp/gpkg 的查询键经 GdalVectorReader.queryFeatures 取命中要素（已重投影 WGS84），
// 清除旧高亮后按几何类型叠加洋红高亮叠加层并缩放到结果四至。
// 高亮为临时叠加、不写文档，故缓存命中要素于 BusinessOverlayManager.rebuild 后重建保留：
//  · onOverlayLayersCleared：clearOverlayLayers 后仅失效索引（保留命中缓存）；
//  · restoreAfterRebuild：重建末尾按缓存要素重画高亮层；
//  · sourcePathIfHit：高亮层命中时回源文件路径，供 FeaturePickController 穿透弹源要素详情
//    （高亮层已置 noPick 不参与 native 拾取，本方法仅作防护兜底）。

import { NativeMapView, VectorStyle } from '@zys/globecore';
import { AppLog } from '../common/AppLog';
import { Ui } from '../common/Ui';
import { GeomType, GdalVectorReader, VectorFeature, VectorResult } from '../vector/GdalVectorReader';
import { CameraNavigator } from './CameraNavigator';
import { MapStyle } from './MapStyle';

/** 结果回调：宿主按 count 刷新查询状态条 / 结果列表 */
export type QueryResultListener = (path: string, features: VectorFeature[]) => void;

export class SqlQueryController {
  private readonly view: NativeMapView;
  private readonly navigator: CameraNavigator;

  /** 命中要素缓存（临时叠加、不写文档，重建后据此恢复） */
  private queryHighlight: VectorFeature[] | null = null;
  /** 查询高亮占用的叠加层索引 */
  private queryOverlayIndices: number[] = [];
  /** 当前查询的源文件路径：高亮层命中时点击穿透回源要素、按 FID 回取属性用 */
  private queryPath: string | undefined = undefined;

  onResult: QueryResultListener | undefined = undefined;

  constructor(view: NativeMapView, navigator: CameraNavigator) {
    this.view = view;
    this.navigator = navigator;
  }

  /** 当前查询源路径（无查询结果时 undefined） */
  activeQueryPath(): string | undefined {
    return this.queryPath;
  }

  /** 当前命中要素列表（供结果页复用，不重复查库） */
  activeResult(): VectorFeature[] {
    return this.queryHighlight === null ? [] : this.queryHighlight;
  }

  /**
   * 执行 shp/gpkg 图层 SQL 查询：GDAL 属性过滤取命中要素，清除旧高亮后按几何类型叠加洋红高亮层
   * 并缩放到结果四至；语句错误按 GDAL/OGR 原因长时提示。
   * GDAL 打开为同步 native 调用（大文件可能秒级），故先出提示再经 setTimeout 让出一帧执行。
   */
  runQuery(path: string, sql: string): void {
    Ui.toast('正在执行查询…');
    setTimeout((): void => {
      try {
        this.runImpl(path, sql);
      } catch (e) {
        AppLog.e('SQL 查询异常', e);
        Ui.toastLong(`查询失败：${e}`);
      }
    }, 0);
  }

  private runImpl(path: string, sql: string): void {
    const result: VectorResult = GdalVectorReader.queryFeatures(path, sql);
    if (!result.isSuccess()) {
      Ui.toastLong(`查询失败：${result.error}`);
      return;
    }
    const features: VectorFeature[] = result.features === null ? [] : result.features;
    // 无论命中与否先清旧高亮，避免多次查询叠加
    this.clearHighlight();
    if (features.length === 0) {
      Ui.toast('未查询到符合条件的要素');
      if (this.onResult !== undefined) {
        this.onResult(path, []);
      }
      return;
    }
    this.queryHighlight = features;
    this.queryPath = path;
    this.addHighlightOverlay(features);
    const ext: number[] | null = SqlQueryController.extentOf(features);
    if (ext !== null) {
      this.navigator.zoomToExtent(ext[0], ext[1], ext[2], ext[3]);
    }
    Ui.toast(`查询到 ${features.length} 个要素`);
    if (this.onResult !== undefined) {
      this.onResult(path, features);
    }
  }

  /** 清除地图上的 SQL 查询高亮结果（图层管理「清除」键入口） */
  clearSqlQuery(): void {
    this.clearHighlight();
    Ui.toast('已清除查询结果');
  }

  /** 拆除查询高亮层并清缓存（幂等）：墓碑各高亮层，清空索引与命中要素缓存 */
  private clearHighlight(): void {
    for (let i = 0; i < this.queryOverlayIndices.length; i++) {
      this.view.removeOverlayLayer(this.queryOverlayIndices[i]);
    }
    this.queryOverlayIndices = [];
    this.queryHighlight = null;
    this.queryPath = undefined;
  }

  /**
   * 命中要素 → 洋红高亮叠加层（叠加层一层一种几何类型，故按点/线/面分建至多三层）。
   * VectorFeature 的摊平坐标已是 [lon,lat,…] 顺序，与 updateOverlay* 入参同构，无需换序。
   * 高亮层置 noPick 不参与拾取：其大面积几何会遮蔽测量/拍照等业务叠加与源要素的点击，
   * 命中直接落到下方源矢量层。
   */
  private addHighlightOverlay(features: VectorFeature[]): void {
    const points: VectorFeature[] = features.filter(
      (f: VectorFeature): boolean => f.geom === GeomType.POINT);
    const lines: VectorFeature[] = features.filter(
      (f: VectorFeature): boolean => f.geom === GeomType.LINE);
    const polys: VectorFeature[] = features.filter(
      (f: VectorFeature): boolean => f.geom === GeomType.POLYGON);

    if (points.length > 0) {
      const idx: number = this.view.addOverlayLayer(SqlQueryController.queryStyle(false));
      if (idx >= 0) {
        this.view.setOverlayNoPick(idx, true);
        this.queryOverlayIndices.push(idx);
        const lonlat: number[] = [];
        const fids: number[] = [];
        for (let i = 0; i < points.length; i++) {
          lonlat.push(points[i].x);
          lonlat.push(points[i].y);
          fids.push(points[i].fid);
        }
        this.view.updateOverlayPoints(idx, lonlat, fids);
      }
    }

    if (lines.length > 0) {
      const idx: number = this.view.addOverlayLayer(SqlQueryController.queryStyle(false));
      if (idx >= 0) {
        this.view.setOverlayNoPick(idx, true);
        this.queryOverlayIndices.push(idx);
        // 多段线：每 part 作为一条折线（fids 重复填所属要素 fid）
        const flat: number[] = [];
        const counts: number[] = [];
        const fids: number[] = [];
        for (let i = 0; i < lines.length; i++) {
          const parts: number[][] = lines[i].parts;
          for (let j = 0; j < parts.length; j++) {
            const part: number[] = parts[j];
            const n: number = Math.floor(part.length / 2);
            if (n < 2) {
              continue;
            }
            for (let k = 0; k < part.length; k++) {
              flat.push(part[k]);
            }
            counts.push(n);
            fids.push(lines[i].fid);
          }
        }
        if (counts.length > 0) {
          this.view.updateOverlayLines(idx, flat, counts, fids);
        }
      }
    }

    if (polys.length > 0) {
      const idx: number = this.view.addOverlayLayer(SqlQueryController.queryStyle(true));
      if (idx >= 0) {
        this.view.setOverlayNoPick(idx, true);
        this.queryOverlayIndices.push(idx);
        // 面：外环 + 内环（洞）摊平；ringVertexCounts 每环顶点数、ringsPerFeature 每面环数（首环外环）
        const flat: number[] = [];
        const ringCounts: number[] = [];
        const ringsPer: number[] = [];
        const fids: number[] = [];
        for (let i = 0; i < polys.length; i++) {
          const outer: number[] = polys[i].outer;
          if (outer.length < 6) {
            continue;
          }
          let rings: number = 0;
          for (let k = 0; k < outer.length; k++) {
            flat.push(outer[k]);
          }
          ringCounts.push(Math.floor(outer.length / 2));
          rings++;
          const holes: number[][] = polys[i].holes;
          for (let j = 0; j < holes.length; j++) {
            const hole: number[] = holes[j];
            if (hole.length < 6) {
              continue;
            }
            for (let k = 0; k < hole.length; k++) {
              flat.push(hole[k]);
            }
            ringCounts.push(Math.floor(hole.length / 2));
            rings++;
          }
          ringsPer.push(rings);
          fids.push(polys[i].fid);
        }
        if (ringsPer.length > 0) {
          this.view.updateOverlayPolygons(idx, flat, ringCounts, ringsPer, fids);
        }
      }
    }
  }

  /** 命中要素的 WGS84 四至 [minLon,minLat,maxLon,maxLat]；无有效坐标返回 null */
  static extentOf(features: VectorFeature[]): number[] | null {
    let minLon: number = Number.MAX_VALUE;
    let minLat: number = Number.MAX_VALUE;
    let maxLon: number = -Number.MAX_VALUE;
    let maxLat: number = -Number.MAX_VALUE;
    const accFlat = (flat: number[]): void => {
      let i: number = 0;
      while (i + 1 < flat.length) {
        const lon: number = flat[i];
        const lat: number = flat[i + 1];
        if (!Number.isNaN(lon) && !Number.isNaN(lat)) {
          minLon = Math.min(minLon, lon);
          minLat = Math.min(minLat, lat);
          maxLon = Math.max(maxLon, lon);
          maxLat = Math.max(maxLat, lat);
        }
        i += 2;
      }
    };
    for (let i = 0; i < features.length; i++) {
      const f: VectorFeature = features[i];
      if (f.geom === GeomType.POINT) {
        accFlat([f.x, f.y]);
      } else if (f.geom === GeomType.LINE) {
        for (let j = 0; j < f.parts.length; j++) {
          accFlat(f.parts[j]);
        }
      } else {
        accFlat(f.outer);
        for (let j = 0; j < f.holes.length; j++) {
          accFlat(f.holes[j]);
        }
      }
    }
    if (minLon > maxLon || minLat > maxLat) {
      return null;
    }
    return [minLon, minLat, maxLon, maxLat];
  }

  /** clearOverlayLayers 后调用：仅失效高亮层索引（命中缓存保留待重建） */
  onOverlayLayersCleared(): void {
    this.queryOverlayIndices = [];
  }

  /** 叠加层重建末尾调用：按缓存命中要素重新渲染高亮层（若有） */
  restoreAfterRebuild(): void {
    if (this.queryHighlight !== null) {
      this.addHighlightOverlay(this.queryHighlight);
    }
  }

  /** 查询高亮层命中时回源文件路径（供拾取穿透弹源要素只读详情）；非查询高亮层命中返回 undefined */
  sourcePathIfHit(layerIndex: number): string | undefined {
    return this.queryOverlayIndices.indexOf(layerIndex) >= 0 ? this.queryPath : undefined;
  }

  /** 高亮样式：洋红；面额外带半透明填充，线/点仅描边色 */
  private static queryStyle(withFill: boolean): VectorStyle {
    const style: VectorStyle = MapStyle.defaultStyle();
    style.fillColor = withFill ? MapStyle.QUERY_FILL : 0;
    style.outlineColor = MapStyle.QUERY_OUTLINE;
    style.outlineWidth = MapStyle.QUERY_LINE_WIDTH;
    style.lineColor = MapStyle.QUERY_OUTLINE;
    style.lineWidth = MapStyle.QUERY_LINE_WIDTH;
    style.pointColor = MapStyle.QUERY_OUTLINE;
    style.pointRadiusDp = MapStyle.QUERY_POINT_RADIUS;
    style.labelField = '';
    return style;
  }
}
