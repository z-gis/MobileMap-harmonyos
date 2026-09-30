// MapServices.ets —— 地图控制器单例登记表（主地图页装配，其余页面按名取用）。
//
// Android 侧各 Activity/Dialog 通过 (activity as MainActivity) 拿到地图控制器，鸿蒙侧页面之间
// 没有这种父子关系：router 页是独立实例，且 NativeMapView 与其控制器只能在主地图页的 onReady 后成立。
// 故集中一个进程内登记表：主地图页创建控制器时写入、销毁时清空，二级页取不到即视为「地图未就绪」。
//
// 刻意不做成依赖注入容器——这里只有「一个地图页」的实例，字段即控制器本身，类型明确、无装配歧义。

import { NativeMapView } from 'globecore';
import { BusinessOverlayManager } from './BusinessOverlayManager';
import { CameraNavigator } from './CameraNavigator';
import { FeaturePickController } from './FeaturePickController';
import { LocationController } from './LocationController';
import { MapLayerController } from './MapLayerController';
import { MeasureController } from './MeasureController';
import { SqlQueryController } from './SqlQueryController';
import { TrackController } from './TrackController';

export class MapServices {
  static readonly instance: MapServices = new MapServices();

  view: NativeMapView | undefined = undefined;
  layers: MapLayerController | undefined = undefined;
  overlays: BusinessOverlayManager | undefined = undefined;
  camera: CameraNavigator | undefined = undefined;
  location: LocationController | undefined = undefined;
  sql: SqlQueryController | undefined = undefined;
  measure: MeasureController | undefined = undefined;
  track: TrackController | undefined = undefined;
  pick: FeaturePickController | undefined = undefined;

  /** 主地图页 onReady 后为真；二级页据此决定「回到地图后需要地图配合」的操作是否可用 */
  ready(): boolean {
    return this.view !== undefined && this.layers !== undefined;
  }

  /** 主地图页销毁时清空，避免二级页持有失效的 native 视图引用 */
  clear(): void {
    this.view = undefined;
    this.layers = undefined;
    this.overlays = undefined;
    this.camera = undefined;
    this.location = undefined;
    this.sql = undefined;
    this.measure = undefined;
    this.track = undefined;
    this.pick = undefined;
  }
}
