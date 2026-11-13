# MobileMap-harmonyos（调查宝 · HarmonyOS 版）

调查宝（MobileMap 0.4.2.0）的 **HarmonyOS NEXT** 移植工程：面向野外调查/测绘场景的离线地图与矢量数据应用，集成自研地图渲染内核，以 ohpm 公开发布包 [`@zys/globecore`](https://ohpm.openharmony.cn/ohpm/@zys/globecore) 形式消费（ArkTS 门面 + NAPI + 共享 C++ 引擎，静态链接 GDAL/PROJ/libcurl 等，预打包 `libglobecore.so`）。

- **包名**：`com.zys.MobileMap`
- **应用名**：调查宝
- **版本**：`0.4.2.0`（versionCode `26111202`，与 Android MobileMap 对齐，同一份 `update.json` 可跨端比较）
- **runtimeOS**：HarmonyOS ｜ targetSdk `26.0.0` ｜ compatibleSdk `5.0.0(12)`

## 0.4.2.0 版本要点

渲染内核 `@zys/globecore` 0.1.4 → **0.1.5**（版本单一真源 + `NativeVersion`、GeoPackage 按几何类型分表与 `remark` 列、`SPATIAL_INDEX=YES` 与存量库自愈补建 rtree、点层零面积四至退回 NULL、鸿蒙长按桥接）。与 Android 端同口径落地的功能：

- **兴趣点（长按落点建点 + 相册选图）**：`Index.ets` 注册 `setOnLongPressListener` → `FeaturePickController.onMapLongPress`（空白与命中要素双语义，命中一支留给要素编辑）→ 圆菜单 → `MediaCaptureHelper.addPhotosFromAlbum` / `startSessionAt(lat, lon)`；长按后抬指补发的单击由「时间窗 + 落点距离」双条件抑制。详见 [../doc/兴趣点_长按落点方案_20261112.md](../doc/兴趣点_长按落点方案_20261112.md)。
- **图层分组**：`MapDocument.groups` + `LayerInfo.groupId`，`LayerManagePage` 分节 + 组头折叠/可见性扇出（[../doc/图层分组_改造方案_20261111.md](../doc/图层分组_改造方案_20261111.md)）。
- **备注**：`PhotoRecord` / `MeasureRecord` 加 `remark`，`RemarkEditDialog` 多行输入（[../doc/照片测量备注与标识弹窗_改造方案_20261111.md](../doc/照片测量备注与标识弹窗_改造方案_20261111.md)）。
- **圆菜单命中修复**：遮罩从根 `Stack` 拆成独立全屏兄弟节点（`HitTestMode.Block` 会屏蔽子节点，槽位收不到点击），见上注方案文档 §7.4。
- **仅本端有的改动**：shp 导入改「目录授权 + 应用内列主文件 + 同名冲突重新导入/重命名导入」（`AddLayerPage`），Android 端未跟进同一改造。
- **entry_pc（桌面形态）本版补的两个命令**：工具栏「转到 XY」弹经纬度面板搬到指定点（级别与姿态不动，可「返回上一视图」撤销）；TOC 右键「刷新」按当前符号与标注字段重挂同一数据源并回读要素数/四至（外部改过 shp/gpkg 不必重启；栅格与在线底图无重挂接口，只提示）。顺带把标注字段记进 `LayerRow.labelField`，属性面板打开时回显、换层/刷新不再丢标注。**产物已验**：`mobilemap-pc-v0.4.2.0-debug.hap` 内 `ets/modules.abc` 含「转到 XY」「已刷新」「labelField」字符串。
- **仍为占位的遗留**：工程新建/打开/保存与「选项…」需要业务层先下沉 HSP；桌面形态的长按落点语义（兴趣点）另批。

## 架构与模块

本仓库为多模块工程（hvigor 构建）：

| 模块 | 类型 | 说明 |
|------|------|------|
| `entry` | 应用入口（HAP/entry） | 调查宝界面与业务：地图主页、图层/矢量管理、轨迹、照片、要素详情、调查表、属性/SQL 查询、量算、定位、设置、关于等 |
| `@zys/globecore` | ohpm 依赖（预编译 HAR） | 地图渲染内核：ArkTS 门面 + NAPI 桥 + 预编译 `libglobecore.so`（arm64-v8a / x86_64），由 GlobeCore 引擎仓打包发布 |
| `AppScope` | — | 应用级配置与资源（包名、版本、图标、应用名） |

地图渲染内核已发布为 ohpm 包 **`@zys/globecore`**，本工程以**预编译 HAR** 方式消费（`entry` 依赖 `"@zys/globecore": "0.1.5"`，import 路径统一为 `'@zys/globecore'`），构建时直接使用其中打包好的 ArkTS 门面与 `libglobecore.so`，不再从本仓源码编译原生引擎。

> 当前 `entry/oh-package.json5` 里按版本引用的一行处于注释状态、启用的是指向 GlobeCore 仓本地产物的 `file:` 一行——ohpm 仓实际发布到 `0.1.4`，`0.1.5` 待发版；发版后把两行对调即可。

### 功能页面（entry）
`Index`（地图主界面）、`LayerManagePage`、`AddLayerPage`、`SettingsPage`、`AboutPage`、`HelpPage`、`TrackPage`、`PhotoPage`、`PhotoViewerPage`、`FeatureDetailPage`、`SurveyListPage`、`SurveyEditPage`、`AppSourcePage`。

## 引擎与三方依赖（重要）

地图渲染内核以 ohpm 发布包 **`@zys/globecore`** 消费，本工程**不编译 C++ 引擎**——引擎与三方静态库都在发布侧（**GlobeCore 引擎仓**，原 WorldWindNative）预先编好并打进 har 的 `libglobecore.so`：

- 命名口径：引擎类 `GlobeEngine`、引擎命名空间 `globecore`、数据 IO 桥命名空间 `gcbridge`（原 `wwbridge`）。
- har 的产出与发布在 GlobeCore 仓完成：先由 `build-scripts/build-all.sh --target ohos` 产出三方 `.a` 到 `build-scripts/out/ohos/<abi>/`，再打包发布 `@zys/globecore` 到 ohpm。
- 升级渲染内核只需修改 `entry/oh-package.json5` 里 `@zys/globecore` 的版本号并重新 `ohpm install`，无需在本仓放置 GlobeCore 检出。

> 相关仓库布局（仅发布 har 时需要，本仓构建不依赖）：
> ```
> MobileMap/
> ├── GlobeCore/            # 引擎源码 + 三方库产物 + har 发布
> ├── MobileMap-android/
> └── MobileMap-harmonyos/  # 本工程（消费 har）
> ```

## 技术栈

- **UI/业务**：ArkTS（HarmonyOS NEXT Stage 模型）、DevEco Studio 26.0.0.851、hvigor
- **原生**：NAPI 桥接、OH_NativeXComponent（SURFACE）、EGL + OpenGL ES 3.0 渲染宿主
- **引擎/数据**：C++17 自研渲染引擎；GDAL/OGR 矢量读写、PROJ 坐标转换、libcurl 取瓦片、KML、libsqlite

## 构建

### DevEco Studio（推荐）
1. 用 DevEco Studio 打开本工程根目录；
2. 首次执行 **File → Sync and Refresh Project**（生成本地 `oh_modules` 与依赖映射）；
3. Sync 时 ohpm 会自动从 registry 拉取 `@zys/globecore`（无需本地 GlobeCore 检出）；
4. Build → Build Hap(s)，或运行到设备/模拟器。

### 命令行
```powershell
# 需设置 SDK 与 JDK 环境变量（示例见 _build.ps1）
$env:DEVECO_SDK_HOME = '<DevEco>/sdk'
$env:JAVA_HOME      = '<DevEco>/jbr'
& '<DevEco>/tools/node/node.exe' '<DevEco>/tools/hvigor/bin/hvigorw.js' `
  assembleHap --mode module -p product=default -p buildMode=debug --no-daemon
```
产物：`entry/build/default/outputs/default/entry-default-unsigned.hap`（未签名；签名配置在根 `build-profile.json5` 的 `signingConfigs` 中补充）。

## 目录结构

```
MobileMap-harmonyos/
├── AppScope/                 # 应用级配置与资源
├── entry/                    # 应用入口模块（HAP）
│   └── src/main/ets/         # 页面 pages/、组件 components/、业务 map|survey|vector|media|location|update|doc 等
├── hvigor/                   # 构建配置
└── build-profile.json5       # 工程级：products / signingConfigs / modules
```


