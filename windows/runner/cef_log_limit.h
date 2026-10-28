#pragma once

// CEF 的 debug.log 没有内置上限：界面起不来（或渲染循环反复报错）时，
// 后台进程会一直往可执行文件目录下的 debug.log 追加，实机出现过 250 GB。
// 这里给日志加一个硬上限，运行期定期裁剪。
void StartCefLogLimit();
