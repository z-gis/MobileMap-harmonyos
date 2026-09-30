// EglContext / MapRenderHost —— HarmonyOS NEXT 平台的 GL 上下文宿主与渲染线程。
//
// Android 侧 GL 上下文由 Kotlin GLSurfaceView 创建并绑定，native 仅在其回调线程内执行 GLES2 指令；
// 鸿蒙无对应 Java 视图宿主，XComponent 只给出 OHNativeWindow。本文件承担 GLSurfaceView 的职责：
//   - EglContext：EGL display/config/context/window surface 的 RAII 封装（GLES 2.x 上下文）；
//   - MapRenderHost：独立渲染线程绑定 EglContext，消费「需重绘」脏标记（条件变量唤醒），
//     依次驱动 GlobeEngine 的 surfaceCreated → surfaceChanged → drawFrame → eglSwapBuffers，
//     退出时在渲染线程内 releaseGl（对齐 Android「queueEvent(releaseGl) 先于 destroy」语义）。
//
// GlobeEngine 由 ArkTS 侧经 NAPI 句柄创建/持有，本宿主仅引用不拥有；引擎其余代码不含平台 #ifdef。
#ifndef GLOBECORE_OHOS_EGLCONTEXT_H
#define GLOBECORE_OHOS_EGLCONTEXT_H

#include <condition_variable>
#include <cstdint>
#include <functional>
#include <mutex>
#include <thread>

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <native_window/external_window.h>

namespace globecore { class GlobeEngine; }

namespace gcehos {

/// EGL display + window surface + GLES2 context 的轻量封装。
/// 全部方法须在拥有该上下文的线程（MapRenderHost 渲染线程）调用，destroy() 同。
class EglContext {
public:
    EglContext() = default;
    ~EglContext() { destroy(); }

    EglContext(const EglContext &) = delete;
    EglContext &operator=(const EglContext &) = delete;

    /// eglGetDisplay/Initialize → ChooseConfig(ES2, RGBA8888+depth) → CreateContext →
    /// CreateWindowSurface → MakeCurrent。任一步失败返回 false（内部已回滚半成品对象）。
    bool initialize(OHNativeWindow *window);

    /// 销毁 surface/context 并 terminate display（调用前当前线程应仍持有上下文）。
    void destroy();

    bool makeCurrent();
    bool swapBuffers();

    /// 校对 window surface 的缓冲几何：与请求尺寸（px，容差 ±4）不符则销毁重建 surface 并重新
    /// makeCurrent，返回是否发生了重建。转屏时窗口缓冲几何常滞后于 OnSurfaceChanged，
    /// 不重建则本 surface 一直按旧几何出帧（画面被拉伸），须等下一次尺寸变化才恢复。
    /// 仅渲染线程可调（与其余 EGL 方法同口径）。
    bool syncSurfaceSize(int32_t width, int32_t height);

private:
    EGLDisplay display_ = EGL_NO_DISPLAY;
    EGLConfig config_ = nullptr;
    EGLContext context_ = EGL_NO_CONTEXT;
    EGLSurface surface_ = EGL_NO_SURFACE;
    OHNativeWindow *window_ = nullptr; // 非拥有（XComponent 提供）
};

/// 渲染线程宿主：一个 GlobeEngine 实例 ↔ 一个 OHNativeWindow 的绘制绑定，等价 Android 上
/// GLSurfaceView(RENDERMODE_WHEN_DIRTY) + Renderer 回调的组合。
///
/// 线程模型：
///   - 构造即在专属线程完成 EGL 初始化 + GlobeEngine::surfaceCreated()；
///   - requestRender()/setSurfaceSize() 任意线程可调（置脏 + 条件变量唤醒），对齐
///     Kotlin GLSurfaceView.requestRender 的线程安全语义；nativeSetRenderCallback 在鸿蒙侧
///     即「把 GlobeEngine 重绘回调接到本宿主」，无 JNI 反射；
///   - 析构置 quit 并 join：渲染线程退出循环后在 GL 线程内 releaseGl + EGL 销毁。
class MapRenderHost {
public:
    MapRenderHost(globecore::GlobeEngine *engine, OHNativeWindow *window);
    ~MapRenderHost();

    MapRenderHost(const MapRenderHost &) = delete;
    MapRenderHost &operator=(const MapRenderHost &) = delete;

    /// 置「需重绘」脏标记并唤醒渲染线程（幂等、任意线程）。
    void requestRender();

    /// XComponent surface 尺寸变化：记录视口 + 请求一帧重绘（引擎内部幂等处理重复尺寸）。
    /// 尺寸真变了 → 重启沉降补帧；同尺寸重发（布局抖动/补发）→ 仅补两帧，不重复重建 surface。
    void setSurfaceSize(int32_t width, int32_t height);

