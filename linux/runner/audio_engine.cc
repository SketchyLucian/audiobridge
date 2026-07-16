#include "audio_engine.h"

#include <arpa/inet.h>
#include <dlfcn.h>
#include <netdb.h>
#include <netinet/in.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdint>
#include <cstring>
#include <deque>
#include <exception>
#include <memory>
#include <mutex>
#include <optional>
#include <sstream>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace {

constexpr int kAudioPort = 47885;
constexpr int kMaxPacketBytes = 1200;
constexpr int kPacketV5HeaderBytes = 64;
constexpr uint32_t kPacketV5Magic = 0x35524241;  // ABR5, little-endian.
constexpr uint16_t kCodecPcm = 0;
constexpr uint16_t kPacketKindAudio = 0;
constexpr uint16_t kPacketKindHeartbeat = 1;
constexpr uint16_t kPacketFlagMuted = 1;
constexpr int kSubscribeIntervalMs = 300;
constexpr int kHeartbeatIntervalMs = 800;
constexpr int kPeerHeartbeatTimeoutMs = 3000;
constexpr int kSocketTimeoutMs = 150;
constexpr int kAudioSocketBufferBytes = 256 * 1024;
constexpr int kLowDelayTrafficClass = 0xB8;

constexpr int kSndPcmStreamPlayback = 0;
constexpr int kSndPcmStreamCapture = 1;
constexpr int kSndPcmFormatS16Le = 2;
constexpr int kSndPcmAccessRwInterleaved = 3;

int64_t NowMillis() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}

void CloseSocket(int* socket_fd) {
  if (*socket_fd < 0) {
    return;
  }
  shutdown(*socket_fd, SHUT_RDWR);
  close(*socket_fd);
  *socket_fd = -1;
}

void WriteU16(std::vector<uint8_t>* output, size_t offset, uint16_t value) {
  (*output)[offset] = static_cast<uint8_t>(value & 0xFF);
  (*output)[offset + 1] = static_cast<uint8_t>((value >> 8) & 0xFF);
}

void WriteU32(std::vector<uint8_t>* output, size_t offset, uint32_t value) {
  for (size_t index = 0; index < 4; ++index) {
    (*output)[offset + index] =
        static_cast<uint8_t>((value >> (index * 8)) & 0xFF);
  }
}

void WriteU64(std::vector<uint8_t>* output, size_t offset, uint64_t value) {
  for (size_t index = 0; index < 8; ++index) {
    (*output)[offset + index] =
        static_cast<uint8_t>((value >> (index * 8)) & 0xFF);
  }
}

uint16_t ReadU16(const uint8_t* input) {
  return static_cast<uint16_t>(input[0]) |
         (static_cast<uint16_t>(input[1]) << 8);
}

uint32_t ReadU32(const uint8_t* input) {
  uint32_t value = 0;
  for (size_t index = 0; index < 4; ++index) {
    value |= static_cast<uint32_t>(input[index]) << (index * 8);
  }
  return value;
}

uint64_t ReadU64(const uint8_t* input) {
  uint64_t value = 0;
  for (size_t index = 0; index < 8; ++index) {
    value |= static_cast<uint64_t>(input[index]) << (index * 8);
  }
  return value;
}

FlValue* StringList(std::initializer_list<const char*> values) {
  FlValue* result = fl_value_new_list();
  for (const char* value : values) {
    fl_value_append_take(result, fl_value_new_string(value));
  }
  return result;
}

void SetMapString(FlValue* map, const char* key, const std::string& value) {
  fl_value_set_string_take(map, key, fl_value_new_string(value.c_str()));
}

void SetMapBool(FlValue* map, const char* key, bool value) {
  fl_value_set_string_take(map, key, fl_value_new_bool(value));
}

void SetMapInt(FlValue* map, const char* key, int64_t value) {
  fl_value_set_string_take(map, key, fl_value_new_int(value));
}

void SetMapFloat(FlValue* map, const char* key, double value) {
  fl_value_set_string_take(map, key, fl_value_new_float(value));
}

std::optional<int> MapInt(FlValue* arguments, const char* key) {
  if (arguments == nullptr || fl_value_get_type(arguments) != FL_VALUE_TYPE_MAP) {
    return std::nullopt;
  }
  FlValue* value = fl_value_lookup_string(arguments, key);
  if (value == nullptr) {
    return std::nullopt;
  }
  if (fl_value_get_type(value) == FL_VALUE_TYPE_INT) {
    return static_cast<int>(fl_value_get_int(value));
  }
  if (fl_value_get_type(value) == FL_VALUE_TYPE_FLOAT) {
    return static_cast<int>(fl_value_get_float(value));
  }
  return std::nullopt;
}

std::optional<double> MapDouble(FlValue* arguments, const char* key) {
  if (arguments == nullptr || fl_value_get_type(arguments) != FL_VALUE_TYPE_MAP) {
    return std::nullopt;
  }
  FlValue* value = fl_value_lookup_string(arguments, key);
  if (value == nullptr) {
    return std::nullopt;
  }
  if (fl_value_get_type(value) == FL_VALUE_TYPE_INT) {
    return static_cast<double>(fl_value_get_int(value));
  }
  if (fl_value_get_type(value) == FL_VALUE_TYPE_FLOAT) {
    return fl_value_get_float(value);
  }
  return std::nullopt;
}

