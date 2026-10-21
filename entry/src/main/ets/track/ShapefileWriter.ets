// ShapefileWriter.ets —— 纯 ArkTS 写出 ESRI Shapefile（对应 Android util/ShapefileWriter）。
//
// 目前仅支持折线（PolyLine，shapeType=3），供轨迹分享导出使用（一次一条轨迹，单点串单部件，属性表一行）。
// 按 ESRI Shapefile 规范落盘一组同名不同扩展的文件，缺一不可，须整组一起分享/导入才有意义（上层打包成 zip）：
//  - .shp：几何主文件，100 字节大端/小端混排文件头 + 逐条记录（记录号/内容长度大端，其余小端）；
//  - .shx：索引文件，独立文件头 + 每条记录 8 字节（.shp 内偏移/内容长度，均大端，单位：16 位字）；
//  - .dbf：属性表，dBASE III 格式，字段一律用字符型（'C'），避免数值型宽度/小数位换算歧义；
//  - .prj：WGS84 地理坐标系 WKT（轨迹点本身即 WGS84 经纬度，无需投影变换）；
//  - .cpg：属性表字段文本编码声明（固定 UTF-8）。
// 坐标轴序统一为 x=经度、y=纬度（与调用方传入的 lonLatPoints 顺序一致）。

import fs from '@ohos.file.fs';
import { util } from '@kit.ArkTS';
import { AppLog } from '../common/AppLog';

/** shapeType=3：Arc/PolyLine（本类固定写出该类型） */
const SHAPE_TYPE_POLYLINE: number = 3;
/** 文件代号，规范固定值 9994 */
const FILE_CODE: number = 9994;
/** 版本号，规范固定值 1000 */
const VERSION: number = 1000;
/** 单个文件头长度（字节），.shp/.shx 相同 */
const HEADER_BYTES: number = 100;
/** 属性表字段最大字符宽度（dBASE III 单字段上限 254） */
const DBF_MAX_CHAR_WIDTH: number = 254;

/** WGS84 地理坐标系标准 WKT（EPSG:4326），主流 GIS 软件同一写法保证兼容 */
const PRJ_WGS84_WKT: string =
  'GEOGCS["GCS_WGS_1984",DATUM["D_WGS_1984",SPHEROID["WGS_1984",6378137.0,298.257223563]],' +
  'PRIMEM["Greenwich",0.0],UNIT["Degree",0.0174532925199433]]';

/** 属性表一列：name 字段名（截断为不超过 10 字节 ASCII），width 字符型宽度，value 字段值文本 */
export class DbfField {
  name: string;
  width: number;
  value: string;

  constructor(name: string, width: number, value: string) {
    this.name = name;
    this.width = width;
    this.value = value;
  }
}

/** 小工具：定长缓冲 writer（内部维护 position，混合端序逐段写入） */
class Buf {
  readonly view: DataView;
  private readonly bytes: Uint8Array;
  pos: number = 0;

  constructor(totalBytes: number) {
    const ab: ArrayBuffer = new ArrayBuffer(totalBytes);
    this.view = new DataView(ab);
    this.bytes = new Uint8Array(ab);
  }

  u8(v: number): void {
    this.view.setUint8(this.pos, v);
    this.pos += 1;
  }

  i16LE(v: number): void {
    this.view.setInt16(this.pos, v, true);
    this.pos += 2;
  }

  i32LE(v: number): void {
    this.view.setInt32(this.pos, v, true);
    this.pos += 4;
  }

  i32BE(v: number): void {
    this.view.setInt32(this.pos, v, false);
    this.pos += 4;
  }

  f64LE(v: number): void {
    this.view.setFloat64(this.pos, v, true);
    this.pos += 8;
  }

  putBytes(data: Uint8Array): void {
    this.bytes.set(data, this.pos);
    this.pos += data.length;
  }

  /** 定长 ASCII 写入（不足补 0，超长截断），用于字段名 */
  putFixedAscii(text: string, len: number): void {
    for (let i = 0; i < len; i++) {
      this.view.setUint8(this.pos + i, i < text.length ? text.charCodeAt(i) & 0x7F : 0);
    }
    this.pos += len;
  }

