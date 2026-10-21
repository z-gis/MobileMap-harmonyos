import backgroundTaskManager from '@ohos.resourceschedule.backgroundTaskManager';
import { wantAgent, WantAgent, common } from '@kit.AbilityKit';
import { AppLog } from '../common/AppLog';
import { DocumentManager } from '../doc/DocumentManager';

/**
 * 后台定位保活的统一门控（对齐 Android location/BackgroundLocationController）。
 *
 * 语义：「后台定位」开关只是记录期许可——长时任务（continuousTask，backgroundModes=location）
 * 仅在「轨迹记录中 且 开关为开」时申请；轨迹停止（或开关关闭）即刻释放，不做记录之外的后台定位。
 * 鸿蒙端以 @kit.BackgroundTasksKit 的 continuousTaskManager 实现保活：长时任务期间息屏 / 退后台
 * 仍能持续定位订阅（LocationManager 单例由界面侧持有，本控制器不重复注册定位）。
 * 全部接口幂等；申请 / 释放失败仅记日志，不影响记录主流程。
 */
export class BackgroundLocationController {
  /** 轨迹记录态（含暂停——暂停属于记录会话中，保持保活） */
  private static trackRecording: boolean = false;
  /** 长时任务运行态缓存（幂等判重） */
  private static running: boolean = false;
  /** 复用的 wantAgent（点击常驻提醒回主界面） */
  private static cachedAgent: WantAgent | undefined = undefined;

  /** 轨迹记录态变化：开始/恢复记录传 true，停止记录传 false；按「记录态 && 开关」启停 */
  static onTrackRecordingChanged(context: common.UIAbilityContext, recording: boolean): void {
    BackgroundLocationController.trackRecording = recording;
    BackgroundLocationController.syncTask(context);
  }

  /** 「后台定位」开关值变化（配置须先落盘再调用）：按「记录态 && 开关」启停 */
  static onSettingChanged(context: common.UIAbilityContext): void {
    BackgroundLocationController.syncTask(context);
  }

  /** 门控合一处：记录中且开关为开 → 申请长时任务（幂等）；任一不满足 → 释放 */
  private static syncTask(context: common.UIAbilityContext): void {
    const enabled: boolean = BackgroundLocationController.trackRecording &&
      DocumentManager.getInstance().getConfig().backgroundLocation;
    if (enabled) {
      BackgroundLocationController.start(context);
    } else {
      BackgroundLocationController.stop(context);
    }
  }

  private static start(context: common.UIAbilityContext): void {
    if (BackgroundLocationController.running) {
      return;
    }
    BackgroundLocationController.running = true;
    BackgroundLocationController.ensureAgent(context).then((agent: WantAgent) => {
      return backgroundTaskManager.startBackgroundRunning(context, ['location'], agent);
    }).then(() => {
      AppLog.i('后台定位长时任务已启动');
    }).catch((err: Error) => {
      BackgroundLocationController.running = false;
      AppLog.w(`后台定位长时任务启动失败：${err.message}`);
    });
  }

  private static stop(context: common.UIAbilityContext): void {
    if (!BackgroundLocationController.running) {
      return;
    }
    BackgroundLocationController.running = false;
    backgroundTaskManager.stopBackgroundRunning(context).then(() => {
      AppLog.i('后台定位长时任务已停止');
    }).catch((err: Error) => {
      AppLog.w(`后台定位长时任务停止失败：${err.message}`);
    });
  }

  private static ensureAgent(context: common.UIAbilityContext): Promise<WantAgent> {
    const cached: WantAgent | undefined = BackgroundLocationController.cachedAgent;
    if (cached !== undefined) {
      return Promise.resolve(cached);
    }
    const info: wantAgent.WantAgentInfo = {
      wants: [{
        bundleName: context.abilityInfo.bundleName,
        abilityName: context.abilityInfo.name
      }],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0
    };
    return wantAgent.getWantAgent(info).then((agent: WantAgent): WantAgent => {
      BackgroundLocationController.cachedAgent = agent;
      return agent;
    });
  }
}