std::optional<bool> MapBool(FlValue* arguments, const char* key) {
  if (arguments == nullptr || fl_value_get_type(arguments) != FL_VALUE_TYPE_MAP) {
    return std::nullopt;
  }
  FlValue* value = fl_value_lookup_string(arguments, key);
  if (value == nullptr || fl_value_get_type(value) != FL_VALUE_TYPE_BOOL) {
    return std::nullopt;
  }
  return fl_value_get_bool(value);
}

std::optional<std::string> MapString(FlValue* arguments, const char* key) {
  if (arguments == nullptr || fl_value_get_type(arguments) != FL_VALUE_TYPE_MAP) {
    return std::nullopt;
  }
  FlValue* value = fl_value_lookup_string(arguments, key);
  if (value == nullptr || fl_value_get_type(value) != FL_VALUE_TYPE_STRING) {
    return std::nullopt;
  }
  return std::string(fl_value_get_string(value));
}

std::optional<std::string> MetricValue(const std::string& message,
                                       const char* key) {
  const std::string prefix = std::string(key) + "=";
  std::istringstream values(message);
  std::string value;
  while (values >> value) {
    if (value.rfind(prefix, 0) == 0) {
      return value.substr(prefix.size());
    }
  }
  return std::nullopt;
}

std::optional<uint64_t> SessionIdFromMessage(const std::string& message) {
  const auto protocol = MetricValue(message, "protocol");
  const auto session_id = MetricValue(message, "sessionId");
  if (!protocol.has_value() || !session_id.has_value()) {
    return std::nullopt;
  }
  try {
    if (std::stoll(protocol.value()) < 5) {
      return std::nullopt;
    }
    const uint64_t value = std::stoull(session_id.value());
    return value == 0 ? std::nullopt : std::optional<uint64_t>(value);
  } catch (const std::exception&) {
    return std::nullopt;
  }
}

class AlsaApi {
 public:
  AlsaApi() {
    handle_ = dlopen("libasound.so.2", RTLD_NOW | RTLD_LOCAL);
    if (handle_ == nullptr) {
      return;
    }
    pcm_open_ = Load<pcm_open_fn>("snd_pcm_open");
    pcm_close_ = Load<pcm_close_fn>("snd_pcm_close");
    pcm_set_params_ = Load<pcm_set_params_fn>("snd_pcm_set_params");
    pcm_readi_ = Load<pcm_readi_fn>("snd_pcm_readi");
    pcm_writei_ = Load<pcm_writei_fn>("snd_pcm_writei");
    pcm_recover_ = Load<pcm_recover_fn>("snd_pcm_recover");
    strerror_ = Load<strerror_fn>("snd_strerror");
    available_ = pcm_open_ != nullptr && pcm_close_ != nullptr &&
                 pcm_set_params_ != nullptr && pcm_readi_ != nullptr &&
                 pcm_writei_ != nullptr && pcm_recover_ != nullptr;
    if (!available_) {
      dlclose(handle_);
      handle_ = nullptr;
    }
  }

  ~AlsaApi() {
    if (handle_ != nullptr) {
      dlclose(handle_);
    }
  }

  AlsaApi(const AlsaApi&) = delete;
  AlsaApi& operator=(const AlsaApi&) = delete;

  bool available() const { return available_; }

  int Open(void** pcm, int stream) const {
    return pcm_open_(pcm, "default", stream, 0);
  }

  int Close(void* pcm) const { return pcm_close_(pcm); }

  int Configure(void* pcm, int channels, int sample_rate,
                int latency_ms) const {
    return pcm_set_params_(pcm, kSndPcmFormatS16Le,
                           kSndPcmAccessRwInterleaved, channels, sample_rate,
                           1, static_cast<unsigned int>(
                                  std::clamp(latency_ms, 5, 500) * 1000));
  }

  long Read(void* pcm, int16_t* frames, unsigned long frame_count) const {
    return pcm_readi_(pcm, frames, frame_count);
  }

  long Write(void* pcm, const int16_t* frames,
             unsigned long frame_count) const {
    return pcm_writei_(pcm, frames, frame_count);
  }

  int Recover(void* pcm, int error) const { return pcm_recover_(pcm, error, 1); }

  std::string Error(int error) const {
    return strerror_ == nullptr ? std::to_string(error) : strerror_(error);
  }

 private:
  using pcm_open_fn = int (*)(void**, const char*, int, int);
  using pcm_close_fn = int (*)(void*);
  using pcm_set_params_fn = int (*)(void*, int, int, unsigned int,
                                    unsigned int, int, unsigned int);
  using pcm_readi_fn = long (*)(void*, void*, unsigned long);
  using pcm_writei_fn = long (*)(void*, const void*, unsigned long);
  using pcm_recover_fn = int (*)(void*, int, int);
  using strerror_fn = const char* (*)(int);

  template <typename T>
  T Load(const char* name) {
    return reinterpret_cast<T>(dlsym(handle_, name));
  }

  void* handle_ = nullptr;
  pcm_open_fn pcm_open_ = nullptr;
  pcm_close_fn pcm_close_ = nullptr;
  pcm_set_params_fn pcm_set_params_ = nullptr;
  pcm_readi_fn pcm_readi_ = nullptr;
  pcm_writei_fn pcm_writei_ = nullptr;
  pcm_recover_fn pcm_recover_ = nullptr;
  strerror_fn strerror_ = nullptr;
  bool available_ = false;
};

}  // namespace

class LinuxAudioEngine::Impl {
 public:
  Impl() = default;