  /** 定长文本写入（不足补空格，超长按字符截断至宽度内），用于字段值 */
  putFixedPaddedText(text: string, len: number, encoder: util.TextEncoder): void {
    let s: string = text;
    let bytes: Uint8Array = encoder.encodeInto(s);
    while (bytes.length > len) {
      s = s.substring(0, s.length - 1);
      bytes = encoder.encodeInto(s);
    }
    this.putBytes(bytes);
    for (let i = bytes.length; i < len; i++) {
      this.u8(0x20);
    }
  }

  arrayBuffer(): ArrayBuffer {
    return this.bytes.buffer as ArrayBuffer;
  }
}

export class ShapefileWriter {
  /**
   * 写出一条轨迹对应的完整 shp 文件组到 baseFile（不含扩展名）下，返回生成的全部文件路径
   * （.shp/.shx/.dbf/.prj/.cpg）。至少两点且写出成功时返回列表；点数不足或写盘异常返回空列表。
   */
  static writePolyline(baseFile: string, lonLatPoints: number[][], fields: DbfField[]): string[] {
    if (lonLatPoints.length < 2) {
      return [];
    }
    const exts: string[] = ['.shp', '.shx', '.dbf', '.prj', '.cpg'];
    try {
      const encoder: util.TextEncoder = util.TextEncoder.create('utf-8');
      const box: number[] = ShapefileWriter.boundingBox(lonLatPoints);
      const out: string[] = [];
      for (let i = 0; i < exts.length; i++) {
        out.push(`${baseFile}${exts[i]}`);
      }
      const recordContentBytes: number = ShapefileWriter.writeShp(out[0], box, lonLatPoints);
      ShapefileWriter.writeShx(out[1], box, recordContentBytes);
      ShapefileWriter.writeDbf(out[2], fields, encoder);
      ShapefileWriter.writeTextFile(out[3], PRJ_WGS84_WKT);
      ShapefileWriter.writeTextFile(out[4], 'UTF-8');
      return out;
    } catch (e) {
      AppLog.e('Shapefile 写出失败', e);
      for (let i = 0; i < exts.length; i++) {
        try {
          fs.unlinkSync(`${baseFile}${exts[i]}`);
        } catch (e2) {
          // 未生成的文件忽略
        }
      }
      return [];
    }
  }

  /** 四至 [minLon, minLat, maxLon, maxLat] */
  private static boundingBox(points: number[][]): number[] {
    let minLon: number = Number.MAX_VALUE;
    let maxLon: number = -Number.MAX_VALUE;
    let minLat: number = Number.MAX_VALUE;
    let maxLat: number = -Number.MAX_VALUE;
    for (let i = 0; i < points.length; i++) {
      const p: number[] = points[i];
      if (p[0] < minLon) {
        minLon = p[0];
      }
      if (p[0] > maxLon) {
        maxLon = p[0];
      }
      if (p[1] < minLat) {
        minLat = p[1];
      }
      if (p[1] > maxLat) {
        maxLat = p[1];
      }
    }
    return [minLon, minLat, maxLon, maxLat];
  }

  /** 写出 .shp 文件：文件头 + 单条记录（一条轨迹视为一个部件）。返回记录「内容段」字节数 */
  private static writeShp(file: string, box: number[], points: number[][]): number {
    const numPoints: number = points.length;
    // 内容 = shapeType(4) + box(64) + numParts(4) + numPoints(4) + parts(4*1) + points(16*numPoints)
    const contentBytes: number = 4 + 64 + 4 + 4 + 4 + 16 * numPoints;
    const totalBytes: number = HEADER_BYTES + 8 + contentBytes;

    const buf: Buf = new Buf(totalBytes);
    ShapefileWriter.putFileHeader(buf, box, totalBytes);
    // 记录头（大端）：记录号 1 起、内容长度（16 位字为单位）
    buf.pos = HEADER_BYTES;
    buf.i32BE(1);
    buf.i32BE(contentBytes / 2);
    // 记录内容（小端）
    buf.i32LE(SHAPE_TYPE_POLYLINE);
    buf.f64LE(box[0]);
    buf.f64LE(box[1]);
    buf.f64LE(box[2]);
    buf.f64LE(box[3]);
    buf.f64LE(0);
    buf.f64LE(0);
    buf.f64LE(0);
    buf.f64LE(0); // Zmin/Zmax/Mmin/Mmax 未使用
    buf.i32LE(1); // numParts：单条轨迹固定一个部件
    buf.i32LE(numPoints);
    buf.i32LE(0); // parts[0]：本部件起始点索引
    for (let i = 0; i < numPoints; i++) {
      buf.f64LE(points[i][0]);
      buf.f64LE(points[i][1]);
    }
    ShapefileWriter.writeBytes(file, buf.arrayBuffer());
    return contentBytes;
  }

