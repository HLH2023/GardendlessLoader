/// 桌面端键盘引导脚本：让 CEF 的原生键盘通路真正开始投递。
///
/// 背景（2026-10-28 实机定位，B-74）：游戏在 `webview_cef` 的 CEF 离屏渲染里，
/// 键盘消息由 `main.cpp` 的消息循环转给插件，插件再调
/// `CefBrowserHost::SendKeyEvent`。但插件的 `WebviewHandler::sendKeyEvent`
/// 只把事件发给 `current_focused_browser_`，而该成员只在渲染进程上报
/// 「焦点节点变化」（`FocusedNodeChanged` IPC）时才被赋值；页面上没有任何
/// 可聚焦元素、焦点永远停在 `body` 时这条 IPC 不发，按键在 `sendKeyEvent`
/// 第一行就被丢弃——表现就是「鼠标能玩、键盘全废」。
///
/// 修法：页面加载完成后放一个**隐藏的可聚焦输入框**并聚焦它。
/// 实测这一下会触发 `focusednode` IPC，之后 `SendKeyEvent` 才真正进渲染进程，
/// 游戏里的数字选卡、字母铲子、F 键全屏都能收到（页面自己的 keydown 监听器
/// 能看到 `activeElement === CANVAS`）。
///
/// 为什么用 input 而不是 div：只有**可编辑**节点会让 CEF 把它当作键盘输入目标
/// 并保持输入焦点；div[tabindex] 能被聚焦，但在这套离屏渲染里不足以让键盘
/// 事件真正投递（实测对比过）。输入框在屏幕外、透明、不吃指针事件，
/// 并且实时清空，避免把用户输入吞进这个不可见的元素里。
///
/// 为什么不去改插件：`webview_cef` 是三方包，改它要 vendor + 只能 Windows
/// 构建；这段脚本对其它宿主无害（普通浏览器里只是一个隐藏节点）。
///
/// 2026-10-28 第二次实机复现：hlh.30 能用的键盘在 hlh.31 又失效。代码没动过，
/// 差别只在时序——旧脚本一进来就先写「已安装」标志、再检查 `document.body`；
/// 如果注入落在 HTML 解析中（`initialize()` 返回得比页面加载快），探针被解析器
/// 移走、焦点丢失，而 loadEnd 的第二次注入被标志挡掉，就再也没人引导键盘。
/// 现在改成「只有探针真的挂上并聚焦成功才算安装完成」，并且每次注入都会在
/// 没聚焦成功时重试。同时把状态经 JS 通道报给 Dart（`keyboard.log`），
/// 下次再出问题不用靠猜。
library;

