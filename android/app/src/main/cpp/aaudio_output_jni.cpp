#include <jni.h>
#include <android/log.h>
#include <dlfcn.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <vector>

namespace {

constexpr const char* kLogTag = "AudioBridgeAAudio";

using AAudioStream = struct AAudioStreamStruct;
using AAudioStreamBuilder = struct AAudioStreamBuilderStruct;
using aaudio_result_t = int32_t;
using aaudio_direction_t = int32_t;
using aaudio_format_t = int32_t;
using aaudio_sharing_mode_t = int32_t;
using aaudio_performance_mode_t = int32_t;
using aaudio_usage_t = int32_t;
using aaudio_content_type_t = int32_t;
using aaudio_stream_state_t = int32_t;

constexpr aaudio_result_t kAAudioOk = 0;
constexpr aaudio_direction_t kAAudioDirectionOutput = 0;
constexpr aaudio_format_t kAAudioFormatPcmI16 = 1;
constexpr aaudio_sharing_mode_t kAAudioSharingModeShared = 1;
constexpr aaudio_performance_mode_t kAAudioPerformanceModeNone = 10;
constexpr aaudio_performance_mode_t kAAudioPerformanceModeLowLatency = 12;
constexpr aaudio_usage_t kAAudioUsageMedia = 1;
constexpr aaudio_content_type_t kAAudioContentTypeMusic = 2;
constexpr aaudio_stream_state_t kAAudioStreamStateStarted = 4;

struct AAudioApi {
  void* lib = nullptr;
  bool loaded = false;

  aaudio_result_t (*createStreamBuilder)(AAudioStreamBuilder**) = nullptr;
  aaudio_result_t (*builderDelete)(AAudioStreamBuilder*) = nullptr;
  void (*builderSetDirection)(AAudioStreamBuilder*, aaudio_direction_t) = nullptr;
  void (*builderSetSampleRate)(AAudioStreamBuilder*, int32_t) = nullptr;
  void (*builderSetChannelCount)(AAudioStreamBuilder*, int32_t) = nullptr;
  void (*builderSetFormat)(AAudioStreamBuilder*, aaudio_format_t) = nullptr;
  void (*builderSetSharingMode)(AAudioStreamBuilder*, aaudio_sharing_mode_t) = nullptr;
  void (*builderSetPerformanceMode)(AAudioStreamBuilder*, aaudio_performance_mode_t) = nullptr;
  void (*builderSetBufferCapacityInFrames)(AAudioStreamBuilder*, int32_t) = nullptr;
  void (*builderSetUsage)(AAudioStreamBuilder*, aaudio_usage_t) = nullptr;
  void (*builderSetContentType)(AAudioStreamBuilder*, aaudio_content_type_t) = nullptr;
  aaudio_result_t (*builderOpenStream)(AAudioStreamBuilder*, AAudioStream**) = nullptr;

