// PieMenuLayer.ets —— 长按落点圆菜单浮层（对应 Android control/PieMenu + PieMenuView）
//
// 口径照 Android：以落点为锚，动作项沿半径 pathRadius 的圆等分顺时针排布（第 0 项在正上方），
// 每项「图标在上、文案在下」，文案带深底胶囊（压在明暗不定的底图上才读得出）；
// 圆心按整块外扩钳位到屏内，钳位后偏离落点足够远时画虚线连回。
// 不画环带背景：Android 侧同样去掉了那条深色圆弧，只留浮在遮罩上的白底按钮，文案向下外扩才不会被圆环边界切到。
//
// 命中口径（SDK 对 HitTestMode 的定义：Block=自身响应并屏蔽「子节点+兄弟+祖先」，Default=自身+子节点
// 响应并只屏蔽兄弟，None=自身不响应也不屏蔽）：遮罩必须是独立节点而不是根 Stack 本身——根上挂 Block
// 会连槽位子节点一起屏蔽，项内点击永远落到遮罩。故遮罩自吞点击（同时 Block 住兄弟地图，菜单期间手势
// 不下发），槽位排在遮罩之后置顶、自身也 Block（挡住身后的遮罩，选中不会顺带收起）。
// 纯装饰节点一律 None 放行给遮罩（点按钮之间的空白即收起），热区按 Android 改写后的口径整块交给槽位节点本身
// （图标 ∪ 文案一整块矩形），不再拆成两块分别挂点击。
//
// 坐标：native 长按回传的是 px（引擎 screenToGeo/pickVector 同口径），本浮层是 ArkUI 布局，
// 故锚点由宿主按 density 换算成 vp 传入（px ÷ densityPixels = vp）。

import { AppLog } from '../common/AppLog';

/** 环外径（Android DIAMETER_DP=150） */
const RING_SIZE: number = 150;
/** 5 项及以上的外径：150 环上 5 项弧距只有 62vp，装不下 84vp 槽位（文案会互压），扩到 172 让弧距到 75 */
const RING_SIZE_WIDE: number = 172;
/** 环带宽（Android BAND_DP=44）：环中线半径 = 外径半径 - 半带宽 */
const RING_BAND: number = 44;
/** 图标圆底板边长（Android band 半宽再内缩 4：44/2-4） */
const BUTTON_SIZE: number = 36;
/** 图标长边（Android ICON_RATIO=0.6；PNG 只定长边，另一边按原图比例自适） */
const ICON_SIZE: number = 22;
/** 单项槽位：宽按最长文案（5 字 11fp + 胶囊内衬 ≈ 67）留足，图标水平居中于槽位中心 */
const SLOT_W: number = 84;
const SLOT_H: number = 60;
/** 文案（Android LABEL_*） */
const LABEL_FONT: number = 11;
const LABEL_PAD_H: number = 6;
const LABEL_PAD_V: number = 3;
const LABEL_GAP: number = 3;
const LABEL_RADIUS: number = 7;
const LABEL_MAX_WIDTH: number = 130;
/** 圆心距屏幕边留白 / 落点脱离多远才画连接线 / 落点标记直径 */
const EDGE_MARGIN: number = 8;
const LINK_THRESHOLD: number = 12;
const ANCHOR_DOT: number = 6;
/** 逐项「长出来」的间隔：Android 用 220ms 扫完 360°，4 项等价 55ms 一项 */
const REVEAL_STEP_MS: number = 55;
/** 连接线宽与虚线节奏（Android LINK_WIDTH_DP=1.5 / DashPathEffect 6,5） */
const LINK_WIDTH: number = 1.5;

const SCRIM_COLOR: string = '#22000000';
const BUTTON_BG: string = '#FFFFFFFF';
const ICON_TINT: string = '#FF333333';
const LINK_COLOR: string = '#FF57ACFD';
const LABEL_BG: string = '#E6303030';
const LABEL_TEXT: string = '#FFFFFFFF';

/** 圆菜单单项：图标（rawfile SVG 可被 fillColor 染色，PNG 原样）+ 文案 + 动作 */
export class PieMenuAction {
  icon: Resource;
  label: string;
  /** 点击执行；执行前浮层已收起，动作里可直接拉相机/对话框 */
  run: () => void;

  // 全参带默认值：既支持宿主三参构造，也让组件侧的字段初值 `new PieMenuAction()` 成立
  constructor(icon: Resource = $rawfile('ic_pie_center.svg'), label: string = '',
    run: () => void = (): void => {}) {
    this.icon = icon;
    this.label = label;
    this.run = run;
  }
}

