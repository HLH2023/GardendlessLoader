const appDisplayName = 'GardendlessLoader'; // App 显示名称
const appBundleId =
    'io.github.dey410.gardendlessloader'; // App 包名（Bundle ID），用于区分不同平台的应用
const githubUrl =
    'https://github.com/Gzh0821/pvzge_web'; // GitHub 仓库地址，指向 PvZ2 Gardendless 项目的源代码
const appGithubUrl =
    'https://github.com/Dey410/GardendlessLoader'; // GardendlessLoader 的 GitHub 仓库地址
const gameReleaseNotesUrl =
    'https://github.com/Gzh0821/pvzg_site/releases/tag/{version}'; // 上游游戏版本的更新说明，{version} 替换为版本号
const cloudDriveUrl =
    'https://pan.quark.cn/s/c3da839ca8b1?pwd=qLBU'; // 网盘地址，加载器更新与游戏资源下载默认共用
const bilibiliHomeUrl = 'https://space.bilibili.com/523667580'; // B站主页地址
const remoteAnnouncementUrls = [
  'https://raw.githubusercontent.com/Dey410/GardendlessLoader/main/announcements.json',
  'https://cdn.jsdelivr.net/gh/Dey410/GardendlessLoader@main/announcements.json',
]; // 远程公告 URL，按顺序尝试；GitHub 无法访问时改用 jsDelivr
const remoteAboutContentUrl =
    'https://raw.githubusercontent.com/Dey410/GardendlessLoader/main/about_content.json'; // 远程关于内容 URL
// 云存档与资源服务器地址：只能由构建时的 --dart-define=PVZGE_SERVER=… 注入，
// 默认留空，用户也可以在设置页填写。仓库里不保存任何真实服务器地址。
const kDefaultServerBase = String.fromEnvironment(
  'PVZGE_SERVER',
  defaultValue: '',
);
const saveServerRequestTimeout = Duration(seconds: 20); // 服务器请求（清单、注入脚本）超时时间
const saveLoginPagePath = '/_save/app.html'; // 令牌签发页；浏览器打开时是手动复制模式
const saveLoginBridgeQuery = 'bridge=1'; // 应用内登录：页面通过 GardendlessBridge 回传令牌
const saveAdminPagePath =
    '/_save/admin.html'; // 完整存档管理页（历史/回滚/设备），需浏览器 authentik 会话
const saveWhoamiPath = '/_save/app/whoami'; // 校验设备令牌，返回 {"user": "..."}
const saveLoadPath = '/_save/app/load'; // 云端存档元信息（data/mtime/summary）
const saveHistoryPath = '/_save/app/history'; // 某个存档键的历史版本（需管理员）
const saveRestorePath = '/_save/app/restore'; // 回滚到指定历史版本
const saveProfileHistoryPath = '/_save/app/profile/history'; // 单个玩家数据的历史版本
const saveProfileRestorePath = '/_save/app/profile/restore'; // 只回滚一个玩家，不动其它玩家
const saveApkManifestPath =
    '/_save/app/res/apk/manifest.json'; // 应用内更新的 APK 清单，带 Bearer 令牌请求
const saveApkManifestMaxBytes = 64 * 1024; // APK 清单最大响应体，64KB
const saveWindowsManifestPath =
    '/_save/app/res/win/manifest.json'; // Windows 构建清单（zip + sha256），带 Bearer 令牌请求
const saveWindowsManifestMaxBytes = 64 * 1024; // Windows 清单最大响应体，64KB
const saveServerDownloadConnectTimeout = Duration(seconds: 20); // 资源下载建立连接的超时时间
const saveServerManifestMaxBytes = 512 * 1024; // 资源清单最大响应体，512KB
const saveServerScriptMaxBytes = 2 * 1024 * 1024; // 注入脚本最大响应体，2MB
const saveServerSavesMaxBytes = 4 * 1024 * 1024; // 存档清单最大响应体（含 meta 摘要），4MB
const saveServerHistoryLimit = 20; // 存档历史默认拉取条数
const syncBridgeFileName = '__sync_app.js'; // 云存档注入脚本文件名（与资源槽同级）
// 本机存档版本保护脚本：与登录无关，必须在游戏读 localStorage 之前执行。
// 由 Dart 生成、原生宿主读取，保证 Android 与桌面端跑的是同一份逻辑。
const localSaveGuardFileName = '__local_save_guard.js';
// 旧版在线宿主写下的长期设备令牌文件；在线游玩删除后无人读取，只在启动与
// 登出时清理，避免明文令牌继续躺在用户可选的资源目录里。
const legacyNativeTokenFileName = '__sync_native_token';
const resourceFolderName = 'GardendlessLoader'; // 资源文件夹名称
const appVersion = String.fromEnvironment('APP_VERSION', defaultValue: '0.9.0');
const announcementTimeout = Duration(seconds: 3); //公告请求超时时间
const announcementMaxBytes = 32 * 1024; //公告请求最大响应体大小，32KB应该足够了
const aboutContentTimeout = Duration(seconds: 3); //关于内容请求超时时间
const aboutContentMaxBytes = 16 * 1024; //关于内容请求最大响应体大小