  aaudio_result_t (*streamClose)(AAudioStream*) = nullptr;
  aaudio_result_t (*streamRequestStart)(AAudioStream*) = nullptr;
  aaudio_result_t (*streamRequestPause)(AAudioStream*) = nullptr;
  aaudio_result_t (*streamRequestFlush)(AAudioStream*) = nullptr;
  aaudio_result_t (*streamRequestStop)(AAudioStream*) = nullptr;
  aaudio_stream_state_t (*streamGetState)(AAudioStream*) = nullptr;
  aaudio_result_t (*streamWrite)(AAudioStream*, const void*, int32_t, int64_t) = nullptr;
  aaudio_result_t (*streamSetBufferSizeInFrames)(AAudioStream*, int32_t) = nullptr;
  int32_t (*streamGetBufferCapacityInFrames)(AAudioStream*) = nullptr;
  int32_t (*streamGetFramesPerBurst)(AAudioStream*) = nullptr;
  int64_t (*streamGetFramesRead)(AAudioStream*) = nullptr;
  int32_t (*streamGetXRunCount)(AAudioStream*) = nullptr;
};

template <typename Fn>
bool LoadSym(void* lib, const char* name, Fn* out) {
  *out = reinterpret_cast<Fn>(dlsym(lib, name));
  return *out != nullptr;
}

const AAudioApi& GetAAudioApi() {
  static AAudioApi api = []() {
    AAudioApi result;
    result.lib = dlopen("libaaudio.so", RTLD_NOW);
    if (result.lib == nullptr) {
      return result;
    }

    const bool ok =
        LoadSym(result.lib, "AAudio_createStreamBuilder", &result.createStreamBuilder) &&
        LoadSym(result.lib, "AAudioStreamBuilder_delete", &result.builderDelete) &&
        LoadSym(result.lib, "AAudioStreamBuilder_setDirection", &result.builderSetDirection) &&
        LoadSym(result.lib, "AAudioStreamBuilder_setSampleRate", &result.builderSetSampleRate) &&
        LoadSym(result.lib, "AAudioStreamBuilder_setChannelCount", &result.builderSetChannelCount) &&
        LoadSym(result.lib, "AAudioStreamBuilder_setFormat", &result.builderSetFormat) &&
        LoadSym(result.lib, "AAudioStreamBuilder_setSharingMode", &result.builderSetSharingMode) &&
        LoadSym(result.lib, "AAudioStreamBuilder_setPerformanceMode", &result.builderSetPerformanceMode) &&
        LoadSym(result.lib, "AAudioStreamBuilder_setBufferCapacityInFrames", &result.builderSetBufferCapacityInFrames) &&
        LoadSym(result.lib, "AAudioStreamBuilder_openStream", &result.builderOpenStream) &&
        LoadSym(result.lib, "AAudioStream_close", &result.streamClose) &&
        LoadSym(result.lib, "AAudioStream_requestStart", &result.streamRequestStart) &&
        LoadSym(result.lib, "AAudioStream_requestPause", &result.streamRequestPause) &&
        LoadSym(result.lib, "AAudioStream_requestFlush", &result.streamRequestFlush) &&
        LoadSym(result.lib, "AAudioStream_requestStop", &result.streamRequestStop) &&
        LoadSym(result.lib, "AAudioStream_getState", &result.streamGetState) &&
        LoadSym(result.lib, "AAudioStream_write", &result.streamWrite) &&
        LoadSym(result.lib, "AAudioStream_setBufferSizeInFrames", &result.streamSetBufferSizeInFrames) &&
        LoadSym(result.lib, "AAudioStream_getBufferCapacityInFrames", &result.streamGetBufferCapacityInFrames) &&
        LoadSym(result.lib, "AAudioStream_getFramesPerBurst", &result.streamGetFramesPerBurst) &&
        LoadSym(result.lib, "AAudioStream_getFramesRead", &result.streamGetFramesRead) &&
        LoadSym(result.lib, "AAudioStream_getXRunCount", &result.streamGetXRunCount);

    // Optional API 28+ attributes (usage / content type).
    LoadSym(result.lib, "AAudioStreamBuilder_setUsage", &result.builderSetUsage);
    LoadSym(result.lib, "AAudioStreamBuilder_setContentType", &result.builderSetContentType);

    result.loaded = ok;
    if (!ok) {
      dlclose(result.lib);
      result.lib = nullptr;
    }
    return result;
  }();
  return api;
}

struct AAudioOutputHolder {
  AAudioStream* stream = nullptr;
  int32_t sample_rate = 48000;
  int32_t channels = 2;
  std::atomic<float> gain{1.0f};
  std::vector<int16_t> scratch_pcm;
};

}  // namespace