  ~Impl() { Disconnect(); }

  FlValue* GetCapabilities() const {
    FlValue* capabilities = fl_value_new_map();
    SetMapString(capabilities, "platform", "linux");
    SetMapBool(capabilities, "canSend", alsa_.available());
    SetMapBool(capabilities, "canReceive", alsa_.available());
    SetMapBool(capabilities, "canPlaySoundEffects", false);
    SetMapString(capabilities, "backend", "linux-alsa-pcm-udp");
    SetMapString(capabilities, "detail",
                 alsa_.available()
                     ? "Wi-Fi PCM relay using the default ALSA device. PipeWire and PulseAudio are supported through ALSA compatibility."
                     : "libasound.so.2 is unavailable. Install ALSA compatibility support to enable audio relay.");
    fl_value_set_string_take(capabilities, "supportedCodecs",
                             StringList({"pcm"}));
    fl_value_set_string_take(capabilities, "supportedOutputBackends",
                             StringList({"auto"}));
    fl_value_set_string_take(capabilities, "supportedTransports",
                             StringList({"wifi"}));
    fl_value_set_string_take(capabilities, "soundboardOutputDevices",
                             fl_value_new_list());
    fl_value_set_string_take(capabilities, "codecBitrateRanges",
                             fl_value_new_map());
    return capabilities;
  }

  FlValue* GetMetrics() const {
    const int sample_rate = active_sample_rate_.load();
    const int64_t queued_frames = playback_queue_frames_.load();
    const int64_t target_frames = target_buffer_frames_.load();
    const bool is_receiver = role_.load() == Role::kReceiver;
    const int64_t peer_seen_at = last_peer_seen_at_ms_.load();
    const bool peer_connected =
        peer_seen_at > 0 && NowMillis() - peer_seen_at <= kPeerHeartbeatTimeoutMs;

    FlValue* metrics = fl_value_new_map();
    const double output_latency_ms =
        is_receiver && sample_rate > 0
            ? static_cast<double>(queued_frames) * 1000.0 / sample_rate
            : 0.0;
    SetMapFloat(metrics, "outputLatencyMs", output_latency_ms);
    SetMapInt(metrics, "queuedFrames", queued_frames);
    SetMapInt(metrics, "bufferSizeFrames", target_frames);
    SetMapInt(metrics, "targetBufferFrames", target_frames);
    SetMapInt(metrics, "adaptivePlaybackBufferMs", playback_buffer_ms_.load());
    SetMapInt(metrics, "adaptiveMaxPlaybackBufferMs", playback_buffer_ms_.load());
    SetMapBool(metrics, "adaptiveLimitReached", false);
    SetMapInt(metrics, "adaptiveUnderrunsInWindow", 0);
    SetMapInt(metrics, "adaptiveUnderrunsInBurst", 0);
    SetMapInt(metrics, "adaptiveLowQueueSamples", 0);
    const int64_t queue_percent = target_frames <= 0
                                      ? 0
                                      : std::clamp<int64_t>(
                                            queued_frames * 100 / target_frames,
                                            0, 200);
    SetMapInt(metrics, "playbackQueueFillPercent", queue_percent);
    SetMapInt(metrics, "underrunCount", underrun_count_.load());
    SetMapInt(metrics, "droppedPacketCount", dropped_packet_count_.load());
    SetMapInt(metrics, "lostPacketCount", lost_packet_count_.load());
    SetMapInt(metrics, "trimCount", trim_count_.load());
    SetMapFloat(metrics, "signalLevel", signal_level_.load());
    SetMapBool(metrics, "peerConnected", peer_connected);
    {
      std::scoped_lock lock(remote_capabilities_mutex_);
      if (!remote_platform_.empty()) {
        SetMapString(metrics, "remotePlatform", remote_platform_);
      }
    }
    return metrics;
  }

  std::optional<std::string> PrepareSender(FlValue* arguments) {
    Disconnect();
    if (!alsa_.available()) {
      return "ALSA compatibility is unavailable. Install libasound and configure a default capture device.";
    }
    ReadProfile(arguments);
    role_ = Role::kSender;
    const auto requested_bind_address = MapString(arguments, "networkBindAddress");
    const auto error = OpenSenderSocket(requested_bind_address.value_or(""));
    if (error.has_value()) {
      return error;
    }
    control_running_ = true;
    control_thread_ = std::thread(&Impl::SenderControlLoop, this);
    return std::nullopt;
  }

  std::optional<std::string> PrepareReceiver(FlValue* arguments) {
    Disconnect();
    ReadProfile(arguments);
    role_ = Role::kReceiver;
    return std::nullopt;
  }

  std::optional<std::string> ConnectToSender(FlValue* arguments) {
    if (arguments == nullptr || fl_value_get_type(arguments) != FL_VALUE_TYPE_MAP) {
      return "Missing sender connection details.";
    }
    FlValue* device = fl_value_lookup_string(arguments, "device");
    if (device == nullptr || fl_value_get_type(device) != FL_VALUE_TYPE_MAP) {
      return "Missing sender device.";
    }
    const auto transport = MapString(device, "transport").value_or("wifi");
    if (transport != "wifi") {
      return "Linux currently supports Wi-Fi transport only.";
    }
    const auto host = MapString(device, "host");
    if (!host.has_value() || host->empty()) {
      return "Missing sender host.";
    }
    const int port = MapInt(device, "port").value_or(kAudioPort);
    sockaddr_in source = {};
    source.sin_family = AF_INET;
    source.sin_port = htons(static_cast<uint16_t>(std::clamp(port, 1, 65535)));
    if (inet_pton(AF_INET, host->c_str(), &source.sin_addr) != 1) {
      return "The selected sender does not have a usable IPv4 address.";
    }
    Disconnect();
    ReadProfile(arguments);
    role_ = Role::kReceiver;
    {
      std::scoped_lock lock(source_mutex_);
      receiver_source_ = source;
      receiver_source_available_ = true;
    }
    return std::nullopt;
  }