/** 一次弹出的圆菜单内容：锚点（vp，页面坐标）+ 动作项 */
export class PieMenuSpec {
  anchorXVp: number = 0;
  anchorYVp: number = 0;
  actions: PieMenuAction[] = [];
}

@Component
export struct PieMenuLayer {
  /** 内容在弹出时一次给定、存续期不变：普通成员即可（@Prop 深拷贝会把 run 引用丢掉） */
  spec: PieMenuSpec = new PieMenuSpec();
  /** 收起回调：宿主置空自己的菜单状态以卸载本浮层 */
  onDismiss: () => void = (): void => {};

  /** 已扫出的项数（对齐 Android openingAngle：扫过该项扇区末端才可见可点） */
  @State private shown: number = 0;
  /** 浮层实测尺寸（vp）：圆心钳位依赖，首帧 onAreaChange 前不画内容 */
  @State private areaW: number = 0;
  @State private areaH: number = 0;
  private revealTimers: number[] = [];

  aboutToAppear(): void {
    const n: number = this.spec.actions.length;
    for (let i = 0; i < n; i++) {
      this.revealTimers.push(setTimeout((): void => {
        this.shown = i + 1;
      }, REVEAL_STEP_MS * (i + 1)));
    }
    AppLog.i(`[PieMenu] 弹出 项数=${n} 锚点vp=(${this.spec.anchorXVp.toFixed(1)},${this.spec.anchorYVp.toFixed(1)})`);
  }

  aboutToDisappear(): void {
    for (let i = 0; i < this.revealTimers.length; i++) {
      clearTimeout(this.revealTimers[i]);
    }
    this.revealTimers = [];
  }

  /** 环外径：项数多了整环放大，否则相邻槽位的文案会叠在一起 */
  private ringSize(): number {
    return this.spec.actions.length > 4 ? RING_SIZE_WIDE : RING_SIZE;
  }

  /** 环中线半径：动作项就摆在这条线上 */
  private pathRadius(): number {
    return this.ringSize() / 2 - RING_BAND / 2;
  }

  /** 整块（含下方文案槽位）相对圆心的最大外扩：钳位用，保证文案不被屏幕裁掉 */
  private extent(): number {
    const radial: number = Math.max(SLOT_W / 2, SLOT_H - BUTTON_SIZE / 2);
    return Math.max(this.ringSize() / 2, this.pathRadius() + radial);
  }

  /** 单轴钳位；屏幕太小导致边界倒挂时退回下界（等价 Android coerceAtLeast 兜底） */
  private clampAxis(value: number, lo: number, hi: number): number {
    if (hi < lo) {
      return lo;
    }
    return value < lo ? lo : (value > hi ? hi : value);
  }

  private centerX(): number {
    const e: number = this.extent() + EDGE_MARGIN;
    return this.clampAxis(this.spec.anchorXVp, e, this.areaW - e);
  }

  private centerY(): number {
    const e: number = this.extent() + EDGE_MARGIN;
    return this.clampAxis(this.spec.anchorYVp, e, this.areaH - e);
  }

  /** 扇区角宽 */
  private segment(): number {
    const n: number = this.spec.actions.length;
    return n === 0 ? 360 : 360 / n;
  }

  /** 第 index 项图标圆心：第 0 项在正上方，顺时针等分（ArkUI y 向下 → 角度顺时针为正） */
  private itemCenter(index: number): number[] {
    const rad: number = Math.PI / 180 * (-90 + index * this.segment());
    return [this.centerX() + this.pathRadius() * Math.cos(rad),
      this.centerY() + this.pathRadius() * Math.sin(rad)];
  }

