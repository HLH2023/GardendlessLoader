#include "gpu_preference.h"

#include <windows.h>

#include <d3d11.h>
#include <dxgi1_6.h>
#include <wrl/client.h>

#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <cwchar>
#include <iterator>
#include <set>
#include <string>
#include <utility>
#include <vector>

namespace gpu {
namespace {

using Microsoft::WRL::ComPtr;

// 本程序自己的偏好镜像。Windows 的 UserGpuPreferences 只记「当前 exe 的
// 生效值」，没有「下次启动要还原成什么」的信息；一次性选择（不记住）需要
// 额外一层状态，否则临时选的独显会永远留在系统设置里。
constexpr wchar_t kAppKey[] =
    L"Software\\io.github.dey410\\GardendlessLoader";
constexpr wchar_t kDesiredValue[] = L"GpuPreference";
constexpr wchar_t kPendingValue[] = L"PendingGpuPreference";
constexpr wchar_t kPreviousValue[] = L"PreviousGpuPreference";
constexpr wchar_t kPreviousExistsValue[] = L"PreviousGpuPreferenceExists";
constexpr wchar_t kRestoreValue[] = L"RestorePreviousGpuPreference";

// Windows 10 1803+ 的「图形性能首选项」。值名是 exe 全路径，数据是
// `GpuPreference=2;`（1=节能，2=高性能，0/缺省=由 Windows 决定）。
// 注意：这里和 DXGI_GPU_PREFERENCE_* 的数值一致，但 1/2 的顺序容易记反。
constexpr wchar_t kUserGpuKey[] =
    L"Software\\Microsoft\\DirectX\\UserGpuPreferences";

std::wstring Trim(const std::wstring& value) {
  const size_t first = value.find_first_not_of(L" \t\r\n");
  if (first == std::wstring::npos) return L"";
  const size_t last = value.find_last_not_of(L" \t\r\n");
  return value.substr(first, last - first + 1);
}

std::wstring CurrentExePath() {
  std::vector<wchar_t> buffer(32768);
  const DWORD length = ::GetModuleFileNameW(
      nullptr, buffer.data(), static_cast<DWORD>(buffer.size()));
  if (length == 0 || length >= buffer.size()) return L"";
  return std::wstring(buffer.data(), length);
}

bool ReadString(HKEY root, const wchar_t* subkey, const wchar_t* name,
                std::wstring* out) {
  HKEY key = nullptr;
  if (::RegOpenKeyExW(root, subkey, 0, KEY_READ, &key) != ERROR_SUCCESS) {
    return false;
  }
  DWORD type = 0;
  DWORD size = 0;
  LONG result =
      ::RegQueryValueExW(key, name, nullptr, &type, nullptr, &size);
  if (result != ERROR_SUCCESS ||
      (type != REG_SZ && type != REG_EXPAND_SZ)) {
    ::RegCloseKey(key);
    return false;
  }
  std::vector<wchar_t> buffer(size / sizeof(wchar_t) + 1, L'\0');
  result = ::RegQueryValueExW(key, name, nullptr, &type,
                              reinterpret_cast<LPBYTE>(buffer.data()), &size);
  ::RegCloseKey(key);
  if (result != ERROR_SUCCESS) return false;
  *out = std::wstring(buffer.data());
  return true;
}

bool WriteString(HKEY root, const wchar_t* subkey, const wchar_t* name,
                 const std::wstring& value) {
  HKEY key = nullptr;
  if (::RegCreateKeyExW(root, subkey, 0, nullptr, 0, KEY_SET_VALUE, nullptr,
                        &key, nullptr) != ERROR_SUCCESS) {
    return false;
  }
  const DWORD bytes =
      static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t));
  const LONG result = ::RegSetValueExW(
      key, name, 0, REG_SZ,
      reinterpret_cast<const BYTE*>(value.c_str()), bytes);
  ::RegCloseKey(key);
  return result == ERROR_SUCCESS;
}

