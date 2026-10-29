#include "flutter_window.h"

#include <flutter/standard_method_codec.h>

#include <optional>
#include <string>
#include <vector>

#include "flutter/generated_plugin_registrant.h"
#include "gpu_preference.h"

namespace {

// Dart 侧的服务名与 `lib/src/services/window_service.dart` 必须一致。
constexpr char kWindowChannelName[] =
    "io.github.dey410.gardendlessloader/window";

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());

  // 窗口能力通道：目前只有全屏。游戏在 CEF 的离屏渲染里跑，HTML5 全屏不会
  // 改变窗口，只能由宿主代为执行；同时 F11 也在本窗口消息里处理，所以状态
  // 变化要用 InvokeMethod 推回 Dart，界面按钮才不会和真实状态脱节。
  window_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), kWindowChannelName,
      &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "setFullscreen") {
          const bool* value = std::get_if<bool>(call.arguments());
          if (!value) {
            result->Error("invalid_arguments", "expected a bool");
            return;
          }
          SetFullscreen(*value);
          result->Success(flutter::EncodableValue(fullscreen_));
          return;
        }
        if (call.method_name() == "isFullscreen") {
          result->Success(flutter::EncodableValue(fullscreen_));
          return;
        }
        if (call.method_name() == "setKeyForwarding") {
          const bool* value = std::get_if<bool>(call.arguments());
          if (!value) {
            result->Error("invalid_arguments", "expected a bool");
            return;
          }
          SetKeyForwarding(*value);
          result->Success();
          return;
        }
        if (call.method_name() == "listGpus") {
          result->Success(gpu::AdaptersToEncodable(gpu::ListAdapters()));
          return;
        }
        if (call.method_name() == "getGpuPreference") {
          result->Success(
              flutter::EncodableValue(gpu::PreferenceName(
                  gpu::ReadCurrentPreference())));
          return;
        }
        if (call.method_name() == "getActiveGpu") {
          const gpu::AdapterInfo active = gpu::ActiveAdapter();
          if (active.name.empty()) {
            result->Success(flutter::EncodableValue());
          } else {
            result->Success(gpu::AdapterToEncodable(active));
          }
          return;
        }
        if (call.method_name() == "setGpuPreference") {
          const auto* arguments =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (arguments == nullptr) {
            result->Error("invalid_arguments", "expected a map");
            return;
          }
          const auto preference_it =
              arguments->find(flutter::EncodableValue("preference"));
          if (preference_it == arguments->end()) {
            result->Error("invalid_arguments", "missing preference");
            return;
          }
          const auto* preference_name =
              std::get_if<std::string>(&preference_it->second);
          gpu::Preference preference = gpu::Preference::kAutomatic;
          if (preference_name == nullptr ||
              !gpu::PreferenceFromName(*preference_name, &preference)) {
            result->Error("invalid_arguments", "unknown preference");
            return;
          }
          bool remember = false;
          const auto remember_it =
              arguments->find(flutter::EncodableValue("remember"));
          if (remember_it != arguments->end()) {
            const auto* value = std::get_if<bool>(&remember_it->second);
            if (value != nullptr) remember = *value;
          }
          result->Success(
              flutter::EncodableValue(gpu::SetPreference(preference, remember)));
          return;
        }
        if (call.method_name() == "restart") {
          // 显卡偏好由 Windows 在进程创建 DXGI 设备时读取，改完只能重启
          // 加载器；重启时带 `--gpu-choice-done`，新进程不再弹一次选择框。
          std::wstring command_line = ::GetCommandLineW();
          if (command_line.find(L"--gpu-choice-done") ==
              std::wstring::npos) {
            command_line += L" --gpu-choice-done";
          }
          std::vector<wchar_t> mutable_command_line(command_line.begin(),
                                                    command_line.end());
          mutable_command_line.push_back(L'\0');
          STARTUPINFOW startup_info = {sizeof(startup_info)};
          PROCESS_INFORMATION process_info = {};
          if (!::CreateProcessW(nullptr, mutable_command_line.data(), nullptr,
                               nullptr, FALSE, 0, nullptr, nullptr,
                               &startup_info, &process_info)) {
            result->Error("restart_failed", "CreateProcessW failed");
            return;
          }
          ::CloseHandle(process_info.hThread);
          ::CloseHandle(process_info.hProcess);
          ::PostMessage(GetHandle(), WM_CLOSE, 0, 0);
          result->Success();
          return;
        }
        if (call.method_name() == "quit") {
          // 正常退出：关闭主窗口 → WM_DESTROY → PostQuitMessage →
          // 消息循环结束 → CoUninitialize。不要从 Dart 侧 exit(0)：
          // 硬终止时 CEF 的线程还在跑，CRT teardown 会 fail-fast
          // （事件日志 0xc0000409 / ucrtbase.dll，2026-10-27 实测）。
          PostMessage(GetHandle(), WM_CLOSE, 0, 0);
          result->Success();
          return;
        }
        result->NotImplemented();
      });

  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  window_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::SetFullscreen(bool fullscreen) {
  HWND hwnd = GetHandle();
  if (!hwnd || fullscreen == fullscreen_) {
    return;
  }

  if (fullscreen) {
    saved_style_ = GetWindowLongPtr(hwnd, GWL_STYLE);
    saved_ex_style_ = GetWindowLongPtr(hwnd, GWL_EXSTYLE);
    saved_placement_.length = sizeof(WINDOWPLACEMENT);
    if (!GetWindowPlacement(hwnd, &saved_placement_)) {
      saved_placement_ = {sizeof(WINDOWPLACEMENT)};
    }

    HMONITOR monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
    MONITORINFO info = {};
    info.cbSize = sizeof(MONITORINFO);
    if (!GetMonitorInfo(monitor, &info)) {
      return;
    }
    const RECT& target = info.rcMonitor;

    // WS_POPUP：没有标题栏与边框。保留 WS_CLIPCHILDREN/CLIPSIBLINGS，
    // 否则 Flutter 的子窗口会跟着重绘闪烁。
    SetWindowLongPtr(hwnd, GWL_STYLE,
                     WS_POPUP | WS_VISIBLE | WS_CLIPCHILDREN | WS_CLIPSIBLINGS);
    SetWindowLongPtr(hwnd, GWL_EXSTYLE,
                     saved_ex_style_ &
                         ~(WS_EX_WINDOWEDGE | WS_EX_CLIENTEDGE |
                           WS_EX_DLGMODALFRAME));
    SetWindowPos(hwnd, HWND_TOP, target.left, target.top,
                 target.right - target.left, target.bottom - target.top,
                 SWP_FRAMECHANGED | SWP_SHOWWINDOW | SWP_NOOWNERZORDER);
  } else {
    SetWindowLongPtr(hwnd, GWL_STYLE, saved_style_);
    SetWindowLongPtr(hwnd, GWL_EXSTYLE, saved_ex_style_);
    SetWindowPos(hwnd, nullptr, 0, 0, 0, 0,
                 SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER |
                     SWP_NOOWNERZORDER);
    // SetWindowPlacement 会一并还原最大化前的正常尺寸与位置。
    if (saved_placement_.length == sizeof(WINDOWPLACEMENT)) {
      SetWindowPlacement(hwnd, &saved_placement_);
    }
  }

  fullscreen_ = fullscreen;
}

