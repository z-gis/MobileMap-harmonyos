// EntryAbility.ets —— 应用入口（对应 Android 的 Application + MainActivity 启动初始化段）。
//
// 启动链与 Android MainActivity.initializeAndSetup() 逐项等价，且顺序不可调换：
//   1) AppDirs.init：建全目录树（调查宝/{layer,map,Media,sample,config,tiles,log}）并把日志落到 调查宝/log，
//      后续任何模块取路径前必须完成，故排第一位；
//   2) NativeSrs.initProjData：解压 rawfile 内的 proj.db 与格网改正数并把路径交给 native
//      （坐标换算的前置条件，内核在首次触达 NativeSrs/NativeNet 时才会加载 so）；
//   3) NativeNet.initCaBundle：注入 CA 证书包，联网取瓦片/检查更新走的是 native 请求，缺它则 https 全失败；
//   4) DocumentManager.loadOrCreate：读 config/document.json，无则建默认工程（含内置图源）。
// 地图视图与各业务控制器的装配在主地图页（pages/Index）的 onReady 中完成——内核视图是 ArkTS 组件，
// 只能在页面树里创建，Ability 侧仅负责上述「进程级一次性」初始化。
import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { NativeNet, NativeSrs } from '@zys/globecore';
import { AppDirs } from '../common/AppDirs';
import { AppLog } from '../common/AppLog';
import { PageData, PageKeys, PageSignals } from '../common/PageData';
import { SystemInsets } from '../common/SystemInsets';
import { DocumentManager } from '../doc/DocumentManager';
import { ProjectManager } from '../project/ProjectManager';

const TAG: string = 'EntryAbility';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    const t0: number = Date.now();
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (e) {
      AppLog.e('设置颜色模式失败', e);
    }
    // 1) 目录树 + 日志目录
    AppDirs.init(this.context.filesDir);
    // 2) PROJ 投影数据（坐标换算前置）
    NativeSrs.initProjData(this.context);
    // 3) CA 证书包（native https 请求前置）
    NativeNet.initCaBundle(this.context);
    // 4) 地图工程文档
    DocumentManager.getInstance().loadOrCreate(this.context);
    // 5) 工程模块预热：后台启动恢复/创建+旧库迁移；主地图页装配前会 await 同一 Promise
    //    （Android 在 initializeAndSetup 后台线程做 ensureLoaded 后再 setupMapUi，此处等价提前起跑）
    ProjectManager.get(this.context).ensureLoaded().then((): void => {
      AppLog.i(`${TAG} 工程装载完成`);
    }, (e: Error): void => {
      AppLog.e('工程装载失败', `${e}`);
    });
    AppLog.i(`${TAG} onCreate 初始化完成 ${Date.now() - t0}ms`);
    // 6) 外部打开（文件管理「打开方式」等经 viewData 拉起）：URI 先入交接槽，
    //    由主地图页装配完成后消费（此时才有图层控制器与文档，冷启动时序不可提前）
    this.offerExternalWant(want);
  }

  /** 已在运行中再次被外部打开（launchType=singleton，对齐 Android singleTask） */
  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    AppLog.i(`${TAG} onNewWant`);
    this.offerExternalWant(want);
  }

  /** 取外部打开的文件 URI 入槽并通知主地图页；桌面图标启动不带 uri，静默跳过 */
  private offerExternalWant(want: Want): void {
    // 各入口（文件管理/文件预览/微信）传的 action 口径不一，故不按 action 过滤，只认 uri；
    // 原始 want 全量落日志便于对账（parameters 里可能另有 ability.params.stream 授权清单）
    AppLog.i(`${TAG} want action=${want.action ?? ''} type=${want.type ?? ''} uri=${want.uri ?? ''}`
      + ` flags=${want.flags ?? 0} params=${JSON.stringify(want.parameters ?? {})}`);
    const uri: string | undefined = want.uri;
    if (uri === undefined || uri.length === 0) {
      return;
    }
    PageData.put(PageKeys.EXTERNAL_OPEN_URI, uri);
    // 主地图页已装配（热启动）时立即消费；未装配时 fire 无人绑定，槽位留待 setupMap 收尾取用
    PageSignals.fire(PageKeys.EXTERNAL_OPEN_URI);
  }

  onDestroy(): void {
    AppLog.i(`${TAG} onDestroy`);
    // 落盘前的缓冲日志（D/I 攒批）随生命周期收尾刷出，减小进程回收丢失窗口
    AppLog.flush();
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // 先建键再加载页面：保证 Index 的 @StorageProp 首次绑定时键已存在（避免首帧底部 HUD 位置抖动）
    SystemInsets.init();
    windowStage.loadContent('pages/Index', (err): void => {
      if (err.code) {
        AppLog.e(`${TAG} 主页面加载失败`, `${err.code} ${err.message}`);
        return;
      }
      AppLog.i(`${TAG} 主页面已加载`);
    });
    // 全屏沉浸：地图 HUD 覆盖到状态栏与导航条区域（等价 Android UiUtil.enableFullscreen）。
    // 代价是内容区不再自动让开系统栏，故全屏生效后立即把顶（状态栏）/底（导航条）避让高度写入 AppStorage：
    // 主地图 HUD 与各二级页 TitleBar 读 topInsetVp，底部按钮与页面内容读 bottomInsetVp。
    windowStage.getMainWindow().then((win: window.Window): void => {
      win.setWindowLayoutFullScreen(true).then((): void => {
        SystemInsets.bind(win);
      }).catch((e: Error): void => {
        AppLog.w('开启全屏失败', `${e}`);
        SystemInsets.bind(win);
      });
    }, (e: Error): void => {
      AppLog.w('获取主窗口失败', `${e}`);
    });
  }

  onWindowStageDestroy(): void {
    AppLog.i(`${TAG} onWindowStageDestroy`);
  }

  onForeground(): void {
    // 定位/相机轮询的恢复在主地图页 onPageShow 内处理，此处不重复
  }

  onBackground(): void {
    // 后台定位由 systemConfig.backgroundLocation 决定（LocationManager 按间隔持续订阅，无需在此干预）
    // 退后台时把攒批的文件日志刷出（外业现场杀进程/回收后日志仍可取回）
    AppLog.flush();
  }
}