  std::optional<std::string> StartStream(FlValue* arguments) {
    ReadProfile(arguments);
    if (!alsa_.available()) {
      return "ALSA compatibility is unavailable. Install libasound and configure a default audio device.";
    }
    if (role_.load() == Role::kSender) {
      if (!control_running_) {
        return "Start Wi-Fi discovery before starting the sender.";
      }
      if (const auto error = ValidateDefaultDevice(kSndPcmStreamCapture)) {
        return error;
      }
      if (capture_running_.exchange(true)) {
        return std::nullopt;
      }
      capture_thread_ = std::thread(&Impl::CaptureLoop, this);
      return std::nullopt;
    }

    {
      std::scoped_lock lock(source_mutex_);
      if (!receiver_source_available_) {
        return "Select a Wi-Fi sender before starting playback.";
      }
    }
    if (const auto error = ValidateDefaultDevice(kSndPcmStreamPlayback)) {
      return error;
    }
    if (playback_running_.exchange(true)) {
      return std::nullopt;
    }
    const auto error = OpenReceiverSocket();
    if (error.has_value()) {
      playback_running_ = false;
      return error;
    }
    receiver_session_id_ = NextSessionId();
    last_sequence_ = -1;
    last_peer_seen_at_ms_ = 0;
    playback_queue_frames_ = 0;
    dropped_packet_count_ = 0;
    lost_packet_count_ = 0;
    trim_count_ = 0;
    underrun_count_ = 0;
    signal_level_ = 0.0;
    receive_thread_ = std::thread(&Impl::ReceiverLoop, this);
    playback_thread_ = std::thread(&Impl::PlaybackLoop, this);
    return std::nullopt;
  }

  std::optional<std::string> PrepareUsbSender(FlValue*) const {
    return "Linux currently supports Wi-Fi transport only.";
  }

  std::optional<std::string> PrepareUsbReceiver(FlValue*) const {
    return "Linux currently supports Wi-Fi transport only.";
  }

  void StopStream() {
    capture_running_ = false;
    if (capture_thread_.joinable()) {
      capture_thread_.join();
    }

    playback_running_ = false;
    playback_queue_cv_.notify_all();
    CloseSocket(&receiver_socket_);
    if (receive_thread_.joinable()) {
      receive_thread_.join();
    }
    if (playback_thread_.joinable()) {
      playback_thread_.join();
    }
    {
      std::scoped_lock lock(playback_queue_mutex_);
      playback_queue_.clear();
      playback_queue_frames_ = 0;
    }
    receiver_session_id_ = 0;
    target_buffer_frames_ = 0;
    active_sample_rate_ = profile_.sample_rate;
    signal_level_ = 0.0;
  }

  void SetVolume(FlValue* arguments) {
    const auto value = MapDouble(arguments, "value");
    if (value.has_value()) {
      volume_ = std::clamp(value.value(), 0.0, 1.0);
    }
  }

  void SetMuted(FlValue* arguments) {
    const auto value = MapBool(arguments, "value");
    if (value.has_value()) {
      muted_ = value.value();
    }
  }

  void Disconnect() {
    StopStream();
    control_running_ = false;
    CloseSocket(&sender_socket_);
    if (control_thread_.joinable()) {
      control_thread_.join();
    }
    {
      std::scoped_lock lock(endpoint_mutex_);
      sender_endpoint_available_ = false;
      sender_session_id_ = 0;
    }
    {
      std::scoped_lock lock(source_mutex_);
      receiver_source_available_ = false;
    }
    last_peer_seen_at_ms_ = 0;
  }

 private:
  enum class Role { kSender, kReceiver };

  struct Profile {
    int sample_rate = 48000;
    int channels = 2;
    int capture_buffer_ms = 35;
    int playback_buffer_ms = 35;
    int packet_time_ms = 3;
  };

  struct PcmPacket {
    std::vector<int16_t> samples;
    int sample_rate = 48000;
    int channels = 2;
  };

  void ReadProfile(FlValue* arguments) {
    profile_.sample_rate = std::clamp(MapInt(arguments, "sampleRate").value_or(48000),
                                      8000, 96000);
    profile_.channels = std::clamp(MapInt(arguments, "channels").value_or(2),
                                   1, 2);
    profile_.capture_buffer_ms = std::clamp(
        MapInt(arguments, "captureBufferMs").value_or(35), 5, 500);
    profile_.playback_buffer_ms = std::clamp(
        MapInt(arguments, "playbackBufferMs").value_or(35), 5, 500);
    profile_.packet_time_ms = std::clamp(
        MapInt(arguments, "packetTimeMs").value_or(3), 1, 12);
    playback_buffer_ms_ = profile_.playback_buffer_ms;
    active_sample_rate_ = profile_.sample_rate;
  }

