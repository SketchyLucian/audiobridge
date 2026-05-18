#include <endpointvolume.h>
#include <mmdeviceapi.h>
#include <objbase.h>
#include <propkey.h>
#include <propsys.h>

#include <algorithm>
#include <iostream>
#include <string>

const PROPERTYKEY kPkeyDeviceFriendlyName = {
    {0xa45c254e,
     0xdf1c,
     0x4efd,
     {0x80, 0x20, 0x67, 0xd1, 0x46, 0xa8, 0x50, 0xe0}},
    14};

// Undocumented Windows CoreAudio policy interface used by common audio tools
// to change the default endpoint. Keep this in tools only; the app should not
// change system defaults without a visible user command.
MIDL_INTERFACE("f8679f50-850a-41cf-9c72-430f290290c8")
IPolicyConfig : public IUnknown {
 public:
  virtual HRESULT GetMixFormat(LPCWSTR, WAVEFORMATEX**) = 0;
  virtual HRESULT GetDeviceFormat(LPCWSTR, INT, WAVEFORMATEX**) = 0;
  virtual HRESULT ResetDeviceFormat(LPCWSTR) = 0;
  virtual HRESULT SetDeviceFormat(LPCWSTR, WAVEFORMATEX*, WAVEFORMATEX*) = 0;
  virtual HRESULT GetProcessingPeriod(LPCWSTR, INT, PINT64, PINT64) = 0;
  virtual HRESULT SetProcessingPeriod(LPCWSTR, PINT64) = 0;
  virtual HRESULT GetShareMode(LPCWSTR, void*) = 0;
  virtual HRESULT SetShareMode(LPCWSTR, void*) = 0;
  virtual HRESULT GetPropertyValue(LPCWSTR, const PROPERTYKEY&, PROPVARIANT*) = 0;
  virtual HRESULT SetPropertyValue(LPCWSTR, const PROPERTYKEY&, PROPVARIANT*) = 0;
  virtual HRESULT SetDefaultEndpoint(LPCWSTR device_id, ERole role) = 0;
  virtual HRESULT SetEndpointVisibility(LPCWSTR, INT) = 0;
};

class DECLSPEC_UUID("870af99c-171d-4f9e-af0d-e63df40c2bc9")
    PolicyConfigClient;

std::wstring Lower(std::wstring value) {
  std::transform(value.begin(), value.end(), value.begin(), ::towlower);
  return value;
}

std::wstring DeviceId(IMMDevice* device) {
  LPWSTR raw_id = nullptr;
  std::wstring id;
  if (SUCCEEDED(device->GetId(&raw_id)) && raw_id != nullptr) {
    id = raw_id;
    CoTaskMemFree(raw_id);
  }
  return id;
}

std::wstring FriendlyName(IMMDevice* device) {
  IPropertyStore* properties = nullptr;
  if (FAILED(device->OpenPropertyStore(STGM_READ, &properties))) {
    return L"";
  }
  PROPVARIANT value;
  PropVariantInit(&value);
  std::wstring name;
  if (SUCCEEDED(properties->GetValue(kPkeyDeviceFriendlyName, &value)) &&
      value.vt == VT_LPWSTR && value.pwszVal != nullptr) {
    name = value.pwszVal;
  }
  PropVariantClear(&value);
  properties->Release();
  return name;
}

bool IsSameDevice(IMMDevice* left, IMMDevice* right) {
  if (left == nullptr || right == nullptr) {
    return false;
  }
  return DeviceId(left) == DeviceId(right);
}

IMMDevice* FindCableOutputCapture(IMMDeviceEnumerator* enumerator) {
  IMMDeviceCollection* collection = nullptr;
  if (FAILED(enumerator->EnumAudioEndpoints(eCapture, DEVICE_STATE_ACTIVE,
                                            &collection))) {
    return nullptr;
  }

  UINT count = 0;
  collection->GetCount(&count);
  for (UINT index = 0; index < count; ++index) {
    IMMDevice* device = nullptr;
    if (FAILED(collection->Item(index, &device))) {
      continue;
    }
    const std::wstring haystack =
        Lower(FriendlyName(device) + L" " + DeviceId(device));
    if (haystack.find(L"cable output") != std::wstring::npos ||
        haystack.find(L"ef028424-65b9-4a6a-875d-993e8dc5186f") !=
            std::wstring::npos) {
      collection->Release();
      return device;
    }
    device->Release();
  }

  collection->Release();
  return nullptr;
}

IMMDevice* FindRealtekCapture(IMMDeviceEnumerator* enumerator) {
  IMMDeviceCollection* collection = nullptr;
  if (FAILED(enumerator->EnumAudioEndpoints(eCapture, DEVICE_STATEMASK_ALL,
                                            &collection))) {
    return nullptr;
  }

  UINT count = 0;
  collection->GetCount(&count);
  for (UINT index = 0; index < count; ++index) {
    IMMDevice* device = nullptr;
    if (FAILED(collection->Item(index, &device))) {
      continue;
    }
    const std::wstring haystack =
        Lower(FriendlyName(device) + L" " + DeviceId(device));
    if (haystack.find(L"realtek") != std::wstring::npos ||
        haystack.find(L"2fd9afd0-2916-4feb-8e86-d03cdfa3dfaf") !=
            std::wstring::npos) {
      collection->Release();
      return device;
    }
    device->Release();
  }

  collection->Release();
  return nullptr;
}

