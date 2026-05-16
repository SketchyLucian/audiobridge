#include "flutter_window.h"

#include <optional>
#include <shellapi.h>
#include <string>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"
#include <flutter/method_call.h>
#include <flutter/method_result.h>
#include <flutter/standard_method_codec.h>

namespace {

void ReturnError(std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>&
                     result,
                 const std::optional<std::string>& error) {
  if (error.has_value()) {
    result->Error("audio_engine", error.value());
  } else {
    result->Success();
  }
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  native_audio_engine_ = std::make_unique<WindowsAudioEngine>();
  native_audio_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "audio_bridge/native_engine",
          &flutter::StandardMethodCodec::GetInstance());
  native_audio_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        const std::string& method = call.method_name();
        if (method == "getCapabilities") {
          result->Success(
              flutter::EncodableValue(native_audio_engine_->GetCapabilities()));
          return;
        }

        if (method == "getNetworkInterfaces") {
          result->Success(flutter::EncodableValue(
              native_audio_engine_->GetNetworkInterfaces()));
          return;
        }

        if (method == "getMetrics") {
          result->Success(
              flutter::EncodableValue(native_audio_engine_->GetMetrics()));
          return;
        }

        if (method == "prepareSender") {
          ReturnError(result,
                      native_audio_engine_->PrepareSender(call.arguments()));
          return;
        }

        if (method == "prepareUsbSender") {
          ReturnError(result, native_audio_engine_->PrepareUsbSender(
                                  call.arguments()));
          return;
        }

        if (method == "prepareReceiver") {
          ReturnError(result,
                      native_audio_engine_->PrepareReceiver(call.arguments()));
          return;
        }

        if (method == "prepareUsbReceiver") {
          ReturnError(result, native_audio_engine_->PrepareUsbReceiver(
                                  call.arguments()));
          return;
        }

        if (method == "connectToSender") {
          ReturnError(result,
                      native_audio_engine_->ConnectToSender(call.arguments()));
          return;
        }

        if (method == "startStream") {
          ReturnError(result, native_audio_engine_->StartStream(call.arguments()));
          return;
        }

        if (method == "stopStream") {
          native_audio_engine_->StopStream();
          result->Success();
          return;
        }

        if (method == "setVolume") {
          native_audio_engine_->SetVolume(call.arguments());
          result->Success();
          return;
        }

        if (method == "setMuted") {
          native_audio_engine_->SetMuted(call.arguments());
          result->Success();
          return;
        }

        if (method == "disconnect") {
          native_audio_engine_->Disconnect();
          result->Success();
          return;
        }

        result->NotImplemented();
      });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  AddTrayIcon();

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  RemoveTrayIcon();
  if (native_audio_engine_) {
    native_audio_engine_->Disconnect();
  }
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_CLOSE:
      ::ShowWindow(hwnd, SW_HIDE);
      return 0;
    case WM_COMMAND:
      switch (LOWORD(wparam)) {
        case ID_TRAY_SHOW:
          ShowFromTray();
          return 0;
        case ID_TRAY_EXIT:
          ExitFromTray();
          return 0;
      }
      break;
    case WM_APP_TRAY:
      if (lparam == WM_LBUTTONUP || lparam == WM_LBUTTONDBLCLK) {
        ShowFromTray();
        return 0;
      }
      if (lparam == WM_RBUTTONUP || lparam == WM_CONTEXTMENU) {
        ShowTrayMenu();
        return 0;
      }
      break;
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

void FlutterWindow::AddTrayIcon() {
  if (tray_icon_added_) {
    return;
  }

  NOTIFYICONDATA notify_icon = {};
  notify_icon.cbSize = sizeof(NOTIFYICONDATA);
  tray_window_handle_ = GetHandle();
  notify_icon.hWnd = tray_window_handle_;
  notify_icon.uID = IDI_APP_ICON;
  notify_icon.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
  notify_icon.uCallbackMessage = WM_APP_TRAY;
  notify_icon.hIcon =
      LoadIcon(GetModuleHandle(nullptr), MAKEINTRESOURCE(IDI_APP_ICON));
  wcscpy_s(notify_icon.szTip, window_title_.c_str());

  tray_icon_added_ = Shell_NotifyIcon(NIM_ADD, &notify_icon) == TRUE;
}

void FlutterWindow::RemoveTrayIcon() {
  if (!tray_icon_added_) {
    return;
  }

  NOTIFYICONDATA notify_icon = {};
  notify_icon.cbSize = sizeof(NOTIFYICONDATA);
  notify_icon.hWnd = tray_window_handle_;
  notify_icon.uID = IDI_APP_ICON;
  Shell_NotifyIcon(NIM_DELETE, &notify_icon);
  tray_icon_added_ = false;
  tray_window_handle_ = nullptr;
}

void FlutterWindow::ShowTrayMenu() {
  HMENU menu = CreatePopupMenu();
  if (!menu) {
    return;
  }

  AppendMenu(menu, MF_STRING, ID_TRAY_SHOW, L"Show AudioBridge");
  AppendMenu(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenu(menu, MF_STRING, ID_TRAY_EXIT, L"Exit");

  POINT cursor;
  GetCursorPos(&cursor);
  SetForegroundWindow(GetHandle());
  TrackPopupMenu(menu, TPM_RIGHTBUTTON, cursor.x, cursor.y, 0, GetHandle(),
                 nullptr);
  DestroyMenu(menu);
}

void FlutterWindow::ShowFromTray() {
  HWND window = GetHandle();
  ShowWindow(window, SW_SHOW);
  ShowWindow(window, SW_RESTORE);
  SetForegroundWindow(window);
}

void FlutterWindow::ExitFromTray() {
  if (native_audio_engine_) {
    native_audio_engine_->Disconnect();
  }
  Close();
}
