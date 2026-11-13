// GpkgDml.ets —— GeoPackage NAPI 薄封装（对应 Android project/GeoPackageWriter.kt + GeoPackageDml.kt）。
//
// 引擎侧（globecore HAR）导出 NativeGpkg 门面，函数与 Android JNI 同语义：
// 整读写与日常增量写全部走 GDAL（nativeReadGeoPackage / nativeWriteGeoPackage 整文件
// tmp+rename 原子替换；nativeGpkg* 增量 DML 经 OGRLayer CreateFeature/SetFeature/
// DeleteFeature 落业务表，空间表按几何类型拆分：tracks / measures_point /
// measures_line / measures_polygon / photos / media_groups / survey_point /
// survey_polygon / project_meta / layer_refs），照片本体 BLOB 入库（主照片
// photos.photo_data，第 2..N 张附件附加表 photo_att_data，未注册表走 ExecuteSQL
// x'hex' 字面量）。老库的 measures / survey_plots 混装单表仍可读、增量写会回退落
// 老表，由 prepareSchema 原地迁移拆表（详见 GpkgDml.prepareSchema）。
// 鸿蒙全 GDAL 路径无需像 Android 纯 SQLite 那样清除 rtree 触发器/索引（GDAL 自带模块），
// 建库时统一 SPATIAL_INDEX=NO，与 Android 产物保持同一文件形状。
//
// 调用风格与现有 native 调用一致（见 vector/GdalVectorReader.ets）：native 为同步函数，
// 本类每个函数一个 async 包装（try/catch 吞异常记日志、回兜底值），UI/管理器侧一律 await。
//
// ── 各增量函数 JSON 形状（键名与 ProjectModels 序列化输出逐字一致）──
//  insertTrack / insertMeasure / insertPhoto / insertGroup / upsertSurveyPlot：
//    对应记录 toJsonObject() 全量（轨迹 points 为平铺前 [[lon,lat,alt],...]，含 id）；
//  updateTrack：   {"name":?, "color":?, "hidden":bool, "lineWidth":int}
//  updateMeasure： {"color":?, "lineWidth":int}
//  updatePhoto：   稀疏列包，仅带需改键 {"name":?} / {"groupId":long} / {"visible":bool} / {"remark":?}
//                  附件整行重写时 {"attachments":[{name,path,time},...], "photo_path":"主照片路径"}
//  syncMeta：      {"meta":{"name":?,"description":?,"srs":?,"createTime":long,"updateTime":long},
//                   "layerRefs":["图层绝对路径",...]}
//                  （native 负责 project_meta 重写与 gpkg_contents/ogr_contents 元数据刷新）
//  addPhotoAttachment：仅照片字节走 ArrayBuffer，不入 JSON（idx=0 主照片 photo_data，>=1 photo_att_data）。

import { NativeGpkg } from '@zys/globecore';
import { AppLog } from '../common/AppLog';

const TAG: string = 'GpkgDml';

export class GpkgDml {
  // ── 整读写（GDAL，仅新建工程文件 / 老库 schema 升级用）──

  /** 整读工程 JSON；文件不存在/结构不符返回 null */
  static async readGeoPackage(path: string): Promise<string | null> {
    try {
      const json: string | null = NativeGpkg.nativeReadGeoPackage(path);
      return json !== null && json.length > 0 ? json : null;
    } catch (e) {
      AppLog.e(`${TAG} readGeoPackage 失败: ${path}`, e);
      return null;
    }
  }

  /** 整写工程 JSON（GDAL 整文件重建，tmp+rename 原子替换） */
  static async writeGeoPackage(path: string, json: string): Promise<boolean> {
    try {
      return NativeGpkg.nativeWriteGeoPackage(path, json);
    } catch (e) {
      AppLog.e(`${TAG} writeGeoPackage 失败: ${path}`, e);
      return false;
    }
  }

  // ── schema 检查 / 准备 ──

  /**
   * 业务表与列是否齐备（齐备即可增量写；文件不存在返回 true，由新建流程负责建库）。
   * 量测/样地两种形状都算齐备：新库的 measures_point/measures_line/measures_polygon +
   * survey_point/survey_polygon 分表，或老库的 measures / survey_plots 混装单表。
   * 老库返回 true 是有意的——返回 false 会触发宿主整文件重建，而重建会丢掉只存在于库内的照片 BLOB；
   * 混装单表由 prepareSchema 原地迁移成分表。
   */
  static async schemaCurrent(path: string): Promise<boolean> {
    try {
      return NativeGpkg.nativeGpkgSchemaCurrent(path);
    } catch (e) {
      AppLog.e(`${TAG} schemaCurrent 检查失败: ${path}`, e);
      return false;
    }
  }

