// AddLayerPage.ets —— 导入本地图层页（对应 Android ui.activity.OpenFileActivity）。
//
// Android 自研文件管理器可原地引用沙箱外路径；鸿蒙沙箱不允许应用遍历公共目录，须先经系统选择器
// 拿授权再拷入沙箱 调查宝/layer/。关键约束：手机 FILE 选择器只授权「点中的单个文件」，未选中的
// 同名附属（.dbf/.shx/.prj…）直读必被拒——故主链路走 FOLDER 目录授权（API26 手机支持）：
//  · 选文件夹 → 应用内只列主数据文件（shp/kml/zip/tif…）→ 勾选 → 在授权目录下自动收齐同名附属整族拷入；
//  · 旧系统无 FolderSelection 能力时降级 FILE 多选（附属需手动一并选中）。
// 同名冲突弹「重新导入 / 重命名导入」；导入成功写文档落盘，主界面监听把图层加进地图并缩放到四至。
// 入口参数 tab 决定初始类型；导入完成后写入 PageData 供主界面缩放（等价 Android 行为）。

import { picker } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { PageData, PageKeys } from '../common/PageData';
import { Theme } from '../common/Theme';
import { Ui } from '../common/Ui';
import { LayerInfo } from '../doc/DocModels';
import { DocumentManager } from '../doc/DocumentManager';
import { ImportResult, VectorFileImporter, ImportCandidate } from '../vector/VectorFileImporter';
import { LayerType, VectorFormats } from '../vector/VectorFormats';
import { TitleBar } from '../components/TitleBar';
import { NameEditDialog } from '../components/NameEditDialog';
import { FolderFilePickDialog } from '../components/FolderFilePickDialog';

@Entry
@Component
struct AddLayerPage {
  /** 底部导航条避让高度（vp）：主窗口是全屏布局，页面内容要让开导航条 */
  @StorageProp('bottomInsetVp') bottomInset: number = 0;
  @State isVector: boolean = true;
  @State busy: boolean = false;
  /** 本机是否支持 FOLDER 目录授权（API26 手机起支持；旧系统降级 FILE 多选） */
  @State folderSupported: boolean = false;
  /** 已成功导入的图层名（本页内的即时反馈清单，离开页面即失） */
  @State imported: string[] = [];
  /** 弹窗控制器须挂成员字段：局部变量持有的控制器不会被框架注入弹窗（this.controller 为 undefined 致 close 崩溃） */
  private folderPickDialog: CustomDialogController | null = null;
  private nameDialog: CustomDialogController | null = null;

  aboutToAppear(): void {
    this.folderSupported = canIUse('SystemCapability.FileManagement.UserFileService.FolderSelection');
    const raw: Object = router.getParams();
    if (raw === undefined || raw === null) {
      return;
    }
    // LayerManageParams.tab：0 矢量 / 1 栅格 / 2 地图源（地图源不会进本页，按矢量处理）
    const tab: number = (raw as Record<string, number>).tab ?? 0;
    this.isVector = tab !== 1;
  }

  private typeLabel(): string {
    return this.isVector ? '矢量图层' : '栅格图层';
  }

  private supportedExts(): string[] {
    return VectorFormats.pickFilter(this.isVector ? LayerType.VECTOR : LayerType.RASTER);
  }

  private switchType(toVector: boolean): void {
    if (toVector === this.isVector) {
      return;
    }
    this.isVector = toVector;
  }

