#ifndef NOMINMAX
#define NOMINMAX
#endif

#include <audioclient.h>
#include <ksmedia.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
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
#include <vector>

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

bool IsPcmFormat(const WAVEFORMATEX& format) {
  if (format.wFormatTag == WAVE_FORMAT_PCM) {
    return true;
  }
  if (format.wFormatTag != WAVE_FORMAT_EXTENSIBLE) {
    return false;
  }
  const auto& extensible =
      reinterpret_cast<const WAVEFORMATEXTENSIBLE&>(format);
  return IsEqualGUID(extensible.SubFormat, KSDATAFORMAT_SUBTYPE_PCM);
}

float Pcm16ToFloat(int16_t value) {
  return std::clamp(static_cast<float>(value) / 32768.0f, -1.0f, 1.0f);
}

int16_t FloatToPcm16(float value) {
  const float clipped = std::clamp(value, -1.0f, 1.0f);
  return static_cast<int16_t>(std::lrintf(clipped * 32767.0f));
}

float ReadSample(const BYTE* data, size_t index, const WAVEFORMATEX& format) {
  if (IsFloatFormat(format) && format.wBitsPerSample == 32) {
    return reinterpret_cast<const float*>(data)[index];
  }
  if (IsPcmFormat(format) && format.wBitsPerSample == 16) {
    return Pcm16ToFloat(reinterpret_cast<const int16_t*>(data)[index]);
  }
  if (IsPcmFormat(format) && format.wBitsPerSample == 24) {
    const BYTE* sample = data + index * 3;
    int32_t value = sample[0] | (sample[1] << 8) | (sample[2] << 16);
    if ((value & 0x00800000) != 0) {
      value |= 0xFF000000;
    }
    return std::clamp(static_cast<float>(value) / 8388608.0f, -1.0f, 1.0f);
  }
  return 0.0f;
}

IMMDevice* FindEndpoint(IMMDeviceEnumerator* enumerator,
                        EDataFlow flow,
                        const std::wstring& token) {
  IMMDeviceCollection* collection = nullptr;
  if (FAILED(enumerator->EnumAudioEndpoints(flow, DEVICE_STATE_ACTIVE,
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
    const bool is_bad_16ch = haystack.find(L"16ch") != std::wstring::npos ||
                             haystack.find(L"16 ch") != std::wstring::npos;
    if (haystack.find(lower_token) != std::wstring::npos && !is_bad_16ch) {
      collection->Release();
      return device;
    }
    device->Release();
  }

  collection->Release();
  return nullptr;
}

std::vector<int16_t> DecodeFile(const std::wstring& path,
                                int sample_rate,
                                int channels,
                                double gain,
                                double* peak) {
  std::vector<int16_t> pcm_out;
  if (FAILED(MFStartup(MF_VERSION))) {
    return pcm_out;
  }

  IMFSourceReader* reader = nullptr;
  HRESULT hr = MFCreateSourceReaderFromURL(path.c_str(), nullptr, &reader);
  if (FAILED(hr)) {
    MFShutdown();
    return pcm_out;
  }

  const DWORD all_streams = static_cast<DWORD>(MF_SOURCE_READER_ALL_STREAMS);
  const DWORD first_audio_stream =
      static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM);
  reader->SetStreamSelection(all_streams, FALSE);
  if (FAILED(reader->SetStreamSelection(first_audio_stream, TRUE))) {
    reader->Release();
    MFShutdown();
    return pcm_out;
  }

  IMFMediaType* media_type = nullptr;
  if (FAILED(MFCreateMediaType(&media_type))) {
    reader->Release();
    MFShutdown();
    return pcm_out;
  }

  const UINT32 bits_per_sample = 16;
  const UINT32 block_alignment =
      static_cast<UINT32>(channels * sizeof(int16_t));
  media_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
  media_type->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM);
  media_type->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS,
                        static_cast<UINT32>(channels));
  media_type->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND,
                        static_cast<UINT32>(sample_rate));
  media_type->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, bits_per_sample);
  media_type->SetUINT32(MF_MT_AUDIO_BLOCK_ALIGNMENT, block_alignment);
  media_type->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND,
                        static_cast<UINT32>(sample_rate) * block_alignment);

  hr = reader->SetCurrentMediaType(first_audio_stream, nullptr, media_type);
  media_type->Release();
  if (FAILED(hr)) {
    reader->Release();
    MFShutdown();
    return pcm_out;
  }

  while (true) {
    DWORD flags = 0;
    IMFSample* sample = nullptr;
    hr = reader->ReadSample(first_audio_stream, 0, nullptr, &flags, nullptr,
                            &sample);
    if (FAILED(hr)) {
      pcm_out.clear();
      break;
    }
    if ((flags & MF_SOURCE_READERF_ENDOFSTREAM) != 0) {
      break;
    }
    if (sample == nullptr) {
      continue;
    }

    IMFMediaBuffer* buffer = nullptr;
    hr = sample->ConvertToContiguousBuffer(&buffer);
    sample->Release();
    if (FAILED(hr)) {
      pcm_out.clear();
      break;
    }

    BYTE* data = nullptr;
    DWORD max_length = 0;
    DWORD current_length = 0;
    hr = buffer->Lock(&data, &max_length, &current_length);
    (void)max_length;
    if (FAILED(hr)) {
      buffer->Release();
      pcm_out.clear();
      break;
    }

    const size_t sample_count = current_length / sizeof(int16_t);
    const auto* pcm = reinterpret_cast<const int16_t*>(data);
    pcm_out.reserve(pcm_out.size() + sample_count);
    for (size_t index = 0; index < sample_count; ++index) {
      const float sample_value = Pcm16ToFloat(pcm[index]) *
                                 static_cast<float>(gain);
      *peak = std::max<double>(*peak, std::abs(sample_value));
      pcm_out.push_back(FloatToPcm16(sample_value));
    }
    buffer->Unlock();
    buffer->Release();
  }

  reader->Release();
  MFShutdown();
  return pcm_out;
}

