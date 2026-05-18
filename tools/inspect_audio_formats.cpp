#include <audioclient.h>
#include <mmdeviceapi.h>
#include <objbase.h>
#include <propkey.h>
#include <propvarutil.h>
#include <propsys.h>
#include <ksmedia.h>

#include <iostream>
#include <string>

std::wstring GuidName(const GUID& guid) {
  if (IsEqualGUID(guid, KSDATAFORMAT_SUBTYPE_IEEE_FLOAT)) {
    return L"IEEE_FLOAT";
  }
  if (IsEqualGUID(guid, KSDATAFORMAT_SUBTYPE_PCM)) {
    return L"PCM";
  }
  wchar_t buffer[64] = {};
  StringFromGUID2(guid, buffer, 64);
  return buffer;
}

void PrintEndpoints(EDataFlow flow, const wchar_t* flow_name) {
  IMMDeviceEnumerator* enumerator = nullptr;
  if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
                              CLSCTX_ALL, IID_PPV_ARGS(&enumerator)))) {
    return;
  }

  IMMDeviceCollection* collection = nullptr;
  if (FAILED(enumerator->EnumAudioEndpoints(flow, DEVICE_STATE_ACTIVE,
                                            &collection))) {
    enumerator->Release();
    return;
  }

  UINT count = 0;
  collection->GetCount(&count);
  for (UINT index = 0; index < count; ++index) {
    IMMDevice* device = nullptr;
    if (FAILED(collection->Item(index, &device))) {
      continue;
    }

    LPWSTR raw_id = nullptr;
    std::wstring id;
    if (SUCCEEDED(device->GetId(&raw_id)) && raw_id != nullptr) {
      id = raw_id;
      CoTaskMemFree(raw_id);
    }

    IAudioClient* client = nullptr;
    if (FAILED(device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                                reinterpret_cast<void**>(&client)))) {
      device->Release();
      continue;
    }

    WAVEFORMATEX* format = nullptr;
    if (SUCCEEDED(client->GetMixFormat(&format)) && format != nullptr) {
      std::wcout << flow_name << L" | " << id << L"\n";
      std::wcout << L"  tag=" << format->wFormatTag
                 << L" channels=" << format->nChannels
                 << L" hz=" << format->nSamplesPerSec
                 << L" bits=" << format->wBitsPerSample
                 << L" blockAlign=" << format->nBlockAlign
                 << L" avgBytes=" << format->nAvgBytesPerSec
                 << L" cbSize=" << format->cbSize;
      if (format->wFormatTag == WAVE_FORMAT_EXTENSIBLE &&
          format->cbSize >= 22) {
        const auto* extensible =
            reinterpret_cast<const WAVEFORMATEXTENSIBLE*>(format);
        std::wcout << L" validBits=" << extensible->Samples.wValidBitsPerSample
                   << L" subformat=" << GuidName(extensible->SubFormat);
      }
      std::wcout << L"\n";
      CoTaskMemFree(format);
    }

    client->Release();
    device->Release();
  }

  collection->Release();
  enumerator->Release();
}

int wmain() {
  CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  PrintEndpoints(eRender, L"Render");
  PrintEndpoints(eCapture, L"Capture");
  CoUninitialize();
  return 0;
}
