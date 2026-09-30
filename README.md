# MobileMap-harmonyos（调查宝 · HarmonyOS 版）

调查宝（MobileMap 0.3.0.1）的 **HarmonyOS NEXT** 移植工程：面向野外调查/测绘场景的离线地图与矢量数据应用，集成自研地图渲染内核，以 ohpm 公开发布包 [`@zys/globecore`](https://ohpm.openharmony.cn/ohpm/@zys/globecore) 形式消费（ArkTS 门面 + NAPI + 共享 C++ 引擎，静态链接 GDAL/PROJ/libcurl 等，预打包 `libglobecore.so`）。

- **包名**：`com.zys.MobileMap`
- **应用名**：调查宝
- **版本**：`0.3.0.1`（versionCode `26092701`，与 Android MobileMap27 对齐，同一份 `update.json` 可跨端比较）
- **runtimeOS**：HarmonyOS ｜ targetSdk `26.0.0` ｜ compatibleSdk `5.0.0(12)`

## 架构与模块

本仓库为多模块工程（hvigor 构建）：

| 模块 | 类型 | 说明 |
|------|------|------|
| `entry` | 应用入口（HAP/entry） | 调查宝界面与业务：地图主页、图层/矢量管理、轨迹、照片、要素详情、调查表、属性/SQL 查询、量算、定位、设置、关于等 |
| `@zys/globecore` | ohpm 依赖（预编译 HAR） | 地图渲染内核：ArkTS 门面 + NAPI 桥 + 预编译 `libglobecore.so`（arm64-v8a / x86_64），由 GlobeCore 引擎仓打包发布 |
| `AppScope` | — | 应用级配置与资源（包名、版本、图标、应用名） |

地图渲染内核已发布为 ohpm 包 **`@zys/globecore`**，本工程以**预编译 HAR** 方式消费（`entry` 依赖 `"@zys/globecore": "0.1.1"`，import 路径统一为 `'@zys/globecore'`），构建时直接使用其中打包好的 ArkTS 门面与 `libglobecore.so`，不再从本仓源码编译原生引擎。

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


