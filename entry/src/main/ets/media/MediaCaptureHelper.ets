// MediaCaptureHelper.ets —— 拍照会话管理（对应 Android media.MediaCaptureHelper，0.4.0.4 工程版）。
//
// 语义与 Android 一致：一次会话对应一个拍照点位（PhotoRecord），拍照后不退出，可继续拍，
// 多张照片作为同一点位的多个附件保存；附件文件落沙箱 调查宝/Media/<点位ID>/IMG_yyyyMMdd_HHmmss.jpg，
// 照片本体经 ProjectManager.addPhotoAttachment 增量入库 gpkg BLOB，库提交成功后源文件自动删除。
//
// 点位坐标只有「会话起点」一个来源口径：定位拍照按钮走 launchPhotoCapture（取当前定位，
// 未定位成功不建点）；地图长按空白落点走 startSessionAt（调用方给经纬度，与定位无关，即兴趣点）；
// 相册选图走 addPhotosFromAlbum（同样按落点建点，照片来自图库，不加水印、时间记入库时刻）。
// 会话期内该坐标不变，水印按它落字，故不随单张照片的清理复位（连拍第 2 张起仍须有坐标）。
//
// 平台差异：
//   调起相机 Android 用 ACTION_IMAGE_CAPTURE + FileProvider；鸿蒙用 cameraPicker.pick + saveUri，
//     系统相机应用直接把照片写入该 URI，回调仅返回结果码与 URI（无 ActivityResult）。
//   相册选图 Android 用 ACTION_PICK + MediaStore  URI；鸿蒙用 photoAccessHelper.PhotoViewPicker，
//     返回的是媒体库 URI（无沙箱路径），只能按 URI 打开，故必须先拷进会话目录再走 BLOB 入库。
//   权限 picker 由系统相机进程完成取景拍照，应用侧无需 CAMERA 权限（清单声明仅作说明用途），
//     故不再走 Android 的「先申请相机权限再调起」分支。
//   弹窗 Android 用 AlertDialog/MediaEditDialog；鸿蒙普通类无法弹自定义对话框，
//     连拍询问走 Ui.items，完成后的「改名 + 分组」编辑交由页面（onEditSession 回调）呈现。
//   空点位清理 Android deleteRecursively；鸿蒙 AppDirs.removeTree 递归删除。

import { camera, cameraPicker } from '@kit.CameraKit';
import { common } from '@kit.AbilityKit';
import fs from '@ohos.file.fs';
import photoAccessHelper from '@ohos.file.photoAccessHelper';
import { fileUri } from '@kit.CoreFileKit';
import { AppDirs } from '../common/AppDirs';
import { AppLog } from '../common/AppLog';
import { Ui } from '../common/Ui';
import { MapDocument } from '../doc/DocModels';
import { DocumentManager } from '../doc/DocumentManager';
import { LocationManager, LocationPoint } from '../location/LocationManager';
import { ProjectManager } from '../project/ProjectManager';
import { PhotoRecord } from '../project/ProjectModels';
import { MediaWatermark } from './MediaWatermark';

const TAG: string = 'MediaCapture';

/** 附件落库记绝对沙箱路径（与 Android 记绝对路径同口径，读取端无需再拼根目录） */
export class MediaCaptureHelper {
  /** 当前会话点位主键，-1 表示无会话 */
  private sessionPlacemarkId: number = -1;
  /** 会话点位坐标（建会话时定，整个连拍期不变；水印按它落字，不能随单张清理） */
  private sessionLat: number = Number.NaN;
  private sessionLon: number = Number.NaN;
  /** 本次拍摄的目标文件路径（调起相机前确定，回调后据此落库） */
  private pendingCapturePath: string = '';
  private readonly ctx: common.UIAbilityContext;

  /** 媒体数据变化（新增/删除附件、点位名称或分组变更）后回调，页面据此刷新标注 */
  onMediaChanged: () => void = (): void => {};
  /** 会话完成回调：页面呈现「修改名称 + 所属分组」编辑面板（等价 Android MediaEditDialog） */
  onEditSession: (photo: PhotoRecord) => void = (photo: PhotoRecord): void => {};

  constructor(ctx: common.UIAbilityContext) {
    this.ctx = ctx;
  }