  /** 写出 .shx 文件：独立文件头 + 单条索引记录（偏移指向几何记录在 .shp 中的起始位置） */
  private static writeShx(file: string, box: number[], recordContentBytes: number): void {
    const totalBytes: number = HEADER_BYTES + 8;
    const buf: Buf = new Buf(totalBytes);
    ShapefileWriter.putFileHeader(buf, box, totalBytes);
    buf.pos = HEADER_BYTES;
    buf.i32BE(HEADER_BYTES / 2);
    buf.i32BE(recordContentBytes / 2);
    ShapefileWriter.writeBytes(file, buf.arrayBuffer());
  }

  /** 写出 dBASE III 属性表：全部字段字符型（'C'），固定一条记录；fields 为空时写合法空字段表 */
  private static writeDbf(file: string, fields: DbfField[], encoder: util.TextEncoder): void {
    let recordLen: number = 1;
    for (let i = 0; i < fields.length; i++) {
      recordLen += Math.min(DBF_MAX_CHAR_WIDTH, Math.max(1, fields[i].width));
    }
    const headerLen: number = 32 + fields.length * 32 + 1;
    const totalBytes: number = headerLen + recordLen + 1; // +1 = 文件结束符 0x1A

    const buf: Buf = new Buf(totalBytes);
    buf.u8(0x03); // dBASE III 无备注文件
    const now: Date = new Date();
    buf.u8(now.getFullYear() - 1900);
    buf.u8(now.getMonth() + 1);
    buf.u8(now.getDate());
    buf.i32LE(1); // 记录数：本导出固定一条
    buf.i16LE(headerLen);
    buf.i16LE(recordLen);
    buf.pos = 29;
    buf.u8(0x00); // 语言驱动 ID 留空

    let fieldHeaderPos: number = 32;
    for (let i = 0; i < fields.length; i++) {
      const f: DbfField = fields[i];
      buf.pos = fieldHeaderPos;
      buf.putFixedAscii(f.name, 11);
      buf.u8(0x43); // 'C'
      buf.i32LE(0); // 字段保留（位移）
      buf.u8(Math.min(DBF_MAX_CHAR_WIDTH, Math.max(1, f.width)));
      buf.u8(0); // 小数位数（字符型固定 0）
      buf.pos = fieldHeaderPos + 32;
      fieldHeaderPos += 32;
    }
    buf.pos = headerLen - 1;
    buf.u8(0x0D); // 文件头结束标志

    buf.pos = headerLen;
    buf.u8(0x20); // 记录删除标志：空格 = 未删除
    for (let i = 0; i < fields.length; i++) {
      const f: DbfField = fields[i];
      buf.putFixedPaddedText(f.value, Math.min(DBF_MAX_CHAR_WIDTH, Math.max(1, f.width)), encoder);
    }
    buf.u8(0x1A); // 文件结束符
    ShapefileWriter.writeBytes(file, buf.arrayBuffer());
  }

  /** 写入 .shp/.shx 共用的 100 字节文件头（大端段 0..27；小端段 28..99） */
  private static putFileHeader(buf: Buf, box: number[], totalBytes: number): void {
    buf.pos = 0;
    buf.i32BE(FILE_CODE);
    for (let i = 0; i < 5; i++) {
      buf.i32BE(0); // 5 个未使用 int
    }
    buf.i32BE(totalBytes / 2); // 文件长度（含头，单位：16 位字）
    buf.i32LE(VERSION);
    buf.i32LE(SHAPE_TYPE_POLYLINE);
    buf.f64LE(box[0]);
    buf.f64LE(box[1]);
    buf.f64LE(box[2]);
    buf.f64LE(box[3]);
    buf.f64LE(0);
    buf.f64LE(0);
    buf.f64LE(0);
    buf.f64LE(0);
  }

  private static writeBytes(path: string, data: ArrayBuffer): void {
    const f = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(f.fd, data);
    } finally {
      fs.closeSync(f);
    }
  }

  private static writeTextFile(path: string, content: string): void {
    ShapefileWriter.writeBytes(path, util.TextEncoder.create('utf-8').encodeInto(content).buffer as ArrayBuffer);
  }
}
