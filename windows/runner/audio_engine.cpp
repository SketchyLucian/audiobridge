#include "audio_engine.h"

#include <winsock2.h>
#include <ws2tcpip.h>

#include <audioclient.h>
#include <avrt.h>
#include <cmath>
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <cwchar>
#include <iphlpapi.h>
#include <ksmedia.h>
#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <mmdeviceapi.h>
#include <mmreg.h>
#include <objbase.h>
#include <propsys.h>
#include <propvarutil.h>
#include <functiondiscoverykeys_devpkey.h>
#include <cwctype>
#include <initguid.h>
#include <setupapi.h>
#include <usb.h>
#include <usbiodef.h>
#include <winusb.h>
#include <wrl/client.h>

#include "opus.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <cctype>
#include <chrono>
#include <condition_variable>
#include <deque>
#include <fstream>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <vector>

namespace {

void UsbDebugLog(const std::string& message) {
  static std::mutex log_mutex;
  std::scoped_lock lock(log_mutex);

  SYSTEMTIME now = {};
  GetLocalTime(&now);
  char line[2048] = {};
  std::snprintf(line, sizeof(line),
                "%04u-%02u-%02u %02u:%02u:%02u.%03u %s\n",
                now.wYear, now.wMonth, now.wDay, now.wHour, now.wMinute,
                now.wSecond, now.wMilliseconds, message.c_str());

  char temp_path[MAX_PATH] = {};
  const DWORD temp_length = GetTempPathA(MAX_PATH, temp_path);
  const std::string path =
      temp_length > 0 ? std::string(temp_path) + "AudioBridgeNativeUsb.log"
                      : "AudioBridgeNativeUsb.log";
  std::ofstream file(path, std::ios::app);
  file << line;
  OutputDebugStringA(line);
}

std::string Narrow(const std::wstring& value) {
  if (value.empty()) {
    return {};
  }
  const int size = WideCharToMultiByte(CP_UTF8, 0, value.c_str(),
                                      static_cast<int>(value.size()), nullptr,
                                      0, nullptr, nullptr);
  if (size <= 0) {
    return {};
  }
  std::string output(size, '\0');
  WideCharToMultiByte(CP_UTF8, 0, value.c_str(),
                      static_cast<int>(value.size()), output.data(), size,
                      nullptr, nullptr);
  return output;
}

std::wstring Widen(const std::string& value) {
  if (value.empty()) {
    return {};
  }
  const int size = MultiByteToWideChar(CP_UTF8, 0, value.c_str(),
                                       static_cast<int>(value.size()),
                                       nullptr, 0);
  if (size <= 0) {
    return {};
  }
  std::wstring output(size, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, value.c_str(),
                      static_cast<int>(value.size()), output.data(), size);
  return output;
}

std::string GuidToString(const GUID& guid) {
  wchar_t buffer[64] = {};
  if (StringFromGUID2(guid, buffer,
                      static_cast<int>(sizeof(buffer) / sizeof(buffer[0]))) <=
      0) {
    return {};
  }
  return Narrow(buffer);
}

constexpr int kAudioPort = 47885;
constexpr int kMaxPacketBytes = 1200;
constexpr int kUsbFrameHeaderBytes = 4;
constexpr int kPacketHeaderBytes = 16;
constexpr int kPacketV2HeaderBytes = 24;
constexpr int kPacketV3HeaderBytes = 48;
constexpr int kPacketV4HeaderBytes = 56;
constexpr int kPacketV5HeaderBytes = 64;
constexpr int kLowDelayTrafficClass = 0xB8;
constexpr int kAudioSocketBufferBytes = 256 * 1024;
constexpr int kMinBufferMs = 5;
constexpr int kMaxBufferMs = 500;
constexpr int kLowLatencyPerformanceMaxMs = 80;
constexpr int64_t kSourceIdleTimeoutMs = 1200;
constexpr int64_t kPeerHeartbeatTimeoutMs = 3000;
constexpr int64_t kHeartbeatIntervalMs = 800;
constexpr char kSubscribePrefix[] = "ABR_SUBSCRIBE";
constexpr size_t kSubscribeMaxBytes = 2048;
constexpr char kReceiverSupportedCodecs[] = "pcm";
constexpr uint16_t kAoaGetProtocol = 51;
constexpr uint16_t kAoaSendString = 52;
constexpr uint16_t kAoaStart = 53;
constexpr uint16_t kAoaStringManufacturer = 0;
constexpr uint16_t kAoaStringModel = 1;
constexpr uint16_t kAoaStringDescription = 2;
constexpr uint16_t kAoaStringVersion = 3;
constexpr uint16_t kAoaStringUri = 4;
constexpr uint16_t kAoaStringSerial = 5;
constexpr uint16_t kAoaAccessoryVid = 0x18D1;
constexpr uint16_t kAoaAccessoryPid = 0x2D00;
constexpr uint16_t kAoaAccessoryAdbPid = 0x2D01;
constexpr char kAoaManufacturer[] = "AudioBridge";
constexpr char kAoaModel[] = "AudioBridge Native USB";
constexpr char kAoaDescription[] = "Low-latency audio relay";
constexpr char kAoaVersion[] = "1.0";
constexpr char kAoaUri[] = "https://example.invalid/audiobridge";
constexpr char kAoaSerial[] = "audiobridge-native-usb";
constexpr char kAoaAccessoryUnavailable[] =
    "Android accessory interface is not available yet.";
constexpr uint32_t kPacketMagic = 0x31524241;  // ABR1, little-endian.
constexpr uint32_t kPacketV2Magic = 0x32524241;  // ABR2, little-endian.
constexpr uint32_t kPacketV3Magic = 0x33524241;  // ABR3, little-endian.
constexpr uint32_t kPacketV4Magic = 0x34524241;  // ABR4, little-endian.
constexpr uint32_t kPacketV5Magic = 0x35524241;  // ABR5, little-endian.
constexpr uint16_t kCodecPcm = 0;
constexpr uint16_t kCodecOpus = 1;
constexpr uint16_t kCodecAac = 2;
constexpr uint16_t kCodecG711MuLaw = 8;
constexpr uint16_t kCodecG711ALaw = 9;
constexpr uint16_t kCodecImaAdpcm = 10;
constexpr uint16_t kPacketKindAudio = 0;
constexpr uint16_t kPacketKindHeartbeat = 1;
constexpr uint16_t kPacketFlagMuted = 1;
constexpr uint32_t kReceiverOptionAdaptiveBuffer = 1;
constexpr int kReceiverOptionModeShift = 4;
constexpr uint32_t kReceiverOptionModeMask = 3u << kReceiverOptionModeShift;
constexpr int kReceiverOptionCustomCapShift = 8;
constexpr uint32_t kReceiverOptionCustomCapMask =
    0x1FFu << kReceiverOptionCustomCapShift;
constexpr int kReceiverOptionBitrateShift = 20;
constexpr uint32_t kReceiverOptionBitrateMask =
    0xFFFu << kReceiverOptionBitrateShift;
constexpr int kAacSamplesPerFrame = 1024;
constexpr int kOpusSampleRate = 48000;
constexpr int kOpusLowFrameSamples = kOpusSampleRate * 25 / 10000;
constexpr int kOpusShortFrameMs = 5;
constexpr int kOpusLongFrameMs = 10;
constexpr int kOpusShortFrameSamples =
    kOpusSampleRate * kOpusShortFrameMs / 1000;
constexpr int kOpusLongFrameSamples =
    kOpusSampleRate * kOpusLongFrameMs / 1000;
constexpr int kOpusMaxPacketBytes = 4000;
constexpr int64_t kSequenceModulus = 0x100000000LL;
constexpr int kAdaptiveBufferCooldownMs = 1500;
constexpr int kAdaptiveBufferRelaxMs = 6000;
constexpr int kAdaptiveBufferFastRelaxMs = 2500;
constexpr int64_t kAdaptivePlaybackStartGraceMs = 1000;
constexpr int kAdaptiveUnderrunSlowWindowMs = 15000;
constexpr int kAdaptiveAcceptableUnderrunsPerSlowWindow = 4;
constexpr int kAdaptiveUnderrunBurstWindowMs = 2000;
constexpr int kAdaptiveAcceptableUnderrunsPerBurst = 3;
constexpr int64_t kAdaptiveLowQueueDivisor = 4;
constexpr int kAdaptiveLowQueueGrowthSamples = 3;
constexpr int kAdaptiveLowLatencyStepMs = 4;
constexpr int kAdaptiveBalancedStepMs = 8;
constexpr int kAdaptiveStableStepMs = 20;
constexpr int kAdaptiveGamingCapMs = 120;
constexpr int kAdaptiveBalancedCapMs = 240;
constexpr int64_t kAdaptiveDelaySampleIntervalMs = 500;
constexpr size_t kAdaptiveDelayHistorySamples = 32;
constexpr size_t kAdaptiveDelayMinHistorySamples = 4;
constexpr double kAdaptiveDelayQuantile = 0.75;
constexpr int kAdaptiveDelayHeadroomNumerator = 3;
constexpr int kAdaptiveDelayHeadroomDenominator = 5;
constexpr double kAdaptiveDelayMaxMs = 2000.0;
constexpr int64_t kAdaptiveSequenceResetGap = 50;
constexpr int kAdaptiveNetworkTargetHysteresisMs = 3;
constexpr int kAdaptiveFastRelaxMarginMs = 8;
constexpr double kAdaptiveAudibleSignalFloor = 0.001;
constexpr int kPlaybackCatchUpGuardMs = 4;
constexpr int kPlaybackCatchUpMaxReductionDivisor = 50;

DEFINE_GUID(kAndroidWinUsbInterfaceGuid, 0xf72fe0d4, 0xcbcb, 0x407d, 0x88,
            0x14, 0x9e, 0xd6, 0x73, 0xd0, 0xdd, 0x6b);
DEFINE_GUID(kWinUsbDeviceInterfaceGuid, 0xdee824ef, 0x729b, 0x4a0e, 0x9c,
            0x14, 0xb7, 0x11, 0x7d, 0x33, 0xa8, 0x17);

enum class AudioCodec {
  kPcm,
  kOpus,
  kAac,
  kG711MuLaw,
  kG711ALaw,
  kImaAdpcm,
};

enum class AudioMode {
  kBalanced,
  kGaming,
  kMusic,
  kCustom,
};

bool ShouldGrowAdaptiveBufferForLowQueue(int low_queue_samples) {
  return low_queue_samples >= kAdaptiveLowQueueGrowthSamples;
}

int AdaptiveBufferIncreaseTargetMs(int current_ms, int step_ms,
                                   int network_floor_ms,
                                   bool pressure_increase,
                                   bool network_floor_increase) {
  const int step_target_ms = current_ms + step_ms;
  return pressure_increase || network_floor_increase
             ? std::max(step_target_ms, network_floor_ms)
             : step_target_ms;
}

int PlaybackCatchUpFrameCount(int packet_frames, int64_t queued_frames,
                              int64_t target_frames, int sample_rate) {
  if (packet_frames <= 0) {
    return 0;
  }
  if (sample_rate <= 0 || target_frames <= 0) {
    return packet_frames;
  }

  const int64_t guard_frames =
      std::max<int64_t>(packet_frames,
                        static_cast<int64_t>(sample_rate) *
                            kPlaybackCatchUpGuardMs / 1000);
  const int64_t excess_frames =
      queued_frames - target_frames - guard_frames;
  if (excess_frames <= 0) {
    return packet_frames;
  }

  const int64_t correction_range_frames =
      std::max<int64_t>(target_frames,
                        static_cast<int64_t>(sample_rate) * 20 / 1000);
  const int64_t proportional_reduction =
      (excess_frames * packet_frames + correction_range_frames - 1) /
      correction_range_frames;
  const int max_reduction =
      std::max(1, (packet_frames + kPlaybackCatchUpMaxReductionDivisor - 1) /
                      kPlaybackCatchUpMaxReductionDivisor);
  const int frames_to_remove = static_cast<int>(
      std::clamp<int64_t>(proportional_reduction, 1, max_reduction));
  return std::max(1, packet_frames - frames_to_remove);
}

double PacketArrivalDelaySampleMs(double elapsed_ms, double expected_ms) {
  if (!std::isfinite(elapsed_ms) || !std::isfinite(expected_ms)) {
    return 0.0;
  }
  return std::clamp(elapsed_ms - expected_ms, 0.0, kAdaptiveDelayMaxMs);
}

enum class TransportMode {
  kWifi,
  kUsb,
};

struct AudioProfile {
  AudioMode mode = AudioMode::kBalanced;
  AudioCodec codec = AudioCodec::kPcm;
  int sample_rate = 48000;
  int channels = 2;
  int bitrate_kbps = 192;
  int latency_ms = 35;
  int capture_buffer_ms = 35;
  int playback_buffer_ms = 35;
  int packet_time_ms = 3;
  bool receiver_adaptive_buffer = true;
  int adaptive_buffer_cap_ms = 0;
};

struct Endpoint {
  sockaddr_in address = {};
  bool available = false;
  uint64_t session_id = 0;
};

struct ReceiverSource {
  sockaddr_in address = {};
  bool available = false;
};

struct PcmPlaybackPacket {
  std::vector<int16_t> pcm;
  int sample_rate = 48000;
  int channels = 2;
  uint16_t flags = 0;
};

struct EncodedAudioPacket {
  std::vector<uint8_t> payload;
  uint16_t codec_id = kCodecPcm;
  uint16_t packet_kind = kPacketKindAudio;
  uint16_t flags = 0;
  uint32_t decoded_frame_count = 0;
};

struct RemoteReceiverClockEcho {
  int64_t receiver_time_ms = 0;
  int64_t received_at_sender_time_ms = 0;
};

struct SoundEffectClip {
  std::vector<int16_t> pcm;
  size_t sample_offset = 0;
  int sample_rate = 48000;
  int channels = 2;
};

struct SoundboardOutputFormat {
  int sample_rate = 48000;
  int channels = 2;
};

int HexDigitValue(wchar_t digit) {
  if (digit >= L'0' && digit <= L'9') {
    return static_cast<int>(digit - L'0');
  }
  if (digit >= L'A' && digit <= L'F') {
    return 10 + static_cast<int>(digit - L'A');
  }
  return -1;
}

std::wstring Uppercase(std::wstring value) {
  std::transform(value.begin(), value.end(), value.begin(),
                 [](wchar_t item) {
                   return static_cast<wchar_t>(std::towupper(item));
                 });
  return value;
}

bool DevicePathContains(const std::wstring& path, const wchar_t* token) {
  return Uppercase(path).find(token) != std::wstring::npos;
}

bool IsLikelyVirtualCableEndpoint(const std::wstring& value) {
  const std::wstring label = Uppercase(value);
  return label.find(L"VB-AUDIO") != std::wstring::npos ||
         label.find(L"VIRTUAL AUDIO") != std::wstring::npos ||
         label.find(L"VIRTUAL CABLE") != std::wstring::npos ||
         label.find(L"VOICEMEETER") != std::wstring::npos ||
         label.find(L"CABLE INPUT") != std::wstring::npos ||
         label.find(L"CABLE-A INPUT") != std::wstring::npos ||
         label.find(L"CABLE-B INPUT") != std::wstring::npos ||
         (label.find(L"LINE 1") != std::wstring::npos &&
          label.find(L"VIRTUAL") != std::wstring::npos);
}

bool IsUnsupportedVirtualCableRenderEndpoint(const std::wstring& name,
                                             const std::wstring& id) {
  const std::wstring label = Uppercase(name + L" " + id);
  const bool is_vb_cable = label.find(L"VB-AUDIO") != std::wstring::npos ||
                           label.find(L"VIRTUAL CABLE") != std::wstring::npos;
  const bool is_16_channel = label.find(L"16CH") != std::wstring::npos ||
                             label.find(L"16 CH") != std::wstring::npos;
  const bool is_cable_input = label.find(L"CABLE IN") != std::wstring::npos ||
                              label.find(L"CABLE INPUT") != std::wstring::npos;
  return is_vb_cable && is_16_channel && is_cable_input;
}

bool IsAoaAccessoryDevice(const USB_DEVICE_DESCRIPTOR& descriptor) {
  return descriptor.idVendor == kAoaAccessoryVid &&
         (descriptor.idProduct == kAoaAccessoryPid ||
          descriptor.idProduct == kAoaAccessoryAdbPid);
}

bool IsKnownAndroidUsbVendor(uint16_t vendor_id) {
  switch (vendor_id) {
    case 0x04E8:  // Samsung
    case 0x0BB4:  // HTC
    case 0x0FCE:  // Sony
    case 0x1004:  // LG
    case 0x12D1:  // Huawei/Honor
    case 0x17EF:  // Lenovo
    case 0x18D1:  // Google
    case 0x19D2:  // ZTE
    case 0x22B8:  // Motorola
    case 0x22D9:  // OPPO
    case 0x2717:  // Xiaomi
    case 0x2A70:  // OnePlus
    case 0x2D95:  // Vivo
      return true;
    default:
      return false;
  }
}

bool IsAndroidAccessoryNegotiationPath(
    const std::wstring& path,
    const USB_DEVICE_DESCRIPTOR& descriptor) {
  if (IsAoaAccessoryDevice(descriptor)) {
    return false;
  }

  return DevicePathContains(
             path, L"F72FE0D4-CBCB-407D-8814-9ED673D0DD6B") ||
         IsKnownAndroidUsbVendor(descriptor.idVendor);
}

std::optional<uint16_t> ReadUsbIdFromDevicePath(const std::wstring& path,
                                                const wchar_t* token) {
  const std::wstring upper_path = Uppercase(path);

  const std::wstring token_string(token);
  const size_t position = upper_path.find(token_string);
  if (position == std::wstring::npos ||
      position + token_string.size() + 4 > upper_path.size()) {
    return std::nullopt;
  }

  uint16_t value = 0;
  for (size_t index = position + token_string.size();
       index < position + token_string.size() + 4; ++index) {
    const int digit = HexDigitValue(upper_path[index]);
    if (digit < 0) {
      return std::nullopt;
    }
    value = static_cast<uint16_t>((value << 4) | digit);
  }
  return value;
}

std::optional<USB_DEVICE_DESCRIPTOR> ReadUsbDeviceDescriptorFromPath(
    const std::wstring& path) {
  const auto vendor_id = ReadUsbIdFromDevicePath(path, L"VID_");
  const auto product_id = ReadUsbIdFromDevicePath(path, L"PID_");
  if (!vendor_id.has_value() || !product_id.has_value()) {
    return std::nullopt;
  }

  USB_DEVICE_DESCRIPTOR descriptor = {};
  descriptor.idVendor = vendor_id.value();
  descriptor.idProduct = product_id.value();
  return descriptor;
}

bool IsAoaAccessoryAudioInterfacePath(const std::wstring& path,
                                      const USB_DEVICE_DESCRIPTOR& descriptor) {
  if (descriptor.idVendor != kAoaAccessoryVid) {
    return false;
  }
  if (descriptor.idProduct == kAoaAccessoryPid) {
    return !DevicePathContains(path, L"MI_01");
  }
  if (descriptor.idProduct == kAoaAccessoryAdbPid) {
    return DevicePathContains(path, L"MI_00");
  }
  return false;
}

void AppendUniqueGuid(std::vector<GUID>* guids, const GUID& guid) {
  for (const GUID& existing : *guids) {
    if (IsEqualGUID(existing, guid)) {
      return;
    }
  }
  UsbDebugLog("adding USB interface GUID " + GuidToString(guid));
  guids->push_back(guid);
}

void AppendRegistryDeviceInterfaceGuids(std::vector<GUID>* guids, HKEY key) {
  DWORD type = 0;
  DWORD bytes = 0;
  if (RegQueryValueExW(key, L"DeviceInterfaceGUIDs", nullptr, &type, nullptr,
                       &bytes) != ERROR_SUCCESS ||
      bytes < sizeof(wchar_t) ||
      (type != REG_SZ && type != REG_MULTI_SZ)) {
    return;
  }

  std::vector<wchar_t> buffer(bytes / sizeof(wchar_t) + 2, L'\0');
  if (RegQueryValueExW(key, L"DeviceInterfaceGUIDs", nullptr, &type,
                       reinterpret_cast<LPBYTE>(buffer.data()),
                       &bytes) != ERROR_SUCCESS) {
    return;
  }

  const auto append_guid_string = [guids](const wchar_t* value) {
    if (value == nullptr || value[0] == L'\0') {
      return;
    }
    GUID guid = {};
    if (SUCCEEDED(CLSIDFromString(value, &guid))) {
      AppendUniqueGuid(guids, guid);
    }
  };

  if (type == REG_SZ) {
    append_guid_string(buffer.data());
    return;
  }

  const wchar_t* cursor = buffer.data();
  while (*cursor != L'\0') {
    append_guid_string(cursor);
    cursor += std::wcslen(cursor) + 1;
  }
}

std::vector<GUID> DiscoverAoaAccessoryAudioInterfaceGuids() {
  std::vector<GUID> guids;
  UsbDebugLog("discovering AOA accessory interface GUIDs");
  HDEVINFO info = SetupDiGetClassDevsW(nullptr, L"USB", nullptr,
                                       DIGCF_ALLCLASSES | DIGCF_PRESENT);
  if (info == INVALID_HANDLE_VALUE) {
    UsbDebugLog("SetupDiGetClassDevsW USB devices failed: " +
                std::to_string(GetLastError()));
    return guids;
  }

  for (DWORD index = 0;; ++index) {
    SP_DEVINFO_DATA device_info = {};
    device_info.cbSize = sizeof(device_info);
    if (!SetupDiEnumDeviceInfo(info, index, &device_info)) {
      break;
    }

    DWORD required_size = 0;
    SetupDiGetDeviceInstanceIdW(info, &device_info, nullptr, 0,
                                &required_size);
    if (required_size == 0) {
      continue;
    }

    std::vector<wchar_t> instance_id(required_size, L'\0');
    if (!SetupDiGetDeviceInstanceIdW(info, &device_info, instance_id.data(),
                                     required_size, nullptr)) {
      continue;
    }

    const std::wstring instance_id_text(instance_id.data());
    const auto descriptor = ReadUsbDeviceDescriptorFromPath(instance_id_text);
    if (!descriptor.has_value() ||
        !IsAoaAccessoryAudioInterfacePath(instance_id_text,
                                          descriptor.value())) {
      continue;
    }

    UsbDebugLog("found AOA audio device instance " + Narrow(instance_id_text));

    HKEY key = SetupDiOpenDevRegKey(info, &device_info, DICS_FLAG_GLOBAL, 0,
                                    DIREG_DEV, KEY_READ);
    if (key == INVALID_HANDLE_VALUE) {
      UsbDebugLog("SetupDiOpenDevRegKey failed: " +
                  std::to_string(GetLastError()));
      continue;
    }
    AppendRegistryDeviceInterfaceGuids(&guids, key);
    RegCloseKey(key);
  }

  SetupDiDestroyDeviceInfoList(info);
  return guids;
}

int ReadInt(const flutter::EncodableMap& map, const char* key, int fallback) {
  const auto value = map.find(flutter::EncodableValue(key));
  if (value == map.end()) {
    return fallback;
  }

  if (std::holds_alternative<int>(value->second)) {
    return std::get<int>(value->second);
  }
  if (std::holds_alternative<int64_t>(value->second)) {
    return static_cast<int>(std::get<int64_t>(value->second));
  }
  if (std::holds_alternative<double>(value->second)) {
    return static_cast<int>(std::get<double>(value->second));
  }
  return fallback;
}

double ReadDouble(const flutter::EncodableMap& map, const char* key,
                  double fallback) {
  const auto value = map.find(flutter::EncodableValue(key));
  if (value == map.end()) {
    return fallback;
  }

  if (std::holds_alternative<double>(value->second)) {
    return std::get<double>(value->second);
  }
  if (std::holds_alternative<int>(value->second)) {
    return std::get<int>(value->second);
  }
  if (std::holds_alternative<int64_t>(value->second)) {
    return static_cast<double>(std::get<int64_t>(value->second));
  }
  return fallback;
}

bool ReadBool(const flutter::EncodableMap& map, const char* key,
              bool fallback) {
  const auto value = map.find(flutter::EncodableValue(key));
  if (value == map.end() || !std::holds_alternative<bool>(value->second)) {
    return fallback;
  }
  return std::get<bool>(value->second);
}

std::string ReadString(const flutter::EncodableMap& map, const char* key,
                       const std::string& fallback) {
  const auto value = map.find(flutter::EncodableValue(key));
  if (value == map.end() || !std::holds_alternative<std::string>(value->second)) {
    return fallback;
  }
  return std::get<std::string>(value->second);
}

std::string ReadArgumentString(const flutter::EncodableValue* arguments,
                               const char* key,
                               const std::string& fallback = "") {
  if (!arguments || !std::holds_alternative<flutter::EncodableMap>(*arguments)) {
    return fallback;
  }
  return ReadString(std::get<flutter::EncodableMap>(*arguments), key, fallback);
}

AudioCodec ReadCodec(const flutter::EncodableMap& map) {
  const std::string codec = ReadString(map, "codec", "pcm");
  if (codec == "opus") {
    return AudioCodec::kOpus;
  }
  if (codec == "aac") {
    return AudioCodec::kAac;
  }
  if (codec == "g711MuLaw") {
    return AudioCodec::kG711MuLaw;
  }
  if (codec == "g711ALaw") {
    return AudioCodec::kG711ALaw;
  }
  if (codec == "imaAdpcm") {
    return AudioCodec::kImaAdpcm;
  }
  return AudioCodec::kPcm;
}

AudioMode ReadMode(const flutter::EncodableMap& map) {
  const std::string mode = ReadString(map, "mode", "balanced");
  if (mode == "gaming" || mode == "game" || mode == "lowLatency") {
    return AudioMode::kGaming;
  }
  if (mode == "music" || mode == "stable" || mode == "stability") {
    return AudioMode::kMusic;
  }
  if (mode == "custom" || mode == "user" || mode == "manual") {
    return AudioMode::kCustom;
  }
  return AudioMode::kBalanced;
}

AudioMode ModeFromPacketId(uint32_t mode_id) {
  switch (mode_id) {
    case 1:
      return AudioMode::kGaming;
    case 2:
      return AudioMode::kMusic;
    case 3:
      return AudioMode::kCustom;
    default:
      return AudioMode::kBalanced;
  }
}

uint32_t ModePacketId(AudioMode mode) {
  switch (mode) {
    case AudioMode::kGaming:
      return 1;
    case AudioMode::kMusic:
      return 2;
    case AudioMode::kCustom:
      return 3;
    case AudioMode::kBalanced:
      return 0;
  }
  return 0;
}

std::string ModeName(AudioMode mode) {
  switch (mode) {
    case AudioMode::kGaming:
      return "gaming";
    case AudioMode::kMusic:
      return "music";
    case AudioMode::kCustom:
      return "custom";
    case AudioMode::kBalanced:
      return "balanced";
  }
  return "balanced";
}

uint32_t ReceiverOptionsFor(const AudioProfile& profile) {
  const uint32_t adaptive =
      profile.receiver_adaptive_buffer ? kReceiverOptionAdaptiveBuffer : 0;
  const uint32_t bitrate =
      static_cast<uint32_t>(std::clamp(profile.bitrate_kbps, 0, 0xFFF));
  return adaptive |
         ((ModePacketId(profile.mode) << kReceiverOptionModeShift) &
          kReceiverOptionModeMask) |
         ((std::clamp(profile.adaptive_buffer_cap_ms, 0, kMaxBufferMs)
           << kReceiverOptionCustomCapShift) &
          kReceiverOptionCustomCapMask) |
         ((bitrate << kReceiverOptionBitrateShift) &
          kReceiverOptionBitrateMask);
}

int64_t NowMillis() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}

uint64_t GenerateSessionId() {
  static std::atomic<uint64_t> counter{1};
  const uint64_t clock = static_cast<uint64_t>(NowMillis());
  const uint64_t process = static_cast<uint64_t>(GetCurrentProcessId());
  const uint64_t value =
      (clock << 21) ^ (process << 9) ^ counter.fetch_add(1);
  return (value & static_cast<uint64_t>(INT64_MAX)) | 1u;
}

