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
import { SystemInsets } from '../common/SystemInsets';
import { DocumentManager } from '../doc/DocumentManager';

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
    AppLog.i(`${TAG} onCreate 初始化完成 ${Date.now() - t0}ms`);
  }

  onDestroy(): void {
    AppLog.i(`${TAG} onDestroy`);
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
  }
}
