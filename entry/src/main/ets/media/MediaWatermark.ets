// MediaWatermark.ets —— 照片坐标水印（对应 Android media.MediaWatermark）。
//
// 与 Android 同口径：在照片左下角绘制「经纬度 + 拍摄时间」两行白字，衬半透明圆角黑底；
// 绘制前按 EXIF 方向把位图摆正，绘制后以 JPEG 原地覆盖写回。
//
// 平台差异（鸿蒙无 BitmapFactory / Canvas / ExifInterface 直写）：
//   解码   image.createImageSource(path) + createPixelMap()
//   绘制   OffscreenCanvas(px 单位) + drawImage/fillText/roundRect
//   编码   ImagePacker.packToData(jpeg, 92) → 先编码到内存再截断写回，
//          避免「已清空文件但编码失败」导致照片丢失（Android FileOutputStream(false) 有此风险）
//   方向   getImageProperty('Orientation') 取 EXIF 值；仅处理纯旋转（3/6/8），
//          镜像类方向（2/4/5/7）极少见于手机直出照片，按原图处理，保证水印仍能加上
// 重编码后 EXIF 全部丢失（方向标记随之消失），与 Android bitmap.compress 行为一致，故无需再写回方向。

import image from '@ohos.multimedia.image';
import fs from '@ohos.file.fs';
import { LengthMetricsUnit } from '@kit.ArkUI';
import { AppLog } from '../common/AppLog';

/** EXIF 方向属性名（API 12 的 getImageProperty 以字符串键取值） */
const ORIENTATION_KEY: string = 'Orientation';

/** JPEG 写回质量（%）：兼顾清晰度与照片体积 */
const JPEG_QUALITY: number = 92;

/** 字号 / 内边距：随照片短边等比缩放，并各设像素下限 */
const TEXT_SIZE_MIN_PX: number = 28;
const TEXT_SIZE_RATIO: number = 0.035;
const PADDING_MIN_PX: number = 16;
const PADDING_RATIO: number = 0.025;

/** 行距与底板内边距、圆角（均相对字号） */
const LINE_SPACING_RATIO: number = 0.25;
const BG_PADDING_H_RATIO: number = 0.30;
const BG_PADDING_V_RATIO: number = 0.22;
const BG_RADIUS_RATIO: number = 0.18;

/** 水印底板底色：半透明黑 */
const BG_COLOR: string = '#88000000';
/** 水印文字色：纯白 */
const TEXT_COLOR: string = '#FFFFFFFF';

/** 字体基线近似：ascent / descent 各占字号的比例（canvas 无 fontMetrics 接口） */
const FONT_ASCENT_RATIO: number = 0.8;
const FONT_DESCENT_RATIO: number = 0.2;

export class MediaWatermark {
  /**
   * 为照片添加坐标水印（原地覆盖写回）。
   * @param photoPath 照片沙箱绝对路径
   * @return 是否成功；失败仅返回 false 并落日志，由调用方提示（水印失败不应否定照片本身）
   */
  static async addCoordinateWatermark(photoPath: string, latitude: number, longitude: number,
    capturedAt: number): Promise<boolean> {
    let source: image.ImageSource | null = null;
    let pixelMap: image.PixelMap | null = null;
    let result: image.PixelMap | null = null;
    try {
      source = image.createImageSource(photoPath);
      const orientation: number = await MediaWatermark.readOrientation(source);
      pixelMap = await source.createPixelMap();
      const info: image.ImageInfo = pixelMap.getImageInfoSync();
      const srcW: number = info.size.width;
      const srcH: number = info.size.height;
      if (srcW <= 0 || srcH <= 0) {
        return false;
      }

      const rotateDeg: number = MediaWatermark.rotationOf(orientation);
      const swap: boolean = rotateDeg === 90 || rotateDeg === 270;
      const outW: number = swap ? srcH : srcW;
      const outH: number = swap ? srcW : srcH;

      const canvas: OffscreenCanvas = new OffscreenCanvas(outW, outH, LengthMetricsUnit.PX);
      const ctx: OffscreenCanvasRenderingContext2D | undefined = canvas.getContext('2d');
      if (ctx === undefined) {
        return false;
      }

      // ① 摆正：绕画布中心旋转后按原尺寸居中绘制
      ctx.save();
      ctx.translate(outW / 2, outH / 2);
      if (rotateDeg !== 0) {
        ctx.rotate(rotateDeg * Math.PI / 180);
      }
      ctx.drawImage(pixelMap, -srcW / 2, -srcH / 2, srcW, srcH);
      ctx.restore();

      // ② 水印：坐标与时间两行，第二行贴底
      MediaWatermark.drawWatermark(ctx, outW, outH, latitude, longitude, capturedAt);

      result = ctx.getPixelMap(0, 0, outW, outH);
      const packer: image.ImagePacker = image.createImagePacker();
      const option: image.PackingOption = { format: 'image/jpeg', quality: JPEG_QUALITY };
      const buffer: ArrayBuffer = await packer.packToData(result, option);
      MediaWatermark.writeFully(photoPath, buffer);
      return true;
    } catch (e) {
      AppLog.e(`添加坐标水印失败: ${photoPath}`, e);
      return false;
    } finally {
      MediaWatermark.release(pixelMap);
      MediaWatermark.release(result);
      if (source !== null) {
        try {
          source.release();
        } catch (e) {
          // 释放失败不影响结果
        }
      }
    }
  }

