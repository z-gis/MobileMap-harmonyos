// AppSourcePage.ets —— 地图源管理页（对应 Android LayerManageDialog「地图源」页签的独立成页形态）。
//
// Android 把地图源管理藏在图层管理对话框的第三个页签里；鸿蒙侧另给一个直达入口（主界面底图切换、
// 图层管理页均可跳转至此），故把列表与动作抽成 MapSourceList 组件，两处共用同一实现。
// 本页只负责标题栏与返回：列表行为（单选切换底图 / 编辑 / 新增 / 删除自定义源）全在组件内。

import { Theme } from '../common/Theme';
import { DocumentManager } from '../doc/DocumentManager';
import { MapSourceList } from '../components/MapSourceList';
import { TitleBar } from '../components/TitleBar';

@Entry
@Component
struct AppSourcePage {
  /** 底部导航条避让高度（vp）：主窗口是全屏布局，页面内容要让开导航条 */
  @StorageProp('bottomInsetVp') bottomInset: number = 0;
  /** 生效底图名：进入时取一次，切换由 MapSourceList 内部完成，返回时再同步一次 */
  @State activeName: string = '';

  aboutToAppear(): void {
    this.activeName = DocumentManager.getInstance().activeBaseMap();
  }

  onPageShow(): void {
    this.activeName = DocumentManager.getInstance().activeBaseMap();
  }

  build() {
    Column() {
      TitleBar({
        title: '地图源',
        subtitle: this.activeName.length > 0 ? `当前底图：${this.activeName}` : '当前未选择底图',
      })
      Column() {
        MapSourceList({
          refreshToken: 0,
          onActiveChanged: (name: string): void => {
            this.activeName = name;
          },
        })
      }
      .layoutWeight(1)
      .width('100%')
      .padding({ left: Theme.PAD, right: Theme.PAD, top: Theme.GAP, bottom: Theme.PAD })
    }
    .width('100%')
    .height('100%')
    .padding({ bottom: this.bottomInset })
    .backgroundColor(Theme.BG)
  }
}