void FlutterWindow::NotifyFullscreen() {
  if (window_channel_) {
    window_channel_->InvokeMethod(
        "onFullscreenChanged",
        std::make_unique<flutter::EncodableValue>(fullscreen_));
  }
}

void FlutterWindow::ToggleFullscreen() {
  SetFullscreen(!fullscreen_);
  NotifyFullscreen();
}

bool FlutterWindow::HandleKeyMessage(UINT message, WPARAM resolved,
                                     LPARAM lparam) {
  if (resolved == VK_F11 &&
      (message == WM_KEYDOWN || message == WM_SYSKEYDOWN)) {
    // WM_SYSKEYDOWN 也接：按住 Alt 时 F11 会走系统键路径。
    ToggleFullscreen();
    return true;
  }
  if (resolved == VK_F11 && (message == WM_KEYUP || message == WM_SYSKEYUP)) {
    // 只吞掉，不重复翻转：否则一次按键会切换两次。
    return true;
  }
  // F11 已经由宿主接管；其余按键按原样转给页面（CFE 自己的 key 通路实测
  // 不可用，见 B-74）。这里**不**吞消息：Flutter 界面仍然需要键盘。
  ForwardKeyToPage(message, resolved, lparam);
  return false;
}

void FlutterWindow::SetKeyForwarding(bool enabled) {
  key_forwarding_ = enabled;
}

