#include <audiopolicy.h>
#include <mmdeviceapi.h>
#include <objbase.h>
#include <propkey.h>
#include <propsys.h>
#include <windows.h>

#include <algorithm>
#include <iostream>
#include <string>

const PROPERTYKEY kPkeyDeviceFriendlyName = {
    {0xa45c254e,
     0xdf1c,
     0x4efd,
     {0x80, 0x20, 0x67, 0xd1, 0x46, 0xa8, 0x50, 0xe0}},
    14};

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

std::wstring ProcessName(DWORD pid) {
  HANDLE process =
      OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (process == nullptr) {
    return L"";
  }
  wchar_t path[MAX_PATH] = {};
  DWORD size = MAX_PATH;
  std::wstring name;
  if (QueryFullProcessImageNameW(process, 0, path, &size)) {
    name = path;
    const size_t slash = name.find_last_of(L"\\/");
    if (slash != std::wstring::npos) {
      name = name.substr(slash + 1);
    }
  }
  CloseHandle(process);
  return name;
}

const wchar_t* StateName(AudioSessionState state) {
  switch (state) {
    case AudioSessionStateInactive:
      return L"inactive";
    case AudioSessionStateActive:
      return L"active";
    case AudioSessionStateExpired:
      return L"expired";
  }
  return L"unknown";
}

void InspectDeviceSessions(IMMDevice* device) {
  std::wcout << L"Capture endpoint: " << FriendlyName(device) << L"\n";

  IAudioSessionManager2* manager = nullptr;
  HRESULT hr = device->Activate(__uuidof(IAudioSessionManager2), CLSCTX_ALL,
                                nullptr, reinterpret_cast<void**>(&manager));
  if (FAILED(hr)) {
    std::cerr << "IAudioSessionManager2 failed: 0x" << std::hex << hr << "\n";
    return;
  }

  IAudioSessionEnumerator* sessions = nullptr;
  hr = manager->GetSessionEnumerator(&sessions);
  if (FAILED(hr)) {
    std::cerr << "GetSessionEnumerator failed: 0x" << std::hex << hr << "\n";
    manager->Release();
    return;
  }

  int count = 0;
  sessions->GetCount(&count);
  std::wcout << L"Sessions: " << count << L"\n";
  for (int index = 0; index < count; ++index) {
    IAudioSessionControl* control = nullptr;
    if (FAILED(sessions->GetSession(index, &control)) || control == nullptr) {
      continue;
    }

    AudioSessionState state = AudioSessionStateInactive;
    control->GetState(&state);

    IAudioSessionControl2* control2 = nullptr;
    DWORD pid = 0;
    if (SUCCEEDED(control->QueryInterface(IID_PPV_ARGS(&control2))) &&
        control2 != nullptr) {
      control2->GetProcessId(&pid);
      control2->Release();
    }

    std::wcout << L"  [" << index << L"] pid=" << pid
               << L" process=" << ProcessName(pid)
               << L" state=" << StateName(state) << L"\n";
    control->Release();
  }

  sessions->Release();
  manager->Release();
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

void InspectAllCaptureEndpoints(IMMDeviceEnumerator* enumerator) {
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
    InspectDeviceSessions(device);
    device->Release();
  }

  collection->Release();
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

  if (argc > 1 && std::wstring(argv[1]) == L"all") {
    InspectAllCaptureEndpoints(enumerator);
    enumerator->Release();
    CoUninitialize();
    return 0;
  }

  IMMDevice* device = FindCableOutputCapture(enumerator);
  if (device == nullptr) {
    std::cerr << "CABLE Output capture endpoint not found\n";
    enumerator->Release();
    CoUninitialize();
    return 2;
  }

  InspectDeviceSessions(device);
  device->Release();
  enumerator->Release();
  CoUninitialize();
  return 0;
}
