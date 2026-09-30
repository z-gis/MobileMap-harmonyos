// SurveyModels.ets —— 样地调查数据模型与下拉选项配置
// （对应 Android survey/SurveyModels.kt + SampleSurveyConfig.kt）。
//
// 业务口径（林业外业）：一个「样地」挂在某个矢量图斑（sourcePath + sourceFid）上，
// 同一图斑可布设多个样地（plotNo 递增）；样地内逐木记录「树种/胸径/类别/抚育方式/备注」明细行。
// 角点坐标 cornerCoordinates 为「lat,lon;lat,lon;…」文本（四角定位仪手工录入），
// 中心点由角点求均值后落库，供地图点位叠加。

/** 样地主记录 */
export class SurveyPlot {
  id: number = 0;
  /** 源数据文件绝对路径（与文档图层 path 同值，用于回查图斑） */
  sourcePath: string = '';
  /** 源数据要素 FID */
  sourceFid: number = 0;
  /** 小班号 */
  compartmentNo: string = '';
  /** 样地编号（同一图斑内递增） */
  plotNo: number = 1;
  /** 平均树高（手工文本，允许「1.3-2.5」这类区间写法） */
  averageTreeHeight: string = '';
  /** 郁闭度（NaN = 未填） */
  canopyDensity: number = Number.NaN;
  /** 角点坐标文本：lat,lon;lat,lon;… */
  cornerCoordinates: string = '';
  centerLatitude: number = Number.NaN;
  centerLongitude: number = Number.NaN;
  createdAt: number = 0;
  updatedAt: number = 0;
  rows: SurveyRow[] = [];

  /** 标题：样地#编号（图斑名可选拼接） */
  title(): string {
    return `样地#${this.plotNo}`;
  }

  /** 是否已有有效中心坐标（新建未定位的草稿不显示在地图上） */
  hasCenter(): boolean {
    return !Number.isNaN(this.centerLatitude) && !Number.isNaN(this.centerLongitude);
  }

  /** 角点解析为 [lat,lon] 数组（供地图画样方框）；无角点返回空 */
  corners(): number[][] {
    return SurveyPlot.parseCorners(this.cornerCoordinates);
  }

  /** 角点文本 → [lat,lon] 列表（非法项跳过） */
  static parseCorners(text: string): number[][] {
    const out: number[][] = [];
    if (text.trim().length === 0) {
      return out;
    }
    const groups: string[] = text.split(';');
    for (let i = 0; i < groups.length; i++) {
      const seg: string[] = groups[i].split(',');
      if (seg.length < 2) {
        continue;
      }
      const lat: number = Number.parseFloat(seg[0].trim());
      const lon: number = Number.parseFloat(seg[1].trim());
      if (!Number.isNaN(lat) && !Number.isNaN(lon)) {
        out.push([lat, lon]);
      }
    }
    return out;
  }

  /** [lat,lon] 列表 → 角点文本 */
  static cornersToString(corners: number[][]): string {
    const parts: string[] = [];
    for (let i = 0; i < corners.length; i++) {
      parts.push(`${corners[i][0]},${corners[i][1]}`);
    }
    return parts.join(';');
  }

  /** 由角点求中心（算术均值，样地尺度足够）；无角点返回 NaN 对 */
  static centerOf(corners: number[][]): number[] {
    if (corners.length === 0) {
      return [Number.NaN, Number.NaN];
    }
    let latSum: number = 0;
    let lonSum: number = 0;
    for (let i = 0; i < corners.length; i++) {
      latSum += corners[i][0];
      lonSum += corners[i][1];
    }
    return [latSum / corners.length, lonSum / corners.length];
  }
}

/** 样地调查明细行（逐木） */
export class SurveyRow {
  id: number = 0;
  /**
   * 界面行稳定标识（仅作 ForEach 的 key，不落库）：
   * 已入库行取数据库 id（正数），本次新增行取递减负数，两者不致撞 key 而引发行重建错位。
   */
  uid: number = 0;
  sortNo: number = 0;
  /** 树种 */
  treeSpecies: string = '';
  /** 胸径（cm，允许区间文本） */
  dbh: string = '';
  /** 林木类别（如「优势木/被压木」） */
  category: string = '';
  /** 抚育方式（如「间伐/修枝」） */
  thinningMethod: string = '';
  remark: string = '';
}

/** 样地照片记录 */
export class SurveyPhoto {
  id: number = 0;
  plotId: number = 0;
  filePath: string = '';
  capturedAt: number = 0;
}

/** 样地调查下拉选项配置（与 Android SampleSurveyConfig 同源，现场可直接改此表） */
export class SampleSurveyConfig {
  /** 可选树种列表 */
  static readonly TREE_SPECIES: string[] = [
    '油松', '落叶松', '樟子松', '云杉', '侧柏', '桧柏',
    '白桦', '山杨', '蒙古栎', '栎树', '榆树', '槐树',
    '杨树', '柳树', '桦树', '椴树', '水曲柳', '花楸',
    '刺槐', '沙棘', '杜松', '其他',
  ];

  /** 林木类别 */
  static readonly CATEGORIES: string[] = [
    '优势木', '被压木', '普通木', '枯立木', '风倒木', '病虫害木',
  ];

  /** 抚育方式 */
  static readonly THINNING_METHODS: string[] = [
    '间伐', '卫生伐', '抚育伐', '修枝', '补植', '割灌', '不移动',
  ];

  /** 明细行可编辑列（表格表头与导出列顺序） */
  static readonly ROW_COLUMNS: string[] = ['树种', '胸径(cm)', '类别', '抚育方式', '备注'];

  static speciesAt(index: number): string {
    return index >= 0 && index < SampleSurveyConfig.TREE_SPECIES.length
      ? SampleSurveyConfig.TREE_SPECIES[index] : '';
  }

  static categoryAt(index: number): string {
    return index >= 0 && index < SampleSurveyConfig.CATEGORIES.length
      ? SampleSurveyConfig.CATEGORIES[index] : '';
  }

  static thinningAt(index: number): string {
    return index >= 0 && index < SampleSurveyConfig.THINNING_METHODS.length
      ? SampleSurveyConfig.THINNING_METHODS[index] : '';
  }

  /** 文本 → 下拉索引（未命中返回 -1，界面回退到「自定义输入」） */
  static indexOf(list: string[], value: string): number {
    return list.indexOf(value);
  }
}
