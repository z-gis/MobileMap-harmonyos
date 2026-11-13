// PcAbility.ets —— 桌面端（2in1）入口 Ability。
//
// 与手机端 EntryAbility 的初始化链同构，但只留 PC 用得到的三步：
//   1) DeskDirs.init：建本模块沙箱目录树（瓦片缓存/导入数据/配置）；
//   2) NativeSrs.initProjData：解压 HAR 内置 proj 数据（坐标换算前置）；
//   3) NativeNet.initCaBundle：注入 CA 包（联网取瓦片走 native https）。
// 不做手机端的全屏沉浸（PC 窗口由系统装饰管理），也不申请定位/相机、不启后台长时任务。
// 工程文档（DocumentManager）与业务控制器目前在 entry 模块内，HAP 之间不能互相引用，
// 待下沉 HSP 后在此接入——框架期工作台自带一份演示用的图层清单。
import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { NativeNet, NativeSrs } from '@zys/globecore';
import { DeskDirs } from '../common/DeskDirs';
import { DeskLog } from '../common/DeskLog';

const TAG: string = 'PcAbility';

export default class PcAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    const t0: number = Date.now();
    DeskDirs.init(this.context.filesDir);
    NativeSrs.initProjData(this.context);
    NativeNet.initCaBundle(this.context);
    DeskLog.i(`${TAG} onCreate 初始化完成 ${Date.now() - t0}ms`);
  }

  onDestroy(): void {
    DeskLog.i(`${TAG} onDestroy`);
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Workbench', (err): void => {
      if (err.code) {
        DeskLog.e(`${TAG} 工作台加载失败 ${err.code} ${err.message}`);
        return;
      }
      DeskLog.i(`${TAG} 工作台已加载`);
    });
  }

  onWindowStageDestroy(): void {
    DeskLog.i(`${TAG} onWindowStageDestroy`);
  }

  onForeground(): void {
  }

  onBackground(): void {
  }
}