std::string WideToUtf8(const wchar_t* value) {
  if (!value || value[0] == L'\0') {
    return "";
  }

  const int required = WideCharToMultiByte(CP_UTF8, 0, value, -1, nullptr, 0,
                                           nullptr, nullptr);
  if (required <= 1) {
    return "";
  }

  std::string result(static_cast<size_t>(required - 1), '\0');
  WideCharToMultiByte(CP_UTF8, 0, value, -1, result.data(), required, nullptr,
                      nullptr);
  return result;
}

int OpusFrameSamplesForPacketTime(int packet_time_ms) {
  if (packet_time_ms <= 2) {
    return kOpusLowFrameSamples;
  }
  return packet_time_ms <= kOpusShortFrameMs ? kOpusShortFrameSamples
                                             : kOpusLongFrameSamples;
}

bool IsSupportedOpusFrameSamples(int frame_samples) {
  return frame_samples == kOpusLowFrameSamples ||
         frame_samples == kOpusShortFrameSamples ||
         frame_samples == kOpusLongFrameSamples;
}

std::optional<double> ParseDoubleMetric(const std::string& message,
                                        const char* key) {
  const std::string token = std::string(key) + "=";
  const size_t position = message.find(token);
  if (position == std::string::npos) {
    return std::nullopt;
  }

  const char* start = message.c_str() + position + token.size();
  char* end = nullptr;
  const double value = std::strtod(start, &end);
  if (end == start || !std::isfinite(value)) {
    return std::nullopt;
  }
  return value;
}

std::optional<int64_t> ParseIntMetric(const std::string& message,
                                      const char* key) {
  const std::string token = std::string(key) + "=";
  const size_t position = message.find(token);
  if (position == std::string::npos) {
    return std::nullopt;
  }

  const char* start = message.c_str() + position + token.size();
  char* end = nullptr;
  const long long value = std::strtoll(start, &end, 10);
  if (end == start) {
    return std::nullopt;
  }
  return static_cast<int64_t>(value);
}

std::optional<std::string> ParseStringMetric(const std::string& message,
                                             const char* key) {
  const std::string token = std::string(key) + "=";
  const size_t position = message.find(token);
  if (position == std::string::npos) {
    return std::nullopt;
  }

  const size_t value_start = position + token.size();
  const size_t value_end = message.find(' ', value_start);
  std::string value = message.substr(
      value_start,
      value_end == std::string::npos ? std::string::npos
                                     : value_end - value_start);
  value.erase(value.begin(),
              std::find_if(value.begin(), value.end(), [](unsigned char c) {
                return !std::isspace(c);
              }));
  value.erase(std::find_if(value.rbegin(), value.rend(),
                           [](unsigned char c) { return !std::isspace(c); })
                  .base(),
              value.end());
  if (value.empty()) {
    return std::nullopt;
  }
  return value;
}

std::vector<std::string> SplitMetricList(const std::string& value) {
  std::vector<std::string> result;
  size_t start = 0;
  while (start <= value.size()) {
    const size_t end = value.find(',', start);
    std::string item =
        value.substr(start, end == std::string::npos ? std::string::npos
                                                     : end - start);
    item.erase(item.begin(),
               std::find_if(item.begin(), item.end(), [](unsigned char c) {
                 return !std::isspace(c);
               }));
    item.erase(std::find_if(item.rbegin(), item.rend(),
                            [](unsigned char c) { return !std::isspace(c); })
                   .base(),
               item.end());
    if (!item.empty()) {
      result.push_back(item);
    }
    if (end == std::string::npos) {
      break;
    }
    start = end + 1;
  }
  return result;
}

AudioProfile ReadProfile(const flutter::EncodableValue* arguments) {
  AudioProfile profile;
  if (!arguments || !std::holds_alternative<flutter::EncodableMap>(*arguments)) {
    return profile;
  }

  const auto& map = std::get<flutter::EncodableMap>(*arguments);
  profile.mode = ReadMode(map);
  profile.codec = ReadCodec(map);
  profile.sample_rate = ReadInt(map, "sampleRate", profile.sample_rate);
  profile.channels =
      std::clamp(ReadInt(map, "channels", profile.channels), 1, 2);
  profile.bitrate_kbps = ReadInt(map, "bitrateKbps", profile.bitrate_kbps);
  profile.latency_ms = ReadInt(map, "latencyMs", profile.latency_ms);
  profile.capture_buffer_ms =
      ReadInt(map, "captureBufferMs", profile.latency_ms);
  profile.playback_buffer_ms =
      ReadInt(map, "playbackBufferMs", profile.latency_ms);
  profile.packet_time_ms = ReadInt(map, "packetTimeMs", profile.packet_time_ms);
  profile.receiver_adaptive_buffer =
      ReadBool(map, "receiverAdaptiveBuffer", profile.receiver_adaptive_buffer);
  profile.adaptive_buffer_cap_ms =
      ReadInt(map, "adaptiveBufferCapMs", profile.adaptive_buffer_cap_ms);
  return profile;
}

AudioCodec CodecFromPacketId(int codec_id) {
  switch (codec_id) {
    case kCodecOpus:
      return AudioCodec::kOpus;
    case kCodecAac:
      return AudioCodec::kAac;
    case kCodecG711MuLaw:
      return AudioCodec::kG711MuLaw;
    case kCodecG711ALaw:
      return AudioCodec::kG711ALaw;
    case kCodecImaAdpcm:
      return AudioCodec::kImaAdpcm;
    default:
      return AudioCodec::kPcm;
  }
}

std::string CodecName(AudioCodec codec) {
  switch (codec) {
    case AudioCodec::kOpus:
      return "opus";
    case AudioCodec::kAac:
      return "aac";
    case AudioCodec::kG711MuLaw:
      return "g711MuLaw";
    case AudioCodec::kG711ALaw:
      return "g711ALaw";
    case AudioCodec::kImaAdpcm:
      return "imaAdpcm";
    case AudioCodec::kPcm:
      return "pcm";
  }
  return "pcm";
}

flutter::EncodableMap ProfileToEncodableMap(const AudioProfile& profile) {
  flutter::EncodableMap map;
  map[flutter::EncodableValue("mode")] =
      flutter::EncodableValue(ModeName(profile.mode));
  map[flutter::EncodableValue("codec")] =
      flutter::EncodableValue(CodecName(profile.codec));
  map[flutter::EncodableValue("outputBackend")] =
      flutter::EncodableValue("auto");
  map[flutter::EncodableValue("sampleRate")] =
      flutter::EncodableValue(profile.sample_rate);
  map[flutter::EncodableValue("bitrateKbps")] =
      flutter::EncodableValue(profile.bitrate_kbps);
  map[flutter::EncodableValue("latencyMs")] =
      flutter::EncodableValue(profile.latency_ms);
  map[flutter::EncodableValue("captureBufferMs")] =
      flutter::EncodableValue(profile.capture_buffer_ms);
  map[flutter::EncodableValue("playbackBufferMs")] =
      flutter::EncodableValue(profile.playback_buffer_ms);
  map[flutter::EncodableValue("packetTimeMs")] =
      flutter::EncodableValue(profile.packet_time_ms);
  map[flutter::EncodableValue("channels")] =
      flutter::EncodableValue(profile.channels);
  map[flutter::EncodableValue("receiverAdaptiveBuffer")] =
      flutter::EncodableValue(profile.receiver_adaptive_buffer);
  map[flutter::EncodableValue("adaptiveBufferCapMs")] =
      flutter::EncodableValue(profile.adaptive_buffer_cap_ms);
  return map;
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

int16_t ClampToPcm16(float sample, float volume, bool muted) {
  if (muted) {
    return 0;
  }

  const float scaled = std::clamp(sample * volume, -1.0f, 1.0f);
  return static_cast<int16_t>(std::round(scaled * 32767.0f));
}

float Pcm16ToFloat(int16_t sample) {
  return sample < 0 ? static_cast<float>(sample) / 32768.0f
                    : static_cast<float>(sample) / 32767.0f;
}

double PcmPeakLevel(const std::vector<int16_t>& pcm) {
  int max_sample = 0;
  for (const int16_t sample : pcm) {
    max_sample = std::max(max_sample, std::abs(static_cast<int>(sample)));
  }
  return std::clamp(static_cast<double>(max_sample) / 32768.0, 0.0, 1.0);
}

int16_t FloatToPcm16(float sample) {
  return static_cast<int16_t>(
      std::round(std::clamp(sample, -1.0f, 1.0f) * 32767.0f));
}

float ReadRemixedSample(const std::vector<int16_t>& pcm, int frame,
                        int input_channels, int output_channels,
                        int output_channel) {
  const int channels = std::max(1, input_channels);
  const int base = frame * channels;
  if (output_channels == 1) {
    float sum = 0.0f;
    for (int channel = 0; channel < channels; ++channel) {
      sum += Pcm16ToFloat(pcm[base + channel]);
    }
    return sum / channels;
  }

  if (channels == 1) {
    return Pcm16ToFloat(pcm[base]);
  }

  return Pcm16ToFloat(pcm[base + std::min(output_channel, channels - 1)]);
}

std::vector<int16_t> ConvertToPcm16(const BYTE* data, UINT32 frame_count,
                                    const WAVEFORMATEX& format, bool silent,
                                    float volume, bool muted) {
  const int channels = std::max<int>(1, format.nChannels);
  std::vector<int16_t> pcm(frame_count * channels);
  if (silent || data == nullptr) {
    return pcm;
  }

  if (IsFloatFormat(format) && format.wBitsPerSample == 32) {
    const auto* samples = reinterpret_cast<const float*>(data);
    for (size_t index = 0; index < pcm.size(); ++index) {
      pcm[index] = ClampToPcm16(samples[index], volume, muted);
    }
    return pcm;
  }

  if (IsPcmFormat(format) && format.wBitsPerSample == 16) {
    const auto* samples = reinterpret_cast<const int16_t*>(data);
    for (size_t index = 0; index < pcm.size(); ++index) {
      const float normalized = static_cast<float>(samples[index]) / 32768.0f;
      pcm[index] = ClampToPcm16(normalized, volume, muted);
    }
    return pcm;
  }

  if (IsPcmFormat(format) && format.wBitsPerSample == 24) {
    const int bytes_per_sample = format.wBitsPerSample / 8;
    for (size_t index = 0; index < pcm.size(); ++index) {
      const BYTE* sample = data + index * bytes_per_sample;
      int32_t value = sample[0] | (sample[1] << 8) | (sample[2] << 16);
      if ((value & 0x00800000) != 0) {
        value |= 0xFF000000;
      }
      const float normalized = static_cast<float>(value) / 8388608.0f;
      pcm[index] = ClampToPcm16(normalized, volume, muted);
    }
    return pcm;
  }

  if (IsPcmFormat(format) && format.wBitsPerSample == 32) {
    const auto* samples = reinterpret_cast<const int32_t*>(data);
    for (size_t index = 0; index < pcm.size(); ++index) {
      const float normalized =
          static_cast<float>(samples[index]) / 2147483648.0f;
      pcm[index] = ClampToPcm16(normalized, volume, muted);
    }
  }

  return pcm;
}

std::vector<int16_t> ReformatPcm(const std::vector<int16_t>& input,
                                 int input_sample_rate, int input_channels,
                                 int output_sample_rate,
                                 int output_channels) {
  const int source_channels = std::max(1, input_channels);
  const int target_channels = std::max(1, output_channels);
  const int input_frames = static_cast<int>(input.size()) / source_channels;
  if (input_frames <= 0 || input_sample_rate <= 0 || output_sample_rate <= 0) {
    return {};
  }

  const int output_frames = std::max(
      1, static_cast<int>(std::llround(
             static_cast<double>(input_frames) * output_sample_rate /
             input_sample_rate)));
  std::vector<int16_t> output;
  output.reserve(output_frames * target_channels);

  for (int frame = 0; frame < output_frames; ++frame) {
    const double source_position =
        static_cast<double>(frame) * input_sample_rate / output_sample_rate;
    const int left_frame = std::clamp(
        static_cast<int>(std::floor(source_position)), 0, input_frames - 1);
    const int right_frame = std::min(left_frame + 1, input_frames - 1);
    const float fraction =
        static_cast<float>(source_position - std::floor(source_position));

    for (int channel = 0; channel < target_channels; ++channel) {
      const float left = ReadRemixedSample(input, left_frame, source_channels,
                                           target_channels, channel);
      const float right = ReadRemixedSample(input, right_frame, source_channels,
                                            target_channels, channel);
      output.push_back(FloatToPcm16(left + (right - left) * fraction));
    }
  }
  return output;
}

void WriteU16(std::vector<uint8_t>& packet, size_t offset, uint16_t value) {
  packet[offset] = static_cast<uint8_t>(value & 0xFF);
  packet[offset + 1] = static_cast<uint8_t>((value >> 8) & 0xFF);
}

void WriteU32(std::vector<uint8_t>& packet, size_t offset, uint32_t value) {
  packet[offset] = static_cast<uint8_t>(value & 0xFF);
  packet[offset + 1] = static_cast<uint8_t>((value >> 8) & 0xFF);
  packet[offset + 2] = static_cast<uint8_t>((value >> 16) & 0xFF);
  packet[offset + 3] = static_cast<uint8_t>((value >> 24) & 0xFF);
}

void WriteU64(std::vector<uint8_t>& packet, size_t offset, uint64_t value) {
  for (size_t byte = 0; byte < sizeof(uint64_t); ++byte) {
    packet[offset + byte] = static_cast<uint8_t>((value >> (byte * 8)) & 0xFF);
  }
}

void AppendU16(std::vector<uint8_t>& packet, uint16_t value) {
  packet.push_back(static_cast<uint8_t>(value & 0xFF));
  packet.push_back(static_cast<uint8_t>((value >> 8) & 0xFF));
}

uint32_t ReadU32Le(const uint8_t* data) {
  return static_cast<uint32_t>(data[0]) |
         (static_cast<uint32_t>(data[1]) << 8) |
         (static_cast<uint32_t>(data[2]) << 16) |
         (static_cast<uint32_t>(data[3]) << 24);
}

uint16_t ReadU16Le(const uint8_t* data) {
  return static_cast<uint16_t>(data[0]) |
         static_cast<uint16_t>(static_cast<uint16_t>(data[1]) << 8);
}

uint64_t ReadU64Le(const uint8_t* data) {
  uint64_t value = 0;
  for (size_t byte = 0; byte < sizeof(uint64_t); ++byte) {
    value |= static_cast<uint64_t>(data[byte]) << (byte * 8);
  }
  return value;
}

uint8_t LinearToMuLaw(int16_t sample) {
  constexpr int kBias = 0x84;
  constexpr int kClip = 32635;
  int value = sample;
  const int sign = (value >> 8) & 0x80;
  if (sign != 0) {
    value = -value;
  }
  value = std::min(value, kClip) + kBias;

  int exponent = 7;
  for (int mask = 0x4000; (value & mask) == 0 && exponent > 0;
       mask >>= 1) {
    --exponent;
  }
  const int mantissa = (value >> (exponent + 3)) & 0x0F;
  return static_cast<uint8_t>(~(sign | (exponent << 4) | mantissa));
}

uint8_t LinearToALaw(int16_t sample) {
  int value = sample;
  int mask = 0xD5;
  if (value < 0) {
    value = -value - 1;
    mask = 0x55;
  }
  value = std::min(value, 32635);

  int compressed = 0;
  if (value >= 256) {
    int exponent = 7;
    for (int exp_mask = 0x4000; (value & exp_mask) == 0 && exponent > 0;
         exp_mask >>= 1) {
      --exponent;
    }
    const int mantissa = (value >> (exponent + 3)) & 0x0F;
    compressed = (exponent << 4) | mantissa;
  } else {
    compressed = value >> 4;
  }

  return static_cast<uint8_t>(compressed ^ mask);
}

constexpr int kImaIndexTable[16] = {
    -1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8};
constexpr int kImaStepTable[89] = {
    7,     8,     9,     10,    11,    12,    13,    14,    16,
    17,    19,    21,    23,    25,    28,    31,    34,    37,
    41,    45,    50,    55,    60,    66,    73,    80,    88,
    97,    107,   118,   130,   143,   157,   173,   190,   209,
    230,   253,   279,   307,   337,   371,   408,   449,   494,
    544,   598,   658,   724,   796,   876,   963,   1060,  1166,
    1282,  1411,  1552,  1707,  1878,  2066,  2272,  2499,  2749,
    3024,  3327,  3660,  4026,  4428,  4871,  5358,  5894,  6484,
    7132,  7845,  8630,  9493,  10442, 11487, 12635, 13899, 15289,
    16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767};

struct ImaAdpcmChannelState {
  int predictor = 0;
  int step_index = 0;
};

uint8_t EncodeImaNibble(int16_t sample, ImaAdpcmChannelState& state) {
  const int step = kImaStepTable[state.step_index];
  int diff = static_cast<int>(sample) - state.predictor;
  uint8_t code = 0;
  if (diff < 0) {
    code = 8;
    diff = -diff;
  }

  int delta = step >> 3;
  if (diff >= step) {
    code |= 4;
    diff -= step;
    delta += step;
  }
  if (diff >= step >> 1) {
    code |= 2;
    diff -= step >> 1;
    delta += step >> 1;
  }
  if (diff >= step >> 2) {
    code |= 1;
    delta += step >> 2;
  }

  state.predictor += (code & 8) != 0 ? -delta : delta;
  state.predictor = std::clamp(state.predictor, -32768, 32767);
  state.step_index =
      std::clamp(state.step_index + kImaIndexTable[code & 0x0F], 0, 88);
  return code & 0x0F;
}

class PcmCodecAdapter {
 public:
  EncodedAudioPacket Encode(const std::vector<int16_t>& pcm, int channels,
                            bool muted) const {
    EncodedAudioPacket packet;
    packet.flags = muted ? kPacketFlagMuted : 0;
    packet.decoded_frame_count = channels <= 0
                                     ? 0
                                     : static_cast<uint32_t>(pcm.size() /
                                                             channels);
    packet.payload.resize(pcm.size() * sizeof(int16_t));
    if (!packet.payload.empty()) {
      std::memcpy(packet.payload.data(), pcm.data(), packet.payload.size());
    }
    return packet;
  }
};

class AacCodecAdapter {
 public:
  AacCodecAdapter() = default;

  ~AacCodecAdapter() {
    Shutdown();
  }

  bool Configure(int sample_rate, int channels, int bitrate_bps) {
    const int clamped_sample_rate = std::clamp(sample_rate, 8000, 96000);
    const int clamped_channels = std::clamp(channels, 1, 2);
    const int clamped_bitrate = std::clamp(bitrate_bps, 96000, 192000);
    if (writer_ != nullptr && sample_rate_ == clamped_sample_rate &&
        channels_ == clamped_channels && bitrate_bps_ == clamped_bitrate) {
      return true;
    }

    Shutdown();

    Microsoft::WRL::ComPtr<IMFMediaType> output_type;
    HRESULT hr = MFCreateMediaType(&output_type);
    if (FAILED(hr)) {
      return false;
    }
    output_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
    output_type->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_AAC);
    output_type->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND,
                           clamped_sample_rate);
    output_type->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, clamped_channels);
    output_type->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
    output_type->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND,
                           clamped_bitrate / 8);
    output_type->SetUINT32(MF_MT_AAC_AUDIO_PROFILE_LEVEL_INDICATION, 0x29);
    output_type->SetUINT32(MF_MT_AAC_PAYLOAD_TYPE, 0);

    Microsoft::WRL::ComPtr<IMFMediaType> input_type;
    hr = MFCreateMediaType(&input_type);
    if (FAILED(hr)) {
      return false;
    }
    input_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
    input_type->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM);
    input_type->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND,
                          clamped_sample_rate);
    input_type->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, clamped_channels);
    input_type->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
    input_type->SetUINT32(MF_MT_AUDIO_BLOCK_ALIGNMENT,
                          clamped_channels * sizeof(int16_t));
    input_type->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND,
                          clamped_sample_rate * clamped_channels *
                              static_cast<int>(sizeof(int16_t)));

    Microsoft::WRL::ComPtr<IMFByteStream> byte_stream;
    hr = MFCreateMFByteStreamOnStreamEx(
        static_cast<IStream*>(&stream_), &byte_stream);
    if (FAILED(hr)) {
      return false;
    }

    Microsoft::WRL::ComPtr<IMFMediaSink> media_sink;
    hr = MFCreateADTSMediaSink(byte_stream.Get(), output_type.Get(),
                               &media_sink);
    if (FAILED(hr)) {
      return false;
    }

    Microsoft::WRL::ComPtr<IMFSinkWriter> writer;
    hr = MFCreateSinkWriterFromMediaSink(media_sink.Get(), nullptr, &writer);
    if (FAILED(hr)) {
      media_sink->Shutdown();
      return false;
    }

    constexpr DWORD stream_index = 0;
    hr = writer->SetInputMediaType(stream_index, input_type.Get(), nullptr);
    if (FAILED(hr)) {
      media_sink->Shutdown();
      return false;
    }
    hr = writer->BeginWriting();
    if (FAILED(hr)) {
      media_sink->Shutdown();
      return false;
    }

    writer_ = writer;
    media_sink_ = media_sink;
    stream_index_ = stream_index;
    sample_rate_ = clamped_sample_rate;
    channels_ = clamped_channels;
    bitrate_bps_ = clamped_bitrate;
    written_frames_ = 0;
    stream_.Drain();
    return true;
  }

  EncodedAudioPacket Encode(const std::vector<int16_t>& pcm, int channels,
                            bool muted) {
    EncodedAudioPacket packet;
    packet.codec_id = kCodecAac;
    packet.flags = muted ? kPacketFlagMuted : 0;
    packet.decoded_frame_count = 0;
    if (writer_ == nullptr || pcm.empty()) {
      return packet;
    }

    const size_t bytes = pcm.size() * sizeof(int16_t);
    Microsoft::WRL::ComPtr<IMFMediaBuffer> buffer;
    HRESULT hr = MFCreateMemoryBuffer(static_cast<DWORD>(bytes), &buffer);
    if (FAILED(hr)) {
      return packet;
    }

    BYTE* output = nullptr;
    hr = buffer->Lock(&output, nullptr, nullptr);
    if (FAILED(hr)) {
      return packet;
    }
    if (muted) {
      std::memset(output, 0, bytes);
    } else {
      std::memcpy(output, pcm.data(), bytes);
    }
    buffer->Unlock();
    buffer->SetCurrentLength(static_cast<DWORD>(bytes));

    Microsoft::WRL::ComPtr<IMFSample> sample;
    hr = MFCreateSample(&sample);
    if (FAILED(hr)) {
      return packet;
    }
    sample->AddBuffer(buffer.Get());

    const int frame_count =
        channels_ <= 0 ? 0 : static_cast<int>(pcm.size()) / channels_;
    sample->SetSampleTime(written_frames_ * 10000000LL / sample_rate_);
    sample->SetSampleDuration(frame_count * 10000000LL / sample_rate_);
    written_frames_ += frame_count;

    hr = writer_->WriteSample(stream_index_, sample.Get());
    if (FAILED(hr)) {
      Shutdown();
      return packet;
    }

    packet.payload = stream_.Drain();
    return packet;
  }

  void Shutdown() {
    if (writer_ != nullptr) {
      writer_->Finalize();
    }
    writer_.Reset();
    if (media_sink_ != nullptr) {
      media_sink_->Shutdown();
    }
    media_sink_.Reset();
    stream_index_ = 0;
    written_frames_ = 0;
    stream_.Drain();
  }

 private:
  class MemoryStream final : public IStream {
   public:
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid,
                                             void** object) override {
      if (object == nullptr) {
        return E_POINTER;
      }
      if (riid == IID_IUnknown || riid == IID_IStream ||
          riid == IID_ISequentialStream) {
        *object = static_cast<IStream*>(this);
        AddRef();
        return S_OK;
      }
      *object = nullptr;
      return E_NOINTERFACE;
    }

    ULONG STDMETHODCALLTYPE AddRef() override {
      return ++reference_count_;
    }

    ULONG STDMETHODCALLTYPE Release() override {
      const ULONG count = --reference_count_;
      return count;
    }

    HRESULT STDMETHODCALLTYPE Read(void* data, ULONG bytes,
                                   ULONG* bytes_read) override {
      if (bytes_read != nullptr) {
        *bytes_read = 0;
      }
      if (data == nullptr) {
        return STG_E_INVALIDPOINTER;
      }
      std::scoped_lock lock(mutex_);
      const size_t available = position_ < storage_.size()
                                   ? storage_.size() - position_
                                   : 0;
      const size_t count = std::min<size_t>(bytes, available);
      if (count > 0) {
        std::memcpy(data, storage_.data() + position_, count);
        position_ += count;
      }
      if (bytes_read != nullptr) {
        *bytes_read = static_cast<ULONG>(count);
      }
      return count == bytes ? S_OK : S_FALSE;
    }

    HRESULT STDMETHODCALLTYPE Write(const void* data, ULONG bytes,
                                    ULONG* bytes_written) override {
      if (bytes_written != nullptr) {
        *bytes_written = 0;
      }
      if (data == nullptr) {
        return STG_E_INVALIDPOINTER;
      }
      std::scoped_lock lock(mutex_);
      if (position_ + bytes > storage_.size()) {
        storage_.resize(position_ + bytes);
      }
      std::memcpy(storage_.data() + position_, data, bytes);
      position_ += bytes;
      if (bytes_written != nullptr) {
        *bytes_written = bytes;
      }
      return S_OK;
    }

    HRESULT STDMETHODCALLTYPE Seek(LARGE_INTEGER move, DWORD origin,
                                   ULARGE_INTEGER* new_position) override {
      std::scoped_lock lock(mutex_);
      int64_t base = 0;
      if (origin == STREAM_SEEK_CUR) {
        base = static_cast<int64_t>(position_);
      } else if (origin == STREAM_SEEK_END) {
        base = static_cast<int64_t>(storage_.size());
      } else if (origin != STREAM_SEEK_SET) {
        return STG_E_INVALIDFUNCTION;
      }

      const int64_t next = base + move.QuadPart;
      if (next < 0) {
        return STG_E_INVALIDFUNCTION;
      }
      position_ = static_cast<size_t>(next);
      if (new_position != nullptr) {
        new_position->QuadPart = position_;
      }
      return S_OK;
    }

    HRESULT STDMETHODCALLTYPE SetSize(ULARGE_INTEGER size) override {
      std::scoped_lock lock(mutex_);
      storage_.resize(static_cast<size_t>(size.QuadPart));
      if (position_ > storage_.size()) {
        position_ = storage_.size();
      }
      return S_OK;
    }

    HRESULT STDMETHODCALLTYPE CopyTo(IStream* target, ULARGE_INTEGER bytes,
                                     ULARGE_INTEGER* bytes_read,
                                     ULARGE_INTEGER* bytes_written) override {
      if (bytes_read != nullptr) {
        bytes_read->QuadPart = 0;
      }
      if (bytes_written != nullptr) {
        bytes_written->QuadPart = 0;
      }
      if (target == nullptr) {
        return STG_E_INVALIDPOINTER;
      }

      std::vector<uint8_t> copy;
      {
        std::scoped_lock lock(mutex_);
        const size_t available = position_ < storage_.size()
                                     ? storage_.size() - position_
                                     : 0;
        const size_t count =
            static_cast<size_t>(std::min<uint64_t>(bytes.QuadPart, available));
        copy.assign(storage_.begin() + position_,
                    storage_.begin() + position_ + count);
        position_ += count;
      }

      ULONG written = 0;
      const HRESULT hr =
          target->Write(copy.data(), static_cast<ULONG>(copy.size()), &written);
      if (bytes_read != nullptr) {
        bytes_read->QuadPart = copy.size();
      }
      if (bytes_written != nullptr) {
        bytes_written->QuadPart = written;
      }
      return hr;
    }

    HRESULT STDMETHODCALLTYPE Commit(DWORD) override { return S_OK; }
    HRESULT STDMETHODCALLTYPE Revert() override { return STG_E_REVERTED; }
    HRESULT STDMETHODCALLTYPE LockRegion(ULARGE_INTEGER, ULARGE_INTEGER,
                                         DWORD) override {
      return STG_E_INVALIDFUNCTION;
    }
    HRESULT STDMETHODCALLTYPE UnlockRegion(ULARGE_INTEGER, ULARGE_INTEGER,
                                           DWORD) override {
      return STG_E_INVALIDFUNCTION;
    }

    HRESULT STDMETHODCALLTYPE Stat(STATSTG* stat, DWORD) override {
      if (stat == nullptr) {
        return STG_E_INVALIDPOINTER;
      }
      std::memset(stat, 0, sizeof(STATSTG));
      std::scoped_lock lock(mutex_);
      stat->type = STGTY_STREAM;
      stat->cbSize.QuadPart = storage_.size();
      return S_OK;
    }

    HRESULT STDMETHODCALLTYPE Clone(IStream** copy) override {
      if (copy == nullptr) {
        return E_POINTER;
      }
      *copy = nullptr;
      return E_NOTIMPL;
    }

    std::vector<uint8_t> Drain() {
      std::scoped_lock lock(mutex_);
      std::vector<uint8_t> drained;
      if (read_offset_ < storage_.size()) {
        drained.assign(storage_.begin() + read_offset_, storage_.end());
        read_offset_ = storage_.size();
      }
      return drained;
    }

   private:
    std::atomic<ULONG> reference_count_ = 1;
    std::mutex mutex_;
    std::vector<uint8_t> storage_;
    size_t position_ = 0;
    size_t read_offset_ = 0;
  };

  MemoryStream stream_;
  Microsoft::WRL::ComPtr<IMFSinkWriter> writer_;
  Microsoft::WRL::ComPtr<IMFMediaSink> media_sink_;
  DWORD stream_index_ = 0;
  int sample_rate_ = 0;
  int channels_ = 0;
  int bitrate_bps_ = 0;
  int64_t written_frames_ = 0;
};

