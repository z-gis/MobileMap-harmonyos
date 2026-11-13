// ProjectManagePage.ets —— 工程管理页（对应 Android ui/dialog/ProjectManageDialog.kt）。
//
// Android 是主界面「工程」入口的对话框；鸿蒙侧同类对话框做成 router 全屏页
// （与 LayerManagePage 同策略：列表行操作密度高，对话框放不下），主界面入口接线在后续批次统一做。
// 交互对齐 Android 已定规则：
//  · 列表项：工程名 +（当前工程蓝底标记）+ 修改时间/大小；行点击 = 打开，右侧三点按钮弹操作菜单
//    （分享/复制/重命名/备份/合并，非当前工程另有「删除」「合并到当前工程」），禁止长按交互。
//    菜单不含「打开」——与 Android 一致，打开走行点击。
//  · 打开/新建成功后经 PageData 交接槽（PageKeys.PROJECT_CHANGED）携结果返回，
//    主界面消费后刷新数据（与 IMPORTED_LAYER_PATH 同一惯例）；合并改写了当前工程数据，
//    同样置该交接槽（页面留在原地，返回主界面即重建叠加层）。
//  · 重命名同名冲突由 ProjectManager 拒绝，此处 toast 提示；新建重名自动带序号；
//    复制命名「xx 副本」，已存在则递增序号（uniqueCopyName 同口径）。
//  · 删除需二次确认；API 层 ProjectManager.deleteProject 亦拒绝删除当前工程（双保险）。
//  · 合并（startMerge）恒以当前工程为目标：源工程只读不改写；并入前自动备份当前工程，
//    备份失败即中止（本操作不可撤销地改写当前工程，宁可不做），因此无需「撤销」。
//    整段流程（读源 → 确认 → 备份 → 并表 → 落盘）由 merging 标记防抖；鸿蒙增量写是同步
//    NAPI，故各步直接 await，不进线程（Android 的后台线程编排在此无对应物）。
//
// 分享导出（鸿蒙沙箱无公共目录写权限，两路径按优先级）：
//  ① 系统分享面板 @kit.ShareKit systemShare（media/MediaPackage.ets 分享照片包已验证同款可用），
//     gpkg 单文件自包含，分享文件本体，QGIS/ArcGIS 可直接读取；当前工程先 saveNow() 保证元数据落盘；
//  ② 分享面板拉起失败时退化为「导出副本」：@kit.CoreFileKit picker DocumentSaveOptions
//     让用户选公共 Documents 目录位置保存副本。
// 备份同理落在沙箱 <filesDir>/调查宝/backups/（Android 是 /sdcard/调查宝/backups），
// 需要取出时用「分享」把备份文件发出去（本版本先保数据，不做备份列表 UI）。

import fs from '@ohos.file.fs';
import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { fileUri, picker } from '@kit.CoreFileKit';
import { systemShare } from '@kit.ShareKit';
import { AppDirs } from '../common/AppDirs';
import { AppLog } from '../common/AppLog';
import { PageData, PageKeys } from '../common/PageData';
import { Theme } from '../common/Theme';
import { Ui } from '../common/Ui';
import { MergeResult, ProjectManager, ProjectInfo } from '../project/ProjectManager';
import { Project } from '../project/ProjectModels';
import { NameEditDialog } from '../components/NameEditDialog';
import { OptionListDialog } from '../components/OptionListDialog';
import { TitleBar } from '../components/TitleBar';

/** UDMF 统一数据类型：数据库文件（gpkg 本质 SQLite，分享面板据此匹配接收端） */
const UTD_DATABASE: string = 'general.database';

/** 工程行视图模型：由 ProjectInfo 重建，含当前工程标记与去扩展名显示名 */
class ProjectRow {
  fileName: string = '';
  filePath: string = '';
  /** 去 .gpkg 扩展名的显示名 */
  baseName: string = '';
  displaySize: string = '';
  displayDate: string = '';
  /** 是否当前工程（决定蓝底标记与菜单是否含「删除」） */
  current: boolean = false;

  /** ForEach 键：任一影响显示的值变化即重建该行 */
  key(): string {
    return `${this.fileName}|${this.current}|${this.displaySize}|${this.displayDate}`;
  }
}