  /** 是否处于连拍会话中 */
  hasSession(): boolean {
    return this.sessionPlacemarkId >= 0;
  }

  /** 结束当前连拍会话（不含删除，空点位清理由 cleanupEmptySessionPlacemark 负责） */
  resetSession(): void {
    this.sessionPlacemarkId = -1;
    this.sessionLat = Number.NaN;
    this.sessionLon = Number.NaN;
    this.clearPendingCapture();
  }

  /**
   * 启动拍照（定位坐标口径，拍照按钮走这条）：已在会话中则直接拍下一张；
   * 无会话时取当前定位坐标建点，未定位成功不建点。
   */
  async launchPhotoCapture(): Promise<void> {
    if (this.sessionPlacemarkId >= 0) {
      await this.captureNext();
      return;
    }
    const location: LocationPoint | null = LocationManager.getInstance().getLastLocation();
    if (location === null) {
      Ui.toastLong('尚未定位成功，无法标注照片位置');
      return;
    }
    await this.startSessionAt(location.latitude, location.longitude, '拍照');
  }

  /**
   * 以指定坐标起拍照会话（地图落点用，不依赖定位）：建点位 → 拍第一张。
   * 已有会话时拒绝——否则本次照片会并入上一个点位，归属不可控。
   * @param namePrefix 点位默认名前缀（定位拍照「拍照」、落点兴趣点「兴趣点」）
   */
  async startSessionAt(lat: number, lon: number, namePrefix: string): Promise<void> {
    if (this.sessionPlacemarkId >= 0) {
      Ui.toast('请先完成当前连拍');
      return;
    }
    const now: number = Date.now();
    this.sessionLat = lat;
    this.sessionLon = lon;
    this.sessionPlacemarkId = await ProjectManager.get(this.ctx).addPhoto(
      Ui.stampName(namePrefix, now), lat, lon, now);
    if (this.sessionPlacemarkId < 0) {
      Ui.toast('创建拍照记录失败');
      return;
    }
    await this.captureNext();
  }

  /**
   * 从相册选图建/补兴趣点：不调相机、不依赖定位，选中照片作为当前点位的附件入库。
   * 无会话时按落点坐标新建点位（兴趣点口径）；已在会话中则并入当前会话点位，与连拍同归属。
   * 取消选择或全部读取失败 → 走空点位清理，不留没有照片的标注。
   * 相册原图不带本应用坐标，故不加水印、capturedAt 记本次入库时刻。
   */
  async addPhotosFromAlbum(lat: number, lon: number, namePrefix: string): Promise<void> {
    const pm: ProjectManager = ProjectManager.get(this.ctx);
    if (this.sessionPlacemarkId < 0) {
      const now: number = Date.now();
      const placemarkId: number = await pm.addPhoto(Ui.stampName(namePrefix, now), lat, lon, now);
      if (placemarkId < 0) {
        Ui.toast('创建兴趣点失败');
        return;
      }
      this.sessionLat = lat;
      this.sessionLon = lon;
      this.sessionPlacemarkId = placemarkId;
    }
    const uris: string[] = await this.pickAlbumImageUris();
    if (uris.length === 0) {
      await this.cleanupEmptySessionPlacemark();
      return;
    }
    let saved: number = 0;
    for (const uri of uris) {
      if (await this.attachAlbumPhoto(uri)) {
        saved++;
      }
    }
    if (saved === 0) {
      await this.cleanupEmptySessionPlacemark();
      Ui.toast('相册照片读取失败');
      return;
    }
    await pm.saveNow();
    this.onMediaChanged();
    Ui.toast(`已添加 ${saved} 张相册照片`);
    await this.finishSession();
  }

  /** 拉起相册选择器（PhotoViewPicker 免权限）；取消或异常返回空数组 */
  private async pickAlbumImageUris(): Promise<string[]> {
    try {
      const options: photoAccessHelper.PhotoSelectOptions = {
        MIMEType: photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE,
        maxSelectNumber: 9,
      };
      const result: photoAccessHelper.PhotoSelectResult =
        await new photoAccessHelper.PhotoViewPicker().select(options);
      return result.photoUris;
    } catch (e) {
      AppLog.e('相册选图取消/失败', e);
      return [];
    }
  }

