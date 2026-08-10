#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

namespace {

// Center an already-created (still hidden) window on the monitor nearest the
// cursor, using the work area so the taskbar is respected.
void CenterWindow(HWND hwnd) {
  if (!hwnd) {
    return;
  }

  POINT cursor_pos = {0, 0};
  ::GetCursorPos(&cursor_pos);
  HMONITOR monitor = ::MonitorFromPoint(cursor_pos, MONITOR_DEFAULTTONEAREST);

  MONITORINFO monitor_info = {};
  monitor_info.cbSize = sizeof(MONITORINFO);
  if (!::GetMonitorInfo(monitor, &monitor_info)) {
    return;
  }

  RECT window_rect = {};
  if (!::GetWindowRect(hwnd, &window_rect)) {
    return;
  }

  const int window_width = window_rect.right - window_rect.left;
  const int window_height = window_rect.bottom - window_rect.top;
  const RECT& work = monitor_info.rcWork;
  const int x = work.left + (work.right - work.left - window_width) / 2;
  const int y = work.top + (work.bottom - work.top - window_height) / 2;

  ::SetWindowPos(hwnd, nullptr, x, y, 0, 0,
                 SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
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

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"vault", origin, size)) {
    return EXIT_FAILURE;
  }
  CenterWindow(window.GetHandle());
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
