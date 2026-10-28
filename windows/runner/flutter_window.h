#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

  // 在消息循环里、分发之前处理窗口级快捷键，返回 true 表示该消息已被吞掉。
  //
  // 为什么不在 MessageHandler 里做：真实按键消息由 Windows 投递给**有焦点的
  // 子窗口**（Flutter 的 `FLUTTERVIEW`），而 MessageHandler 只处理顶层窗口的
  // 消息，子窗口的消息根本不经过这里——2026-10-28 在 Windows 实机用
  // `PostMessage(FLUTTERVIEW, WM_KEYDOWN, VK_F11)` 验证过：顶层窗口样式不变，
  // 同一个消息发给顶层窗口才生效。所以 F11 必须按「消息」而不是按「窗口」拦。
  //
  // 同时要连 KEYUP 一起吞掉：按下时没转给 CEF，再单独转一个抬起会让页面的
  // 键盘状态错位。
  /// |resolved| 是解析过 VK_PROCESSKEY 之后的真实键码（WM_CHAR 时是字符码）。
  bool HandleKeyMessage(UINT message, WPARAM resolved, LPARAM lparam);

  /// 开关「把按键转给页面」：只有游戏页在前台时才打开（Dart 侧控制）。
  void SetKeyForwarding(bool enabled);

  /// 把一条按键消息转成 Dart 侧的 `keyEvent` 调用。
  ///
  /// 为什么不让 CEF 自己送：`webview_cef` 的 key 通路在这套离屏渲染里实测
  /// 完全不投递（B-74），页面拿不到 keydown；而这条方法通道是可靠的。
  void ForwardKeyToPage(UINT message, WPARAM resolved, LPARAM lparam);

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // 边框全屏：去掉标题栏/边框，铺满所在显示器。
  //
  // 为什么需要原生实现：游戏跑在 CEF 的离屏渲染（贴图）里，HTML5 的
  // `requestFullscreen` 在离屏模式下不会触发任何窗口变化，webview_cef 也没有
  // 全屏回调——所以游戏设置里的「全屏」以前点了没有任何效果。
  void SetFullscreen(bool fullscreen);
  void NotifyFullscreen();

  // F11 / 工具栏按钮共用：翻转全屏并通知 Dart。
  void ToggleFullscreen();

  // 记下进入全屏前的窗口样式与位置，退出时原样还原（含最大化状态）。
  LONG_PTR saved_style_ = 0;
  LONG_PTR saved_ex_style_ = 0;
  WINDOWPLACEMENT saved_placement_ = {sizeof(WINDOWPLACEMENT)};
  bool fullscreen_ = false;

  // Dart 侧打开后才转发按键，避免在加载器自己的界面上做无用的跨平台调用。
  bool key_forwarding_ = false;

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      window_channel_;

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
