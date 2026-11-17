#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

namespace {

// 单实例判据用命名互斥量：句柄归内核对象管理，进程正常退出/被强杀都会自动释放，
// 不会出现「进程已经死了，锁还留着，再也打不开」的情况。
//
// 名字带 exe 文件名：完整端 / 相册端 / 音乐端 / 同步端是四个 exe，
// 名字写死会让它们互相挤（开了音乐端就点不开相册端），而它们本来就该各开一个。
constexpr const wchar_t kInstanceMutexPrefix[] = L"Local\\ColaNasOsClient.SingleInstance.";
// Flutter Windows 嵌入层注册的窗口类（见 win32_window.cpp），第二个实例据此找主窗口。
constexpr const wchar_t kMainWindowClass[] = L"FLUTTER_RUNNER_WIN32_WINDOW";

/// 本进程 exe 的完整路径（小写比较用）
std::wstring SelfImagePath() {
  wchar_t path[MAX_PATH * 2];
  const DWORD len =
      ::GetModuleFileNameW(nullptr, path, static_cast<DWORD>(sizeof(path) / sizeof(path[0])));
  return std::wstring(path, len);
}

/// 目标进程是不是同一个 exe（同一台机器上可能同时跑着别的 ColaNasOs 客户端）
bool IsSameExecutable(DWORD pid) {
  HANDLE process = ::OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (process == nullptr) return false;
  wchar_t path[MAX_PATH * 2];
  DWORD size = static_cast<DWORD>(sizeof(path) / sizeof(path[0]));
  const bool ok = ::QueryFullProcessImageNameW(process, 0, path, &size) != FALSE;
  ::CloseHandle(process);
  if (!ok) return false;
  return ::lstrcmpiW(std::wstring(path, size).c_str(), SelfImagePath().c_str()) == 0;
}

struct FindContext {
  HWND window;
};

BOOL CALLBACK FindMainWindowProc(HWND hwnd, LPARAM param) {
  wchar_t cls[256];
  if (::GetClassNameW(hwnd, cls, static_cast<int>(sizeof(cls) / sizeof(cls[0]))) == 0) {
    return TRUE;
  }
  if (::lstrcmpW(cls, kMainWindowClass) != 0) return TRUE;

  DWORD pid = 0;
  ::GetWindowThreadProcessId(hwnd, &pid);
  if (pid == 0 || pid == ::GetCurrentProcessId()) return TRUE;
  if (!IsSameExecutable(pid)) return TRUE;

  reinterpret_cast<FindContext*>(param)->window = hwnd;
  return FALSE;  // 找到就停
}

/// 找已在运行的同一个 exe 的主窗口。
///
/// ⚠️ 原来用 `FindWindowW(类名, nullptr)`：实测在这台机器上**返回 0**（窗口明明在，
/// 类名也一模一样），于是「再点一次快捷方式」没有任何反应。改成 EnumWindows 逐个比对
/// 类名 + 进程 exe 路径，稳。
HWND FindRunningInstance() {
  FindContext ctx{nullptr};
  // 第一次启动可能还在建窗口：短暂重试，避免「第二次启动毫无反应」。
  for (int i = 0; i < 20 && ctx.window == nullptr; ++i) {
    ::EnumWindows(FindMainWindowProc, reinterpret_cast<LPARAM>(&ctx));
    if (ctx.window == nullptr) ::Sleep(100);
  }
  return ctx.window;
}

/// 把已在运行的窗口唤到前台：隐藏态先显示 → 还原最小化 → 置前 → 任务栏闪烁兜底。
///
/// Windows 会拒绝后台进程直接抢焦点，所以先临时 AttachThreadInput 到目标窗口线程，
/// 置前后再解除；即使系统仍不给焦点，FlashWindowEx 也会让任务栏图标闪烁提示用户。
void ActivateRunningInstance() {
  HWND window = FindRunningInstance();
  if (window == nullptr) return;

  // 静默启动（启动时最小化到托盘）的窗口是**从未 Show 过**的隐藏态：
  // 只 SW_RESTORE 不会让它出现，必须先 SW_SHOW，否则用户再点一次快捷方式会觉得「没反应」。
  if (!::IsWindowVisible(window)) ::ShowWindow(window, SW_SHOW);
  if (::IsIconic(window)) ::ShowWindow(window, SW_RESTORE);

  const DWORD target_thread = ::GetWindowThreadProcessId(window, nullptr);
  const DWORD self_thread = ::GetCurrentThreadId();
  const bool attached = target_thread != 0 && target_thread != self_thread &&
                        ::AttachThreadInput(self_thread, target_thread, TRUE);
  ::SetForegroundWindow(window);
  ::BringWindowToTop(window);
  if (attached) ::AttachThreadInput(self_thread, target_thread, FALSE);

  FLASHWINFO flash{sizeof(flash), window, FLASHW_ALL | FLASHW_TIMERNOFG, 0, 0};
  ::FlashWindowEx(&flash);
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  // 同一台机器只允许**同一个 exe** 开一个窗口：双击快捷方式、开始菜单、命令行最终
  // 都是这个进程，所以在这里统一拦截，第二个实例不开窗口，只把已有窗口唤到前台。
  // 互斥量创建失败时按单实例放行 —— 不能因为拿不到锁就让用户打不开软件。
  const std::wstring image = SelfImagePath();
  const size_t slash = image.find_last_of(L"\\/");
  const std::wstring mutex_name = std::wstring(kInstanceMutexPrefix) +
                                  (slash == std::wstring::npos ? image : image.substr(slash + 1));
  HANDLE instance_mutex = ::CreateMutexW(nullptr, TRUE, mutex_name.c_str());
  if (instance_mutex != nullptr && ::GetLastError() == ERROR_ALREADY_EXISTS) {
    ActivateRunningInstance();
    ::CloseHandle(instance_mutex);
    return EXIT_SUCCESS;
  }

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"ColaNasOs 客户端", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
