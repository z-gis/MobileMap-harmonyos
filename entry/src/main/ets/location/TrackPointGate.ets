// TrackPointGate.ets —— 轨迹采集点门控（对应 Android location/TrackPointGate.kt，0.4.1.1）。
//
// 把一次系统定位回调判为「接受 / 拒绝（原因）/ 间隙接受」。存在的理由与 Android 侧完全一致
// （见 MobileMap-android/doc/模块/轨迹跳点成因与修复方案.md）：记录链路原先只判「与上一个已录点
// 距离 ≥ 5 m」，5 m 门限挡的是 GNSS 噪声，挡不住几十到几百米的粗差——网络/室内定位的粗差点、
// 静止随机游走点、失锁重定位的首点都会成为轨迹顶点，两侧连线即现场看到的「单点跑偏 + 尖角」。
// 本类把判据集中到一处：来源、新鲜度、精度、间距、速度。
//
// 口径约定（与 Android 同）：
//  - 只作用于**轨迹入库链路**。蓝点显示、底部坐标文本、相机跟随仍吃全部来源，否则室内会退化成
//    「无定位」，用户看到的是没点而不是差点；
//  - 输入是 [GateInput] 纯数据（由调用方从 LocationPoint 抽取），本类不引用任何系统 API，
//    可脱离设备直接判（用例见 Android TrackPointGateTest，移植时逐条对齐）；
//  - 有状态（连续被拒簇计数），**一个记录会话一个实例**，开始/恢复记录时新建或 [reset]。
//
// 鸿蒙差异（判据阈值不变，只有数据来源口径不同，均在上层消化后传入本类）：
//  1) 无 `Location.provider` 字符串，只有 `LocationSourceType` 枚举 → 来源白名单改为按 sourceType 判
//     （GNSS/RTK 放行，网络/室内拦截，未知放行交精度与速度兜底，语义等价 Android 的 gps 放行 /
//     network+passive 拦截 / 未知 provider 放行）；
//  2) 无 `elapsedRealtimeNanos`，点间隔（速度判据分母）用 [LocationPoint.receivedMonotonicMs]
//     （systemDateTime 单调时钟，含休眠，等价 elapsedRealtime 口径）；fix 年龄只能用墙钟 timeStamp
//     差值（设备未上报 timeStamp 时按「新鲜」放行，不据此拒点——拒了会把整条轨迹卡死）。

import { GeoCalc } from '../common/GeoCalc';

/** 门控结论类别 */
export enum GateVerdictKind {
  /** 接受入轨迹 */
  ACCEPT = 0,
  /** 间隙接受：连续被拒后认定确实到了新位置 */
  ACCEPT_GAP = 1,
  /** 拒掉，并给出原因 */
  REJECT = 2
}

/** 拒绝原因：日志与剔除计数按此分类，现场反馈可据此判断是混入粗差还是失锁间隙 */
export enum GateRejectReason {
  STALE = 0,
  UNTRUSTED_SOURCE = 1,
  POOR_ACCURACY = 2,
  TOO_CLOSE = 3,
  IMPROBABLE_SPEED = 4
}

/** 拒绝原因的中文口径（日志用，与 Android 提示文案同源） */
export function rejectReasonText(reason: GateRejectReason): string {
  switch (reason) {
    case GateRejectReason.STALE:
      return '陈旧';
    case GateRejectReason.UNTRUSTED_SOURCE:
      return '来源不可信';
    case GateRejectReason.POOR_ACCURACY:
      return '精度差';
    case GateRejectReason.TOO_CLOSE:
      return '间距不足';
    case GateRejectReason.IMPROBABLE_SPEED:
      return '速度不合理';
    default:
      return '未知';
  }
}

/**
 * 门控结论。ArkTS 无 Kotlin 的 sealed interface，改为 kind + 附带字段的单类，
 * 由静态工厂构造：[GateVerdict.accept] / [GateVerdict.reject] / [GateVerdict.acceptGap]。
 * [gapDistanceMeters] 仅 ACCEPT_GAP 有意义（到上一个已接受点的距离，阶段 2 据此在此断段）；
 * [consecutiveRejects] 仅 ACCEPT_GAP 有意义。
 */
export class GateVerdict {
  kind: GateVerdictKind = GateVerdictKind.ACCEPT;
  reason: GateRejectReason = GateRejectReason.STALE;
  gapDistanceMeters: number = Number.NaN;
  consecutiveRejects: number = 0;

  static accept(): GateVerdict {
    const v: GateVerdict = new GateVerdict();
    v.kind = GateVerdictKind.ACCEPT;
    return v;
  }

