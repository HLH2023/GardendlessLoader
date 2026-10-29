#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

// webview_cef（游戏窗口用的 CEF 内核）要求两个钩子：
//   1. initCEFProcesses 必须作为 wWinMain 的第一条语句，启动 Chromium 子进程；
//   2. 消息循环里把消息转发给 CEF，键盘/输入法才能进到页面。
#include "webview_cef/webview_cef_plugin_c_api.h"

#include "cef_log_limit.h"
#include "flutter_window.h"
#include "gpu_preference.h"
#include "utils.h"

#include <imm.h>

namespace {

// 中文输入法（微软拼音等）会把按键消息的 wParam 换成 VK_PROCESSKEY(0xE5)，
// 真正的虚拟键码要用 ImmGetVirtualKey 取回。不还原的话：
//   * webview_cef 直接把 wParam 当键码转给 CEF，页面收到的全是 0xE5，
//     字母/功能键全部失效；
//   * 宿主自己的 F11 判断也永远匹配不上。
// 只在**转发给 CEF / 自己判断**时用还原后的键码；原消息保持不动再交给
// TranslateMessage/DispatchMessage，否则输入法的组字流程会被打断。
WPARAM ResolveVirtualKey(const MSG& message) {
  if (message.message != WM_KEYDOWN && message.message != WM_SYSKEYDOWN) {
    return message.wParam;
  }
  if (message.wParam != VK_PROCESSKEY) {
    return message.wParam;
  }
  const UINT resolved = ::ImmGetVirtualKey(message.hwnd);
  return resolved != 0 ? static_cast<WPARAM>(resolved) : message.wParam;
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // 必须最先执行：CEF 子进程模式下这一句会直接返回退出码。
  int cef_exit_code = initCEFProcesses(instance);
  if (cef_exit_code >= 0) {
    return cef_exit_code;
  }

  // 必须在 Flutter 引擎创建之前：Windows 在进程第一次创建 DXGI 设备时
  // 读取按应用显卡偏好。晚于引擎创建，只有 CEF 会换到独显，而 Flutter
  // 的 ANGLE 仍留在核显，两边共享纹理打不开，游戏画面会黑。
  gpu::ApplyStartupPreference();

  // CEF 的 debug.log 没有上限，界面异常时可能写到几百 GB；只裁浏览器进程的日志。
  StartCefLogLimit();

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"GardendlessLoader", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    const WPARAM virtual_key = ResolveVirtualKey(msg);
    // 窗口级快捷键必须在分发之前处理：真实按键投递给 Flutter 的子窗口
    // （FLUTTERVIEW），不会进入 FlutterWindow::MessageHandler。命中时连
    // CEF 的转发也一起跳过，页面拿不到这个键就不会和宿主抢全屏状态。
    if (window.HandleKeyMessage(msg.message, virtual_key, msg.lParam)) {
      continue;
    }
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
    // 转发给 CEF：缺少这一句时页面收不到键盘输入。键码用解析过
    // VK_PROCESSKEY 的那个，否则输入法激活时页面收到的全是 0xE5。
    handleWndProcForCEF(msg.hwnd, msg.message,
                        virtual_key != 0 ? virtual_key : msg.wParam,
                        msg.lParam);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