bool WriteDword(HKEY root, const wchar_t* subkey, const wchar_t* name,
                DWORD value) {
  HKEY key = nullptr;
  if (::RegCreateKeyExW(root, subkey, 0, nullptr, 0, KEY_SET_VALUE, nullptr,
                        &key, nullptr) != ERROR_SUCCESS) {
    return false;
  }
  const LONG result = ::RegSetValueExW(
      key, name, 0, REG_DWORD, reinterpret_cast<const BYTE*>(&value),
      sizeof(value));
  ::RegCloseKey(key);
  return result == ERROR_SUCCESS;
}

DWORD ReadDword(HKEY root, const wchar_t* subkey, const wchar_t* name,
                DWORD fallback) {
  HKEY key = nullptr;
  if (::RegOpenKeyExW(root, subkey, 0, KEY_READ, &key) != ERROR_SUCCESS) {
    return fallback;
  }
  DWORD type = 0;
  DWORD value = fallback;
  DWORD size = sizeof(value);
  const LONG result = ::RegQueryValueExW(
      key, name, nullptr, &type, reinterpret_cast<LPBYTE>(&value), &size);
  ::RegCloseKey(key);
  if (result != ERROR_SUCCESS || type != REG_DWORD) return fallback;
  return value;
}

void DeleteValue(HKEY root, const wchar_t* subkey, const wchar_t* name) {
  HKEY key = nullptr;
  if (::RegOpenKeyExW(root, subkey, 0, KEY_SET_VALUE, &key) !=
      ERROR_SUCCESS) {
    return;
  }
  ::RegDeleteValueW(key, name);
  ::RegCloseKey(key);
}

// 把 `GpuPreference=` 字段从 Windows 的偏好字符串里替换/移除，保留其它
// 字段（例如显卡驱动或系统写入的 SwapEffectUpgradeEnable）。
std::wstring SetGpuPreferenceField(const std::wstring& raw, int value) {
  std::vector<std::wstring> fields;
  size_t start = 0;
  while (start < raw.size()) {
    const size_t end = raw.find(L';', start);
    fields.push_back(raw.substr(
        start, end == std::wstring::npos ? std::wstring::npos : end - start));
    if (end == std::wstring::npos) break;
    start = end + 1;
  }
  std::wstring result;
  bool replaced = false;
  for (const std::wstring& field : fields) {
    const std::wstring trimmed = Trim(field);
    if (trimmed.rfind(L"GpuPreference=", 0) == 0) {
      if (value != 0) {
        result += L"GpuPreference=" + std::to_wstring(value) + L";";
        replaced = true;
      }
    } else if (!trimmed.empty()) {
      result += trimmed + L";";
    }
  }
  if (value != 0 && !replaced) {
    result += L"GpuPreference=" + std::to_wstring(value) + L";";
  }
  return result;
}

int PreferenceRegistryValue(Preference preference) {
  switch (preference) {
    case Preference::kHighPerformance:
      return 2;
    case Preference::kPowerSaving:
      return 1;
    case Preference::kAutomatic:
      return 0;
  }
  return 0;
}

void ApplyUserGpuPreference(Preference preference) {
  const std::wstring exe = CurrentExePath();
  if (exe.empty()) return;
  std::wstring raw;
  const bool exists =
      ReadString(HKEY_CURRENT_USER, kUserGpuKey, exe.c_str(), &raw);
  const std::wstring updated =
      SetGpuPreferenceField(exists ? raw : L"",
                            PreferenceRegistryValue(preference));
  if (updated.empty()) {
    DeleteValue(HKEY_CURRENT_USER, kUserGpuKey, exe.c_str());
  } else {
    WriteString(HKEY_CURRENT_USER, kUserGpuKey, exe.c_str(), updated);
  }
}

