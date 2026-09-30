// MediaCaptureHelper.ets —— 拍照会话管理（对应 Android media.MediaCaptureHelper）。
//
// 语义与 Android 一致：一次会话对应一个媒体点位（Placemark），拍照后不退出，可继续拍，
// 多张照片作为同一点位的多个附件保存；附件文件落沙箱 调查宝/Media/<点位ID>/IMG_yyyyMMdd_HHmmss.jpg。
//
// 平台差异：
//   调起相机 Android 用 ACTION_IMAGE_CAPTURE + FileProvider；鸿蒙用 cameraPicker.pick + saveUri，
//     系统相机应用直接把照片写入该 URI，回调仅返回结果码与 URI（无 ActivityResult）。
//   权限 picker 由系统相机进程完成取景拍照，应用侧无需 CAMERA 权限（清单声明仅作说明用途），
//     故不再走 Android 的「先申请相机权限再调起」分支。
//   弹窗 Android 用 AlertDialog/MediaEditDialog；鸿蒙普通类无法弹自定义对话框，
//     连拍询问走 Ui.items，完成后的「改名 + 分组」编辑交由页面（onEditSession 回调）呈现。
//   空点位清理 Android deleteRecursively；鸿蒙 fs.rmdir 支持递归删除。

import { camera, cameraPicker } from '@kit.CameraKit';
import { common } from '@kit.AbilityKit';
import fs from '@ohos.file.fs';
import { fileUri } from '@kit.CoreFileKit';
import { AppDirs } from '../common/AppDirs';
import { AppLog } from '../common/AppLog';
import { Ui } from '../common/Ui';
import { MapDocument } from '../doc/DocModels';
import { DocumentManager } from '../doc/DocumentManager';
import { LocationManager, LocationPoint } from '../location/LocationManager';
import { MediaAttachment, MediaPlacemark, MediaStore } from './MediaStore';
import { MediaWatermark } from './MediaWatermark';

/** 附件落库记绝对沙箱路径（与 Android 记绝对路径同口径，读取端无需再拼根目录） */
export class MediaCaptureHelper {
  /** 当前会话点位主键，-1 表示无会话 */
  private sessionPlacemarkId: number = -1;
  /** 本次拍摄的目标文件路径与坐标（调起相机前确定，回调后据此落库） */
  private pendingCapturePath: string = '';
  private pendingCaptureLat: number = Number.NaN;
  private pendingCaptureLon: number = Number.NaN;
  private readonly ctx: common.UIAbilityContext;

  /** 媒体数据变化（新增/删除附件、点位名称或分组变更）后回调，页面据此刷新标注 */
  onMediaChanged: () => void = (): void => {};
  /** 会话完成回调：页面呈现「修改名称 + 所属分组」编辑面板（等价 Android MediaEditDialog） */
  onEditSession: (placemark: MediaPlacemark) => void = (placemark: MediaPlacemark): void => {};

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
    this.clearPendingCapture();
  }

  /**
   * 启动拍照：会话首张固定坐标并建点位 → 准备附件文件 → 调起系统相机。
   * @param groupId 新点位所属分组（-1 未分组）；会话已存在时忽略该参数
   */
  async launchPhotoCapture(groupId: number = MediaStore.UNGROUPED_ID): Promise<void> {
    const store: MediaStore = await MediaStore.getInstance(this.ctx);
    if (this.sessionPlacemarkId < 0) {
      const location: LocationPoint | null = LocationManager.getInstance().getLastLocation();
      if (location === null) {
        Ui.toastLong('尚未定位成功，无法标注照片位置');
        return;
      }
      this.pendingCaptureLat = location.latitude;
      this.pendingCaptureLon = location.longitude;

      const now: number = Date.now();
      this.sessionPlacemarkId = await store.insertPlacemark(
        MediaCaptureHelper.formatPlacemarkName(now),
        this.pendingCaptureLat, this.pendingCaptureLon, now, groupId);
      if (this.sessionPlacemarkId < 0) {
        Ui.toast('创建拍照记录失败');
        return;
      }
    }

    const outPath: string = this.nextCaptureFilePath();
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
   * 拍照结果处理：成功则加水印并写附件记录，随后询问继续或完成；
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

    const capturedAt: number = Date.now();
    const store: MediaStore = await MediaStore.getInstance(this.ctx);

    // 按设置添加坐标水印；水印失败不影响照片与记录（与 Android 提示口径一致）
    const doc: MapDocument | null = DocumentManager.getInstance().getDocument();
    const watermarkEnabled: boolean = doc === null ? true : doc.systemConfig.photoAddWatermark;
    if (watermarkEnabled) {
      const stamped: boolean = await MediaWatermark.addCoordinateWatermark(
        path, this.pendingCaptureLat, this.pendingCaptureLon, capturedAt);
      if (!stamped) {
        Ui.toastLong('照片已保存，但添加坐标水印失败');
      }
    }

    const fileName: string = MediaCaptureHelper.nameOfPath(path);
    await store.insertAttachment(this.sessionPlacemarkId, MediaAttachment.TYPE_PHOTO,
      fileName, path, capturedAt);
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
    const store: MediaStore = await MediaStore.getInstance(this.ctx);
    const placemark: MediaPlacemark | undefined = await store.findPlacemark(placemarkId);
    this.resetSession();
    if (placemark !== undefined) {
      this.onEditSession(placemark);
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
    const store: MediaStore = await MediaStore.getInstance(this.ctx);
    const placemark: MediaPlacemark | undefined = await store.findPlacemark(this.sessionPlacemarkId);
    if (placemark !== undefined && placemark.attachments.length === 0) {
      const dir: string = this.sessionDir();
      await store.deletePlacemark(this.sessionPlacemarkId);
      MediaCaptureHelper.removeDir(dir);
      this.resetSession();
      this.onMediaChanged();
    }
  }

  /** 会话附件目录：调查宝/Media/<点位ID> */
  private sessionDir(): string {
    return `${AppDirs.mediaDir()}/${this.sessionPlacemarkId}`;
  }

  /** 生成下一张照片的目标路径；目录创建失败返回空串并已提示 */
  private nextCaptureFilePath(): string {
    const dir: string = this.sessionDir();
    if (AppDirs.ensureDir(dir).length === 0 || !AppDirs.exists(dir)) {
      Ui.toast('创建媒体目录失败');
      return '';
    }
    return `${dir}/IMG_${MediaCaptureHelper.fileStamp(Date.now())}.jpg`;
  }

  private clearPendingCapture(): void {
    this.pendingCapturePath = '';
    this.pendingCaptureLat = Number.NaN;
    this.pendingCaptureLon = Number.NaN;
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

  /** 删除会话目录（可能含 picker 预留的 0 字节文件），递归清理；失败仅记日志 */
  private static removeDir(path: string): void {
    AppDirs.removeTree(path);
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

  /** 会话点位默认时间名：`拍照 yyyy-MM-dd HH:mm:ss` */
  static formatPlacemarkName(time: number): string {
    return Ui.stampName('拍照', time);
  }
}