  /** 圆心是否已因钳位离开落点足够远（决定是否画连接线 + 落点标记） */
  private showLink(): boolean {
    const dx: number = this.centerX() - this.spec.anchorXVp;
    const dy: number = this.centerY() - this.spec.anchorYVp;
    return Math.hypot(dx, dy) > LINK_THRESHOLD;
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 遮罩：全屏兄弟节点，排在最下（先画），Block 让它吃掉按钮之外的空白并挡住身后的地图。
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(SCRIM_COLOR)
        .hitTestBehavior(HitTestMode.Block)
        .onClick((): void => {
          AppLog.i('[PieMenu] 点击遮罩空白 → 收起');
          this.onDismiss();
        })

      if (this.areaW > 0 && this.areaH > 0) {
        if (this.showLink()) {
          Path()
            .commands(`M ${this.spec.anchorXVp} ${this.spec.anchorYVp} L ${this.centerX()} ${this.centerY()}`)
            .stroke(LINK_COLOR)
            .strokeWidth(LINK_WIDTH)
            .strokeDashArray([6, 5])
            .fill(Color.Transparent)
            .width(this.areaW)
            .height(this.areaH)
            .position({ x: 0, y: 0 })
            .hitTestBehavior(HitTestMode.None)
        }
        Circle()
          .width(ANCHOR_DOT)
          .height(ANCHOR_DOT)
          .fill(LINK_COLOR)
          .position({ x: this.spec.anchorXVp - ANCHOR_DOT / 2, y: this.spec.anchorYVp - ANCHOR_DOT / 2 })
          .hitTestBehavior(HitTestMode.None)

        ForEach(this.spec.actions, (item: PieMenuAction, index: number): void => {
          PieMenuSlot({
            item: item,
            cx: this.itemCenter(index)[0],
            cy: this.itemCenter(index)[1],
            visible: this.shown > index,
            onPick: (): void => {
              AppLog.i(`[PieMenu] 点击项 #${index} ${item.label}`);
              item.run();
              this.onDismiss();
            },
          })
        }, (item: PieMenuAction, index: number): string => `${index}-${item.label}`)
      }
    }
    .width('100%')
    .height('100%')
    // 根节点保持默认命中模式：自身与子节点参与命中（槽位才收得到点击），兄弟节点（地图）被屏蔽，
    // 菜单打开期间地图依旧收不到手势；空白点击由遮罩节点自己处理，根节点不挂 onClick 免重复收起。
    .onAreaChange((oldValue: Area, newValue: Area): void => {
      this.areaW = typeof newValue.width === 'number' ? newValue.width : this.areaW;
      this.areaH = typeof newValue.height === 'number' ? newValue.height : this.areaH;
    })
  }
}

/**
 * 圆菜单单项槽位：图标圆在上、文案胶囊在下，整块槽位即热区（对齐 Android hitTest 的矩形口径）。
 * 拆成独立 @Component 而不用 @Builder：@Builder 的传参不随外部状态刷新（本工程实测坑），
 * 而这里的显隐恰恰要随逐项扫出动画刷新。
 */
@Component
struct PieMenuSlot {
  /** 动作项：弹出时定死，故用普通成员（函数成员不能过 @Prop 的深拷贝） */
  item: PieMenuAction = new PieMenuAction();
  /** 图标圆心（vp）：槽位以此为定位基准 */
  cx: number = 0;
  cy: number = 0;
  /** 是否已扫出（父组件逐项推进 shown 驱动） */
  @Prop visible: boolean = false;
  onPick: () => void = (): void => {};

  build() {
    Column() {
      Stack() {
        // 只定长边：SVG 方形自然 22x22，PNG 标记图（48x72 点位图标）按原比例收窄，不拉伸变形
        Image(this.item.icon)
          .height(ICON_SIZE)
          .objectFit(ImageFit.Contain)
          .fillColor(ICON_TINT)
      }
      .width(BUTTON_SIZE)
      .height(BUTTON_SIZE)
      .borderRadius(BUTTON_SIZE / 2)
      .backgroundColor(BUTTON_BG)

      Text(this.item.label)
        .fontSize(LABEL_FONT)
        .fontColor(LABEL_TEXT)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .padding({ left: LABEL_PAD_H, right: LABEL_PAD_H, top: LABEL_PAD_V, bottom: LABEL_PAD_V })
        .backgroundColor(LABEL_BG)
        .borderRadius(LABEL_RADIUS)
        .constraintSize({ maxWidth: LABEL_MAX_WIDTH })
        .margin({ top: LABEL_GAP })
    }
    .width(SLOT_W)
    .height(SLOT_H)
    .alignItems(HorizontalAlign.Center)
    .justifyContent(FlexAlign.Start)
    // 热区就是这一整块槽位：子节点不挂点击也不阻挡，命中一律落到槽位本身（图标 ∪ 文案）
    .hitTestBehavior(HitTestMode.Block)
    .onClick((): void => {
      this.onPick();
    })
    .position({ x: this.cx - SLOT_W / 2, y: this.cy - BUTTON_SIZE / 2 })
    .opacity(this.visible ? 1 : 0)
    .scale({ x: this.visible ? 1 : 0.6, y: this.visible ? 1 : 0.6 })
    .animation({ duration: 120, curve: Curve.EaseOut })
  }
}
