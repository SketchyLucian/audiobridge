#include "flutter_window.h"

#include <algorithm>
#include <cctype>
#include <cstdint>
#include <optional>
#include <shellapi.h>
#include <string>
#include <variant>
#include <windows.h>

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

std::optional<std::string> StringArgument(
    const flutter::EncodableValue* arguments,
    const std::string& key) {
  if (!arguments ||
      !std::holds_alternative<flutter::EncodableMap>(*arguments)) {
    return std::nullopt;
  }

  const auto& map = std::get<flutter::EncodableMap>(*arguments);
  auto iterator = map.find(flutter::EncodableValue(key));
  if (iterator == map.end() ||
      !std::holds_alternative<std::string>(iterator->second)) {
    return std::nullopt;
  }

  return std::get<std::string>(iterator->second);
}

std::wstring Utf8ToWide(const std::string& value) {
  if (value.empty()) {
    return std::wstring();
  }

  const int size = MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), nullptr, 0);
  if (size <= 0) {
    return std::wstring();
  }

  std::wstring wide(size, L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                      static_cast<int>(value.size()), wide.data(), size);
  return wide;
}

bool HasCaseInsensitiveSuffix(const std::string& value,
                              const std::string& suffix) {
  if (value.size() < suffix.size()) {
    return false;
  }

  std::string tail = value.substr(value.size() - suffix.size());
  std::transform(tail.begin(), tail.end(), tail.begin(),
                 [](unsigned char character) {
                   return static_cast<char>(std::tolower(character));
                 });
  return tail == suffix;
}

bool ShellOpen(const std::string& target) {
  const std::wstring wide_target = Utf8ToWide(target);
  if (wide_target.empty()) {
    return false;
  }

  const HINSTANCE outcome =
      ShellExecuteW(nullptr, L"open", wide_target.c_str(), nullptr, nullptr,
                    SW_SHOWNORMAL);
  return reinterpret_cast<intptr_t>(outcome) > 32;
}

std::string Base64Encode(const uint8_t* data, size_t length) {
  static constexpr char alphabet[] =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

  std::string output;
  output.reserve(((length + 2) / 3) * 4);
  for (size_t index = 0; index < length; index += 3) {
    const uint32_t byte0 = data[index];
    const uint32_t byte1 = index + 1 < length ? data[index + 1] : 0;
    const uint32_t byte2 = index + 2 < length ? data[index + 2] : 0;
    const uint32_t chunk = (byte0 << 16) | (byte1 << 8) | byte2;

    output.push_back(alphabet[(chunk >> 18) & 0x3F]);
    output.push_back(alphabet[(chunk >> 12) & 0x3F]);
    output.push_back(index + 1 < length ? alphabet[(chunk >> 6) & 0x3F]
                                        : '=');
    output.push_back(index + 2 < length ? alphabet[chunk & 0x3F] : '=');
  }
  return output;
}

std::string PowerShellEncodedCommand(const std::wstring& script) {
  const auto* bytes = reinterpret_cast<const uint8_t*>(script.data());
  return Base64Encode(bytes, script.size() * sizeof(wchar_t));
}

std::wstring PowerShellSingleQuoted(const std::wstring& value) {
  std::wstring quoted = L"'";
  for (const wchar_t character : value) {
    if (character == L'\'') {
      quoted += L"''";
    } else {
      quoted.push_back(character);
    }
  }
  quoted += L"'";
  return quoted;
}

std::wstring CurrentExecutablePath() {
  std::wstring buffer(MAX_PATH, L'\0');
  DWORD size = GetModuleFileNameW(nullptr, buffer.data(),
                                  static_cast<DWORD>(buffer.size()));
  if (size == 0) {
    return std::wstring();
  }

  while (size == buffer.size() &&
         GetLastError() == ERROR_INSUFFICIENT_BUFFER) {
    buffer.resize(buffer.size() * 2);
    size = GetModuleFileNameW(nullptr, buffer.data(),
                              static_cast<DWORD>(buffer.size()));
    if (size == 0) {
      return std::wstring();
    }
  }

  buffer.resize(size);
  return buffer;
}

