// AndroidIcons.ets —— rawfile 位图图标解码器（与 Android drawable 同一套 PNG，逐像素同源）。
//
// 为什么需要它：内核 billboard 纹理只吃「ARGB 像素数组 + 像素宽高」，而宽高在内核里身兼两职：
//  ① 校验：桥接层 iconArgbToRgba 要求 argb.length === w*h，不等则整张纹理丢弃 → 点回退画屏幕固定圆
//     （Android 同口径：decodeIconArgb 失败返回 null，宿主传 0 → 画圆）；
//  ② 显示尺寸（屏幕固定，不随缩放变化）：矢量/叠加层 half = iconW*0.5*worldPerPx，
//     定位标记 half = iconW*0.5*kMarkerIconScale*density*worldPerPx。
// Android 传的是 drawable 解码后的真实位图尺寸；鸿蒙此前传的是 dp 数（24/12/10）而数组固定
// 64×64，①必然不过，所以拍照点/样地点/定位标记一直显示为回退圆点（「橙色的点」「没有外圈指北圈」）。
// 本模块把 Android res/drawable-nodpi 的 ic_compass / ic_media / ic_sample 三张原图（已复制到
// entry/src/main/resources/rawfile/，字节相同）解成 0xAARRGGBB 像素并按真实宽高返回，图标内容与
// 尺寸同时与 Android 对齐。FeatureIcons（程序化形状）仍保留给样式对话框里的 pin/circle/… 图标：
// 那组在 Android 是矢量 XML drawable，鸿蒙无法解码 XML，故只对齐「尺寸契约」不逐像素对齐内容。
import image from '@ohos.multimedia.image';
import { common } from '@kit.AbilityKit';
import { AppLog } from '../common/AppLog';

const TAG: string = 'AndroidIcons';

/** 解码结果：ARGB（0xAARRGGBB，行优先，长度 = w*h）+ 真实像素宽高 */
export class IconBitmap {
  readonly argb: number[];
  readonly w: number;
  readonly h: number;

  constructor(argb: number[], w: number, h: number) {
    this.argb = argb;
    this.w = w;
    this.h = h;
  }
}

export class AndroidIcons {
  /** 定位标记罗盘（Android R.drawable.ic_compass，156×156） */
  static readonly COMPASS: string = 'ic_compass.png';
  /** 拍照点位（Android R.drawable.ic_media，48×72） */
  static readonly MEDIA: string = 'ic_media.png';
  /** 样地点位（Android R.drawable.ic_sample，48×72） */
  static readonly SAMPLE: string = 'ic_sample.png';

  /** 解码缓存：同名只解一次（叠加层重建频繁，避免重复读 rawfile） */
  private static cache: Map<string, IconBitmap> = new Map<string, IconBitmap>();
  /** 失败名单：解码失败的名称不再重试，调用方走回退图标 */
  private static failed: Set<string> = new Set<string>();

  /**
   * 取图标位图（同步解码；失败返回 undefined，由调用方决定回退）。
   * @param ctx 宿主上下文（取 resourceManager）
   * @param name rawfile 文件名
   */
  static of(ctx: common.Context | undefined, name: string): IconBitmap | undefined {
    if (ctx === undefined) {
      return undefined;
    }
    const hit: IconBitmap | undefined = AndroidIcons.cache.get(name);
    if (hit !== undefined) {
      return hit;
    }
    if (AndroidIcons.failed.has(name)) {
      return undefined;
    }
    let src: image.ImageSource | null = null;
    let pm: image.PixelMap | null = null;
    try {
      const bytes: Uint8Array = ctx.resourceManager.getRawFileContentSync(name);
      if (bytes.byteLength === 0) {
        throw new Error('rawfile 为空');
      }
      // createImageSource 只认 ArrayBuffer；getRawFileContentSync 返回的是整段新建的 Uint8Array
      src = image.createImageSource(bytes.buffer as ArrayBuffer);
      pm = src.createPixelMapSync();
      const info: image.ImageInfo = pm.getImageInfoSync();
      const w: number = info.size.width;
      const h: number = info.size.height;
      if (w <= 0 || h <= 0) {
        throw new Error(`尺寸非法 ${w}x${h}`);
      }
      const fmt: image.PixelMapFormat = info.pixelFormat;
      if (fmt !== image.PixelMapFormat.BGRA_8888 && fmt !== image.PixelMapFormat.RGBA_8888) {
        throw new Error(`像素格式不支持 ${fmt}`);
      }
      const buf: ArrayBuffer = new ArrayBuffer(w * h * 4);
      pm.readPixelsToBufferSync(buf);
      const px: Uint8Array = new Uint8Array(buf);
      // BGRA_8888 = 鸿蒙解码默认；按 Android Bitmap.getPixels 的 0xAARRGGBB 口径重排
      const bgra: boolean = fmt === image.PixelMapFormat.BGRA_8888;
      const argb: number[] = [];
      const n: number = w * h;
      for (let i = 0; i < n; i++) {
        const c0: number = i * 4;
        const r: number = bgra ? px[c0 + 2] : px[c0];
        const g: number = px[c0 + 1];
        const b: number = bgra ? px[c0] : px[c0 + 2];
        const a: number = px[c0 + 3];
        argb.push(((a << 24) | (r << 16) | (g << 8) | b) | 0);
      }
      const out: IconBitmap = new IconBitmap(argb, w, h);
      AndroidIcons.cache.set(name, out);
      AppLog.i(`${TAG} 图标解码完成 ${name} ${w}x${h}`);
      return out;
    } catch (e) {
      AndroidIcons.failed.add(name);
      AppLog.w(`${TAG} 图标解码失败 ${name}: ${e}`);
      return undefined;
    } finally {
      AndroidIcons.release(pm);
      AndroidIcons.releaseSource(src);
    }
  }

  private static release(pm: image.PixelMap | null): void {
    if (pm === null) {
      return;
    }
    try {
      pm.release();
    } catch (e) {
      // 释放失败不影响结果
    }
  }

  private static releaseSource(src: image.ImageSource | null): void {
    if (src === null) {
      return;
    }
    try {
      src.release();
    } catch (e) {
      // 释放失败不影响结果
    }
  }
}