void PrintCaptureEndpoints(IMMDeviceEnumerator* enumerator) {
  IMMDevice* default_console = nullptr;
  IMMDevice* default_communications = nullptr;
  enumerator->GetDefaultAudioEndpoint(eCapture, eConsole, &default_console);
  enumerator->GetDefaultAudioEndpoint(eCapture, eCommunications,
                                      &default_communications);

  IMMDeviceCollection* collection = nullptr;
  if (FAILED(enumerator->EnumAudioEndpoints(eCapture, DEVICE_STATE_ACTIVE,
                                            &collection))) {
    return;
  }

  UINT count = 0;
  collection->GetCount(&count);
  for (UINT index = 0; index < count; ++index) {
    IMMDevice* device = nullptr;
    if (FAILED(collection->Item(index, &device))) {
      continue;
    }
    std::wcout << L"Capture: " << FriendlyName(device);
    if (IsSameDevice(device, default_console)) {
      std::wcout << L" [default]";
    }
    if (IsSameDevice(device, default_communications)) {
      std::wcout << L" [communications]";
    }
    std::wcout << L"\n";
    std::wcout << L"  " << DeviceId(device) << L"\n";
    device->Release();
  }

  collection->Release();
  if (default_console != nullptr) {
    default_console->Release();
  }
  if (default_communications != nullptr) {
    default_communications->Release();
  }
}

int wmain(int argc, wchar_t** argv) {
  HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  if (FAILED(hr)) {
    std::cerr << "CoInitializeEx failed: 0x" << std::hex << hr << "\n";
    return 1;
  }

  IMMDeviceEnumerator* enumerator = nullptr;
  hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                        IID_PPV_ARGS(&enumerator));
  if (FAILED(hr)) {
    std::cerr << "MMDeviceEnumerator failed: 0x" << std::hex << hr << "\n";
    CoUninitialize();
    return 1;
  }

  const std::wstring command = argc > 1 ? argv[1] : L"";
  if (command.empty()) {
    PrintCaptureEndpoints(enumerator);
    enumerator->Release();
    CoUninitialize();
    return 0;
  }

  const bool should_set = command == L"set-cable-output-default";
  const bool should_hide_realtek = command == L"hide-realtek";
  const bool should_show_realtek = command == L"show-realtek";
  if (!should_set && !should_hide_realtek && !should_show_realtek) {
    std::cerr << "Unknown command.\n";
    enumerator->Release();
    CoUninitialize();
    return 5;
  }

  IMMDevice* cable_output = FindCableOutputCapture(enumerator);
  if (cable_output == nullptr) {
    std::cerr << "CABLE Output capture endpoint was not found.\n";
    enumerator->Release();
    CoUninitialize();
    return 2;
  }

  const std::wstring id = DeviceId(cable_output);
  IPolicyConfig* policy = nullptr;
  hr = CoCreateInstance(__uuidof(PolicyConfigClient), nullptr, CLSCTX_ALL,
                        __uuidof(IPolicyConfig),
                        reinterpret_cast<void**>(&policy));
  if (FAILED(hr)) {
    std::cerr << "PolicyConfig failed: 0x" << std::hex << hr << "\n";
    cable_output->Release();
    enumerator->Release();
    CoUninitialize();
    return 3;
  }

  if (should_hide_realtek || should_show_realtek) {
    IMMDevice* realtek = FindRealtekCapture(enumerator);
    if (realtek == nullptr) {
      std::cerr << "Realtek capture endpoint was not found.\n";
      policy->Release();
      cable_output->Release();
      enumerator->Release();
      CoUninitialize();
      return 6;
    }
    const std::wstring realtek_id = DeviceId(realtek);
    const HRESULT visibility_hr =
        policy->SetEndpointVisibility(realtek_id.c_str(),
                                      should_hide_realtek ? FALSE : TRUE);
    std::wcout << (should_hide_realtek ? L"Hid" : L"Showed")
               << L" capture endpoint: " << FriendlyName(realtek) << L"\n";
    std::wcout << L"  visibility=0x" << std::hex << visibility_hr << L"\n";
    realtek->Release();
    policy->Release();
    cable_output->Release();
    PrintCaptureEndpoints(enumerator);
    enumerator->Release();
    CoUninitialize();
    return SUCCEEDED(visibility_hr) ? 0 : 7;
  }

  HRESULT console_hr = policy->SetDefaultEndpoint(id.c_str(), eConsole);
  HRESULT multimedia_hr = policy->SetDefaultEndpoint(id.c_str(), eMultimedia);
  HRESULT communications_hr =
      policy->SetDefaultEndpoint(id.c_str(), eCommunications);

  IAudioEndpointVolume* volume = nullptr;
  if (SUCCEEDED(cable_output->Activate(__uuidof(IAudioEndpointVolume),
                                       CLSCTX_ALL, nullptr,
                                       reinterpret_cast<void**>(&volume)))) {
    volume->SetMute(FALSE, nullptr);
    volume->SetMasterVolumeLevelScalar(1.0f, nullptr);
    volume->Release();
  }

  std::wcout << L"Set default capture microphone to: "
             << FriendlyName(cable_output) << L"\n";
  std::wcout << L"  console=0x" << std::hex << console_hr
             << L" multimedia=0x" << multimedia_hr
             << L" communications=0x" << communications_hr << L"\n";

  policy->Release();
  cable_output->Release();
  PrintCaptureEndpoints(enumerator);
  enumerator->Release();
  CoUninitialize();
  return SUCCEEDED(console_hr) && SUCCEEDED(multimedia_hr) &&
                 SUCCEEDED(communications_hr)
             ? 0
             : 4;
}