class OpusCodecAdapter {
 public:
  OpusCodecAdapter() = default;

  ~OpusCodecAdapter() {
    Shutdown();
  }

  bool Configure(int channels, int bitrate_bps, bool low_delay) {
    const int clamped_channels = std::clamp(channels, 1, 2);
    const int clamped_bitrate = std::clamp(bitrate_bps, 64000, 256000);
    if (encoder_ != nullptr && channels_ == clamped_channels &&
        bitrate_bps_ == clamped_bitrate && low_delay_ == low_delay) {
      return true;
    }

    Shutdown();

    int error = OPUS_OK;
    encoder_ = opus_encoder_create(kOpusSampleRate, clamped_channels,
                                   low_delay
                                       ? OPUS_APPLICATION_RESTRICTED_LOWDELAY
                                       : OPUS_APPLICATION_AUDIO,
                                   &error);
    if (error != OPUS_OK || encoder_ == nullptr) {
      encoder_ = nullptr;
      return false;
    }

    opus_encoder_ctl(encoder_, OPUS_SET_BITRATE(clamped_bitrate));
    opus_encoder_ctl(encoder_, OPUS_SET_VBR(0));
    opus_encoder_ctl(encoder_, OPUS_SET_COMPLEXITY(low_delay ? 4 : 5));
    opus_encoder_ctl(encoder_, OPUS_SET_SIGNAL(OPUS_SIGNAL_MUSIC));
    opus_encoder_ctl(encoder_, OPUS_SET_INBAND_FEC(0));
    opus_encoder_ctl(encoder_, OPUS_SET_DTX(0));
    channels_ = clamped_channels;
    bitrate_bps_ = clamped_bitrate;
    low_delay_ = low_delay;
    return true;
  }

  EncodedAudioPacket Encode(const std::vector<int16_t>& pcm, int channels,
                            int frame_samples, bool muted) {
    EncodedAudioPacket packet;
    packet.codec_id = kCodecOpus;
    packet.flags = muted ? kPacketFlagMuted : 0;
    packet.decoded_frame_count = channels <= 0
                                     ? 0
                                     : static_cast<uint32_t>(pcm.size() /
                                                             channels);
    const int expected_samples = IsSupportedOpusFrameSamples(frame_samples)
                                     ? frame_samples
                                     : kOpusShortFrameSamples;
    if (encoder_ == nullptr || pcm.empty() ||
        packet.decoded_frame_count != static_cast<uint32_t>(expected_samples)) {
      return packet;
    }

    std::vector<int16_t> input(pcm);
    if (muted) {
      std::fill(input.begin(), input.end(), int16_t{0});
    }

    packet.payload.resize(kOpusMaxPacketBytes);
    const int encoded_bytes = opus_encode(
        encoder_, input.data(), expected_samples, packet.payload.data(),
        static_cast<opus_int32>(packet.payload.size()));
    if (encoded_bytes <= 0) {
      packet.payload.clear();
      return packet;
    }
    packet.payload.resize(static_cast<size_t>(encoded_bytes));
    return packet;
  }

  void Shutdown() {
    if (encoder_ != nullptr) {
      opus_encoder_destroy(encoder_);
      encoder_ = nullptr;
    }
    channels_ = 0;
    bitrate_bps_ = 0;
    low_delay_ = false;
  }

 private:
  OpusEncoder* encoder_ = nullptr;
  int channels_ = 0;
  int bitrate_bps_ = 0;
  bool low_delay_ = false;
};

class G711CodecAdapter {
 public:
  explicit G711CodecAdapter(bool mu_law) : mu_law_(mu_law) {}

  EncodedAudioPacket Encode(const std::vector<int16_t>& pcm, int channels,
                            bool muted) const {
    EncodedAudioPacket packet;
    packet.codec_id = mu_law_ ? kCodecG711MuLaw : kCodecG711ALaw;
    packet.flags = muted ? kPacketFlagMuted : 0;
    packet.decoded_frame_count = channels <= 0
                                     ? 0
                                     : static_cast<uint32_t>(pcm.size() /
                                                             channels);
    packet.payload.resize(pcm.size());
    for (size_t index = 0; index < pcm.size(); ++index) {
      const int16_t sample = muted ? 0 : pcm[index];
      packet.payload[index] =
          mu_law_ ? LinearToMuLaw(sample) : LinearToALaw(sample);
    }
    return packet;
  }

 private:
  bool mu_law_;
};

class ImaAdpcmCodecAdapter {
 public:
  EncodedAudioPacket Encode(const std::vector<int16_t>& pcm, int channels,
                            bool muted) {
    EncodedAudioPacket packet;
    packet.codec_id = kCodecImaAdpcm;
    packet.flags = muted ? kPacketFlagMuted : 0;
    packet.decoded_frame_count = channels <= 0
                                     ? 0
                                     : static_cast<uint32_t>(pcm.size() /
                                                             channels);
    if (pcm.empty()) {
      return packet;
    }

    const int channel_count = std::max(1, channels);
    std::vector<ImaAdpcmChannelState> states(channel_count);
    for (int channel = 0; channel < channel_count; ++channel) {
      const size_t sample_index = static_cast<size_t>(channel);
      states[channel].predictor =
          sample_index < pcm.size() && !muted ? pcm[sample_index] : 0;
      states[channel].step_index = 0;
    }

    uint8_t pending_nibble = 0;
    bool has_pending_nibble = false;
    packet.payload.reserve(channel_count * 4 + (pcm.size() + 1) / 2);
    for (const auto& state : states) {
      packet.payload.push_back(static_cast<uint8_t>(state.predictor & 0xFF));
      packet.payload.push_back(
          static_cast<uint8_t>((state.predictor >> 8) & 0xFF));
      packet.payload.push_back(static_cast<uint8_t>(state.step_index));
      packet.payload.push_back(0);
    }
    for (size_t index = 0; index < pcm.size(); ++index) {
      const int channel = static_cast<int>(index % channel_count);
      const uint8_t nibble =
          EncodeImaNibble(muted ? 0 : pcm[index], states[channel]);
      if (!has_pending_nibble) {
        pending_nibble = nibble;
        has_pending_nibble = true;
      } else {
        packet.payload.push_back(
            static_cast<uint8_t>(pending_nibble | (nibble << 4)));
        has_pending_nibble = false;
      }
    }
    if (has_pending_nibble) {
      packet.payload.push_back(pending_nibble);
    }

    return packet;
  }
};

void ConfigureLowDelaySocket(SOCKET socket) {
  int send_buffer_bytes = kAudioSocketBufferBytes;
  setsockopt(socket, SOL_SOCKET, SO_SNDBUF,
             reinterpret_cast<const char*>(&send_buffer_bytes),
             sizeof(send_buffer_bytes));

  int receive_buffer_bytes = kAudioSocketBufferBytes;
  setsockopt(socket, SOL_SOCKET, SO_RCVBUF,
             reinterpret_cast<const char*>(&receive_buffer_bytes),
             sizeof(receive_buffer_bytes));

  int traffic_class = kLowDelayTrafficClass;
  setsockopt(socket, IPPROTO_IP, IP_TOS,
             reinterpret_cast<const char*>(&traffic_class),
             sizeof(traffic_class));
}

}  // namespace

class WindowsAudioEngine::Impl {
 public:
  Impl() = default;

  ~Impl() {
    Disconnect();
  }

  flutter::EncodableMap GetCapabilities() const {
    flutter::EncodableMap capabilities;
    capabilities[flutter::EncodableValue("platform")] =
        flutter::EncodableValue("windows");
    capabilities[flutter::EncodableValue("canSend")] =
        flutter::EncodableValue(true);
    capabilities[flutter::EncodableValue("canReceive")] =
        flutter::EncodableValue(true);
    capabilities[flutter::EncodableValue("canPlaySoundEffects")] =
        flutter::EncodableValue(true);
    capabilities[flutter::EncodableValue("soundboardOutputDevices")] =
        flutter::EncodableValue(GetSoundboardOutputDevices());
    capabilities[flutter::EncodableValue("backend")] =
        flutter::EncodableValue("windows-wasapi-codecs-udp-native-usb");
    capabilities[flutter::EncodableValue("detail")] =
        flutter::EncodableValue(
            "Low-delay WASAPI loopback capture over UDP and Android Open Accessory USB");
    capabilities[flutter::EncodableValue("supportedCodecs")] =
        flutter::EncodableValue(flutter::EncodableList{
            flutter::EncodableValue("pcm"),
            flutter::EncodableValue("opus"),
            flutter::EncodableValue("aac"),
            flutter::EncodableValue("g711MuLaw"),
            flutter::EncodableValue("g711ALaw"),
            flutter::EncodableValue("imaAdpcm"),
        });
    capabilities[flutter::EncodableValue("supportedOutputBackends")] =
        flutter::EncodableValue(flutter::EncodableList{
            flutter::EncodableValue("auto"),
            flutter::EncodableValue("wasapiShared"),
        });
    capabilities[flutter::EncodableValue("codecBitrateRanges")] =
        flutter::EncodableValue(flutter::EncodableMap{
            {flutter::EncodableValue("pcm"),
             flutter::EncodableValue(flutter::EncodableMap{
                 {flutter::EncodableValue("minKbps"),
                  flutter::EncodableValue(0)},
                 {flutter::EncodableValue("maxKbps"),
                  flutter::EncodableValue(0)},
             })},
            {flutter::EncodableValue("opus"),
             flutter::EncodableValue(flutter::EncodableMap{
                 {flutter::EncodableValue("minKbps"),
                  flutter::EncodableValue(64)},
                 {flutter::EncodableValue("maxKbps"),
                  flutter::EncodableValue(256)},
             })},
            {flutter::EncodableValue("aac"),
             flutter::EncodableValue(flutter::EncodableMap{
                 {flutter::EncodableValue("minKbps"),
                  flutter::EncodableValue(96)},
                 {flutter::EncodableValue("maxKbps"),
                  flutter::EncodableValue(192)},
             })},
            {flutter::EncodableValue("g711MuLaw"),
             flutter::EncodableValue(flutter::EncodableMap{
                 {flutter::EncodableValue("minKbps"),
                  flutter::EncodableValue(64)},
                 {flutter::EncodableValue("maxKbps"),
                  flutter::EncodableValue(1536)},
             })},
            {flutter::EncodableValue("g711ALaw"),
             flutter::EncodableValue(flutter::EncodableMap{
                 {flutter::EncodableValue("minKbps"),
                  flutter::EncodableValue(64)},
                 {flutter::EncodableValue("maxKbps"),
                  flutter::EncodableValue(1536)},
             })},
            {flutter::EncodableValue("imaAdpcm"),
             flutter::EncodableValue(flutter::EncodableMap{
                 {flutter::EncodableValue("minKbps"),
                  flutter::EncodableValue(32)},
                 {flutter::EncodableValue("maxKbps"),
                  flutter::EncodableValue(768)},
             })},
        });
    return capabilities;
  }

  flutter::EncodableList GetSoundboardOutputDevices() const {
    HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    const bool owns_com = SUCCEEDED(hr);
    if (FAILED(hr) && hr != RPC_E_CHANGED_MODE) {
      return {};
    }

    flutter::EncodableList devices;
    Microsoft::WRL::ComPtr<IMMDeviceEnumerator> enumerator;
    hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                          IID_PPV_ARGS(&enumerator));
    if (FAILED(hr)) {
      FinishCom(owns_com);
      return devices;
    }

    std::wstring default_id;
    Microsoft::WRL::ComPtr<IMMDevice> default_device;
    if (SUCCEEDED(enumerator->GetDefaultAudioEndpoint(
            eRender, eCommunications, &default_device))) {
      default_id = DeviceId(default_device.Get());
    }

