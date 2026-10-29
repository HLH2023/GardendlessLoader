#ifndef RUNNER_GPU_PREFERENCE_H_
#define RUNNER_GPU_PREFERENCE_H_

#include <flutter/encodable_value.h>

#include <string>
#include <vector>

namespace gpu {

// Windows 的「图形性能首选项」只有三档：让 Windows 决定、高性能、节能。
// 真正按显卡名选择需要 DXGI 的 LUID，并把 LUID 传给每个渲染进程；Flutter
// 引擎的 ANGLE 设备不接受这个开关，所以只能走系统级偏好，让 Flutter 和
// CEF 在进程启动时一起选到同一块显卡。详见 docs/07-backlog.md B-83。
enum class Preference {
  kAutomatic,
  kHighPerformance,
  kPowerSaving,
};

struct AdapterInfo {
  std::wstring name;
  uint32_t vendor_id = 0;
  uint32_t device_id = 0;
  uint32_t subsys_id = 0;
  uint32_t revision = 0;
  uint64_t dedicated_video_memory = 0;
  int32_t luid_high = 0;
  uint32_t luid_low = 0;
  bool software = false;
  bool high_performance = false;
  bool minimum_power = false;
};

std::vector<AdapterInfo> ListAdapters();
flutter::EncodableValue AdaptersToEncodable(
    const std::vector<AdapterInfo>& adapters);

// 当前进程默认会用的显卡（D3D11CreateDevice(nullptr) + GetAdapter）。
// 用来在设置页显示「重启后到底有没有换过去」，也是没法在 Linux 上跑
// Windows 时的唯一现场证据。
AdapterInfo ActiveAdapter();
flutter::EncodableValue AdapterToEncodable(const AdapterInfo& adapter);

// 读取当前 exe 在 HKCU\...\DirectX\UserGpuPreferences 里的实际值。
Preference ReadCurrentPreference();

// 用户显式选择：把偏好写进本程序的镜像，记住/一次性两种语义都在这里
// 落盘。**不直接改 Windows 的 UserGpuPreferences**：当前 Flutter 已经
// 建好设备，立刻改只会让随后启动的 CEF 单独换卡。实际应用由
// ApplyStartupPreference 在下一次进程启动、Flutter 引擎创建之前完成。
// 返回镜像是否写入成功。
bool SetPreference(Preference preference, bool remember);

// 必须在 Flutter 窗口/引擎创建之前调用：把记住的或一次性的偏好应用给
// 当前 exe。Windows 在进程第一次创建 DXGI 设备时读取该偏好，所以时机
// 早于 Flutter 才能让加载器自身和 CEF 用到同一块显卡。
void ApplyStartupPreference();

std::string PreferenceName(Preference preference);
bool PreferenceFromName(const std::string& name, Preference* out);

}  // namespace gpu

#endif  // RUNNER_GPU_PREFERENCE_H_
