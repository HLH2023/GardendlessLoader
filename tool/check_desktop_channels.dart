// 桌面端平台通道契约验收（纯 Dart，本机可跑）
//
// 为什么单独盯这个：`io.github.dey410.gardendlessloader/*` 这几个平台通道
// 只在 Android(Kotlin)/iOS(Swift)/鸿蒙(ETS) 里实现，Windows/Linux/macOS
// 一个都没有。桌面端一旦直接 `invokeMethod`，Flutter 会抛
// MissingPluginException；如果这行在初始化路径上，异常会被 `initialize()`
// 的兜底 catch 接住，用户看到的是整页「应用初始化失败」——2026-10-27 的
// Windows 包就是死在 `incomingZip` 这一步（日志：app_controller.dart:1258）。
//
// 这个套件不看运行结果，只看源码契约：调用点必须先把桌面端挡掉，或者
// 把 MissingPluginException 当成「平台没这个能力」处理。
//
// 用法: dart run tool/check_desktop_channels.dart
import 'dart:io';

int passed = 0;
int failed = 0;

void check(String name, bool ok, [Object? extra]) {
  if (ok) {
    passed++;
    stdout.writeln('  ok   $name${extra != null ? ' -> $extra' : ''}');
  } else {
    failed++;
    stdout.writeln('  FAIL $name${extra != null ? ' -> $extra' : ''}');
  }
}

/// 抓出 `Future<...> name(...) async { ... }` 的方法体（按大括号配对）。
String? methodBody(String source, String name) {
  final signature = RegExp(
      '(Future<[^>]*>|void|String\\??)\\s+${RegExp.escape(name)}\\s*\\(');
  final match = signature.firstMatch(source);
  if (match == null) return null;
  final start = source.indexOf('{', match.start);
  if (start < 0) return null;
  var depth = 0;
  for (var i = start; i < source.length; i++) {
    final ch = source[i];
    if (ch == '{') depth++;
    if (ch == '}') {
      depth--;
      if (depth == 0) return source.substring(start, i + 1);
    }
  }
  return null;
}

String read(String path) => File(path).readAsStringSync();
List<File> dartFilesUnder(String dir) => Directory(dir)
    .listSync(recursive: true)
    .whereType<File>()
    .where((file) => file.path.endsWith('.dart'))
    .toList();

/// 每一次 `Relaunch` 调用前 400 字符内必须出现 `Close-Ui`：
/// 窗口留着不关，重新拉起的加载器会被它挡在后面。
bool _everyRelaunchClosesUi(String source) {
  final calls = RegExp(r'\n\s+Relaunch\r?\n').allMatches(source);
  if (calls.isEmpty) return false;
  return calls.every((match) {
    final start = match.start - 400 < 0 ? 0 : match.start - 400;
    return source.substring(start, match.start).contains('Close-Ui');
  });
}