  private async choose(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      const ctx: common.UIAbilityContext =
        this.getUIContext().getHostContext() as common.UIAbilityContext;
      if (this.folderSupported) {
        await this.pickFromFolder(ctx);
      } else {
        await this.pickFilesFallback(ctx);
      }
    } catch (e) {
      Ui.toast(`选择文件失败：${e}`);
    } finally {
      this.busy = false;
    }
  }

  /**
   * 主链路：FOLDER 目录授权 → 应用内只列主数据文件 → 勾选 → 授权目录下自动收同名附属整族导入。
   * 目录枚举失败（能力命中但系统未真正放行）时降级 FILE 多选，保证仍可导入。
   */
  private async pickFromFolder(ctx: common.UIAbilityContext): Promise<void> {
    const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
    options.selectMode = picker.DocumentSelectMode.FOLDER;
    const folders: string[] = await new picker.DocumentViewPicker(ctx).select(options);
    if (folders === undefined || folders.length === 0) {
      return;
    }
    const folderUri: string = folders[0];
    const mains: string[] = VectorFileImporter.listMainInFolder(folderUri, !this.isVector);
    if (mains.length === 0) {
      Ui.toast('该文件夹内无可导入数据（或目录读取受限），改用文件选择');
      await this.pickFilesFallback(ctx);
      return;
    }
    const folderName: string = VectorFileImporter.fileNameOfUri(folderUri);
    const picked: string[] = await this.askPickFiles(folderName, mains);
    if (picked.length === 0) {
      return;
    }
    const candidates: ImportCandidate[] = VectorFileImporter.planSources(picked);
    for (let i = 0; i < candidates.length; i++) {
      candidates[i].sideCars = VectorFileImporter.collectFolderSiblings(candidates[i].mainUri);
    }
    await this.doImportCandidates(candidates);
  }

  /** 旧系统降级：FILE 多选（只列主文件；附属需用户手动一并选中，分组导入由导入器负责） */
  private async pickFilesFallback(ctx: common.UIAbilityContext): Promise<void> {
    const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
    options.maxSelectNumber = 64;
    options.fileSuffixFilters = this.mainSuffixFilters();
    const uris: string[] = await new picker.DocumentViewPicker(ctx).select(options);
    if (uris === undefined || uris.length === 0) {
      return;
    }
    const candidates: ImportCandidate[] = VectorFileImporter.planSources(uris);
    await this.doImportCandidates(candidates);
  }

  /** 文件夹内主文件勾选框：确定返回勾选 URI，取消/遮罩返回空数组 */
  private askPickFiles(folderName: string, files: string[]): Promise<string[]> {
    return new Promise<string[]>((resolve: (v: string[]) => void): void => {
      let settled: boolean = false;
      const finish = (v: string[]): void => {
        if (!settled) {
          settled = true;
          this.folderPickDialog?.close();
          resolve(v);
        }
      };
      const dlg: CustomDialogController = new CustomDialogController({
        builder: FolderFilePickDialog({
          folderName: folderName,
          files: files,
          onPick: (uris: string[]): void => {
            finish(uris);
          },
          onCancel: (): void => {
            finish([]);
          },
        }),
        customStyle: true,
        alignment: DialogAlignment.Center,
        autoCancel: true,
        cancel: (): void => {
          finish([]);
        },
      });
      this.folderPickDialog = dlg;
      dlg.open();
    });
  }

  /** 选择器只放行主数据扩展名（矢量/栅格白名单），附属文件不列出（FILE 降级时附属需手动多选） */
  private mainSuffixFilters(): string[] {
    const exts: string[] = this.isVector ? VectorFormats.VECTOR_EXTS : VectorFormats.RASTER_EXTS;
    const out: string[] = [];
    for (let i = 0; i < exts.length; i++) {
      out.push(`.${exts[i]}`);
    }
    return out;
  }

  /**
   * 候选式导入：先规划（不拷贝）→ 逐个判同名冲突 → 按用户选择落盘 → 写文档落盘。
   *  · 无冲突：整族拷入 + 新增层；
   *  · 同名冲突：重新导入（覆盖 + styleVersion+1 触发墓碑换层刷新，保留样式）/ 重命名导入（另存新层）/ 取消；
   *  · 归档 zip/kmz：走既有解压链路（自带 _2 避重），不做同名弹框。
   * 矢量/栅格按各自主文件类型路由，不受当前页签限制。
   */
  private async doImportCandidates(candidates: ImportCandidate[]): Promise<void> {
    if (candidates.length === 0) {
      Ui.toast('文件夹内无可导入数据');
      return;
    }
    const doc = DocumentManager.getInstance().getDocument();
    if (doc === null) {
      Ui.toast('地图文档未就绪');
      return;
    }
    const added: string[] = [];
    let lastPath: string = '';
    for (let i = 0; i < candidates.length; i++) {
      const c: ImportCandidate = candidates[i];
      if (VectorFormats.isArchive(c.mainUri)) {
        const rs: ImportResult[] = await VectorFileImporter.importOne(c.mainUri);
        for (let j = 0; j < rs.length; j++) {
          const r: ImportResult = rs[j];
          const target: LayerInfo[] = VectorFormats.isRaster(r.path) ? doc.rasterLayers : doc.vectorLayers;
          const type: string = VectorFormats.isRaster(r.path) ? LayerInfo.TYPE_RASTER : LayerInfo.TYPE_VECTOR;
          let exists: boolean = false;
          for (let k = 0; k < target.length; k++) {
            if (target[k].path === r.path) {
              exists = true;
              break;
            }
          }
          if (!exists) {
            target.push(new LayerInfo(r.name, r.path, type, true));
            added.push(r.name);
            lastPath = r.path;
          }
        }
        continue;
      }
      const raster: boolean = VectorFormats.isRaster(c.mainUri);
      const target: LayerInfo[] = raster ? doc.rasterLayers : doc.vectorLayers;
      const type: string = raster ? LayerInfo.TYPE_RASTER : LayerInfo.TYPE_VECTOR;
      const existing: LayerInfo | undefined = this.findConflict(target, c.name);
      if (existing === undefined) {
        const r: ImportResult | null = VectorFileImporter.importGroup(c, c.name);
        if (r !== null) {
          target.push(new LayerInfo(r.name, r.path, type, true));
          added.push(r.name);
          lastPath = r.path;
        } else {
          Ui.toast(`导入失败：${c.name}`);
        }
        continue;
      }
      const choice: number = await Ui.items(`图层「${c.name}」已存在`, ['重新导入', '重命名导入', '取消']);
      if (choice === 0) {
        // 重新导入：整族覆盖 + styleVersion+1 → syncVectorLayers 墓碑旧层重挂，native 重开刷新（无需重启）
        const r: ImportResult | null = VectorFileImporter.importGroup(c, c.name);
        if (r !== null) {
          existing.path = r.path;
          existing.styleVersion += 1;
          added.push(c.name);
          lastPath = r.path;
        } else {
          Ui.toast(`重新导入失败：${c.name}`);
        }
      } else if (choice === 1) {
        const def: string = this.uniqueName(target, c.name);
        const newName: string = await this.askNewName(def);
        if (newName.length === 0) {
          continue;
        }
        if (this.findConflict(target, newName) !== undefined) {
          Ui.toast('名称仍重复，已跳过');
          continue;
        }
        const r: ImportResult | null = VectorFileImporter.importGroup(c, newName);
        if (r !== null) {
          target.push(new LayerInfo(r.name, r.path, type, true));
          added.push(r.name);
          lastPath = r.path;
        } else {
          Ui.toast(`导入失败：${newName}`);
        }
      }
    }
    DocumentManager.getInstance().save();
    if (added.length === 0) {
      Ui.toast('未导入任何图层');
      return;
    }
    PageData.put(PageKeys.IMPORTED_LAYER_PATH, lastPath);
    const merged: string[] = [];
    for (let i = 0; i < this.imported.length; i++) {
      merged.push(this.imported[i]);
    }
    for (let i = 0; i < added.length; i++) {
      merged.push(added[i]);
    }
    this.imported = merged;
    Ui.toast(`已导入 ${added.length} 个图层`);
  }

  /** 同类型图层列表里按显示名查冲突层（无则 undefined） */
  private findConflict(layers: LayerInfo[], name: string): LayerInfo | undefined {
    for (let i = 0; i < layers.length; i++) {
      if (layers[i].displayName() === name) {
        return layers[i];
      }
    }
    return undefined;
  }

  /** 生成不冲突的默认新名：base_1、base_2… */
  private uniqueName(layers: LayerInfo[], base: string): string {
    let seq: number = 1;
    let cand: string = `${base}_${seq}`;
    while (this.findConflict(layers, cand) !== undefined) {
      seq++;
      cand = `${base}_${seq}`;
    }
    return cand;
  }

  /** 重命名输入框：确定返回新名，取消/遮罩返回空串（复用 NameEditDialog） */
  private askNewName(initial: string): Promise<string> {
    return new Promise<string>((resolve: (v: string) => void): void => {
      let settled: boolean = false;
      const finish = (v: string): void => {
        if (!settled) {
          settled = true;
          resolve(v);
        }
      };
      const dlg: CustomDialogController = new CustomDialogController({
        builder: NameEditDialog({
          title: '重命名导入',
          label: '新名称',
          placeholder: '请输入新名称',
          initialValue: initial,
          onConfirmName: (name: string): void => {
            finish(name);
          },
          onCancel: (): void => {
            finish('');
          },
        }),
        customStyle: true,
        alignment: DialogAlignment.Center,
        autoCancel: true,
        cancel: (): void => {
          finish('');
        },
      });
      this.nameDialog = dlg;
      dlg.open();
    });
  }

  build() {
    Column() {
      TitleBar({ title: '导入本地图层', subtitle: this.typeLabel() })

      Row({ space: 8 }) {
        this.tabItem('矢量图层', true)
        this.tabItem('栅格图层', false)
      }
      .width('100%')
      .padding({ left: Theme.PAD, right: Theme.PAD, top: Theme.GAP })

      Text(`支持格式：${this.supportedExts().join('、')}`)
        .fontSize(Theme.FONT_SUB)
        .fontColor(Theme.TEXT_SUB)
        .width('100%')
        .padding({ left: Theme.PAD, right: Theme.PAD, top: 10 })

      Text('提示：先选数据所在文件夹，列表只列主数据文件（shp/kml/zip 等），勾选后自动收齐'
        + '同目录同名附属（.dbf/.shx/.prj 等），zip/kmz 自动解压。\n同名图层可选「重新导入」覆盖刷新或「重命名导入」另存。'
        + '导入后的文件复制到应用数据目录「调查宝/layer」，与原文件不再关联。')
        .fontSize(Theme.FONT_SUB)
        .fontColor(Theme.TEXT_HINT)
        .width('100%')
        .padding({ left: Theme.PAD, right: Theme.PAD, top: 6 })

      Button(this.busy ? '正在导入…' : (this.folderSupported ? '选择数据文件夹' : '选择数据文件'))
        .width('100%')
        .height(44)
        .fontSize(Theme.FONT)
        .fontColor(Theme.TEXT_ON_DARK)
        .backgroundColor(Theme.PRIMARY)
        .borderRadius(Theme.RADIUS)
        .enabled(!this.busy)
        .margin({ left: Theme.PAD, right: Theme.PAD, top: 14 })
        .onClick((): void => {
          this.choose();
        })

      List({ space: Theme.GAP }) {
        ForEach(this.imported, (name: string): void => {
          ListItem() {
            Row() {
              SymbolGlyph($r('sys.symbol.checkmark'))
                .fontSize(16)
                .fontColor([Theme.OK])
                .margin({ right: 8 })
              Text(name)
                .fontSize(Theme.FONT)
                .fontColor(Theme.TEXT)
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .width('100%')
            .padding(12)
            .backgroundColor(Theme.CARD)
            .borderRadius(Theme.RADIUS)
          }
        }, (name: string, index: number): string => `${name}_${index}`)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .padding({ left: Theme.PAD, right: Theme.PAD, top: Theme.GAP, bottom: Theme.PAD })
    }
    .width('100%')
    .height('100%')
    .padding({ bottom: this.bottomInset })
    .backgroundColor(Theme.BG)
  }

  /**
   * 类型页签。
   * 选中态用 @State isVector 直接判定（非 @Builder 入参），保证切换后两枚页签同时刷新。
   */
  @Builder
  tabItem(label: string, toVector: boolean) {
    Text(label)
      .fontSize(Theme.FONT)
      .fontColor(this.isVector === toVector ? Theme.TEXT_ON_DARK : Theme.TEXT_SUB)
      .textAlign(TextAlign.Center)
      .height(34)
      .layoutWeight(1)
      .backgroundColor(this.isVector === toVector ? Theme.PRIMARY : Theme.SUBTLE)
      .borderRadius(Theme.RADIUS)
      .onClick((): void => {
        this.switchType(toVector);
      })
  }
}