bool LaunchWindowsInstallerAndRestart(const std::string& installer_path) {
  const std::wstring wide_installer_path = Utf8ToWide(installer_path);
  const std::wstring executable_path = CurrentExecutablePath();
  if (wide_installer_path.empty() || executable_path.empty()) {
    return false;
  }

  std::wstring script;
  script += L"$ErrorActionPreference = 'SilentlyContinue'\n";
  script += L"$msi = " + PowerShellSingleQuoted(wide_installer_path) + L"\n";
  script += L"$exe = " + PowerShellSingleQuoted(executable_path) + L"\n";
  script += L"$pidToWatch = " + std::to_wstring(GetCurrentProcessId()) + L"\n";
  script +=
      L"Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/i', $msi) "
      L"-Wait\n";
  script += L"Start-Sleep -Milliseconds 800\n";
  script +=
      L"if (-not (Get-Process -Id $pidToWatch -ErrorAction "
      L"SilentlyContinue)) {\n";
  script += L"  if (Test-Path -LiteralPath $exe) {\n";
  script +=
      L"    Start-Process -FilePath $exe -WorkingDirectory "
      L"(Split-Path -Parent $exe)\n";
  script += L"  }\n";
  script += L"}\n";

  const std::string encoded = PowerShellEncodedCommand(script);
  const std::wstring encoded_wide(encoded.begin(), encoded.end());
  const std::wstring parameters =
      L"-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden "
      L"-EncodedCommand " +
      encoded_wide;
  const HINSTANCE outcome = ShellExecuteW(
      nullptr, L"open", L"powershell.exe", parameters.c_str(), nullptr,
      SW_HIDE);
  return reinterpret_cast<intptr_t>(outcome) > 32;
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

        if (method == "playSoundEffect") {
          ReturnError(result,
                      native_audio_engine_->PlaySoundEffect(call.arguments()));
          return;
        }

        if (method == "configureVirtualMicPassthrough") {
          ReturnError(result, native_audio_engine_->ConfigureVirtualMicPassthrough(
                                  call.arguments()));
          return;
        }

        if (method == "stopSoundEffects") {
          native_audio_engine_->StopSoundEffects();
          result->Success();
          return;
        }

        if (method == "disconnect") {
          native_audio_engine_->Disconnect();
          result->Success();
          return;
        }

        if (method == "openExternalUrl") {
          const auto url = StringArgument(call.arguments(), "url");
          if (!url.has_value() || url->rfind("https://", 0) != 0) {
            result->Error("update_url", "The release link is not secure.");
            return;
          }
          if (!ShellOpen(url.value())) {
            result->Error("update_url", "Unable to open release page.");
            return;
          }
          result->Success();
          return;
        }

        if (method == "installUpdatePackage") {
          const auto path = StringArgument(call.arguments(), "path");
          if (!path.has_value() ||
              !HasCaseInsensitiveSuffix(path.value(), ".msi")) {
            result->Error("update_package",
                          "The downloaded Windows installer is missing.");
            return;
          }
          const std::wstring wide_path = Utf8ToWide(path.value());
          if (wide_path.empty() ||
              GetFileAttributesW(wide_path.c_str()) == INVALID_FILE_ATTRIBUTES) {
            result->Error("update_package",
                          "The downloaded Windows installer is missing.");
            return;
          }
          if (!LaunchWindowsInstallerAndRestart(path.value())) {
            result->Error("update_package",
                          "Unable to open Windows installer.");
            return;
          }
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
    case WM_QUERYENDSESSION:
      return TRUE;
    case WM_ENDSESSION:
      if (wparam == TRUE) {
        ExitFromTray();
      }
      return 0;
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