  /**
   * 把一张相册 URI 拷进会话目录再入库。picker 授予的是所选 URI 的临时读权限，
   * 只能按 URI 打开、不能按路径访问，故必须先落到沙箱再走 addPhotoAttachment。
   */
  private async attachAlbumPhoto(uri: string): Promise<boolean> {
    const outPath: string = this.nextCaptureFilePath('ALB');
    if (outPath.length === 0) {
      return false;
    }
    if (!MediaCaptureHelper.prepareFile(outPath)) {
      Ui.toast('创建媒体文件失败');
      return false;
    }
    let src: fs.File | null = null;
    let dst: fs.File | null = null;
    try {
      src = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      dst = fs.openSync(outPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE);
      fs.copyFileSync(src.fd, dst.fd);
      if (fs.statSync(dst.fd).size <= 0) {
        throw new Error('相册照片内容为空');
      }
    } catch (e) {
      AppLog.e('相册照片拷贝失败', e);
      if (src !== null) fs.closeSync(src);
      if (dst !== null) fs.closeSync(dst);
      AppDirs.removeFile(outPath);
      return false;
    }
    fs.closeSync(src);
    fs.closeSync(dst);
    const capturedAt: number = Date.now();
    await ProjectManager.get(this.ctx).addPhotoAttachment(
      this.sessionPlacemarkId, MediaCaptureHelper.nameOfPath(outPath), outPath, capturedAt);
    return true;
  }

  /**
   * 拍下一张：准备附件文件 → 调起系统相机（会话点位须已存在）。
   */
  private async captureNext(): Promise<void> {
    const outPath: string = this.nextCaptureFilePath('IMG');
    if (outPath.length === 0) {
      return;
    }
    this.pendingCapturePath = outPath;

    // picker 要求目标文件已存在且可写，故先建空文件
    if (!MediaCaptureHelper.prepareFile(outPath)) {
      this.clearPendingCapture();
      Ui.toast('创建媒体文件失败');
      return;
    }

    const profile: cameraPicker.PickerProfile = {
      cameraPosition: camera.CameraPosition.CAMERA_POSITION_BACK,
      saveUri: fileUri.getUriFromPath(outPath),
    };
    const types: cameraPicker.PickerMediaType[] = [cameraPicker.PickerMediaType.PHOTO];
    try {
      const result: cameraPicker.PickerResult = await cameraPicker.pick(this.ctx, types, profile);
      await this.handleCaptureResult(result.resultCode === 0);
    } catch (e) {
      // 用户取消 / 相机不可用：与 Android ActivityNotFoundException 及非 RESULT_OK 同处理
      AppLog.e('调起相机失败', e);
      await this.handleCaptureResult(false);
    }
  }

  /**
   * 拍照结果处理：成功则加水印并把照片本体入库 gpkg BLOB（库提交成功后源文件删除），随后询问继续或完成；
   * 失败则清理尚无附件的空点位（避免地图残留无照片标注）。
   */
  private async handleCaptureResult(success: boolean): Promise<void> {
    const path: string = this.pendingCapturePath;
    if (!success || path.length === 0 || this.sessionPlacemarkId < 0) {
      this.clearPendingCapture();
      await this.cleanupEmptySessionPlacemark();
      return;
    }
    if (!fs.accessSync(path) || fs.statSync(path).size <= 0) {
      this.clearPendingCapture();
      Ui.toast('照片保存失败');
      return;
    }
    const fileBytes: number = fs.statSync(path).size;

    const capturedAt: number = Date.now();
    const t0: number = Date.now();
    const pm: ProjectManager = ProjectManager.get(this.ctx);

    // 按设置添加坐标水印；水印失败不影响照片与记录（与 Android 提示口径一致）
    const doc: MapDocument | null = DocumentManager.getInstance().getDocument();
    const watermarkEnabled: boolean = doc === null ? true : doc.systemConfig.photoAddWatermark;
    if (watermarkEnabled) {
      const stamped: boolean = await MediaWatermark.addCoordinateWatermark(
        path, this.sessionLat, this.sessionLon, capturedAt);
      if (!stamped) {
        Ui.toastLong('照片已保存，但添加坐标水印失败');
      }
    }
    const t1: number = Date.now();

    // 写入附件记录（照片本体增量入库 gpkg BLOB，库提交成功后源文件自动删除）
    const fileName: string = MediaCaptureHelper.nameOfPath(path);
    await pm.addPhotoAttachment(this.sessionPlacemarkId, fileName, path, capturedAt);
    // 鸿蒙增量写为同步 NAPI，saveNow 语义 = 元数据落盘（对齐 Android 栅栏排空语义）
    await pm.saveNow();
    AppLog.i(`${TAG} 照片入库耗时 水印=${t1 - t0}ms 读文件+BLOB落库=${Date.now() - t1}ms `
      + `合计=${Date.now() - t0}ms bytes=${fileBytes}`);
    this.clearPendingCapture();
    this.onMediaChanged();
    Ui.toast('照片已保存并标注');

    await this.showContinueCaptureDialog();
  }