const String desktopKeyboardScript = r'''
(function () {
  "use strict";

  function isEditable(node) {
    if (!node || node.nodeType !== 1) return false;
    var tag = (node.tagName || "").toLowerCase();
    if (tag === "input" || tag === "textarea" || tag === "select") return true;
    return node.isContentEditable === true;
  }

  function findProbe() {
    return document.querySelector("input[data-gardendless-keyboard]");
  }

  // 没有 body 时绝不提前返回并记「已安装」：文档还在解析，节点会被解析器
  // 移走/重建，而 loadEnd 的第二次注入会被标志挡住，键盘就永远没人引导。
  function ensureProbe() {
    var existing = findProbe();
    if (existing) return existing;
    if (!document.body) return null;
    var probe = document.createElement("input");
    probe.type = "text";
    probe.tabIndex = -1;
    probe.autocomplete = "off";
    probe.setAttribute("data-gardendless-keyboard", "");
    probe.style.cssText =
      "position:fixed;left:-200px;top:-200px;width:10px;height:10px;" +
      "opacity:0;pointer-events:none;";
    // 焦点可能落到这个不可见输入框里；不清理会把用户输入吞掉。
    probe.addEventListener("input", function () { probe.value = ""; });
    document.body.appendChild(probe);
    return probe;
  }

  function focusProbe() {
    var probe = ensureProbe();
    if (!probe) return false;
    if (document.activeElement === probe) {
      window.__gardendlessKeyboardPrimed = true;
      return true;
    }
    // 用户正在真实输入框里（玩家名、聊天）：绝不抢焦点，否则字打不进去。
    if (isEditable(document.activeElement)) return false;
    try {
      probe.focus();
    } catch (error) {
      return false;
    }
    if (document.activeElement === probe) {
      // 记录「这一次真的把焦点按上去了」：再注入时不重复抢游戏画布的焦点。
      window.__gardendlessKeyboardPrimed = true;
      return true;
    }
    return false;
  }

  // 宿主在加载完成 1.2s 后调用一次：此时窗口一定已有客户端焦点，
  // 强制 blur+focus 能补上首轮可能漏掉的 focusednode 上报。每次页面只做一次。
  window.__gardendlessKeyboardNudge = function () {
    if (window.__gardendlessKeyboardNudged) return false;
    window.__gardendlessKeyboardNudged = true;
    var probe = ensureProbe();
    if (!probe) return false;
    if (isEditable(document.activeElement) && document.activeElement !== probe) {
      return false;
    }
    try { probe.blur(); } catch (error) { /* ignore */ }
    try { probe.focus(); } catch (error) { return false; }
    window.__gardendlessKeyboardPrimed = document.activeElement === probe;
    return window.__gardendlessKeyboardPrimed;
  };

  function describe(element) {
    if (!element) return "";
    var tag = element.tagName || "?";
    var id = element.id ? "#" + element.id : "";
    return tag + id;
  }

  // 状态只经 JS 通道交给宿主，页面自身不依赖它；宿主写在 keyboard.log。
  function report(kind, key, extra) {
    extra = extra || {};
    try {
      var bridge = window.gardendlessDesktop;
      if (typeof bridge !== "function") return;
      bridge(JSON.stringify({
        command: "keyboard:state",
        kind: kind || "state",
        installed: !!findProbe(),
        primed: !!window.__gardendlessKeyboardPrimed,
        active: describe(document.activeElement),
        readyState: document.readyState,
        key: key || "",
        code: extra.code || "",
        keyCode: extra.keyCode || 0,
        target: extra.target || ""
      }), 0);
    } catch (error) { /* 诊断不能影响游戏 */ }
  }

  // event.code 缺失时从 keyCode 还原（Cocos 的热键映射只认 code）。
  function codeFromKeyCode(keyCode) {
    if (keyCode >= 65 && keyCode <= 90) {
      return "Key" + String.fromCharCode(keyCode);
    }
    if (keyCode >= 48 && keyCode <= 57) return "Digit" + (keyCode - 48);
    if (keyCode >= 96 && keyCode <= 105) return "Numpad" + (keyCode - 96);
    if (keyCode >= 112 && keyCode <= 123) return "F" + (keyCode - 111);
    var map = {
      8: "Backspace", 9: "Tab", 13: "Enter", 16: "ShiftLeft",
      17: "ControlLeft", 18: "AltLeft", 27: "Escape", 32: "Space",
      33: "PageUp", 34: "PageDown", 35: "End", 36: "Home",
      37: "ArrowLeft", 38: "ArrowUp", 39: "ArrowRight", 40: "ArrowDown",
      45: "Insert", 46: "Delete", 186: "Semicolon", 187: "Equal",
      188: "Comma", 189: "Minus", 190: "Period", 191: "Slash",
      192: "Backquote", 219: "BracketLeft", 220: "Backslash",
      221: "BracketRight", 222: "Quote"
    };
    return map[keyCode] || "";
  }

  // 游戏（Cocos）把 keydown/keyup 绑在 #GameCanvas 上，并用 event.code 映射
  // 热键。webview_cef 把整条 lParam 当成 native_key_code 交给 CEF，Chromium
  // 算出来的 code 可能是空/Unidentified——页面能看到 key/keyCode，游戏却拿不到
  // 可识别的键（2026-10-28 实机日志：key=1/2 已到页面，游戏无反应）。
  // 在事件到达画布之前校正：code 缺失就从 keyCode 还原，目标不是画布就重派发到
  // 画布；原生事件被截住，不会出现双份 keydown。真实输入框不拦。
  function normalizeKeyEvent(event) {
    if (event.__gardendlessNormalized) return;
    var canvas = document.getElementById("GameCanvas");
    if (!canvas) return;
    var target = event.target;
    var probe = findProbe();
    if (isEditable(target) && target !== probe) return;
    // 注意判断的是「原生 code 是否缺失」，不是还原后的 code：
    // Digit/Key 系列能从 keyCode 还原出来，但原生事件本身仍然不可用
    // （hlh.34 实机日志：code="" keyCode=49 target=CANVAS，游戏不响应；
    // 旧逻辑把 wrongCode 算成 false，校正没触发）。
    var originalCode = event.code && event.code !== "Unidentified"
      ? event.code
      : "";
    var code = originalCode || codeFromKeyCode(event.keyCode);
    var wrongTarget = target !== canvas;
    var wrongCode = !originalCode;
    if (!wrongTarget && !wrongCode) return;
    var fixed = new KeyboardEvent(event.type, {
      key: event.key,
      code: code || "",
      location: event.location || 0,
      ctrlKey: event.ctrlKey,
      shiftKey: event.shiftKey,
      altKey: event.altKey,
      metaKey: event.metaKey,
      repeat: event.repeat,
      isComposing: event.isComposing,
      bubbles: true,
      cancelable: true,
      composed: true
    });
    try {
      Object.defineProperty(fixed, "keyCode",
        { get: function () { return event.keyCode; } });
      Object.defineProperty(fixed, "which",
        { get: function () { return event.keyCode; } });
      Object.defineProperty(fixed, "__gardendlessNormalized", { value: true });
    } catch (error) { /* ignore */ }
    if (!window.__gardendlessKeyboardFixedCount ||
        window.__gardendlessKeyboardFixedCount < 5) {
      window.__gardendlessKeyboardFixedCount =
        (window.__gardendlessKeyboardFixedCount || 0) + 1;
      report("normalized", event.key, {
        code: (event.code || "") + "->" + (code || ""),
        keyCode: event.keyCode,
        target: describe(target) + "->" + describe(canvas)
      });
    }
    event.stopImmediatePropagation();
    if (event.cancelable) event.preventDefault();
    canvas.dispatchEvent(fixed);
  }

  // 测试/诊断入口：Node 假 DOM 里可以直接调用校正函数。
  window.__gardendlessKeyboardNormalize = normalizeKeyEvent;

  function install() {
    var existed = !!findProbe();
    var probe = ensureProbe();
    if (!probe) return false;
    if (!existed || !window.__gardendlessKeyboardPrimed) focusProbe();
    if (!window.__gardendlessKeyboardHooked) {
      window.__gardendlessKeyboardHooked = true;
      // 只记前 5 个 keydown：用来判断「按键有没有进到页面」。
      // 不拦截、不 preventDefault，游戏自己的监听器照常收到。
      window.addEventListener("keydown", function (event) {
        if (window.__gardendlessKeyboardKeyCount >= 5) return;
        window.__gardendlessKeyboardKeyCount =
          (window.__gardendlessKeyboardKeyCount || 0) + 1;
        report("keydown", event.key, {
          code: event.code,
          keyCode: event.keyCode,
          target: describe(event.target)
        });
      }, true);
      // 监听顺序：先记原始事件，再校正（stopImmediatePropagation 只影响
      // 之后注册的监听器，所以报告总能拿到原生字段）。
      window.addEventListener("keydown", normalizeKeyEvent, true);
      window.addEventListener("keyup", normalizeKeyEvent, true);
    }
    setTimeout(function () { report("install"); }, 0);
    return true;
  }

  window.__gardendlessKeyboardInstall = install;
  // 每次注入都跑一遍：第一次造节点并聚焦；后续（loadEnd / 延迟重试）只在
  // 没聚焦成功时补焦，不会从已经拿到焦点的游戏画布手里反复抢。
  install();

  if (!document.body && !window.__gardendlessKeyboardWaiting) {
    window.__gardendlessKeyboardWaiting = true;
    document.addEventListener("DOMContentLoaded", install, { once: true });
    var tries = 0;
    var timer = setInterval(function () {
      if (install() || ++tries > 200) clearInterval(timer);
    }, 50);
  }
})();
''';
