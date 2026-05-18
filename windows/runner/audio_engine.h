#ifndef RUNNER_AUDIO_ENGINE_H_
#define RUNNER_AUDIO_ENGINE_H_

#include <flutter/encodable_value.h>

#include <memory>
#include <optional>
#include <string>

class WindowsAudioEngine {
 public:
  WindowsAudioEngine();
  ~WindowsAudioEngine();

  flutter::EncodableMap GetCapabilities() const;
  flutter::EncodableList GetSoundboardOutputDevices() const;
  flutter::EncodableList GetNetworkInterfaces() const;
  flutter::EncodableMap GetMetrics() const;
  std::optional<std::string> PrepareSender(
      const flutter::EncodableValue* arguments);
  std::optional<std::string> PrepareUsbSender(
      const flutter::EncodableValue* arguments);
  std::optional<std::string> PrepareUsbReceiver(
      const flutter::EncodableValue* arguments);
  std::optional<std::string> PrepareReceiver(
      const flutter::EncodableValue* arguments);
  std::optional<std::string> ConnectToSender(
      const flutter::EncodableValue* arguments);
  std::optional<std::string> StartStream(const flutter::EncodableValue* arguments);
  void StopStream();
  void SetVolume(const flutter::EncodableValue* arguments);
  void SetMuted(const flutter::EncodableValue* arguments);
  std::optional<std::string> PlaySoundEffect(
      const flutter::EncodableValue* arguments);
  std::optional<std::string> ConfigureVirtualMicPassthrough(
      const flutter::EncodableValue* arguments);
  void StopSoundEffects();
  void Disconnect();

 private:
  class Impl;
  std::unique_ptr<Impl> impl_;
};

#endif  // RUNNER_AUDIO_ENGINE_H_
