// SystemInsets.ets —— 系统避让区（状态栏 / 底部导航条）尺寸读取，对应 Android WindowInsets 处理。
//
// 主窗口开启了 setWindowLayoutFullScreen（地图要铺到栏下，与 Android UiUtil.enableFullscreen 一致），
// 因此内容区不再自动让开系统栏：
// · 底部：主地图的竖排按钮、测量工具条、坐标状态栏要按导航条高度上移，否则被指示条/三键栏压住；
// · 顶部：各二级页的 TitleBar 要下移状态栏高度，否则标题与右侧动作（导入等）与状态栏重叠、点不到。
// 这里把两个避让高度（vp）写入 AppStorage 供页面/组件 @StorageProp 订阅，
// 并监听 avoidAreaChange（全面屏手势/三键切换、状态栏隐藏、横竖屏变化时高度会变）。
import { window } from '@kit.ArkUI';
import { display } from '@kit.ArkUI';
import { AppLog } from './AppLog';

/** AppStorage 键：底部导航条避让高度（vp） */
const BOTTOM_KEY: string = 'bottomInsetVp';
/** AppStorage 键：顶部状态栏避让高度（vp） */
const TOP_KEY: string = 'topInsetVp';

export class SystemInsets {
  /** 底部避让高度在 AppStorage 中的键名（页面用 @StorageProp('bottomInsetVp') 读取） */
  static readonly BOTTOM_KEY: string = BOTTOM_KEY;
  /** 顶部避让高度在 AppStorage 中的键名（TitleBar 用 @StorageProp('topInsetVp') 读取） */
  static readonly TOP_KEY: string = TOP_KEY;

  /** 先置 0 建键，避免页面在窗口就绪前读不到键 */
  static init(): void {
    AppStorage.setOrCreate(BOTTOM_KEY, 0);
    AppStorage.setOrCreate(TOP_KEY, 0);
  }

  /** 绑定主窗口：读一次并持续监听变化（窗口销毁前无需显式 off，跟随窗口生命周期） */
  static bind(win: window.Window): void {
    SystemInsets.read(win);
    try {
      win.on('avoidAreaChange', (): void => {
        SystemInsets.read(win);
      });
    } catch (e) {
      AppLog.e('监听避让区变化失败', e as Object);
    }
  }

  private static read(win: window.Window): void {
    let density: number = 0;
    try {
      density = display.getDefaultDisplaySync().densityPixels;
    } catch (e) {
      AppLog.w('取屏幕密度失败，避让高度按 0 处理', `${e}`);
    }
    if (density <= 0) {
      AppStorage.setOrCreate(BOTTOM_KEY, 0);
      AppStorage.setOrCreate(TOP_KEY, 0);
      return;
    }
    // 底部：导航条（手势指示条与三键栏均计入此区）
    try {
      const nav: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      AppStorage.setOrCreate(BOTTOM_KEY, nav.bottomRect.height / density);
    } catch (e) {
      AppLog.w('取底部导航条避让高度失败，按 0 处理', `${e}`);
      AppStorage.setOrCreate(BOTTOM_KEY, 0);
    }
    // 顶部：状态栏——TYPE_SYSTEM 的 topRect 即状态栏区域
    try {
      const sys: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      AppStorage.setOrCreate(TOP_KEY, sys.topRect.height / density);
    } catch (e) {
      AppLog.w('取顶部状态栏避让高度失败，按 0 处理', `${e}`);
      AppStorage.setOrCreate(TOP_KEY, 0);
    }
  }
}
