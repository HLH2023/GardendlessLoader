# Windows 端构建脚本（在 Windows 构建机上执行）
#
# 前置（一次性）：
#   1. Flutter SDK（3.41.x，与 Linux/CI 对齐）解压到 C:\src\flutter，PATH 里有 flutter
#   2. Visual Studio 2022 Build Tools + "Desktop development with C++" 工作负载
#   3. Git（拉代码）
#   4. 首次构建会自动下载 ~330MB CEF 并编译 libcef_dll_wrapper（耗时较长）
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File tools\build-windows.ps1
#   powershell -ExecutionPolicy Bypass -File tools\build-windows.ps1 -Server https://example.com
#
# -Server 会以 --dart-define=PVZGE_SERVER 注入服务器地址（源码里没有任何域名）。

param(
    [string]$Server = "",
    [string]$OutDir = ""
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $repo

Write-Host "== 环境检查 ==" -ForegroundColor Cyan
flutter --version
if ($LASTEXITCODE -ne 0) { throw "找不到 flutter：把 Flutter SDK 的 bin 加到 PATH" }

Write-Host "== flutter doctor（桌面工具链）==" -ForegroundColor Cyan
flutter doctor -v | Select-String -Pattern "Visual Studio|Windows Version|Flutter version" -Context 0,2

Write-Host "== 依赖 ==" -ForegroundColor Cyan
flutter pub get
if ($LASTEXITCODE -ne 0) { throw "flutter pub get 失败" }

$defines = @()
if ($Server -ne "") {
    $defines += "--dart-define=PVZGE_SERVER=$Server"
    Write-Host "注入服务器地址：$Server"
} else {
    Write-Warning "未传 -Server：构建出的客户端需要在设置页里手填服务器地址"
}

Write-Host "== 构建 release ==" -ForegroundColor Cyan
flutter build windows --release @defines
if ($LASTEXITCODE -ne 0) { throw "flutter build windows 失败" }

$release = "build\windows\x64\runner\Release"
if (-not (Test-Path $release)) { throw "找不到产物目录 $release" }

$version = (Select-String -Path "pubspec.yaml" -Pattern '^version:\s*(\S+)').Matches[0].Groups[1].Value
$safeVersion = $version -replace '[+]', '-'
if ($OutDir -eq "") {
    $OutDir = "dist"
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$zip = Join-Path $OutDir "gardendless-loader-$safeVersion-windows-x64.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path "$release\*" -DestinationPath $zip

$hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
"$hash  $([System.IO.Path]::GetFileName($zip))" | Out-File -Encoding ascii "$zip.sha256"

Write-Host ""
Write-Host "== 完成 ==" -ForegroundColor Green
Write-Host "产物: $zip"
Write-Host "大小: $([math]::Round((Get-Item $zip).Length / 1MB, 1)) MB"
Write-Host "sha256: $hash"