    Microsoft::WRL::ComPtr<IMMDeviceCollection> collection;
    hr = enumerator->EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE,
                                        &collection);
    if (FAILED(hr)) {
      FinishCom(owns_com);
      return devices;
    }

    UINT count = 0;
    collection->GetCount(&count);
    for (UINT index = 0; index < count; ++index) {
      Microsoft::WRL::ComPtr<IMMDevice> device;
      if (FAILED(collection->Item(index, &device))) {
        continue;
      }

      const std::wstring id = DeviceId(device.Get());
      if (id.empty()) {
        continue;
      }
      const std::wstring name = DeviceFriendlyName(device.Get());
      if (IsUnsupportedVirtualCableRenderEndpoint(name, id)) {
        continue;
      }
      const bool is_virtual_cable =
          IsLikelyVirtualCableEndpoint(name) || IsLikelyVirtualCableEndpoint(id);
      flutter::EncodableMap item;
      item[flutter::EncodableValue("id")] = flutter::EncodableValue(Narrow(id));
      item[flutter::EncodableValue("name")] =
          flutter::EncodableValue(Narrow(name.empty() ? id : name));
      item[flutter::EncodableValue("isDefault")] =
          flutter::EncodableValue(id == default_id);
      item[flutter::EncodableValue("isVirtualCable")] =
          flutter::EncodableValue(is_virtual_cable);
      devices.emplace_back(flutter::EncodableValue(item));
    }

    FinishCom(owns_com);
    return devices;
  }

  flutter::EncodableList GetNetworkInterfaces() const {
    ULONG buffer_size = 16 * 1024;
    std::vector<unsigned char> buffer(buffer_size);
    IP_ADAPTER_ADDRESSES* adapters =
        reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buffer.data());
    ULONG result = GetAdaptersAddresses(
        AF_INET,
        GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST |
            GAA_FLAG_SKIP_DNS_SERVER,
        nullptr, adapters, &buffer_size);

    if (result == ERROR_BUFFER_OVERFLOW) {
      buffer.resize(buffer_size);
      adapters = reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buffer.data());
      result = GetAdaptersAddresses(
          AF_INET,
          GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST |
              GAA_FLAG_SKIP_DNS_SERVER,
          nullptr, adapters, &buffer_size);
    }

    flutter::EncodableList interfaces;
    if (result != NO_ERROR) {
      return interfaces;
    }

    for (IP_ADAPTER_ADDRESSES* adapter = adapters; adapter != nullptr;
         adapter = adapter->Next) {
      if (adapter->OperStatus != IfOperStatusUp) {
        continue;
      }

      flutter::EncodableList addresses;
      flutter::EncodableList address_metadata;
      for (IP_ADAPTER_UNICAST_ADDRESS* unicast =
               adapter->FirstUnicastAddress;
           unicast != nullptr; unicast = unicast->Next) {
        const sockaddr* socket_address = unicast->Address.lpSockaddr;
        if (!socket_address || socket_address->sa_family != AF_INET) {
          continue;
        }

        char address_text[INET_ADDRSTRLEN] = {};
        const auto* ipv4 =
            reinterpret_cast<const sockaddr_in*>(socket_address);
        if (inet_ntop(AF_INET, &ipv4->sin_addr, address_text,
                      sizeof(address_text)) != nullptr) {
          const std::string address(address_text);
          addresses.emplace_back(address);

          const int prefix_length =
              std::clamp(static_cast<int>(unicast->OnLinkPrefixLength), 0, 32);
          const uint32_t host_address = ntohl(ipv4->sin_addr.S_un.S_addr);
          const uint32_t mask =
              prefix_length == 0
                  ? 0
                  : (0xFFFFFFFFu << (32 - prefix_length)) & 0xFFFFFFFFu;
          const uint32_t broadcast = host_address | (~mask & 0xFFFFFFFFu);
          in_addr broadcast_address = {};
          broadcast_address.S_un.S_addr = htonl(broadcast);
          char broadcast_text[INET_ADDRSTRLEN] = {};

          flutter::EncodableMap metadata;
          metadata[flutter::EncodableValue("address")] =
              flutter::EncodableValue(address);
          metadata[flutter::EncodableValue("prefixLength")] =
              flutter::EncodableValue(prefix_length);
          if (inet_ntop(AF_INET, &broadcast_address, broadcast_text,
                        sizeof(broadcast_text)) != nullptr) {
            metadata[flutter::EncodableValue("broadcastAddress")] =
                flutter::EncodableValue(std::string(broadcast_text));
          }
          address_metadata.emplace_back(metadata);
        }
      }

      if (addresses.empty()) {
        continue;
      }

      flutter::EncodableMap item;
      item[flutter::EncodableValue("name")] =
          flutter::EncodableValue(WideToUtf8(adapter->FriendlyName));
      item[flutter::EncodableValue("description")] =
          flutter::EncodableValue(WideToUtf8(adapter->Description));
      item[flutter::EncodableValue("index")] =
          flutter::EncodableValue(static_cast<int>(adapter->IfIndex));
      item[flutter::EncodableValue("addresses")] =
          flutter::EncodableValue(addresses);
      item[flutter::EncodableValue("addressMetadata")] =
          flutter::EncodableValue(address_metadata);
      interfaces.emplace_back(item);
    }

    return interfaces;
  }

  flutter::EncodableMap GetMetrics() const {
    flutter::EncodableMap metrics;
    if (playback_running_.load()) {
      const int64_t last_packet_at =
          local_last_peer_packet_received_at_ms_.load();
      metrics[flutter::EncodableValue("peerConnected")] =
          flutter::EncodableValue(last_packet_at > 0 &&
                                  NowMillis() - last_packet_at <=
                                      kPeerHeartbeatTimeoutMs);

      const double output_latency_ms = LocalOutputLatencyMs();
      if (output_latency_ms < 0) {
        return metrics;
      }

      metrics[flutter::EncodableValue("outputLatencyMs")] =
          flutter::EncodableValue(output_latency_ms);
      metrics[flutter::EncodableValue("queuedFrames")] =
          flutter::EncodableValue(playback_queue_frames_.load());
      metrics[flutter::EncodableValue("bufferSizeFrames")] =
          flutter::EncodableValue(local_buffer_size_frames_.load());
      metrics[flutter::EncodableValue("targetBufferFrames")] =
          flutter::EncodableValue(local_target_buffer_frames_.load());
      metrics[flutter::EncodableValue("adaptivePlaybackBufferMs")] =
          flutter::EncodableValue(local_adaptive_playback_buffer_ms_.load());
      metrics[flutter::EncodableValue("adaptiveMaxPlaybackBufferMs")] =
          flutter::EncodableValue(
              local_adaptive_max_playback_buffer_ms_.load());
      metrics[flutter::EncodableValue("adaptiveLimitReached")] =
          flutter::EncodableValue(local_adaptive_limit_reached_.load() > 0);
      metrics[flutter::EncodableValue("adaptiveUnderrunsInWindow")] =
          flutter::EncodableValue(
              local_adaptive_underruns_in_window_.load());
      metrics[flutter::EncodableValue("adaptiveUnderrunsInBurst")] =
          flutter::EncodableValue(local_adaptive_underruns_in_burst_.load());
      metrics[flutter::EncodableValue("adaptiveLowQueueSamples")] =
          flutter::EncodableValue(local_adaptive_low_queue_samples_.load());
      const int64_t local_target_frames = local_target_buffer_frames_.load();
      const int64_t local_queue_fill_percent =
          local_target_frames > 0
              ? std::clamp<int64_t>(
                    playback_queue_frames_.load() * 100 / local_target_frames,
                    0, 200)
              : 0;
      metrics[flutter::EncodableValue("playbackQueueFillPercent")] =
          flutter::EncodableValue(local_queue_fill_percent);
      metrics[flutter::EncodableValue("underrunCount")] =
          flutter::EncodableValue(local_underrun_count_.load());
      metrics[flutter::EncodableValue("droppedPacketCount")] =
          flutter::EncodableValue(local_dropped_packet_count_.load());
      metrics[flutter::EncodableValue("lostPacketCount")] =
          flutter::EncodableValue(local_lost_packet_count_.load());
      metrics[flutter::EncodableValue("trimCount")] = flutter::EncodableValue(0);
      metrics[flutter::EncodableValue("signalLevel")] =
          flutter::EncodableValue(TakeSignalLevel());

      AudioProfile active_profile = profile_;
      const int input_sample_rate = local_input_sample_rate_.load();
      if (input_sample_rate > 0) {
        active_profile.sample_rate = input_sample_rate;
      }
      const int input_channels = local_input_channels_.load();
      if (input_channels > 0) {
        active_profile.channels = input_channels;
      }
      active_profile.codec = CodecFromPacketId(local_codec_id_.load());
      metrics[flutter::EncodableValue("activeProfile")] =
          flutter::EncodableValue(ProfileToEncodableMap(active_profile));
      return metrics;
    }

    const bool capture_running = capture_running_.load();
    if (capture_running) {
      metrics[flutter::EncodableValue("signalLevel")] =
          flutter::EncodableValue(TakeSignalLevel());
    }

    const int64_t received_at = remote_metrics_received_at_ms_.load();
    const double output_latency_ms = remote_output_latency_ms_.load();
    const double audio_latency_ms = remote_audio_latency_ms_.load();
    const bool peer_connected =
        received_at > 0 && NowMillis() - received_at <= 3000;
    metrics[flutter::EncodableValue("peerConnected")] =
        flutter::EncodableValue(peer_connected);
    if (!peer_connected) {
      return metrics;
    }

    if (audio_latency_ms >= 0) {
      metrics[flutter::EncodableValue("audioLatencyMs")] =
          flutter::EncodableValue(audio_latency_ms);
    }
    if (output_latency_ms >= 0) {
      metrics[flutter::EncodableValue("outputLatencyMs")] =
          flutter::EncodableValue(output_latency_ms);
    }
    const double network_latency_ms = remote_network_latency_ms_.load();
    if (network_latency_ms >= 0) {
      metrics[flutter::EncodableValue("networkLatencyMs")] =
          flutter::EncodableValue(network_latency_ms);
    }
    metrics[flutter::EncodableValue("queuedFrames")] =
        flutter::EncodableValue(remote_queued_frames_.load());
    metrics[flutter::EncodableValue("bufferSizeFrames")] =
        flutter::EncodableValue(remote_buffer_size_frames_.load());
    metrics[flutter::EncodableValue("targetBufferFrames")] =
        flutter::EncodableValue(remote_target_buffer_frames_.load());
    metrics[flutter::EncodableValue("adaptivePlaybackBufferMs")] =
        flutter::EncodableValue(remote_adaptive_playback_buffer_ms_.load());
    metrics[flutter::EncodableValue("adaptiveMaxPlaybackBufferMs")] =
        flutter::EncodableValue(remote_adaptive_max_playback_buffer_ms_.load());
    metrics[flutter::EncodableValue("adaptiveLimitReached")] =
        flutter::EncodableValue(remote_adaptive_limit_reached_.load() > 0);
    metrics[flutter::EncodableValue("adaptiveUnderrunsInWindow")] =
        flutter::EncodableValue(remote_adaptive_underruns_in_window_.load());
    metrics[flutter::EncodableValue("adaptiveUnderrunsInBurst")] =
        flutter::EncodableValue(remote_adaptive_underruns_in_burst_.load());
    metrics[flutter::EncodableValue("adaptiveLowQueueSamples")] =
        flutter::EncodableValue(remote_adaptive_low_queue_samples_.load());
    metrics[flutter::EncodableValue("playbackQueueFillPercent")] =
        flutter::EncodableValue(remote_playback_queue_fill_percent_.load());
    metrics[flutter::EncodableValue("underrunCount")] =
        flutter::EncodableValue(remote_underrun_count_.load());
    metrics[flutter::EncodableValue("droppedPacketCount")] =
        flutter::EncodableValue(remote_dropped_packet_count_.load());
    metrics[flutter::EncodableValue("lostPacketCount")] =
        flutter::EncodableValue(remote_lost_packet_count_.load());
    metrics[flutter::EncodableValue("trimCount")] =
        flutter::EncodableValue(remote_trim_count_.load());
    if (!capture_running) {
      metrics[flutter::EncodableValue("signalLevel")] =
          flutter::EncodableValue(remote_signal_level_.load());
    }
    {
      std::scoped_lock lock(remote_capabilities_mutex_);
      if (!remote_platform_.empty()) {
        metrics[flutter::EncodableValue("remotePlatform")] =
            flutter::EncodableValue(remote_platform_);
      }
      if (!remote_supported_codecs_.empty()) {
        flutter::EncodableList codec_list;
        for (const auto& codec : remote_supported_codecs_) {
          codec_list.emplace_back(flutter::EncodableValue(codec));
        }
        metrics[flutter::EncodableValue("remoteSupportedCodecs")] =
            flutter::EncodableValue(codec_list);
      }
    }
    return metrics;
  }

  double TakeSignalLevel() const {
    return std::clamp(local_signal_peak_.exchange(0.0), 0.0, 1.0);
  }

  void PublishSignalLevel(double level) {
    level = std::clamp(level, 0.0, 1.0);
    double previous = local_signal_peak_.load();
    while (level > previous &&
           !local_signal_peak_.compare_exchange_weak(previous, level)) {
    }
  }

  std::optional<std::string> PrepareSender(
      const flutter::EncodableValue* arguments) {
    profile_ = ReadProfile(arguments);
    transport_mode_ = TransportMode::kWifi;
    usb_receiver_mode_ = false;
    in_addr bind_address = {};
    bind_address.s_addr = htonl(INADDR_ANY);
    const std::string bind_address_text =
        ReadArgumentString(arguments, "networkBindAddress");
    if (!bind_address_text.empty() &&
        inet_pton(AF_INET, bind_address_text.c_str(), &bind_address) != 1) {
      return "Unable to parse local UDP bind address.";
    }

    const auto media_foundation_error = EnsureMediaFoundationStarted();
    if (media_foundation_error.has_value()) {
      return media_foundation_error;
    }

    if (socket_ != INVALID_SOCKET) {
      if (socket_bind_address_ == bind_address.s_addr) {
        return std::nullopt;
      }
      CloseNetworkSocket();
    }

    const auto startup_error = EnsureWinsockStarted();
    if (startup_error.has_value()) {
      return startup_error;
    }

    socket_ = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (socket_ == INVALID_SOCKET) {
      Disconnect();
      return "Unable to open UDP audio socket.";
    }
    ConfigureLowDelaySocket(socket_);

    sockaddr_in local = {};
    local.sin_family = AF_INET;
    local.sin_addr = bind_address;
    local.sin_port = htons(kAudioPort);

    if (bind(socket_, reinterpret_cast<sockaddr*>(&local), sizeof(local)) ==
        SOCKET_ERROR) {
      Disconnect();
      return "Unable to bind UDP audio socket on port 47885.";
    }

    DWORD timeout_ms = 60;
    setsockopt(socket_, SOL_SOCKET, SO_RCVTIMEO,
               reinterpret_cast<const char*>(&timeout_ms), sizeof(timeout_ms));

    control_running_ = true;
    control_thread_ = std::thread(&Impl::ControlLoop, this);
    socket_bind_address_ = bind_address.s_addr;
    return std::nullopt;
  }

  std::optional<std::string> PrepareUsbSender(
      const flutter::EncodableValue* arguments) {
    UsbDebugLog("PrepareUsbSender");
    profile_ = ReadProfile(arguments);
    transport_mode_ = TransportMode::kUsb;
    usb_receiver_mode_ = false;

    const auto media_foundation_error = EnsureMediaFoundationStarted();
    if (media_foundation_error.has_value()) {
      return media_foundation_error;
    }

    if (usb_device_handle_ != INVALID_HANDLE_VALUE && usb_winusb_ != nullptr) {
      UsbDebugLog("PrepareUsbSender reused existing USB transport");
      return std::nullopt;
    }

    const auto usb_error = OpenAccessoryTransport();
    if (usb_error.has_value()) {
      UsbDebugLog("PrepareUsbSender failed: " + usb_error.value());
      return usb_error;
    }

    UsbDebugLog("PrepareUsbSender opened USB transport");
    usb_control_running_ = true;
    usb_control_thread_ = std::thread(&Impl::UsbControlLoop, this);
    return std::nullopt;
  }

  std::optional<std::string> PrepareReceiver(
      const flutter::EncodableValue* arguments) {
    profile_ = ReadProfile(arguments);
    transport_mode_ = TransportMode::kWifi;
    usb_receiver_mode_ = false;
    if (profile_.codec != AudioCodec::kPcm) {
      return "Windows receiver playback currently supports PCM only. Select PCM on the sender.";
    }

    const auto startup_error = EnsureWinsockStarted();
    if (startup_error.has_value()) {
      return startup_error;
    }

    if (socket_ == INVALID_SOCKET) {
      socket_ = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
      if (socket_ == INVALID_SOCKET) {
        Disconnect();
        return "Unable to open UDP audio receiver socket.";
      }
      ConfigureLowDelaySocket(socket_);

      sockaddr_in local = {};
      local.sin_family = AF_INET;
      local.sin_addr.s_addr = htonl(INADDR_ANY);
      local.sin_port = htons(0);
      if (bind(socket_, reinterpret_cast<sockaddr*>(&local), sizeof(local)) ==
          SOCKET_ERROR) {
        Disconnect();
        return "Unable to bind UDP audio receiver socket.";
      }

      DWORD timeout_ms = 60;
      setsockopt(socket_, SOL_SOCKET, SO_RCVTIMEO,
                 reinterpret_cast<const char*>(&timeout_ms),
                 sizeof(timeout_ms));
    }
    return std::nullopt;
  }

  std::optional<std::string> PrepareUsbReceiver(
      const flutter::EncodableValue* arguments) {
    profile_ = ReadProfile(arguments);
    transport_mode_ = TransportMode::kUsb;
    usb_receiver_mode_ = true;
    if (profile_.codec != AudioCodec::kPcm) {
      return "Windows USB receiver playback currently supports PCM only. Select PCM on the sender.";
    }

    if (usb_device_handle_ != INVALID_HANDLE_VALUE && usb_winusb_ != nullptr) {
      return std::nullopt;
    }

    return OpenAccessoryTransport();
  }

  std::optional<std::string> ConnectToSender(
      const flutter::EncodableValue* arguments) {
    if (!arguments || !std::holds_alternative<flutter::EncodableMap>(*arguments)) {
      return "Missing sender connection payload.";
    }

    const auto& payload = std::get<flutter::EncodableMap>(*arguments);
    const auto device_entry = payload.find(flutter::EncodableValue("device"));
    if (device_entry == payload.end() ||
        !std::holds_alternative<flutter::EncodableMap>(device_entry->second)) {
      return "Missing sender device.";
    }

    const auto profile_entry = payload.find(flutter::EncodableValue("profile"));
    if (profile_entry != payload.end()) {
      profile_ = ReadProfile(&profile_entry->second);
    }
    if (profile_.codec != AudioCodec::kPcm) {
      return "Windows receiver playback currently supports PCM only. Select PCM on the sender.";
    }

    const auto& device = std::get<flutter::EncodableMap>(device_entry->second);
    const std::string transport = ReadString(device, "transport", "wifi");
    if (transport == "usb") {
      return profile_entry != payload.end() ? PrepareUsbReceiver(&profile_entry->second)
                                            : PrepareUsbReceiver(nullptr);
    }
    const std::string host = ReadString(device, "host", "");
    if (host.empty()) {
      return "Missing sender host.";
    }
    const int port = ReadInt(device, "port", kAudioPort);

    const auto prepare_error =
        profile_entry != payload.end() ? PrepareReceiver(&profile_entry->second)
                                       : PrepareReceiver(nullptr);
    if (prepare_error.has_value()) {
      return prepare_error;
    }

    sockaddr_in address = {};
    address.sin_family = AF_INET;
    address.sin_port = htons(static_cast<u_short>(port));
    if (inet_pton(AF_INET, host.c_str(), &address.sin_addr) != 1) {
      return "Unable to parse sender address.";
    }

    {
      std::scoped_lock lock(receiver_source_mutex_);
      receiver_source_.address = address;
      receiver_source_.available = true;
    }
    return std::nullopt;
  }

  std::optional<std::string> StartStream(
      const flutter::EncodableValue* arguments) {
    profile_ = ReadProfile(arguments);
    UsbDebugLog("StartStream transport=" +
                std::to_string(transport_mode_ == TransportMode::kUsb ? 1 : 0) +
                " usb_receiver=" + std::to_string(usb_receiver_mode_ ? 1 : 0));

    bool has_receiver_source = false;
    {
      std::scoped_lock lock(receiver_source_mutex_);
      has_receiver_source = receiver_source_.available;
    }
    if ((has_receiver_source || usb_receiver_mode_) && !playback_running_) {
      receiver_session_id_ = GenerateSessionId();
      session_protocol_active_ = false;
      local_last_peer_packet_received_at_ms_ = 0;
    }
    if (has_receiver_source) {
      if (profile_.codec != AudioCodec::kPcm) {
        return "Windows receiver playback currently supports PCM only. Select PCM on the sender.";
      }
      if (playback_running_) {
        return std::nullopt;
      }
      ResetLocalAdaptivePlayback(profile_.sample_rate);
      playback_running_ = true;
      playback_receive_thread_ = std::thread(&Impl::PlaybackReceiveLoop, this);
      playback_render_thread_ = std::thread(&Impl::PlaybackRenderLoop, this);
      return std::nullopt;
    }

    if (usb_receiver_mode_) {
      if (profile_.codec != AudioCodec::kPcm) {
        return "Windows USB receiver playback currently supports PCM only. Select PCM on the sender.";
      }
      if (usb_device_handle_ == INVALID_HANDLE_VALUE || usb_winusb_ == nullptr) {
        const auto error = PrepareUsbReceiver(arguments);
        if (error.has_value()) {
          return error;
        }
      }
      if (playback_running_) {
        return std::nullopt;
      }
      ResetLocalAdaptivePlayback(profile_.sample_rate);
      playback_running_ = true;
      playback_receive_thread_ = std::thread(&Impl::PlaybackReceiveLoop, this);
      playback_render_thread_ = std::thread(&Impl::PlaybackRenderLoop, this);
      return std::nullopt;
    }

    if (transport_mode_ == TransportMode::kUsb &&
        (usb_device_handle_ == INVALID_HANDLE_VALUE || usb_winusb_ == nullptr)) {
      const auto error = PrepareUsbSender(arguments);
      if (error.has_value()) {
        return error;
      }
    } else if (transport_mode_ == TransportMode::kWifi &&
               socket_ == INVALID_SOCKET) {
      const auto error = PrepareSender(arguments);
      if (error.has_value()) {
        return error;
      }
    }

    if (capture_running_) {
      return std::nullopt;
    }

    capture_running_ = true;
    UsbDebugLog("StartStream capture thread starting");
    capture_thread_ = std::thread(&Impl::CaptureLoop, this);
    return std::nullopt;
  }

  void StopStream() {
    UsbDebugLog("StopStream");
    capture_running_ = false;
    if (capture_thread_.joinable()) {
      capture_thread_.join();
    }
    playback_running_ = false;
    playback_queue_cv_.notify_all();
    if (playback_receive_thread_.joinable()) {
      playback_receive_thread_.join();
    }
    if (playback_render_thread_.joinable()) {
      playback_render_thread_.join();
    }
    {
      std::scoped_lock lock(playback_queue_mutex_);
      playback_queue_.clear();
      playback_queue_frames_ = 0;
    }
    StopSoundEffects();
    {
      std::scoped_lock lock(receiver_source_mutex_);
      receiver_source_ = {};
    }
    local_input_sample_rate_ = 0;
    local_input_channels_ = 0;
    local_codec_id_ = kCodecPcm;
    local_output_sample_rate_ = 0;
    local_buffer_size_frames_ = 0;
    local_target_buffer_frames_ = 0;
    local_adaptive_playback_buffer_ms_ = 0;
    local_adaptive_max_playback_buffer_ms_ = 0;
    local_adaptive_limit_reached_ = 0;
    local_adaptive_underruns_in_window_ = 0;
    local_adaptive_underruns_in_burst_ = 0;
    local_adaptive_low_queue_samples_ = 0;
    local_render_started_ = false;
    local_render_started_at_ms_ = 0;
    local_signal_peak_ = 0.0;
    local_last_playback_signal_level_ = 0.0;
    local_last_audio_packet_received_at_ms_ = 0;
    local_last_peer_packet_received_at_ms_ = 0;
    receiver_session_id_ = 0;
    session_protocol_active_ = false;
    ResetLocalAdaptiveDelayTracker();
    opus_codec_.Shutdown();
    aac_codec_.Shutdown();
    ResetPacketizer();
  }

  void SetVolume(const flutter::EncodableValue* arguments) {
    if (!arguments || !std::holds_alternative<flutter::EncodableMap>(*arguments)) {
      return;
    }
    volume_ = static_cast<float>(
        std::clamp(ReadDouble(std::get<flutter::EncodableMap>(*arguments),
                              "value", volume_.load()),
                   0.0, 1.0));
  }

  void SetMuted(const flutter::EncodableValue* arguments) {
    if (!arguments || !std::holds_alternative<flutter::EncodableMap>(*arguments)) {
      return;
    }
    muted_ = ReadBool(std::get<flutter::EncodableMap>(*arguments), "value",
                      muted_.load());
  }

  std::optional<std::string> PlaySoundEffect(
      const flutter::EncodableValue* arguments) {
    if (!arguments ||
        !std::holds_alternative<flutter::EncodableMap>(*arguments)) {
      return "Missing soundboard payload.";
    }

    const auto& map = std::get<flutter::EncodableMap>(*arguments);
    const std::string path = ReadString(map, "path", "");
    if (path.empty()) {
      return "Choose a sound file first.";
    }

    const std::string target = ReadString(map, "target", "stream");
    if (target == "micRoute") {
      return PlaySoundEffectToOutput(arguments);
    }

    if (!capture_running_.load()) {
      return "Start the sender stream before playing soundboard audio.";
    }

    const double gain = std::clamp(ReadDouble(map, "volume", 1.0), 0.0, 1.0);
    const int sample_rate = OutputSampleRateForProfile();
    const int channels = std::clamp(profile_.channels, 1, 2);
    auto decoded = DecodeSoundEffectFile(path, sample_rate, channels, gain);
    if (!decoded.has_value()) {
      return "Unable to decode that sound file.";
    }
    if (decoded->pcm.empty()) {
      return "The selected sound file has no playable audio.";
    }

    std::scoped_lock lock(sound_effect_mutex_);
    sound_effect_queue_.push_back(std::move(*decoded));
    return std::nullopt;
  }

  void StopSoundEffects() {
    {
      std::scoped_lock lock(sound_effect_mutex_);
      sound_effect_queue_.clear();
    }
    StopSoundEffectOutput();
    StopSoundEffectMonitor();
  }

  void Disconnect() {
    StopVirtualMicPassthrough();
    StopSoundEffects();
    StopStream();
    usb_receiver_mode_ = false;

    control_running_ = false;
    if (socket_ != INVALID_SOCKET) {
      closesocket(socket_);
      socket_ = INVALID_SOCKET;
    }
    socket_bind_address_ = INADDR_ANY;
    if (control_thread_.joinable()) {
      control_thread_.join();
    }

    usb_control_running_ = false;
    if (usb_control_thread_.joinable()) {
      usb_control_thread_.join();
    }
    CloseUsbTransport();

    {
      std::scoped_lock lock(receiver_source_mutex_);
      receiver_source_ = {};
    }
    {
      std::scoped_lock lock(endpoint_mutex_);
      endpoint_ = {};
    }
    remote_output_latency_ms_ = -1.0;
    remote_audio_latency_ms_ = -1.0;
    remote_network_latency_ms_ = -1.0;
    remote_signal_level_ = 0.0;
    remote_queued_frames_ = 0;
    remote_buffer_size_frames_ = 0;
    remote_target_buffer_frames_ = 0;
    remote_adaptive_playback_buffer_ms_ = 0;
    remote_adaptive_max_playback_buffer_ms_ = 0;
    remote_adaptive_limit_reached_ = 0;
    remote_adaptive_underruns_in_window_ = 0;
    remote_adaptive_underruns_in_burst_ = 0;
    remote_adaptive_low_queue_samples_ = 0;
    remote_playback_queue_fill_percent_ = 0;
    remote_underrun_count_ = 0;
    remote_dropped_packet_count_ = 0;
    remote_lost_packet_count_ = 0;
    remote_trim_count_ = 0;
    remote_metrics_received_at_ms_ = 0;
    remote_session_id_ = 0;
    last_heartbeat_sent_at_ms_ = 0;
    {
      std::scoped_lock lock(remote_receiver_clock_mutex_);
      remote_receiver_clock_echo_ = {};
    }
    {
      std::scoped_lock lock(remote_capabilities_mutex_);
      remote_platform_.clear();
      remote_supported_codecs_.clear();
    }
    local_signal_peak_ = 0.0;

    if (winsock_started_) {
      WSACleanup();
      winsock_started_ = false;
    }
    if (media_foundation_started_) {
      MFShutdown();
      media_foundation_started_ = false;
    }
  }

  std::optional<std::string> ConfigureVirtualMicPassthrough(
      const flutter::EncodableValue* arguments) {
    if (!arguments ||
        !std::holds_alternative<flutter::EncodableMap>(*arguments)) {
      return "Missing virtual mic payload.";
    }

    const auto& map = std::get<flutter::EncodableMap>(*arguments);
    const bool enabled = ReadBool(map, "enabled", false);
    const std::string device_id = ReadString(map, "outputDeviceId", "");
    if (!enabled || device_id.empty()) {
      StopVirtualMicPassthrough();
      return std::nullopt;
    }

    if (virtual_mic_passthrough_running_.load() &&
        virtual_mic_passthrough_output_device_id_ == device_id) {
      return std::nullopt;
    }

    StopVirtualMicPassthrough();
    virtual_mic_passthrough_output_device_id_ = device_id;
    virtual_mic_passthrough_running_ = true;
    virtual_mic_passthrough_thread_ =
        std::thread(&Impl::VirtualMicPassthroughLoop, this, device_id);
    return std::nullopt;
  }

 private:
  std::wstring DeviceId(IMMDevice* device) const {
    if (device == nullptr) {
      return {};
    }

    LPWSTR raw_id = nullptr;
    if (FAILED(device->GetId(&raw_id)) || raw_id == nullptr) {
      return {};
    }
    std::wstring id(raw_id);
    CoTaskMemFree(raw_id);
    return id;
  }

  std::wstring DeviceFriendlyName(IMMDevice* device) const {
    if (device == nullptr) {
      return {};
    }

    Microsoft::WRL::ComPtr<IPropertyStore> properties;
    if (FAILED(device->OpenPropertyStore(STGM_READ, &properties))) {
      return {};
    }

    PROPVARIANT value;
    PropVariantInit(&value);
    std::wstring name;
    if (SUCCEEDED(properties->GetValue(PKEY_Device_FriendlyName, &value)) &&
        value.vt == VT_LPWSTR && value.pwszVal != nullptr) {
      name = value.pwszVal;
    }
    PropVariantClear(&value);
    return name;
  }

  Microsoft::WRL::ComPtr<IMMDevice> SoundboardOutputDeviceForId(
      IMMDeviceEnumerator* enumerator,
      const std::string& device_id) const {
    Microsoft::WRL::ComPtr<IMMDevice> device;
    if (enumerator == nullptr) {
      return device;
    }

    if (device_id.empty()) {
      enumerator->GetDefaultAudioEndpoint(eRender, eCommunications, &device);
      return device;
    }

    const std::wstring wide_id = Widen(device_id);
    if (!wide_id.empty()) {
      enumerator->GetDevice(wide_id.c_str(), &device);
    }
    return device;
  }

  Microsoft::WRL::ComPtr<IMMDevice> SoundboardMonitorDevice(
      IMMDeviceEnumerator* enumerator) const {
    Microsoft::WRL::ComPtr<IMMDevice> device;
    if (enumerator == nullptr) {
      return device;
    }

    const auto is_usable_monitor = [this](IMMDevice* candidate) {
      if (candidate == nullptr) {
        return false;
      }
      const std::wstring name = DeviceFriendlyName(candidate);
      const std::wstring id = DeviceId(candidate);
      return !IsLikelyVirtualCableEndpoint(name) &&
             !IsLikelyVirtualCableEndpoint(id) &&
             !IsUnsupportedVirtualCableRenderEndpoint(name, id);
    };

    if (SUCCEEDED(enumerator->GetDefaultAudioEndpoint(eRender, eConsole,
                                                      &device)) &&
        is_usable_monitor(device.Get())) {
      return device;
    }
    device.Reset();

    if (SUCCEEDED(enumerator->GetDefaultAudioEndpoint(eRender, eMultimedia,
                                                      &device)) &&
        is_usable_monitor(device.Get())) {
      return device;
    }
    device.Reset();

    Microsoft::WRL::ComPtr<IMMDeviceCollection> collection;
    if (FAILED(enumerator->EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE,
                                               &collection))) {
      return device;
    }

    UINT count = 0;
    collection->GetCount(&count);
    for (UINT index = 0; index < count; ++index) {
      Microsoft::WRL::ComPtr<IMMDevice> candidate;
      if (FAILED(collection->Item(index, &candidate))) {
        continue;
      }
      if (is_usable_monitor(candidate.Get())) {
        return candidate;
      }
    }

    return device;
  }

  Microsoft::WRL::ComPtr<IMMDevice> PhysicalMicrophoneDevice(
      IMMDeviceEnumerator* enumerator) const {
    Microsoft::WRL::ComPtr<IMMDevice> device;
    if (enumerator == nullptr) {
      return device;
    }

    if (SUCCEEDED(enumerator->GetDefaultAudioEndpoint(
            eCapture, eCommunications, &device))) {
      const std::wstring name = DeviceFriendlyName(device.Get());
      const std::wstring id = DeviceId(device.Get());
      if (!IsLikelyVirtualCableEndpoint(name) &&
          !IsLikelyVirtualCableEndpoint(id)) {
        return device;
      }
      device.Reset();
    }

    Microsoft::WRL::ComPtr<IMMDeviceCollection> collection;
    if (FAILED(enumerator->EnumAudioEndpoints(eCapture, DEVICE_STATE_ACTIVE,
                                               &collection))) {
      return device;
    }

    UINT count = 0;
    collection->GetCount(&count);
    for (UINT index = 0; index < count; ++index) {
      Microsoft::WRL::ComPtr<IMMDevice> candidate;
      if (FAILED(collection->Item(index, &candidate))) {
        continue;
      }

      const std::wstring name = DeviceFriendlyName(candidate.Get());
      const std::wstring id = DeviceId(candidate.Get());
      if (!IsLikelyVirtualCableEndpoint(name) &&
          !IsLikelyVirtualCableEndpoint(id)) {
        return candidate;
      }
    }

    return device;
  }

  std::optional<std::string> EnsureMediaFoundationStarted() {
    if (media_foundation_started_) {
      return std::nullopt;
    }

    const HRESULT hr = MFStartup(MF_VERSION);
    if (FAILED(hr)) {
      return "Unable to initialize Windows Media Foundation.";
    }
    media_foundation_started_ = true;
    return std::nullopt;
  }

  std::optional<std::string> EnsureWinsockStarted() {
    if (winsock_started_) {
      return std::nullopt;
    }

    WSADATA data = {};
    const int startup_result = WSAStartup(MAKEWORD(2, 2), &data);
    if (startup_result != 0) {
      return "Unable to initialize Winsock.";
    }
    winsock_started_ = true;
    return std::nullopt;
  }

  std::optional<SoundEffectClip> DecodeSoundEffectFile(
      const std::string& path,
      int sample_rate,
      int channels,
      double gain) {
    if (sample_rate <= 0 || channels <= 0) {
      return std::nullopt;
    }

    const auto media_foundation_error = EnsureMediaFoundationStarted();
    if (media_foundation_error.has_value()) {
      return std::nullopt;
    }

    const std::wstring wide_path = Widen(path);
    if (wide_path.empty()) {
      return std::nullopt;
    }

    Microsoft::WRL::ComPtr<IMFSourceReader> reader;
    HRESULT hr =
        MFCreateSourceReaderFromURL(wide_path.c_str(), nullptr, &reader);
    if (FAILED(hr)) {
      return std::nullopt;
    }

    const DWORD all_streams =
        static_cast<DWORD>(MF_SOURCE_READER_ALL_STREAMS);
    const DWORD first_audio_stream =
        static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM);
    reader->SetStreamSelection(all_streams, FALSE);
    hr = reader->SetStreamSelection(first_audio_stream, TRUE);
    if (FAILED(hr)) {
      return std::nullopt;
    }

    Microsoft::WRL::ComPtr<IMFMediaType> media_type;
    hr = MFCreateMediaType(&media_type);
    if (FAILED(hr)) {
      return std::nullopt;
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

    hr = reader->SetCurrentMediaType(first_audio_stream, nullptr,
                                     media_type.Get());
    if (FAILED(hr)) {
      return std::nullopt;
    }

    SoundEffectClip clip;
    clip.sample_rate = sample_rate;
    clip.channels = channels;

    while (true) {
      DWORD flags = 0;
      Microsoft::WRL::ComPtr<IMFSample> sample;
      hr = reader->ReadSample(first_audio_stream, 0, nullptr, &flags, nullptr,
                              &sample);
      if (FAILED(hr)) {
        return std::nullopt;
      }
      if ((flags & MF_SOURCE_READERF_ENDOFSTREAM) != 0) {
        break;
      }
      if (!sample) {
        continue;
      }

      Microsoft::WRL::ComPtr<IMFMediaBuffer> buffer;
      hr = sample->ConvertToContiguousBuffer(&buffer);
      if (FAILED(hr)) {
        return std::nullopt;
      }

      BYTE* data = nullptr;
      DWORD max_length = 0;
      DWORD current_length = 0;
      hr = buffer->Lock(&data, &max_length, &current_length);
      if (FAILED(hr)) {
        return std::nullopt;
      }
      (void)max_length;

      const size_t sample_count = current_length / sizeof(int16_t);
      const auto* pcm = reinterpret_cast<const int16_t*>(data);
      clip.pcm.reserve(clip.pcm.size() + sample_count);
      for (size_t index = 0; index < sample_count; ++index) {
        clip.pcm.push_back(FloatToPcm16(Pcm16ToFloat(pcm[index]) *
                                        static_cast<float>(gain)));
      }
      buffer->Unlock();
    }

    return clip;
  }

  std::optional<SoundboardOutputFormat> SoundboardOutputFormatForDevice(
      const std::string& device_id) const {
    HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    const bool owns_com = SUCCEEDED(hr);
    if (FAILED(hr) && hr != RPC_E_CHANGED_MODE) {
      return std::nullopt;
    }

    Microsoft::WRL::ComPtr<IMMDeviceEnumerator> enumerator;
    hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                          IID_PPV_ARGS(&enumerator));
    if (FAILED(hr)) {
      FinishCom(owns_com);
      return std::nullopt;
    }

    auto device = SoundboardOutputDeviceForId(enumerator.Get(), device_id);
    if (!device) {
      FinishCom(owns_com);
      return std::nullopt;
    }

    Microsoft::WRL::ComPtr<IAudioClient> audio_client;
    hr = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                          reinterpret_cast<void**>(audio_client.GetAddressOf()));
    if (FAILED(hr)) {
      FinishCom(owns_com);
      return std::nullopt;
    }

    WAVEFORMATEX* raw_mix_format = nullptr;
    hr = audio_client->GetMixFormat(&raw_mix_format);
    if (FAILED(hr) || raw_mix_format == nullptr) {
      FinishCom(owns_com);
      return std::nullopt;
    }

    SoundboardOutputFormat format;
    format.sample_rate = static_cast<int>(raw_mix_format->nSamplesPerSec);
    format.channels = std::max<int>(1, raw_mix_format->nChannels);

    const REFERENCE_TIME buffer_duration = 10000000LL * 80 / 1000;
    hr = audio_client->Initialize(AUDCLNT_SHAREMODE_SHARED, 0,
                                  buffer_duration, 0, raw_mix_format, nullptr);
    if (FAILED(hr)) {
      CoTaskMemFree(raw_mix_format);
      FinishCom(owns_com);
      return std::nullopt;
    }

    CoTaskMemFree(raw_mix_format);
    FinishCom(owns_com);
    return format;
  }

  std::optional<std::string> PlaySoundEffectToOutput(
      const flutter::EncodableValue* arguments) {
    if (!arguments ||
        !std::holds_alternative<flutter::EncodableMap>(*arguments)) {
      return "Missing soundboard payload.";
    }

    const auto& map = std::get<flutter::EncodableMap>(*arguments);
    const std::string path = ReadString(map, "path", "");
    const std::string device_id = ReadString(map, "outputDeviceId", "");
    const double gain = std::clamp(ReadDouble(map, "volume", 1.0), 0.0, 1.0);
    if (path.empty()) {
      return "Choose a sound file first.";
    }

    const auto format = SoundboardOutputFormatForDevice(device_id);
    if (!format.has_value()) {
      return "Unable to open the selected mic route device.";
    }

    auto decoded = DecodeSoundEffectFile(path, format->sample_rate,
                                         format->channels, gain);
    if (!decoded.has_value()) {
      return "Unable to decode that sound file.";
    }
    if (decoded->pcm.empty()) {
      return "The selected sound file has no playable audio.";
    }

    const SoundEffectClip monitor_clip = *decoded;
    {
      std::unique_lock lock(sound_effect_output_mutex_);
      const bool device_changed =
          sound_effect_output_running_.load() &&
          (sound_effect_output_device_id_ != device_id ||
           sound_effect_output_sample_rate_ != format->sample_rate ||
           sound_effect_output_channels_ != format->channels);
      if (device_changed) {
        lock.unlock();
        StopSoundEffectOutput();
        lock.lock();
      }

      if (!sound_effect_output_running_.load()) {
        if (sound_effect_output_thread_.joinable()) {
          lock.unlock();
          sound_effect_output_thread_.join();
          lock.lock();
        }
        sound_effect_output_device_id_ = device_id;
        sound_effect_output_sample_rate_ = format->sample_rate;
        sound_effect_output_channels_ = format->channels;
        sound_effect_output_running_ = true;
        sound_effect_output_thread_ =
            std::thread(&Impl::SoundEffectOutputLoop, this, device_id);
      }
      sound_effect_output_queue_.push_back(std::move(*decoded));
    }
    sound_effect_output_cv_.notify_one();
    QueueSoundEffectMonitor(monitor_clip);
    return std::nullopt;
  }

  void StopSoundEffectOutput() {
    sound_effect_output_running_ = false;
    sound_effect_output_cv_.notify_all();
    if (sound_effect_output_thread_.joinable()) {
      sound_effect_output_thread_.join();
    }
    {
      std::scoped_lock lock(sound_effect_output_mutex_);
      sound_effect_output_queue_.clear();
      sound_effect_output_device_id_.clear();
      sound_effect_output_sample_rate_ = 0;
      sound_effect_output_channels_ = 0;
    }
  }

  void QueueSoundEffectMonitor(const SoundEffectClip& clip) {
    std::unique_lock lock(sound_effect_monitor_mutex_);
    if (!sound_effect_monitor_running_.load()) {
      if (sound_effect_monitor_thread_.joinable()) {
        lock.unlock();
        sound_effect_monitor_thread_.join();
        lock.lock();
      }
      sound_effect_monitor_running_ = true;
      sound_effect_monitor_thread_ =
          std::thread(&Impl::SoundEffectMonitorLoop, this);
    }
    sound_effect_monitor_queue_.push_back(clip);
    lock.unlock();
    sound_effect_monitor_cv_.notify_one();
  }

  void StopSoundEffectMonitor() {
    sound_effect_monitor_running_ = false;
    sound_effect_monitor_cv_.notify_all();
    if (sound_effect_monitor_thread_.joinable()) {
      sound_effect_monitor_thread_.join();
    }
    {
      std::scoped_lock lock(sound_effect_monitor_mutex_);
      sound_effect_monitor_queue_.clear();
    }
  }

  void StopVirtualMicPassthrough() {
    virtual_mic_passthrough_running_ = false;
    if (virtual_mic_passthrough_thread_.joinable()) {
      virtual_mic_passthrough_thread_.join();
    }
    virtual_mic_passthrough_output_device_id_.clear();
  }

  void VirtualMicPassthroughLoop(std::string output_device_id) {
    HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    const bool owns_com = SUCCEEDED(hr);
    if (FAILED(hr) && hr != RPC_E_CHANGED_MODE) {
      virtual_mic_passthrough_running_ = false;
      return;
    }

    Microsoft::WRL::ComPtr<IMMDeviceEnumerator> enumerator;
    hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                          IID_PPV_ARGS(&enumerator));
    if (FAILED(hr)) {
      FinishCom(owns_com);
      virtual_mic_passthrough_running_ = false;
      return;
    }

    auto input_device = PhysicalMicrophoneDevice(enumerator.Get());
    auto output_device =
        SoundboardOutputDeviceForId(enumerator.Get(), output_device_id);
    if (!input_device || !output_device) {
      FinishCom(owns_com);
      virtual_mic_passthrough_running_ = false;
      return;
    }

    Microsoft::WRL::ComPtr<IAudioClient> capture_client;
    hr = input_device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                                reinterpret_cast<void**>(
                                    capture_client.GetAddressOf()));
    if (FAILED(hr)) {
      FinishCom(owns_com);
      virtual_mic_passthrough_running_ = false;
      return;
    }

    Microsoft::WRL::ComPtr<IAudioClient> render_client_audio;
    hr = output_device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                                 reinterpret_cast<void**>(
                                     render_client_audio.GetAddressOf()));
    if (FAILED(hr)) {
      FinishCom(owns_com);
      virtual_mic_passthrough_running_ = false;
      return;
    }

    WAVEFORMATEX* raw_capture_format = nullptr;
    hr = capture_client->GetMixFormat(&raw_capture_format);
    if (FAILED(hr) || raw_capture_format == nullptr) {
      FinishCom(owns_com);
      virtual_mic_passthrough_running_ = false;
      return;
    }

    WAVEFORMATEX* raw_render_format = nullptr;
    hr = render_client_audio->GetMixFormat(&raw_render_format);
    if (FAILED(hr) || raw_render_format == nullptr) {
      CoTaskMemFree(raw_capture_format);
      FinishCom(owns_com);
      virtual_mic_passthrough_running_ = false;
      return;
    }

    const size_t capture_format_size =
        sizeof(WAVEFORMATEX) + raw_capture_format->cbSize;
    std::vector<BYTE> capture_format_storage(capture_format_size);
    std::memcpy(capture_format_storage.data(), raw_capture_format,
                capture_format_size);
    const auto* capture_format =
        reinterpret_cast<const WAVEFORMATEX*>(capture_format_storage.data());
    CoTaskMemFree(raw_capture_format);

    const size_t render_format_size =
        sizeof(WAVEFORMATEX) + raw_render_format->cbSize;
    std::vector<BYTE> render_format_storage(render_format_size);
    std::memcpy(render_format_storage.data(), raw_render_format,
                render_format_size);
    const auto* render_format =
        reinterpret_cast<const WAVEFORMATEX*>(render_format_storage.data());
    CoTaskMemFree(raw_render_format);

    const REFERENCE_TIME buffer_duration = 10000000LL * 80 / 1000;
    hr = capture_client->Initialize(AUDCLNT_SHAREMODE_SHARED, 0,
                                    buffer_duration, 0, capture_format,
                                    nullptr);
    if (FAILED(hr)) {
      FinishCom(owns_com);
      virtual_mic_passthrough_running_ = false;
      return;
    }

    hr = render_client_audio->Initialize(AUDCLNT_SHAREMODE_SHARED, 0,
                                         buffer_duration, 0, render_format,
                                         nullptr);
    if (FAILED(hr)) {
      FinishCom(owns_com);
      virtual_mic_passthrough_running_ = false;
      return;
    }

    Microsoft::WRL::ComPtr<IAudioCaptureClient> capture_client_audio;
    hr = capture_client->GetService(IID_PPV_ARGS(&capture_client_audio));
    if (FAILED(hr)) {
      FinishCom(owns_com);
      virtual_mic_passthrough_running_ = false;
      return;
    }

    Microsoft::WRL::ComPtr<IAudioRenderClient> render_client;
    hr = render_client_audio->GetService(IID_PPV_ARGS(&render_client));
    if (FAILED(hr)) {
      FinishCom(owns_com);
      virtual_mic_passthrough_running_ = false;
      return;
    }

    UINT32 render_buffer_frames = 0;
    render_client_audio->GetBufferSize(&render_buffer_frames);

    DWORD task_index = 0;
    HANDLE task_handle =
        AvSetMmThreadCharacteristics(L"Pro Audio", &task_index);
    if (task_handle != nullptr) {
      AvSetMmThreadPriority(task_handle, AVRT_PRIORITY_HIGH);
    }

    capture_client->Start();
    render_client_audio->Start();

    while (virtual_mic_passthrough_running_) {
      UINT32 packet_frames = 0;
      if (FAILED(capture_client_audio->GetNextPacketSize(&packet_frames))) {
        break;
      }
      if (packet_frames == 0) {
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
        continue;
      }

      while (virtual_mic_passthrough_running_ && packet_frames > 0) {
        BYTE* data = nullptr;
        UINT32 frames = 0;
        DWORD flags = 0;
        hr = capture_client_audio->GetBuffer(&data, &frames, &flags, nullptr,
                                             nullptr);
        if (FAILED(hr)) {
          virtual_mic_passthrough_running_ = false;
          break;
        }

        const bool silent = (flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0;
        auto pcm = ConvertToPcm16(data, frames, *capture_format, silent, 1.0f,
                                  false);
        capture_client_audio->ReleaseBuffer(frames);

        if (!pcm.empty()) {
          const auto output =
              ReformatPcm(pcm, capture_format->nSamplesPerSec,
                          capture_format->nChannels,
                          render_format->nSamplesPerSec,
                          render_format->nChannels);
          WriteRenderPcm(render_client.Get(), render_client_audio.Get(),
                         render_buffer_frames, *render_format, output,
                         virtual_mic_passthrough_running_, false);
        }

        if (FAILED(capture_client_audio->GetNextPacketSize(&packet_frames))) {
          virtual_mic_passthrough_running_ = false;
          break;
        }
      }
    }

    capture_client->Stop();
    render_client_audio->Stop();
    if (task_handle != nullptr) {
      AvRevertMmThreadCharacteristics(task_handle);
    }
    FinishCom(owns_com);
    virtual_mic_passthrough_running_ = false;
  }

  void SoundEffectOutputLoop(std::string device_id) {
    HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    const bool owns_com = SUCCEEDED(hr);
    if (FAILED(hr) && hr != RPC_E_CHANGED_MODE) {
      sound_effect_output_running_ = false;
      return;
    }

    Microsoft::WRL::ComPtr<IMMDeviceEnumerator> enumerator;
    hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                          IID_PPV_ARGS(&enumerator));
    if (FAILED(hr)) {
      FinishCom(owns_com);
      sound_effect_output_running_ = false;
      return;
    }

    auto device = SoundboardOutputDeviceForId(enumerator.Get(), device_id);
    if (!device) {
      FinishCom(owns_com);
      sound_effect_output_running_ = false;
      return;
    }

    Microsoft::WRL::ComPtr<IAudioClient> audio_client;
    hr = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                          reinterpret_cast<void**>(audio_client.GetAddressOf()));
    if (FAILED(hr)) {
      FinishCom(owns_com);
      sound_effect_output_running_ = false;
      return;
    }

    WAVEFORMATEX* raw_mix_format = nullptr;
    hr = audio_client->GetMixFormat(&raw_mix_format);
    if (FAILED(hr) || raw_mix_format == nullptr) {
      FinishCom(owns_com);
      sound_effect_output_running_ = false;
      return;
    }

    const size_t mix_format_size = sizeof(WAVEFORMATEX) + raw_mix_format->cbSize;
    std::vector<BYTE> mix_format_storage(mix_format_size);
    std::memcpy(mix_format_storage.data(), raw_mix_format, mix_format_size);
    const auto* mix_format =
        reinterpret_cast<const WAVEFORMATEX*>(mix_format_storage.data());
    CoTaskMemFree(raw_mix_format);

    const REFERENCE_TIME buffer_duration = 10000000LL * 80 / 1000;
    hr = audio_client->Initialize(AUDCLNT_SHAREMODE_SHARED, 0,
                                  buffer_duration, 0, mix_format, nullptr);
    if (FAILED(hr)) {
      FinishCom(owns_com);
      sound_effect_output_running_ = false;
      return;
    }

    UINT32 buffer_frames = 0;
    audio_client->GetBufferSize(&buffer_frames);
    Microsoft::WRL::ComPtr<IAudioRenderClient> render_client;
    hr = audio_client->GetService(IID_PPV_ARGS(&render_client));
    if (FAILED(hr)) {
      FinishCom(owns_com);
      sound_effect_output_running_ = false;
      return;
    }

    DWORD task_index = 0;
    HANDLE task_handle = AvSetMmThreadCharacteristics(L"Pro Audio", &task_index);
    if (task_handle != nullptr) {
      AvSetMmThreadPriority(task_handle, AVRT_PRIORITY_HIGH);
    }
    audio_client->Start();

    while (sound_effect_output_running_) {
      SoundEffectClip clip;
      {
        std::unique_lock lock(sound_effect_output_mutex_);
        sound_effect_output_cv_.wait_for(
            lock, std::chrono::milliseconds(40), [this] {
              return !sound_effect_output_running_.load() ||
                     !sound_effect_output_queue_.empty();
            });
        if (!sound_effect_output_running_) {
          break;
        }
        if (sound_effect_output_queue_.empty()) {
          continue;
        }
        clip = std::move(sound_effect_output_queue_.front());
        sound_effect_output_queue_.pop_front();
      }

      const auto output = ReformatPcm(clip.pcm, clip.sample_rate,
                                      clip.channels,
                                      mix_format->nSamplesPerSec,
                                      mix_format->nChannels);
      WriteRenderPcm(render_client.Get(), audio_client.Get(), buffer_frames,
                     *mix_format, output, sound_effect_output_running_, false);
    }

    audio_client->Stop();
    if (task_handle != nullptr) {
      AvRevertMmThreadCharacteristics(task_handle);
    }
    FinishCom(owns_com);
    sound_effect_output_running_ = false;
  }

  void SoundEffectMonitorLoop() {
    HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    const bool owns_com = SUCCEEDED(hr);
    if (FAILED(hr) && hr != RPC_E_CHANGED_MODE) {
      sound_effect_monitor_running_ = false;
      return;
    }

    Microsoft::WRL::ComPtr<IMMDeviceEnumerator> enumerator;
    hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                          IID_PPV_ARGS(&enumerator));
    if (FAILED(hr)) {
      FinishCom(owns_com);
      sound_effect_monitor_running_ = false;
      return;
    }

    auto device = SoundboardMonitorDevice(enumerator.Get());
    if (!device) {
      FinishCom(owns_com);
      sound_effect_monitor_running_ = false;
      return;
    }

    Microsoft::WRL::ComPtr<IAudioClient> audio_client;
    hr = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                          reinterpret_cast<void**>(audio_client.GetAddressOf()));
    if (FAILED(hr)) {
      FinishCom(owns_com);
      sound_effect_monitor_running_ = false;
      return;
    }

    WAVEFORMATEX* raw_mix_format = nullptr;
    hr = audio_client->GetMixFormat(&raw_mix_format);
    if (FAILED(hr) || raw_mix_format == nullptr) {
      FinishCom(owns_com);
      sound_effect_monitor_running_ = false;
      return;
    }

    const size_t mix_format_size = sizeof(WAVEFORMATEX) + raw_mix_format->cbSize;
    std::vector<BYTE> mix_format_storage(mix_format_size);
    std::memcpy(mix_format_storage.data(), raw_mix_format, mix_format_size);
    const auto* mix_format =
        reinterpret_cast<const WAVEFORMATEX*>(mix_format_storage.data());
    CoTaskMemFree(raw_mix_format);

    const REFERENCE_TIME buffer_duration = 10000000LL * 80 / 1000;
    hr = audio_client->Initialize(AUDCLNT_SHAREMODE_SHARED, 0,
                                  buffer_duration, 0, mix_format, nullptr);
    if (FAILED(hr)) {
      FinishCom(owns_com);
      sound_effect_monitor_running_ = false;
      return;
    }

    UINT32 buffer_frames = 0;
    audio_client->GetBufferSize(&buffer_frames);
    Microsoft::WRL::ComPtr<IAudioRenderClient> render_client;
    hr = audio_client->GetService(IID_PPV_ARGS(&render_client));
    if (FAILED(hr)) {
      FinishCom(owns_com);
      sound_effect_monitor_running_ = false;
      return;
    }

    DWORD task_index = 0;
    HANDLE task_handle = AvSetMmThreadCharacteristics(L"Pro Audio", &task_index);
    if (task_handle != nullptr) {
      AvSetMmThreadPriority(task_handle, AVRT_PRIORITY_HIGH);
    }
    audio_client->Start();

    while (sound_effect_monitor_running_) {
      SoundEffectClip clip;
      {
        std::unique_lock lock(sound_effect_monitor_mutex_);
        sound_effect_monitor_cv_.wait_for(
            lock, std::chrono::milliseconds(40), [this] {
              return !sound_effect_monitor_running_.load() ||
                     !sound_effect_monitor_queue_.empty();
            });
        if (!sound_effect_monitor_running_) {
          break;
        }
        if (sound_effect_monitor_queue_.empty()) {
          continue;
        }
        clip = std::move(sound_effect_monitor_queue_.front());
        sound_effect_monitor_queue_.pop_front();
      }

      const auto output = ReformatPcm(clip.pcm, clip.sample_rate,
                                      clip.channels,
                                      mix_format->nSamplesPerSec,
                                      mix_format->nChannels);
      WriteRenderPcm(render_client.Get(), audio_client.Get(), buffer_frames,
                     *mix_format, output, sound_effect_monitor_running_, false);
    }

    audio_client->Stop();
    if (task_handle != nullptr) {
      AvRevertMmThreadCharacteristics(task_handle);
    }
    FinishCom(owns_com);
    sound_effect_monitor_running_ = false;
  }

  void ControlLoop() {
    std::vector<char> buffer(kSubscribeMaxBytes);

    while (control_running_) {
      sockaddr_in remote = {};
      int remote_size = sizeof(remote);
      const int received =
          recvfrom(socket_, buffer.data(), static_cast<int>(buffer.size()), 0,
                   reinterpret_cast<sockaddr*>(&remote), &remote_size);
      if (received == SOCKET_ERROR) {
        continue;
      }
      if (received < static_cast<int>(std::strlen(kSubscribePrefix)) ||
          std::memcmp(buffer.data(), kSubscribePrefix,
                      std::strlen(kSubscribePrefix)) != 0) {
        continue;
      }

      const std::string message(buffer.data(), received);
      UpdateRemoteMetrics(message);
      const uint64_t session_id = remote_session_id_.load();

      {
        std::scoped_lock lock(endpoint_mutex_);
        endpoint_.address = remote;
        endpoint_.available = true;
        endpoint_.session_id = session_id;
      }
      MaybeSendHeartbeat(remote, session_id);
    }
  }

  std::vector<uint8_t> BuildHeartbeatPacket(uint64_t session_id,
                                            int64_t now) const {
    std::vector<uint8_t> packet(kPacketV5HeaderBytes);
    WriteU32(packet, 0, kPacketV5Magic);
    WriteU32(packet, 4, sequence_.load());
    WriteU32(packet, 8, 0);
    WriteU16(packet, 12, 0);
    WriteU16(packet, 14, 0);
    WriteU16(packet, 16, kCodecPcm);
    WriteU16(packet, 18, kPacketKindHeartbeat);
    WriteU32(packet, 20, 0);
    WriteU64(packet, 24, static_cast<uint64_t>(now));
    WriteU64(packet, 32, 0);
    WriteU64(packet, 40, 0);
    WriteU32(packet, 48, static_cast<uint32_t>(std::clamp(
                           profile_.playback_buffer_ms, kMinBufferMs,
                           kMaxBufferMs)));
    WriteU32(packet, 52, ReceiverOptionsFor(profile_));
    WriteU64(packet, 56, session_id);
    return packet;
  }

  void MaybeSendHeartbeat(const sockaddr_in& address, uint64_t session_id) {
    if (session_id == 0 || socket_ == INVALID_SOCKET) {
      return;
    }

    const int64_t now = NowMillis();
    const int64_t last_sent = last_heartbeat_sent_at_ms_.load();
    if (now - last_sent < kHeartbeatIntervalMs) {
      return;
    }

    const std::vector<uint8_t> packet =
        BuildHeartbeatPacket(session_id, now);
    if (sendto(socket_, reinterpret_cast<const char*>(packet.data()),
               static_cast<int>(packet.size()), 0,
               reinterpret_cast<const sockaddr*>(&address),
               sizeof(address)) != SOCKET_ERROR) {
      last_heartbeat_sent_at_ms_ = now;
    }
  }

  void CloseNetworkSocket() {
    control_running_ = false;
    if (socket_ != INVALID_SOCKET) {
      closesocket(socket_);
      socket_ = INVALID_SOCKET;
    }
    if (control_thread_.joinable()) {
      control_thread_.join();
    }
    socket_bind_address_ = INADDR_ANY;
    {
      std::scoped_lock lock(endpoint_mutex_);
      endpoint_ = {};
    }
  }

  std::optional<std::string> OpenAccessoryTransport() {
    UsbDebugLog("OpenAccessoryTransport");
    CloseUsbTransport();

    if (auto error = OpenExistingAccessory()) {
      if (error.value() != kAoaAccessoryUnavailable) {
        UsbDebugLog("OpenExistingAccessory failed: " + error.value());
        return error;
      }
      UsbDebugLog("AOA accessory not already available; starting accessory mode");
    } else {
      UsbDebugLog("OpenExistingAccessory succeeded without renegotiation");
      return std::nullopt;
    }
    if (auto error = StartAccessoryMode()) {
      UsbDebugLog("StartAccessoryMode failed: " + error.value());
      return error;
    }

    const auto deadline = std::chrono::steady_clock::now() +
                          std::chrono::seconds(4);
    std::optional<std::string> last_error;
    while (std::chrono::steady_clock::now() < deadline) {
      auto error = OpenExistingAccessory();
      if (!error.has_value()) {
        UsbDebugLog("OpenExistingAccessory succeeded after negotiation");
        return std::nullopt;
      }
      last_error = error;
      std::this_thread::sleep_for(std::chrono::milliseconds(150));
    }

    return last_error.value_or(
        "Unable to open Android Open Accessory USB interface. Install/bind the "
        "WinUSB driver for the Android accessory interface, unlock the phone, "
        "and approve the AudioBridge accessory prompt.");
  }

  std::optional<std::string> OpenExistingAccessory() {
    UsbDebugLog("OpenExistingAccessory");
    const auto path = FindUsbDevicePath(
        [](const USB_DEVICE_DESCRIPTOR& descriptor) {
          return IsAoaAccessoryDevice(descriptor);
        },
        [](const std::wstring& path,
           const USB_DEVICE_DESCRIPTOR& descriptor) {
          return IsAoaAccessoryAudioInterfacePath(path, descriptor);
        });
    if (!path.has_value()) {
      UsbDebugLog("OpenExistingAccessory did not find AOA audio path");
      const auto any_accessory_path = FindUsbDevicePath(
          [](const USB_DEVICE_DESCRIPTOR& descriptor) {
            return IsAoaAccessoryDevice(descriptor);
          });
      if (any_accessory_path.has_value()) {
        return "Android accessory audio interface is not available through "
               "WinUSB. Bind the Android Accessory Interface (MI_00) to "
               "WinUSB, then retry Native USB.";
      }
      return kAoaAccessoryUnavailable;
    }

    UsbDebugLog("OpenExistingAccessory path " + Narrow(path.value()));
    return OpenUsbPath(path.value(), true);
  }

  std::optional<std::string> StartAccessoryMode() {
    const auto path = FindUsbDevicePath(
        [](const USB_DEVICE_DESCRIPTOR& descriptor) {
          return !IsAoaAccessoryDevice(descriptor);
        },
        [](const std::wstring& path,
           const USB_DEVICE_DESCRIPTOR& descriptor) {
          return IsAndroidAccessoryNegotiationPath(path, descriptor);
        });
    if (!path.has_value()) {
      if (usb_interface_access_denied_) {
        return "Android WinUSB interface is busy. Stop Android/Flutter debug "
               "or run `adb kill-server`, then retry Native USB.";
      }
      if (usb_interface_without_winusb_) {
        return "Android device is connected, but its current USB interface is "
               "MTP/WPD, not WinUSB. Enable USB debugging with the Android "
               "USB driver, or bind this Android interface to WinUSB, then "
               "retry Native USB.";
      }
      return "No WinUSB-compatible Android device was found for native USB.";
    }

    const auto open_error = OpenUsbPath(path.value(), false);
    if (open_error.has_value() && !open_error.value().empty()) {
      return open_error;
    }

    uint16_t protocol = 0;
    ULONG transferred = 0;
    WINUSB_SETUP_PACKET get_protocol = {};
    get_protocol.RequestType = 0xC0;
    get_protocol.Request = kAoaGetProtocol;
    get_protocol.Length = sizeof(protocol);
    if (!WinUsb_ControlTransfer(usb_winusb_, get_protocol,
                                reinterpret_cast<PUCHAR>(&protocol),
                                sizeof(protocol), &transferred, nullptr) ||
        transferred != sizeof(protocol) || protocol < 1) {
      CloseUsbTransport();
      return "The attached Android device did not accept accessory protocol negotiation.";
    }

    const auto send_string = [this](uint16_t index,
                                    const char* value,
                                    const char* label)
        -> std::optional<std::string> {
      const size_t length = std::strlen(value) + 1;
      std::vector<uint8_t> buffer(length);
      std::memcpy(buffer.data(), value, length);

      WINUSB_SETUP_PACKET packet = {};
      packet.RequestType = 0x40;
      packet.Request = kAoaSendString;
      packet.Index = index;
      packet.Length = static_cast<USHORT>(buffer.size());
      ULONG transferred = 0;
      if (WinUsb_ControlTransfer(usb_winusb_, packet, buffer.data(),
                                 packet.Length, &transferred, nullptr) ==
          FALSE) {
        return std::string("Unable to send Android accessory ") + label +
               " string. Windows error " + std::to_string(GetLastError()) +
               ".";
      }
      if (transferred != packet.Length) {
        return std::string("Unable to send complete Android accessory ") +
               label + " string. Sent " + std::to_string(transferred) +
               " of " + std::to_string(packet.Length) + " bytes.";
      }
      return std::nullopt;
    };

    const std::pair<uint16_t, std::pair<const char*, const char*>>
        identity_strings[] = {
            {kAoaStringManufacturer, {"manufacturer", kAoaManufacturer}},
            {kAoaStringModel, {"model", kAoaModel}},
            {kAoaStringDescription, {"description", kAoaDescription}},
            {kAoaStringVersion, {"version", kAoaVersion}},
            {kAoaStringUri, {"uri", kAoaUri}},
            {kAoaStringSerial, {"serial", kAoaSerial}},
        };
    for (const auto& entry : identity_strings) {
      if (auto error = send_string(entry.first, entry.second.second,
                                   entry.second.first)) {
        CloseUsbTransport();
        return error;
      }
    }

    WINUSB_SETUP_PACKET start = {};
    start.RequestType = 0x40;
    start.Request = kAoaStart;
    ULONG ignored = 0;
    if (!WinUsb_ControlTransfer(usb_winusb_, start, nullptr, 0, &ignored,
                                nullptr)) {
      CloseUsbTransport();
      return "Unable to switch Android device into accessory mode.";
    }

    CloseUsbTransport();
    return std::nullopt;
  }

  template <typename Predicate>
  std::optional<std::wstring> FindUsbDevicePath(Predicate predicate) {
    return FindUsbDevicePath(
        predicate,
        [](const std::wstring&, const USB_DEVICE_DESCRIPTOR&) {
          return true;
        });
  }

  template <typename Predicate, typename PathPredicate>
  std::optional<std::wstring> FindUsbDevicePath(Predicate predicate,
                                                PathPredicate path_predicate) {
    usb_interface_access_denied_ = false;
    usb_interface_without_winusb_ = false;
    std::vector<GUID> interface_guids = {
        kAndroidWinUsbInterfaceGuid,
        kWinUsbDeviceInterfaceGuid,
        GUID_DEVINTERFACE_USB_DEVICE,
    };
    for (const GUID& guid : DiscoverAoaAccessoryAudioInterfaceGuids()) {
      AppendUniqueGuid(&interface_guids, guid);
    }

    const DWORD interface_scans[] = {
        DIGCF_DEVICEINTERFACE | DIGCF_PRESENT,
        DIGCF_DEVICEINTERFACE,
    };

    for (const DWORD flags : interface_scans) {
      for (const GUID& interface_guid : interface_guids) {
        auto path = FindUsbDevicePathForInterface(interface_guid, predicate,
                                                 path_predicate, flags);
        if (path.has_value()) {
          return path;
        }
      }
    }

    return std::nullopt;
  }

  template <typename Predicate, typename PathPredicate>
  std::optional<std::wstring> FindUsbDevicePathForInterface(
      const GUID& interface_guid,
      Predicate predicate,
      PathPredicate path_predicate,
      DWORD flags) {
    HDEVINFO info = SetupDiGetClassDevs(&interface_guid, nullptr, nullptr,
                                        flags);
    if (info == INVALID_HANDLE_VALUE) {
      return std::nullopt;
    }

    std::optional<std::wstring> result;
    for (DWORD index = 0; !result.has_value(); ++index) {
      SP_DEVICE_INTERFACE_DATA interface_data = {};
      interface_data.cbSize = sizeof(interface_data);
      if (!SetupDiEnumDeviceInterfaces(info, nullptr, &interface_guid, index,
                                       &interface_data)) {
        break;
      }

      DWORD required_size = 0;
      SetupDiGetDeviceInterfaceDetail(info, &interface_data, nullptr, 0,
                                      &required_size, nullptr);
      if (required_size == 0) {
        continue;
      }

      std::vector<BYTE> detail_buffer(required_size);
      auto* detail =
          reinterpret_cast<SP_DEVICE_INTERFACE_DETAIL_DATA*>(detail_buffer.data());
      detail->cbSize = sizeof(SP_DEVICE_INTERFACE_DETAIL_DATA);
      if (!SetupDiGetDeviceInterfaceDetail(info, &interface_data, detail,
                                           required_size, nullptr, nullptr)) {
        continue;
      }

      const std::wstring path(detail->DevicePath);
      const auto path_descriptor = ReadUsbDeviceDescriptorFromPath(path);
      const bool path_matches =
          path_descriptor.has_value() && predicate(path_descriptor.value()) &&
          path_predicate(path, path_descriptor.value());
      if (path_matches) {
        UsbDebugLog("candidate USB path for " + GuidToString(interface_guid) +
                    " flags=" + std::to_string(flags) + " path=" +
                    Narrow(path));
      }
      HANDLE handle = CreateFileW(path.c_str(), GENERIC_WRITE | GENERIC_READ,
                                  FILE_SHARE_WRITE | FILE_SHARE_READ, nullptr,
                                  OPEN_EXISTING,
                                  FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OVERLAPPED,
                                  nullptr);
      if (handle == INVALID_HANDLE_VALUE) {
        const DWORD error = GetLastError();
        if (path_matches) {
          UsbDebugLog("CreateFileW failed for candidate: " +
                      std::to_string(error));
        }
        if (path_matches && error == ERROR_ACCESS_DENIED) {
          usb_interface_access_denied_ = true;
        }
        continue;
      }

      WINUSB_INTERFACE_HANDLE winusb = nullptr;
      if (!WinUsb_Initialize(handle, &winusb)) {
        const DWORD error = GetLastError();
        if (path_matches) {
          UsbDebugLog("WinUsb_Initialize failed for candidate: " +
                      std::to_string(error));
          usb_interface_without_winusb_ = true;
        }
        CloseHandle(handle);
        continue;
      }

      USB_DEVICE_DESCRIPTOR descriptor = {};
      ULONG transferred = 0;
      const BOOL read_descriptor = WinUsb_GetDescriptor(
          winusb, USB_DEVICE_DESCRIPTOR_TYPE, 0, 0,
          reinterpret_cast<PUCHAR>(&descriptor), sizeof(descriptor),
          &transferred);
      WinUsb_Free(winusb);
      CloseHandle(handle);

      std::optional<USB_DEVICE_DESCRIPTOR> device_descriptor;
      if (read_descriptor && transferred == sizeof(descriptor)) {
        device_descriptor = descriptor;
      } else if (path_descriptor.has_value()) {
        device_descriptor = path_descriptor.value();
      }

      if (device_descriptor.has_value() && predicate(device_descriptor.value()) &&
          path_predicate(path, device_descriptor.value())) {
        UsbDebugLog("selected USB path for " + GuidToString(interface_guid) +
                    ": " + Narrow(path));
        result = path;
      }
    }

    SetupDiDestroyDeviceInfoList(info);
    return result;
  }

  std::optional<std::string> OpenUsbPath(const std::wstring& path,
                                         bool require_bulk_endpoints) {
    UsbDebugLog("OpenUsbPath require_bulk=" +
                std::to_string(require_bulk_endpoints ? 1 : 0) + " path=" +
                Narrow(path));
    HANDLE handle = CreateFileW(path.c_str(), GENERIC_WRITE | GENERIC_READ,
                                FILE_SHARE_WRITE | FILE_SHARE_READ, nullptr,
                                OPEN_EXISTING,
                                FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OVERLAPPED,
                                nullptr);
    if (handle == INVALID_HANDLE_VALUE) {
      UsbDebugLog("OpenUsbPath CreateFileW failed: " +
                  std::to_string(GetLastError()));
      return "Unable to open Android USB interface. It may not be bound to WinUSB.";
    }

    WINUSB_INTERFACE_HANDLE winusb = nullptr;
    if (!WinUsb_Initialize(handle, &winusb)) {
      UsbDebugLog("OpenUsbPath WinUsb_Initialize failed: " +
                  std::to_string(GetLastError()));
      CloseHandle(handle);
      return "Unable to initialize WinUSB for the Android interface.";
    }

    UCHAR bulk_in = 0;
    UCHAR bulk_out = 0;
    if (require_bulk_endpoints &&
        !FindBulkEndpoints(winusb, &bulk_in, &bulk_out)) {
      UsbDebugLog("OpenUsbPath bulk endpoint discovery failed");
      WinUsb_Free(winusb);
      CloseHandle(handle);
      return "Android accessory interface does not expose bulk audio endpoints.";
    }

    usb_device_handle_ = handle;
    usb_winusb_ = winusb;
    usb_bulk_in_pipe_ = bulk_in;
    usb_bulk_out_pipe_ = bulk_out;
    usb_audio_packets_sent_ = 0;
    usb_audio_bytes_sent_ = 0;
    usb_subscribe_packets_received_ = 0;
    usb_read_failures_ = 0;
    usb_write_failures_ = 0;
    if (require_bulk_endpoints) {
      UsbDebugLog("OpenUsbPath bulk endpoints in=0x" +
                  std::to_string(static_cast<int>(usb_bulk_in_pipe_)) +
                  " out=0x" +
                  std::to_string(static_cast<int>(usb_bulk_out_pipe_)));
      ULONG input_timeout_ms = 20;
      ULONG output_timeout_ms = 500;
      WinUsb_SetPipePolicy(usb_winusb_, usb_bulk_in_pipe_, PIPE_TRANSFER_TIMEOUT,
                           sizeof(input_timeout_ms), &input_timeout_ms);
      WinUsb_SetPipePolicy(usb_winusb_, usb_bulk_out_pipe_, PIPE_TRANSFER_TIMEOUT,
                           sizeof(output_timeout_ms), &output_timeout_ms);
    }
    return std::nullopt;
  }

  bool FindBulkEndpoints(WINUSB_INTERFACE_HANDLE winusb, UCHAR* bulk_in,
                         UCHAR* bulk_out) {
    USB_INTERFACE_DESCRIPTOR descriptor = {};
    if (!WinUsb_QueryInterfaceSettings(winusb, 0, &descriptor)) {
      UsbDebugLog("WinUsb_QueryInterfaceSettings failed: " +
                  std::to_string(GetLastError()));
      return false;
    }

    UsbDebugLog("USB interface has " +
                std::to_string(static_cast<int>(descriptor.bNumEndpoints)) +
                " endpoints");
    for (UCHAR index = 0; index < descriptor.bNumEndpoints; ++index) {
      WINUSB_PIPE_INFORMATION pipe = {};
      if (!WinUsb_QueryPipe(winusb, 0, index, &pipe)) {
        UsbDebugLog("WinUsb_QueryPipe failed index=" +
                    std::to_string(static_cast<int>(index)) + " error=" +
                    std::to_string(GetLastError()));
        continue;
      }
      UsbDebugLog("USB pipe index=" + std::to_string(static_cast<int>(index)) +
                  " id=0x" +
                  std::to_string(static_cast<int>(pipe.PipeId)) +
                  " type=" + std::to_string(static_cast<int>(pipe.PipeType)) +
                  " maxPacket=" +
                  std::to_string(static_cast<int>(pipe.MaximumPacketSize)));
      if (pipe.PipeType != UsbdPipeTypeBulk) {
        continue;
      }
      if (USB_ENDPOINT_DIRECTION_IN(pipe.PipeId)) {
        *bulk_in = pipe.PipeId;
      } else {
        *bulk_out = pipe.PipeId;
      }
    }

    return *bulk_in != 0 && *bulk_out != 0;
  }

  void CloseUsbTransport() {
    if (usb_winusb_ != nullptr) {
      WinUsb_Free(usb_winusb_);
      usb_winusb_ = nullptr;
    }
    if (usb_device_handle_ != INVALID_HANDLE_VALUE) {
      CloseHandle(usb_device_handle_);
      usb_device_handle_ = INVALID_HANDLE_VALUE;
    }
    usb_bulk_in_pipe_ = 0;
    usb_bulk_out_pipe_ = 0;
  }

  void UsbControlLoop() {
    std::vector<uint8_t> header(kUsbFrameHeaderBytes);
    UsbDebugLog("UsbControlLoop started");
    while (usb_control_running_) {
      if (!ReadUsbExact(header.data(), header.size(), usb_control_running_)) {
        continue;
      }

      const uint32_t length = ReadU32Le(header.data());
      if (length == 0 || length > 4096) {
        continue;
      }

      std::vector<char> payload(length);
      if (!ReadUsbExact(reinterpret_cast<uint8_t*>(payload.data()),
                        payload.size(), usb_control_running_)) {
        continue;
      }

      if (length >= std::strlen(kSubscribePrefix) &&
          std::memcmp(payload.data(), kSubscribePrefix,
                      std::strlen(kSubscribePrefix)) == 0) {
        const uint64_t count = ++usb_subscribe_packets_received_;
        if (count <= 5 || count % 60 == 0) {
          UsbDebugLog("received USB subscribe #" + std::to_string(count) +
                      " payload=" + std::string(payload.data(),
                                                payload.size()));
        }
        UpdateRemoteMetrics(std::string(payload.data(), payload.size()));
        MaybeSendUsbHeartbeat(remote_session_id_.load());
      }
    }
    UsbDebugLog("UsbControlLoop stopped");
  }

  bool ReadUsbExact(uint8_t* data, size_t size,
                    const std::atomic_bool& running) {
    size_t offset = 0;
    while (running.load() && offset < size) {
      ULONG transferred = 0;
      if (!WinUsb_ReadPipe(usb_winusb_, usb_bulk_in_pipe_, data + offset,
                           static_cast<ULONG>(size - offset), &transferred,
                           nullptr)) {
        const DWORD error = GetLastError();
        if (error != ERROR_SEM_TIMEOUT) {
          const uint64_t count = ++usb_read_failures_;
          if (count <= 5 || count % 20 == 0) {
            UsbDebugLog("WinUsb_ReadPipe failed error=" +
                        std::to_string(error) + " count=" +
                        std::to_string(count));
          }
        }
        return false;
      }
      if (transferred == 0) {
        const uint64_t count = ++usb_read_failures_;
        if (count <= 5 || count % 20 == 0) {
          UsbDebugLog("WinUsb_ReadPipe transferred 0 count=" +
                      std::to_string(count));
        }
        return false;
      }
      offset += transferred;
    }
    return offset == size;
  }

  bool WriteUsbAll(const uint8_t* data, size_t size) {
    size_t offset = 0;
    while (offset < size) {
      ULONG transferred = 0;
      if (!WinUsb_WritePipe(usb_winusb_, usb_bulk_out_pipe_,
                            const_cast<PUCHAR>(data + offset),
                            static_cast<ULONG>(size - offset), &transferred,
                            nullptr)) {
        const DWORD error = GetLastError();
        const uint64_t count = ++usb_write_failures_;
        UsbDebugLog("WinUsb_WritePipe failed error=" + std::to_string(error) +
                    " size=" + std::to_string(size) +
                    " offset=" + std::to_string(offset) +
                    " count=" + std::to_string(count));
        return false;
      }
      if (transferred == 0) {
        const uint64_t count = ++usb_write_failures_;
        UsbDebugLog("WinUsb_WritePipe transferred 0 size=" +
                    std::to_string(size) + " offset=" +
                    std::to_string(offset) + " count=" +
                    std::to_string(count));
        return false;
      }
      offset += transferred;
    }
    return true;
  }

  bool WriteUsbFrame(const uint8_t* data, size_t size) {
    std::vector<uint8_t> header(kUsbFrameHeaderBytes);
    WriteU32(header, 0, static_cast<uint32_t>(size));

    // Audio and heartbeat frames are written by different threads. Keep each
    // length-prefixed frame contiguous on the shared USB bulk endpoint.
    std::scoped_lock lock(usb_write_mutex_);
    return WriteUsbAll(header.data(), header.size()) &&
           WriteUsbAll(data, size);
  }

  void MaybeSendUsbHeartbeat(uint64_t session_id) {
    if (session_id == 0 || usb_winusb_ == nullptr || usb_bulk_out_pipe_ == 0) {
      return;
    }

    const int64_t now = NowMillis();
    const int64_t last_sent = last_heartbeat_sent_at_ms_.load();
    if (now - last_sent < kHeartbeatIntervalMs) {
      return;
    }

    const std::vector<uint8_t> packet =
        BuildHeartbeatPacket(session_id, now);
    if (WriteUsbFrame(packet.data(), packet.size())) {
      last_heartbeat_sent_at_ms_ = now;
    }
  }

  void UpdateRemoteMetrics(const std::string& message) {
    const int64_t received_at = NowMillis();
    const auto protocol = ParseIntMetric(message, "protocol");
    const auto session_id = ParseIntMetric(message, "sessionId");
    remote_session_id_ =
        protocol.has_value() && protocol.value() >= 5 &&
                session_id.has_value() && session_id.value() > 0
            ? static_cast<uint64_t>(session_id.value())
            : 0;
    if (const auto receiver_time = ParseIntMetric(message, "receiverTimeMs")) {
      std::scoped_lock lock(remote_receiver_clock_mutex_);
      remote_receiver_clock_echo_ = {
          receiver_time.value(),
          received_at,
      };
    }

    bool has_metric = false;
    const auto platform = ParseStringMetric(message, "platform");
    const auto supported_codecs =
        ParseStringMetric(message, "supportedCodecs");
    if (platform.has_value() || supported_codecs.has_value()) {
      std::scoped_lock lock(remote_capabilities_mutex_);
      if (platform.has_value()) {
        remote_platform_ = platform.value();
      }
      if (supported_codecs.has_value()) {
        remote_supported_codecs_ = SplitMetricList(supported_codecs.value());
      }
      has_metric = true;
    }
    const auto latency = ParseDoubleMetric(message, "outputLatencyMs");
    if (latency.has_value()) {
      remote_output_latency_ms_ = latency.value();
      has_metric = true;
    }
    if (const auto audio_latency = ParseDoubleMetric(message, "audioLatencyMs")) {
      remote_audio_latency_ms_ = audio_latency.value();
      has_metric = true;
    }
    if (const auto network_latency =
            ParseDoubleMetric(message, "networkLatencyMs")) {
      remote_network_latency_ms_ = network_latency.value();
      has_metric = true;
    }

    if (const auto queued_frames = ParseIntMetric(message, "queuedFrames")) {
      remote_queued_frames_ = queued_frames.value();
      has_metric = true;
    }
    if (const auto buffer_size = ParseIntMetric(message, "bufferSizeFrames")) {
      remote_buffer_size_frames_ = buffer_size.value();
      has_metric = true;
    }
    if (const auto target_buffer =
            ParseIntMetric(message, "targetBufferFrames")) {
      remote_target_buffer_frames_ = target_buffer.value();
      has_metric = true;
    }
    if (const auto adaptive_buffer =
            ParseIntMetric(message, "adaptivePlaybackBufferMs")) {
      remote_adaptive_playback_buffer_ms_ = adaptive_buffer.value();
      has_metric = true;
    }
    if (const auto adaptive_max_buffer =
            ParseIntMetric(message, "adaptiveMaxPlaybackBufferMs")) {
      remote_adaptive_max_playback_buffer_ms_ = adaptive_max_buffer.value();
      has_metric = true;
    }
    if (const auto adaptive_limit =
            ParseIntMetric(message, "adaptiveLimitReached")) {
      remote_adaptive_limit_reached_ = adaptive_limit.value() > 0 ? 1 : 0;
      has_metric = true;
    }
    if (const auto adaptive_window =
            ParseIntMetric(message, "adaptiveUnderrunsInWindow")) {
      remote_adaptive_underruns_in_window_ = adaptive_window.value();
      has_metric = true;
    }
    if (const auto adaptive_burst =
            ParseIntMetric(message, "adaptiveUnderrunsInBurst")) {
      remote_adaptive_underruns_in_burst_ = adaptive_burst.value();
      has_metric = true;
    }
    if (const auto low_queue =
            ParseIntMetric(message, "adaptiveLowQueueSamples")) {
      remote_adaptive_low_queue_samples_ = low_queue.value();
      has_metric = true;
    }
    if (const auto queue_fill =
            ParseIntMetric(message, "playbackQueueFillPercent")) {
      remote_playback_queue_fill_percent_ = queue_fill.value();
      has_metric = true;
    }
    if (const auto underruns = ParseIntMetric(message, "underrunCount")) {
      remote_underrun_count_ = underruns.value();
      has_metric = true;
    }
    if (const auto drops = ParseIntMetric(message, "droppedPacketCount")) {
      remote_dropped_packet_count_ = drops.value();
      has_metric = true;
    }
    if (const auto lost = ParseIntMetric(message, "lostPacketCount")) {
      remote_lost_packet_count_ = lost.value();
      has_metric = true;
    }
    if (const auto trims = ParseIntMetric(message, "trimCount")) {
      remote_trim_count_ = trims.value();
      has_metric = true;
    }
    if (const auto signal = ParseDoubleMetric(message, "signalLevel")) {
      remote_signal_level_ = std::clamp(signal.value(), 0.0, 1.0);
      has_metric = true;
    }
    if (has_metric) {
      remote_metrics_received_at_ms_ = received_at;
    }
  }

  std::vector<int16_t> ReformatPcmForProfile(
      const std::vector<int16_t>& input, int input_sample_rate,
      int input_channels) {
    const int output_sample_rate = OutputSampleRateForProfile();
    const int output_channels = std::clamp(profile_.channels, 1, 2);
    const int source_channels = std::max(1, input_channels);
    const int input_frames = static_cast<int>(input.size()) / source_channels;
    if (input_frames <= 0 || input_sample_rate <= 0) {
      return {};
    }

    if (!resampler_initialized_ ||
        resampler_input_sample_rate_ != input_sample_rate ||
        resampler_input_channels_ != source_channels ||
        resampler_output_sample_rate_ != output_sample_rate ||
        resampler_output_channels_ != output_channels) {
      resampler_initialized_ = true;
      resampler_source_cursor_ = 0.0;
      resampler_input_frames_consumed_ = 0;
      resampler_input_sample_rate_ = input_sample_rate;
      resampler_input_channels_ = source_channels;
      resampler_output_sample_rate_ = output_sample_rate;
      resampler_output_channels_ = output_channels;
    }

    const double input_start =
        static_cast<double>(resampler_input_frames_consumed_);
    const double input_end = input_start + input_frames;
    const double source_step =
        static_cast<double>(input_sample_rate) / output_sample_rate;
    const int estimated_frames = std::max(
        1, static_cast<int>(std::ceil(input_frames / source_step)) + 1);
    std::vector<int16_t> output;
    output.reserve(estimated_frames * output_channels);

    while (resampler_source_cursor_ < input_end && capture_running_) {
      const double local_position = resampler_source_cursor_ - input_start;
      if (local_position < 0.0) {
        resampler_source_cursor_ += source_step;
        continue;
      }

      const int left_frame =
          std::clamp(static_cast<int>(std::floor(local_position)), 0,
                     input_frames - 1);
      const int right_frame = std::min(left_frame + 1, input_frames - 1);
      const float fraction =
          static_cast<float>(local_position - std::floor(local_position));

      for (int channel = 0; channel < output_channels; ++channel) {
        const float left =
            ReadRemixedSample(input, left_frame, source_channels,
                              output_channels, channel);
        const float right =
            ReadRemixedSample(input, right_frame, source_channels,
                              output_channels, channel);
        output.push_back(FloatToPcm16(left + (right - left) * fraction));
      }

      resampler_source_cursor_ += source_step;
    }

    resampler_input_frames_consumed_ += input_frames;
    return output;
  }

  bool MixSoundEffects(std::vector<int16_t>* pcm,
                       int sample_rate,
                       int channels) {
    if (pcm == nullptr || pcm->empty() || sample_rate <= 0 || channels <= 0) {
      return false;
    }

    std::scoped_lock lock(sound_effect_mutex_);
    if (sound_effect_queue_.empty()) {
      return false;
    }

    size_t mixed_samples = 0;
    const size_t output_samples = pcm->size();
    while (mixed_samples < output_samples && !sound_effect_queue_.empty()) {
      auto& clip = sound_effect_queue_.front();
      if (clip.sample_rate != sample_rate || clip.channels != channels ||
          clip.sample_offset >= clip.pcm.size()) {
        sound_effect_queue_.pop_front();
        continue;
      }

      const size_t available_samples = clip.pcm.size() - clip.sample_offset;
      const size_t samples_to_mix =
          std::min(output_samples - mixed_samples, available_samples);
      for (size_t index = 0; index < samples_to_mix; ++index) {
        const int mixed =
            static_cast<int>((*pcm)[mixed_samples + index]) +
            static_cast<int>(clip.pcm[clip.sample_offset + index]);
        (*pcm)[mixed_samples + index] = static_cast<int16_t>(
            std::clamp(mixed, -32768, 32767));
      }

      clip.sample_offset += samples_to_mix;
      mixed_samples += samples_to_mix;
      if (clip.sample_offset >= clip.pcm.size()) {
        sound_effect_queue_.pop_front();
      }
    }

    return mixed_samples > 0;
  }

  void CaptureLoop() {
    HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    const bool owns_com = SUCCEEDED(hr);
    if (FAILED(hr) && hr != RPC_E_CHANGED_MODE) {
      capture_running_ = false;
      return;
    }

    Microsoft::WRL::ComPtr<IMMDeviceEnumerator> enumerator;
    hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                          IID_PPV_ARGS(&enumerator));
    if (FAILED(hr)) {
      FinishCom(owns_com);
      capture_running_ = false;
      return;
    }

    Microsoft::WRL::ComPtr<IMMDevice> device;
    hr = enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device);
    if (FAILED(hr)) {
      FinishCom(owns_com);
      capture_running_ = false;
      return;
    }

    Microsoft::WRL::ComPtr<IAudioClient> audio_client;
    hr = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                          reinterpret_cast<void**>(audio_client.GetAddressOf()));
    if (FAILED(hr)) {
      FinishCom(owns_com);
      capture_running_ = false;
      return;
    }

    WAVEFORMATEX* raw_mix_format = nullptr;
    hr = audio_client->GetMixFormat(&raw_mix_format);
    if (FAILED(hr) || raw_mix_format == nullptr) {
      FinishCom(owns_com);
      capture_running_ = false;
      return;
    }

    const size_t mix_format_size = sizeof(WAVEFORMATEX) + raw_mix_format->cbSize;
    std::vector<BYTE> mix_format_storage(mix_format_size);
    std::memcpy(mix_format_storage.data(), raw_mix_format, mix_format_size);
    const auto* mix_format =
        reinterpret_cast<const WAVEFORMATEX*>(mix_format_storage.data());
    CoTaskMemFree(raw_mix_format);

    const int min_capture_buffer_ms =
        transport_mode_ == TransportMode::kUsb ? 5 : 10;
    const REFERENCE_TIME buffer_duration =
        10000000LL *
        std::max(min_capture_buffer_ms, profile_.capture_buffer_ms) / 1000;
    hr = audio_client->Initialize(
        AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_LOOPBACK, buffer_duration,
        0, mix_format, nullptr);
    if (FAILED(hr)) {
      FinishCom(owns_com);
      capture_running_ = false;
      return;
    }

    Microsoft::WRL::ComPtr<IAudioCaptureClient> capture_client;
    hr = audio_client->GetService(IID_PPV_ARGS(&capture_client));
    if (FAILED(hr)) {
      FinishCom(owns_com);
      capture_running_ = false;
      return;
    }

    DWORD task_index = 0;
    HANDLE task_handle = AvSetMmThreadCharacteristics(L"Pro Audio", &task_index);
    if (task_handle != nullptr) {
      AvSetMmThreadPriority(task_handle, AVRT_PRIORITY_CRITICAL);
    }
    audio_client->Start();

    while (capture_running_) {
      UINT32 packet_frames = 0;
      hr = capture_client->GetNextPacketSize(&packet_frames);
      if (FAILED(hr)) {
        break;
      }

      if (packet_frames == 0) {
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
        continue;
      }

      BYTE* data = nullptr;
      UINT32 frames_available = 0;
      DWORD flags = 0;
      hr = capture_client->GetBuffer(&data, &frames_available, &flags, nullptr,
                                     nullptr);
      if (FAILED(hr)) {
        break;
      }

      const bool silent = (flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0;
      const auto captured_pcm =
          ConvertToPcm16(data, frames_available, *mix_format, silent,
                         volume_.load(), muted_.load());
      const int output_sample_rate = OutputSampleRateForProfile();
      const int output_channels = std::clamp(profile_.channels, 1, 2);
      auto output_pcm = ReformatPcmForProfile(
          captured_pcm, mix_format->nSamplesPerSec, mix_format->nChannels);
      MixSoundEffects(&output_pcm, output_sample_rate, output_channels);
      SendPcm(output_pcm, output_sample_rate, output_channels);
      capture_client->ReleaseBuffer(frames_available);
    }

    audio_client->Stop();
    if (task_handle != nullptr) {
      AvRevertMmThreadCharacteristics(task_handle);
    }
    FinishCom(owns_com);
    capture_running_ = false;
  }

  void PlaybackReceiveLoop() {
    if (transport_mode_ == TransportMode::kUsb) {
      UsbPlaybackReceiveLoop();
      return;
    }

    std::vector<uint8_t> buffer(1500);
    int64_t last_subscribe_at = 0;

    while (playback_running_) {
      ReceiverSource source;
      {
        std::scoped_lock lock(receiver_source_mutex_);
        source = receiver_source_;
      }
      if (!source.available || socket_ == INVALID_SOCKET) {
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
        continue;
      }

      const int64_t now = NowMillis();
      if (now - last_subscribe_at > 300) {
        SendSubscribe(source.address);
        last_subscribe_at = now;
      }

      sockaddr_in remote = {};
      int remote_size = sizeof(remote);
      const int received =
          recvfrom(socket_, reinterpret_cast<char*>(buffer.data()),
                   static_cast<int>(buffer.size()), 0,
                   reinterpret_cast<sockaddr*>(&remote), &remote_size);
      if (received == SOCKET_ERROR) {
        continue;
      }
      HandlePlaybackPacket(buffer.data(), received);
    }
  }

  void UsbPlaybackReceiveLoop() {
    std::vector<uint8_t> header(kUsbFrameHeaderBytes);
    int64_t last_subscribe_at = 0;

    while (playback_running_) {
      if (usb_winusb_ == nullptr || usb_bulk_in_pipe_ == 0 ||
          usb_bulk_out_pipe_ == 0) {
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
        continue;
      }

      const int64_t now = NowMillis();
      if (now - last_subscribe_at > 300) {
        SendUsbSubscribe();
        last_subscribe_at = now;
      }

      if (!ReadUsbExact(header.data(), header.size(), playback_running_)) {
        continue;
      }

      const uint32_t length = ReadU32Le(header.data());
      if (length == 0 || length > 64 * 1024) {
        continue;
      }

      std::vector<uint8_t> payload(length);
      if (!ReadUsbExact(payload.data(), payload.size(), playback_running_)) {
        continue;
      }
      HandlePlaybackPacket(payload.data(), static_cast<int>(payload.size()));
    }
  }

  std::string BuildSubscribeMessage() const {
    std::string message = std::string(kSubscribePrefix) +
                          " protocol=5 sessionId=" +
                          std::to_string(receiver_session_id_.load()) +
                          " platform=windows supportedCodecs=" +
                          kReceiverSupportedCodecs +
                          " receiverTimeMs=" +
                          std::to_string(NowMillis());
    const double output_latency_ms = LocalOutputLatencyMs();
    if (output_latency_ms >= 0) {
      message += " outputLatencyMs=" + std::to_string(output_latency_ms);
    }
    message += " queuedFrames=" + std::to_string(playback_queue_frames_.load());
    message += " bufferSizeFrames=" +
               std::to_string(local_buffer_size_frames_.load());
    message += " targetBufferFrames=" +
               std::to_string(local_target_buffer_frames_.load());
    message += " adaptivePlaybackBufferMs=" +
               std::to_string(local_adaptive_playback_buffer_ms_.load());
    message += " adaptiveMaxPlaybackBufferMs=" +
               std::to_string(local_adaptive_max_playback_buffer_ms_.load());
    message += " adaptiveLimitReached=" +
               std::to_string(local_adaptive_limit_reached_.load() > 0 ? 1 : 0);
    message += " adaptiveUnderrunsInWindow=" +
               std::to_string(local_adaptive_underruns_in_window_.load());
    message += " adaptiveUnderrunsInBurst=" +
               std::to_string(local_adaptive_underruns_in_burst_.load());
    message += " adaptiveLowQueueSamples=" +
               std::to_string(local_adaptive_low_queue_samples_.load());
    const int64_t local_target_frames = local_target_buffer_frames_.load();
    const int64_t queue_fill_percent =
        local_target_frames > 0
            ? std::clamp<int64_t>(
                  playback_queue_frames_.load() * 100 / local_target_frames, 0,
                  200)
            : 0;
    message += " playbackQueueFillPercent=" +
               std::to_string(queue_fill_percent);
    message += " underrunCount=" + std::to_string(local_underrun_count_.load());
    message += " droppedPacketCount=" +
               std::to_string(local_dropped_packet_count_.load());
    message += " lostPacketCount=" +
               std::to_string(local_lost_packet_count_.load());
    message += " trimCount=0";
    message += " signalLevel=" + std::to_string(TakeSignalLevel());
    return message;
  }

  void SendSubscribe(const sockaddr_in& address) {
    const std::string message = BuildSubscribeMessage();
    sendto(socket_, message.data(), static_cast<int>(message.size()), 0,
           reinterpret_cast<const sockaddr*>(&address), sizeof(address));
  }

  void SendUsbSubscribe() {
    const std::string message = BuildSubscribeMessage();
    WriteUsbFrame(reinterpret_cast<const uint8_t*>(message.data()),
                  message.size());
  }

  void HandlePlaybackPacket(const uint8_t* data, int length) {
    if (length <= kPacketHeaderBytes) {
      return;
    }

    const uint32_t magic = ReadU32Le(data);
    if (session_protocol_active_.load() && magic != kPacketV5Magic) {
      return;
    }
    if (magic == kPacketMagic) {
      const uint32_t sequence = ReadU32Le(data + 4);
      const int sample_rate = static_cast<int>(ReadU32Le(data + 8));
      const int channels = static_cast<int>(ReadU16Le(data + 12));
      const uint16_t flags = ReadU16Le(data + 14);
      UpdateLocalPacketLoss(sequence);
      QueuePcmPayload(data + kPacketHeaderBytes, length - kPacketHeaderBytes,
                      sequence, sample_rate, channels, flags);
      return;
    }

    if (magic != kPacketV2Magic && magic != kPacketV3Magic &&
        magic != kPacketV4Magic && magic != kPacketV5Magic) {
      return;
    }
    const int header_bytes = magic == kPacketV2Magic ? kPacketV2HeaderBytes
                           : magic == kPacketV3Magic ? kPacketV3HeaderBytes
                           : magic == kPacketV4Magic ? kPacketV4HeaderBytes
                                                     : kPacketV5HeaderBytes;
    if (length < header_bytes) {
      return;
    }

    const uint32_t sequence = ReadU32Le(data + 4);
    const int sample_rate = static_cast<int>(ReadU32Le(data + 8));
    const int channels = static_cast<int>(ReadU16Le(data + 12));
    const uint16_t flags = ReadU16Le(data + 14);
    const uint16_t codec_id =
        magic == kPacketV2Magic ? kCodecPcm : ReadU16Le(data + 16);
    const uint16_t packet_kind =
        magic == kPacketV2Magic ? kPacketKindAudio : ReadU16Le(data + 18);

    if (magic == kPacketV5Magic) {
      const uint64_t session_id = ReadU64Le(data + 56);
      if (receiver_session_id_.load() == 0 ||
          session_id != receiver_session_id_.load()) {
        ++local_dropped_packet_count_;
        return;
      }
      session_protocol_active_ = true;
      local_last_peer_packet_received_at_ms_ = NowMillis();
      if (packet_kind == kPacketKindHeartbeat) {
        return;
      }
    }

    if (length <= header_bytes) {
      ++local_dropped_packet_count_;
      return;
    }

    if (packet_kind != kPacketKindAudio || codec_id != kCodecPcm) {
      ++local_dropped_packet_count_;
      return;
    }
    UpdateLocalPacketLoss(sequence);

    if (magic == kPacketV4Magic || magic == kPacketV5Magic) {
      const int playback_buffer_ms = static_cast<int>(
          std::clamp<uint32_t>(ReadU32Le(data + 48), kMinBufferMs,
                               kMaxBufferMs));
      const uint32_t receiver_options = ReadU32Le(data + 52);
      const bool receiver_adaptive_buffer =
          (receiver_options & kReceiverOptionAdaptiveBuffer) != 0;
      const AudioMode mode = ModeFromPacketId(
          (receiver_options & kReceiverOptionModeMask) >>
          kReceiverOptionModeShift);
      const int adaptive_buffer_cap_ms =
          static_cast<int>((receiver_options & kReceiverOptionCustomCapMask) >>
                           kReceiverOptionCustomCapShift);
      const int active_bitrate_kbps =
          static_cast<int>((receiver_options & kReceiverOptionBitrateMask) >>
                           kReceiverOptionBitrateShift);
      const bool adaptive_policy_changed =
          profile_.receiver_adaptive_buffer != receiver_adaptive_buffer ||
          profile_.mode != mode ||
          profile_.adaptive_buffer_cap_ms != adaptive_buffer_cap_ms;
      const bool playback_target_changed =
          profile_.playback_buffer_ms != playback_buffer_ms;
      if (active_bitrate_kbps > 0) {
        profile_.bitrate_kbps = active_bitrate_kbps;
      }
      const int previous_adaptive_buffer_ms =
          static_cast<int>(local_adaptive_playback_buffer_ms_.load());
      profile_.playback_buffer_ms = playback_buffer_ms;
      profile_.receiver_adaptive_buffer = receiver_adaptive_buffer;
      profile_.mode = mode;
      profile_.adaptive_buffer_cap_ms = adaptive_buffer_cap_ms;
      if (adaptive_policy_changed || playback_target_changed) {
        if (adaptive_policy_changed) {
          ResetLocalAdaptiveDelayTracker();
        }
        const int next_max_buffer_ms =
            AdaptiveMaxPlaybackBufferMs(playback_buffer_ms);
        const int next_buffer_ms =
            !receiver_adaptive_buffer
                ? playback_buffer_ms
                : adaptive_policy_changed &&
                          ShouldStartAdaptiveBufferAtRequested(
                              playback_buffer_ms)
                      ? playback_buffer_ms
                : playback_buffer_ms > previous_adaptive_buffer_ms
                      ? playback_buffer_ms
                      : previous_adaptive_buffer_ms > next_max_buffer_ms
                            ? next_max_buffer_ms
                            : previous_adaptive_buffer_ms;
        SetLocalAdaptivePlaybackBufferMs(sample_rate, next_buffer_ms);
      }
    }

    QueuePcmPayload(data + header_bytes, length - header_bytes, sequence,
                    sample_rate, channels, flags);
  }

  void QueuePcmPayload(const uint8_t* payload, int payload_size,
                       uint32_t sequence, int sample_rate, int channels,
                       uint16_t flags) {
    if (sample_rate <= 0 || channels <= 0 || payload_size <= 0) {
      ++local_dropped_packet_count_;
      return;
    }

    const int bytes_per_frame = channels * static_cast<int>(sizeof(int16_t));
    const int frames = payload_size / bytes_per_frame;
    if (frames <= 0) {
      ++local_dropped_packet_count_;
      return;
    }

    local_input_sample_rate_ = sample_rate;
    local_input_channels_ = channels;
    local_codec_id_ = kCodecPcm;
    const int64_t received_at = NowMillis();
    local_last_audio_packet_received_at_ms_ = received_at;
    local_last_peer_packet_received_at_ms_ = received_at;

    PcmPlaybackPacket packet;
    packet.sample_rate = sample_rate;
    packet.channels = channels;
    packet.flags = flags;
    packet.pcm.resize(static_cast<size_t>(frames) * channels);
    std::memcpy(packet.pcm.data(), payload,
                packet.pcm.size() * sizeof(int16_t));
    if ((flags & kPacketFlagMuted) != 0 || muted_.load()) {
      std::fill(packet.pcm.begin(), packet.pcm.end(), int16_t{0});
    }
    const double peak_level = PcmPeakLevel(packet.pcm);
    PublishSignalLevel(peak_level);
    local_last_playback_signal_level_ = peak_level;

    ObserveLocalAdaptivePacketArrival(NowMillis(), sequence, sample_rate,
                                      frames);

    {
      std::scoped_lock lock(playback_queue_mutex_);
      playback_queue_frames_ += frames;
      AdaptLocalPlaybackBuffer(sample_rate, playback_queue_frames_.load());
      const int target_frames = LocalAdaptiveTargetFrames(sample_rate);
      const int hard_limit =
          std::max(target_frames * 3,
                   target_frames + sample_rate * 50 / 1000);
      while (!playback_queue_.empty() &&
             playback_queue_frames_.load() > hard_limit) {
        playback_queue_frames_ -=
            static_cast<int64_t>(playback_queue_.front().pcm.size()) /
            std::max(1, playback_queue_.front().channels);
        playback_queue_.pop_front();
        ++local_dropped_packet_count_;
      }
      playback_queue_.push_back(std::move(packet));
    }
    playback_queue_cv_.notify_one();
  }

  void ResetLocalAdaptivePlayback(int sample_rate) {
    const int requested_ms = RequestedPlaybackBufferMs();
    const int adaptive_max_ms = AdaptiveMaxPlaybackBufferMs(requested_ms);
    local_adaptive_playback_buffer_ms_ = requested_ms;
    local_adaptive_max_playback_buffer_ms_ = adaptive_max_ms;
    local_adaptive_limit_reached_ = 0;
    local_adaptive_underruns_in_window_ = 0;
    local_adaptive_underruns_in_burst_ = 0;
    local_adaptive_low_queue_samples_ = 0;
    local_render_started_ = false;
    local_render_started_at_ms_ = 0;
    local_target_buffer_frames_ = LatencyFrames(sample_rate, requested_ms);
    local_last_adaptive_buffer_increase_at_ms_ = 0;
    local_last_playback_pressure_at_ms_ = 0;
    local_last_known_underrun_count_ = local_underrun_count_.load();
    local_adaptive_underrun_window_start_at_ms_ = 0;
    local_adaptive_underruns_in_window_counter_ = 0;
    local_adaptive_underrun_burst_start_at_ms_ = 0;
    local_adaptive_underruns_in_burst_counter_ = 0;
    local_adaptive_low_queue_sample_count_ = 0;
    ResetLocalAdaptiveDelayTracker();
  }

  void ResetLocalAdaptiveDelayTracker() {
    local_adaptive_last_arrival_sequence_ = -1;
    local_adaptive_last_arrival_at_ms_ = 0;
    local_adaptive_last_packet_duration_ms_ = 0.0;
    local_adaptive_relative_delay_ms_ = 0.0;
    local_adaptive_delay_window_start_at_ms_ = 0;
    local_adaptive_delay_window_peak_ms_ = 0.0;
    local_adaptive_delay_history_ms_.fill(0);
    local_adaptive_delay_history_index_ = 0;
    local_adaptive_delay_history_count_ = 0;
    local_adaptive_network_target_buffer_ms_ = 0;
  }

  int RequestedPlaybackBufferMs() const {
    return std::clamp(profile_.playback_buffer_ms, kMinBufferMs, kMaxBufferMs);
  }

  int AdaptiveMaxPlaybackBufferMs(int requested_ms) const {
    int cap_ms = kMaxBufferMs;
    switch (profile_.mode) {
      case AudioMode::kGaming:
        cap_ms = kAdaptiveGamingCapMs;
        break;
      case AudioMode::kBalanced:
        cap_ms = kAdaptiveBalancedCapMs;
        break;
      case AudioMode::kMusic:
        cap_ms = kMaxBufferMs;
        break;
      case AudioMode::kCustom:
        cap_ms = profile_.adaptive_buffer_cap_ms > 0
                     ? profile_.adaptive_buffer_cap_ms
                     : kMaxBufferMs;
        break;
    }
    return std::clamp(cap_ms, requested_ms, kMaxBufferMs);
  }

  bool ShouldStartAdaptiveBufferAtRequested(int requested_ms) const {
    return profile_.mode == AudioMode::kGaming ||
           requested_ms <= kLowLatencyPerformanceMaxMs;
  }

  int AdaptiveBufferStepMs(int requested_ms) const {
    const int packet_step_ms = std::clamp(profile_.packet_time_ms, 1, 12) * 2;
    const int profile_step_ms =
        requested_ms <= 28
            ? kAdaptiveLowLatencyStepMs
            : (requested_ms <= kLowLatencyPerformanceMaxMs
                   ? kAdaptiveBalancedStepMs
                   : kAdaptiveStableStepMs);
    return std::min(std::max(packet_step_ms, profile_step_ms),
                    kAdaptiveStableStepMs);
  }

  int LatencyFrames(int sample_rate, int latency_ms) const {
    return std::max(1, sample_rate *
                           std::clamp(latency_ms, kMinBufferMs, kMaxBufferMs) /
                           1000);
  }

  int LocalAdaptiveTargetFrames(int sample_rate) const {
    const int adaptive_ms =
        static_cast<int>(local_adaptive_playback_buffer_ms_.load());
    return LatencyFrames(sample_rate, adaptive_ms);
  }

  void SetLocalAdaptivePlaybackBufferMs(int sample_rate, int next_buffer_ms) {
    const int requested_ms = RequestedPlaybackBufferMs();
    const int adaptive_max_ms = AdaptiveMaxPlaybackBufferMs(requested_ms);
    const int next_ms =
        std::clamp(next_buffer_ms, requested_ms, adaptive_max_ms);
    local_adaptive_playback_buffer_ms_ = next_ms;
    local_adaptive_max_playback_buffer_ms_ = adaptive_max_ms;
    local_adaptive_limit_reached_ = next_ms >= adaptive_max_ms ? 1 : 0;
    local_target_buffer_frames_ = LatencyFrames(sample_rate, next_ms);
  }

  void ObserveLocalAdaptivePacketArrival(int64_t now, uint32_t sequence,
                                         int sample_rate, int packet_frames) {
    if (!profile_.receiver_adaptive_buffer || sample_rate <= 0 ||
        packet_frames <= 0) {
      return;
    }

    const double packet_duration_ms =
        static_cast<double>(packet_frames) * 1000.0 / sample_rate;
    if (local_adaptive_last_arrival_at_ms_ <= 0 ||
        local_adaptive_last_arrival_sequence_ < 0 ||
        now - local_adaptive_last_arrival_at_ms_ > kSourceIdleTimeoutMs) {
      SeedLocalAdaptiveDelayTracker(now, sequence, packet_duration_ms);
      return;
    }

    const int64_t sequence_delta =
        PacketSequenceDelta(sequence, local_adaptive_last_arrival_sequence_);
    if (sequence_delta <= 0) {
      return;
    }
    if (sequence_delta > kAdaptiveSequenceResetGap) {
      SeedLocalAdaptiveDelayTracker(now, sequence, packet_duration_ms);
      return;
    }

    const double elapsed_ms =
        static_cast<double>(std::max<int64_t>(
            0, now - local_adaptive_last_arrival_at_ms_));
    const double expected_ms =
        local_adaptive_last_packet_duration_ms_ * sequence_delta;
    local_adaptive_relative_delay_ms_ =
        PacketArrivalDelaySampleMs(elapsed_ms, expected_ms);
    if (local_adaptive_delay_window_start_at_ms_ <= 0) {
      local_adaptive_delay_window_start_at_ms_ =
          local_adaptive_last_arrival_at_ms_;
    }
    local_adaptive_delay_window_peak_ms_ =
        std::max(local_adaptive_delay_window_peak_ms_,
                 local_adaptive_relative_delay_ms_);

    while (now - local_adaptive_delay_window_start_at_ms_ >=
           kAdaptiveDelaySampleIntervalMs) {
      RecordLocalAdaptiveDelaySample(
          static_cast<int>(std::ceil(local_adaptive_delay_window_peak_ms_)));
      local_adaptive_delay_window_start_at_ms_ +=
          kAdaptiveDelaySampleIntervalMs;
      local_adaptive_delay_window_peak_ms_ =
          local_adaptive_relative_delay_ms_;
    }

    local_adaptive_last_arrival_sequence_ = sequence;
    local_adaptive_last_arrival_at_ms_ = now;
    local_adaptive_last_packet_duration_ms_ = packet_duration_ms;
  }

  void SeedLocalAdaptiveDelayTracker(int64_t now, uint32_t sequence,
                                     double packet_duration_ms) {
    local_adaptive_last_arrival_sequence_ = sequence;
    local_adaptive_last_arrival_at_ms_ = now;
    local_adaptive_last_packet_duration_ms_ = packet_duration_ms;
    local_adaptive_relative_delay_ms_ = 0.0;
    local_adaptive_delay_window_start_at_ms_ = now;
    local_adaptive_delay_window_peak_ms_ = 0.0;
  }

  void RecordLocalAdaptiveDelaySample(int delay_ms) {
    local_adaptive_delay_history_ms_[local_adaptive_delay_history_index_] =
        std::clamp(delay_ms, 0, static_cast<int>(kAdaptiveDelayMaxMs));
    local_adaptive_delay_history_index_ =
        (local_adaptive_delay_history_index_ + 1) %
        kAdaptiveDelayHistorySamples;
    local_adaptive_delay_history_count_ =
        std::min(kAdaptiveDelayHistorySamples,
                 local_adaptive_delay_history_count_ + 1);
  }

  int LocalAdaptiveDelayQuantileMs() const {
    if (local_adaptive_delay_history_count_ == 0) {
      return 0;
    }
    std::vector<int> samples(local_adaptive_delay_history_ms_.begin(),
                             local_adaptive_delay_history_ms_.begin() +
                                 local_adaptive_delay_history_count_);
    std::sort(samples.begin(), samples.end());
    const size_t quantile_index = std::clamp<size_t>(
        static_cast<size_t>(
            std::ceil(local_adaptive_delay_history_count_ *
                      kAdaptiveDelayQuantile)),
        static_cast<size_t>(1), local_adaptive_delay_history_count_) -
                                  1;
    return samples[quantile_index];
  }

  int LocalAdaptiveNetworkFloorBufferMs(int requested_ms) {
    const int estimated_delay_ms = LocalAdaptiveDelayQuantileMs();
    if (estimated_delay_ms <= 0 ||
        local_adaptive_delay_history_count_ <
            kAdaptiveDelayMinHistorySamples) {
      local_adaptive_network_target_buffer_ms_ = requested_ms;
      return requested_ms;
    }

    const int packet_guard_ms =
        std::max(std::clamp(profile_.packet_time_ms, 1, 12),
                 std::max(1, static_cast<int>(std::ceil(
                                 local_adaptive_last_packet_duration_ms_))));
    if (estimated_delay_ms <= packet_guard_ms) {
      local_adaptive_network_target_buffer_ms_ = requested_ms;
      return requested_ms;
    }
    const int jitter_beyond_guard_ms = estimated_delay_ms - packet_guard_ms;
    const int jitter_headroom_ms = static_cast<int>(std::ceil(
        static_cast<double>(jitter_beyond_guard_ms) *
        kAdaptiveDelayHeadroomNumerator /
        kAdaptiveDelayHeadroomDenominator));
    local_adaptive_network_target_buffer_ms_ =
        std::clamp(requested_ms + packet_guard_ms + jitter_headroom_ms,
                   requested_ms, AdaptiveMaxPlaybackBufferMs(requested_ms));
    return local_adaptive_network_target_buffer_ms_;
  }

  int64_t PacketSequenceDelta(uint32_t sequence, int64_t previous_sequence) {
    const int64_t current = static_cast<int64_t>(sequence);
    const int64_t raw_delta =
        current >= previous_sequence ? current - previous_sequence
                                     : current + kSequenceModulus -
                                           previous_sequence;
    return raw_delta > kSequenceModulus / 2 ? 0 : raw_delta;
  }

  bool ExceedsLocalAdaptiveUnderrunBudget(int64_t now, int64_t underrun_delta) {
    if (local_adaptive_underrun_window_start_at_ms_ <= 0 ||
        now - local_adaptive_underrun_window_start_at_ms_ >
            kAdaptiveUnderrunSlowWindowMs) {
      local_adaptive_underrun_window_start_at_ms_ = now;
      local_adaptive_underruns_in_window_counter_ = 0;
    }
    if (local_adaptive_underrun_burst_start_at_ms_ <= 0 ||
        now - local_adaptive_underrun_burst_start_at_ms_ >
            kAdaptiveUnderrunBurstWindowMs) {
      local_adaptive_underrun_burst_start_at_ms_ = now;
      local_adaptive_underruns_in_burst_counter_ = 0;
    }

    local_adaptive_underruns_in_window_counter_ += underrun_delta;
    local_adaptive_underruns_in_burst_counter_ += underrun_delta;
    local_adaptive_underruns_in_window_ =
        local_adaptive_underruns_in_window_counter_;
    local_adaptive_underruns_in_burst_ =
        local_adaptive_underruns_in_burst_counter_;
    return local_adaptive_underruns_in_burst_counter_ >
               kAdaptiveAcceptableUnderrunsPerBurst ||
           local_adaptive_underruns_in_window_counter_ >
               kAdaptiveAcceptableUnderrunsPerSlowWindow;
  }

  bool IsLocalPlaybackQueueTooLow(int sample_rate, int64_t queued_frames,
                                  int64_t target_frames) const {
    const int64_t packet_frames =
        std::max<int64_t>(1, sample_rate *
                                 std::clamp(profile_.packet_time_ms, 1, 12) /
                                 1000);
    const int64_t low_queue_frames =
        std::max(packet_frames, target_frames / kAdaptiveLowQueueDivisor);
    return queued_frames < low_queue_frames;
  }

  int64_t HealthyLocalPlaybackQueueFrames(int sample_rate,
                                          int64_t target_frames) const {
    const int64_t requested_frames =
        LatencyFrames(sample_rate, RequestedPlaybackBufferMs());
    return std::max(requested_frames, target_frames * 3 / 4);
  }

  void AdaptLocalPlaybackBuffer(int sample_rate, int64_t queued_frames) {
    if (sample_rate <= 0) {
      return;
    }

    const int requested_ms = RequestedPlaybackBufferMs();
    if (!profile_.receiver_adaptive_buffer) {
      ResetLocalAdaptiveGrowthPressure(local_underrun_count_.load(),
                                       true);
      SetLocalAdaptivePlaybackBufferMs(sample_rate, requested_ms);
      return;
    }

    const int64_t now = NowMillis();
    const int64_t underruns = local_underrun_count_.load();
    if (!HasLocalAdaptivePlaybackSignal()) {
      ResetLocalAdaptiveGrowthPressure(underruns);
      local_last_playback_pressure_at_ms_ = now;
      return;
    }

    const int64_t target_frames = LocalAdaptiveTargetFrames(sample_rate);
    const int network_floor_ms =
        LocalAdaptiveNetworkFloorBufferMs(requested_ms);
    const int64_t render_started_at = local_render_started_at_ms_.load();
    const bool render_stable =
        local_render_started_.load() && render_started_at > 0 &&
        now - render_started_at >= kAdaptivePlaybackStartGraceMs;
    const int64_t underrun_delta =
        render_stable
            ? std::max<int64_t>(0,
                                underruns - local_last_known_underrun_count_)
            : 0;
    if (!render_stable) {
      local_last_known_underrun_count_ = underruns;
    }
    bool should_increase = false;
    bool pressure_increase = false;
    if (underrun_delta > 0) {
      local_last_playback_pressure_at_ms_ = now;
      should_increase =
          ExceedsLocalAdaptiveUnderrunBudget(now, underrun_delta);
      pressure_increase = should_increase;
    }

    if (render_stable &&
        IsLocalPlaybackQueueTooLow(sample_rate, queued_frames, target_frames)) {
      ++local_adaptive_low_queue_sample_count_;
      local_adaptive_low_queue_samples_ =
          local_adaptive_low_queue_sample_count_;
      if (ShouldGrowAdaptiveBufferForLowQueue(
              local_adaptive_low_queue_sample_count_)) {
        local_last_playback_pressure_at_ms_ = now;
        should_increase = true;
        pressure_increase = true;
      }
    } else {
      local_adaptive_low_queue_sample_count_ = 0;
      local_adaptive_low_queue_samples_ = 0;
    }

    const int current_ms =
        static_cast<int>(local_adaptive_playback_buffer_ms_.load());
    const bool network_floor_increase =
        network_floor_ms > current_ms + kAdaptiveNetworkTargetHysteresisMs;
    if (network_floor_increase) {
      should_increase = true;
    }

    if (should_increase &&
        now - local_last_adaptive_buffer_increase_at_ms_ >=
            kAdaptiveBufferCooldownMs) {
      SetLocalAdaptivePlaybackBufferMs(
          sample_rate,
          AdaptiveBufferIncreaseTargetMs(
              current_ms, AdaptiveBufferStepMs(requested_ms), network_floor_ms,
              pressure_increase, network_floor_increase));
      local_last_adaptive_buffer_increase_at_ms_ = now;
      local_adaptive_low_queue_sample_count_ = 0;
      local_adaptive_low_queue_samples_ = 0;
    } else if (ShouldRelaxLocalAdaptiveBuffer(
                   now, current_ms, network_floor_ms, queued_frames,
                   target_frames, sample_rate)) {
      SetLocalAdaptivePlaybackBufferMs(
          sample_rate,
          std::max(network_floor_ms,
                   current_ms - AdaptiveBufferStepMs(requested_ms)));
    }

    local_last_known_underrun_count_ = underruns;
  }

  void ResetLocalAdaptiveGrowthPressure(int64_t underruns,
                                        bool reset_delay_tracker = false) {
    local_last_known_underrun_count_ = underruns;
    local_adaptive_underrun_window_start_at_ms_ = 0;
    local_adaptive_underruns_in_window_counter_ = 0;
    local_adaptive_underruns_in_window_ = 0;
    local_adaptive_underrun_burst_start_at_ms_ = 0;
    local_adaptive_underruns_in_burst_counter_ = 0;
    local_adaptive_underruns_in_burst_ = 0;
    local_adaptive_low_queue_sample_count_ = 0;
    local_adaptive_low_queue_samples_ = 0;
    if (reset_delay_tracker) {
      ResetLocalAdaptiveDelayTracker();
    }
  }

  bool HasLocalAdaptivePlaybackSignal() const {
    return !muted_.load() &&
           local_last_playback_signal_level_.load() >=
               kAdaptiveAudibleSignalFloor;
  }

  bool ShouldRelaxLocalAdaptiveBuffer(int64_t now, int current_ms,
                                      int network_floor_ms,
                                      int64_t queued_frames,
                                      int64_t target_frames,
                                      int sample_rate) const {
    if (current_ms <=
        network_floor_ms + kAdaptiveNetworkTargetHysteresisMs) {
      return false;
    }
    if (queued_frames <
        HealthyLocalPlaybackQueueFrames(sample_rate, target_frames)) {
      return false;
    }

    const bool queue_at_or_above_target = queued_frames >= target_frames;
    const bool has_room_to_fast_relax =
        current_ms - network_floor_ms >= kAdaptiveFastRelaxMarginMs;
    const int relax_delay_ms =
        queue_at_or_above_target && has_room_to_fast_relax
            ? kAdaptiveBufferFastRelaxMs
            : kAdaptiveBufferRelaxMs;
    return now - local_last_playback_pressure_at_ms_ >= relax_delay_ms;
  }

  void UpdateLocalPacketLoss(uint32_t sequence) {
    const int64_t previous = local_last_sequence_.load();
    if (previous >= 0 && sequence > previous + 1) {
      local_lost_packet_count_ += sequence - static_cast<uint32_t>(previous) - 1;
    }
    local_last_sequence_ = sequence;
  }

  double LocalOutputLatencyMs() const {
    const int sample_rate = local_output_sample_rate_.load();
    if (sample_rate <= 0) {
      return -1.0;
    }
    return playback_queue_frames_.load() * 1000.0 / sample_rate;
  }

  void PlaybackRenderLoop() {
    HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    const bool owns_com = SUCCEEDED(hr);
    if (FAILED(hr) && hr != RPC_E_CHANGED_MODE) {
      playback_running_ = false;
      return;
    }

    Microsoft::WRL::ComPtr<IMMDeviceEnumerator> enumerator;
    hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                          IID_PPV_ARGS(&enumerator));
    if (FAILED(hr)) {
      FinishCom(owns_com);
      playback_running_ = false;
      return;
    }

    Microsoft::WRL::ComPtr<IMMDevice> device;
    hr = enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device);
    if (FAILED(hr)) {
      FinishCom(owns_com);
      playback_running_ = false;
      return;
    }

    Microsoft::WRL::ComPtr<IAudioClient> audio_client;
    hr = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                          reinterpret_cast<void**>(audio_client.GetAddressOf()));
    if (FAILED(hr)) {
      FinishCom(owns_com);
      playback_running_ = false;
      return;
    }

    WAVEFORMATEX* raw_mix_format = nullptr;
    hr = audio_client->GetMixFormat(&raw_mix_format);
    if (FAILED(hr) || raw_mix_format == nullptr) {
      FinishCom(owns_com);
      playback_running_ = false;
      return;
    }

    const size_t mix_format_size = sizeof(WAVEFORMATEX) + raw_mix_format->cbSize;
    std::vector<BYTE> mix_format_storage(mix_format_size);
    std::memcpy(mix_format_storage.data(), raw_mix_format, mix_format_size);
    const auto* mix_format =
        reinterpret_cast<const WAVEFORMATEX*>(mix_format_storage.data());
    CoTaskMemFree(raw_mix_format);

    const REFERENCE_TIME buffer_duration =
        10000000LL *
        std::clamp(profile_.playback_buffer_ms, kMinBufferMs, kMaxBufferMs) /
        1000;
    hr = audio_client->Initialize(AUDCLNT_SHAREMODE_SHARED, 0,
                                  buffer_duration, 0, mix_format, nullptr);
    if (FAILED(hr)) {
      FinishCom(owns_com);
      playback_running_ = false;
      return;
    }

    UINT32 buffer_frames = 0;
    audio_client->GetBufferSize(&buffer_frames);
    local_buffer_size_frames_ = buffer_frames;
    local_output_sample_rate_ = mix_format->nSamplesPerSec;
    SetLocalAdaptivePlaybackBufferMs(
        mix_format->nSamplesPerSec,
        static_cast<int>(local_adaptive_playback_buffer_ms_.load()));

    Microsoft::WRL::ComPtr<IAudioRenderClient> render_client;
    hr = audio_client->GetService(IID_PPV_ARGS(&render_client));
    if (FAILED(hr)) {
      FinishCom(owns_com);
      playback_running_ = false;
      return;
    }

    DWORD task_index = 0;
    HANDLE task_handle = AvSetMmThreadCharacteristics(L"Pro Audio", &task_index);
    if (task_handle != nullptr) {
      AvSetMmThreadPriority(task_handle, AVRT_PRIORITY_CRITICAL);
    }

    bool render_started = false;
    bool needs_prebuffer = true;
    while (playback_running_) {
      PcmPlaybackPacket packet;
      int64_t queued_frames_before_render = 0;
      {
        std::unique_lock lock(playback_queue_mutex_);
        playback_queue_cv_.wait_for(lock, std::chrono::milliseconds(20), [this, needs_prebuffer] {
          if (!playback_running_) {
            return true;
          }
          if (needs_prebuffer) {
            return playback_queue_frames_.load() >=
                   local_target_buffer_frames_.load();
          }
          return !playback_queue_.empty();
        });
        if (!playback_running_) {
          break;
        }
        if (needs_prebuffer &&
            playback_queue_frames_.load() < local_target_buffer_frames_.load()) {
          continue;
        }
        needs_prebuffer = false;
        if (playback_queue_.empty()) {
          ++local_underrun_count_;
          needs_prebuffer = true;
          continue;
        }
        packet = std::move(playback_queue_.front());
        playback_queue_.pop_front();
        queued_frames_before_render = playback_queue_frames_.load();
      }

      const int packet_frames = static_cast<int>(packet.pcm.size()) /
                                std::max(1, packet.channels);
      const int catch_up_frames = PlaybackCatchUpFrameCount(
          packet_frames, queued_frames_before_render,
          LocalAdaptiveTargetFrames(packet.sample_rate), packet.sample_rate);
      std::vector<int16_t> catch_up_pcm;
      const std::vector<int16_t>* playback_pcm = &packet.pcm;
      if (catch_up_frames < packet_frames) {
        catch_up_pcm = ReformatPcm(packet.pcm, packet_frames, packet.channels,
                                   catch_up_frames, packet.channels);
        playback_pcm = &catch_up_pcm;
      }

      const auto output = ReformatPcm(*playback_pcm, packet.sample_rate,
                                      packet.channels,
                                      mix_format->nSamplesPerSec,
                                      mix_format->nChannels);
      if (!render_started) {
        audio_client->Start();
        render_started = true;
        local_render_started_ = true;
        local_render_started_at_ms_ = NowMillis();
        local_last_known_underrun_count_ = local_underrun_count_.load();
      }
      WriteRenderPcm(render_client.Get(), audio_client.Get(), buffer_frames,
                     *mix_format, output, playback_running_);
      playback_queue_frames_ -=
          static_cast<int64_t>(packet.pcm.size()) / std::max(1, packet.channels);
    }

    if (render_started) {
      audio_client->Stop();
    }
    local_render_started_ = false;
    local_render_started_at_ms_ = 0;
    if (task_handle != nullptr) {
      AvRevertMmThreadCharacteristics(task_handle);
    }
    FinishCom(owns_com);
    playback_running_ = false;
  }

  void WriteRenderPcm(IAudioRenderClient* render_client,
                      IAudioClient* audio_client,
                      UINT32 buffer_frames,
                      const WAVEFORMATEX& format,
                      const std::vector<int16_t>& pcm,
                      const std::atomic_bool& running,
                      bool apply_output_volume = true) {
    const int channels = std::max<int>(1, format.nChannels);
    size_t offset_frames = 0;
    const size_t total_frames = pcm.size() / channels;
    while (running && offset_frames < total_frames) {
      UINT32 padding = 0;
      if (FAILED(audio_client->GetCurrentPadding(&padding))) {
        return;
      }
      const UINT32 available = buffer_frames > padding ? buffer_frames - padding : 0;
      if (available == 0) {
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
        continue;
      }

      const UINT32 frames_to_write = static_cast<UINT32>(std::min<size_t>(
          available, total_frames - offset_frames));
      BYTE* output = nullptr;
      if (FAILED(render_client->GetBuffer(frames_to_write, &output))) {
        return;
      }
      WritePcmToMixBuffer(pcm.data() + offset_frames * channels,
                          frames_to_write, format, output,
                          apply_output_volume);
      render_client->ReleaseBuffer(frames_to_write, 0);
      offset_frames += frames_to_write;
    }
  }

  void WritePcmToMixBuffer(const int16_t* pcm, UINT32 frames,
                           const WAVEFORMATEX& format, BYTE* output,
                           bool apply_output_volume) {
    const int channels = std::max<int>(1, format.nChannels);
    const size_t sample_count = static_cast<size_t>(frames) * channels;
    const float volume = apply_output_volume ? volume_.load() : 1.0f;
    const bool muted = apply_output_volume && muted_.load();

    if (IsFloatFormat(format) && format.wBitsPerSample == 32) {
      auto* samples = reinterpret_cast<float*>(output);
      for (size_t index = 0; index < sample_count; ++index) {
        samples[index] = muted ? 0.0f : Pcm16ToFloat(pcm[index]) * volume;
      }
      return;
    }

    if (IsPcmFormat(format) && format.wBitsPerSample == 16) {
      auto* samples = reinterpret_cast<int16_t*>(output);
      for (size_t index = 0; index < sample_count; ++index) {
        samples[index] = muted ? 0 : FloatToPcm16(Pcm16ToFloat(pcm[index]) * volume);
      }
      return;
    }

    std::memset(output, 0, frames * format.nBlockAlign);
  }

  void SendPcm(const std::vector<int16_t>& pcm, int sample_rate, int channels) {
    if (profile_.codec == AudioCodec::kOpus) {
      sample_rate = kOpusSampleRate;
    }
    if (!pcm.empty()) {
      PublishSignalLevel(PcmPeakLevel(pcm));
    }

    const bool usb_mode = transport_mode_ == TransportMode::kUsb;
    Endpoint endpoint;
    if (!usb_mode) {
      std::scoped_lock lock(endpoint_mutex_);
      endpoint = endpoint_;
    }
    if (channels <= 0 ||
        (usb_mode &&
         (usb_winusb_ == nullptr || usb_bulk_out_pipe_ == 0)) ||
        (!usb_mode && (!endpoint.available || socket_ == INVALID_SOCKET))) {
      return;
    }
    const uint64_t session_id =
        usb_mode ? remote_session_id_.load() : endpoint.session_id;
    const int packet_header_bytes =
        session_id == 0 ? kPacketV4HeaderBytes : kPacketV5HeaderBytes;

    const int packet_time_ms = std::clamp(profile_.packet_time_ms, 1, 12);
    if (packetizer_sample_rate_ != sample_rate ||
        packetizer_channels_ != channels ||
        packetizer_packet_time_ms_ != packet_time_ms ||
        packetizer_codec_ != profile_.codec) {
      ResetPacketizer(sample_rate, channels, packet_time_ms);
    }

    if (!pcm.empty()) {
      packetizer_pending_pcm_.insert(packetizer_pending_pcm_.end(), pcm.begin(),
                                     pcm.end());
    }

    const int bytes_per_frame = EncodedBytesPerFrame(profile_.codec, channels);
    const int max_payload_bytes = kMaxPacketBytes - kPacketV5HeaderBytes -
                                  EncodedPacketOverhead(profile_.codec,
                                                        channels);
    const int max_frames = profile_.codec == AudioCodec::kOpus
                               ? OpusFrameSamplesForPacketTime(packet_time_ms)
                           : profile_.codec == AudioCodec::kAac
                               ? kAacSamplesPerFrame
                               : std::max(1, max_payload_bytes /
                                                  std::max(1, bytes_per_frame));
    if (profile_.codec == AudioCodec::kOpus &&
        !opus_codec_.Configure(channels, profile_.bitrate_kbps * 1000,
                               ShouldUseLowDelayOpus())) {
      return;
    }
    if (profile_.codec == AudioCodec::kAac &&
        !aac_codec_.Configure(sample_rate, channels,
                              profile_.bitrate_kbps * 1000)) {
      return;
    }

    while (capture_running_) {
      const int pending_frames =
          static_cast<int>(packetizer_pending_pcm_.size()) / channels;
      const int frames = NextPacketFrameCount(sample_rate, packet_time_ms,
                                              max_frames);
      if (pending_frames < frames) {
        break;
      }

      const auto begin = packetizer_pending_pcm_.begin();
      const auto end = begin + frames * channels;
      const std::vector<int16_t> chunk(begin, end);
      const auto encoded = EncodeAudio(chunk, channels);
      if (encoded.payload.empty()) {
        packetizer_pending_pcm_.erase(packetizer_pending_pcm_.begin(), end);
        packetizer_sent_frames_ += frames;
        ++packetizer_packet_count_;
        continue;
      }
      std::vector<uint8_t> packet(packet_header_bytes + encoded.payload.size());
      const int64_t send_time_ms = NowMillis();
      RemoteReceiverClockEcho receiver_clock_echo;
      {
        std::scoped_lock lock(remote_receiver_clock_mutex_);
        receiver_clock_echo = remote_receiver_clock_echo_;
      }
      const bool has_fresh_receiver_time =
          receiver_clock_echo.receiver_time_ms > 0 &&
          receiver_clock_echo.received_at_sender_time_ms > 0 &&
          send_time_ms - receiver_clock_echo.received_at_sender_time_ms < 3000;
      const int64_t echoed_receiver_time_ms =
          has_fresh_receiver_time ? receiver_clock_echo.receiver_time_ms : 0;
      const int64_t echo_received_at_sender_time_ms =
          has_fresh_receiver_time
              ? receiver_clock_echo.received_at_sender_time_ms
              : 0;

      WriteU32(packet, 0,
               session_id == 0 ? kPacketV4Magic : kPacketV5Magic);
      WriteU32(packet, 4, sequence_++);
      WriteU32(packet, 8, static_cast<uint32_t>(sample_rate));
      WriteU16(packet, 12, static_cast<uint16_t>(channels));
      WriteU16(packet, 14, encoded.flags);
      WriteU16(packet, 16, encoded.codec_id);
      WriteU16(packet, 18, encoded.packet_kind);
      WriteU32(packet, 20, encoded.decoded_frame_count);
      WriteU64(packet, 24, static_cast<uint64_t>(send_time_ms));
      WriteU64(packet, 32, static_cast<uint64_t>(echoed_receiver_time_ms));
      WriteU64(packet, 40,
               static_cast<uint64_t>(echo_received_at_sender_time_ms));
      WriteU32(packet, 48, static_cast<uint32_t>(std::clamp(
                             profile_.playback_buffer_ms, kMinBufferMs,
                             kMaxBufferMs)));
      WriteU32(packet, 52, ReceiverOptionsFor(profile_));
      if (session_id != 0) {
        WriteU64(packet, 56, session_id);
      }
      if (!encoded.payload.empty()) {
        std::memcpy(packet.data() + packet_header_bytes,
                    encoded.payload.data(), encoded.payload.size());
      }

      if (usb_mode) {
        if (!WriteUsbFrame(packet.data(), packet.size())) {
          UsbDebugLog("USB audio write failed; stopping capture");
          capture_running_ = false;
          usb_control_running_ = false;
          packetizer_pending_pcm_.erase(packetizer_pending_pcm_.begin(), end);
          packetizer_sent_frames_ += frames;
          ++packetizer_packet_count_;
          break;
        }
        const uint64_t count = ++usb_audio_packets_sent_;
        usb_audio_bytes_sent_.fetch_add(kUsbFrameHeaderBytes + packet.size());
        if (count <= 5 || count % 1000 == 0) {
          UsbDebugLog("sent USB audio packet #" + std::to_string(count) +
                      " bytes=" +
                      std::to_string(kUsbFrameHeaderBytes + packet.size()) +
                      " frames=" + std::to_string(frames) +
                      " sampleRate=" + std::to_string(sample_rate) +
                      " channels=" + std::to_string(channels) +
                      " codec=" + std::to_string(encoded.codec_id));
        }
      } else {
        sendto(socket_, reinterpret_cast<const char*>(packet.data()),
               static_cast<int>(packet.size()), 0,
               reinterpret_cast<const sockaddr*>(&endpoint.address),
               sizeof(endpoint.address));
      }

      packetizer_pending_pcm_.erase(packetizer_pending_pcm_.begin(), end);
      packetizer_sent_frames_ += frames;
      ++packetizer_packet_count_;
    }
  }

  int NextPacketFrameCount(int sample_rate, int packet_time_ms,
                           int max_frames) const {
    if (packetizer_codec_ == AudioCodec::kOpus) {
      return std::min(OpusFrameSamplesForPacketTime(packet_time_ms),
                      max_frames);
    }
    if (packetizer_codec_ == AudioCodec::kAac) {
      return std::min(kAacSamplesPerFrame, max_frames);
    }

    const double target_frames =
        static_cast<double>(sample_rate) * packet_time_ms / 1000.0;
    if (target_frames >= max_frames) {
      return max_frames;
    }

    const auto next_packet_index =
        static_cast<double>(packetizer_packet_count_ + 1);
    const auto scheduled_total_frames = static_cast<uint64_t>(
        std::llround(next_packet_index * target_frames));
    const uint64_t next_frames =
        scheduled_total_frames > packetizer_sent_frames_
            ? scheduled_total_frames - packetizer_sent_frames_
            : 1;

    return std::clamp(static_cast<int>(next_frames), 1, max_frames);
  }

  int EncodedBytesPerFrame(AudioCodec codec, int channels) const {
    const int channel_count = std::max(1, channels);
    switch (codec) {
      case AudioCodec::kOpus:
      case AudioCodec::kAac:
        return 1;
      case AudioCodec::kG711MuLaw:
      case AudioCodec::kG711ALaw:
        return channel_count;
      case AudioCodec::kImaAdpcm:
        return std::max(1, (channel_count + 1) / 2);
      case AudioCodec::kPcm:
      default:
        return channel_count * static_cast<int>(sizeof(int16_t));
    }
  }

  int EncodedPacketOverhead(AudioCodec codec, int channels) const {
    switch (codec) {
      case AudioCodec::kImaAdpcm:
        return std::max(1, channels) * 4;
      case AudioCodec::kOpus:
      case AudioCodec::kAac:
        return 0;
      case AudioCodec::kG711MuLaw:
      case AudioCodec::kG711ALaw:
      case AudioCodec::kPcm:
      default:
        return 0;
    }
  }

  EncodedAudioPacket EncodeAudio(const std::vector<int16_t>& pcm,
                                 int channels) {
    const bool muted = muted_.load();
    switch (profile_.codec) {
      case AudioCodec::kOpus:
        return opus_codec_.Encode(
            pcm, channels, static_cast<int>(pcm.size() / std::max(1, channels)),
            muted);
      case AudioCodec::kAac:
        return aac_codec_.Encode(pcm, channels, muted);
      case AudioCodec::kG711MuLaw:
        return g711_mu_law_codec_.Encode(pcm, channels, muted);
      case AudioCodec::kG711ALaw:
        return g711_a_law_codec_.Encode(pcm, channels, muted);
      case AudioCodec::kImaAdpcm:
        return ima_adpcm_codec_.Encode(pcm, channels, muted);
      case AudioCodec::kPcm:
      default:
        return pcm_codec_.Encode(pcm, channels, muted);
    }
  }

  void ResetPacketizer() {
    packetizer_pending_pcm_.clear();
    packetizer_sent_frames_ = 0;
    packetizer_packet_count_ = 0;
    packetizer_sample_rate_ = 0;
    packetizer_channels_ = 0;
    packetizer_packet_time_ms_ = 0;
    packetizer_codec_ = AudioCodec::kPcm;
  }

  void ResetPacketizer(int sample_rate, int channels, int packet_time_ms) {
    ResetPacketizer();
    packetizer_sample_rate_ = sample_rate;
    packetizer_channels_ = channels;
    packetizer_packet_time_ms_ = packet_time_ms;
    packetizer_codec_ = profile_.codec;
  }

  int OutputSampleRateForProfile() const {
    if (profile_.codec == AudioCodec::kOpus) {
      return kOpusSampleRate;
    }
    return std::clamp(profile_.sample_rate, 8000, 192000);
  }

  bool ShouldUseLowDelayOpus() const {
    return profile_.mode == AudioMode::kGaming ||
           profile_.packet_time_ms <= 2 ||
           profile_.playback_buffer_ms <= 28;
  }

  static void FinishCom(bool owns_com) {
    if (owns_com) {
      CoUninitialize();
    }
  }

  AudioProfile profile_;
  TransportMode transport_mode_ = TransportMode::kWifi;
  bool usb_receiver_mode_ = false;
  SOCKET socket_ = INVALID_SOCKET;
  unsigned long socket_bind_address_ = INADDR_ANY;
  HANDLE usb_device_handle_ = INVALID_HANDLE_VALUE;
  WINUSB_INTERFACE_HANDLE usb_winusb_ = nullptr;
  UCHAR usb_bulk_in_pipe_ = 0;
  UCHAR usb_bulk_out_pipe_ = 0;
  bool usb_interface_access_denied_ = false;
  bool usb_interface_without_winusb_ = false;
  std::atomic<uint64_t> usb_audio_packets_sent_ = 0;
  std::atomic<uint64_t> usb_audio_bytes_sent_ = 0;
  std::atomic<uint64_t> usb_subscribe_packets_received_ = 0;
  std::atomic<uint64_t> usb_read_failures_ = 0;
  std::atomic<uint64_t> usb_write_failures_ = 0;
  std::mutex usb_write_mutex_;
  bool winsock_started_ = false;
  bool media_foundation_started_ = false;
  std::thread control_thread_;
  std::thread usb_control_thread_;
  std::thread capture_thread_;
  std::thread playback_receive_thread_;
  std::thread playback_render_thread_;
  std::atomic_bool control_running_ = false;
  std::atomic_bool usb_control_running_ = false;
  std::atomic_bool capture_running_ = false;
  std::atomic_bool playback_running_ = false;
  std::atomic<float> volume_ = 0.86f;
  std::atomic_bool muted_ = false;
  std::atomic<uint32_t> sequence_ = 0;
  std::atomic<double> remote_output_latency_ms_ = -1.0;
  std::atomic<double> remote_audio_latency_ms_ = -1.0;
  std::atomic<double> remote_network_latency_ms_ = -1.0;
  std::atomic<double> remote_signal_level_ = 0.0;
  std::atomic<int64_t> remote_queued_frames_ = 0;
  std::atomic<int64_t> remote_buffer_size_frames_ = 0;
  std::atomic<int64_t> remote_target_buffer_frames_ = 0;
  std::atomic<int64_t> remote_adaptive_playback_buffer_ms_ = 0;
  std::atomic<int64_t> remote_adaptive_max_playback_buffer_ms_ = 0;
  std::atomic<int64_t> remote_adaptive_limit_reached_ = 0;
  std::atomic<int64_t> remote_adaptive_underruns_in_window_ = 0;
  std::atomic<int64_t> remote_adaptive_underruns_in_burst_ = 0;
  std::atomic<int64_t> remote_adaptive_low_queue_samples_ = 0;
  std::atomic<int64_t> remote_playback_queue_fill_percent_ = 0;
  std::atomic<int64_t> remote_underrun_count_ = 0;
  std::atomic<int64_t> remote_dropped_packet_count_ = 0;
  std::atomic<int64_t> remote_lost_packet_count_ = 0;
  std::atomic<int64_t> remote_trim_count_ = 0;
  std::atomic<int64_t> remote_metrics_received_at_ms_ = 0;
  std::atomic<uint64_t> remote_session_id_ = 0;
  std::atomic<int64_t> last_heartbeat_sent_at_ms_ = 0;
  std::mutex remote_receiver_clock_mutex_;
  RemoteReceiverClockEcho remote_receiver_clock_echo_;
  std::string remote_platform_;
  std::vector<std::string> remote_supported_codecs_;
  mutable std::atomic<double> local_signal_peak_ = 0.0;
  std::atomic<double> local_last_playback_signal_level_ = 0.0;
  std::atomic<int64_t> local_last_audio_packet_received_at_ms_ = 0;
  std::atomic<int64_t> local_last_peer_packet_received_at_ms_ = 0;
  std::atomic<uint64_t> receiver_session_id_ = 0;
  std::atomic_bool session_protocol_active_ = false;
  std::atomic<int64_t> local_buffer_size_frames_ = 0;
  std::atomic<int64_t> local_target_buffer_frames_ = 0;
  std::atomic<int64_t> local_adaptive_playback_buffer_ms_ = 0;
  std::atomic<int64_t> local_adaptive_max_playback_buffer_ms_ = 0;
  std::atomic<int64_t> local_adaptive_limit_reached_ = 0;
  std::atomic<int64_t> local_adaptive_underruns_in_window_ = 0;
  std::atomic<int64_t> local_adaptive_underruns_in_burst_ = 0;
  std::atomic<int64_t> local_adaptive_low_queue_samples_ = 0;
  std::atomic_bool local_render_started_ = false;
  std::atomic<int64_t> local_render_started_at_ms_ = 0;
  std::atomic<int64_t> local_underrun_count_ = 0;
  std::atomic<int64_t> local_dropped_packet_count_ = 0;
  std::atomic<int64_t> local_lost_packet_count_ = 0;
  std::atomic<int64_t> local_last_sequence_ = -1;
  std::atomic<int> local_output_sample_rate_ = 0;
  std::atomic<int> local_input_sample_rate_ = 0;
  std::atomic<int> local_input_channels_ = 0;
  std::atomic<int> local_codec_id_ = kCodecPcm;
  std::mutex endpoint_mutex_;
  std::mutex receiver_source_mutex_;
  mutable std::mutex remote_capabilities_mutex_;
  std::mutex playback_queue_mutex_;
  std::condition_variable playback_queue_cv_;
  std::mutex sound_effect_mutex_;
  std::mutex sound_effect_output_mutex_;
  std::mutex sound_effect_monitor_mutex_;
  std::condition_variable sound_effect_output_cv_;
  std::condition_variable sound_effect_monitor_cv_;
  Endpoint endpoint_;
  ReceiverSource receiver_source_;
  std::deque<PcmPlaybackPacket> playback_queue_;
  std::deque<SoundEffectClip> sound_effect_queue_;
  std::deque<SoundEffectClip> sound_effect_output_queue_;
  std::deque<SoundEffectClip> sound_effect_monitor_queue_;
  std::thread sound_effect_output_thread_;
  std::thread sound_effect_monitor_thread_;
  std::thread virtual_mic_passthrough_thread_;
  std::atomic_bool sound_effect_output_running_ = false;
  std::atomic_bool sound_effect_monitor_running_ = false;
  std::atomic_bool virtual_mic_passthrough_running_ = false;
  std::string sound_effect_output_device_id_;
  std::string virtual_mic_passthrough_output_device_id_;
  int sound_effect_output_sample_rate_ = 0;
  int sound_effect_output_channels_ = 0;
  std::atomic<int64_t> playback_queue_frames_ = 0;
  PcmCodecAdapter pcm_codec_;
  OpusCodecAdapter opus_codec_;
  AacCodecAdapter aac_codec_;
  G711CodecAdapter g711_mu_law_codec_{true};
  G711CodecAdapter g711_a_law_codec_{false};
  ImaAdpcmCodecAdapter ima_adpcm_codec_;
  int64_t local_last_adaptive_buffer_increase_at_ms_ = 0;
  int64_t local_last_playback_pressure_at_ms_ = 0;
  int64_t local_last_known_underrun_count_ = 0;
  int64_t local_adaptive_underrun_window_start_at_ms_ = 0;
  int64_t local_adaptive_underruns_in_window_counter_ = 0;
  int64_t local_adaptive_underrun_burst_start_at_ms_ = 0;
  int64_t local_adaptive_underruns_in_burst_counter_ = 0;
  int local_adaptive_low_queue_sample_count_ = 0;
  int64_t local_adaptive_last_arrival_sequence_ = -1;
  int64_t local_adaptive_last_arrival_at_ms_ = 0;
  double local_adaptive_last_packet_duration_ms_ = 0.0;
  double local_adaptive_relative_delay_ms_ = 0.0;
  int64_t local_adaptive_delay_window_start_at_ms_ = 0;
  double local_adaptive_delay_window_peak_ms_ = 0.0;
  std::array<int, kAdaptiveDelayHistorySamples> local_adaptive_delay_history_ms_{};
  size_t local_adaptive_delay_history_index_ = 0;
  size_t local_adaptive_delay_history_count_ = 0;
  int local_adaptive_network_target_buffer_ms_ = 0;
  std::vector<int16_t> packetizer_pending_pcm_;
  uint64_t packetizer_sent_frames_ = 0;
  uint64_t packetizer_packet_count_ = 0;
  int packetizer_sample_rate_ = 0;
  int packetizer_channels_ = 0;
  int packetizer_packet_time_ms_ = 0;
  AudioCodec packetizer_codec_ = AudioCodec::kPcm;
  bool resampler_initialized_ = false;
  double resampler_source_cursor_ = 0.0;
  int64_t resampler_input_frames_consumed_ = 0;
  int resampler_input_sample_rate_ = 0;
  int resampler_input_channels_ = 0;
  int resampler_output_sample_rate_ = 0;
  int resampler_output_channels_ = 0;
};

