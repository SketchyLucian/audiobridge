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

struct DecoderHandle {
  OpusDecoder* decoder = nullptr;
  int channels = 0;
};

DecoderHandle* ToHandle(jlong value) {
  return reinterpret_cast<DecoderHandle*>(value);
}

}  // namespace

extern "C" JNIEXPORT jlong JNICALL
Java_com_example_audiorelay_1clone_OpusNative_createDecoder(JNIEnv*, jobject,
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
Java_com_example_audiorelay_1clone_OpusNative_decode(JNIEnv* env, jobject,
                                                     jlong handle_value,
                                                     jbyteArray input,
                                                     jint offset,
                                                     jint size) {
  DecoderHandle* handle = ToHandle(handle_value);
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
Java_com_example_audiorelay_1clone_OpusNative_destroyDecoder(JNIEnv*, jobject,
                                                             jlong handle_value) {
  DecoderHandle* handle = ToHandle(handle_value);
  if (handle == nullptr) {
    return;
  }
  if (handle->decoder != nullptr) {
    opus_decoder_destroy(handle->decoder);
  }
  delete handle;
}
