// napi_init.cpp —— libglobecore 模块注册（对应 Android JNI_OnLoad：JNI 按符号名自动绑定，
// NAPI 需显式把导出挂到模块 exports 对象）。
//
// entry 侧 import 路径：import ww from 'libglobecore'（oh-package.json5 依赖
// "libglobecore": "file:../library"），模块名须与 nm_modname 一致。
#include <napi/native_api.h>
#include <ace/xcomponent/native_interface_xcomponent.h>

namespace gcehos {

// ── 各分组注册函数 ──
napi_value RegisterGlobeEngine(napi_env env, napi_value exports);
napi_value RegisterSrs(napi_env env, napi_value exports);
napi_value RegisterGdalInfo(napi_env env, napi_value exports);
napi_value RegisterLayerInfo(napi_env env, napi_value exports);
napi_value RegisterVectorIo(napi_env env, napi_value exports);

// ── OH_NativeXComponent 取组件逻辑 ──
// 官方方式：XComponent(libraryname) 加载时 ArkUI 在 exports 上设置 OH_NATIVE_XCOMPONENT_OBJ
// 属性，其值是 napi_wrap 的 OH_NativeXComponent*。onLoad 传的 context 对象不是这个。
static napi_ref g_exportsRef = nullptr;
static OH_NativeXComponent *g_cachedComponent = nullptr;

/// 从 exports 的 OH_NATIVE_XCOMPONENT_OBJ 属性取组件指针（首次成功即缓存）。
OH_NativeXComponent *ResolveNativeXComponent(napi_env env) {
    if (g_cachedComponent != nullptr) return g_cachedComponent;
    if (g_exportsRef == nullptr) return nullptr;
    napi_value exports = nullptr;
    if (napi_get_reference_value(env, g_exportsRef, &exports) != napi_ok || exports == nullptr)
        return nullptr;
    napi_value instance = nullptr;
    if (napi_get_named_property(env, exports, OH_NATIVE_XCOMPONENT_OBJ, &instance) != napi_ok
        || instance == nullptr)
        return nullptr;
    void *ptr = nullptr;
    if (napi_unwrap(env, instance, &ptr) != napi_ok || ptr == nullptr)
        return nullptr;
    g_cachedComponent = static_cast<OH_NativeXComponent *>(ptr);
    return g_cachedComponent;
}

namespace {

napi_value Init(napi_env env, napi_value exports) {
    RegisterGlobeEngine(env, exports);
    RegisterSrs(env, exports);
    RegisterGdalInfo(env, exports);
    RegisterLayerInfo(env, exports);
    RegisterVectorIo(env, exports);
    // 缓存 exports 引用，XComponent 加载后 ResolveNativeXComponent 可通过它取组件
    napi_create_reference(env, exports, 1, &g_exportsRef);
    // 尝试立即取一次（当 .so 由 XComponent libraryname 加载时属性已注入）
    ResolveNativeXComponent(env);
    return exports;
}

} // namespace

} // namespace gcehos

static napi_module globeCoreModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = gcehos::Init,
    .nm_modname = "globecore",
    .nm_priv = nullptr,
    .reserved = { nullptr },
};

extern "C" __attribute__((constructor)) void RegisterGlobeCoreModule() {
    napi_module_register(&globeCoreModule);
}