    /// 惯性滑动：以初速度（vp/s，屏幕坐标系，右/下为正）启动自驱动平移帧序列，
    /// 渲染线程逐帧按 dt 平移相机并指数衰减，低于阈值自动停止（任意线程可调，重复调覆盖）。
    void startFling(double vxVpPerSec, double vyVpPerSec);
    /// 中止惯性滑动（新一次触摸按下/双击缩放时调用，任意线程）。
    void cancelFling();

    /// 单击延时确认：触摸层在 UP 时投递候选点（vp 坐标 + 截止时刻 steady_clock ns），
    /// 渲染线程到点未被双击取消则触发 singleTap 回调（用于与双击缩放消歧）。
    /// 投递/取消都自增 selfWakeSeq_：地图静止时渲染线程停在无超时的 wait 上，
    /// 仅 notify_all 唤不醒带断言的等待（断言仍为假会立刻重新休眠），单击会被压到
    /// 下一次重绘请求才触发（表现为「点要素没反应，动一下地图才弹属性」）。
    void postPendingTap(float xVp, float yVp, int64_t deadlineNs);
    void cancelPendingTap();

    /// 单击确认后的回调（在渲染线程触发；接线方负责转投 ArkTS 主线程）。
    void setSingleTapCallback(std::function<void(float, float)> cb) {
        std::lock_guard<std::mutex> lock(mtx_);
        singleTapCb_ = std::move(cb);
    }

private:
    void renderLoop(); // 渲染线程主体（EGL 绑定 → 事件循环 → releaseGl/销毁）
    /// 渲染线程内：按帧推进惯性平移，返回是否仍需续帧（持锁调用段自行加锁）。
    bool advanceFling(int64_t nowNs);
    /// 渲染线程内：单击候选到点且未被取消则触发回调。
    void checkPendingTap(int64_t nowNs);

    globecore::GlobeEngine *engine_ = nullptr; // 非拥有
    OHNativeWindow *window_ = nullptr;   // 非拥有（XComponent 在 host 存活期间保证有效）
    EglContext egl_;

    std::thread thread_;
    std::mutex mtx_;
    std::condition_variable cv_;
    bool quit_ = false;
    bool sizeDirty_ = false; // 有新视口尺寸待应用
    bool frameDirty_ = false; // 请求一帧重绘
    int32_t width_ = 0;      // 最近一次 setSurfaceSize 的视口宽高
    int32_t height_ = 0;
    // 尺寸变更后的剩余补帧数（见 renderLoop 的沉降期注释）：mtx_ 保护，仅渲染线程消耗
    int settleFrames_ = 0;
    // 沉降期内「缓冲几何已与视口一致」的连续命中数：达到阈值即提前结束补帧，
    // 避免常态（尺寸并未真的变化/一次就跟齐）下白刷一整个窗口（仅渲染线程读写）
    int settleStable_ = 0;
    /// 沉降补帧参数：尺寸变化后按 kSettleIntervalMs 节拍补帧，最多 kSettleFrames 帧（≈1s 上限）。
    /// 转屏（或分屏拖拽）时窗口缓冲几何重配置常晚于尺寸下发，只出一帧会定格在旧几何上，
    /// 表现为「旋转后地图不跟随、平移一下才回正」；补帧期间逐帧校对 surface 缓冲几何、必要时
    /// 重建 surface，而几何已连续一致 kSettleStableExit 次即提前收工（未转屏时几帧后归零）。
    static constexpr int kSettleFrames = 30;
    static constexpr int64_t kSettleIntervalMs = 32;
    static constexpr int kSettleStableExit = 2;

    // 惯性滑动状态（mtx_ 保护）：速度单位 vp/s；lastFlingNs_ 为上一推进时刻（steady_clock ns）
    double flingVx_ = 0.0;
    double flingVy_ = 0.0;
    int64_t lastFlingNs_ = 0;

    // 单击延时确认（mtx_ 保护）：UP 投递，截止前无 DOWN 接续则确认为单击
    bool pendingTap_ = false;
    // 自驱动状态变更序号（待确认单击/惯性启停）：不作废「按旧状态选定的等待方式」——
    // 这些变更不产生脏帧，渲染线程须据此退出等待重算超时（见 renderLoop 的 wake 断言）
    uint64_t selfWakeSeq_ = 0;
    float pendingTapX_ = 0.0f;
    float pendingTapY_ = 0.0f;
    int64_t pendingTapDeadlineNs_ = 0;
    std::function<void(float, float)> singleTapCb_;
};

} // namespace gcehos

#endif // GLOBECORE_OHOS_EGLCONTEXT_H
