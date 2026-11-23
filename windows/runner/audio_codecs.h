#ifndef RUNNER_AUDIO_CODECS_H_
#define RUNNER_AUDIO_CODECS_H_

#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <objbase.h>
#include <wrl/client.h>

#include "opus.h"

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <cstring>
#include <mutex>
#include <vector>

namespace audiobridge_codecs {

constexpr uint16_t kCodecPcm = 0;
constexpr uint16_t kCodecOpus = 1;
constexpr uint16_t kCodecAac = 2;
constexpr uint16_t kCodecG711MuLaw = 8;
constexpr uint16_t kCodecG711ALaw = 9;
constexpr uint16_t kCodecImaAdpcm = 10;

constexpr uint16_t kPacketKindAudio = 0;
constexpr uint16_t kPacketKindHeartbeat = 1;
constexpr uint16_t kPacketFlagMuted = 1;

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

struct EncodedAudioPacket {
  std::vector<uint8_t> payload;
  uint16_t codec_id = kCodecPcm;
  uint16_t packet_kind = kPacketKindAudio;
  uint16_t flags = 0;
  uint32_t decoded_frame_count = 0;
};

inline int OpusFrameSamplesForPacketTime(int packet_time_ms) {
  if (packet_time_ms <= 2) {
    return kOpusLowFrameSamples;
  }
  return packet_time_ms <= kOpusShortFrameMs ? kOpusShortFrameSamples
                                             : kOpusLongFrameSamples;
}

inline bool IsSupportedOpusFrameSamples(int frame_samples) {
  return frame_samples == kOpusLowFrameSamples ||
         frame_samples == kOpusShortFrameSamples ||
         frame_samples == kOpusLongFrameSamples;
}

inline uint8_t LinearToMuLaw(int16_t sample) {
  constexpr int kBias = 0x84;
  constexpr int kClip = 32635;
  int value = sample;
  const int sign = (value >> 8) & 0x80;
  if (sign != 0) {
    value = -value;
  }
  value = std::min(value, kClip) + kBias;

  int exponent = 7;
  for (int mask = 0x4000; (value & mask) == 0 && exponent > 0; mask >>= 1) {
    --exponent;
  }
  const int mantissa = (value >> (exponent + 3)) & 0x0F;
  return static_cast<uint8_t>(~(sign | (exponent << 4) | mantissa));
}

inline uint8_t LinearToALaw(int16_t sample) {
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

inline uint8_t EncodeImaNibble(int16_t sample, ImaAdpcmChannelState& state) {
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
  void EncodeInto(const int16_t* pcm, size_t sample_count, int channels,
                  bool muted, EncodedAudioPacket* out) const {
    out->codec_id = kCodecPcm;
    out->packet_kind = kPacketKindAudio;
    out->flags = muted ? kPacketFlagMuted : 0;
    out->decoded_frame_count =
        channels <= 0 ? 0 : static_cast<uint32_t>(sample_count / channels);
    const size_t bytes = sample_count * sizeof(int16_t);
    out->payload.resize(bytes);
    if (bytes > 0) {
      if (muted) {
        std::memset(out->payload.data(), 0, bytes);
      } else {
        std::memcpy(out->payload.data(), pcm, bytes);
      }
    }
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
    output_type->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, clamped_sample_rate);
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
    input_type->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, clamped_sample_rate);
    input_type->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, clamped_channels);
    input_type->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
    input_type->SetUINT32(MF_MT_AUDIO_BLOCK_ALIGNMENT,
                          clamped_channels * sizeof(int16_t));
    input_type->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND,
                          clamped_sample_rate * clamped_channels *
                              static_cast<int>(sizeof(int16_t)));

    Microsoft::WRL::ComPtr<IMFByteStream> byte_stream;
    hr = MFCreateMFByteStreamOnStreamEx(static_cast<IStream*>(&stream_),
                                        &byte_stream);
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
    stream_.Clear();
    return true;
  }

  void EncodeInto(const int16_t* pcm, size_t sample_count, int /*channels*/,
                  bool muted, EncodedAudioPacket* out) {
    out->codec_id = kCodecAac;
    out->packet_kind = kPacketKindAudio;
    out->flags = muted ? kPacketFlagMuted : 0;
    out->decoded_frame_count = 0;
    out->payload.clear();
    if (writer_ == nullptr || sample_count == 0) {
      return;
    }

    const size_t bytes = sample_count * sizeof(int16_t);
    Microsoft::WRL::ComPtr<IMFMediaBuffer> buffer;
    HRESULT hr = MFCreateMemoryBuffer(static_cast<DWORD>(bytes), &buffer);
    if (FAILED(hr)) {
      return;
    }

    BYTE* output = nullptr;
    hr = buffer->Lock(&output, nullptr, nullptr);
    if (FAILED(hr)) {
      return;
    }
    if (muted) {
      std::memset(output, 0, bytes);
    } else {
      std::memcpy(output, pcm, bytes);
    }
    buffer->Unlock();
    buffer->SetCurrentLength(static_cast<DWORD>(bytes));

    Microsoft::WRL::ComPtr<IMFSample> sample;
    hr = MFCreateSample(&sample);
    if (FAILED(hr)) {
      return;
    }
    sample->AddBuffer(buffer.Get());

    const int frame_count =
        channels_ <= 0 ? 0 : static_cast<int>(sample_count) / channels_;
    sample->SetSampleTime(written_frames_ * 10000000LL / sample_rate_);
    sample->SetSampleDuration(frame_count * 10000000LL / sample_rate_);
    written_frames_ += frame_count;

    hr = writer_->WriteSample(stream_index_, sample.Get());
    if (FAILED(hr)) {
      Shutdown();
      return;
    }

    stream_.DrainInto(&out->payload);
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
    stream_.Clear();
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
      const size_t available =
          position_ < storage_.size() ? storage_.size() - position_ : 0;
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
        const size_t available =
            position_ < storage_.size() ? storage_.size() - position_ : 0;
        const size_t count =
            static_cast<size_t>(std::min<uint64_t>(bytes.QuadPart, available));
        copy.assign(storage_.begin() + position_,
                    storage_.begin() + position_ + count);
        position_ += count;
      }

      ULONG written = 0;
      const HRESULT hr = target->Write(
          copy.data(), static_cast<ULONG>(copy.size()), &written);
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

    void DrainInto(std::vector<uint8_t>* out) {
      std::scoped_lock lock(mutex_);
      out->clear();
      if (read_offset_ < storage_.size()) {
        out->assign(storage_.begin() + read_offset_, storage_.end());
        read_offset_ = storage_.size();
        // Compact once read_offset_ catches up so memory never grows unbounded.
        if (read_offset_ >= 65536 && position_ == storage_.size()) {
          storage_.clear();
          position_ = 0;
          read_offset_ = 0;
        }
      }
    }

    void Clear() {
      std::scoped_lock lock(mutex_);
      storage_.clear();
      position_ = 0;
      read_offset_ = 0;
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

  void EncodeInto(const int16_t* pcm, size_t sample_count, int channels,
                  int frame_samples, bool muted, EncodedAudioPacket* out) {
    out->codec_id = kCodecOpus;
    out->packet_kind = kPacketKindAudio;
    out->flags = muted ? kPacketFlagMuted : 0;
    out->decoded_frame_count =
        channels <= 0 ? 0 : static_cast<uint32_t>(sample_count / channels);
    out->payload.clear();
    const int expected_samples = IsSupportedOpusFrameSamples(frame_samples)
                                     ? frame_samples
                                     : kOpusShortFrameSamples;
    if (encoder_ == nullptr || sample_count == 0 ||
        out->decoded_frame_count != static_cast<uint32_t>(expected_samples)) {
      return;
    }

    const int16_t* input_ptr = pcm;
    if (muted) {
      if (silence_buffer_.size() < sample_count) {
        silence_buffer_.assign(sample_count, 0);
      }
      input_ptr = silence_buffer_.data();
    }

    out->payload.resize(kOpusMaxPacketBytes);
    const int encoded_bytes = opus_encode(
        encoder_, input_ptr, expected_samples, out->payload.data(),
        static_cast<opus_int32>(out->payload.size()));
    if (encoded_bytes <= 0) {
      out->payload.clear();
      return;
    }
    out->payload.resize(static_cast<size_t>(encoded_bytes));
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
  std::vector<int16_t> silence_buffer_;
};

class G711CodecAdapter {
 public:
  explicit G711CodecAdapter(bool mu_law) : mu_law_(mu_law) {}

  void EncodeInto(const int16_t* pcm, size_t sample_count, int channels,
                  bool muted, EncodedAudioPacket* out) const {
    out->codec_id = mu_law_ ? kCodecG711MuLaw : kCodecG711ALaw;
    out->packet_kind = kPacketKindAudio;
    out->flags = muted ? kPacketFlagMuted : 0;
    out->decoded_frame_count =
        channels <= 0 ? 0 : static_cast<uint32_t>(sample_count / channels);
    out->payload.resize(sample_count);
    for (size_t index = 0; index < sample_count; ++index) {
      const int16_t sample = muted ? 0 : pcm[index];
      out->payload[index] =
          mu_law_ ? LinearToMuLaw(sample) : LinearToALaw(sample);
    }
  }

 private:
  bool mu_law_;
};

class ImaAdpcmCodecAdapter {
 public:
  void EncodeInto(const int16_t* pcm, size_t sample_count, int channels,
                  bool muted, EncodedAudioPacket* out) {
    out->codec_id = kCodecImaAdpcm;
    out->packet_kind = kPacketKindAudio;
    out->flags = muted ? kPacketFlagMuted : 0;
    out->decoded_frame_count =
        channels <= 0 ? 0 : static_cast<uint32_t>(sample_count / channels);
    out->payload.clear();
    if (sample_count == 0) {
      return;
    }

    const int channel_count = std::max(1, channels);
    states_.resize(static_cast<size_t>(channel_count));
    for (int channel = 0; channel < channel_count; ++channel) {
      const size_t sample_index = static_cast<size_t>(channel);
      states_[channel].predictor =
          sample_index < sample_count && !muted ? pcm[sample_index] : 0;
      states_[channel].step_index = 0;
    }

    uint8_t pending_nibble = 0;
    bool has_pending_nibble = false;
    out->payload.reserve(static_cast<size_t>(channel_count) * 4 +
                         (sample_count + 1) / 2);
    for (const auto& state : states_) {
      out->payload.push_back(static_cast<uint8_t>(state.predictor & 0xFF));
      out->payload.push_back(
          static_cast<uint8_t>((state.predictor >> 8) & 0xFF));
      out->payload.push_back(static_cast<uint8_t>(state.step_index));
      out->payload.push_back(0);
    }
    for (size_t index = 0; index < sample_count; ++index) {
      const int channel = static_cast<int>(index % channel_count);
      const uint8_t nibble =
          EncodeImaNibble(muted ? 0 : pcm[index], states_[channel]);
      if (!has_pending_nibble) {
        pending_nibble = nibble;
        has_pending_nibble = true;
      } else {
        out->payload.push_back(
            static_cast<uint8_t>(pending_nibble | (nibble << 4)));
        has_pending_nibble = false;
      }
    }
    if (has_pending_nibble) {
      out->payload.push_back(pending_nibble);
    }
  }

 private:
  std::vector<ImaAdpcmChannelState> states_;
};

}  // namespace audiobridge_codecs

#endif  // RUNNER_AUDIO_CODECS_H_