std::string Narrow(const std::wstring& value) {
  if (value.empty()) return std::string();
  const int size = ::WideCharToMultiByte(CP_UTF8, 0, value.c_str(),
                                         static_cast<int>(value.size()),
                                         nullptr, 0, nullptr, nullptr);
  std::string result(size, '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, value.c_str(),
                        static_cast<int>(value.size()), result.data(), size,
                        nullptr, nullptr);
  return result;
}

bool SameLuid(const LUID& left, const LUID& right) {
  return left.HighPart == right.HighPart && left.LowPart == right.LowPart;
}

bool ReadAdapterLuid(IDXGIFactory6* factory, DXGI_GPU_PREFERENCE preference,
                     LUID* out) {
  if (factory == nullptr) return false;
  ComPtr<IDXGIAdapter> adapter;
  if (FAILED(factory->EnumAdapterByGpuPreference(0, preference,
                                                 IID_PPV_ARGS(&adapter))) ||
      adapter == nullptr) {
    return false;
  }
  ComPtr<IDXGIAdapter1> adapter1;
  if (FAILED(adapter.As(&adapter1)) || adapter1 == nullptr) return false;
  DXGI_ADAPTER_DESC1 desc = {};
  if (FAILED(adapter1->GetDesc1(&desc))) return false;
  *out = desc.AdapterLuid;
  return true;
}

}  // namespace

std::string PreferenceName(Preference preference) {
  switch (preference) {
    case Preference::kHighPerformance:
      return "highPerformance";
    case Preference::kPowerSaving:
      return "powerSaving";
    case Preference::kAutomatic:
      return "automatic";
  }
  return "automatic";
}

bool PreferenceFromName(const std::string& name, Preference* out) {
  if (name == "highPerformance") {
    *out = Preference::kHighPerformance;
    return true;
  }
  if (name == "powerSaving") {
    *out = Preference::kPowerSaving;
    return true;
  }
  if (name == "automatic") {
    *out = Preference::kAutomatic;
    return true;
  }
  return false;
}