WindowsAudioEngine::WindowsAudioEngine()
    : impl_(std::make_unique<WindowsAudioEngine::Impl>()) {}

WindowsAudioEngine::~WindowsAudioEngine() = default;

flutter::EncodableMap WindowsAudioEngine::GetCapabilities() const {
  return impl_->GetCapabilities();
}

flutter::EncodableList WindowsAudioEngine::GetSoundboardOutputDevices() const {
  return impl_->GetSoundboardOutputDevices();
}

flutter::EncodableList WindowsAudioEngine::GetNetworkInterfaces() const {
  return impl_->GetNetworkInterfaces();
}

flutter::EncodableMap WindowsAudioEngine::GetMetrics() const {
  return impl_->GetMetrics();
}

std::optional<std::string> WindowsAudioEngine::PrepareSender(
    const flutter::EncodableValue* arguments) {
  return impl_->PrepareSender(arguments);
}

std::optional<std::string> WindowsAudioEngine::PrepareUsbSender(
    const flutter::EncodableValue* arguments) {
  return impl_->PrepareUsbSender(arguments);
}

std::optional<std::string> WindowsAudioEngine::PrepareUsbReceiver(
    const flutter::EncodableValue* arguments) {
  return impl_->PrepareUsbReceiver(arguments);
}

