#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <memory>
#include <type_traits>

#include "flutter_window.h"
#include "utils.h"

namespace {

constexpr const wchar_t kSingleInstanceMutexName[] =
    L"Local\\AudioBridge.SingleInstance";
constexpr const wchar_t kWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";
constexpr const wchar_t kWindowTitle[] = L"AudioBridge";

struct HandleCloser {
  void operator()(HANDLE handle) const {
    if (handle != nullptr) {
      ::CloseHandle(handle);
    }
  }
};

using UniqueHandle =
    std::unique_ptr<std::remove_pointer<HANDLE>::type, HandleCloser>;

bool ShowExistingInstance(int show_command) {
  for (int attempt = 0; attempt < 20; ++attempt) {
    HWND existing_window = ::FindWindow(kWindowClassName, kWindowTitle);
    if (existing_window != nullptr) {
      ::ShowWindow(existing_window, SW_SHOW);
      if (::IsIconic(existing_window)) {
        ::ShowWindow(existing_window, SW_RESTORE);
      } else {
        ::ShowWindow(existing_window,
                     show_command == SW_SHOWMINIMIZED ? SW_SHOWNORMAL
                                                       : show_command);
      }
      ::SetForegroundWindow(existing_window);
      return true;
    }

    ::Sleep(100);
  }

  return false;
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  HANDLE mutex_handle = ::CreateMutex(nullptr, TRUE, kSingleInstanceMutexName);
  const DWORD mutex_error = ::GetLastError();
  UniqueHandle single_instance_mutex(mutex_handle);
  if ((single_instance_mutex && mutex_error == ERROR_ALREADY_EXISTS) ||
      (!single_instance_mutex && mutex_error == ERROR_ACCESS_DENIED)) {
    ShowExistingInstance(show_command);
    return EXIT_SUCCESS;
  }

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
  if (!window.Create(L"AudioBridge", origin, size)) {
    ::CoUninitialize();
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(false);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