  std::optional<std::string> ValidateDefaultDevice(int stream) const {
    void* device = nullptr;
    const int open_result = alsa_.Open(&device, stream);
    if (open_result < 0) {
      return "Unable to open the default ALSA " +
             std::string(stream == kSndPcmStreamCapture ? "capture" : "playback") +
             " device: " + alsa_.Error(open_result);
    }
    const int configure_result = alsa_.Configure(
        device, profile_.channels, profile_.sample_rate,
        stream == kSndPcmStreamCapture ? profile_.capture_buffer_ms
                                       : profile_.playback_buffer_ms);
    alsa_.Close(device);
    if (configure_result < 0) {
      return "Unable to configure the default ALSA " +
             std::string(stream == kSndPcmStreamCapture ? "capture" : "playback") +
             " device: " + alsa_.Error(configure_result);
    }
    return std::nullopt;
  }

  std::optional<std::string> OpenSenderSocket(const std::string& bind_address) {
    sender_socket_ = socket(AF_INET, SOCK_DGRAM, 0);
    if (sender_socket_ < 0) {
      return "Unable to open the Wi-Fi audio socket.";
    }
    ConfigureSocket(sender_socket_);
    sockaddr_in local = {};
    local.sin_family = AF_INET;
    local.sin_port = htons(kAudioPort);
    local.sin_addr.s_addr = htonl(INADDR_ANY);
    if (!bind_address.empty() &&
        inet_pton(AF_INET, bind_address.c_str(), &local.sin_addr) != 1) {
      CloseSocket(&sender_socket_);
      return "The selected Wi-Fi interface does not have a usable IPv4 address.";
    }
    if (bind(sender_socket_, reinterpret_cast<sockaddr*>(&local), sizeof(local)) !=
        0) {
      CloseSocket(&sender_socket_);
      return "Unable to listen for Wi-Fi receivers on UDP port 47885.";
    }
    return std::nullopt;
  }

