#include <audioclient.h>
#include <ksmedia.h>
#include <mmdeviceapi.h>
#include <objbase.h>
#include <propkey.h>
#include <propsys.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <iostream>
#include <string>
#include <thread>

constexpr double kPi = 3.14159265358979323846;
const PROPERTYKEY kPkeyDeviceFriendlyName = {
    {0xa45c254e,
     0xdf1c,
     0x4efd,
     {0x80, 0x20, 0x67, 0xd1, 0x46, 0xa8, 0x50, 0xe0}},
    14};

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

std::wstring Lower(std::wstring value) {
  std::transform(value.begin(), value.end(), value.begin(), ::towlower);
  return value;
}

bool IsFloatFormat(const WAVEFORMATEX& format) {
  if (format.wFormatTag == WAVE_FORMAT_IEEE_FLOAT) {
    return true;
  }
  if (format.wFormatTag != WAVE_FORMAT_EXTENSIBLE) {
    return false;
  }
  const auto& extensible =
      reinterpret_cast<const WAVEFORMATEXTENSIBLE&>(format);
  return IsEqualGUID(extensible.SubFormat, KSDATAFORMAT_SUBTYPE_IEEE_FLOAT);
}

IMMDevice* FindRenderEndpoint(IMMDeviceEnumerator* enumerator,
                              const std::wstring& token) {
  IMMDeviceCollection* collection = nullptr;
  if (FAILED(enumerator->EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE,
                                            &collection))) {
    return nullptr;
  }

  const std::wstring lower_token = Lower(token);
  UINT count = 0;
  collection->GetCount(&count);
  for (UINT index = 0; index < count; ++index) {
    IMMDevice* device = nullptr;
    if (FAILED(collection->Item(index, &device))) {
      continue;
    }
    const std::wstring haystack =
        Lower(FriendlyName(device) + L" " + DeviceId(device));
    const bool is_match = haystack.find(lower_token) != std::wstring::npos;
    const bool is_bad_16ch = haystack.find(L"16ch") != std::wstring::npos ||
                             haystack.find(L"16 ch") != std::wstring::npos;
    if (is_match && !is_bad_16ch) {
      collection->Release();
      return device;
    }
    device->Release();
  }

  collection->Release();
  return nullptr;
}

void WriteTone(BYTE* output,
               UINT32 frames,
               const WAVEFORMATEX& format,
               int64_t start_frame) {
  const int channels = std::max<int>(1, format.nChannels);
  const double hz = 660.0;
  if (IsFloatFormat(format) && format.wBitsPerSample == 32) {
    auto* samples = reinterpret_cast<float*>(output);
    for (UINT32 frame = 0; frame < frames; ++frame) {
      const float sample = static_cast<float>(
          std::sin(2.0 * kPi * hz *
                   static_cast<double>(start_frame + frame) /
                   format.nSamplesPerSec) *
          0.65);
      for (int channel = 0; channel < channels; ++channel) {
        samples[frame * channels + channel] = sample;
      }
    }
    return;
  }

  if (format.wBitsPerSample == 16) {
    auto* samples = reinterpret_cast<int16_t*>(output);
    for (UINT32 frame = 0; frame < frames; ++frame) {
      const auto sample = static_cast<int16_t>(
          std::sin(2.0 * kPi * hz *
                   static_cast<double>(start_frame + frame) /
                   format.nSamplesPerSec) *
          22000.0);
      for (int channel = 0; channel < channels; ++channel) {
        samples[frame * channels + channel] = sample;
      }
    }
    return;
  }

  std::memset(output, 0, frames * format.nBlockAlign);
}

int wmain(int argc, wchar_t** argv) {
  const int seconds = argc > 1 ? (std::max)(1, _wtoi(argv[1])) : 8;
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

  IMMDevice* render_device = FindRenderEndpoint(enumerator, L"cable input");
  if (render_device == nullptr) {
    std::cerr << "CABLE Input render endpoint not found\n";
    enumerator->Release();
    CoUninitialize();
    return 2;
  }

  std::wcout << L"Playing " << seconds << L"s test tone to "
             << FriendlyName(render_device) << L"\n";

  IAudioClient* audio_client = nullptr;
  hr = render_device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                               reinterpret_cast<void**>(&audio_client));
  if (FAILED(hr)) {
    std::cerr << "Activate failed: 0x" << std::hex << hr << "\n";
    render_device->Release();
    enumerator->Release();
    CoUninitialize();
    return 3;
  }

  WAVEFORMATEX* mix_format = nullptr;
  hr = audio_client->GetMixFormat(&mix_format);
  if (FAILED(hr) || mix_format == nullptr) {
    std::cerr << "GetMixFormat failed: 0x" << std::hex << hr << "\n";
    audio_client->Release();
    render_device->Release();
    enumerator->Release();
    CoUninitialize();
    return 4;
  }

  const REFERENCE_TIME buffer_duration = 10000000LL * 80 / 1000;
  hr = audio_client->Initialize(AUDCLNT_SHAREMODE_SHARED, 0, buffer_duration,
                                0, mix_format, nullptr);
  if (FAILED(hr)) {
    std::cerr << "Initialize failed: 0x" << std::hex << hr << "\n";
    CoTaskMemFree(mix_format);
    audio_client->Release();
    render_device->Release();
    enumerator->Release();
    CoUninitialize();
    return 5;
  }

  IAudioRenderClient* render_client = nullptr;
  hr = audio_client->GetService(IID_PPV_ARGS(&render_client));
  if (FAILED(hr)) {
    std::cerr << "GetService failed: 0x" << std::hex << hr << "\n";
    CoTaskMemFree(mix_format);
    audio_client->Release();
    render_device->Release();
    enumerator->Release();
    CoUninitialize();
    return 6;
  }

  UINT32 buffer_frames = 0;
  audio_client->GetBufferSize(&buffer_frames);
  audio_client->Start();

  int64_t tone_frame = 0;
  const auto end_at =
      std::chrono::steady_clock::now() + std::chrono::seconds(seconds);
  while (std::chrono::steady_clock::now() < end_at) {
    UINT32 padding = 0;
    if (FAILED(audio_client->GetCurrentPadding(&padding))) {
      break;
    }
    const UINT32 available =
        buffer_frames > padding ? buffer_frames - padding : 0;
    if (available == 0) {
      std::this_thread::sleep_for(std::chrono::milliseconds(2));
      continue;
    }

    BYTE* output = nullptr;
    if (SUCCEEDED(render_client->GetBuffer(available, &output))) {
      WriteTone(output, available, *mix_format, tone_frame);
      tone_frame += available;
      render_client->ReleaseBuffer(available, 0);
    }
  }

  audio_client->Stop();
  render_client->Release();
  CoTaskMemFree(mix_format);
  audio_client->Release();
  render_device->Release();
  enumerator->Release();
  CoUninitialize();
  return 0;
}