std::vector<AdapterInfo> ListAdapters() {
  std::vector<AdapterInfo> adapters;
  ComPtr<IDXGIFactory1> factory;
  if (FAILED(::CreateDXGIFactory1(IID_PPV_ARGS(&factory))) ||
      factory == nullptr) {
    return adapters;
  }

  LUID high_luid = {};
  LUID min_luid = {};
  bool has_high = false;
  bool has_min = false;
  ComPtr<IDXGIFactory6> factory6;
  if (SUCCEEDED(factory.As(&factory6)) && factory6 != nullptr) {
    has_high = ReadAdapterLuid(factory6.Get(),
                               DXGI_GPU_PREFERENCE_HIGH_PERFORMANCE, &high_luid);
    has_min = ReadAdapterLuid(factory6.Get(),
                              DXGI_GPU_PREFERENCE_MINIMUM_POWER, &min_luid);
  }

  std::set<std::pair<LONG, DWORD>> seen_luids;
  std::set<std::wstring> seen_names;
  for (UINT index = 0;; ++index) {
    ComPtr<IDXGIAdapter1> adapter;
    if (factory->EnumAdapters1(index, adapter.GetAddressOf()) ==
        DXGI_ERROR_NOT_FOUND) {
      break;
    }
    if (adapter == nullptr) continue;
    DXGI_ADAPTER_DESC1 desc = {};
    if (FAILED(adapter->GetDesc1(&desc))) continue;

    if (!seen_luids
             .insert(std::make_pair(desc.AdapterLuid.HighPart,
                                    desc.AdapterLuid.LowPart))
             .second) {
      continue;
    }
    // 部分 Win10 版本会把同一块物理显卡枚举两次，LUID 还不同；用描述去重，
    // 避免设置页出现两个一模一样的名字。
    std::wstring duplicate_key = std::wstring(desc.Description) + L"|" +
                                 std::to_wstring(desc.VendorId) + L"|" +
                                 std::to_wstring(desc.DeviceId) + L"|" +
                                 std::to_wstring(desc.SubSysId) + L"|" +
                                 std::to_wstring(desc.DedicatedVideoMemory);
    if (!seen_names.insert(duplicate_key).second) continue;

    AdapterInfo info;
    info.name = desc.Description;
    info.vendor_id = desc.VendorId;
    info.device_id = desc.DeviceId;
    info.subsys_id = desc.SubSysId;
    info.revision = desc.Revision;
    info.dedicated_video_memory = desc.DedicatedVideoMemory;
    info.luid_high = desc.AdapterLuid.HighPart;
    info.luid_low = desc.AdapterLuid.LowPart;
    info.software = (desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) != 0;
    info.high_performance = has_high && SameLuid(desc.AdapterLuid, high_luid);
    info.minimum_power = has_min && SameLuid(desc.AdapterLuid, min_luid);
    adapters.push_back(info);
  }

  // 没有 IDXGIFactory6（Win10 1803 之前）时按显存做保底判断：多数情况下
  // 独显显存更大、核显更小。
  if (!has_high || !has_min) {
    const AdapterInfo* high = nullptr;
    const AdapterInfo* low = nullptr;
    for (const AdapterInfo& info : adapters) {
      if (info.software) continue;
      if (high == nullptr ||
          info.dedicated_video_memory > high->dedicated_video_memory) {
        high = &info;
      }
      if (low == nullptr ||
          info.dedicated_video_memory < low->dedicated_video_memory) {
        low = &info;
      }
    }
    for (AdapterInfo& info : adapters) {
      if (!has_high && high != nullptr && &info == high) {
        info.high_performance = true;
      }
      if (!has_min && low != nullptr && &info == low) {
        info.minimum_power = true;
      }
    }
  }

  const bool has_hardware =
      std::any_of(adapters.begin(), adapters.end(),
                  [](const AdapterInfo& info) { return !info.software; });
  if (has_hardware) {
    adapters.erase(
        std::remove_if(adapters.begin(), adapters.end(),
                       [](const AdapterInfo& info) { return info.software; }),
        adapters.end());
  }

  std::stable_sort(adapters.begin(), adapters.end(),
                   [](const AdapterInfo& left, const AdapterInfo& right) {
                     return left.high_performance && !right.high_performance;
                   });
  return adapters;
}

flutter::EncodableValue AdapterToEncodable(const AdapterInfo& info) {
  flutter::EncodableMap map;
  map[flutter::EncodableValue("name")] =
      flutter::EncodableValue(Narrow(info.name));
  map[flutter::EncodableValue("vendorId")] =
      flutter::EncodableValue(static_cast<int32_t>(info.vendor_id));
  map[flutter::EncodableValue("deviceId")] =
      flutter::EncodableValue(static_cast<int32_t>(info.device_id));
  map[flutter::EncodableValue("subSysId")] =
      flutter::EncodableValue(static_cast<int32_t>(info.subsys_id));
  map[flutter::EncodableValue("revision")] =
      flutter::EncodableValue(static_cast<int32_t>(info.revision));
  map[flutter::EncodableValue("dedicatedVideoMemory")] =
      flutter::EncodableValue(
          static_cast<int64_t>(info.dedicated_video_memory));
  map[flutter::EncodableValue("luidHigh")] =
      flutter::EncodableValue(static_cast<int32_t>(info.luid_high));
  map[flutter::EncodableValue("luidLow")] =
      flutter::EncodableValue(static_cast<int64_t>(info.luid_low));
  map[flutter::EncodableValue("software")] =
      flutter::EncodableValue(info.software);
  map[flutter::EncodableValue("highPerformance")] =
      flutter::EncodableValue(info.high_performance);
  map[flutter::EncodableValue("minimumPower")] =
      flutter::EncodableValue(info.minimum_power);
  return flutter::EncodableValue(map);
}