  std::optional<std::string> OpenReceiverSocket() {
    receiver_socket_ = socket(AF_INET, SOCK_DGRAM, 0);
    if (receiver_socket_ < 0) {
      return "Unable to open the Wi-Fi playback socket.";
    }
    ConfigureSocket(receiver_socket_);
    sockaddr_in local = {};
    local.sin_family = AF_INET;
    local.sin_port = 0;
    local.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(receiver_socket_, reinterpret_cast<sockaddr*>(&local), sizeof(local)) !=
        0) {
      CloseSocket(&receiver_socket_);
      return "Unable to bind the Wi-Fi playback socket.";
    }
    return std::nullopt;
  }

  void ConfigureSocket(int socket_fd) const {
    const int enabled = 1;
    setsockopt(socket_fd, SOL_SOCKET, SO_REUSEADDR, &enabled, sizeof(enabled));
    setsockopt(socket_fd, SOL_SOCKET, SO_RCVBUF, &kAudioSocketBufferBytes,
               sizeof(kAudioSocketBufferBytes));
    setsockopt(socket_fd, SOL_SOCKET, SO_SNDBUF, &kAudioSocketBufferBytes,
               sizeof(kAudioSocketBufferBytes));
    setsockopt(socket_fd, IPPROTO_IP, IP_TOS, &kLowDelayTrafficClass,
               sizeof(kLowDelayTrafficClass));
    timeval timeout = {};
    timeout.tv_usec = kSocketTimeoutMs * 1000;
    setsockopt(socket_fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
  }

  void SenderControlLoop() {
    std::array<char, 2048> buffer = {};
    while (control_running_) {
      sockaddr_in remote = {};
      socklen_t remote_size = sizeof(remote);
      const ssize_t received = recvfrom(
          sender_socket_, buffer.data(), buffer.size(), 0,
          reinterpret_cast<sockaddr*>(&remote), &remote_size);
      if (received <= 0) {
        continue;
      }
      const std::string message(buffer.data(), static_cast<size_t>(received));
      if (message.rfind("ABR_SUBSCRIBE", 0) != 0) {
        continue;
      }
      const auto session_id = SessionIdFromMessage(message);
      if (!session_id.has_value()) {
        continue;
      }
      if (const auto platform = MetricValue(message, "platform")) {
        std::scoped_lock lock(remote_capabilities_mutex_);
        remote_platform_ = platform.value();
      }
      {
        std::scoped_lock lock(endpoint_mutex_);
        sender_endpoint_ = remote;
        sender_endpoint_available_ = true;
        sender_session_id_ = session_id.value();
      }
      last_peer_seen_at_ms_ = NowMillis();
      MaybeSendHeartbeat();
    }
  }

  void MaybeSendHeartbeat() {
    const int64_t now = NowMillis();
    if (now - last_heartbeat_sent_at_ms_.load() < kHeartbeatIntervalMs) {
      return;
    }
    sockaddr_in endpoint = {};
    uint64_t session_id = 0;
    {
      std::scoped_lock lock(endpoint_mutex_);
      if (!sender_endpoint_available_) {
        return;
      }
      endpoint = sender_endpoint_;
      session_id = sender_session_id_;
    }
    const std::vector<uint8_t> heartbeat = BuildPacket(
        nullptr, 0, 0, kPacketKindHeartbeat, session_id, false);
    if (sendto(sender_socket_, heartbeat.data(), heartbeat.size(), 0,
               reinterpret_cast<const sockaddr*>(&endpoint), sizeof(endpoint)) >=
        0) {
      last_heartbeat_sent_at_ms_ = now;
    }
  }

  void CaptureLoop() {
    void* capture = nullptr;
    const int open_result = alsa_.Open(&capture, kSndPcmStreamCapture);
    if (open_result < 0) {
      dropped_packet_count_++;
      capture_running_ = false;
      return;
    }
    const int configure_result = alsa_.Configure(
        capture, profile_.channels, profile_.sample_rate, profile_.capture_buffer_ms);
    if (configure_result < 0) {
      alsa_.Close(capture);
      dropped_packet_count_++;
      capture_running_ = false;
      return;
    }

    const int max_frames =
        std::max(1, (kMaxPacketBytes - kPacketV5HeaderBytes) /
                        (profile_.channels * static_cast<int>(sizeof(int16_t))));
    const int requested_frames = std::max(
        1, profile_.sample_rate * profile_.packet_time_ms / 1000);
    const int frames_per_read = std::min(requested_frames, max_frames);
    std::vector<int16_t> samples(
        static_cast<size_t>(frames_per_read) * profile_.channels);

    while (capture_running_) {
      const long frames = alsa_.Read(capture, samples.data(), frames_per_read);
      if (frames < 0) {
        alsa_.Recover(capture, static_cast<int>(frames));
        ++underrun_count_;
        continue;
      }
      if (frames == 0) {
        continue;
      }
      SendCapturePacket(samples.data(), static_cast<int>(frames));
    }
    alsa_.Close(capture);
  }

  void SendCapturePacket(const int16_t* samples, int frame_count) {
    sockaddr_in endpoint = {};
    uint64_t session_id = 0;
    {
      std::scoped_lock lock(endpoint_mutex_);
      if (!sender_endpoint_available_) {
        return;
      }
      endpoint = sender_endpoint_;
      session_id = sender_session_id_;
    }
    const bool muted = muted_.load();
    const std::vector<uint8_t> packet = BuildPacket(
        samples, frame_count, profile_.sample_rate, kPacketKindAudio, session_id,
        muted);
    if (sendto(sender_socket_, packet.data(), packet.size(), 0,
               reinterpret_cast<const sockaddr*>(&endpoint), sizeof(endpoint)) <
        0) {
      ++dropped_packet_count_;
      return;
    }
    PublishSignalLevel(samples, frame_count * profile_.channels, muted);
  }

  std::vector<uint8_t> BuildPacket(const int16_t* samples, int frame_count,
                                   int sample_rate, uint16_t packet_kind,
                                   uint64_t session_id, bool muted) {
    const size_t payload_bytes =
        samples == nullptr
            ? 0
            : static_cast<size_t>(frame_count) * profile_.channels *
                  sizeof(int16_t);
    std::vector<uint8_t> packet(kPacketV5HeaderBytes + payload_bytes);
    WriteU32(&packet, 0, kPacketV5Magic);
    WriteU32(&packet, 4, sequence_++);
    WriteU32(&packet, 8, static_cast<uint32_t>(sample_rate));
    WriteU16(&packet, 12, static_cast<uint16_t>(profile_.channels));
    WriteU16(&packet, 14, muted ? kPacketFlagMuted : 0);
    WriteU16(&packet, 16, kCodecPcm);
    WriteU16(&packet, 18, packet_kind);
    WriteU32(&packet, 20, static_cast<uint32_t>(frame_count));
    WriteU64(&packet, 24, static_cast<uint64_t>(NowMillis()));
    WriteU64(&packet, 32, 0);
    WriteU64(&packet, 40, 0);
    WriteU32(&packet, 48, static_cast<uint32_t>(profile_.playback_buffer_ms));
    WriteU32(&packet, 52, 1);
    WriteU64(&packet, 56, session_id);
    if (samples != nullptr && payload_bytes > 0) {
      std::memcpy(packet.data() + kPacketV5HeaderBytes, samples, payload_bytes);
    }
    return packet;
  }

  void ReceiverLoop() {
    std::array<uint8_t, 1500> buffer = {};
    int64_t last_subscribe_at = 0;
    while (playback_running_) {
      const int64_t now = NowMillis();
      if (now - last_subscribe_at >= kSubscribeIntervalMs) {
        SendSubscribe();
        last_subscribe_at = now;
      }
      sockaddr_in remote = {};
      socklen_t remote_size = sizeof(remote);
      const ssize_t received = recvfrom(
          receiver_socket_, buffer.data(), buffer.size(), 0,
          reinterpret_cast<sockaddr*>(&remote), &remote_size);
      if (received <= 0) {
        continue;
      }
      HandlePlaybackPacket(buffer.data(), static_cast<size_t>(received));
    }
  }

  void SendSubscribe() {
    sockaddr_in source = {};
    {
      std::scoped_lock lock(source_mutex_);
      if (!receiver_source_available_) {
        return;
      }
      source = receiver_source_;
    }
    const int rate = std::max(active_sample_rate_.load(), 1);
    const int64_t queued = playback_queue_frames_.load();
    std::string message = "ABR_SUBSCRIBE v1 protocol=5 sessionId=" +
                          std::to_string(receiver_session_id_.load()) +
                          " platform=linux supportedCodecs=pcm receiverTimeMs=" +
                          std::to_string(NowMillis()) +
                          " outputLatencyMs=" +
                          std::to_string(static_cast<double>(queued) * 1000.0 / rate) +
                          " queuedFrames=" + std::to_string(queued) +
                          " bufferSizeFrames=" +
                          std::to_string(target_buffer_frames_.load()) +
                          " targetBufferFrames=" +
                          std::to_string(target_buffer_frames_.load()) +
                          " underrunCount=" +
                          std::to_string(underrun_count_.load()) +
                          " droppedPacketCount=" +
                          std::to_string(dropped_packet_count_.load()) +
                          " lostPacketCount=" +
                          std::to_string(lost_packet_count_.load()) +
                          " trimCount=" + std::to_string(trim_count_.load()) +
                          " signalLevel=" + std::to_string(signal_level_.load());
    sendto(receiver_socket_, message.data(), message.size(), 0,
           reinterpret_cast<const sockaddr*>(&source), sizeof(source));
  }

  void HandlePlaybackPacket(const uint8_t* data, size_t length) {
    if (length < static_cast<size_t>(kPacketV5HeaderBytes) ||
        ReadU32(data) != kPacketV5Magic) {
      ++dropped_packet_count_;
      return;
    }
    const uint64_t session_id = ReadU64(data + 56);
    if (session_id != receiver_session_id_.load()) {
      ++dropped_packet_count_;
      return;
    }
    last_peer_seen_at_ms_ = NowMillis();
    const uint16_t codec = ReadU16(data + 16);
    const uint16_t packet_kind = ReadU16(data + 18);
    if (packet_kind == kPacketKindHeartbeat) {
      return;
    }
    const int sample_rate = static_cast<int>(ReadU32(data + 8));
    const int channels = static_cast<int>(ReadU16(data + 12));
    const uint16_t flags = ReadU16(data + 14);
    if (codec != kCodecPcm || packet_kind != kPacketKindAudio ||
        sample_rate < 8000 || sample_rate > 96000 || channels < 1 ||
        channels > 2 || length <= static_cast<size_t>(kPacketV5HeaderBytes)) {
      ++dropped_packet_count_;
      return;
    }
    const size_t payload_bytes = length - kPacketV5HeaderBytes;
    const size_t bytes_per_frame = channels * sizeof(int16_t);
    if (payload_bytes % bytes_per_frame != 0) {
      ++dropped_packet_count_;
      return;
    }
    const int frame_count = static_cast<int>(payload_bytes / bytes_per_frame);
    if (frame_count <= 0) {
      ++dropped_packet_count_;
      return;
    }
    if (last_sequence_ >= 0) {
      const uint32_t sequence = ReadU32(data + 4);
      const uint32_t expected = static_cast<uint32_t>(last_sequence_ + 1);
      if (sequence != expected && sequence > expected) {
        lost_packet_count_ += sequence - expected;
      }
      last_sequence_ = sequence;
    } else {
      last_sequence_ = ReadU32(data + 4);
    }

    PcmPacket packet;
    packet.sample_rate = sample_rate;
    packet.channels = channels;
    packet.samples.resize(static_cast<size_t>(frame_count) * channels);
    std::memcpy(packet.samples.data(), data + kPacketV5HeaderBytes,
                payload_bytes);
    if ((flags & kPacketFlagMuted) != 0 || muted_.load()) {
      std::fill(packet.samples.begin(), packet.samples.end(), int16_t{0});
    }
    active_sample_rate_ = sample_rate;
    playback_buffer_ms_ = std::clamp<int>(
        static_cast<int>(ReadU32(data + 48)), 5, 500);
    const int64_t target =
        static_cast<int64_t>(sample_rate) * playback_buffer_ms_.load() / 1000;
    target_buffer_frames_ = std::max<int64_t>(1, target);
    PublishSignalLevel(packet.samples.data(), static_cast<int>(packet.samples.size()),
                       false);

    {
      std::scoped_lock lock(playback_queue_mutex_);
      playback_queue_frames_ += frame_count;
      const int64_t queue_limit =
          std::max<int64_t>(target_buffer_frames_.load() * 4, frame_count * 2);
      while (!playback_queue_.empty() && playback_queue_frames_ > queue_limit) {
        playback_queue_frames_ -= static_cast<int64_t>(
            playback_queue_.front().samples.size() /
            playback_queue_.front().channels);
        playback_queue_.pop_front();
        ++trim_count_;
      }
      playback_queue_.push_back(std::move(packet));
    }
    playback_queue_cv_.notify_one();
  }

  void PlaybackLoop() {
    void* playback = nullptr;
    int configured_rate = 0;
    int configured_channels = 0;
    bool render_started = false;

    while (playback_running_) {
      PcmPacket packet;
      {
        std::unique_lock lock(playback_queue_mutex_);
        playback_queue_cv_.wait_for(lock, std::chrono::milliseconds(100), [this] {
          return !playback_running_ || !playback_queue_.empty();
        });
        if (!playback_running_) {
          break;
        }
        if (!render_started &&
            playback_queue_frames_.load() < target_buffer_frames_.load()) {
          continue;
        }
        if (playback_queue_.empty()) {
          render_started = false;
          continue;
        }
        packet = std::move(playback_queue_.front());
        playback_queue_.pop_front();
        playback_queue_frames_ -= static_cast<int64_t>(
            packet.samples.size() / packet.channels);
        render_started = true;
      }

      if (playback == nullptr || configured_rate != packet.sample_rate ||
          configured_channels != packet.channels) {
        if (playback != nullptr) {
          alsa_.Close(playback);
          playback = nullptr;
        }
        if (alsa_.Open(&playback, kSndPcmStreamPlayback) < 0 ||
            alsa_.Configure(playback, packet.channels, packet.sample_rate,
                            playback_buffer_ms_.load()) < 0) {
          if (playback != nullptr) {
            alsa_.Close(playback);
            playback = nullptr;
          }
          ++dropped_packet_count_;
          continue;
        }
        configured_rate = packet.sample_rate;
        configured_channels = packet.channels;
      }

      const bool muted = muted_.load();
      const double volume = muted ? 0.0 : volume_.load();
      if (volume != 1.0) {
        for (int16_t& sample : packet.samples) {
          sample = static_cast<int16_t>(std::clamp(
              static_cast<int>(std::lround(sample * volume)), -32768, 32767));
        }
      }
      size_t offset_frames = 0;
      const size_t total_frames = packet.samples.size() / packet.channels;
      while (playback_running_ && offset_frames < total_frames) {
        const long written = alsa_.Write(
            playback, packet.samples.data() + offset_frames * packet.channels,
            total_frames - offset_frames);
        if (written < 0) {
          alsa_.Recover(playback, static_cast<int>(written));
          ++underrun_count_;
          break;
        }
        if (written == 0) {
          break;
        }
        offset_frames += static_cast<size_t>(written);
      }
    }
    if (playback != nullptr) {
      alsa_.Close(playback);
    }
  }

  void PublishSignalLevel(const int16_t* samples, int count, bool muted) {
    if (samples == nullptr || count <= 0 || muted) {
      signal_level_ = 0.0;
      return;
    }
    int peak = 0;
    for (int index = 0; index < count; ++index) {
      peak = std::max(peak, std::abs(static_cast<int>(samples[index])));
    }
    signal_level_ = static_cast<double>(peak) / 32768.0;
  }

  uint64_t NextSessionId() {
    static std::atomic<uint64_t> counter{1};
    return (static_cast<uint64_t>(NowMillis()) << 16) ^ counter.fetch_add(1);
  }

  AlsaApi alsa_;
  Profile profile_;
  std::atomic<Role> role_{Role::kReceiver};
  std::atomic_bool capture_running_{false};
  std::atomic_bool playback_running_{false};
  std::atomic_bool control_running_{false};
  std::atomic_bool muted_{false};
  std::atomic<double> volume_{0.86};
  std::atomic<double> signal_level_{0.0};
  std::atomic<int> active_sample_rate_{48000};
  std::atomic<int> playback_buffer_ms_{35};
  std::atomic<int64_t> target_buffer_frames_{0};
  std::atomic<int64_t> playback_queue_frames_{0};
  std::atomic<int64_t> underrun_count_{0};
  std::atomic<int64_t> dropped_packet_count_{0};
  std::atomic<int64_t> lost_packet_count_{0};
  std::atomic<int64_t> trim_count_{0};
  std::atomic<int64_t> last_peer_seen_at_ms_{0};
  std::atomic<int64_t> last_heartbeat_sent_at_ms_{0};
  std::atomic<uint64_t> receiver_session_id_{0};
  std::atomic<uint32_t> sequence_{0};
  int64_t last_sequence_ = -1;

  int sender_socket_ = -1;
  int receiver_socket_ = -1;
  std::thread control_thread_;
  std::thread capture_thread_;
  std::thread receive_thread_;
  std::thread playback_thread_;

  std::mutex endpoint_mutex_;
  sockaddr_in sender_endpoint_ = {};
  bool sender_endpoint_available_ = false;
  uint64_t sender_session_id_ = 0;

  std::mutex source_mutex_;
  sockaddr_in receiver_source_ = {};
  bool receiver_source_available_ = false;

  std::mutex playback_queue_mutex_;
  std::condition_variable playback_queue_cv_;
  std::deque<PcmPacket> playback_queue_;

  mutable std::mutex remote_capabilities_mutex_;
  std::string remote_platform_;
};

