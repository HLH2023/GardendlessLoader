// CEF 日志硬上限。
//
// 为什么需要：CEF 默认把日志写到工作目录（通常是 exe 所在目录）的
// debug.log，且没有大小上限。程序界面起不来、Chromium 在后台反复报同一个
// 错误时，这个文件会无限增长——2026-10-25 实机留下了一个 250 GB 的
// debug.log，直接把系统盘写满。
//
// 为什么能改写 CEF 正持有的文件：Chromium 以 FILE_SHARE_READ | WRITE |
// DELETE 打开日志，Windows 允许另一个句柄 SetEndOfFile；写入方是追加模式，
// 裁剪后下一次写从 0 开始。实机验证过：运行中裁剪成功，文件从 0 重新增长。
//
// 为什么不用 --log-severity=disable：webview_cef 在插件内部固定
// CefSettings，没有暴露开关；改命令行需要给进程加参数，双击启动时做不到。
// 保留日志对排查界面问题有用，所以选择「限量」而不是「关闭」。

#include "cef_log_limit.h"

#include <windows.h>

#include <chrono>
#include <string>
#include <thread>
#include <vector>

namespace {

// 32 MB 足够保留最近几十分钟的 CEF 日志；超过就清空。
constexpr unsigned long long kMaxBytes = 32ull * 1024ull * 1024ull;
constexpr auto kTrimInterval = std::chrono::seconds(15);

std::wstring ExeDirectory() {
  wchar_t buffer[MAX_PATH] = {0};
  const DWORD length = GetModuleFileNameW(nullptr, buffer, MAX_PATH);
  if (length == 0 || length >= MAX_PATH) return std::wstring();
  std::wstring path(buffer, length);
  const std::wstring::size_type slash = path.find_last_of(L"\\/");
  if (slash == std::wstring::npos) return std::wstring();
  return path.substr(0, slash + 1);
}

// CEF 的日志落在「工作目录」，而工作目录不一定是 exe 目录（例如从 IDE 或
// 终端启动时是项目根目录）。两处都检查，去重后逐个裁剪。
std::vector<std::wstring> LogCandidates() {
  std::vector<std::wstring> candidates;
  const std::wstring exe_dir = ExeDirectory();
  if (!exe_dir.empty()) candidates.push_back(exe_dir + L"debug.log");

  wchar_t cwd[MAX_PATH] = {0};
  const DWORD cwd_length = GetCurrentDirectoryW(MAX_PATH, cwd);
  if (cwd_length > 0 && cwd_length < MAX_PATH) {
    std::wstring in_cwd(cwd, cwd_length);
    in_cwd += L"\\debug.log";
    bool duplicate = false;
    for (const std::wstring& item : candidates) {
      if (_wcsicmp(item.c_str(), in_cwd.c_str()) == 0) {
        duplicate = true;
        break;
      }
    }
    if (!duplicate) candidates.push_back(in_cwd);
  }
  return candidates;
}

void TrimOne(const std::wstring& path) {
  // 必须带 FILE_SHARE_WRITE/DELETE，否则 CEF 持有句柄时这里打不开。
  HANDLE handle = CreateFileW(path.c_str(), GENERIC_WRITE,
                              FILE_SHARE_READ | FILE_SHARE_WRITE |
                                  FILE_SHARE_DELETE,
                              nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL,
                              nullptr);
  if (handle == INVALID_HANDLE_VALUE) return;
  LARGE_INTEGER size = {};
  if (GetFileSizeEx(handle, &size) &&
      size.QuadPart > static_cast<LONGLONG>(kMaxBytes)) {
    LARGE_INTEGER origin = {};
    if (SetFilePointerEx(handle, origin, nullptr, FILE_BEGIN)) {
      SetEndOfFile(handle);
    }
  }
  CloseHandle(handle);
}

void TrimAll() {
  for (const std::wstring& path : LogCandidates()) TrimOne(path);
}

}  // namespace

void StartCefLogLimit() {
  TrimAll();
  std::thread([] {
    for (;;) {
      std::this_thread::sleep_for(kTrimInterval);
      TrimAll();
    }
  }).detach();
}
