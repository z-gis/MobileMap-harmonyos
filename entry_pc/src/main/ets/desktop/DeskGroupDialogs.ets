// DeskGroupDialogs.ets —— 居中面板对话框集合：分组命名（新建/重命名）+ 移至分组 + 转到 XY。
//
// 与 LayerPropsPanel 同口径：不做 @CustomDialog，由宿主在 Stack 里盖遮罩渲染普通 @Component，
// @Prop 每次开面板重建取当前值（CustomDialogController 的 builder 参数构造期快照会拿旧值）。
// 命名面板回抛 name；移组面板回抛 (groupId, newGroupName)——newGroupName 非空时宿主先建组再移入。
import { DeskLayerGroup, DeskTheme, LayerRow } from '../common/DeskTheme';

/** 命名对话框：新建分组 / 重命名分组共用 */
@Component
export struct DeskNameDialog {
  @Prop title: string = '';
  @Prop initial: string = '';
  onConfirm: ((name: string) => void) | undefined = undefined;
  onClose: (() => void) | undefined = undefined;

  @State private name: string = '';

  aboutToAppear(): void {
    this.name = this.initial;
  }

  private close(): void {
    const cb = this.onClose;
    if (cb !== undefined) {
      cb();
    }
  }

  private confirm(): void {
    const n: string = this.name.trim();
    if (n.length === 0) {
      return;
    }
    const cb = this.onConfirm;
    if (cb !== undefined) {
      cb(n);
    }
    this.close();
  }

  build() {
    Column() {
      Row() {
        Text(this.title)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(DeskTheme.TEXT)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text('×')
          .fontSize(16)
          .fontColor(DeskTheme.TEXT_SUB)
          .width(24)
          .height(24)
          .textAlign(TextAlign.Center)
          .hoverEffect(HoverEffect.Highlight)
          .onClick((): void => { this.close(); })
      }
      .width('100%')
      .height(32)
      .padding({ left: 12, right: 6 })
      .backgroundColor(DeskTheme.CHROME)
      .border({ width: { bottom: 1 }, color: { bottom: DeskTheme.DIVIDER } })

      Column({ space: 8 }) {
        Text('分组名称')
          .fontSize(DeskTheme.FONT_BODY)
          .fontColor(DeskTheme.TEXT_SUB)
          .width('100%')
        TextInput({ text: this.name, placeholder: '请输入分组名称' })
          .fontSize(DeskTheme.FONT_BODY)
          .height(32)
          .width('100%')
          .backgroundColor(DeskTheme.PANEL)
          .border({ width: 1, color: DeskTheme.DIVIDER })
          .borderRadius(2)
          .onChange((v: string): void => { this.name = v; })
          .onSubmit((): void => { this.confirm(); })
      }
      .width('100%')
      .padding(14)
      .backgroundColor(DeskTheme.PANEL)
      .alignItems(HorizontalAlign.Start)

      Row({ space: 8 }) {
        Blank()
        Text('确定')
          .fontSize(DeskTheme.FONT_BODY)
          .fontColor(DeskTheme.TEXT)
          .width(76)
          .height(26)
          .textAlign(TextAlign.Center)
          .backgroundColor(DeskTheme.CHROME)
          .border({ width: 1, color: DeskTheme.DIVIDER })
          .borderRadius(2)
          .hoverEffect(HoverEffect.Highlight)
          .onClick((): void => { this.confirm(); })
        Text('取消')
          .fontSize(DeskTheme.FONT_BODY)
          .fontColor(DeskTheme.TEXT)
          .width(76)
          .height(26)
          .textAlign(TextAlign.Center)
          .backgroundColor(DeskTheme.CHROME)
          .border({ width: 1, color: DeskTheme.DIVIDER })
          .borderRadius(2)
          .hoverEffect(HoverEffect.Highlight)
          .onClick((): void => { this.close(); })
      }
      .width('100%')
      .height(42)
      .padding({ left: 12, right: 12 })
      .backgroundColor(DeskTheme.CHROME)
      .border({ width: { top: 1 }, color: { top: DeskTheme.DIVIDER_SOFT } })
    }
    .width(360)
    .backgroundColor(DeskTheme.PANEL)
    .border({ width: 1, color: DeskTheme.DIVIDER })
    .borderRadius(3)
    .shadow({ radius: 18, color: 'rgba(0,0,0,0.35)', offsetX: 0, offsetY: 6 })
  }
}

/** 移至分组对话框：Select 选已有组 / 未分组，末项「新建分组…」展开内联输入 */
@Component
export struct DeskGroupPickDialog {
  @Prop layerName: string = '';
  @Prop currentGroupId: number = LayerRow.UNGROUPED_ID;
  @Prop groups: DeskLayerGroup[] = [];
  onConfirm: ((groupId: number, newGroupName: string) => void) | undefined = undefined;
  onClose: (() => void) | undefined = undefined;

  /** 0=未分组，1..groups.length=对应组，groups.length+1=新建分组… */
  @State private selIndex: number = 0;
  @State private newName: string = '';