flutter::EncodableValue AdaptersToEncodable(
    const std::vector<AdapterInfo>& adapters) {
  flutter::EncodableList list;
  for (const AdapterInfo& info : adapters) {
    list.emplace_back(AdapterToEncodable(info));
  }
  return flutter::EncodableValue(list);
}

AdapterInfo ActiveAdapter() {
  AdapterInfo info;
  ComPtr<ID3D11Device> device;
  ComPtr<ID3D11DeviceContext> context;
  const D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_1,
                                      D3D_FEATURE_LEVEL_11_0};
  const HRESULT created = ::D3D11CreateDevice(
      nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
      D3D11_CREATE_DEVICE_BGRA_SUPPORT, levels,
      static_cast<UINT>(ARRAYSIZE(levels)), D3D11_SDK_VERSION,
      device.GetAddressOf(), nullptr, context.GetAddressOf());
  if (FAILED(created) || device == nullptr) return info;

  ComPtr<IDXGIDevice> dxgi_device;
  if (FAILED(device.As(&dxgi_device)) || dxgi_device == nullptr) return info;
  ComPtr<IDXGIAdapter> adapter;
  if (FAILED(dxgi_device->GetAdapter(adapter.GetAddressOf())) ||
      adapter == nullptr) {
    return info;
  }
  DXGI_ADAPTER_DESC desc = {};
  if (FAILED(adapter->GetDesc(&desc))) return info;

  info.name = desc.Description;
  info.vendor_id = desc.VendorId;
  info.device_id = desc.DeviceId;
  info.subsys_id = desc.SubSysId;
  info.revision = desc.Revision;
  info.dedicated_video_memory = desc.DedicatedVideoMemory;
  info.luid_high = desc.AdapterLuid.HighPart;
  info.luid_low = desc.AdapterLuid.LowPart;
  return info;
}

Preference ReadCurrentPreference() {
  const std::wstring exe = CurrentExePath();
  if (exe.empty()) return Preference::kAutomatic;
  std::wstring raw;
  if (!ReadString(HKEY_CURRENT_USER, kUserGpuKey, exe.c_str(), &raw)) {
    return Preference::kAutomatic;
  }
  size_t start = 0;
  while (start <= raw.size()) {
    const size_t end = raw.find(L';', start);
    const std::wstring field = Trim(raw.substr(
        start, end == std::wstring::npos ? std::wstring::npos : end - start));
    if (field.rfind(L"GpuPreference=", 0) == 0) {
      const int value =
          static_cast<int>(::wcstol(field.c_str() + 14, nullptr, 10));
      if (value == 2) return Preference::kHighPerformance;
      if (value == 1) return Preference::kPowerSaving;
      return Preference::kAutomatic;
    }
    if (end == std::wstring::npos) break;
    start = end + 1;
  }
  return Preference::kAutomatic;
}