  static reject(reason: GateRejectReason): GateVerdict {
    const v: GateVerdict = new GateVerdict();
    v.kind = GateVerdictKind.REJECT;
    v.reason = reason;
    return v;
  }

  static acceptGap(distanceMeters: number, consecutiveRejects: number): GateVerdict {
    const v: GateVerdict = new GateVerdict();
    v.kind = GateVerdictKind.ACCEPT_GAP;
    v.gapDistanceMeters = distanceMeters;
    v.consecutiveRejects = consecutiveRejects;
    return v;
  }
}

/**
 * 门控输入：从系统定位抽取的判据，全部为纯数据类型（对应 Android GateInput）。
 *
 * [accuracyMeters] 传 -1 表示设备未提供精度半径；
 * [fixAgeMs] 是「判定时刻 - fix 时间戳」（毫秒）；
 * [gapMs] 传 -1 表示与上一个已接受点没有可靠的时间基准（如恢复历史草稿后首次判定），此时跳过速度判定；
 * [distanceFromLastMeters] 传 -1 表示尚无已接受点。
 */
export class GateInput {
  lat: number = 0;
  lon: number = 0;
  /** geoLocationManager.LocationSourceType 数值（-1/0 视为未知来源） */
  sourceType: number = -1;
  accuracyMeters: number = -1;
  fixAgeMs: number = 0;
  gapMs: number = -1;
  distanceFromLastMeters: number = -1;

  constructor(lat: number = 0, lon: number = 0, sourceType: number = -1, accuracyMeters: number = -1,
    fixAgeMs: number = 0, gapMs: number = -1, distanceFromLastMeters: number = -1) {
    this.lat = lat;
    this.lon = lon;
    this.sourceType = sourceType;
    this.accuracyMeters = accuracyMeters;
    this.fixAgeMs = fixAgeMs;
    this.gapMs = gapMs;
    this.distanceFromLastMeters = distanceFromLastMeters;
  }
}

/** 轨迹采集点门控：五判据 + 连续被拒簇升级为间隙接受（阈值与 Android 完全一致） */
export class TrackPointGate {
  /** 上一个被拒点（相邻间距参照）；NaN 表示无进行中的被拒簇 */
  private runRefLat: number = Number.NaN;
  private runRefLon: number = Number.NaN;

  /** 当前连续被拒且相邻彼此聚簇的点数：达到 GAP_CONSECUTIVE_REJECTS 且离上一接受点足够远即转间隙接受 */
  private rejectRun: number = 0;

  /** 清掉被拒簇计数（接受一个点、或判定为「回到原处/太近」时调用） */
  reset(): void {
    this.runRefLat = Number.NaN;
    this.runRefLon = Number.NaN;
    this.rejectRun = 0;
  }

  /**
   * 判定一次定位。本方法不修改宿主状态，宿主据返回值决定入库/计数/提示，并在接受后自行 [reset]。
   */
  decide(input: GateInput): GateVerdict {
    // 1) 陈旧 fix（息屏/Doze 期间批量补发的旧点）：直接拒，且不参与被拒簇计数——它说明不了「人 moved 到哪」
    if (input.fixAgeMs > TrackPointGate.MAX_FIX_AGE_MS) {
      return GateVerdict.reject(GateRejectReason.STALE);
    }
    // 2) 粗差来源：网络定位（城镇偏差 50–300 m、山区公里级）与室内定位（多为转载/锚点推算）
    if (!TrackPointGate.isTrustedSource(input.sourceType)) {
      return GateVerdict.reject(GateRejectReason.UNTRUSTED_SOURCE);
    }

    const hasLast: boolean = input.distanceFromLastMeters >= 0;
    const distance: number = hasLast ? input.distanceFromLastMeters : Number.NaN;
    // 设备未上报精度半径（accuracy<0）时不设精度上限，靠来源+新鲜度+速度兜底
    const poorAccuracy: boolean = input.accuracyMeters >= 0 && input.accuracyMeters > TrackPointGate.MAX_ACCURACY_M;
    const tooClose: boolean = hasLast && distance < TrackPointGate.MIN_DISTANCE_METERS;
    // 速度：位移/单调时间差；间隔过短（多源同秒回调）不判，避免把 5 m 抖动放大成「超音速」
    const speedMps: number = hasLast && input.gapMs >= TrackPointGate.MIN_GAP_MS
      ? distance * 1000.0 / input.gapMs : Number.NaN;
    const improbable: boolean = Number.isFinite(speedMps) && speedMps > TrackPointGate.MAX_SPEED_MPS;

    if (!poorAccuracy && !improbable) {
      // 尚无已接受点（起录/恢复后的首点）：质量达标即接受
      if (!hasLast) {
        this.reset();
        return GateVerdict.accept();
      }
      if (tooClose) {
        this.reset();
        return GateVerdict.reject(GateRejectReason.TOO_CLOSE);
      }
      this.reset();
      return GateVerdict.accept();
    }

    // 3) 被拒的点要攒成「簇」才升级为间隙接受：连续 GAP_CONSECUTIVE_REJECTS 个点相邻彼此相距
    //    ≤ RUN_CLUSTER_RADIUS_M（信号稳定在一片新区域，而不是到处乱跳）且离上一接受点
    //    > GAP_DISTANCE_M（真的移动了一段，典型场景是长隧道/林下失锁后重定位）——此时接受并
    //    标间隙，否则记录会被永久卡死在失锁前的位置。
    const reason: GateRejectReason = poorAccuracy ? GateRejectReason.POOR_ACCURACY : GateRejectReason.IMPROBABLE_SPEED;
    this.noteReject(input, distance, hasLast);
    if (this.rejectRun >= TrackPointGate.GAP_CONSECUTIVE_REJECTS && hasLast
      && distance > TrackPointGate.GAP_DISTANCE_M) {
      this.reset();
      return GateVerdict.acceptGap(distance, TrackPointGate.GAP_CONSECUTIVE_REJECTS);
    }
    return GateVerdict.reject(reason);
  }