  aboutToAppear(): void {
    this.selIndex = 0;
    for (let i = 0; i < this.groups.length; i++) {
      if (this.groups[i].id === this.currentGroupId) {
        this.selIndex = i + 1;
        break;
      }
    }
    this.newName = '';
  }

  private close(): void {
    const cb = this.onClose;
    if (cb !== undefined) {
      cb();
    }
  }

  private options(): SelectOption[] {
    const out: SelectOption[] = [{ value: '未分组' }];
    for (let i = 0; i < this.groups.length; i++) {
      out.push({ value: this.groups[i].name });
    }
    out.push({ value: '新建分组…' });
    return out;
  }

  private selText(): string {
    if (this.selIndex === 0) {
      return '未分组';
    }
    if (this.selIndex <= this.groups.length) {
      return this.groups[this.selIndex - 1].name;
    }
    return '新建分组…';
  }

  private confirm(): void {
    const cb = this.onConfirm;
    if (cb === undefined) {
      return;
    }
    if (this.selIndex === 0) {
      cb(LayerRow.UNGROUPED_ID, '');
    } else if (this.selIndex <= this.groups.length) {
      cb(this.groups[this.selIndex - 1].id, '');
    } else {
      const n: string = this.newName.trim();
      if (n.length === 0) {
        return;
      }
      cb(LayerRow.UNGROUPED_ID, n);
    }
    this.close();
  }

  build() {
    Column() {
      Row() {
        Text(`移至分组：${this.layerName}`)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(DeskTheme.TEXT)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text('×')
          .fontSize(16)
          .fontColor(DeskTheme.TEXT_SUB)
          .width(24)
          .height(24)
          .textAlign(TextAlign.Center)
          .hoverEffect(HoverEffect.Highlight)
          .onClick((): void => { this.close(); })
      }
      .width('100%')
      .height(32)
      .padding({ left: 12, right: 6 })
      .backgroundColor(DeskTheme.CHROME)
      .border({ width: { bottom: 1 }, color: { bottom: DeskTheme.DIVIDER } })

      Column({ space: 10 }) {
        Text('目标分组')
          .fontSize(DeskTheme.FONT_BODY)
          .fontColor(DeskTheme.TEXT_SUB)
          .width('100%')
        Select(this.options())
          .selected(this.selIndex)
          .value(this.selText())
          .font({ size: DeskTheme.FONT_BODY })
          .width('100%')
          .height(32)
          .onSelect((index: number, value: string): void => { this.selIndex = index; })
        if (this.selIndex === this.groups.length + 1) {
          TextInput({ text: this.newName, placeholder: '新分组名称' })
            .fontSize(DeskTheme.FONT_BODY)
            .height(32)
            .width('100%')
            .backgroundColor(DeskTheme.PANEL)
            .border({ width: 1, color: DeskTheme.DIVIDER })
            .borderRadius(2)
            .onChange((v: string): void => { this.newName = v; })
            .onSubmit((): void => { this.confirm(); })
        }
      }
      .width('100%')
      .padding(14)
      .backgroundColor(DeskTheme.PANEL)
      .alignItems(HorizontalAlign.Start)

      Row({ space: 8 }) {
        Blank()
        Text('确定')
          .fontSize(DeskTheme.FONT_BODY)
          .fontColor(DeskTheme.TEXT)
          .width(76)
          .height(26)
          .textAlign(TextAlign.Center)
          .backgroundColor(DeskTheme.CHROME)
          .border({ width: 1, color: DeskTheme.DIVIDER })
          .borderRadius(2)
          .hoverEffect(HoverEffect.Highlight)
          .onClick((): void => { this.confirm(); })
        Text('取消')
          .fontSize(DeskTheme.FONT_BODY)
          .fontColor(DeskTheme.TEXT)
          .width(76)
          .height(26)
          .textAlign(TextAlign.Center)
          .backgroundColor(DeskTheme.CHROME)
          .border({ width: 1, color: DeskTheme.DIVIDER })
          .borderRadius(2)
          .hoverEffect(HoverEffect.Highlight)
          .onClick((): void => { this.close(); })
      }
      .width('100%')
      .height(42)
      .padding({ left: 12, right: 12 })
      .backgroundColor(DeskTheme.CHROME)
      .border({ width: { top: 1 }, color: { top: DeskTheme.DIVIDER_SOFT } })
    }
    .width(360)
    .backgroundColor(DeskTheme.PANEL)
    .border({ width: 1, color: DeskTheme.DIVIDER })
    .borderRadius(3)
    .shadow({ radius: 18, color: 'rgba(0,0,0,0.35)', offsetX: 0, offsetY: 6 })
  }
}
/**
 * 转到 XY 对话框（工具栏「转到 XY」）：十进制度输入，经度 -180..180 / 纬度 -90..90，
 * 越界或非数值只在面板内提示、不关闭（照 ArcMap Go To 的容错口径）。
 * 回抛 (lat, lon)，海拔/姿态由宿主保持不动。
 */