LinuxAudioEngine::LinuxAudioEngine() : impl_(std::make_unique<Impl>()) {}

LinuxAudioEngine::~LinuxAudioEngine() = default;

FlValue* LinuxAudioEngine::GetCapabilities() const {
  return impl_->GetCapabilities();
}

FlValue* LinuxAudioEngine::GetMetrics() const { return impl_->GetMetrics(); }

std::optional<std::string> LinuxAudioEngine::PrepareSender(FlValue* arguments) {
  return impl_->PrepareSender(arguments);
}

std::optional<std::string> LinuxAudioEngine::PrepareReceiver(
    FlValue* arguments) {
  return impl_->PrepareReceiver(arguments);
}

std::optional<std::string> LinuxAudioEngine::ConnectToSender(
    FlValue* arguments) {
  return impl_->ConnectToSender(arguments);
}

std::optional<std::string> LinuxAudioEngine::StartStream(FlValue* arguments) {
  return impl_->StartStream(arguments);
}

std::optional<std::string> LinuxAudioEngine::PrepareUsbSender(
    FlValue* arguments) {
  return impl_->PrepareUsbSender(arguments);
}

std::optional<std::string> LinuxAudioEngine::PrepareUsbReceiver(
    FlValue* arguments) {
  return impl_->PrepareUsbReceiver(arguments);
}

void LinuxAudioEngine::StopStream() { impl_->StopStream(); }

void LinuxAudioEngine::SetVolume(FlValue* arguments) {
  impl_->SetVolume(arguments);
}

void LinuxAudioEngine::SetMuted(FlValue* arguments) { impl_->SetMuted(arguments); }

void LinuxAudioEngine::Disconnect() { impl_->Disconnect(); }
