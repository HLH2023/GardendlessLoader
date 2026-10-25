# 在 Windows 构建机上安装 Flutter SDK + VS2022 C++ 工具链（幂等）
#
# 由 NBPC 通过 `ssh win "powershell -NoProfile -File C:\Users\s2681\install-toolchain.ps1"` 调用。
# SSH 会话已是管理员（实测 IsAdmin=True），因此 VS 安装可以静默进行。

$ErrorActionPreference = "Continue"
$log = "C:\Users\s2681\toolchain-install.log"
function Log($msg) {
    $line = "$(Get-Date -Format 'HH:mm:ss') $msg"
    Write-Host $line
    Add-Content -Path $log -Value $line -Encoding utf8
}

Log "=== 工具链安装开始 ==="

# ---------- 1. Flutter SDK ----------
$flutterRoot = "C:\src\flutter"
$flutterExe = Join-Path $flutterRoot "bin\flutter.bat"
if (Test-Path $flutterExe) {
    Log "Flutter 已存在，跳过解压：$flutterRoot"
} else {
    $zip = "C:\Users\s2681\Downloads\flutter_windows_3.41.9-stable.zip"
    if (-not (Test-Path $zip)) { Log "缺少 $zip"; exit 1 }
    Log "解压 Flutter SDK（1.8GB，约 3-5 分钟）..."
    New-Item -ItemType Directory -Force -Path "C:\src" | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, "C:\src")
    Log "解压完成：$(Test-Path $flutterExe)"
}

# PATH：当前会话 + 用户级持久化
$env:Path = "$flutterRoot\bin;" + $env:Path
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($userPath -notlike "*$flutterRoot\bin*") {
    [Environment]::SetEnvironmentVariable("Path", "$flutterRoot\bin;$userPath", "User")
    Log "已把 Flutter 写入用户 PATH"
}

# ---------- 2. VS2022 Build Tools（Desktop C++）----------
$vswhere = "C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe"
$hasCpp = $false
if (Test-Path $vswhere) {
    $found = & $vswhere -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null
    if ($found) { $hasCpp = $true; Log "已装 C++ 工具链：$found" }
}
if ($hasCpp) {
    Log "VS C++ 工具链已存在，跳过安装"
} else {
    $bootstrapper = "C:\Users\s2681\Downloads\vs_buildtools.exe"
    if (-not (Test-Path $bootstrapper)) { Log "缺少 $bootstrapper"; exit 1 }
    Log "开始静默安装 VS2022 Build Tools + VCTools（通常 20-40 分钟）..."
    $args = @(
        "--quiet", "--wait", "--norestart", "--nocache",
        "--installPath", "C:\BuildTools",
        "--add", "Microsoft.VisualStudio.Workload.VCTools",
        "--includeRecommended"
    )
    $proc = Start-Process -FilePath $bootstrapper -ArgumentList $args -PassThru -Wait
    Log "VS 安装结束，退出码：$($proc.ExitCode)（0/3010 为成功）"
    if (Test-Path $vswhere) {
        $found = & $vswhere -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null
        Log "安装后检测 C++ 工具链：$found"
    }
}

# ---------- 3. Flutter 桌面配置 + doctor ----------
Log "启用 Windows 桌面支持..."
& $flutterExe config --enable-windows-desktop 2>&1 | ForEach-Object { Log $_ }

Log "flutter doctor（桌面相关）..."
& $flutterExe doctor -v 2>&1 | Select-String -Pattern "Flutter version|Windows Version|Visual Studio|Windows (desktop|SDK)|CMake" | ForEach-Object { Log $_ }

Log "=== 工具链安装结束 ==="
