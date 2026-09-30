// PageData.ets —— 页面间复杂对象的旁路传递槽。
//
// router.pushUrl 的 params 只做「可序列化数据」的传递，跨页传类实例（含方法、Map 字段）不可靠；
// 而要素详情请求、测量/轨迹记录这类需要回调与结构化字段的对象必须原样送达目标页。
// 故复杂对象经此进程内槽位交接：发起方 put，目标页 aboutToAppear 时 take（读后即焚，防脏读）。
// 仅限同进程页面跳转使用；简单标量仍走 router params，保持可读性。

export class PageData {
  private static readonly slots: Map<string, Object> = new Map<string, Object>();

  static put(key: string, value: Object): void {
    PageData.slots.set(key, value);
  }

  /** 取出并移除（未放入过返回 undefined） */
  static take(key: string): Object | undefined {
    const value: Object | undefined = PageData.slots.get(key);
    PageData.slots.delete(key);
    return value;
  }

  /** 只看不取（供同一页多次刷新） */
  static peek(key: string): Object | undefined {
    return PageData.slots.get(key);
  }

  static clear(key: string): void {
    PageData.slots.delete(key);
  }
}

/** 交接槽键名（集中声明，避免拼写漂移） */
export class PageKeys {
  /** FeatureDetailRequest：要素详情 */
  static readonly FEATURE_DETAIL: string = 'featureDetail';
  /** MeasurementRecord：测量详情 */
  static readonly MEASURE_DETAIL: string = 'measureDetail';
  /** TrackRecord：轨迹详情 */
  static readonly TRACK_DETAIL: string = 'trackDetail';
  /** MediaPlacemark：拍照点位浏览 */
  static readonly MEDIA_PLACEMARK: string = 'mediaPlacemark';
  /** SurveyEntry：样地调查入口上下文（小班号字段候选 + 图斑外环） */
  static readonly SURVEY_ENTRY: string = 'surveyEntry';
  /** 导入图层的最后一个文件路径：添加图层页写入，主界面消费后缩放到其四至 */
  static readonly IMPORTED_LAYER_PATH: string = 'importedLayerPath';
}

/**
 * 跨页就绪信号：栈底页（主地图）取到的异步结果要就地刷到栈顶页（要素详情的属性回填）。
 *
 * PageData 传的是「对象」，而这里要传的是「事件」——对象能被 mutate，但页面感知不到变化。
 * 故栈顶页 aboutToAppear 时 bind 一个回调、aboutToDisappear 时 unbind；栈底页拿到数据后 fire。
 * 键复用 PageKeys，与交接槽一一对应；未绑定时 fire 静默丢弃（页面已关闭属正常情形）。
 */
export class PageSignals {
  private static readonly handlers: Map<string, () => void> = new Map<string, () => void>();

  static bind(key: string, handler: () => void): void {
    PageSignals.handlers.set(key, handler);
  }

  static unbind(key: string): void {
    PageSignals.handlers.delete(key);
  }

  static fire(key: string): void {
    const handler: (() => void) | undefined = PageSignals.handlers.get(key);
    if (handler !== undefined) {
      handler();
    }
  }
}
