// EglContext / MapRenderHost 实现。见 EglContext.h 顶部职责说明。
#include "EglContext.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <utility>

#include <native_buffer/native_buffer.h> // NATIVEBUFFER_PIXEL_FMT_RGBA_8888

#include "core/GlobeEngine.h"
#include "util/Log.h"

namespace gcehos {

// ────────────────────────────── EglContext ──────────────────────────────

bool EglContext::initialize(OHNativeWindow *window) {
    if (window == nullptr) return false;

    display_ = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (display_ == EGL_NO_DISPLAY) {
        LOGE("eglGetDisplay failed: 0x%x", eglGetError());
        return false;
    }
    EGLint major = 0;
    EGLint minor = 0;
    if (eglInitialize(display_, &major, &minor) == EGL_FALSE) {
        LOGE("eglInitialize failed: 0x%x", eglGetError());
        display_ = EGL_NO_DISPLAY;
        return false;
    }
    LOGI("EGL initialized: %d.%d", major, minor);

    // 引擎 render/ 层为 GLES2 指令集，申请 ES2 可渲染配置（ES3.2 驱动向下兼容）
    const EGLint configAttribs[] = {
        EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
        EGL_RED_SIZE, 8,
        EGL_GREEN_SIZE, 8,
        EGL_BLUE_SIZE, 8,
        EGL_ALPHA_SIZE, 8,
        EGL_DEPTH_SIZE, 16,
        EGL_NONE
    };
    EGLint numConfig = 0;
    if (eglChooseConfig(display_, configAttribs, &config_, 1, &numConfig) == EGL_FALSE || numConfig < 1) {
        LOGE("eglChooseConfig failed: 0x%x (num=%d)", eglGetError(), numConfig);
        destroy();
        return false;
    }

    // XComponent 缓冲默认格式对齐 RGBA8888，避免与 EGL config 通道不匹配导致黑屏/偏色
    OH_NativeWindow_NativeWindowHandleOpt(window, SET_FORMAT, NATIVEBUFFER_PIXEL_FMT_RGBA_8888);

    const EGLint contextAttribs[] = { EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE };
    context_ = eglCreateContext(display_, config_, EGL_NO_CONTEXT, contextAttribs);
    if (context_ == EGL_NO_CONTEXT) {
        LOGE("eglCreateContext failed: 0x%x", eglGetError());
        destroy();
        return false;
    }

    surface_ = eglCreateWindowSurface(display_, config_,
                                      reinterpret_cast<EGLNativeWindowType>(window), nullptr);
    if (surface_ == EGL_NO_SURFACE) {
        LOGE("eglCreateWindowSurface failed: 0x%x", eglGetError());
        destroy();
        return false;
    }

    if (!makeCurrent()) {
        destroy();
        return false;
    }
    window_ = window;
    return true;
}

void EglContext::destroy() {
    if (display_ != EGL_NO_DISPLAY) {
        eglMakeCurrent(display_, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        if (surface_ != EGL_NO_SURFACE) {
            eglDestroySurface(display_, surface_);
            surface_ = EGL_NO_SURFACE;
        }
        if (context_ != EGL_NO_CONTEXT) {
            eglDestroyContext(display_, context_);
            context_ = EGL_NO_CONTEXT;
        }
        eglTerminate(display_);
        display_ = EGL_NO_DISPLAY;
    }
    config_ = nullptr;
    window_ = nullptr;
}

bool EglContext::makeCurrent() {
    if (display_ == EGL_NO_DISPLAY || surface_ == EGL_NO_SURFACE || context_ == EGL_NO_CONTEXT) {
        return false;
    }
    return eglMakeCurrent(display_, surface_, surface_, context_) != EGL_FALSE;
}

bool EglContext::swapBuffers() {
    if (display_ == EGL_NO_DISPLAY || surface_ == EGL_NO_SURFACE) return false;
    return eglSwapBuffers(display_, surface_) != EGL_FALSE;
}

bool EglContext::syncSurfaceSize(int32_t width, int32_t height) {
    if (display_ == EGL_NO_DISPLAY || surface_ == EGL_NO_SURFACE || context_ == EGL_NO_CONTEXT
        || window_ == nullptr || width <= 0 || height <= 0) {
        return false;
    }
    EGLint sw = 0;
    EGLint sh = 0;
    eglQuerySurface(display_, surface_, EGL_WIDTH, &sw);
    eglQuerySurface(display_, surface_, EGL_HEIGHT, &sh);
    // 容差 ±4px：ArkTS 侧兜底按 vp×密度 换算整尺寸，取整误差不足以说明几何真变了
    if (std::abs(sw - width) <= 4 && std::abs(sh - height) <= 4) return false;
    // 窗口缓冲几何仍停在旧尺寸：先开新 surface（同 display/config/window）再销毁旧的，
    // 失败时至少还持有一个可用 surface（上下文不变，GL 资源与 viewport 状态均保留）
    eglMakeCurrent(display_, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    const EGLSurface old = surface_;
    surface_ = eglCreateWindowSurface(display_, config_,
                                      reinterpret_cast<EGLNativeWindowType>(window_), nullptr);
    if (surface_ == EGL_NO_SURFACE) {
        LOGE("eglCreateWindowSurface(recreate) failed: 0x%x", eglGetError());
        surface_ = old;
        makeCurrent(); // 回到旧 surface 继续出帧（至少不失画面）
        return false;
    }
    eglDestroySurface(display_, old);
    if (!makeCurrent()) {
        LOGE("makeCurrent after surface recreate failed: 0x%x", eglGetError());
        return false;
    }
    LOGI("EGL surface recreated: %dx%d -> %dx%d", sw, sh, width, height);
    return true;
}

// ───────────────────────────── MapRenderHost ─────────────────────────────

MapRenderHost::MapRenderHost(globecore::GlobeEngine *engine, OHNativeWindow *window)
    : engine_(engine), window_(window) {
    // 「需重绘」回调接本宿主脏标记：对应 Android nativeSetRenderCallback 的反射 requestRender，
    // 鸿蒙侧纯 native 通路（瓦片/矢量异步到位后驱动 WHEN_DIRTY 模式下的下一帧）。
    engine_->setRenderCallback([this] { requestRender(); });
    thread_ = std::thread([this] { renderLoop(); });
}

MapRenderHost::~MapRenderHost() {
    {
        std::lock_guard<std::mutex> lock(mtx_);
        quit_ = true;
    }
    cv_.notify_all();
    if (thread_.joinable()) thread_.join();
    // join 后再摘除回调：确保 lambda（捕获 this）不会在本宿主析构后被引擎线程触发
    engine_->setRenderCallback(nullptr);
}

void MapRenderHost::requestRender() {
    {
        std::lock_guard<std::mutex> lock(mtx_);
        frameDirty_ = true;
    }
    cv_.notify_all();
}

void MapRenderHost::setSurfaceSize(int32_t width, int32_t height) {
    {
        std::lock_guard<std::mutex> lock(mtx_);
        if (width <= 0 || height <= 0) return;
        width_ = width;
        height_ = height;
        sizeDirty_ = true;
        frameDirty_ = true; // 尺寸变化必然重绘（对齐 GLSurfaceView.onSurfaceChanged 后刷帧）
    }
    cv_.notify_all();
}

namespace {
inline int64_t steadyNowNs() {
    return std::chrono::duration_cast<std::chrono::nanoseconds>(
               std::chrono::steady_clock::now().time_since_epoch()).count();
}
constexpr double kFlingStopVpPerSec = 20.0; // 低于此速度停止（vp/s）
constexpr double kFlingDecayPerSec = 6.0;   // 指数衰减时间常数≈167ms，0.7s 内收敛到停止阈值
// 尺寸沉降补帧的节拍/额度参数不在这里：属渲染宿主自身策略，见 EglContext.h 的
// MapRenderHost::kSettleFrames / kSettleIntervalMs / kSettleStableExit。
} // namespace

void MapRenderHost::startFling(double vxVpPerSec, double vyVpPerSec) {
    {
        std::lock_guard<std::mutex> lock(mtx_);
        flingVx_ = vxVpPerSec;
        flingVy_ = vyVpPerSec;
        lastFlingNs_ = 0;
    }
    requestRender();
}

void MapRenderHost::cancelFling() {
    std::lock_guard<std::mutex> lock(mtx_);
    flingVx_ = 0.0;
    flingVy_ = 0.0;
    lastFlingNs_ = 0;
}

void MapRenderHost::postPendingTap(float xVp, float yVp, int64_t deadlineNs) {
    std::lock_guard<std::mutex> lock(mtx_);
    pendingTap_ = true;
    pendingTapX_ = xVp;
    pendingTapY_ = yVp;
    pendingTapDeadlineNs_ = deadlineNs;
    ++selfWakeSeq_;      // 使「按旧状态选定的无限等待」作废，本轮重算为到点定时唤醒
    cv_.notify_all();    // 唤醒休眠中的循环以装载定时唤醒
}

void MapRenderHost::cancelPendingTap() {
    std::lock_guard<std::mutex> lock(mtx_);
    pendingTap_ = false;
    ++selfWakeSeq_;      // 双击已消歧：让循环尽快重算超时，不再为已作废的单击空等
    cv_.notify_all();
}

bool MapRenderHost::advanceFling(int64_t nowNs) {
    double dx = 0.0;
    double dy = 0.0;
    bool active = false;
    {
        std::lock_guard<std::mutex> lock(mtx_);
        if (flingVx_ == 0.0 && flingVy_ == 0.0) return false;
        double dtS = lastFlingNs_ == 0 ? 1.0 / 60.0
                                       : static_cast<double>(nowNs - lastFlingNs_) * 1e-9;
        if (dtS <= 0.0) dtS = 1.0 / 120.0;
        if (dtS > 0.05) dtS = 0.05; // 长停顿（如瓦片解码挤占）后钳住步长，防一次大跳
        dx = flingVx_ * dtS;
        dy = flingVy_ * dtS;
        const double k = std::exp(-dtS * kFlingDecayPerSec);
        flingVx_ *= k;
        flingVy_ *= k;
        active = std::hypot(flingVx_, flingVy_) >= kFlingStopVpPerSec;
        if (!active) {
            flingVx_ = flingVy_ = 0.0;
            lastFlingNs_ = 0;
        } else {
            lastFlingNs_ = nowNs;
        }
    }
    if (dx != 0.0 || dy != 0.0) engine_->panByPixels(dx, dy); // 锁外：与触摸线程同口径的相机推进
    return active;
}

void MapRenderHost::checkPendingTap(int64_t nowNs) {
    std::function<void(float, float)> cb;
    float x = 0.0f;
    float y = 0.0f;
    {
        std::lock_guard<std::mutex> lock(mtx_);
        if (!pendingTap_ || nowNs < pendingTapDeadlineNs_) return;
        pendingTap_ = false;
        cb = singleTapCb_; // 锁内拷贝，锁外触发（回调可能进 NAPI/ArkTS，不可持锁）
        x = pendingTapX_;
        y = pendingTapY_;
    }
    if (cb) cb(x, y);
}

void MapRenderHost::renderLoop() {
    if (!egl_.initialize(window_)) {
        LOGE("MapRenderHost: EGL init failed, render thread exits");
        return;
    }
    engine_->surfaceCreated();

    bool sizeApplied = false; // surfaceChanged(w,h) 至少成功应用一次后才允许 drawFrame
    for (;;) {
        int32_t w = 0;
        int32_t h = 0;
        int32_t curW = 0; // 当前生效视口（沉降帧校对 surface 缓冲几何用）
        int32_t curH = 0;
        bool quit = false;
        bool draw = false;
        bool settling = false; // 本轮是否处于尺寸沉降补帧期（常规帧不查几何，省两次 eglQuery）
        // 进入等待前的自驱动状态序号快照：待确认单击/惯性启停不产生脏帧，仅靠
        // notify_all 唤不醒带断言的 wait（断言仍为假则立刻重新休眠），单击就永远等不到
        // 到点那一轮；故把序号纳作唤醒条件，令其退出并重算超时。
        uint64_t seqSeen = 0;
        {
            std::unique_lock<std::mutex> lock(mtx_);
            // 自驱动帧源装载超时：惯性滑动需 ~60fps 节拍逐帧推进；待确认单击需到点唤醒；
            // 尺寸变更后的沉降期按固定节拍补帧。三者皆无时回到 WHEN_DIRTY 的无限休眠（零空转）。
            int64_t timeoutMs = -1;
            if (flingVx_ != 0.0 || flingVy_ != 0.0) timeoutMs = 16;
            settling = settleFrames_ > 0;
            if (settling) {
                timeoutMs = timeoutMs < 0 ? kSettleIntervalMs : std::min(timeoutMs, kSettleIntervalMs);
            }
            if (pendingTap_) {
                int64_t remainMs = (pendingTapDeadlineNs_ - steadyNowNs() + 999999) / 1000000;
                if (remainMs < 0) remainMs = 0;
                timeoutMs = (timeoutMs < 0) ? remainMs : std::min(timeoutMs, remainMs);
            }
            seqSeen = selfWakeSeq_;
            const auto wake = [this, seqSeen] {
                return quit_ || sizeDirty_ || frameDirty_ || selfWakeSeq_ != seqSeen;
            };
            if (timeoutMs < 0) {
                cv_.wait(lock, wake);
            } else {
                cv_.wait_for(lock, std::chrono::milliseconds(timeoutMs), wake);
            }
            quit = quit_;
            if (!quit) {
                if (sizeDirty_) {
                    w = width_;
                    h = height_;
                    sizeDirty_ = false;
                    settleFrames_ = kSettleFrames; // 新尺寸 → 进入沉降补帧期
                    settleStable_ = 0;             // 新一轮尺寸 → 几何一致计数从头开始
                }
                curW = width_;
                curH = height_;
                settling = settleFrames_ > 0;
                draw = frameDirty_ || settling;
                frameDirty_ = false; // 同帧合并多次唤醒（WHEN_DIRTY 语义）
                if (draw && settling) --settleFrames_; // 补帧额度只在真正出帧时消耗
            }
        }
        if (quit) break;
        if (w > 0 && h > 0) {
            engine_->surfaceChanged(w, h);
            sizeApplied = true;
        }
        if (draw && sizeApplied) {
            if (settling) {
                // 校对窗口缓冲几何：仍滞后于视口则重建 window surface 强制申请新尺寸；
                // 已连续 kSettleStableExit 次对齐 → 清零额度提前结束，不等 1s 上限走完
                if (egl_.syncSurfaceSize(curW, curH)) {
                    settleStable_ = 0;
                } else if (++settleStable_ >= kSettleStableExit) {
                    std::lock_guard<std::mutex> lock(mtx_);
                    settleFrames_ = 0;
                }
            }
            engine_->drawFrame(); // 引擎内部可能同步回调 requestRender → 下轮唤醒，天然形成续帧
            if (!egl_.swapBuffers()) {
                LOGE("eglSwapBuffers failed: 0x%x", eglGetError());
            }
        }
        // 帧后推进自驱动动画：惯性未停则续请一帧；单击到点则触发回调（均不持锁执行）
        const int64_t nowNs = steadyNowNs();
        if (advanceFling(nowNs)) {
            requestRender();
        }
        checkPendingTap(nowNs);
    }

    // GL 资源（着色器/VBO/纹理）必须在上下文销毁前、于本渲染线程释放
    engine_->releaseGl();
    egl_.destroy();
    LOGI("MapRenderHost: render thread exited");
}

} // namespace gcehos
