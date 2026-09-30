// RouteParams.ets —— router 跳转参数模型（仅承载可序列化的标量与短字符串）。
//
// 复杂对象（带方法的类实例、Map 字段）不走 router params，见 common/PageData 的交接槽。
// 参数类字段全部给默认值：目标页对「未传」与「传空」不做区分处理，缺省即回退到安全值。
//
// 约定：经纬度未定位/未知统一用 Number.NaN 表示（与 SurveyPlot.centerLatitude 口径一致），
// 目标页判定时用 Number.isFinite 而非 >=0（0 经度是合法值）。

/** 样地列表页（对应 Android FeaturePickController.showSurveyEntryDialog 的列表对话框） */
export class SurveyListParams {
  /** 源矢量文件绝对路径 */
  sourcePath: string = '';
  /** 源图斑 FID */
  sourceFid: number = -1;
  /** 小班号（空则显示「未命名小班」） */
  compartmentNo: string = '';
}

/** 样地录入页（对应 Android SampleSurveyActivity 的 intent extras） */
export class SurveyEditParams {
  sourcePath: string = '';
  sourceFid: number = -1;
  compartmentNo: string = '';
  centerLat: number = Number.NaN;
  centerLon: number = Number.NaN;
  /** >0 表示编辑已有样地，-1 表示新建草稿 */
  plotId: number = -1;
}

/** 照片浏览页（对应 Android PhotoViewerActivity） */
export class PhotoViewerParams {
  /** 点位 id（MediaStore.media_placemarks._id） */
  placemarkId: number = -1;
  /** 直接浏览单张照片时传文件路径（为空表示按点位取列表） */
  filePath: string = '';
  /** 起始张序（点位照片网格点击某张时传入，对应 Android EXTRA_INDEX） */
  initialIndex: number = 0;
}

/** 图层管理页（对应 Android LayerManageDialog） */
export class LayerManageParams {
  /** 起始页签：0 矢量 / 1 栅格 / 2 地图源 */
  tab: number = 0;
}

/** 添加图层页（对应 Android OpenFileActivity） */
export class AddLayerParams {
  /** 导入完成后是否立即缩放到新图层四至 */
  zoomTo: number = 1;
}

/**
 * 样地调查入口上下文（走 PageData 交接，含 Map 与嵌套数组）。
 * 对应 Android showSurveyEntryDialog 的入参 attrs + fg。
 */
export class SurveyEntryContext {
  /** 要素属性表（异步回取可能尚未完成，为空则小班号回退「未命名小班」） */
  attributes: Map<string, string> | null = null;
  /** 图斑外环 [lat,lon] 二元组列表（非面为空，跳过环内判定） */
  outerRing: number[][] = [];
}
