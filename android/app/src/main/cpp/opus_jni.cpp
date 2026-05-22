#include <jni.h>

#include <algorithm>
#include <cstdint>
#include <memory>
#include <vector>

#include "opus.h"

namespace {

constexpr int kOpusSampleRate = 48000;
constexpr int kMaxChannels = 2;
constexpr int kMaxFrameSamples = 5760;
constexpr int kOpusMaxPacketBytes = 4000;

struct DecoderHandle {
  OpusDecoder* decoder = nullptr;
  int channels = 0;
};

struct EncoderHandle {
  OpusEncoder* encoder = nullptr;
  int channels = 0;
};

DecoderHandle* ToDecoderHandle(jlong value) {
  return reinterpret_cast<DecoderHandle*>(value);
}

EncoderHandle* ToEncoderHandle(jlong value) {
  return reinterpret_cast<EncoderHandle*>(value);
}

}  // namespace

extern "C" JNIEXPORT jlong JNICALL
Java_com_audiobridge_app_OpusNative_createDecoder(JNIEnv*, jobject,
                                                  jint channels) {
  const int clamped_channels = std::clamp(static_cast<int>(channels), 1,
                                          kMaxChannels);
  int error = OPUS_OK;
  OpusDecoder* decoder =
      opus_decoder_create(kOpusSampleRate, clamped_channels, &error);
  if (error != OPUS_OK || decoder == nullptr) {
    return 0;
  }

  auto* handle = new DecoderHandle();
  handle->decoder = decoder;
  handle->channels = clamped_channels;
  return reinterpret_cast<jlong>(handle);
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_audiobridge_app_OpusNative_decode(JNIEnv* env, jobject,
                                           jlong handle_value,
                                           jbyteArray input,
                                           jint offset,
                                           jint size) {
  DecoderHandle* handle = ToDecoderHandle(handle_value);
  if (handle == nullptr || handle->decoder == nullptr || input == nullptr ||
      offset < 0 || size <= 0) {
    return nullptr;
  }

  const jsize input_size = env->GetArrayLength(input);
  if (offset + size > input_size) {
    return nullptr;
  }

  std::vector<uint8_t> encoded(static_cast<size_t>(size));
  env->GetByteArrayRegion(input, offset, size,
                          reinterpret_cast<jbyte*>(encoded.data()));
  if (env->ExceptionCheck()) {
    return nullptr;
  }

  std::vector<int16_t> pcm(kMaxFrameSamples * handle->channels);
  const int decoded_samples = opus_decode(
      handle->decoder, encoded.data(), size, pcm.data(), kMaxFrameSamples, 0);
  if (decoded_samples <= 0) {
    return nullptr;
  }

  const jsize output_bytes =
      static_cast<jsize>(decoded_samples * handle->channels * sizeof(int16_t));
  jbyteArray output = env->NewByteArray(output_bytes);
  if (output == nullptr) {
    return nullptr;
  }
  env->SetByteArrayRegion(output, 0, output_bytes,
                          reinterpret_cast<const jbyte*>(pcm.data()));
  return output;
}

extern "C" JNIEXPORT void JNICALL
Java_com_audiobridge_app_OpusNative_destroyDecoder(JNIEnv*, jobject,
                                                   jlong handle_value) {
  DecoderHandle* handle = ToDecoderHandle(handle_value);
  if (handle == nullptr) {
    return;
  }
  if (handle->decoder != nullptr) {
    opus_decoder_destroy(handle->decoder);
  }
  delete handle;
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_audiobridge_app_OpusNative_createEncoder(
    JNIEnv*, jobject, jint channels, jint bitrate_bps, jboolean low_delay) {
  const int clamped_channels = std::clamp(static_cast<int>(channels), 1,
                                          kMaxChannels);
  const int clamped_bitrate = std::clamp(static_cast<int>(bitrate_bps), 64000,
                                         256000);
  int error = OPUS_OK;
  OpusEncoder* encoder = opus_encoder_create(
      kOpusSampleRate, clamped_channels,
      low_delay ? OPUS_APPLICATION_RESTRICTED_LOWDELAY : OPUS_APPLICATION_AUDIO,
      &error);
  if (error != OPUS_OK || encoder == nullptr) {
    return 0;
  }

  opus_encoder_ctl(encoder, OPUS_SET_BITRATE(clamped_bitrate));
  opus_encoder_ctl(encoder, OPUS_SET_VBR(0));
  opus_encoder_ctl(encoder, OPUS_SET_COMPLEXITY(low_delay ? 4 : 5));
  opus_encoder_ctl(encoder, OPUS_SET_SIGNAL(OPUS_SIGNAL_MUSIC));
  opus_encoder_ctl(encoder, OPUS_SET_INBAND_FEC(0));
  opus_encoder_ctl(encoder, OPUS_SET_DTX(0));

  auto* handle = new EncoderHandle();
  handle->encoder = encoder;
  handle->channels = clamped_channels;
  return reinterpret_cast<jlong>(handle);
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_audiobridge_app_OpusNative_encode(JNIEnv* env, jobject,
                                           jlong handle_value,
                                           jshortArray input,
                                           jint frame_samples) {
  EncoderHandle* handle = ToEncoderHandle(handle_value);
  if (handle == nullptr || handle->encoder == nullptr || input == nullptr ||
      frame_samples <= 0 || frame_samples > kMaxFrameSamples) {
    return nullptr;
  }

  const jsize input_samples = env->GetArrayLength(input);
  const int required_samples = static_cast<int>(frame_samples) * handle->channels;
  if (input_samples != required_samples) {
    return nullptr;
  }

  std::vector<int16_t> pcm(static_cast<size_t>(input_samples));
  env->GetShortArrayRegion(input, 0, input_samples,
                           reinterpret_cast<jshort*>(pcm.data()));
  if (env->ExceptionCheck()) {
    return nullptr;
  }

  std::vector<uint8_t> encoded(kOpusMaxPacketBytes);
  const int encoded_bytes = opus_encode(
      handle->encoder, pcm.data(), static_cast<int>(frame_samples),
      encoded.data(), static_cast<opus_int32>(encoded.size()));
  if (encoded_bytes <= 0) {
    return nullptr;
  }

  jbyteArray output = env->NewByteArray(static_cast<jsize>(encoded_bytes));
  if (output == nullptr) {
    return nullptr;
  }
  env->SetByteArrayRegion(output, 0, static_cast<jsize>(encoded_bytes),
                          reinterpret_cast<const jbyte*>(encoded.data()));
  return output;
}

extern "C" JNIEXPORT void JNICALL
Java_com_audiobridge_app_OpusNative_destroyEncoder(JNIEnv*, jobject,
                                                   jlong handle_value) {
  EncoderHandle* handle = ToEncoderHandle(handle_value);
  if (handle == nullptr) {
    return;
  }
  if (handle->encoder != nullptr) {
    opus_encoder_destroy(handle->encoder);
  }
  delete handle;
}