void FlutterWindow::ForwardKeyToPage(UINT message, WPARAM resolved,
                                     LPARAM lparam) {
  if (!key_forwarding_ || !window_channel_) {
    return;
  }
  // 只转发宿主自己的快捷键：F10（游戏页工具条显隐）。其余按键继续走 CEF 的
  // 原生键盘通路——聚焦一个可聚焦节点之后那条路是通的，原生输入法也能用。
  if (resolved != VK_F10) {
    return;
  }
  const char* type = nullptr;
  switch (message) {
    case WM_KEYDOWN:
    case WM_SYSKEYDOWN:
      type = "keydown";
      break;
    case WM_KEYUP:
    case WM_SYSKEYUP:
      type = "keyup";
      break;
    default:
      return;
  }

  flutter::EncodableMap payload;
  payload[flutter::EncodableValue("type")] = flutter::EncodableValue(type);
  payload[flutter::EncodableValue("virtualKey")] =
      flutter::EncodableValue(static_cast<int32_t>(resolved));
  // WM_CHAR 的 wParam 就是字符码；按键消息这里是虚拟键码。
  payload[flutter::EncodableValue("character")] = flutter::EncodableValue(
      message == WM_CHAR || message == WM_SYSCHAR
          ? static_cast<int32_t>(resolved)
          : 0);
  payload[flutter::EncodableValue("scanCode")] =
      flutter::EncodableValue(static_cast<int32_t>((lparam >> 16) & 0xFF));
  payload[flutter::EncodableValue("extended")] =
      flutter::EncodableValue((lparam & (1LL << 24)) != 0);
  payload[flutter::EncodableValue("repeat")] =
      flutter::EncodableValue((lparam & (1LL << 30)) != 0);
  payload[flutter::EncodableValue("shift")] =
      flutter::EncodableValue((::GetKeyState(VK_SHIFT) & 0x8000) != 0);
  payload[flutter::EncodableValue("ctrl")] =
      flutter::EncodableValue((::GetKeyState(VK_CONTROL) & 0x8000) != 0);
  payload[flutter::EncodableValue("alt")] =
      flutter::EncodableValue((::GetKeyState(VK_MENU) & 0x8000) != 0);
  window_channel_->InvokeMethod(
      "keyEvent", std::make_unique<flutter::EncodableValue>(payload));
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // 兜底：消息循环已经拦了 F11（见 HandleKeyMessage），这里再处理一次是为了
  // 覆盖 `SendMessage` 直投顶层窗口的情况（测试脚本就是这么做的）。两条路径
  // 不会同时触发，因为循环命中后会 `continue`，不再分发。
  if (message == WM_KEYDOWN || message == WM_SYSKEYDOWN) {
    if (wparam == VK_F11) {
      ToggleFullscreen();
      return 0;
    }
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      if (flutter_controller_ && flutter_controller_->engine()) {
        flutter_controller_->engine()->ReloadSystemFonts();
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