  /**
   * 写前准备（幂等）：补建附件 BLOB 附加表 photo_att_data、修正 gpkg_geometry_columns.z，
   * 并把老库的 measures / survey_plots 混装单表原地迁移为按几何类型拆分的分表
   * （ArcMap 10.8 靠 gpkg_geometry_columns 的写实类型定 shapeType，混装 GEOMETRY 表会吞要素）。
   * （Android 纯 SQLite 路径还需移除 RTree 触发器/索引并清 gpkg_extensions 登记项；
   * 鸿蒙走 GDAL 自带 rtree 模块，native 侧无需该清理，但新建库同样以 SPATIAL_INDEX=NO 不建索引，
   * 保证两端产出的文件形状一致。）
   */
  static async prepareSchema(path: string): Promise<boolean> {
    try {
      return NativeGpkg.nativeGpkgPrepareSchema(path);
    } catch (e) {
      AppLog.e(`${TAG} prepareSchema 失败: ${path}`, e);
      return false;
    }
  }

  // ── 轨迹 ──

  /** 插入轨迹（json = TrackRecord 全量），返回 fid，-1 失败 */
  static async insertTrack(path: string, json: string): Promise<number> {
    try {
      return NativeGpkg.nativeGpkgInsertTrack(path, json);
    } catch (e) {
      AppLog.e(`${TAG} insertTrack 失败: ${path}`, e);
      return -1;
    }
  }

  /** 更新轨迹属性（json = {name,color,hidden,lineWidth}） */
  static async updateTrack(path: string, id: number, json: string): Promise<boolean> {
    try {
      return NativeGpkg.nativeGpkgUpdateTrack(path, id, json);
    } catch (e) {
      AppLog.e(`${TAG} updateTrack 失败: ${path}`, e);
      return false;
    }
  }

  static async deleteTrack(path: string, id: number): Promise<boolean> {
    try {
      return NativeGpkg.nativeGpkgDeleteTrack(path, id);
    } catch (e) {
      AppLog.e(`${TAG} deleteTrack 失败: ${path}`, e);
      return false;
    }
  }

  // ── 测量 ──

  /** 插入测量（json = MeasureRecord 全量），返回 fid，-1 失败 */
  static async insertMeasure(path: string, json: string): Promise<number> {
    try {
      return NativeGpkg.nativeGpkgInsertMeasure(path, json);
    } catch (e) {
      AppLog.e(`${TAG} insertMeasure 失败: ${path}`, e);
      return -1;
    }
  }

  /** 更新测量样式（json = {color,lineWidth}） */
  static async updateMeasure(path: string, id: number, json: string): Promise<boolean> {
    try {
      return NativeGpkg.nativeGpkgUpdateMeasure(path, id, json);
    } catch (e) {
      AppLog.e(`${TAG} updateMeasure 失败: ${path}`, e);
      return false;
    }
  }

  static async deleteMeasure(path: string, id: number): Promise<boolean> {
    try {
      return NativeGpkg.nativeGpkgDeleteMeasure(path, id);
    } catch (e) {
      AppLog.e(`${TAG} deleteMeasure 失败: ${path}`, e);
      return false;
    }
  }

  // ── 拍照 ──

  /** 插入拍照点位（json = PhotoRecord 全量，不含 BLOB），返回 fid，-1 失败 */
  static async insertPhoto(path: string, json: string): Promise<number> {
    try {
      return NativeGpkg.nativeGpkgInsertPhoto(path, json);
    } catch (e) {
      AppLog.e(`${TAG} insertPhoto 失败: ${path}`, e);
      return -1;
    }
  }

  /** 更新拍照点位列（json 稀疏：name/groupId/visible/remark/attachments/photo_path 按需携带） */
  static async updatePhoto(path: string, id: number, json: string): Promise<boolean> {
    try {
      return NativeGpkg.nativeGpkgUpdatePhoto(path, id, json);
    } catch (e) {
      AppLog.e(`${TAG} updatePhoto 失败: ${path}`, e);
      return false;
    }
  }

  static async deletePhoto(path: string, id: number): Promise<boolean> {
    try {
      return NativeGpkg.nativeGpkgDeletePhoto(path, id);
    } catch (e) {
      AppLog.e(`${TAG} deletePhoto 失败: ${path}`, e);
      return false;
    }
  }