void main() {
  final picker = read('lib/src/services/resource_picker_service.dart');
  final shortcut = read('lib/src/services/shortcut_service.dart');
  final external = read('lib/src/services/external_url_service.dart');
  final controller = read('lib/src/app_controller.dart');
  final home = read('lib/src/ui/home_page.dart');

  stdout.writeln('== resource_zip_importer 通道 ==');
  final incoming = methodBody(picker, 'incomingZipName');
  check('incomingZipName 存在', incoming != null);
  check(
    'incomingZipName 先挡掉非移动端',
    incoming != null && incoming.contains('_isSupportedPlatform'),
  );
  check(
    'incomingZipName 把 MissingPluginException 当成「没有 ZIP」',
    incoming != null && incoming.contains('on MissingPluginException'),
  );
  final discard = methodBody(picker, 'discardIncomingZip');
  check('discardIncomingZip 存在', discard != null);
  check(
    'discardIncomingZip 先挡掉非移动端',
    discard != null && discard.contains('_isSupportedPlatform'),
  );
  check(
    'discardIncomingZip 忽略缺失通道',
    discard != null && discard.contains('on MissingPluginException'),
  );

  stdout.writeln('== shortcuts 通道 ==');
  final take = methodBody(shortcut, 'take');
  check('take 存在', take != null);
  check('take 在桌面端直接返回 null', take != null && take.contains('_isDesktop'));
  check(
    'take 忽略缺失通道',
    take != null && take.contains('on MissingPluginException'),
  );
  final publish = methodBody(shortcut, 'publish');
  check('publish 存在', publish != null);
  check(
    'publish 在桌面端直接返回',
    publish != null && publish.contains('_isDesktop'),
  );
  check(
    '_isDesktop 覆盖 Windows/Linux/macOS',
    shortcut.contains('Platform.isWindows') &&
        shortcut.contains('Platform.isLinux') &&
        shortcut.contains('Platform.isMacOS'),
  );

  stdout.writeln('== external_browser 通道 ==');
  // 2026-10-27 Windows 实测：`cmd /c start` 会在 URL 里的第一个 `&` 处截断
  // （`?uid=42&profile=x` 只有 `?uid=42` 到达浏览器），另一半被当成独立命令执行。
  check(
    'ExternalUrlService 的 Windows 分支不再用 cmd /c start（& 会被截断/注入）',
    !external.contains("'cmd'") && !external.contains("'/c'"),
  );
  check(
    'ExternalUrlService 的 Windows 分支用 rundll32 ShellExecute',
    external.contains("'rundll32'") &&
        external.contains('url.dll,FileProtocolHandler'),
  );
  check(
    'rundll32 失败时退回 PowerShell ShellExecute 且转义单引号',
    external.contains("'powershell'") &&
        external.contains('Start-Process -FilePath') &&
        external.contains('url.replaceAll("\'", "\'\'")'),
  );
  check(
      'ExternalUrlService 有 macOS 分支', external.contains("Process.run('open'"));
  check('ExternalUrlService 有 Linux 分支',
      external.contains("Process.run('xdg-open'"));
  check(
    'ExternalUrlService 仍保留移动端通道',
    external.contains('/external_browser'),
  );
  check(
    'AppController.openTokenIssuePage 不再直接调通道',
    !(methodBody(controller, 'openTokenIssuePage') ?? '')
        .contains('/external_browser'),
  );
  check(
    'AppController.openExternalUrl 存在',
    methodBody(controller, 'openExternalUrl') != null,
  );
  check(
    'UI 层不再直接调 external_browser 通道',
    !home.contains('/external_browser'),
  );
  check(
    'home_page 的打开链接走 controller',
    home.contains('_controller.openExternalUrl(url)'),
  );

  stdout.writeln('== 初始化路径 ==');
  check(
    'initialize 仍会读取待处理 ZIP 与快捷方式（只是现在桌面端安全）',
    controller.contains('_resourcePickerService.incomingZipName()') &&
        controller.contains('_shortcutService.take()') &&
        controller.contains('_shortcutService.publish('),
  );

  stdout.writeln('== Windows 全屏（窗口能力通道）==');
  // 游戏在 CEF 的离屏渲染里跑：HTML5 全屏不会改变窗口，webview_cef 也没有
  // 全屏回调。所以「游戏设置里的全屏」必须由宿主 Win32 窗口真的做一次。
  final runner = read('windows/runner/flutter_window.cpp');
  final runnerHeader = read('windows/runner/flutter_window.h');
  final mainSource = read('windows/runner/main.cpp');
  final windowService = read('lib/src/services/window_service.dart');
  final keyboardScript = read('lib/src/services/desktop_keyboard_script.dart');
  final runnerCMake = read('windows/runner/CMakeLists.txt');
  final screenScript = read('lib/src/services/desktop_fullscreen_script.dart');
  final gamePage = read('lib/src/ui/pages/desktop_game_page.dart');

  check(
    '原生窗口注册了 window 通道',
    runner.contains('io.github.dey410.gardendlessloader/window'),
  );
  check(
    'Dart 侧通道名与原生一致',
    windowService.contains('io.github.dey410.gardendlessloader/window'),
  );
  check(
    '原生实现 setFullscreen/isFullscreen',
    runner.contains('"setFullscreen"') && runner.contains('"isFullscreen"'),
  );
  check(
    '全屏用 WS_POPUP 去掉标题栏并铺满所在显示器',
    runner.contains('WS_POPUP') &&
        runner.contains('MonitorFromWindow') &&
        runner.contains('MONITOR_DEFAULTTONEAREST') &&
        runner.contains('rcMonitor'),
  );
  check(
    '退出全屏还原原样式与位置（含最大化）',
    runner.contains('saved_style_') &&
        runner.contains('saved_ex_style_') &&
        runner.contains('SetWindowPlacement'),
  );
  check(
    'F11 在消息循环里按「消息」拦下（真实按键投给 FLUTTERVIEW，进不了顶层 WndProc）',
    RegExp(r'window\.HandleKeyMessage\(msg\.message, virtual_key')
            .hasMatch(mainSource) &&
        mainSource.indexOf('HandleKeyMessage(msg.message') <
            mainSource.indexOf('::DispatchMessage(&msg)') &&
        mainSource.indexOf('HandleKeyMessage(msg.message') <
            mainSource.indexOf('handleWndProcForCEF'),
  );
  check(
    'F11 按下/抬起都吞掉（只吞一半会让页面键盘状态错位）',
    runner.contains('bool FlutterWindow::HandleKeyMessage') &&
        RegExp(r'resolved == VK_F11[\s\S]{0,300}?ToggleFullscreen\(\)[\s\S]{0,400}?WM_KEYUP[\s\S]{0,200}?return true;')
            .hasMatch(runner),
  );
  check(
    '顶层 WndProc 仍保留 F11 兜底（SendMessage 直投顶层时）',
    runner.contains('VK_F11') &&
        runner.indexOf('VK_F11') < runner.indexOf('HandleTopLevelWindowProc'),
    null,
  );
  check(
    'F11 的状态变化推回 Dart',
    runner.contains('"onFullscreenChanged"') &&
        runnerHeader.contains('window_channel_'),
  );
  // 中文输入法会把 WM_KEYDOWN 的 wParam 换成 VK_PROCESSKEY(0xE5)。不还原的话
  // 页面收到的键码全是 0xE5（数字键偶然正常），F11 判断也永远不匹配。
  check(
    '输入法的 VK_PROCESSKEY 用 ImmGetVirtualKey 还原',
    mainSource.contains('ImmGetVirtualKey') &&
        mainSource.contains('VK_PROCESSKEY') &&
        runnerCMake.contains('imm32'),
  );
  check(
    '还原后的键码同时用于 F11 判断与 CEF 转发',
    RegExp(r'HandleKeyMessage\(msg\.message,\s*virtual_key')
            .hasMatch(mainSource) &&
        RegExp(r'handleWndProcForCEF\([\s\S]{0,120}?virtual_key')
            .hasMatch(mainSource),
  );
  check(
    'F10 由宿主转发给 Dart（游戏页工具条显隐）',
    runner.contains('VK_F10') &&
        runner.contains('"keyEvent"') &&
        runner.contains('"setKeyForwarding"') &&
        windowService.contains('setKeyForwarding') &&
        windowService.contains('keyEvent') &&
        gamePage.contains('0x79'),
  );
  // 游戏里的「退出」会调 window.close()。CEF 离屏浏览器被销毁后 Flutter 还在
  // 用它的纹理，实机会整窗「未响应」。必须由宿主接管这个动作。
  check(
    '游戏内退出（window.close）交回宿主，不销毁 CEF 浏览器',
    screenScript.contains('window.close') &&
        screenScript.contains('window:closeGame') &&
        gamePage.contains("payload['command'] == 'window:closeGame'") &&
        gamePage.contains('_closing'),
  );

  check(
    '工具条不再由鼠标悬停触发（用户要求别自动弹出）',
    !gamePage.contains('_toolbarVisible = true') &&
        gamePage.contains('if (_toolbarVisible)'),
  );
  check(
    '页面注入可聚焦输入框，把 CEF 的键盘通路激活',
    keyboardScript.contains('createElement("input")') &&
        keyboardScript.contains('.focus()') &&
        gamePage.contains('desktopKeyboardScript') &&
        gamePage.contains('setClientFocus(true)'),
  );
  // hlh.31 实机回归：旧脚本在 document.body 还不存在时就写了「已安装」标志，
  // 探针被解析器移走、焦点丢失后，loadEnd 的第二次注入被标志挡掉，
  // 键盘就再也没人引导。现在只有真的挂上并聚焦成功才算装完。
  check(
    '键盘引导不在 DOM 就绪前记「已安装」，每次注入都会补焦',
    !keyboardScript.contains('__gardendlessKeyboardReady') &&
        keyboardScript.contains('__gardendlessKeyboardPrimed') &&
        keyboardScript.contains('DOMContentLoaded') &&
        keyboardScript.contains(
          '!existed || !window.__gardendlessKeyboardPrimed',
        ),
  );
  check(
    '键盘引导状态写进 keyboard.log（安装状态 + 前 5 个 keydown）',
    keyboardScript.contains('keyboard:state') &&
        keyboardScript.contains('__gardendlessKeyboardKeyCount >= 5') &&
        gamePage.contains("payload['command'] == 'keyboard:state'") &&
        gamePage.contains('keyboard.log') &&
        gamePage.contains('getApplicationSupportDirectory'),
  );
  check(
    'loadEnd 后延迟再注入一次（引擎启动后会自己抢一次画布焦点）',
    gamePage.contains('_reinstallKeyboardLater') &&
        gamePage.contains('Duration(milliseconds: 1200)'),
  );
  // 浏览器还没拿到客户端焦点时，DOM 聚焦不一定触发 focusednode 上报。
  // 必须先 setClientFocus 再聚焦探针，并在 1.2s 后强制补一次。
  // webview_cef 把整条 lParam 当 native_key_code 交给 CEF，Chromium 算出的
  // event.code 可能为空；Cocos 的热键映射只认 code（绑在 #GameCanvas 上）。
  check(
    '按键校正：code 缺失或目标不是 GameCanvas 时重派发，且不重复',
    keyboardScript.contains('"GameCanvas"') &&
        keyboardScript.contains('new KeyboardEvent') &&
        keyboardScript.contains('stopImmediatePropagation') &&
        keyboardScript.contains('codeFromKeyCode') &&
        keyboardScript.contains('__gardendlessNormalized'),
  );
  check(
    '原始按键日志带 code/keyCode/target（判断是通道问题还是映射问题）',
    keyboardScript.contains('keyCode: event.keyCode') &&
        keyboardScript.contains('target: describe(event.target)'),
  );
  check(
    '初始化后按 1/3/6 秒补注入（initialize 可能早于页面创建）',
    gamePage.contains('_retryBridge') &&
        gamePage.contains('const [1, 3, 6]') &&
        gamePage.contains('desktop_bridge.log'),
  );
  check(
    '先给 CEF 客户端焦点，再聚焦探针；1.2s 后再 nudge 一次',
    gamePage.indexOf('setClientFocus(true)') <
            gamePage.indexOf('executeJavaScript(desktopKeyboardScript)') &&
        keyboardScript.contains('__gardendlessKeyboardNudge') &&
        gamePage.contains('__gardendlessKeyboardNudge'),
  );

  check(
    'Dart 侧只在 Windows 调通道（其它平台静默降级）',
    windowService.contains('Platform.isWindows') &&
        windowService.contains('MissingPluginException'),
  );

  check(
    '注入脚本改写 requestFullscreen/exitFullscreen',
    screenScript.contains('requestFullscreen') &&
        screenScript.contains('exitFullscreen') &&
        screenScript.contains('window:setFullscreen'),
  );
  check(
    '注入脚本伪造 fullscreenElement（否则第二次点是「进入」）',
    screenScript.contains('fullscreenElement') &&
        screenScript.contains('Document.prototype'),
  );
  check(
    '注入脚本保留宿主回灌入口',
    screenScript.contains('__gardendlessFullscreen') &&
        screenScript.contains('apply'),
  );
  check(
    '游戏页注册 JS 通道并注入脚本',
    gamePage.contains("'gardendlessDesktop'") &&
        gamePage.contains('JavascriptChannel') &&
        gamePage.contains('desktopFullscreenScript'),
  );
  check(
    '每次加载完成都重装桥（reload 会清掉 JS 通道）',
    RegExp(r'onLoadEnd:[\s\S]{0,400}?_installFullscreenBridge')
        .hasMatch(gamePage),
  );
  check(
    '工具栏有全屏按钮且状态跟真实窗口一致',
    gamePage.contains('enterFullscreen') &&
        gamePage.contains('exitFullscreen') &&
        gamePage.contains('_setFullscreen'),
  );
  check(
    '离开游戏页时退出全屏（否则加载器留在无边框全屏）',
    RegExp(r'void dispose\(\)[\s\S]{0,400}?setFullscreen\(false\)')
        .hasMatch(gamePage),
  );

  stdout.writeln('== Windows 自动更新启动链路（2026-10-27 实测回归）==');
  // 现象：点「退出并自动更新」后加载器消失，进度窗口没有，之后什么都没发生，
  // 重启还是旧版本。两条独立缺陷叠在一起：
  //  1. `ProcessStartMode.detached` 在 Windows 上会「成功返回 pid，但子进程
  //     根本不执行」——脚本连第一行日志都没写（同参数换普通模式立即正常，
  //     且父进程退出后子进程继续跑完）。
  //  2. Dart 的 `exit(0)` 硬终止进程时 CEF 线程还在跑，CRT teardown fail-fast
  //     （事件日志 0xc0000409 / ucrtbase.dll）。
  // 所以这里同时锁住「怎么启动脚本」和「怎么退出」。
  final updater = read('lib/src/services/windows_updater.dart');
  final applyBody = methodBody(controller, 'applyWindowsUpdate') ?? '';
  final quitBody = methodBody(controller, '_quitForUpdate') ?? '';

  check(
    '更新脚本由 WindowsUpdaterScript.start 启动（参数只有一份）',
    methodBody(updater, 'start') != null &&
        applyBody.contains('WindowsUpdaterScript.start('),
  );
  // 注意：不能对 `start({...})` 用 methodBody —— 它按第一个 `{` 配对，会把
  // 命名参数当成函数体。这里直接看整个文件（只有这一份启动实现）。
  check(
    '用普通模式启动（detached 在 Windows 上是空转）',
    updater.contains('mode: ProcessStartMode.normal') &&
        !applyBody.contains('ProcessStartMode.detached'),
  );
  check(
    'lib 里没有任何 mode: ProcessStartMode.detached',
    dartFilesUnder('lib').every((file) =>
        !file.readAsStringSync().contains('mode: ProcessStartMode.detached')),
    dartFilesUnder('lib')
        .where((file) =>
            file.readAsStringSync().contains('mode: ProcessStartMode.detached'))
        .map((file) => file.path)
        .join(','),
  );
  check(
    '关掉子进程 stdin 并读掉 stdout/stderr（否则写满管道会卡住）',
    updater.contains('stdin.close()') &&
        updater.contains('stdout.drain') &&
        updater.contains('stderr.drain'),
  );
  check(
    '退出前确认脚本还活着（秒退就当失败，不许静默消失）',
    applyBody.contains('process.exitCode') && applyBody.contains('更新脚本启动后立即退出'),
  );
  check(
    '退出走窗口通道 quit，而不是直接 exit(0)',
    applyBody.contains('_quitForUpdate()'),
  );
  check(
    'quit 失败才硬退，正常路径先关窗口',
    quitBody.contains('WindowService.instance.quit()') &&
        quitBody.indexOf('exit(0)') >
            quitBody.indexOf('WindowService.instance.quit()'),
  );
  check(
    'Dart 侧 quit 吞掉缺失通道（旧 runner 不会抛异常）',
    methodBody(windowService, 'quit') != null &&
        (methodBody(windowService, 'quit') ?? '')
            .contains('on MissingPluginException'),
  );
  check(
    '原生 quit 走 WM_CLOSE（让 runner 正常退出，别硬杀）',
    runner.contains('"quit"') &&
        RegExp(r'"quit"[\s\S]{0,400}?WM_CLOSE').hasMatch(runner),
  );

  // 脚本侧：退出期间必须自己给用户一个窗口，否则就是「点了就消失」。
  check(
    '更新脚本自带进度窗口（应用已退出，没人能显示进度）',
    updater.contains('Initialize-ProgressUi') &&
        updater.contains('System.Windows.Forms') &&
        updater.contains('DoEvents'),
  );
  check(
    '进度窗口可整体关闭（-NoUi，测试/无桌面环境）',
    updater.contains(r'[switch]$NoUi') &&
        RegExp(r'if \(\$NoUi\) \{ return \}').hasMatch(updater),
  );
  check(
    'UI 任何一步失败都只是没有窗口，不中断更新',
    updater.contains('progress ui unavailable'),
  );
  check(
    '等 robocopy 时泵消息（否则窗口十几秒无响应）',
    updater.contains('function Pump-Ui') &&
        RegExp(r'while \(-not \$process\.HasExited\)[\s\S]{0,120}?Pump-Ui')
            .hasMatch(updater),
  );
  // PS 5.1 的 Start-Process -PassThru（不带 -Wait）拿不到 ExitCode：null 会让
  // `$rc -ge 8` 恒为假，失败被当成成功（应用写出 applied 却没覆盖文件）。
  check(
    'robocopy 用 .NET Process 取真实退出码（Start-Process -PassThru 是 null）',
    updater.contains(r'$process.ExitCode') &&
        RegExp(r'\$info\.FileName = .robocopy\.exe.').hasMatch(updater) &&
        !updater.contains('robocopy -ArgumentList'),
  );
  check(
    '每条失败路径都先关掉进度窗口再重启加载器',
    _everyRelaunchClosesUi(updater),
  );

  stdout.writeln('');
  stdout.writeln('结果：$passed 通过 / $failed 失败');
  if (failed > 0) exitCode = 1;
}
