# vendored `webview_cef`（仅 Windows 用）

来源：pub.dev `webview_cef` **0.6.2**（`https://github.com/hlwhl/webview_cef`）。
整个包原样拷贝，只改了一处：`windows/webview_cef_plugin.cpp` 的 vsync 线程。

## 改了什么

上游的 external BeginFrame 线程用 `EnumAdapters1(0)` + `EnumOutputs(0)` 等
vblank，也就是「第 0 个适配器的第 0 个输出」。多显卡、虚拟显示器、远程桌面
（GameViewer / 向日葵 / RDP）下，这不一定就是窗口所在的那块屏：

- 实机案例：窗口在 1024×768 虚拟显示器上，0/0 却是 NVIDIA 的 2560×1440@179
  ——BeginFrame 按 179 Hz 发，实际显示 60 Hz，帧节奏对不上，表现为轻微抖动。
- 另一类：虚拟显示器没有 DXGI output，上游会一直拿不到 output，退回 60 Hz；
  但现在至少是按窗口所在显示器判断，而不是碰运气。

现在改为：

1. `PickVsyncWindow()` 选前台窗口（其次第一个可见窗口）作为节奏源；
2. `MonitorFromWindow()` 得到 HMONITOR，`AcquireDxgiOutputForMonitor()` 遍历
   所有适配器/输出，按 `DXGI_OUTPUT_DESC.Monitor` 精确匹配；
3. 窗口换屏时自动重取（每帧比较 monitor，变化才重新枚举）；
4. 找不到 output 时用该显示器自己的刷新率（`EnumDisplaySettings` 的
   `szDevice`）兜底，而不是主屏刷新率；
5. 窗口最小化（`IsIconic`）时不再发 `BeginFrame`：没有可见像素要更新，
   继续按刷新率唤醒只是白烧 GPU/CPU；恢复后下一拍自动继续。

## 升级上游时

把新版本整包拷进来，然后按上面的 1–4 重新打一遍 `VsyncThreadProc` 附近的补丁。
`common/` 和 `lib/` 没有改动；其余平台目录保持原样，避免 `pub get` 的平台声明
缺文件。