  /**
   * 照片本体 BLOB 入库：idx=0 主照片（photos.photo_data），idx>=1 附件（photo_att_data）。
   * 入库成功后源文件是否删除由调用方决定（日常采集成功即删；迁移留给 sweep 统一处理）。
   */
  static async addPhotoAttachment(path: string, fid: number, idx: number, data: ArrayBuffer): Promise<boolean> {
    try {
      return NativeGpkg.nativeGpkgAddPhotoAttachment(path, fid, idx, data);
    } catch (e) {
      AppLog.e(`${TAG} addPhotoAttachment 失败: ${path} fid=${fid} idx=${idx}`, e);
      return false;
    }
  }

  /** 读照片 BLOB：idx=0 主照片（photos.photo_data），idx>=1 附件（photo_att_data）；无返回 null */
  static async readPhotoBlob(path: string, fid: number, idx: number): Promise<ArrayBuffer | null> {
    try {
      return NativeGpkg.nativeGpkgReadPhotoBlob(path, fid, idx);
    } catch (e) {
      AppLog.e(`${TAG} readPhotoBlob 失败: ${path} fid=${fid} idx=${idx}`, e);
      return null;
    }
  }

  /**
   * 照片文件清扫（幂等，打开工程时执行）：BLOB 已入库的磁盘原件删除；
   * BLOB 缺失且磁盘原件存在的读入库后删原件。仅处理 mediaRoot 目录下的文件。
   */
  static async sweepPhotoFiles(path: string, mediaRoot: string): Promise<boolean> {
    try {
      return NativeGpkg.nativeGpkgSweepPhotoFiles(path, mediaRoot);
    } catch (e) {
      AppLog.e(`${TAG} sweepPhotoFiles 失败: ${path}`, e);
      return false;
    }
  }

  // ── 分组 ──

  /** 插入分组（json = MediaGroupRecord 全量） */
  static async insertGroup(path: string, json: string): Promise<boolean> {
    try {
      return NativeGpkg.nativeGpkgInsertGroup(path, json);
    } catch (e) {
      AppLog.e(`${TAG} insertGroup 失败: ${path}`, e);
      return false;
    }
  }

  /** 更新分组（json = {id,name}） */
  static async updateGroup(path: string, json: string): Promise<boolean> {
    try {
      return NativeGpkg.nativeGpkgUpdateGroup(path, json);
    } catch (e) {
      AppLog.e(`${TAG} updateGroup 失败: ${path}`, e);
      return false;
    }
  }

  /** 删除分组：组内点位移到未分组（-1），与内存语义一致 */
  static async deleteGroup(path: string, id: number): Promise<boolean> {
    try {
      return NativeGpkg.nativeGpkgDeleteGroup(path, id);
    } catch (e) {
      AppLog.e(`${TAG} deleteGroup 失败: ${path}`, e);
      return false;
    }
  }

  /** 批量设置分组内全部点位可见性 */
  static async setGroupPhotosVisible(path: string, id: number, visible: boolean): Promise<boolean> {
    try {
      return NativeGpkg.nativeGpkgSetGroupPhotosVisible(path, id, visible);
    } catch (e) {
      AppLog.e(`${TAG} setGroupPhotosVisible 失败: ${path}`, e);
      return false;
    }
  }

  // ── 样地 ──

  /** 新增或更新样地（INSERT OR REPLACE；json = SurveyPlot 全量，attributes 为内嵌 JSON 对象） */
  static async upsertSurveyPlot(path: string, json: string): Promise<boolean> {
    try {
      return NativeGpkg.nativeGpkgUpsertSurveyPlot(path, json);
    } catch (e) {
      AppLog.e(`${TAG} upsertSurveyPlot 失败: ${path}`, e);
      return false;
    }
  }

  /** 删除样地（按 fid DeleteFeature） */
  static async deleteSurveyPlot(path: string, id: number): Promise<boolean> {
    try {
      return NativeGpkg.nativeGpkgDeleteSurveyPlot(path, id);
    } catch (e) {
      AppLog.e(`${TAG} deleteSurveyPlot 失败: ${path}`, e);
      return false;
    }
  }

  // ── 工程元数据 ──

  /**
   * 同步元数据与图层引用：json = {"meta":{"name","description","srs","createTime","updateTime"},
   * "layerRefs":[...]}（键名自定但已与引擎侧约定一致；native 含 gpkg_contents/ogr_contents 刷新）。
   */
  static async syncMeta(path: string, json: string): Promise<boolean> {
    try {
      return NativeGpkg.nativeGpkgSyncMeta(path, json);
    } catch (e) {
      AppLog.e(`${TAG} syncMeta 失败: ${path}`, e);
      return false;
    }
  }
}
