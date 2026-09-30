// HelpPage.ets —— 使用说明页（对应 Android ui.activity.HelpActivity + activity_help.xml）。
//
// 与 Android 完全一致的三段可折叠说明（软件界面 / 添加本地图层 / 添加自定义地图源）：
// 标题常驻、正文默认折叠、点标题展开。文案取自 Android strings.xml 的 help_section_*_body 原文，
// 其中「/调查宝/layer/」在鸿蒙对应应用沙箱 files/调查宝/layer（由文件选择器导入，见 AddLayerPage）。

import { Theme } from '../common/Theme';
import { TitleBar } from '../components/TitleBar';

/** 一段说明的视图模型 */
class HelpSection {
  title: string;
  body: string;

  constructor(title: string, body: string) {
    this.title = title;
    this.body = body;
  }
}

const SECTION_UI: string =
  '主界面：全屏地图，四周分布功能按键。\n'
    + '右侧（从上到下）：注记图层开关、放大/缩小（中间显示当前级别）、图层管理。\n'
    + '左侧（从上到下）：北朝向按键、测量、设置、定位锁定、轨迹。\n'
    + '左下角：坐标文本（点击弹出"移动到"）。\n'
    + '右下角：拍照按键。\n'
    + '地图中心：十字准星（可在设置中关闭）。\n\n'
    + '图层管理界面：分矢量图层、栅格图层、地图源三个标签页。每行左侧样式图标（矢量）可打开整层样式，'
    + '图层名可缩放到范围，右侧按键依次为 SQL 查询（仅 shp）、级别可见性、缩放到范围、可见性开关、'
    + '图层信息、移除图层。';

const SECTION_LAYER: string =
  '支持格式：\n'
    + '・矢量：shp、kml、kmz、zip（shp 压缩包）、dwg、dxf\n'
    + '・栅格：tif、tiff、img\n\n'
    + '添加步骤：\n'
    + '1. 将数据文件拷贝到手机（或直接在应用内用"导入"选择本地文件）。\n'
    + '2. 主界面右侧点击"图层管理"按键。\n'
    + '3. 切到"矢量图层"或"栅格图层"标签页，点击"导入"按键。\n'
    + '4. 在文件选择面板中定位到目标文件并选中，导入后自动缩放到图层范围。\n\n'
    + '提示：shp 需同时存在 .shp/.shx/.dbf（建议包含 .prj 声明坐标系），dwg 仅支持 2018 及以下版本。';

const SECTION_SOURCE: string =
  '适用于接入自定义 WMTS/XYZ 瓦片服务。\n\n'
    + '添加步骤：\n'
    + '1. 主界面右侧点击"图层管理"按键，切到"地图源"标签页。\n'
    + '2. 点击"导入"按键弹出地图源编辑对话框。\n'
    + '3. 填写字段：\n'
    + '・名称：自定义名称，作为图层标识。\n'
    + '・网址：瓦片服务地址，包含占位符 {z}/{x}/{y}'
    + '（例：https://host/tile/{z}/{x}/{y}.png）。\n'
    + '・类型：默认 WMTS，目前支持 XYZ/WMTS 瓦片方案。\n'
    + '・Token1/Token2：选填，网址中包含 {token1}/{token2} 占位符时自动替换'
    + '（天地图系列共用 Token，任一地图源中配置后自动同步）。\n'
    + '4. 保存后在地图源列表中选中单选按钮，底图立即切换。\n'
    + '5. 左侧设置按键可重新编辑名称/网址/Token。';

/** 三段说明（顺序与 Android 布局一致） */
const SECTIONS: HelpSection[] = [
  new HelpSection('软件界面说明', SECTION_UI),
  new HelpSection('如何添加本地图层', SECTION_LAYER),
  new HelpSection('如何添加自定义地图源', SECTION_SOURCE),
];

@Entry
@Component
struct HelpPage {
  /** 底部导航条避让高度（vp）：主窗口是全屏布局，页面内容要让开导航条 */
  @StorageProp('bottomInsetVp') bottomInset: number = 0;
  /** 各段展开态：默认全折叠（与 Android 一致） */
  @State expanded: boolean[] = [false, false, false];

  private toggle(index: number): void {
    const next: boolean[] = [];
    for (let i = 0; i < this.expanded.length; i++) {
      next.push(i === index ? !this.expanded[i] : this.expanded[i]);
    }
    this.expanded = next;
  }

  build() {
    Column() {
      TitleBar({ title: '帮助' })
      Scroll() {
        Column({ space: Theme.GAP }) {
          ForEach(SECTIONS, (section: HelpSection, index: number): void => {
            Column() {
              Row() {
                Text(section.title)
                  .fontSize(Theme.FONT)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(Theme.TEXT)
                  .layoutWeight(1)
                Text(this.expanded[index] ? '▾' : '▸')
                  .fontSize(Theme.FONT)
                  .fontColor(Theme.TEXT_SUB)
              }
              .width('100%')
              .onClick((): void => {
                this.toggle(index);
              })

              if (this.expanded[index]) {
                Text(section.body)
                  .fontSize(Theme.FONT_SUB)
                  .fontColor(Theme.TEXT_SUB)
                  .width('100%')
                  .margin({ top: 8 })
              }
            }
            .width('100%')
            .padding(12)
            .alignItems(HorizontalAlign.Start)
            .backgroundColor(Theme.CARD)
            .borderRadius(Theme.RADIUS)
          }, (section: HelpSection): string => section.title)
        }
        .width('100%')
        .padding({ left: Theme.PAD, right: Theme.PAD, top: Theme.GAP, bottom: Theme.PAD })
      }
      .layoutWeight(1)
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .padding({ bottom: this.bottomInset })
    .backgroundColor(Theme.BG)
  }
}