bool SetPreference(Preference preference, bool remember) {
  bool ok = true;
  if (!remember) {
    // 只在第一次临时选择时保存原始值；连续改选、或已经处于一次性的
    // 临时会话（Restore=1）里，都不应把「原始值」覆盖成上一次的临时值。
    std::wstring pending;
    const bool has_pending =
        ReadString(HKEY_CURRENT_USER, kAppKey, kPendingValue, &pending);
    const bool is_restoring =
        ReadDword(HKEY_CURRENT_USER, kAppKey, kRestoreValue, 0) != 0;
    if (!has_pending && !is_restoring) {
      const std::wstring exe = CurrentExePath();
      std::wstring previous;
      const bool previous_exists =
          !exe.empty() &&
          ReadString(HKEY_CURRENT_USER, kUserGpuKey, exe.c_str(), &previous);
      ok = WriteString(HKEY_CURRENT_USER, kAppKey, kPreviousValue,
                       previous_exists ? previous : L"") &&
           ok;
      ok = WriteDword(HKEY_CURRENT_USER, kAppKey, kPreviousExistsValue,
                      previous_exists ? 1 : 0) &&
           ok;
      ok = WriteDword(HKEY_CURRENT_USER, kAppKey, kRestoreValue, 1) && ok;
    }
    const std::string pending_name = PreferenceName(preference);
    ok = WriteString(HKEY_CURRENT_USER, kAppKey, kPendingValue,
                     std::wstring(pending_name.begin(), pending_name.end())) &&
         ok;
  } else {
    const std::string name = PreferenceName(preference);
    ok = WriteString(HKEY_CURRENT_USER, kAppKey, kDesiredValue,
                     std::wstring(name.begin(), name.end())) &&
         ok;
    DeleteValue(HKEY_CURRENT_USER, kAppKey, kPendingValue);
    DeleteValue(HKEY_CURRENT_USER, kAppKey, kPreviousValue);
    DeleteValue(HKEY_CURRENT_USER, kAppKey, kPreviousExistsValue);
    DeleteValue(HKEY_CURRENT_USER, kAppKey, kRestoreValue);
  }
  // 关键：这里**不能**立刻改 Windows 的 UserGpuPreferences。
  // 当前 Flutter 引擎已经按进程启动时的偏好建好了 D3D 设备；此时改注册表，
  // 随后才启动的 CEF GPU 进程会单独换到新显卡，两边共享纹理打不开，游戏黑屏。
  // 新值只写进本程序的镜像，由 ApplyStartupPreference 在**下一次进程启动**、
  // Flutter 引擎创建之前应用。
  return ok;
}

void ApplyStartupPreference() {
  // 顺序很重要：一次性的临时选择优先于记住的值；临时选择用完就删，
  // 下一次启动走「记住的值」或「还原到选择前」。
  std::wstring pending;
  if (ReadString(HKEY_CURRENT_USER, kAppKey, kPendingValue, &pending)) {
    Preference preference = Preference::kAutomatic;
    PreferenceFromName(Narrow(pending), &preference);
    // 先立还原标记再应用：任意一步崩溃，下一次启动仍能走还原路径。
    WriteDword(HKEY_CURRENT_USER, kAppKey, kRestoreValue, 1);
    ApplyUserGpuPreference(preference);
    DeleteValue(HKEY_CURRENT_USER, kAppKey, kPendingValue);
    return;
  }

  std::wstring desired;
  if (ReadString(HKEY_CURRENT_USER, kAppKey, kDesiredValue, &desired)) {
    Preference preference = Preference::kAutomatic;
    PreferenceFromName(Narrow(desired), &preference);
    ApplyUserGpuPreference(preference);
    DeleteValue(HKEY_CURRENT_USER, kAppKey, kRestoreValue);
    DeleteValue(HKEY_CURRENT_USER, kAppKey, kPreviousValue);
    DeleteValue(HKEY_CURRENT_USER, kAppKey, kPreviousExistsValue);
    return;
  }

  if (ReadDword(HKEY_CURRENT_USER, kAppKey, kRestoreValue, 0) == 0) {
    return;
  }
  const std::wstring exe = CurrentExePath();
  std::wstring previous;
  const bool previous_exists =
      ReadDword(HKEY_CURRENT_USER, kAppKey, kPreviousExistsValue, 0) != 0 &&
      ReadString(HKEY_CURRENT_USER, kAppKey, kPreviousValue, &previous);
  if (previous_exists) {
    WriteString(HKEY_CURRENT_USER, kUserGpuKey, exe.c_str(), previous);
  } else if (!exe.empty()) {
    DeleteValue(HKEY_CURRENT_USER, kUserGpuKey, exe.c_str());
  }
  DeleteValue(HKEY_CURRENT_USER, kAppKey, kRestoreValue);
  DeleteValue(HKEY_CURRENT_USER, kAppKey, kPreviousValue);
  DeleteValue(HKEY_CURRENT_USER, kAppKey, kPreviousExistsValue);
}

}  // namespace gpu