  /** 读取 EXIF 方向；无该属性或解析失败按正常方向（1）处理 */
  private static async readOrientation(source: image.ImageSource): Promise<number> {
    try {
      const raw: string = await source.getImageProperty(ORIENTATION_KEY);
      const value: number = parseInt(raw, 10);
      return isNaN(value) ? 1 : value;
    } catch (e) {
      return 1;
    }
  }

  /** EXIF 方向 → 顺时针旋转角度；非纯旋转方向一律 0（保持原图，水印仍能加上） */
  private static rotationOf(orientation: number): number {
    if (orientation === 3) {
      return 180;
    }
    if (orientation === 6) {
      return 90;
    }
    if (orientation === 8) {
      return 270;
    }
    return 0;
  }

  /**
   * 在左下角绘制两行水印文字，衬半透明圆角底板。
   * 坐标基线与 Android 一致：以基线（alphabetic）定位，ascent/descend 按字号比例近似。
   */
  private static drawWatermark(ctx: OffscreenCanvasRenderingContext2D, width: number, height: number,
    latitude: number, longitude: number, capturedAt: number): void {
    const minEdge: number = Math.min(width, height);
    const textSize: number = Math.max(TEXT_SIZE_MIN_PX, minEdge * TEXT_SIZE_RATIO);
    const padding: number = Math.max(PADDING_MIN_PX, minEdge * PADDING_RATIO);

    const coordinateLine: string = `${latitude.toFixed(6)}, ${longitude.toFixed(6)}`;
    const timeLine: string = MediaWatermark.formatTime(capturedAt);

    ctx.font = `${textSize}px sans-serif`;
    ctx.textBaseline = 'alphabetic';

    const ascent: number = textSize * FONT_ASCENT_RATIO;
    const descent: number = textSize * FONT_DESCENT_RATIO;
    const lineHeight: number = ascent + descent;
    const secondLineY: number = height - padding - descent;
    const firstLineY: number = secondLineY - lineHeight - textSize * LINE_SPACING_RATIO;

    const bgPadH: number = textSize * BG_PADDING_H_RATIO;
    const bgPadV: number = textSize * BG_PADDING_V_RATIO;
    const bgRadius: number = textSize * BG_RADIUS_RATIO;
    const textWidth: number = Math.max(ctx.measureText(coordinateLine).width,
      ctx.measureText(timeLine).width);

    ctx.fillStyle = BG_COLOR;
    const bgX: number = padding - bgPadH;
    const bgY: number = firstLineY - ascent - bgPadV;
    const bgW: number = textWidth + bgPadH * 2;
    const bgH: number = (secondLineY + descent) - (firstLineY - ascent) + bgPadV * 2;
    // roundRect 自 API 20 起提供：低版本运行时会抛异常，此处回退直角底板（水印仍可读，不因此判定失败）
    try {
      ctx.beginPath();
      ctx.roundRect(bgX, bgY, bgW, bgH, bgRadius);
      ctx.fill();
    } catch (e) {
      ctx.fillRect(bgX, bgY, bgW, bgH);
    }

    ctx.fillStyle = TEXT_COLOR;
    ctx.fillText(coordinateLine, padding, firstLineY);
    ctx.fillText(timeLine, padding, secondLineY);
  }

  /** 整文件覆写：先写临时截断再落数据，编码失败时不会走到这里 */
  private static writeFully(path: string, buffer: ArrayBuffer): void {
    const file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, buffer);
    } finally {
      fs.closeSync(file);
    }
  }

  private static release(pixelMap: image.PixelMap | null): void {
    if (pixelMap === null) {
      return;
    }
    try {
      pixelMap.release();
    } catch (e) {
      // 释放失败不影响结果
    }
  }

  /** 时间行格式：yyyy-MM-dd HH:mm:ss（与 Android %tY-%tm-%td %tH:%tM:%tS 等价） */
  private static formatTime(ts: number): string {
    const d: Date = new Date(ts);
    const p = (n: number): string => n < 10 ? `0${n}` : `${n}`;
    return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} `
      + `${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
  }
}
