#include <audioclient.h>
#include <ksmedia.h>
#include <mmdeviceapi.h>
#include <objbase.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <iostream>
#include <string>
#include <thread>
#include <vector>

constexpr double kPi = 3.14159265358979323846;

std::wstring DeviceId(IMMDevice* device) {
  LPWSTR raw_id = nullptr;
  std::wstring id;
  if (SUCCEEDED(device->GetId(&raw_id)) && raw_id != nullptr) {
    id = raw_id;
    CoTaskMemFree(raw_id);
  }
  return id;
}

IMMDevice* FindEndpoint(IMMDeviceEnumerator* enumerator,
                        EDataFlow flow,
                        const std::wstring& token) {
  IMMDeviceCollection* collection = nullptr;
  if (FAILED(enumerator->EnumAudioEndpoints(flow, DEVICE_STATE_ACTIVE,
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
    const std::wstring id = DeviceId(device);
    std::wstring lower = id;
    std::transform(lower.begin(), lower.end(), lower.begin(), ::towlower);
    if (lower.find(token) != std::wstring::npos) {
      collection->Release();
      return device;
    }
    device->Release();
  }

  collection->Release();
  return nullptr;
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

float ReadSample(const BYTE* data, size_t index, const WAVEFORMATEX& format) {
  if (IsFloatFormat(format) && format.wBitsPerSample == 32) {
    return reinterpret_cast<const float*>(data)[index];
  }
  if (format.wBitsPerSample == 16) {
    return reinterpret_cast<const int16_t*>(data)[index] / 32768.0f;
  }
  return 0.0f;
}

void WriteTone(BYTE* output,
               UINT32 frames,
               const WAVEFORMATEX& format,
               int64_t start_frame) {
  const int channels = std::max<int>(1, format.nChannels);
  const double hz = 880.0;
  if (IsFloatFormat(format) && format.wBitsPerSample == 32) {
    auto* samples = reinterpret_cast<float*>(output);
    for (UINT32 frame = 0; frame < frames; ++frame) {
      const float sample = static_cast<float>(
          std::sin(2.0 * kPi * hz *
                   static_cast<double>(start_frame + frame) /
                   format.nSamplesPerSec) *
          0.45);
      for (int channel = 0; channel < channels; ++channel) {
        samples[frame * channels + channel] = sample;
      }
    }
    return;
  }

  std::memset(output, 0, frames * format.nBlockAlign);
}

int wmain(int argc, wchar_t** argv) {
  CoInitializeEx(nullptr, COINIT_MULTITHREADED);

  IMMDeviceEnumerator* enumerator = nullptr;
  if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
                              CLSCTX_ALL, IID_PPV_ARGS(&enumerator)))) {
    std::cerr << "No MMDeviceEnumerator\n";
    return 1;
  }

  const std::wstring render_token =
      argc > 1 ? argv[1] : L"d7cc8449-994b-4c25-bac5-e2cd44474c65";
  IMMDevice* render_device =
      FindEndpoint(enumerator, eRender, render_token);
  IMMDevice* capture_device =
      FindEndpoint(enumerator, eCapture, L"ef028424-65b9-4a6a-875d-993e8dc5186f");
  if (render_device == nullptr || capture_device == nullptr) {
    std::cerr << "VB-CABLE endpoints not found\n";
    return 1;
  }

  IAudioClient* render_audio = nullptr;
  IAudioClient* capture_audio = nullptr;
  render_device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                          reinterpret_cast<void**>(&render_audio));
  capture_device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                           reinterpret_cast<void**>(&capture_audio));

  WAVEFORMATEX* render_format = nullptr;
  WAVEFORMATEX* capture_format = nullptr;
  render_audio->GetMixFormat(&render_format);
  capture_audio->GetMixFormat(&capture_format);

  const REFERENCE_TIME buffer_duration = 10000000LL * 100 / 1000;
  HRESULT hr = render_audio->Initialize(AUDCLNT_SHAREMODE_SHARED, 0,
                                        buffer_duration, 0, render_format,
                                        nullptr);
  if (FAILED(hr)) {
    std::cerr << "Render initialize failed: 0x" << std::hex << hr << "\n";
    return 1;
  }
  hr = capture_audio->Initialize(AUDCLNT_SHAREMODE_SHARED, 0, buffer_duration,
                                 0, capture_format, nullptr);
  if (FAILED(hr)) {
    std::cerr << "Capture initialize failed: 0x" << std::hex << hr << "\n";
    return 1;
  }

  IAudioRenderClient* render_client = nullptr;
  IAudioCaptureClient* capture_client = nullptr;
  render_audio->GetService(IID_PPV_ARGS(&render_client));
  capture_audio->GetService(IID_PPV_ARGS(&capture_client));

  UINT32 render_buffer_frames = 0;
  render_audio->GetBufferSize(&render_buffer_frames);
  capture_audio->Start();
  render_audio->Start();

  double peak = 0.0;
  int64_t tone_frame = 0;
  const auto end_at = std::chrono::steady_clock::now() + std::chrono::seconds(3);
  while (std::chrono::steady_clock::now() < end_at) {
    UINT32 padding = 0;
    render_audio->GetCurrentPadding(&padding);
    const UINT32 available =
        render_buffer_frames > padding ? render_buffer_frames - padding : 0;
    if (available > 0) {
      BYTE* output = nullptr;
      if (SUCCEEDED(render_client->GetBuffer(available, &output))) {
        WriteTone(output, available, *render_format, tone_frame);
        tone_frame += available;
        render_client->ReleaseBuffer(available, 0);
      }
    }

    UINT32 packet_frames = 0;
    capture_client->GetNextPacketSize(&packet_frames);
    while (packet_frames > 0) {
      BYTE* data = nullptr;
      UINT32 frames = 0;
      DWORD flags = 0;
      if (FAILED(capture_client->GetBuffer(&data, &frames, &flags, nullptr,
                                           nullptr))) {
        break;
      }
      if ((flags & AUDCLNT_BUFFERFLAGS_SILENT) == 0) {
        const size_t sample_count =
            static_cast<size_t>(frames) * capture_format->nChannels;
        for (size_t index = 0; index < sample_count; ++index) {
          peak = std::max<double>(peak, std::abs(ReadSample(data, index,
                                                           *capture_format)));
        }
      }
      capture_client->ReleaseBuffer(frames);
      capture_client->GetNextPacketSize(&packet_frames);
    }

    std::this_thread::sleep_for(std::chrono::milliseconds(2));
  }

  render_audio->Stop();
  capture_audio->Stop();
  std::cout << "capturedPeak=" << peak << "\n";

  render_client->Release();
  capture_client->Release();
  CoTaskMemFree(render_format);
  CoTaskMemFree(capture_format);
  render_audio->Release();
  capture_audio->Release();
  render_device->Release();
  capture_device->Release();
  enumerator->Release();
  CoUninitialize();

  return peak > 0.05 ? 0 : 2;
}
