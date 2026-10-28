/// 桌面端「全屏」注入脚本。
///
/// 背景：游戏把宿主当成 Electron（资源包里的 `tmppatch.js` 自己造了一个
/// `window.electron`），设置里的全屏最终走 `document.documentElement
/// .requestFullscreen()`。桌面加载器用 CEF 离屏渲染（把画面贴成纹理），
/// HTML5 全屏在离屏模式下不会改变窗口，`webview_cef` 也没实现全屏回调，
/// 于是点了没有任何反应。
///
/// 这里把「谁负责全屏」从浏览器换成宿主：DOM 全屏 API 不再指望 CEF，
/// 而是转发给 `window.gardendlessDesktop`（Dart 侧 `desktop_game_page`
/// 注册的 JS 通道），由 Win32 窗口做边框全屏。同时伪造
/// `document.fullscreenElement`，否则游戏用 `electron.isFullscreen()`
/// 判断状态会永远返回「不是全屏」，第二次点击又变成「进入」。
///
/// 为什么不用资源包里的 patch 覆盖：那段脚本属于用户资源包，会被资源更新
/// 覆盖；宿主能力必须留在宿主侧。
const String desktopFullscreenScript = r'''
(function () {
  "use strict";
  if (window.__gardendlessFullscreen) return;

  var channelName = "gardendlessDesktop";
  var state = false;
  var documentElement = document.documentElement;

  function send(fullscreen) {
    try {
      var bridge = window[channelName];
      if (typeof bridge !== "function") return false;
      // 第二个参数是 webview_cef 的回调 id 占位；全屏是单向通知，
      // 状态由宿主通过 __gardendlessFullscreen.apply 回灌。
      bridge(JSON.stringify({command: "window:setFullscreen", fullscreen: !!fullscreen}), 0);
      return true;
    } catch (error) {
      return false;
    }
  }

  function fire(name) {
    try {
      document.dispatchEvent(new Event(name));
    } catch (error) {
      /* 事件派发失败不影响状态 */
    }
  }

  function apply(value) {
    var next = !!value;
    var changed = next !== state;
    state = next;
    if (changed) {
      fire("fullscreenchange");
      fire("webkitfullscreenchange");
    }
    return state;
  }

  var elementProto = Element.prototype;
  var originalRequest = elementProto.requestFullscreen ||
    elementProto.webkitRequestFullscreen || elementProto.mozRequestFullScreen ||
    elementProto.msRequestFullscreen;

  function request() {
    if (!send(true)) {
      // 宿主通道不在（例如注入到了普通浏览器页面）：保持原行为，不要假装成功。
      if (typeof originalRequest === "function") {
        try { return originalRequest.apply(this, arguments); } catch (error) { /* ignore */ }
      }
      return Promise.reject(new Error("fullscreen_unavailable"));
    }
    apply(true);
    return Promise.resolve();
  }

  elementProto.requestFullscreen = request;
  elementProto.webkitRequestFullscreen = request;
  elementProto.mozRequestFullScreen = request;
  elementProto.msRequestFullscreen = request;

  var originalExit = document.exitFullscreen ||
    document.webkitExitFullscreen || document.mozCancelFullScreen ||
    document.msExitFullscreen;

  function exit() {
    if (!send(false)) {
      if (typeof originalExit === "function") {
        try { return originalExit.apply(document, arguments); } catch (error) { /* ignore */ }
      }
      return Promise.reject(new Error("fullscreen_unavailable"));
    }
    apply(false);
    return Promise.resolve();
  }

  document.exitFullscreen = exit;
  document.webkitExitFullscreen = exit;
  document.mozCancelFullScreen = exit;
  document.msExitFullscreen = exit;

  // 游戏用 document.fullscreenElement 判断「现在是不是全屏」。
  var properties = ["fullscreenElement", "webkitFullscreenElement",
    "mozFullScreenElement", "msFullscreenElement"];
  for (var index = 0; index < properties.length; index++) {
    (function (name) {
      var getter = {
        configurable: true,
        get: function () { return state ? documentElement : null; }
      };
      try {
        Object.defineProperty(Document.prototype, name, getter);
      } catch (error) {
        try { Object.defineProperty(document, name, getter); } catch (ignored) { /* ignore */ }
      }
    })(properties[index]);
  }

  // 游戏内的「退出」最终会调用 `window.close()`（资源包里的 tmppatch 把
  // `electronAPI.quit` 实现成 `window.close()`）。CEF 的离屏浏览器没有
  // 「脚本打开的窗口」这个概念，close 会把浏览器对象销毁，而 Flutter 侧还在
  // 用它的纹理与浏览器 id——实机表现是整个窗口「未响应」（2026-10-28 用户实测）。
  // 这里把动作交回宿主：退出游戏页、回加载器，由 Dart 走正常的收尾流程。
  var originalClose = window.close.bind(window);
  window.close = function () {
    try {
      var bridge = window[channelName];
      if (typeof bridge === "function") {
        bridge(JSON.stringify({command: "window:closeGame"}), 0);
        return;
      }
    } catch (error) { /* 桥不在：退回原生行为 */ }
    try { originalClose(); } catch (error) { /* ignore */ }
  };

  // 宿主改状态时（F11 / 工具栏按钮）回灌，页面与真实窗口才不会脱节。
  window.__gardendlessFullscreen = Object.freeze({
    apply: apply,
    isFullscreen: function () { return state; },
    request: function () { request(); },
    exit: function () { exit(); }
  });
})();
''';
