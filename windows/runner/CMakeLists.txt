cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "cef_log_limit.cc"
  "flutter_window.cpp"
  "gpu_preference.cc"
  "main.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
# 显卡枚举走 DXGI；按应用显卡偏好读写 HKCU（RegOpenKeyEx 等）走 advapi32；
# 设置页的「当前进程实际用哪块卡」需要创建一个默认 D3D11 设备。
target_link_libraries(${BINARY_NAME} PRIVATE "d3d11.lib" "dxgi.lib"
    "advapi32.lib")
# ImmGetVirtualKey：中文输入法把 WM_KEYDOWN 的 wParam 换成 VK_PROCESSKEY 后，
# 要靠它取回真正的虚拟键码（见 main.cpp 的 NormalizeVirtualKey）。
target_link_libraries(${BINARY_NAME} PRIVATE "imm32.lib")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# 说明：main.cpp 用到的 initCEFProcesses / handleWndProcForCEF 由
# flutter/generated_plugins.cmake 负责链接（它对每个插件都执行
# target_link_libraries(${BINARY_NAME} PRIVATE <plugin>_plugin)），而
# webview_cef 的 windows/CMakeLists.txt 用 INTERFACE 暴露了 include 目录。
# 这里不要再手动链接，否则会重复定义/找不到变量。

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)