void WritePcm(BYTE* output,
              UINT32 frames,
              const WAVEFORMATEX& format,
              const int16_t* pcm) {
  const int channels = std::max<int>(1, format.nChannels);
  const size_t sample_count = static_cast<size_t>(frames) * channels;
  if (IsFloatFormat(format) && format.wBitsPerSample == 32) {
    auto* samples = reinterpret_cast<float*>(output);
    for (size_t index = 0; index < sample_count; ++index) {
      samples[index] = Pcm16ToFloat(pcm[index]);
    }
    return;
  }
  if (IsPcmFormat(format) && format.wBitsPerSample == 16) {
    auto* samples = reinterpret_cast<int16_t*>(output);
    for (size_t index = 0; index < sample_count; ++index) {
      samples[index] = pcm[index];
    }
    return;
  }
  std::memset(output, 0, frames * format.nBlockAlign);
}

int wmain(int argc, wchar_t** argv) {
  if (argc < 2) {
    std::wcerr << L"Usage: play_file_to_vbcable.exe <audio-file> [gain]\n";
    return 64;
  }
  const std::wstring path = argv[1];
  const double gain = argc > 2 ? std::wcstod(argv[2], nullptr) : 1.0;

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

  IMMDevice* render_device = FindEndpoint(enumerator, eRender, L"cable input");
  IMMDevice* capture_device =
      FindEndpoint(enumerator, eCapture, L"cable output");
  if (render_device == nullptr || capture_device == nullptr) {
    std::cerr << "VB-CABLE endpoints not found\n";
    if (render_device) render_device->Release();
    if (capture_device) capture_device->Release();
    enumerator->Release();
    CoUninitialize();
    return 2;
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

  double decoded_peak = 0.0;
  auto pcm = DecodeFile(path, static_cast<int>(render_format->nSamplesPerSec),
                        std::max<int>(1, render_format->nChannels), gain,
                        &decoded_peak);
  if (pcm.empty()) {
    std::wcerr << L"Unable to decode: " << path << L"\n";
    CoTaskMemFree(render_format);
    CoTaskMemFree(capture_format);
    render_audio->Release();
    capture_audio->Release();
    render_device->Release();
    capture_device->Release();
    enumerator->Release();
    CoUninitialize();
    return 3;
  }

  const REFERENCE_TIME buffer_duration = 10000000LL * 100 / 1000;
  hr = render_audio->Initialize(AUDCLNT_SHAREMODE_SHARED, 0, buffer_duration,
                                0, render_format, nullptr);
  if (FAILED(hr)) {
    std::cerr << "Render initialize failed: 0x" << std::hex << hr << "\n";
    return 4;
  }
  hr = capture_audio->Initialize(AUDCLNT_SHAREMODE_SHARED, 0, buffer_duration,
                                 0, capture_format, nullptr);
  if (FAILED(hr)) {
    std::cerr << "Capture initialize failed: 0x" << std::hex << hr << "\n";
    return 5;
  }

  IAudioRenderClient* render_client = nullptr;
  IAudioCaptureClient* capture_client = nullptr;
  render_audio->GetService(IID_PPV_ARGS(&render_client));
  capture_audio->GetService(IID_PPV_ARGS(&capture_client));

  UINT32 render_buffer_frames = 0;
  render_audio->GetBufferSize(&render_buffer_frames);
  const int channels = std::max<int>(1, render_format->nChannels);
  const size_t total_frames = pcm.size() / channels;
  size_t offset_frames = 0;
  double captured_peak = 0.0;

  std::wcout << L"Playing " << path << L" to " << FriendlyName(render_device)
             << L"\n";
  std::cout << "decodedFrames=" << total_frames
            << " decodedPeak=" << decoded_peak << "\n";

  capture_audio->Start();
  render_audio->Start();

  const auto drain_until =
      [&] { return std::chrono::steady_clock::now() + std::chrono::seconds(1); };
  auto end_at = std::chrono::steady_clock::time_point::max();
  bool draining = false;

  while (true) {
    if (offset_frames < total_frames) {
      UINT32 padding = 0;
      render_audio->GetCurrentPadding(&padding);
      const UINT32 available =
          render_buffer_frames > padding ? render_buffer_frames - padding : 0;
      if (available > 0) {
        const UINT32 frames_to_write = static_cast<UINT32>(
            std::min<size_t>(available, total_frames - offset_frames));
        BYTE* output = nullptr;
        if (SUCCEEDED(render_client->GetBuffer(frames_to_write, &output))) {
          WritePcm(output, frames_to_write, *render_format,
                   pcm.data() + offset_frames * channels);
          render_client->ReleaseBuffer(frames_to_write, 0);
          offset_frames += frames_to_write;
        }
      }
    } else if (!draining) {
      draining = true;
      end_at = drain_until();
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
          captured_peak = std::max<double>(
              captured_peak, std::abs(ReadSample(data, index, *capture_format)));
        }
      }
      capture_client->ReleaseBuffer(frames);
      capture_client->GetNextPacketSize(&packet_frames);
    }

    if (draining && std::chrono::steady_clock::now() >= end_at) {
      break;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
  }

  render_audio->Stop();
  capture_audio->Stop();
  std::cout << "capturedPeak=" << captured_peak << "\n";

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

  return captured_peak > 0.05 ? 0 : 6;
}