  /** 记入被拒簇：与**上一个被拒点**聚在一起的累加计数，否则以本点重开一簇（乱跳的点不该攒够间隙阈值）。
   *  用相邻间距而非簇首锚点做参照，慢速漂移（每点挪十几米）才能正常攒够计数，不至于把记录永久冻住。 */
  private noteReject(input: GateInput, distanceFromLast: number, hasLast: boolean): void {
    if (!Number.isNaN(this.runRefLat)) {
      const d: number = GeoCalc.distanceMeters(this.runRefLat, this.runRefLon, input.lat, input.lon);
      this.rejectRun = d <= TrackPointGate.RUN_CLUSTER_RADIUS_M ? this.rejectRun + 1 : 1;
    } else {
      this.rejectRun = 1;
    }
    this.runRefLat = input.lat;
    this.runRefLon = input.lon;
    // 被拒点若其实就在上一接受点附近（只是精度差/抖动），不构成「到新区域」的证据：不攒计数
    if (hasLast && distanceFromLast < TrackPointGate.GAP_DISTANCE_M) {
      this.runRefLat = Number.NaN;
      this.runRefLon = Number.NaN;
      this.rejectRun = 0;
    }
  }

  /** fix 年龄上限（毫秒）：超过即视为陈旧点（Doze 批量补发、恢复草稿时的历史点） */
  static readonly MAX_FIX_AGE_MS: number = 8000;

  /** 精度半径上限（米）：现场按机型校准，15 m 会在林下大量丢点、50 m 仍会漏进尖角，故取 30 m 起测 */
  static readonly MAX_ACCURACY_M: number = 30.0;

  /** 相邻轨迹点最小间距（米）：沿用既有口径，挡 GPS 抖动（原 MapStyle.MIN_TRACK_POINT_DISTANCE_METERS） */
  static readonly MIN_DISTANCE_METERS: number = 5.0;

  /** 速度判定所需最小时间间隔（毫秒）：低于此值不判速度，多源同秒回调交给间距判据 */
  static readonly MIN_GAP_MS: number = 500;

  /** 速度上限（米/秒）：覆盖机动车巡检，步行 1.5 m/s 余量极大；2 s 间隔里跑出 200 m 即 100 m/s，明显是跳点 */
  static readonly MAX_SPEED_MPS: number = 25.0;

  /** 间隙接受所需的连续被拒点数 */
  static readonly GAP_CONSECUTIVE_REJECTS: number = 5;

  /** 间隙接受所需的最小位移（米）：小于此距离的持续被拒只是噪声，不值得断线 */
  static readonly GAP_DISTANCE_M: number = 200.0;

  /** 被拒点聚为同一簇的半径（米）：簇内彼此靠近才算「稳定在新区域」 */
  static readonly RUN_CLUSTER_RADIUS_M: number = 30.0;

  /**
   * 是否为可入轨迹的定位来源（语义等价 Android isTrustedProvider）：
   * 放行 GNSS(1) / GNSS RTK(4)；拦掉 网络(2) / 室内(3)；
   * 未知来源（0 或未上报，含部分机型扩展枚举）放行——它们没有粗差来源那么明确的画像，
   * 交给精度与速度判据兜底。
   */
  static isTrustedSource(sourceType: number): boolean {
    if (sourceType === 2 || sourceType === 3) {
      return false;
    }
    return true;
  }
}