@Entry
@Component
struct ProjectManagePage {
  /** 底部导航条避让高度（vp）：主窗口是全屏布局，列表末项要让开导航条 */
  @StorageProp('bottomInsetVp') bottomInset: number = 0;
  @State rows: ProjectRow[] = [];
  /** 打开/新建进行中：防双击重复切换（Android isOpening 标记同义） */
  @State opening: boolean = false;
  /** 合并进行中：整段流程（读源 → 确认 → 备份 → 并表 → 落盘）期间忽略再次点击（Android mergeRunning 同义） */
  private merging: boolean = false;

  private nameDialog: CustomDialogController | undefined = undefined;
  /** 合并源候选列表对话框：候选每次弹前才确定，故重建控制器 */
  private optionDialog: CustomDialogController | undefined = undefined;

  aboutToAppear(): void {
    this.reload();
  }

  private context(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  private pm(): ProjectManager {
    return ProjectManager.get(this.context());
  }

  // ── 列表同步 ────────────────────────────────────────────────────

  private async reload(): Promise<void> {
    const pm: ProjectManager = this.pm();
    const infos: ProjectInfo[] = await pm.listProjects();
    const currentFile: string = pm.currentFileName();
    const rows: ProjectRow[] = [];
    for (let i = 0; i < infos.length; i++) {
      const info: ProjectInfo = infos[i];
      const row: ProjectRow = new ProjectRow();
      row.fileName = info.fileName;
      row.filePath = info.filePath;
      row.baseName = info.fileName.replace(/\.gpkg$/, '');
      row.displaySize = info.displaySize;
      row.displayDate = info.displayDate;
      row.current = info.fileName === currentFile;
      rows.push(row);
    }
    this.rows = rows;
  }

  // ── 工程动作 ────────────────────────────────────────────────────

  /** 打开工程：成功后携结果（PageKeys.PROJECT_CHANGED = 工程名）返回主界面刷新数据 */
  private async openProject(row: ProjectRow): Promise<void> {
    if (this.opening) {
      return;
    }
    if (!AppDirs.exists(row.filePath)) {
      Ui.toast('工程文件不存在');
      await this.reload();
      return;
    }
    this.opening = true;
    Ui.toast('正在打开工程…');
    const p: Project | null = await this.pm().openProject(row.filePath);
    this.opening = false;
    if (p === null) {
      Ui.toast('工程读取失败');
      return;
    }
    Ui.toast(`已打开工程：${p.name}`);
    PageData.put(PageKeys.PROJECT_CHANGED, p.name);
    router.back();
  }

  /** 新建工程：弹输入框（描述从简不填）；重名自动带序号由 ProjectManager 处理 */
  private showCreateDialog(): void {
    this.nameDialog = new CustomDialogController({
      builder: NameEditDialog({
        title: '新建工程',
        placeholder: '请输入工程名称',
        initialValue: '',
        onConfirmName: (name: string): void => {
          this.createProject(name);
        },
      }),
      customStyle: true,
      alignment: DialogAlignment.Center,
      autoCancel: true,
    });
    this.nameDialog.open();
  }

  private async createProject(name: string): Promise<void> {
    if (this.opening) {
      return;
    }
    this.opening = true;
    const p: Project | null = await this.pm().createProject(name, '');
    this.opening = false;
    if (p === null) {
      Ui.toast('创建失败：写入出错');
      return;
    }
    Ui.toast(`已创建并切换到新工程：${p.name}`);
    PageData.put(PageKeys.PROJECT_CHANGED, p.name);
    router.back();
  }

  /** 重命名工程文件：同名冲突 ProjectManager 拒绝（当前工程会同步改工程名并落元数据） */
  private showRenameDialog(row: ProjectRow): void {
    this.nameDialog = new CustomDialogController({
      builder: NameEditDialog({
        title: '重命名工程',
        placeholder: '请输入工程名称',
        initialValue: row.baseName,
        onConfirmName: (name: string): void => {
          this.renameProject(row, name);
        },
      }),
      customStyle: true,
      alignment: DialogAlignment.Center,
      autoCancel: true,
    });
    this.nameDialog.open();
  }

  private async renameProject(row: ProjectRow, newName: string): Promise<void> {
    if (newName === row.baseName) {
      return; // 未改动不视为失败（同路径冲突检查会误报同名）
    }
    const ok: boolean = await this.pm().renameProject(row.fileName, newName);
    if (!ok) {
      Ui.toast('重命名失败：已存在同名工程');
      return;
    }
    Ui.toast('已重命名');
    await this.reload();
  }

  /**
   * 分享工程 .gpkg 文件本体（当前工程先同步落盘保证最新）。
   * 路径①：系统分享面板；拉起失败退化路径②：导出副本到用户所选公共目录。
   */
  private async shareProject(row: ProjectRow): Promise<void> {
    const pm: ProjectManager = this.pm();
    if (row.fileName === pm.currentFileName()) {
      await pm.saveNow(); // 分享的是文件本体，先保证元数据落盘
    }
    if (!AppDirs.exists(row.filePath)) {
      Ui.toast('工程文件不存在');
      await this.reload();
      return;
    }
    try {
      const uri: string = fileUri.getUriFromPath(row.filePath);
      const record: systemShare.SharedRecord = { utd: UTD_DATABASE, uri: uri, title: row.baseName, label: 'FILE' };
      const data: systemShare.SharedData = new systemShare.SharedData(record);
      const controller: systemShare.ShareController = new systemShare.ShareController(data);
      const options: systemShare.ShareControllerOptions = {};
      await controller.show(this.context(), options);
    } catch (e) {
      AppLog.e('工程分享面板启动失败，退化为导出副本', e);
      await this.exportCopy(row);
    }
  }

  /** 路径②：DocumentSaveOptions 让用户选公共 Documents 位置，导出工程副本 */
  private async exportCopy(row: ProjectRow): Promise<void> {
    try {
      const options: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
      options.newFileNames = [row.fileName];
      const uris: string[] = await new picker.DocumentViewPicker(this.context()).save(options);
      if (uris.length === 0) {
        return;
      }
      fs.copyFileSync(row.filePath, uris[0]);
      Ui.toastLong('已导出工程副本到所选位置');
    } catch (e) {
      AppLog.e('导出工程副本失败', e);
      Ui.toast('导出失败');
    }
  }

  /** 删除工程：二次确认；当前工程在菜单中不出现「删除」，API 层另有拒绝防线 */
  private async deleteProject(row: ProjectRow): Promise<void> {
    const ok: boolean = await Ui.confirm('删除工程',
      '删除后该工程文件（.gpkg）不可恢复，是否继续？', '删除');
    if (!ok) {
      return;
    }
    const done: boolean = await this.pm().deleteProject(row.fileName);
    if (done) {
      Ui.toast('已删除工程');
    } else {
      Ui.toast('删除失败');
    }
    await this.reload();
  }

  /** 复制工程为新文件：命名「xx 副本」递增去重，成功后刷新列表（当前工程也会先落盘再复制） */
  private async copyProject(row: ProjectRow): Promise<void> {
    const newName: string = this.uniqueCopyName(row.baseName);
    const done: boolean = await this.pm().duplicateProject(row.fileName, newName);
    if (done) {
      Ui.toast(`已复制为「${newName}」`);
      await this.reload();
    } else {
      Ui.toast('复制失败');
    }
  }

  /** 复制命名：「xx 副本」，已存在则递增序号（同 Android uniqueCopyName） */
  private uniqueCopyName(base: string): string {
    const existing: Set<string> = new Set<string>();
    for (let i = 0; i < this.rows.length; i++) {
      existing.add(this.rows[i].fileName);
    }
    let name: string = `${base} 副本`;
    let i: number = 2;
    while (existing.has(`${name}.gpkg`)) {
      name = `${base} 副本${i}`;
      i++;
    }
    return name;
  }

  /** 备份工程文件到 backups/（带时间戳，不进工程列表）；当前工程先落盘保证备份为最新 */
  private async backupProject(row: ProjectRow): Promise<void> {
    const pm: ProjectManager = this.pm();
    const dst: string = row.current ? await pm.backupCurrentProject() : await pm.backupProjectFile(row.fileName);
    Ui.toastLong(dst.length > 0 ? `已备份：${dst}` : '备份失败');
  }

  // ── 合并（目标恒为当前工程）─────────────────────────────────────

  /** 当前工程行「合并」：列出其余工程供选择作为合并源 */
  private showMergeSourcePicker(current: ProjectRow): void {
    const candidates: ProjectRow[] = [];
    for (let i = 0; i < this.rows.length; i++) {
      if (!this.rows[i].current) {
        candidates.push(this.rows[i]);
      }
    }
    if (candidates.length === 0) {
      Ui.toast('没有其他工程可合并');
      return;
    }
    const names: string[] = [];
    for (let i = 0; i < candidates.length; i++) {
      names.push(candidates[i].baseName);
    }
    this.optionDialog = new CustomDialogController({
      builder: OptionListDialog({
        title: `选择并入「${current.baseName}」的工程`,
        hint: '选中工程的采集数据将追加到当前工程，源工程保持不变。',
        options: names,
        onPick: (index: number): void => {
          this.startMerge(candidates[index]);
        },
      }),
      customStyle: true,
      alignment: DialogAlignment.Center,
      autoCancel: true,
    });
    this.optionDialog.open();
  }

  /**
   * 合并入口：读源工程（整库读，大工程耗时）→ 弹确认框列出并入条数 → 确认后交 doMerge。
   * [source] 是作为合并源的工程行，目标恒为当前工程。
   */
  private async startMerge(source: ProjectRow): Promise<void> {
    const pm: ProjectManager = this.pm();
    if (this.merging) {
      Ui.toast('正在合并工程，请稍候');
      return;
    }
    if (source.fileName === pm.currentFileName()) {
      Ui.toast('源工程与当前工程相同，无需合并');
      return;
    }
    if (!AppDirs.exists(source.filePath)) {
      Ui.toast('源工程文件不存在');
      await this.reload();
      return;
    }
    if (pm.currentProject === null) {
      Ui.toast('当前工程不可用，无法合并');
      return;
    }
    const sourceName: string = source.baseName;
    const targetName: string = ProjectManager.baseNameNoExt(pm.currentFileName());
    this.merging = true;
    Ui.toast('正在读取源工程…');
    const src: Project | null = await pm.readProject(source.filePath);
    if (src === null) {
      this.merging = false;
      Ui.toast('源工程读取失败');
      return;
    }
    const stats: MergeResult = pm.statsOf(src);
    if (stats.isEmpty) {
      this.merging = false;
      Ui.toast(`「${sourceName}」没有可合并的数据`);
      return;
    }
    const agreed: boolean = await Ui.confirm(`合并到「${targetName}」`,
      `将「${sourceName}」的采集数据并入当前工程：\n${stats.describe()}\n\n`
        + '源工程保持不变；当前工程先自动备份到 backups/。', '合并');
    if (!agreed) {
      this.merging = false;
      return;
    }
    await this.doMerge(pm, src, source.filePath, sourceName);
  }

  /**
   * 执行合并：备份当前工程 →（备份成功才继续）并表 + 照片本体搬运 → 元数据落盘 → 刷新列表。
   * 备份失败即中止——本操作不可撤销地改写当前工程，宁可不做。
   */
  private async doMerge(pm: ProjectManager, src: Project, sourcePath: string, sourceName: string): Promise<void> {
    Ui.toast('正在合并工程…');
    const backup: string = await pm.backupCurrentProject();
    if (backup.length === 0) {
      this.merging = false;
      Ui.toastLong('备份当前工程失败，已取消合并');
      return;
    }
    const res: MergeResult | null = await pm.mergeIntoCurrent(src, sourcePath);
    this.merging = false;
    if (res === null) {
      Ui.toast('合并中止：当前工程不可用');
      return;
    }
    await pm.saveNow();
    Ui.toastLong(`已将「${sourceName}」并入：${res.describe()}　·　备份见 调查宝/backups/`);
    // 当前工程数据已变，交回主界面时重建叠加层（同打开/新建的惯例，页面本身留在原地）
    PageData.put(PageKeys.PROJECT_CHANGED, pm.currentFileName());
    await this.reload();
  }

  /** 三点按钮操作菜单（对应 Android setItems）：当前工程无「删除」，合并项按目标恒为当前工程取词 */
  private showActionMenu(row: ProjectRow): void {
    const options: string[] = row.current
      ? ['分享', '复制', '重命名', '备份', '合并']
      : ['分享', '复制', '重命名', '备份', '删除', '合并到当前工程'];
    Ui.items(row.baseName, options).then((idx: number): void => {
      if (idx < 0) {
        return;
      }
      const action: string = options[idx];
      if (action === '分享') {
        this.shareProject(row);
      } else if (action === '复制') {
        this.copyProject(row);
      } else if (action === '重命名') {
        this.showRenameDialog(row);
      } else if (action === '备份') {
        this.backupProject(row);
      } else if (action === '合并') {
        this.showMergeSourcePicker(row);
      } else if (action === '合并到当前工程') {
        this.startMerge(row);
      } else if (action === '删除') {
        this.deleteProject(row);
      }
    });
  }

  build() {
    Column() {
      TitleBar({
        title: '工程',
        subtitle: `共 ${this.rows.length} 个`,
        // 必须用箭头函数包裹：直接传方法引用，子组件回调时 this 指向 TitleBar
        actions: (): void => {
          this.barActions();
        },
      })

      if (this.rows.length === 0) {
        Column() {
          Text('暂无工程')
            .fontSize(Theme.FONT)
            .fontColor(Theme.TEXT_SUB)
          Text('点右上角「+ 新建工程」创建')
            .fontSize(Theme.FONT_SUB)
            .fontColor(Theme.TEXT_HINT)
            .margin({ top: Theme.GAP })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: Theme.GAP }) {
          ForEach(this.rows, (row: ProjectRow): void => {
            ListItem() {
              this.projectCard(row)
            }
          }, (row: ProjectRow): string => row.key())
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .padding({ left: Theme.PAD, right: Theme.PAD, top: Theme.GAP, bottom: Theme.PAD })
      }
    }
    .width('100%')
    .height('100%')
    .padding({ bottom: this.bottomInset })
    .backgroundColor(Theme.BG)
  }

  @Builder
  barActions() {
    Text('+ 新建工程')
      .fontSize(Theme.FONT)
      .fontColor(Theme.TEXT_ON_DARK)
      .height(30)
      .padding({ left: 12, right: 12 })
      .backgroundColor('#33FFFFFF')
      .borderRadius(15)
      .onClick((): void => {
        this.showCreateDialog();
      })
  }

  @Builder
  projectCard(row: ProjectRow) {
    Row({ space: 10 }) {
      Column({ space: 4 }) {
        Row({ space: 6 }) {
          Text(row.baseName)
            .fontSize(Theme.FONT)
            .fontColor(Theme.TEXT)
            .fontWeight(row.current ? FontWeight.Bold : FontWeight.Normal)
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (row.current) {
            Text('当前工程')
              .fontSize(10)
              .fontColor(Theme.TEXT_ON_DARK)
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .backgroundColor(Theme.PRIMARY)
              .borderRadius(4)
          }
        }
        .alignItems(VerticalAlign.Center)

        Text(`${row.displayDate}　·　${row.displaySize}`)
          .fontSize(Theme.FONT_SUB)
          .fontColor(Theme.TEXT_SUB)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      // 行点击 = 打开工程（Android itemView.setOnClickListener 同）
      .onClick((): void => {
        this.openProject(row);
      })

      // 右侧三点按钮：弹操作菜单（分享/复制/重命名/备份/合并，非当前工程另有删除），禁止长按交互
      Text('⋮')
        .fontSize(22)
        .fontColor(Theme.TEXT_SUB)
        .textAlign(TextAlign.Center)
        .width(36)
        .height(36)
        .onClick((): void => {
          this.showActionMenu(row);
        })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding(12)
    .backgroundColor(Theme.CARD)
    .borderRadius(Theme.RADIUS)
  }
}