@Component
export struct DeskGotoDialog {
  @Prop initLat: number = 0;
  @Prop initLon: number = 0;
  onConfirm: ((lat: number, lon: number) => void) | undefined = undefined;
  onClose: (() => void) | undefined = undefined;

  @State private lonText: string = '';
  @State private latText: string = '';
  @State private error: string = '';

  aboutToAppear(): void {
    this.lonText = this.initLon.toFixed(6);
    this.latText = this.initLat.toFixed(6);
    this.error = '';
  }

  private close(): void {
    const cb = this.onClose;
    if (cb !== undefined) {
      cb();
    }
  }

  private confirm(): void {
    const lon: number = Number(this.lonText.trim());
    const lat: number = Number(this.latText.trim());
    if (!Number.isFinite(lon) || !Number.isFinite(lat)) {
      this.error = '请输入十进制度数值（如 113.485796）';
      return;
    }
    if (lon < -180 || lon > 180) {
      this.error = '经度须在 -180 ~ 180 之间';
      return;
    }
    if (lat < -90 || lat > 90) {
      this.error = '纬度须在 -90 ~ 90 之间';
      return;
    }
    const cb = this.onConfirm;
    if (cb !== undefined) {
      cb(lat, lon);
    }
    this.close();
  }

  build() {
    Column() {
      Row() {
        Text('转到 XY')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(DeskTheme.TEXT)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text('×')
          .fontSize(16)
          .fontColor(DeskTheme.TEXT_SUB)
          .width(24)
          .height(24)
          .textAlign(TextAlign.Center)
          .hoverEffect(HoverEffect.Highlight)
          .onClick((): void => { this.close(); })
      }
      .width('100%')
      .height(32)
      .padding({ left: 12, right: 6 })
      .backgroundColor(DeskTheme.CHROME)
      .border({ width: { bottom: 1 }, color: { bottom: DeskTheme.DIVIDER } })

      Column({ space: 8 }) {
        Text('X（经度，十进制度）')
          .fontSize(DeskTheme.FONT_BODY)
          .fontColor(DeskTheme.TEXT_SUB)
          .width('100%')
        TextInput({ text: this.lonText, placeholder: '-180 ~ 180' })
          .fontSize(DeskTheme.FONT_BODY)
          .height(32)
          .width('100%')
          .backgroundColor(DeskTheme.PANEL)
          .border({ width: 1, color: DeskTheme.DIVIDER })
          .borderRadius(2)
          .onChange((v: string): void => {
            this.lonText = v;
            this.error = '';
          })
          .onSubmit((): void => { this.confirm(); })
        Text('Y（纬度，十进制度）')
          .fontSize(DeskTheme.FONT_BODY)
          .fontColor(DeskTheme.TEXT_SUB)
          .width('100%')
        TextInput({ text: this.latText, placeholder: '-90 ~ 90' })
          .fontSize(DeskTheme.FONT_BODY)
          .height(32)
          .width('100%')
          .backgroundColor(DeskTheme.PANEL)
          .border({ width: 1, color: DeskTheme.DIVIDER })
          .borderRadius(2)
          .onChange((v: string): void => {
            this.latText = v;
            this.error = '';
          })
          .onSubmit((): void => { this.confirm(); })
        if (this.error.length > 0) {
          Text(this.error)
            .fontSize(DeskTheme.FONT_BODY)
            .fontColor('#B00000')
            .width('100%')
        }
      }
      .width('100%')
      .padding(14)
      .backgroundColor(DeskTheme.PANEL)
      .alignItems(HorizontalAlign.Start)

      Row({ space: 8 }) {
        Blank()
        Text('转到')
          .fontSize(DeskTheme.FONT_BODY)
          .fontColor(DeskTheme.TEXT)
          .width(76)
          .height(26)
          .textAlign(TextAlign.Center)
          .backgroundColor(DeskTheme.CHROME)
          .border({ width: 1, color: DeskTheme.DIVIDER })
          .borderRadius(2)
          .hoverEffect(HoverEffect.Highlight)
          .onClick((): void => { this.confirm(); })
        Text('取消')
          .fontSize(DeskTheme.FONT_BODY)
          .fontColor(DeskTheme.TEXT)
          .width(76)
          .height(26)
          .textAlign(TextAlign.Center)
          .backgroundColor(DeskTheme.CHROME)
          .border({ width: 1, color: DeskTheme.DIVIDER })
          .borderRadius(2)
          .hoverEffect(HoverEffect.Highlight)
          .onClick((): void => { this.close(); })
      }
      .width('100%')
      .height(42)
      .padding({ left: 12, right: 12 })
      .backgroundColor(DeskTheme.CHROME)
      .border({ width: { top: 1 }, color: { top: DeskTheme.DIVIDER_SOFT } })
    }
    .width(360)
    .backgroundColor(DeskTheme.PANEL)
    .border({ width: 1, color: DeskTheme.DIVIDER })
    .borderRadius(3)
    .shadow({ radius: 18, color: 'rgba(0,0,0,0.35)', offsetX: 0, offsetY: 6 })
  }
}