extern "C" {

JNIEXPORT jboolean JNICALL
Java_com_audiobridge_app_AAudioOutputNative_isAvailable(
    JNIEnv* /*env*/,
    jobject /*thiz*/) {
  return GetAAudioApi().loaded ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT jlong JNICALL
Java_com_audiobridge_app_AAudioOutputNative_createStream(
    JNIEnv* /*env*/,
    jobject /*thiz*/,
    jint sample_rate,
    jint channels,
    jint capacity_frames,
    jint target_frames,
    jboolean low_latency) {
  const auto& api = GetAAudioApi();
  if (!api.loaded || sample_rate <= 0 || channels <= 0) {
    return 0;
  }

  AAudioStreamBuilder* builder = nullptr;
  if (api.createStreamBuilder(&builder) != kAAudioOk || builder == nullptr) {
    return 0;
  }

  const int32_t clamped_channels = std::clamp<int32_t>(channels, 1, 2);
  api.builderSetDirection(builder, kAAudioDirectionOutput);
  api.builderSetFormat(builder, kAAudioFormatPcmI16);
  api.builderSetSampleRate(builder, sample_rate);
  api.builderSetChannelCount(builder, clamped_channels);
  api.builderSetSharingMode(builder, kAAudioSharingModeShared);
  api.builderSetPerformanceMode(
      builder,
      low_latency == JNI_TRUE ? kAAudioPerformanceModeLowLatency
                              : kAAudioPerformanceModeNone);
  if (capacity_frames > 0) {
    api.builderSetBufferCapacityInFrames(builder, capacity_frames);
  }
  if (api.builderSetUsage != nullptr) {
    api.builderSetUsage(builder, kAAudioUsageMedia);
  }
  if (api.builderSetContentType != nullptr) {
    api.builderSetContentType(builder, kAAudioContentTypeMusic);
  }

  AAudioStream* stream = nullptr;
  const aaudio_result_t open_result = api.builderOpenStream(builder, &stream);
  api.builderDelete(builder);
  if (open_result != kAAudioOk || stream == nullptr) {
    __android_log_print(ANDROID_LOG_WARN, kLogTag,
                        "AAudio openStream failed result=%d sr=%d ch=%d",
                        open_result, sample_rate, clamped_channels);
    return 0;
  }

  const int32_t actual_capacity = api.streamGetBufferCapacityInFrames(stream);
  const int32_t frames_per_burst = std::max(1, api.streamGetFramesPerBurst(stream));
  if (target_frames > 0 && actual_capacity > 0) {
    const int32_t desired = std::clamp<int32_t>(
        target_frames, frames_per_burst, actual_capacity);
    api.streamSetBufferSizeInFrames(stream, desired);
  }

  auto* holder = new AAudioOutputHolder();
  holder->stream = stream;
  holder->sample_rate = sample_rate;
  holder->channels = clamped_channels;
  return reinterpret_cast<jlong>(holder);
}

JNIEXPORT jboolean JNICALL
Java_com_audiobridge_app_AAudioOutputNative_startStream(
    JNIEnv* /*env*/,
    jobject /*thiz*/,
    jlong handle) {
  const auto& api = GetAAudioApi();
  auto* holder = reinterpret_cast<AAudioOutputHolder*>(handle);
  if (!api.loaded || holder == nullptr || holder->stream == nullptr) {
    return JNI_FALSE;
  }
  return api.streamRequestStart(holder->stream) == kAAudioOk ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT jint JNICALL
Java_com_audiobridge_app_AAudioOutputNative_writePcm(
    JNIEnv* env,
    jobject /*thiz*/,
    jlong handle,
    jbyteArray data,
    jint offset,
    jint size_bytes,
    jboolean blocking) {
  const auto& api = GetAAudioApi();
  auto* holder = reinterpret_cast<AAudioOutputHolder*>(handle);
  if (!api.loaded || holder == nullptr || holder->stream == nullptr ||
      data == nullptr || offset < 0 || size_bytes <= 0) {
    return 0;
  }

  const jsize array_len = env->GetArrayLength(data);
  if (offset + size_bytes > array_len) {
    return 0;
  }

  const int32_t bytes_per_frame = holder->channels * 2;
  const int32_t frame_count = size_bytes / bytes_per_frame;
  if (frame_count <= 0) {
    return 0;
  }
  const int32_t sample_count = frame_count * holder->channels;
  const int32_t usable_bytes = frame_count * bytes_per_frame;

  holder->scratch_pcm.resize(static_cast<size_t>(sample_count));
  const float gain = std::clamp(holder->gain.load(std::memory_order_relaxed), 0.0f, 1.0f);
  if (gain <= 0.0001f) {
    std::memset(holder->scratch_pcm.data(), 0, static_cast<size_t>(usable_bytes));
  } else {
    env->GetByteArrayRegion(
        data, offset, usable_bytes,
        reinterpret_cast<jbyte*>(holder->scratch_pcm.data()));
    if (gain < 0.9995f) {
      for (int32_t i = 0; i < sample_count; ++i) {
        const float scaled =
            std::clamp(holder->scratch_pcm[i] * gain, -32768.0f, 32767.0f);
        holder->scratch_pcm[i] = static_cast<int16_t>(std::lrintf(scaled));
      }
    }
  }

  const int64_t timeout_ns = blocking == JNI_TRUE ? 20000000LL : 0LL;
  const aaudio_result_t written_frames = api.streamWrite(
      holder->stream, holder->scratch_pcm.data(), frame_count, timeout_ns);
  if (written_frames <= 0) {
    return written_frames;
  }
  return written_frames * bytes_per_frame;
}

JNIEXPORT jint JNICALL
Java_com_audiobridge_app_AAudioOutputNative_setBufferSizeInFrames(
    JNIEnv* /*env*/,
    jobject /*thiz*/,
    jlong handle,
    jint frames) {
  const auto& api = GetAAudioApi();
  auto* holder = reinterpret_cast<AAudioOutputHolder*>(handle);
  if (!api.loaded || holder == nullptr || holder->stream == nullptr || frames <= 0) {
    return 0;
  }
  return api.streamSetBufferSizeInFrames(holder->stream, frames);
}

JNIEXPORT jint JNICALL
Java_com_audiobridge_app_AAudioOutputNative_getBufferCapacityInFrames(
    JNIEnv* /*env*/,
    jobject /*thiz*/,
    jlong handle) {
  const auto& api = GetAAudioApi();
  auto* holder = reinterpret_cast<AAudioOutputHolder*>(handle);
  if (!api.loaded || holder == nullptr || holder->stream == nullptr) {
    return 0;
  }
  return api.streamGetBufferCapacityInFrames(holder->stream);
}

JNIEXPORT jlong JNICALL
Java_com_audiobridge_app_AAudioOutputNative_getFramesRead(
    JNIEnv* /*env*/,
    jobject /*thiz*/,
    jlong handle) {
  const auto& api = GetAAudioApi();
  auto* holder = reinterpret_cast<AAudioOutputHolder*>(handle);
  if (!api.loaded || holder == nullptr || holder->stream == nullptr) {
    return 0;
  }
  return api.streamGetFramesRead(holder->stream);
}

JNIEXPORT jint JNICALL
Java_com_audiobridge_app_AAudioOutputNative_getXRunCount(
    JNIEnv* /*env*/,
    jobject /*thiz*/,
    jlong handle) {
  const auto& api = GetAAudioApi();
  auto* holder = reinterpret_cast<AAudioOutputHolder*>(handle);
  if (!api.loaded || holder == nullptr || holder->stream == nullptr) {
    return 0;
  }
  return std::max(0, api.streamGetXRunCount(holder->stream));
}

JNIEXPORT jboolean JNICALL
Java_com_audiobridge_app_AAudioOutputNative_isPlaying(
    JNIEnv* /*env*/,
    jobject /*thiz*/,
    jlong handle) {
  const auto& api = GetAAudioApi();
  auto* holder = reinterpret_cast<AAudioOutputHolder*>(handle);
  if (!api.loaded || holder == nullptr || holder->stream == nullptr) {
    return JNI_FALSE;
  }
  return api.streamGetState(holder->stream) == kAAudioStreamStateStarted
             ? JNI_TRUE
             : JNI_FALSE;
}

JNIEXPORT void JNICALL
Java_com_audiobridge_app_AAudioOutputNative_setVolume(
    JNIEnv* /*env*/,
    jobject /*thiz*/,
    jlong handle,
    jfloat volume) {
  auto* holder = reinterpret_cast<AAudioOutputHolder*>(handle);
  if (holder != nullptr) {
    holder->gain.store(std::clamp(volume, 0.0f, 1.0f),
                       std::memory_order_relaxed);
  }
}

JNIEXPORT jboolean JNICALL
Java_com_audiobridge_app_AAudioOutputNative_flush(
    JNIEnv* /*env*/,
    jobject /*thiz*/,
    jlong handle) {
  const auto& api = GetAAudioApi();
  auto* holder = reinterpret_cast<AAudioOutputHolder*>(handle);
  if (!api.loaded || holder == nullptr || holder->stream == nullptr) {
    return JNI_FALSE;
  }
  api.streamRequestPause(holder->stream);
  api.streamRequestFlush(holder->stream);
  return api.streamRequestStart(holder->stream) == kAAudioOk ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT void JNICALL
Java_com_audiobridge_app_AAudioOutputNative_closeStream(
    JNIEnv* /*env*/,
    jobject /*thiz*/,
    jlong handle) {
  const auto& api = GetAAudioApi();
  auto* holder = reinterpret_cast<AAudioOutputHolder*>(handle);
  if (holder == nullptr) {
    return;
  }
  if (api.loaded && holder->stream != nullptr) {
    api.streamRequestStop(holder->stream);
    api.streamClose(holder->stream);
  }
  delete holder;
}

}  // extern "C"