std::optional<std::string> WindowsAudioEngine::PrepareReceiver(
    const flutter::EncodableValue* arguments) {
  return impl_->PrepareReceiver(arguments);
}

std::optional<std::string> WindowsAudioEngine::ConnectToSender(
    const flutter::EncodableValue* arguments) {
  return impl_->ConnectToSender(arguments);
}

std::optional<std::string> WindowsAudioEngine::StartStream(
    const flutter::EncodableValue* arguments) {
  return impl_->StartStream(arguments);
}

void WindowsAudioEngine::StopStream() {
  impl_->StopStream();
}

void WindowsAudioEngine::SetVolume(const flutter::EncodableValue* arguments) {
  impl_->SetVolume(arguments);
}

void WindowsAudioEngine::SetMuted(const flutter::EncodableValue* arguments) {
  impl_->SetMuted(arguments);
}

std::optional<std::string> WindowsAudioEngine::PlaySoundEffect(
    const flutter::EncodableValue* arguments) {
  return impl_->PlaySoundEffect(arguments);
}

std::optional<std::string> WindowsAudioEngine::ConfigureVirtualMicPassthrough(
    const flutter::EncodableValue* arguments) {
  return impl_->ConfigureVirtualMicPassthrough(arguments);
}

void WindowsAudioEngine::StopSoundEffects() {
  impl_->StopSoundEffects();
}

void WindowsAudioEngine::Disconnect() {
  impl_->Disconnect();
}
