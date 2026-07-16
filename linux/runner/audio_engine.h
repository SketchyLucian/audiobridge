#ifndef RUNNER_AUDIO_ENGINE_H_
#define RUNNER_AUDIO_ENGINE_H_

#include <flutter_linux/flutter_linux.h>

#include <memory>
#include <optional>
#include <string>

class LinuxAudioEngine {
 public:
  LinuxAudioEngine();
  ~LinuxAudioEngine();

  FlValue* GetCapabilities() const;
  FlValue* GetMetrics() const;
  std::optional<std::string> PrepareSender(FlValue* arguments);
  std::optional<std::string> PrepareReceiver(FlValue* arguments);
  std::optional<std::string> ConnectToSender(FlValue* arguments);
  std::optional<std::string> StartStream(FlValue* arguments);
  std::optional<std::string> PrepareUsbSender(FlValue* arguments);
  std::optional<std::string> PrepareUsbReceiver(FlValue* arguments);
  void StopStream();
  void SetVolume(FlValue* arguments);
  void SetMuted(FlValue* arguments);
  void Disconnect();

 private:
  class Impl;
  std::unique_ptr<Impl> impl_;
};

#endif  // RUNNER_AUDIO_ENGINE_H_