  /** 拍照后不退出：询问继续拍照或完成（结束会话）；取消等同完成前的直接退出 */
  private async showContinueCaptureDialog(): Promise<void> {
    const which: number = await Ui.items('连拍模式', ['继续拍照', '完成']);
    if (which === 0) {
      await this.launchPhotoCapture();
      return;
    }
    if (which === 1) {
      await this.finishSession();
      return;
    }
    // 对话框被取消：仅结束会话，点位与照片保留
    this.resetSession();
  }

  /**
   * 完成会话：先复位会话（编辑面板取消也应结束本次连拍，避免下次拍照误并入本点位），
   * 再把点位交给页面编辑名称与分组。
   */
  private async finishSession(): Promise<void> {
    const placemarkId: number = this.sessionPlacemarkId;
    const photo: PhotoRecord | null = ProjectManager.get(this.ctx).findPhoto(placemarkId);
    this.resetSession();
    if (photo !== null) {
      this.onEditSession(photo);
    }
  }

  /**
   * 无附件的会话点位删除并结束会话（含目录），并刷新标注。
   * 已有附件则保留点位与会话，下次拍照继续归入同一点位。
   */
  private async cleanupEmptySessionPlacemark(): Promise<void> {
    if (this.sessionPlacemarkId < 0) {
      return;
    }
    const pm: ProjectManager = ProjectManager.get(this.ctx);
    const photo: PhotoRecord | null = pm.findPhoto(this.sessionPlacemarkId);
    if (photo !== null && photo.attachments.length === 0) {
      const dir: string = this.sessionDir();
      await pm.removePhoto(this.sessionPlacemarkId);
      AppDirs.removeTree(dir);
      this.resetSession();
      this.onMediaChanged();
    }
  }

  /** 会话附件目录：调查宝/Media/<点位ID> */
  private sessionDir(): string {
    return `${AppDirs.mediaDir()}/${this.sessionPlacemarkId}`;
  }

  /** 生成下一张附件的目标路径；目录创建失败返回空串并已提示。@param prefix 相机 IMG / 相册 ALB */
  private nextCaptureFilePath(prefix: string): string {
    const dir: string = this.sessionDir();
    if (AppDirs.ensureDir(dir).length === 0 || !AppDirs.exists(dir)) {
      Ui.toast('创建媒体目录失败');
      return '';
    }
    return `${dir}/${prefix}_${MediaCaptureHelper.fileStamp(Date.now())}.jpg`;
  }

  private clearPendingCapture(): void {
    this.pendingCapturePath = '';
  }

  /** 建空文件（picker 要求目标存在且可写），失败返回 false */
  private static prepareFile(path: string): boolean {
    try {
      const file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.closeSync(file);
      return true;
    } catch (e) {
      AppLog.e('创建媒体文件失败', e);
      return false;
    }
  }

  private static nameOfPath(path: string): string {
    const idx: number = path.lastIndexOf('/');
    return idx >= 0 ? path.substring(idx + 1) : path;
  }

  /** 文件名时间戳：yyyyMMdd_HHmmss（Android %tY%tm%td_%tH%tM%tS 等价） */
  private static fileStamp(ts: number): string {
    const d: Date = new Date(ts);
    const p = (n: number): string => n < 10 ? `0${n}` : `${n}`;
    return `${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}`
      + `_${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}`;
  }
}
