import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../data/audio_profile_store.dart';
import '../data/audio_relay_preferences_store.dart';
import '../data/discovery_service.dart';
import '../data/native_audio_engine.dart';
import '../data/update_platform.dart';
import '../data/update_service.dart';
import '../domain/audio_relay_models.dart';
import '../domain/update_models.dart';

enum _AdaptiveProfileApplyReason {
  settings,
  metrics,
  liveBufferPolicy,
  autoCodecSwitch,
  receiverCodecFallback,
  display,
}

class AudioRelayController extends ChangeNotifier {
  AudioRelayController({
    AudioRelayEngine? engine,
    DiscoveryService? discoveryService,
    AudioProfileStore? profileStore,
    AudioRelayPreferencesStore? preferencesStore,
    AppUpdateService? updateService,
    UpdateInstaller? updateInstaller,
    Future<String> Function()? appVersionProvider,
    AppUpdateTarget? updateTarget,
    bool checkForUpdatesOnInitialize = true,
    @visibleForTesting
    Duration profileApplyDelay = const Duration(milliseconds: 250),
    @visibleForTesting Duration autoCodecWarmup = const Duration(seconds: 60),
    @visibleForTesting Duration autoCodecQuietHold = const Duration(seconds: 3),
    @visibleForTesting
    Duration discoveryIdleTimeout = const Duration(minutes: 2),
    @visibleForTesting
    Duration streamConnectionTimeout = const Duration(minutes: 10),
    @visibleForTesting
    Duration receiverNoAudioTimeout = const Duration(minutes: 10),
    @visibleForTesting Duration sourceStaleTimeout = const Duration(seconds: 4),
    @visibleForTesting List<Duration> reconnectDelays = _defaultReconnectDelays,
    @visibleForTesting
    Duration preferencesSaveDelay = const Duration(milliseconds: 200),
  }) : _engine = engine ?? const MethodChannelAudioRelayEngine(),
       _discoveryService = discoveryService ?? DiscoveryService(),
       _profileStore =
           profileStore ?? const SharedPreferencesAudioProfileStore(),
       _preferencesStore =
           preferencesStore ??
           const SharedPreferencesAudioRelayPreferencesStore(),
       _updateService = updateService ?? CodebergUpdateService(),
       _updateInstaller =
           updateInstaller ?? const MethodChannelUpdateInstaller(),
       _appVersionProvider = appVersionProvider ?? _defaultAppVersion,
       _updateTarget = updateTarget ?? AppUpdateTarget.current(),
       _checkForUpdatesOnInitialize = checkForUpdatesOnInitialize,
       _profileApplyDelay = profileApplyDelay,
       _autoCodecWarmup = autoCodecWarmup,
       _autoCodecQuietHold = autoCodecQuietHold,
       _discoveryIdleTimeout = discoveryIdleTimeout,
       _streamConnectionTimeout = streamConnectionTimeout,
       _receiverNoAudioTimeout = receiverNoAudioTimeout,
       _sourceStaleTimeout = sourceStaleTimeout,
       _reconnectDelays = List<Duration>.unmodifiable(
         reconnectDelays.isEmpty ? _defaultReconnectDelays : reconnectDelays,
       ),
       _preferencesSaveDelay = preferencesSaveDelay,
       profile = AudioPreset.balanced.profile,
       role = _defaultRole(),
       localDeviceName = _defaultDeviceName();

  final AudioRelayEngine _engine;
  final DiscoveryService _discoveryService;
  final AudioProfileStore _profileStore;
  final AudioRelayPreferencesStore _preferencesStore;
  final AppUpdateService _updateService;
  final UpdateInstaller _updateInstaller;
  final Future<String> Function() _appVersionProvider;
  final AppUpdateTarget _updateTarget;
  final bool _checkForUpdatesOnInitialize;
  final Duration _profileApplyDelay;
  final Duration _autoCodecWarmup;
  final Duration _autoCodecQuietHold;
  final Duration _discoveryIdleTimeout;
  final Duration _streamConnectionTimeout;
  final Duration _receiverNoAudioTimeout;
  final Duration _sourceStaleTimeout;
  final List<Duration> _reconnectDelays;
  final Duration _preferencesSaveDelay;
  RelayRole role;
  RelayTransport transport = RelayTransport.wifi;
  RelayActivity activity = RelayActivity.idle;
  AudioProfile profile;
  OutputAudioBackend receiverOutputBackend = OutputAudioBackend.auto;
  AudioPreset selectedPreset = AudioPreset.balanced;
  PlatformAudioCapabilities capabilities = PlatformAudioCapabilities.fallback();
  AudioRelayMetrics metrics = AudioRelayMetrics.empty;
  List<RelayDevice> devices = const [];
  RelayDevice? selectedDevice;
  String localDeviceName;
  String localAddress = 'Detecting';
  String? errorMessage;
  String? noticeMessage;
  double volume = 0.86;
  double signalLevel = 0;
  bool muted = false;
  List<SoundPlaybackItem> soundboardItems = const [];
  SoundPlaybackItem? selectedSoundboardItem;
  SoundboardPlaybackTarget soundboardTarget = SoundboardPlaybackTarget.micRoute;
  String? selectedSoundboardOutputDeviceId;
  double soundboardVolume = 0.82;
  bool soundboardBusy = false;
  String? soundboardMessage;
  String appVersion = _fallbackAppVersion;
  AppUpdateStatus updateStatus = AppUpdateStatus.idle;
  AppUpdateRelease? availableUpdate;
  String? updateMessage;
  double? updateDownloadProgress;

  Timer? _meterTimer;
  Timer? _profileApplyTimer;
  Timer? _discoveryIdleTimer;
  Timer? _streamConnectionTimer;
  Timer? _reconnectTimer;
  Timer? _sourcePruneTimer;
  Timer? _preferencesSaveTimer;
  AudioProfile? _appliedSenderProfile;
  AudioCodec _autoResolvedCodec = AudioCodec.pcm;
  DateTime? _autoCodecStartedAt;
  DateTime? _autoCodecQuietSince;
  DateTime? _autoCodecLastSwitchAt;
  _AdaptiveMetricsSnapshot? _autoCodecBaseline;
  _AdaptiveMetricsSnapshot? _adaptiveFormatBaseline;
  int _adaptiveFormatPressureScoreValue = 0;
  int _adaptiveFormatQuietPolls = 0;
  bool _autoCodecApplyInFlight = false;
  bool _metricsPollInFlight = false;
  bool _profileApplyPending = false;
  bool _profileApplyInFlight = false;
  bool _virtualMicPassthroughEnabled = false;
  bool _reconnectAttemptInFlight = false;
  String? _virtualMicPassthroughOutputDeviceId;
  String? _downloadedUpdatePath;
  bool _isDisposed = false;
  bool _streamPeerConnected = false;
  bool _hasConnectedThisSession = false;
  int _reconnectAttempt = 0;
  int _reconnectGeneration = 0;
  bool _preferencesReady = false;
  bool _preferencesDirty = false;
  _AdaptiveProfileApplyReason _pendingProfileApplyReason =
      _AdaptiveProfileApplyReason.settings;
  AudioProfile _savedCustomProfile = AudioPreset.custom.profile;
  static const _nativeUsbSourceId = 'native-usb-source';
  static const _autoCodecSwitchCooldown = Duration(seconds: 30);
  static const _autoCodecQuietSignalThreshold = 0.015;
  static const _adaptiveGamingCapMs = 120;
  static const _adaptiveBalancedCapMs = 240;
  static const _adaptiveFormatRecoveryPolls = 4;
  static const _defaultReconnectDelays = [
    Duration(milliseconds: 500),
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
    Duration(seconds: 30),
  ];
  static const _fallbackAppVersion = '1.4.1';
  static const _sampleRateOptions = [44100, 48000, 96000];
  static const _lowLatencyAutoCodecPreference = [
    AudioCodec.opus,
    AudioCodec.imaAdpcm,
    AudioCodec.g711MuLaw,
    AudioCodec.g711ALaw,
  ];

  bool get isBusy => activity == RelayActivity.connecting;

  bool get isStreaming =>
      activity == RelayActivity.streaming ||
      activity == RelayActivity.reconnecting;

  bool get isReconnecting => activity == RelayActivity.reconnecting;

  bool get canEditAudioSettings => role == RelayRole.sender && !isBusy;

  bool get canEditAudioMode => role == RelayRole.sender && !isBusy;

  bool get canEditRestartRequiredAudioSettings =>
      canEditAudioSettings && !isStreaming;

  bool get canEditLiveAudioSettings => canEditAudioSettings;

  bool get canEditReceiverOutputBackend =>
      role == RelayRole.receiver && !isBusy && !isStreaming;

  bool supportsTransport(RelayTransport value) {
    return capabilities.supportedTransports.contains(value);
  }

  bool get isUpdateBusy {
    return updateStatus == AppUpdateStatus.checking ||
        updateStatus == AppUpdateStatus.downloading ||
        updateStatus == AppUpdateStatus.installing;
  }

  bool get canRunUpdateAction => !isUpdateBusy;

  bool get canOpenUpdateReleasePage => availableUpdate != null;

  String get updateStatusLabel {
    return switch (updateStatus) {
      AppUpdateStatus.idle => 'Ready',
      AppUpdateStatus.checking => 'Checking',
      AppUpdateStatus.current => 'Current',
      AppUpdateStatus.available => 'Available',
      AppUpdateStatus.downloading => 'Downloading',
      AppUpdateStatus.ready => 'Downloaded',
      AppUpdateStatus.installing => 'Opening',
      AppUpdateStatus.failed => 'Failed',
    };
  }

  String get updateDetailLabel {
    final release = availableUpdate;
    final message = updateMessage;
    if (message != null) {
      return message;
    }
    return switch (updateStatus) {
      AppUpdateStatus.idle => 'Installed v$appVersion',
      AppUpdateStatus.checking => 'Contacting Codeberg',
      AppUpdateStatus.current => 'Installed v$appVersion',
      AppUpdateStatus.available =>
        release == null
            ? 'Update available'
            : '${release.tagName} for ${release.asset.target.platformLabel}',
      AppUpdateStatus.downloading =>
        _updateProgressLabel ?? 'Downloading package',
      AppUpdateStatus.ready => 'Installer package is ready',
      AppUpdateStatus.installing => 'Opening system installer',
      AppUpdateStatus.failed => 'Update check failed',
    };
  }

  String get updateCurrentVersionLabel => 'v$appVersion';

  String get updateLatestVersionLabel {
    final release = availableUpdate;
    if (release != null) {
      return release.tagName;
    }
    return switch (updateStatus) {
      AppUpdateStatus.current => 'No newer release',
      AppUpdateStatus.checking => 'Checking',
      AppUpdateStatus.failed => 'Unavailable',
      _ => 'Not checked',
    };
  }

  String get updateLatestVersionDetailLabel {
    final release = availableUpdate;
    if (release != null) {
      return 'Latest ${release.asset.target.platformLabel} release';
    }
    return 'Installed $updateCurrentVersionLabel';
  }

  String get updatePackageLabel {
    final release = availableUpdate;
    if (release == null) {
      return 'No package';
    }
    return release.asset.name;
  }

  String get updatePackageDetailLabel {
    final release = availableUpdate;
    if (release == null) {
      return 'Target ${_updateTarget.platformLabel}';
    }
    return '${_formatByteSize(release.asset.sizeBytes)} ${release.asset.target.platformLabel} package';
  }

  String get updatePlatformLabel => _updateTarget.platformLabel;

  String get updateActionLabel {
    return switch (updateStatus) {
      AppUpdateStatus.available => 'Download',
      AppUpdateStatus.ready => 'Install',
      AppUpdateStatus.downloading => 'Downloading',
      AppUpdateStatus.checking => 'Checking',
      AppUpdateStatus.installing => 'Opening',
      _ => 'Check',
    };
  }

  String? get _updateProgressLabel {
    final progress = updateDownloadProgress;
    if (progress == null) {
      return null;
    }
    final percent = (progress.clamp(0, 1) * 100).round();
    return '$percent% downloaded';
  }

  bool get canUseSoundboard {
    return role == RelayRole.sender && capabilities.canPlaySoundEffects;
  }

  bool get canPlaySelectedSound {
    return canPlaySoundboardItem(selectedSoundboardItem);
  }

  String get soundboardStatusLabel {
    if (!canUseSoundboard) {
      return 'Unavailable';
    }
    if (soundboardBusy) {
      return 'Queueing';
    }
    if (soundboardTarget == SoundboardPlaybackTarget.micRoute &&
        soundboardOutputDevices.isEmpty) {
      return 'Needs call mic';
    }
    if (!isStreaming) {
      return soundboardTarget == SoundboardPlaybackTarget.stream
          ? 'Start stream'
          : 'Mic + speaker';
    }
    return soundboardTarget == SoundboardPlaybackTarget.stream
        ? 'Stream mix'
        : 'Mic + speaker';
  }

  List<SoundboardOutputDevice> get soundboardOutputDevices {
    final virtualDevices = capabilities.soundboardOutputDevices
        .where((device) => device.isVirtualCable)
        .toList(growable: false);
    final directCableDevices = virtualDevices
        .where(_isDedicatedSoundboardCableRoute)
        .toList(growable: false);
    if (directCableDevices.isNotEmpty) {
      final sortedDirectDevices = List<SoundboardOutputDevice>.of(
        directCableDevices,
      )..sort(_compareSoundboardCableRoutes);
      return [sortedDirectDevices.first];
    }

    return List<SoundboardOutputDevice>.of(virtualDevices)
      ..sort(_compareSoundboardCableRoutes);
  }

  SoundboardOutputDevice? get selectedSoundboardOutputDevice {
    final selectedId = selectedSoundboardOutputDeviceId;
    if (selectedId == null) {
      return null;
    }
    return soundboardOutputDevices
        .where((device) => device.id == selectedId)
        .firstOrNull;
  }

  String? get selectedSoundboardCallMicrophoneName {
    final device = selectedSoundboardOutputDevice;
    if (device == null) {
      return null;
    }
    return callMicrophoneNameForSoundboardRoute(device);
  }

  String callMicrophoneNameForSoundboardRoute(SoundboardOutputDevice device) {
    return _callMicrophoneNameForRoute(device);
  }

  bool canPlaySoundboardItem(SoundPlaybackItem? item) {
    if (!canUseSoundboard || soundboardBusy || item == null) {
      return false;
    }
    return switch (soundboardTarget) {
      SoundboardPlaybackTarget.stream => isStreaming,
      SoundboardPlaybackTarget.micRoute =>
        selectedSoundboardOutputDevice != null,
    };
  }

  String? get soundboardRouteMessage {
    if (!canUseSoundboard ||
        soundboardTarget != SoundboardPlaybackTarget.micRoute ||
        soundboardOutputDevices.isNotEmpty) {
      return null;
    }
    return 'No virtual microphone driver found. Install or enable VB-CABLE, then select its microphone in the call app.';
  }

  bool get isNativeUsbTransport => transport == RelayTransport.usb;

  bool get isUsbTunnelTransport => isNativeUsbTransport;

  bool get isUsbTetheringTransport => transport == RelayTransport.usbTethering;

  bool get isUsbTransport => isUsbTunnelTransport || isUsbTetheringTransport;

  bool get usesNetworkDiscovery => !isUsbTunnelTransport;

  List<RelayDevice> get visibleDevices {
    final nativeUsbDevice = _nativeUsbSourceDevice;
    if (nativeUsbDevice != null) {
      return [nativeUsbDevice];
    }
    return devices;
  }

  RelayDevice? get connectionTarget {
    return _nativeUsbSourceDevice ?? selectedDevice;
  }

  bool isDeviceSelected(RelayDevice device) {
    if (device.id == _nativeUsbSourceId && _nativeUsbSourceDevice != null) {
      return true;
    }
    return selectedDevice?.id == device.id;
  }

  bool get isDiscovering {
    return activity == RelayActivity.advertising ||
        activity == RelayActivity.scanning;
  }

  bool get canUseSelectedRole {
    return switch (role) {
      RelayRole.sender => capabilities.canSend,
      RelayRole.receiver => capabilities.canReceive,
    };
  }

  double get responsiveness {
    const minBufferMs = AudioProfile.minBufferMs;
    const maxBufferMs = AudioProfile.maxBufferMs;
    final normalized =
        (maxBufferMs - activeBufferMs) / (maxBufferMs - minBufferMs);
    return normalized.clamp(0, 1);
  }

  String get bufferingLabel {
    final activeMs = activePlaybackBufferMs;
    if (isStreaming && activeMs != null) {
      return '${activeMs.round()} ms active';
    }

    final bufferMs = activeBufferMs;
    if (bufferMs <= 28) {
      return 'Fastest';
    }
    if (bufferMs <= 45) {
      return 'Fast';
    }
    if (bufferMs <= 80) {
      return 'Balanced';
    }
    return 'Stable';
  }

  String get presetTradeoffLabel {
    if (profile.hasSameStreamSettings(AudioProfile.usbLowLatency)) {
      return 'Native USB low delay';
    }
    if (profile.hasSameStreamSettings(AudioProfile.usbTetheringLowLatency)) {
      return 'Tethered low delay';
    }

    return switch (profile.mode) {
      AudioPreset.gaming => 'Lowest delay',
      AudioPreset.balanced => 'Delay + stability',
      AudioPreset.music => 'Best fidelity',
      AudioPreset.custom => 'Saved tuning',
    };
  }

  String get presetLabel {
    if (profile.hasSameStreamSettings(AudioProfile.usbLowLatency)) {
      return 'Native USB low latency';
    }
    if (profile.hasSameStreamSettings(AudioProfile.usbTetheringLowLatency)) {
      return 'USB tethering low latency';
    }
    return profile.mode == AudioPreset.custom
        ? 'Custom mode'
        : '${profile.mode.label} mode';
  }

  String get audibleQualityTitle {
    final effectiveLatencyMs =
        profile.captureBufferMs + profile.playbackBufferMs;
    final channelLabel = profile.channels == 1 ? 'mono' : 'stereo';
    if (profile.sampleRate >= 96000 && profile.channels >= 2) {
      return effectiveLatencyMs >= 120
          ? 'High fidelity, relaxed response'
          : 'High fidelity, moderate response';
    }
    if (effectiveLatencyMs <= 60 && profile.packetTimeMs <= 3) {
      return 'Responsive $channelLabel, light buffering';
    }
    return 'Clean $channelLabel, balanced buffering';
  }

  String get audibleQualityDescription {
    final latencyLabel = _latencyFeelLabel();
    final detailLabel = _detailFeelLabel();
    final stabilityLabel = _stabilityFeelLabel();
    final networkLabel = _networkLoadFeelLabel();
    return '$detailLabel $latencyLabel $stabilityLabel $networkLabel';
  }

  String get supportedAdvancedSettingsLabel {
    final codecs = capabilities.supportedCodecs
        .map((codec) => codec.label)
        .join(', ');
    final outputBackends = capabilities.supportedOutputBackends
        .map((backend) => backend.label)
        .join(', ');
    return 'Current engine controls: receiver adaptive buffer, adaptive sample rate, mono/stereo format, codec ($codecs), adaptive bitrate target, sender buffer, receiver buffer, packet time, volume, mute, and role/discovery. Receiver output backends: $outputBackends.';
  }

  String get liveLatencyLabel {
    final latencyMs = displayedLatencyMs;
    if (!isStreaming || latencyMs == null) {
      return role == RelayRole.sender ? 'Waiting' : 'Measuring';
    }
    return '${latencyMs.round()} ms';
  }

  String get latencyMetricLabel {
    return metrics.audioLatencyMs == null ? 'Playback buffer' : 'Audio latency';
  }

  String get profileSummary {
    return '$codecStatusLabel · $sampleRateLabel · $channelModeLabel';
  }

  String get codecStatusLabel {
    if (profile.codec != AudioCodec.auto) {
      return profile.codec.label;
    }
    return isStreaming
        ? 'Adaptive (${_autoResolvedCodec.label})'
        : 'Adaptive (${AudioCodec.pcm.label} first)';
  }

  String get outputBackendLabel {
    return receiverOutputBackend.label;
  }

  String get bufferTargetLabel {
    return '$activeBufferMs ms target';
  }

  String get activePlaybackBufferLabel {
    final activeMs = activePlaybackBufferMs;
    if (!isStreaming || activeMs == null) {
      return 'Requested ${profile.playbackBufferMs} ms';
    }
    return 'Active ${activeMs.round()} ms · requested ${profile.playbackBufferMs} ms';
  }

  String get adaptiveBufferCapLabel {
    if (!profile.receiverAdaptiveBuffer) {
      return 'Fixed';
    }
    final capMs = metrics.adaptiveMaxPlaybackBufferMs;
    if (!isStreaming || capMs == null || capMs <= 0) {
      return '${_adaptiveMaxPlaybackBufferMsForProfile(profile)} ms';
    }
    return metrics.adaptiveLimitReached == true ? '$capMs ms hit' : '$capMs ms';
  }

  String get customAdaptiveCapSettingLabel {
    final capMs = _effectiveAdaptiveBufferCap(profile);
    return '$capMs ms cap';
  }

  int get customAdaptiveCapMs {
    return _effectiveAdaptiveBufferCap(profile);
  }

  String get customAdaptiveCapDetailLabel {
    return profile.mode == AudioPreset.custom
        ? 'Saved with Custom.'
        : 'Available in Custom mode.';
  }

  String get playbackQueueFillLabel {
    final percent = metrics.playbackQueueFillPercent;
    if (!isStreaming) {
      return 'Waiting';
    }
    return '${percent ?? 0}%';
  }

  String get receiverAdaptiveBufferLabel {
    return profile.receiverAdaptiveBuffer ? 'Adaptive' : 'Fixed';
  }

  String get receiverAdaptiveBufferDetailLabel {
    return profile.receiverAdaptiveBuffer
        ? 'Raises above minimum for jitter, underruns, or low queue.'
        : 'Keeps the receiver buffer fixed.';
  }

  String get receiverBufferDescription {
    return profile.receiverAdaptiveBuffer
        ? 'Sets the minimum receiver delay. Adaptive may raise it to prevent pops and dropouts on unstable links.'
        : 'Sets a fixed receiver delay. Lower feels more immediate; higher is safer on unstable links.';
  }

  String get receiverBufferValueLabel {
    return profile.receiverAdaptiveBuffer
        ? '${profile.playbackBufferMs} ms min'
        : '${profile.playbackBufferMs} ms';
  }

  String get receiverBufferDetailLabel {
    final requestedFramesLabel = profile.receiverAdaptiveBuffer
        ? '$playbackBufferFramesLabel minimum'
        : '$playbackBufferFramesLabel fixed';
    final activeMs = activePlaybackBufferMs;
    if (activeMs == null || !isStreaming) {
      return requestedFramesLabel;
    }
    final targetFrames = metrics.targetBufferFrames;
    if (targetFrames == null) {
      return requestedFramesLabel;
    }
    final capMs = metrics.adaptiveMaxPlaybackBufferMs;
    final capLabel = profile.receiverAdaptiveBuffer && capMs != null
        ? ' · $capMs ms cap'
        : '';
    final limitLabel = metrics.adaptiveLimitReached == true ? ' · cap hit' : '';
    return '$targetFrames frames active · $requestedFramesLabel$capLabel$limitLabel';
  }

  String get captureBufferLabel {
    return '${profile.captureBufferMs} ms';
  }

  String get playbackBufferLabel {
    return '${profile.playbackBufferMs} ms';
  }

  String get packetTimeLabel {
    return '${profile.packetTimeMs} ms';
  }

  String get bufferPairLabel {
    return '${profile.captureBufferMs}/${profile.playbackBufferMs} ms';
  }

  String get packetAndBufferLabel {
    return '${profile.packetTimeMs} ms packets · $bufferPairLabel buffers';
  }

  String get sampleRateLabel {
    final label = _formatSampleRate(_displayProfile.sampleRate);
    return profile.adaptiveSampleRate ? 'Adaptive ($label)' : label;
  }

  String get appliedSampleRateLabel {
    return _formatSampleRate(_displayProfile.sampleRate);
  }

  String get sampleRateSettingLabel {
    return profile.adaptiveSampleRate
        ? 'Adaptive'
        : _formatSampleRate(profile.sampleRate);
  }

  String? get sampleRateSettingDetailLabel {
    if (!profile.adaptiveSampleRate) {
      return null;
    }
    return 'Current $appliedSampleRateLabel · limits $adaptiveSampleRateRangeLabel';
  }

  String get adaptiveSampleRateRangeLabel {
    final options = adaptiveSampleRateOptions;
    if (options.isEmpty) {
      return appliedSampleRateLabel;
    }
    return '${_formatSampleRate(options.first)}-${_formatSampleRate(options.last)}';
  }

  List<int> get sampleRateOptions {
    if (profile.codec == AudioCodec.opus) {
      return const [48000];
    }
    final values = <int>{..._sampleRateOptions, profile.sampleRate};
    return values.toList()..sort();
  }

  List<int> get adaptiveSampleRateOptions {
    return profile.codec == AudioCodec.opus
        ? const [48000]
        : _sampleRateOptions;
  }

  bool get canUseAdaptiveSampleRate {
    return adaptiveSampleRateOptions.length > 1;
  }

  String get channelModeLabel {
    return switch (profile.channels) {
      1 => 'Mono',
      2 => 'Stereo',
      _ => '${profile.channels} channels',
    };
  }

  String get streamBitrateLabel {
    return '${_displayProfile.effectiveBitrateKbps} kbps';
  }

  String get streamBitrateFormatLabel {
    if (profile.codec == AudioCodec.auto) {
      return 'Adaptive target';
    }
    return switch (profile.codec) {
      AudioCodec.pcm => 'PCM 16-bit',
      AudioCodec.opus => 'Opus target',
      AudioCodec.aac => 'AAC-LC target',
      AudioCodec.g711MuLaw || AudioCodec.g711ALaw => '8-bit companded',
      AudioCodec.imaAdpcm => '4-bit ADPCM',
      _ => 'Target bitrate',
    };
  }

  bool get hasBitrateTarget {
    return bitrateTargetRange != null;
  }

  int get bitrateTargetKbps {
    final range = bitrateTargetRange;
    if (range == null) {
      return profile.effectiveBitrateKbps;
    }
    return _clampBitrateKbps(profile.bitrateKbps, range);
  }

  String get bitrateTargetLabel {
    return '$bitrateTargetKbps kbps';
  }

  String get appliedBitrateLabel {
    return streamBitrateLabel;
  }

  String get bitrateSettingLabel {
    return profile.adaptiveBitrate && bitrateTargetRange != null
        ? 'Adaptive'
        : bitrateTargetLabel;
  }

  String? get bitrateSettingDetailLabel {
    final range = bitrateTargetRange;
    if (!profile.adaptiveBitrate || range == null) {
      return null;
    }
    final targetCodec = _bitrateTargetCodec;
    final targetLabel = profile.codec == AudioCodec.auto
        ? ' · ${targetCodec.label} target'
        : '';
    return 'Current $appliedBitrateLabel · limits ${range.minKbps}-${range.maxKbps} kbps$targetLabel';
  }

  String get bitrateTargetDetailLabel {
    final targetCodec = _bitrateTargetCodec;
    final range = bitrateTargetRange;
    if (range == null) {
      return 'Fixed by ${profile.codec.label}';
    }
    if (profile.codec == AudioCodec.auto) {
      return '${targetCodec.label} target · ${range.minKbps}-${range.maxKbps} kbps';
    }
    return '${range.minKbps}-${range.maxKbps} kbps range';
  }

  String get bitrateTargetDescription {
    if (profile.codec == AudioCodec.auto) {
      return 'Sets the compressed target when Adaptive selects Opus or AAC. PCM stays calculated from sample rate and channels.';
    }
    if (hasBitrateTarget) {
      return 'Sets the encoder target for the selected compressed codec. Lower reduces network load; higher preserves more detail.';
    }
    return 'This codec has a fixed bitrate calculated from the selected format.';
  }

  int get bitrateTargetDivisions {
    final range = bitrateTargetRange;
    if (range == null) {
      return 1;
    }
    return max(1, ((range.maxKbps - range.minKbps) / 8).round());
  }

  CodecBitrateRange? get bitrateTargetRange {
    final targetCodec = _bitrateTargetCodec;
    if (!_hasConfigurableBitrate(targetCodec)) {
      return null;
    }
    return _bitrateRangeFor(targetCodec);
  }

  List<int> get bitrateTargetOptions {
    final range = bitrateTargetRange;
    if (range == null) {
      return const [];
    }

    const stepKbps = 16;
    final values = <int>{range.minKbps, range.maxKbps, bitrateTargetKbps};
    for (var value = range.minKbps; value <= range.maxKbps; value += stepKbps) {
      values.add(_clampBitrateKbps(value, range));
    }
    return values.toList()..sort();
  }

  String get captureBufferFramesLabel {
    return '${_framesForMs(profile.captureBufferMs)} frames';
  }

  String get playbackBufferFramesLabel {
    return '${_framesForMs(profile.playbackBufferMs)} frames';
  }

  String get packetFramesLabel {
    final displayProfile = _displayProfile;
    if (displayProfile.codec == AudioCodec.opus) {
      final frames = _opusFrameSamplesForPacketTime(profile.packetTimeMs);
      final milliseconds = frames * 1000 / 48000;
      final label = milliseconds == milliseconds.roundToDouble()
          ? '${milliseconds.round()} ms'
          : '${milliseconds.toStringAsFixed(1)} ms';
      return '$frames frames per packet · $label Opus';
    }
    return '${_framesForMs(profile.packetTimeMs)} frames per packet';
  }

  double? get activePlaybackBufferMs {
    final adaptiveMs = metrics.adaptivePlaybackBufferMs;
    if (adaptiveMs != null && adaptiveMs > 0) {
      return adaptiveMs.toDouble();
    }
    final targetFrames = metrics.targetBufferFrames;
    if (targetFrames != null && targetFrames > 0 && profile.sampleRate > 0) {
      return targetFrames * 1000 / profile.sampleRate;
    }
    final queuedFrames = metrics.queuedFrames;
    if (queuedFrames != null && queuedFrames > 0 && profile.sampleRate > 0) {
      return queuedFrames * 1000 / profile.sampleRate;
    }
    return null;
  }

  double? get displayedLatencyMs {
    final measuredLatencyMs = metrics.effectiveLatencyMs;
    final activeBufferMs = activePlaybackBufferMs;
    if (activeBufferMs == null) {
      return measuredLatencyMs ??
          (isStreaming ? profile.playbackBufferMs.toDouble() : null);
    }

    final bufferedFloorMs = metrics.audioLatencyMs == null
        ? activeBufferMs
        : activeBufferMs + (metrics.networkLatencyMs ?? 0);
    if (measuredLatencyMs == null) {
      return bufferedFloorMs;
    }
    return max(measuredLatencyMs, bufferedFloorMs);
  }

  String get networkHealthLabel {
    final drops = metrics.droppedPacketCount ?? 0;
    final lost = metrics.lostPacketCount ?? 0;
    final trims = metrics.trimCount ?? 0;
    final total = drops + lost + trims;
    if (!isStreaming) {
      return 'Idle';
    }
    return total == 0 ? 'Clean' : '$total events';
  }

  String get transportHealthLabel {
    if (isUsbTunnelTransport) {
      return isStreaming ? networkHealthLabel : 'Cable';
    }
    if (isUsbTetheringTransport) {
      return isStreaming ? networkHealthLabel : 'Tethered';
    }
    return networkHealthLabel;
  }

  String get settingsAuthorityLabel {
    return role == RelayRole.sender ? 'Source controlled' : 'Receiver output';
  }

  String get endpointTitle {
    if (role == RelayRole.sender) {
      return switch (transport) {
        RelayTransport.usb => 'Native USB source endpoint',
        RelayTransport.usbTethering => 'USB tether source endpoint',
        RelayTransport.wifi => 'Wi-Fi source endpoint',
      };
    }
    return switch (transport) {
      RelayTransport.usb => 'Native USB source',
      RelayTransport.usbTethering => 'USB tether sources',
      RelayTransport.wifi => 'Available sources',
    };
  }

  String get usbSetupLabel {
    return switch (transport) {
      RelayTransport.usb => 'Android accessory',
      RelayTransport.usbTethering => 'Network over USB',
      RelayTransport.wifi => 'LAN broadcast',
    };
  }

  String get primaryActionLabel {
    return switch ((role, transport)) {
      (RelayRole.sender, RelayTransport.usb) => 'Host native USB',
      (RelayRole.sender, RelayTransport.usbTethering) => 'Host tether',
      (RelayRole.sender, RelayTransport.wifi) => 'Host source',
      (RelayRole.receiver, RelayTransport.usb) => 'Use native USB',
      (RelayRole.receiver, RelayTransport.usbTethering) => 'Scan tether',
      (RelayRole.receiver, RelayTransport.wifi) => 'Scan',
    };
  }

  String get endpointHostLabel {
    return switch (transport) {
      RelayTransport.usb => 'Cable',
      RelayTransport.usbTethering => 'Tether IP',
      RelayTransport.wifi => 'Host',
    };
  }

  String get endpointHostValue {
    return switch (transport) {
      RelayTransport.usb => 'Accessory mode',
      RelayTransport.usbTethering || RelayTransport.wifi => localAddress,
    };
  }

  String get endpointAudioValue {
    return switch (transport) {
      RelayTransport.usb => 'USB bulk frames',
      RelayTransport.usbTethering ||
      RelayTransport.wifi => 'UDP ${DiscoveryService.audioPort}',
    };
  }

  int get activeBufferMs {
    return role == RelayRole.sender
        ? profile.captureBufferMs
        : profile.playbackBufferMs;
  }

  Future<void> initialize() async {
    appVersion = await _appVersionProvider();
    capabilities = await _engine.getCapabilities();
    if (_isDisposed) {
      return;
    }
    await _loadSavedCustomProfile();
    await _loadSavedPreferences();
    await _refreshLocalAddress();
    if (!isOutputBackendSupported(receiverOutputBackend)) {
      receiverOutputBackend = OutputAudioBackend.auto;
    }
    profile = _profileForCurrentRole(profile);
    selectedPreset = profile.mode;

    if (!canUseSelectedRole) {
      role = capabilities.canSend ? RelayRole.sender : RelayRole.receiver;
      profile = _profileForCurrentRole(profile);
      selectedPreset = profile.mode;
    }

    _selectDefaultSoundboardOutputDevice();
    await _applyRestoredEnginePreferences();
    if (_isDisposed) {
      return;
    }
    _preferencesReady = true;
    _schedulePreferencesSave();
    _syncVirtualMicPassthrough();
    notifyListeners();
    if (!_isDisposed && _checkForUpdatesOnInitialize) {
      unawaited(checkForUpdates());
    }
  }

  Future<void> setRole(RelayRole value) async {
    if (role == value) {
      return;
    }

    await stopAll();
    role = value;
    profile = _profileForCurrentRole(profile);
    selectedPreset = profile.mode;
    devices = const [];
    selectedDevice = null;
    errorMessage = null;
    noticeMessage = null;
    _syncVirtualMicPassthrough();
    notifyListeners();
    _schedulePreferencesSave();
  }

  Future<void> setTransport(RelayTransport value) async {
    if (!supportsTransport(value)) {
      _fail('${value.label} is not available on ${capabilities.platform}.');
      return;
    }
    if (transport == value) {
      return;
    }

    await stopAll();
    transport = value;
    _applyTransportProfile(value);
    if (usesNetworkDiscovery) {
      await _refreshLocalAddress();
    }
    devices = const [];
    selectedDevice = null;
    errorMessage = null;
    noticeMessage = null;
    _syncVirtualMicPassthrough();
    notifyListeners();
    _schedulePreferencesSave();
  }

  Future<void> startDiscovery() async {
    if (!canUseSelectedRole) {
      _fail('${role.label} mode is not available on ${capabilities.platform}.');
      return;
    }

    errorMessage = null;
    noticeMessage = null;
    notifyListeners();

    try {
      if (usesNetworkDiscovery) {
        await _refreshLocalAddress(requireUsable: true);
      }
      if (role == RelayRole.sender) {
        final senderProfile = _materializedSenderProfile(profile);
        if (isUsbTunnelTransport) {
          await _engine.prepareUsbSender(senderProfile);
          _appliedSenderProfile = senderProfile;
          activity = RelayActivity.advertising;
        } else {
          await _engine.prepareSender(
            senderProfile,
            networkBindAddress: _networkBindAddress,
          );
          _appliedSenderProfile = senderProfile;
          await _startAdvertisingCurrentProfile(senderProfile);
          activity = RelayActivity.advertising;
        }
      } else {
        if (isUsbTunnelTransport) {
          await _startNativeUsbReceiver();
        } else {
          _cancelSourcePrune();
          devices = const [];
          selectedDevice = null;
          await _discoveryService.startScanning(
            _upsertDevice,
            scope: _discoveryNetworkScope,
          );
          activity = RelayActivity.scanning;
        }
      }
      if (activity == RelayActivity.streaming) {
        _startStreamConnectionWatch();
      } else if (isDiscovering) {
        _scheduleDiscoveryIdleTimeout();
      }
      notifyListeners();
    } on SocketException catch (error) {
      _fail('Network discovery failed: ${error.message}');
    } on OSError catch (error) {
      _fail('Network discovery failed: ${error.message}');
    } on PlatformException catch (error) {
      _fail(error.message ?? 'Unable to start ${transport.label}.');
    }
  }

  Future<void> startSenderStream() async {
    if (role != RelayRole.sender || isBusy || isStreaming) {
      return;
    }

    _cancelDiscoveryIdleTimeout();
    errorMessage = null;
    noticeMessage = null;
    activity = RelayActivity.connecting;
    notifyListeners();

    try {
      _resetAutoCodecSession();
      final senderProfile = _materializedSenderProfile(profile);
      if (isUsbTunnelTransport) {
        await _engine.prepareUsbSender(senderProfile);
      } else {
        await _engine.prepareSender(
          senderProfile,
          networkBindAddress: _networkBindAddress,
        );
      }
      await _engine.startStream(senderProfile);
      _appliedSenderProfile = senderProfile;
      _rememberAutoResolvedCodec(senderProfile);
      activity = RelayActivity.streaming;
      _startMeters();
      _startStreamConnectionWatch();
      notifyListeners();
    } on PlatformException catch (error) {
      _fail(error.message ?? 'Unable to start sender.');
    }
  }

  Future<void> connectToDevice(RelayDevice device) async {
    if (role != RelayRole.receiver || isBusy) {
      return;
    }

    _cancelDiscoveryIdleTimeout();
    selectedDevice = device;
    final receiverProfile = _receiverProfileFor(device.profile);
    profile = receiverProfile;
    errorMessage = null;
    activity = RelayActivity.connecting;
    notifyListeners();

    try {
      if (device.transport == RelayTransport.usb) {
        await _engine.prepareUsbReceiver(receiverProfile);
      } else {
        await _engine.prepareReceiver(receiverProfile);
        await _engine.connectToSender(device, receiverProfile);
      }
      await _engine.startStream(receiverProfile);
      activity = RelayActivity.streaming;
      _startMeters();
      _startStreamConnectionWatch();
      notifyListeners();
    } on PlatformException catch (error) {
      await _discoveryService.stopScanning();
      _fail(error.message ?? 'Unable to connect to ${device.name}.');
    }
  }

  Future<void> stopStream() async {
    _cancelReconnect();
    _cancelStreamConnectionTimeout();
    _cancelSourcePrune();
    await _engine.stopStream();
    _stopMeters();
    _resetAutoCodecSession();
    signalLevel = 0;

    if (role == RelayRole.sender) {
      activity = RelayActivity.advertising;
      _scheduleDiscoveryIdleTimeout();
    } else {
      _cancelDiscoveryIdleTimeout();
      await _discoveryService.stopScanning();
      activity = RelayActivity.idle;
      devices = const [];
      selectedDevice = null;
    }

    noticeMessage = null;
    notifyListeners();
  }

  Future<void> stopAll() async {
    _cancelReconnect();
    _cancelDiscoveryIdleTimeout();
    _cancelStreamConnectionTimeout();
    _cancelSourcePrune();
    _cancelPendingProfileApply();
    await _engine.disconnect();
    _virtualMicPassthroughEnabled = false;
    _virtualMicPassthroughOutputDeviceId = null;
    await _discoveryService.dispose();
    _stopMeters();
    _appliedSenderProfile = null;
    _resetAutoCodecSession();
    activity = RelayActivity.idle;
    devices = const [];
    selectedDevice = null;
    signalLevel = 0;
    noticeMessage = null;
    notifyListeners();
  }

  Future<void> runUpdateAction() {
    if (!canRunUpdateAction) {
      return Future<void>.value();
    }
    return switch (updateStatus) {
      AppUpdateStatus.available => downloadAndInstallUpdate(),
      AppUpdateStatus.ready => installDownloadedUpdate(),
      _ => checkForUpdates(),
    };
  }

  Future<void> checkForUpdates() async {
    if (isUpdateBusy) {
      return;
    }

    updateStatus = AppUpdateStatus.checking;
    updateMessage = null;
    updateDownloadProgress = null;
    notifyListeners();

    try {
      final result = await _updateService.checkForUpdate(
        currentVersion: appVersion,
        target: _updateTarget,
      );
      availableUpdate = result.release;
      _downloadedUpdatePath = null;
      if (result.release == null) {
        updateStatus = AppUpdateStatus.current;
        updateMessage = _updateTarget == AppUpdateTarget.unsupported
            ? 'Updates are not available on ${_updateTarget.platformLabel}.'
            : 'Installed v$appVersion is current.';
      } else {
        updateStatus = AppUpdateStatus.available;
        updateMessage =
            'Current v$appVersion, latest ${result.release!.tagName}.';
      }
    } on AppUpdateException catch (error) {
      updateStatus = AppUpdateStatus.failed;
      updateMessage = error.message;
    } catch (_) {
      updateStatus = AppUpdateStatus.failed;
      updateMessage = 'Unable to check for updates.';
    }
    notifyListeners();
  }

  Future<void> downloadAndInstallUpdate() async {
    if (isUpdateBusy) {
      return;
    }

    var release = availableUpdate;
    if (release == null) {
      await checkForUpdates();
      release = availableUpdate;
      if (release == null) {
        return;
      }
    }

    updateStatus = AppUpdateStatus.downloading;
    updateMessage = null;
    updateDownloadProgress = null;
    notifyListeners();

    try {
      final packageFile = await _updateService.downloadUpdate(
        release,
        onProgress: (progress) {
          updateDownloadProgress = progress;
          notifyListeners();
        },
      );
      _downloadedUpdatePath = packageFile.path;
      updateStatus = AppUpdateStatus.ready;
      updateMessage = '${release.tagName} downloaded.';
      notifyListeners();
      await installDownloadedUpdate();
    } on AppUpdateException catch (error) {
      updateStatus = AppUpdateStatus.failed;
      updateMessage = error.message;
      notifyListeners();
    } catch (_) {
      updateStatus = AppUpdateStatus.failed;
      updateMessage = 'Unable to download update.';
      notifyListeners();
    }
  }

  Future<void> installDownloadedUpdate() async {
    if (isUpdateBusy) {
      return;
    }

    final path = _downloadedUpdatePath;
    if (path == null) {
      updateStatus = AppUpdateStatus.failed;
      updateMessage = 'Download the update first.';
      notifyListeners();
      return;
    }

    updateStatus = AppUpdateStatus.installing;
    updateMessage = null;
    notifyListeners();

    try {
      await _updateInstaller.installPackage(File(path));
      updateStatus = AppUpdateStatus.ready;
      updateMessage = 'System installer opened.';
    } on PlatformException catch (error) {
      if (error.code == 'update_install_permission') {
        updateStatus = AppUpdateStatus.ready;
        updateMessage =
            error.message ??
            'Allow AudioBridge to install updates, then return to the app.';
      } else {
        updateStatus = AppUpdateStatus.failed;
        updateMessage = error.message ?? 'Unable to open installer.';
      }
    } catch (_) {
      updateStatus = AppUpdateStatus.failed;
      updateMessage = 'Unable to open installer.';
    }
    notifyListeners();
  }

  Future<void> openUpdateReleasePage() async {
    final release = availableUpdate;
    if (release == null) {
      return;
    }

    try {
      await _updateInstaller.openReleasePage(release.pageUrl);
    } on PlatformException catch (error) {
      updateStatus = AppUpdateStatus.failed;
      updateMessage = error.message ?? 'Unable to open release page.';
      notifyListeners();
    }
  }

  void selectDevice(RelayDevice device) {
    selectedDevice = device;
    profile = _receiverProfileFor(device.profile);
    selectedPreset = profile.mode;
    notifyListeners();
  }

  bool isCodecSupported(AudioCodec codec) {
    if (codec == AudioCodec.auto) {
      return _autoCodecLocalCandidates().length > 1;
    }
    return capabilities.supportsCodec(codec);
  }

  bool isOutputBackendSupported(OutputAudioBackend backend) {
    return capabilities.supportsOutputBackend(backend);
  }

  void updatePreset(AudioPreset value) {
    if (!canEditAudioMode) {
      return;
    }
    selectedPreset = value;
    final requestedProfile = value == AudioPreset.custom
        ? _savedCustomProfile
        : _profileForPreset(value).copyWith(mode: value);
    final livePresetChange = role == RelayRole.sender && isStreaming;
    final nextProfile = livePresetChange
        ? _activeSenderPolicyProfileFor(requestedProfile)
        : requestedProfile;
    profile = _profileForCurrentRole(_normalizeProfile(nextProfile));
    notifyListeners();
    _schedulePreferencesSave();
    _scheduleActiveProfileApply(
      reason: livePresetChange
          ? _AdaptiveProfileApplyReason.liveBufferPolicy
          : _AdaptiveProfileApplyReason.settings,
    );
  }

  void saveCustomPreset() {
    if (!canEditAudioMode) {
      return;
    }
    final customProfile = _profileForSavedCustom(profile);
    _savedCustomProfile = customProfile;
    selectedPreset = AudioPreset.custom;
    final livePresetChange = role == RelayRole.sender && isStreaming;
    final nextProfile = livePresetChange
        ? _activeSenderPolicyProfileFor(customProfile)
        : customProfile;
    profile = _profileForCurrentRole(_normalizeProfile(nextProfile));
    notifyListeners();
    _schedulePreferencesSave();
    _persistCustomProfile(_savedCustomProfile);
    _scheduleActiveProfileApply(
      reason: livePresetChange
          ? _AdaptiveProfileApplyReason.liveBufferPolicy
          : _AdaptiveProfileApplyReason.settings,
    );
  }

  void updateCodec(AudioCodec value) {
    if (!_canChangeRestartRequiredSenderSetting()) {
      return;
    }
    if (!isCodecSupported(value)) {
      return;
    }
    noticeMessage = null;
    if (profile.codec != value) {
      _resetAutoCodecSession();
    }
    _updateProfile(_normalizeProfile(profile.copyWith(codec: value)));
  }

  void updateOutputBackend(OutputAudioBackend value) {
    if (!canEditReceiverOutputBackend) {
      return;
    }
    if (!isOutputBackendSupported(value)) {
      return;
    }
    receiverOutputBackend = value;
    profile = _receiverProfileFor(profile);
    notifyListeners();
    _schedulePreferencesSave();
    unawaited(_refreshActiveReceiverProfile());
  }

  void updateSampleRate(int value) {
    if (!_canChangeRestartRequiredSenderSetting()) {
      return;
    }
    _updateProfile(
      _normalizeProfile(
        profile.copyWith(sampleRate: value, adaptiveSampleRate: false),
      ),
    );
  }

  void updateAdaptiveSampleRate(bool value) {
    if (!_canChangeRestartRequiredSenderSetting()) {
      return;
    }
    if (value && !canUseAdaptiveSampleRate) {
      return;
    }
    _updateProfile(
      _normalizeProfile(profile.copyWith(adaptiveSampleRate: value)),
    );
  }

  void updateLatency(double value) {
    if (!_canChangeRestartRequiredSenderSetting()) {
      return;
    }
    final latencyMs = _clampBufferMs(value);
    _updateProfile(
      profile.copyWith(
        latencyMs: latencyMs,
        captureBufferMs: latencyMs,
        playbackBufferMs: latencyMs,
      ),
    );
  }

  void updateResponsiveness(double value) {
    if (!_canChangeRestartRequiredSenderSetting()) {
      return;
    }
    const minBufferMs = AudioProfile.minBufferMs;
    const maxBufferMs = AudioProfile.maxBufferMs;
    final nextLatencyMs =
        maxBufferMs -
        (value.clamp(0, 1).toDouble() * (maxBufferMs - minBufferMs));
    final latencyMs = _clampBufferMs(nextLatencyMs);
    _updateProfile(
      profile.copyWith(
        latencyMs: latencyMs,
        captureBufferMs: latencyMs,
        playbackBufferMs: latencyMs,
      ),
    );
  }

  void updateBitrate(double value) {
    if (!_canChangeRestartRequiredSenderSetting()) {
      return;
    }
    final range = bitrateTargetRange;
    if (range == null) {
      return;
    }
    _updateProfile(
      profile.copyWith(
        bitrateKbps: _snapBitrateKbps(value, range),
        adaptiveBitrate: false,
      ),
    );
  }

  void updateAdaptiveBitrate(bool value) {
    if (!_canChangeRestartRequiredSenderSetting()) {
      return;
    }
    if (value && bitrateTargetRange == null) {
      return;
    }
    _updateProfile(profile.copyWith(adaptiveBitrate: value));
  }

  void updateChannels(int value) {
    if (!_canChangeRestartRequiredSenderSetting()) {
      return;
    }
    final channels = value.clamp(1, 2).toInt();
    _updateProfile(_normalizeProfile(profile.copyWith(channels: channels)));
  }

  void updateCaptureBuffer(double value) {
    if (!_canChangeRestartRequiredSenderSetting()) {
      return;
    }
    _updateProfile(profile.copyWith(captureBufferMs: _clampBufferMs(value)));
  }

  void updatePlaybackBuffer(double value) {
    final playbackBufferMs = _clampBufferMs(value);
    _updateProfile(
      profile.copyWith(
        latencyMs: playbackBufferMs,
        playbackBufferMs: playbackBufferMs,
      ),
    );
  }

  void updatePacketTime(double value) {
    _updateProfile(
      profile.copyWith(
        packetTimeMs: value.round().clamp(
          AudioProfile.minPacketTimeMs,
          AudioProfile.maxPacketTimeMs,
        ),
      ),
    );
  }

  void updateReceiverAdaptiveBuffer(bool value) {
    _updateProfile(profile.copyWith(receiverAdaptiveBuffer: value));
  }

  void updateAdaptiveBufferCap(double value) {
    final capMs = value
        .round()
        .clamp(profile.playbackBufferMs, AudioProfile.maxBufferMs)
        .toInt();
    _updateProfile(profile.copyWith(adaptiveBufferCapMs: capMs));
  }

  Future<void> updateVolume(double value) async {
    volume = value;
    notifyListeners();
    _schedulePreferencesSave();
    await _engine.setVolume(value);
  }

  Future<void> updateMuted(bool value) async {
    muted = value;
    if (muted) {
      signalLevel = 0;
    }
    notifyListeners();
    _schedulePreferencesSave();
    await _engine.setMuted(value);
  }

  void addSoundboardFiles(Iterable<String> paths) {
    final nextItems = List<SoundPlaybackItem>.of(soundboardItems);
    for (final path in paths) {
      final normalizedPath = path.trim();
      if (normalizedPath.isEmpty ||
          nextItems.any((item) => item.path == normalizedPath)) {
        continue;
      }
      nextItems.add(_soundboardItemForPath(normalizedPath));
    }

    if (nextItems.length == soundboardItems.length) {
      return;
    }
    soundboardItems = List.unmodifiable(nextItems);
    selectedSoundboardItem ??= soundboardItems.firstOrNull;
    soundboardMessage = null;
    notifyListeners();
    _schedulePreferencesSave();
  }

  void selectSoundboardItem(SoundPlaybackItem item) {
    selectedSoundboardItem = item;
    soundboardMessage = null;
    notifyListeners();
    _schedulePreferencesSave();
  }

  void removeSoundboardItem(SoundPlaybackItem item) {
    final nextItems = soundboardItems
        .where((candidate) => candidate.id != item.id)
        .toList();
    soundboardItems = List.unmodifiable(nextItems);
    if (selectedSoundboardItem?.id == item.id) {
      selectedSoundboardItem = soundboardItems.firstOrNull;
    }
    notifyListeners();
    _schedulePreferencesSave();
  }

  void updateSoundboardVolume(double value) {
    soundboardVolume = value.clamp(0, 1).toDouble();
    notifyListeners();
    _schedulePreferencesSave();
  }

  void updateSoundboardTarget(SoundboardPlaybackTarget value) {
    if (soundboardTarget == value) {
      return;
    }
    soundboardTarget = value;
    soundboardMessage = null;
    _syncVirtualMicPassthrough();
    notifyListeners();
    _schedulePreferencesSave();
  }

  void selectSoundboardOutputDevice(String? id) {
    if (selectedSoundboardOutputDeviceId == id) {
      return;
    }
    selectedSoundboardOutputDeviceId = id;
    soundboardMessage = null;
    _syncVirtualMicPassthrough();
    notifyListeners();
    _schedulePreferencesSave();
  }

  Future<void> playSoundboardItem(SoundPlaybackItem item) async {
    selectedSoundboardItem = item;
    _schedulePreferencesSave();
    await playSelectedSoundboardItem();
  }

  Future<void> playSelectedSoundboardItem() async {
    final item = selectedSoundboardItem;
    if (item == null || soundboardBusy) {
      return;
    }
    if (!canUseSoundboard) {
      soundboardMessage = 'Soundboard injection is not available here.';
      notifyListeners();
      return;
    }
    if (soundboardTarget == SoundboardPlaybackTarget.stream && !isStreaming) {
      soundboardMessage = 'Start sender streaming first.';
      notifyListeners();
      return;
    }
    if (soundboardTarget == SoundboardPlaybackTarget.micRoute &&
        selectedSoundboardOutputDevice == null) {
      soundboardMessage = soundboardOutputDevices.isEmpty
          ? 'Install or enable VB-CABLE first.'
          : 'Select the call app microphone.';
      notifyListeners();
      return;
    }

    soundboardBusy = true;
    soundboardMessage = 'Queueing ${item.name}';
    notifyListeners();
    try {
      await _engine.playSoundEffect(
        path: item.path,
        volume: soundboardVolume,
        target: soundboardTarget,
        outputDeviceId: selectedSoundboardOutputDeviceId,
      );
      soundboardMessage = 'Queued ${item.name}';
    } on PlatformException catch (error) {
      soundboardMessage = error.message ?? 'Unable to play ${item.name}.';
    } finally {
      soundboardBusy = false;
      notifyListeners();
    }
  }

  Future<void> stopSoundboard() async {
    soundboardMessage = 'Stopping soundboard';
    notifyListeners();
    try {
      await _engine.stopSoundEffects();
      soundboardMessage = 'Soundboard stopped';
    } on PlatformException catch (error) {
      soundboardMessage = error.message ?? 'Unable to stop soundboard.';
    }
    notifyListeners();
  }

  Future<void> flushPreferences() async {
    _preferencesSaveTimer?.cancel();
    _preferencesSaveTimer = null;
    if (!_preferencesReady || !_preferencesDirty) {
      return;
    }
    await _savePreferences();
  }

  @visibleForTesting
  Future<void> pollMetricsForTesting() {
    return _pollMetrics();
  }

  @visibleForTesting
  Future<void> pruneStaleSourcesForTesting({DateTime? now}) {
    return _pruneStaleSources(now: now);
  }

  @visibleForTesting
  Future<void> reconnectNowForTesting() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    return _runReconnectAttempt(_reconnectGeneration);
  }

  @visibleForTesting
  List<Duration> get reconnectDelaysForTesting => _reconnectDelays;

  @override
  void notifyListeners() {
    if (_isDisposed) {
      return;
    }
    super.notifyListeners();
  }

  @override
  void dispose() {
    if (_isDisposed) {
      return;
    }
    _isDisposed = true;
    _meterTimer?.cancel();
    _profileApplyTimer?.cancel();
    _discoveryIdleTimer?.cancel();
    _streamConnectionTimer?.cancel();
    _reconnectTimer?.cancel();
    _sourcePruneTimer?.cancel();
    _preferencesSaveTimer?.cancel();
    if (_preferencesReady && _preferencesDirty) {
      unawaited(_savePreferences());
    }
    _resetAutoCodecSession();
    _stopVirtualMicPassthrough();
    unawaited(_engine.disconnect().catchError((Object _) {}));
    unawaited(_discoveryService.dispose().catchError((Object _) {}));
    super.dispose();
  }

  void _upsertDevice(RelayDevice device) {
    final nextDevices = List<RelayDevice>.of(devices);
    final index = nextDevices.indexWhere(
      (candidate) => candidate.id == device.id,
    );

    if (index == -1) {
      nextDevices.add(device);
    } else {
      nextDevices[index] = device;
    }

    nextDevices.sort((left, right) => right.lastSeen.compareTo(left.lastSeen));
    devices = List.unmodifiable(nextDevices);
    final selected = selectedDevice;
    final selectedDeviceSeen =
        selected?.id == device.id ||
        (isReconnecting &&
            selected != null &&
            selected.name == device.name &&
            selected.platform == device.platform);
    if (selectedDeviceSeen) {
      selectedDevice = device;
      profile = _receiverProfileFor(device.profile);
      selectedPreset = profile.mode;
    }
    _scheduleSourcePrune();
    notifyListeners();
    if (selectedDeviceSeen && isReconnecting) {
      _scheduleReconnectAttempt(delay: Duration.zero, replace: true);
    }
  }

  void _startMeters() {
    _meterTimer?.cancel();
    _meterTimer = Timer.periodic(const Duration(milliseconds: 450), (_) {
      _pollMetrics();
    });
  }

  void _stopMeters() {
    _meterTimer?.cancel();
    _meterTimer = null;
    metrics = AudioRelayMetrics.empty;
    _adaptiveFormatBaseline = null;
    _adaptiveFormatPressureScoreValue = 0;
    _adaptiveFormatQuietPolls = 0;
  }

  void _scheduleDiscoveryIdleTimeout() {
    _discoveryIdleTimer?.cancel();
    if (_discoveryIdleTimeout.isNegative) {
      return;
    }

    _discoveryIdleTimer = Timer(_discoveryIdleTimeout, () {
      unawaited(_pauseInactiveDiscovery());
    });
  }

  void _cancelDiscoveryIdleTimeout() {
    _discoveryIdleTimer?.cancel();
    _discoveryIdleTimer = null;
  }

  void _scheduleSourcePrune() {
    _sourcePruneTimer?.cancel();
    if (_sourceStaleTimeout.isNegative ||
        role != RelayRole.receiver ||
        isUsbTunnelTransport ||
        devices.isEmpty ||
        activity == RelayActivity.idle ||
        activity == RelayActivity.error) {
      _sourcePruneTimer = null;
      return;
    }

    final now = DateTime.now();
    var nextDelay = _sourceStaleTimeout;
    for (final device in devices) {
      final expiresIn = device.lastSeen
          .add(_sourceStaleTimeout)
          .difference(now);
      if (expiresIn <= Duration.zero) {
        nextDelay = Duration.zero;
        break;
      }
      if (expiresIn < nextDelay) {
        nextDelay = expiresIn;
      }
    }

    _sourcePruneTimer = Timer(nextDelay, () {
      unawaited(_pruneStaleSources());
    });
  }

  void _cancelSourcePrune() {
    _sourcePruneTimer?.cancel();
    _sourcePruneTimer = null;
  }

  Future<void> _pruneStaleSources({DateTime? now}) async {
    if (_isDisposed ||
        _sourceStaleTimeout.isNegative ||
        role != RelayRole.receiver ||
        isUsbTunnelTransport ||
        devices.isEmpty) {
      _cancelSourcePrune();
      return;
    }

    final currentTime = now ?? DateTime.now();
    final selectedId = selectedDevice?.id;
    final freshDevices = [
      for (final device in devices)
        if (currentTime.difference(device.lastSeen) <= _sourceStaleTimeout)
          device,
    ];
    final selectedExpired =
        selectedId != null &&
        freshDevices.every((device) => device.id != selectedId);

    if (freshDevices.length == devices.length && !selectedExpired) {
      _scheduleSourcePrune();
      return;
    }

    devices = List.unmodifiable(freshDevices);
    if (selectedExpired) {
      if (isStreaming) {
        _enterReconnecting('Source advertisement was lost. Reconnecting...');
        return;
      }
      selectedDevice = null;
    }

    notifyListeners();
    _scheduleSourcePrune();
  }

  Future<void> _pauseInactiveDiscovery() async {
    if (_isDisposed || !isDiscovering) {
      return;
    }

    _cancelDiscoveryIdleTimeout();
    if (activity == RelayActivity.scanning) {
      await _discoveryService.stopScanning();
      devices = const [];
      selectedDevice = null;
    } else {
      await _engine.disconnect();
      await _discoveryService.dispose();
      _appliedSenderProfile = null;
      _resetAutoCodecSession();
    }
    _cancelSourcePrune();

    activity = RelayActivity.idle;
    signalLevel = 0;
    noticeMessage =
        'Paused ${role.label.toLowerCase()} discovery after '
        '${_durationLabel(_discoveryIdleTimeout)} without a connection.';
    notifyListeners();
  }

  void _startStreamConnectionWatch() {
    _cancelReconnect();
    _streamPeerConnected = false;
    _hasConnectedThisSession = false;
    _scheduleStreamConnectionTimeout();
  }

  void _scheduleStreamConnectionTimeout() {
    _streamConnectionTimer?.cancel();
    final timeout = _activeStreamConnectionTimeout;
    if (timeout.isNegative) {
      return;
    }

    _streamConnectionTimer = Timer(timeout, () {
      unawaited(_stopUnconnectedStream());
    });
  }

  void _cancelStreamConnectionTimeout() {
    _streamConnectionTimer?.cancel();
    _streamConnectionTimer = null;
    _streamPeerConnected = false;
    _hasConnectedThisSession = false;
  }

  Future<void> _stopUnconnectedStream() async {
    if (_isDisposed || !isStreaming) {
      return;
    }
    if (_streamPeerConnected) {
      return;
    }

    final timeout = _activeStreamConnectionTimeout;
    final message = role == RelayRole.sender
        ? 'Stopped stream after ${_durationLabel(timeout)} '
              'without reconnecting to a receiver.'
        : 'Stopped stream after ${_durationLabel(timeout)} '
              'without reconnecting to the source.';
    await stopStream();
    noticeMessage = message;
    notifyListeners();
  }

  Duration get _activeStreamConnectionTimeout {
    return role == RelayRole.receiver
        ? _receiverNoAudioTimeout
        : _streamConnectionTimeout;
  }

  void _enterReconnecting(String message) {
    if (_isDisposed || !isStreaming) {
      return;
    }

    _streamPeerConnected = false;
    if (!isReconnecting) {
      activity = RelayActivity.reconnecting;
      _reconnectAttempt = 0;
      noticeMessage = message;
      if (_streamConnectionTimer == null) {
        _scheduleStreamConnectionTimeout();
      }
      notifyListeners();
    }
    _scheduleReconnectAttempt();
  }

  void _scheduleReconnectAttempt({Duration? delay, bool replace = false}) {
    if (_isDisposed || !isReconnecting || _reconnectAttemptInFlight) {
      return;
    }
    if (_reconnectTimer != null && !replace) {
      return;
    }

    _reconnectTimer?.cancel();
    final retryDelay =
        delay ??
        _reconnectDelays[min(_reconnectAttempt, _reconnectDelays.length - 1)];
    final generation = _reconnectGeneration;
    _reconnectTimer = Timer(retryDelay, () {
      _reconnectTimer = null;
      unawaited(_runReconnectAttempt(generation));
    });
  }

  Future<void> _runReconnectAttempt(int generation) async {
    if (!_isReconnectCurrent(generation) || _reconnectAttemptInFlight) {
      return;
    }

    _reconnectAttemptInFlight = true;
    try {
      if (role == RelayRole.receiver) {
        await _reconnectReceiver(generation);
      } else {
        await _reconnectSender(generation);
      }
    } on PlatformException catch (error) {
      if (_isReconnectCurrent(generation)) {
        noticeMessage =
            error.message ?? 'Connection is still unavailable. Retrying...';
        notifyListeners();
      }
    } on SocketException catch (error) {
      if (_isReconnectCurrent(generation)) {
        noticeMessage = '${error.message} Retrying...';
        notifyListeners();
      }
    } on OSError catch (error) {
      if (_isReconnectCurrent(generation)) {
        noticeMessage = '${error.message} Retrying...';
        notifyListeners();
      }
    } finally {
      _reconnectAttemptInFlight = false;
      if (_isReconnectCurrent(generation)) {
        _reconnectAttempt += 1;
        _scheduleReconnectAttempt();
      }
    }
  }

  Future<void> _reconnectReceiver(int generation) async {
    if (usesNetworkDiscovery) {
      await _refreshLocalAddress(requireUsable: true);
      if (!_isReconnectCurrent(generation)) {
        return;
      }
      await _discoveryService.startScanning(
        _upsertDevice,
        scope: _discoveryNetworkScope,
      );
    }

    final target = connectionTarget;
    if (target == null || !_isReconnectCurrent(generation)) {
      return;
    }

    final receiverProfile = _receiverProfileFor(target.profile);
    await _engine.stopStream();
    if (!_isReconnectCurrent(generation)) {
      return;
    }
    if (target.transport == RelayTransport.usb) {
      await _engine.prepareUsbReceiver(receiverProfile);
    } else {
      await _engine.prepareReceiver(receiverProfile);
      if (!_isReconnectCurrent(generation)) {
        return;
      }
      await _engine.connectToSender(target, receiverProfile);
    }
    if (!_isReconnectCurrent(generation)) {
      return;
    }
    await _engine.startStream(receiverProfile);
  }

  Future<void> _reconnectSender(int generation) async {
    final senderProfile = _materializedSenderProfile(profile);
    if (usesNetworkDiscovery) {
      await _refreshLocalAddress(requireUsable: true);
      if (!_isReconnectCurrent(generation)) {
        return;
      }
      await _engine.prepareSender(
        senderProfile,
        networkBindAddress: _networkBindAddress,
      );
      if (!_isReconnectCurrent(generation)) {
        return;
      }
      await _startAdvertisingCurrentProfile(senderProfile);
    } else {
      await _engine.prepareUsbSender(senderProfile);
    }
    if (!_isReconnectCurrent(generation)) {
      return;
    }
    await _engine.startStream(senderProfile);
    _appliedSenderProfile = senderProfile;
  }

  bool _isReconnectCurrent(int generation) {
    return !_isDisposed && generation == _reconnectGeneration && isReconnecting;
  }

  void _cancelReconnect() {
    _reconnectGeneration += 1;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempt = 0;
  }

  Future<void> _updateStreamConnectionFromMetrics(
    AudioRelayMetrics nextMetrics,
  ) async {
    if (!isStreaming) {
      _cancelStreamConnectionTimeout();
      _cancelReconnect();
      return;
    }

    if (nextMetrics.peerConnected == true) {
      final reconnected = isReconnecting && _hasConnectedThisSession;
      _streamPeerConnected = true;
      _hasConnectedThisSession = true;
      _streamConnectionTimer?.cancel();
      _streamConnectionTimer = null;
      _cancelReconnect();
      if (isReconnecting) {
        activity = RelayActivity.streaming;
        noticeMessage = reconnected ? 'Connection restored.' : null;
        notifyListeners();
      }
      return;
    }

    if (nextMetrics.peerConnected != false) {
      return;
    }

    _enterReconnecting(
      _hasConnectedThisSession
          ? 'Connection interrupted. Reconnecting...'
          : 'Waiting for the other device. Reconnecting...',
    );
  }

  Future<void> _pollMetrics() async {
    if (_metricsPollInFlight) {
      return;
    }

    _metricsPollInFlight = true;
    try {
      final nextMetrics = await _engine.getMetrics();
      metrics = nextMetrics;
      await _updateStreamConnectionFromMetrics(nextMetrics);
      if (!isStreaming || isReconnecting) {
        return;
      }
      signalLevel = muted ? 0 : nextMetrics.signalLevel ?? 0;
      _updateAdaptiveFormatPressureFromMetrics(nextMetrics);
      _syncReceiverProfileFromMetrics(nextMetrics);
      await _fallbackUnsupportedManualCodecFromMetrics(nextMetrics);
      _updateAutoCodecFromMetrics(nextMetrics);
      _updateAdaptiveSenderProfileFromMetrics();
      if (isStreaming) {
        notifyListeners();
      }
    } finally {
      _metricsPollInFlight = false;
    }
  }

  void _fail(String message) {
    _cancelReconnect();
    _cancelDiscoveryIdleTimeout();
    _cancelStreamConnectionTimeout();
    _cancelSourcePrune();
    activity = RelayActivity.error;
    errorMessage = message;
    noticeMessage = null;
    _stopMeters();
    _cancelPendingProfileApply();
    notifyListeners();
  }

  void _updateProfile(AudioProfile nextProfile) {
    final previousProfile = profile;
    nextProfile = _profileForCurrentRole(_normalizeProfile(nextProfile));
    if (profile.hasSameSettings(nextProfile)) {
      return;
    }
    final applyReason = _profileChangeApplyReason(previousProfile, nextProfile);
    if (applyReason == _AdaptiveProfileApplyReason.liveBufferPolicy ||
        previousProfile.adaptiveBitrate != nextProfile.adaptiveBitrate ||
        previousProfile.adaptiveSampleRate != nextProfile.adaptiveSampleRate ||
        previousProfile.codec != nextProfile.codec) {
      _resetAdaptiveFormatBaselines();
    }
    profile = nextProfile;
    selectedPreset = profile.mode;
    _saveCustomProfileIfNeeded(profile);
    notifyListeners();
    _schedulePreferencesSave();
    _scheduleActiveProfileApply(reason: applyReason);
  }

  bool _canChangeRestartRequiredSenderSetting() {
    return role != RelayRole.sender || !isStreaming;
  }

  _AdaptiveProfileApplyReason _profileChangeApplyReason(
    AudioProfile previousProfile,
    AudioProfile nextProfile,
  ) {
    if (role == RelayRole.sender &&
        isStreaming &&
        _isLiveBufferPolicyOnlyChange(previousProfile, nextProfile)) {
      return _AdaptiveProfileApplyReason.liveBufferPolicy;
    }
    return _AdaptiveProfileApplyReason.settings;
  }

  bool _isLiveBufferPolicyOnlyChange(
    AudioProfile previousProfile,
    AudioProfile nextProfile,
  ) {
    final sameConcreteFormat =
        previousProfile.codec == nextProfile.codec &&
        previousProfile.outputBackend == nextProfile.outputBackend &&
        previousProfile.sampleRate == nextProfile.sampleRate &&
        previousProfile.effectiveBitrateKbps ==
            nextProfile.effectiveBitrateKbps &&
        previousProfile.adaptiveSampleRate == nextProfile.adaptiveSampleRate &&
        previousProfile.adaptiveBitrate == nextProfile.adaptiveBitrate &&
        previousProfile.captureBufferMs == nextProfile.captureBufferMs &&
        previousProfile.channels == nextProfile.channels;
    if (!sameConcreteFormat) {
      return false;
    }

    return previousProfile.latencyMs != nextProfile.latencyMs ||
        previousProfile.playbackBufferMs != nextProfile.playbackBufferMs ||
        previousProfile.packetTimeMs != nextProfile.packetTimeMs ||
        previousProfile.receiverAdaptiveBuffer !=
            nextProfile.receiverAdaptiveBuffer ||
        previousProfile.adaptiveBufferCapMs != nextProfile.adaptiveBufferCapMs;
  }

  void _resetAdaptiveFormatBaselines() {
    final snapshot = _AdaptiveMetricsSnapshot.fromMetrics(metrics);
    _adaptiveFormatBaseline = snapshot;
    _autoCodecBaseline = snapshot;
    _adaptiveFormatPressureScoreValue = 0;
    _adaptiveFormatQuietPolls = 0;
  }

  void _updateAdaptiveFormatPressureFromMetrics(AudioRelayMetrics nextMetrics) {
    if (role != RelayRole.sender ||
        !isStreaming ||
        (!profile.adaptiveBitrate && !profile.adaptiveSampleRate)) {
      _adaptiveFormatBaseline = null;
      _adaptiveFormatPressureScoreValue = 0;
      _adaptiveFormatQuietPolls = 0;
      return;
    }

    final snapshot = _AdaptiveMetricsSnapshot.fromMetrics(nextMetrics);
    final baseline = _adaptiveFormatBaseline;
    if (baseline == null) {
      _adaptiveFormatBaseline = snapshot;
      _adaptiveFormatPressureScoreValue = 0;
      _adaptiveFormatQuietPolls = 0;
      return;
    }

    final nextScore = _adaptiveFormatPressureScoreFromEvents(
      baseline.transportEventDelta(nextMetrics),
    );
    _adaptiveFormatBaseline = snapshot;
    if (nextScore > 0) {
      _adaptiveFormatPressureScoreValue = max(
        _adaptiveFormatPressureScoreValue,
        nextScore,
      );
      _adaptiveFormatQuietPolls = 0;
      return;
    }

    if (_adaptiveFormatPressureScoreValue <= 0) {
      _adaptiveFormatQuietPolls = 0;
      return;
    }

    _adaptiveFormatQuietPolls += 1;
    if (_adaptiveFormatQuietPolls >= _adaptiveFormatRecoveryPolls) {
      _adaptiveFormatPressureScoreValue -= 1;
      _adaptiveFormatQuietPolls = 0;
    }
  }

  void _syncReceiverProfileFromMetrics(AudioRelayMetrics nextMetrics) {
    if (role != RelayRole.receiver || !isStreaming) {
      return;
    }

    final activeProfile = nextMetrics.activeProfile;
    if (activeProfile == null) {
      return;
    }

    final nextProfile = _receiverProfileFor(_normalizeProfile(activeProfile));
    if (profile.hasSameSettings(nextProfile)) {
      return;
    }

    profile = nextProfile;
    selectedPreset = profile.mode;
  }

  void _updateAdaptiveSenderProfileFromMetrics() {
    if (role != RelayRole.sender ||
        !isStreaming ||
        (!profile.adaptiveBitrate && !profile.adaptiveSampleRate)) {
      return;
    }

    final currentProfile = _appliedSenderProfile;
    if (currentProfile == null) {
      return;
    }

    final nextProfile = _resolveSenderProfile(
      profile,
      reason: _AdaptiveProfileApplyReason.metrics,
    );
    if (_concreteSenderProfilesMatch(currentProfile, nextProfile)) {
      return;
    }

    _scheduleActiveProfileApply(reason: _AdaptiveProfileApplyReason.metrics);
  }

  bool _concreteSenderProfilesMatch(
    AudioProfile currentProfile,
    AudioProfile nextProfile,
  ) {
    return currentProfile.codec == nextProfile.codec &&
        currentProfile.outputBackend == nextProfile.outputBackend &&
        currentProfile.sampleRate == nextProfile.sampleRate &&
        currentProfile.effectiveBitrateKbps ==
            nextProfile.effectiveBitrateKbps &&
        currentProfile.captureBufferMs == nextProfile.captureBufferMs &&
        currentProfile.playbackBufferMs == nextProfile.playbackBufferMs &&
        currentProfile.packetTimeMs == nextProfile.packetTimeMs &&
        currentProfile.channels == nextProfile.channels &&
        currentProfile.receiverAdaptiveBuffer ==
            nextProfile.receiverAdaptiveBuffer &&
        currentProfile.adaptiveBufferCapMs == nextProfile.adaptiveBufferCapMs;
  }

  AudioProfile _profileForPreset(AudioPreset preset) {
    return preset.profile;
  }

  Future<void> _loadSavedCustomProfile() async {
    final savedProfile = await _profileStore.loadCustomProfile();
    _savedCustomProfile = _normalizeProfile(
      _profileForSavedCustom(savedProfile ?? AudioPreset.custom.profile),
    );
  }

  Future<void> _loadSavedPreferences() async {
    final AudioRelayPreferences? savedPreferences;
    try {
      savedPreferences = await _preferencesStore.loadPreferences();
    } catch (_) {
      return;
    }
    if (savedPreferences == null) {
      return;
    }

    role = savedPreferences.role;
    transport = supportsTransport(savedPreferences.transport)
        ? savedPreferences.transport
        : RelayTransport.wifi;
    profile = _normalizeProfile(savedPreferences.profile);
    receiverOutputBackend = savedPreferences.receiverOutputBackend;
    volume = savedPreferences.volume;
    muted = savedPreferences.muted;
    soundboardItems = List.unmodifiable(
      savedPreferences.soundboardPaths.map(_soundboardItemForPath),
    );
    final selectedSoundboardPath = savedPreferences.selectedSoundboardPath;
    selectedSoundboardItem = soundboardItems
        .where((item) => item.path == selectedSoundboardPath)
        .firstOrNull;
    selectedSoundboardItem ??= soundboardItems.firstOrNull;
    soundboardTarget = savedPreferences.soundboardTarget;
    selectedSoundboardOutputDeviceId =
        savedPreferences.selectedSoundboardOutputDeviceId;
    soundboardVolume = savedPreferences.soundboardVolume;
  }

  Future<void> _applyRestoredEnginePreferences() async {
    try {
      await _engine.setVolume(volume);
      await _engine.setMuted(muted);
    } on PlatformException {
      // Keep the restored UI values if the native backend is unavailable.
    }
  }

  AudioRelayPreferences _preferencesSnapshot() {
    return AudioRelayPreferences(
      role: role,
      transport: transport,
      profile: profile,
      receiverOutputBackend: receiverOutputBackend,
      volume: volume,
      muted: muted,
      soundboardPaths: soundboardItems
          .map((item) => item.path)
          .toList(growable: false),
      selectedSoundboardPath: selectedSoundboardItem?.path,
      soundboardTarget: soundboardTarget,
      selectedSoundboardOutputDeviceId: selectedSoundboardOutputDeviceId,
      soundboardVolume: soundboardVolume,
    );
  }

  void _schedulePreferencesSave() {
    if (!_preferencesReady) {
      return;
    }
    _preferencesDirty = true;
    _preferencesSaveTimer?.cancel();
    _preferencesSaveTimer = Timer(_preferencesSaveDelay, () {
      _preferencesSaveTimer = null;
      unawaited(_savePreferences());
    });
  }

  Future<void> _savePreferences() async {
    final preferences = _preferencesSnapshot();
    _preferencesDirty = false;
    try {
      await _preferencesStore.savePreferences(preferences);
    } catch (_) {
      _preferencesDirty = true;
    }
  }

  AudioProfile _profileForSavedCustom(AudioProfile sourceProfile) {
    final customProfile = sourceProfile.copyWith(
      mode: AudioPreset.custom,
      outputBackend: OutputAudioBackend.auto,
    );
    final capMs = _effectiveAdaptiveBufferCap(customProfile);
    return customProfile.copyWith(adaptiveBufferCapMs: capMs);
  }

  AudioProfile _activeSenderPolicyProfileFor(AudioProfile requestedProfile) {
    final activeProfile = _appliedSenderProfile;
    if (activeProfile == null) {
      return requestedProfile;
    }

    return requestedProfile.copyWith(
      codec: activeProfile.codec,
      outputBackend: activeProfile.outputBackend,
      sampleRate: activeProfile.sampleRate,
      bitrateKbps: activeProfile.bitrateKbps,
      adaptiveSampleRate: false,
      adaptiveBitrate: false,
      captureBufferMs: activeProfile.captureBufferMs,
      channels: activeProfile.channels,
    );
  }

  void _saveCustomProfileIfNeeded(AudioProfile nextProfile) {
    if (nextProfile.mode != AudioPreset.custom) {
      return;
    }

    _savedCustomProfile = _profileForSavedCustom(nextProfile);
    _persistCustomProfile(_savedCustomProfile);
  }

  void _persistCustomProfile(AudioProfile customProfile) {
    unawaited(
      _profileStore.saveCustomProfile(customProfile).catchError((Object _) {}),
    );
  }

  void _applyTransportProfile(RelayTransport nextTransport) {
    if (nextTransport == RelayTransport.usb) {
      profile = _profileForCurrentRole(
        _normalizeProfile(AudioProfile.usbLowLatency),
      );
      selectedPreset = profile.mode;
      return;
    }
    if (nextTransport == RelayTransport.usbTethering) {
      profile = _profileForCurrentRole(
        _normalizeProfile(AudioProfile.usbTetheringLowLatency),
      );
      selectedPreset = profile.mode;
      return;
    }

    if (profile.hasSameStreamSettings(AudioProfile.usbLowLatency) ||
        profile.hasSameStreamSettings(AudioProfile.usbTetheringLowLatency)) {
      profile = _profileForCurrentRole(AudioPreset.balanced.profile);
      selectedPreset = AudioPreset.balanced;
    }
  }

  AudioProfile _profileForCurrentRole(AudioProfile sourceProfile) {
    return role == RelayRole.receiver
        ? _receiverProfileFor(sourceProfile)
        : sourceProfile.copyWith(outputBackend: OutputAudioBackend.auto);
  }

  AudioProfile _receiverProfileFor(AudioProfile sourceProfile) {
    return sourceProfile.copyWith(outputBackend: receiverOutputBackend);
  }

  AudioProfile _normalizeProfile(AudioProfile nextProfile) {
    final channels = nextProfile.channels.clamp(1, 2).toInt();
    final formatNormalized = nextProfile.channels == channels
        ? nextProfile
        : nextProfile.copyWith(channels: channels);
    final sampleRateNormalized = switch (formatNormalized.codec) {
      AudioCodec.opus =>
        formatNormalized.sampleRate == 48000
            ? formatNormalized
            : formatNormalized.copyWith(sampleRate: 48000),
      _ => formatNormalized,
    };
    final normalized = sampleRateNormalized.copyWith(
      adaptiveSampleRate: sampleRateNormalized.codec == AudioCodec.opus
          ? false
          : sampleRateNormalized.adaptiveSampleRate,
      adaptiveBitrate: _supportsAdaptiveBitrate(sampleRateNormalized)
          ? sampleRateNormalized.adaptiveBitrate
          : false,
    );

    if (normalized.mode != AudioPreset.custom) {
      return normalized.copyWith(adaptiveBufferCapMs: 0);
    }

    return normalized.copyWith(
      adaptiveBufferCapMs: _effectiveAdaptiveBufferCap(normalized),
    );
  }

  bool _supportsAdaptiveBitrate(AudioProfile nextProfile) {
    if (nextProfile.codec == AudioCodec.auto) {
      return capabilities.supportsCodec(AudioCodec.opus) ||
          capabilities.supportsCodec(AudioCodec.aac);
    }
    return _hasConfigurableBitrate(nextProfile.codec);
  }

  int _effectiveAdaptiveBufferCap(AudioProfile nextProfile) {
    final requestedMs = nextProfile.playbackBufferMs.clamp(
      AudioProfile.minBufferMs,
      AudioProfile.maxBufferMs,
    );
    final fallbackCapMs = max(
      requestedMs,
      AudioPreset.custom.profile.adaptiveBufferCapMs,
    );
    final capMs = nextProfile.adaptiveBufferCapMs <= 0
        ? fallbackCapMs
        : nextProfile.adaptiveBufferCapMs;
    return capMs.clamp(requestedMs, AudioProfile.maxBufferMs).toInt();
  }

  int _adaptiveMaxPlaybackBufferMsForProfile(AudioProfile nextProfile) {
    final requestedMs = nextProfile.playbackBufferMs.clamp(
      AudioProfile.minBufferMs,
      AudioProfile.maxBufferMs,
    );
    final capMs = switch (nextProfile.mode) {
      AudioPreset.gaming => _adaptiveGamingCapMs,
      AudioPreset.balanced => _adaptiveBalancedCapMs,
      AudioPreset.music => AudioProfile.maxBufferMs,
      AudioPreset.custom => _effectiveAdaptiveBufferCap(nextProfile),
    };
    return capMs.clamp(requestedMs, AudioProfile.maxBufferMs).toInt();
  }

  void _scheduleActiveProfileApply({
    _AdaptiveProfileApplyReason reason = _AdaptiveProfileApplyReason.settings,
  }) {
    if (role != RelayRole.sender ||
        (activity != RelayActivity.advertising && !isStreaming)) {
      return;
    }

    _pendingProfileApplyReason = _mergeProfileApplyReasons(
      _profileApplyPending
          ? _pendingProfileApplyReason
          : _AdaptiveProfileApplyReason.settings,
      reason,
    );
    _profileApplyPending = true;
    _profileApplyTimer?.cancel();
    _profileApplyTimer = Timer(_profileApplyDelay, () {
      unawaited(_applyPendingProfile());
    });
  }

  _AdaptiveProfileApplyReason _mergeProfileApplyReasons(
    _AdaptiveProfileApplyReason current,
    _AdaptiveProfileApplyReason next,
  ) {
    if (current == _AdaptiveProfileApplyReason.liveBufferPolicy ||
        next == _AdaptiveProfileApplyReason.liveBufferPolicy) {
      return _AdaptiveProfileApplyReason.liveBufferPolicy;
    }
    if (current == _AdaptiveProfileApplyReason.metrics ||
        next == _AdaptiveProfileApplyReason.metrics) {
      return _AdaptiveProfileApplyReason.metrics;
    }
    return next;
  }

  Future<void> _applyPendingProfile() async {
    if (_profileApplyInFlight) {
      return;
    }

    _profileApplyInFlight = true;
    try {
      while (_profileApplyPending) {
        _profileApplyPending = false;
        final applyReason = _pendingProfileApplyReason;
        _pendingProfileApplyReason = _AdaptiveProfileApplyReason.settings;
        final nextProfile = profile;
        try {
          await _refreshActiveSenderProfile(nextProfile, reason: applyReason);
        } on PlatformException catch (error) {
          _fail(error.message ?? 'Unable to apply audio settings.');
          return;
        } on SocketException catch (error) {
          _fail('Unable to advertise audio settings: ${error.message}');
          return;
        } on OSError catch (error) {
          _fail('Unable to advertise audio settings: ${error.message}');
          return;
        }
      }
    } finally {
      _profileApplyInFlight = false;
      if (_profileApplyPending) {
        _profileApplyTimer?.cancel();
        _profileApplyTimer = Timer(Duration.zero, () {
          unawaited(_applyPendingProfile());
        });
      }
    }
  }

  Future<void> _refreshActiveSenderProfile(
    AudioProfile nextProfile, {
    required _AdaptiveProfileApplyReason reason,
  }) async {
    if (role != RelayRole.sender) {
      return;
    }

    final senderProfile = _resolveSenderProfile(
      nextProfile,
      reason: activity == RelayActivity.streaming
          ? reason
          : _AdaptiveProfileApplyReason.settings,
    );
    if (activity == RelayActivity.advertising) {
      if (isUsbTunnelTransport) {
        await _engine.prepareUsbSender(senderProfile);
        _appliedSenderProfile = senderProfile;
        _rememberAutoResolvedCodec(senderProfile);
      } else {
        await _engine.prepareSender(
          senderProfile,
          networkBindAddress: _networkBindAddress,
        );
        _appliedSenderProfile = senderProfile;
        _rememberAutoResolvedCodec(senderProfile);
        await _startAdvertisingCurrentProfile(senderProfile);
      }
      return;
    }

    if (isReconnecting) {
      _appliedSenderProfile = senderProfile;
      return;
    }

    if (activity != RelayActivity.streaming) {
      return;
    }

    if (_canUpdateActiveSenderProfileWithoutRestart(
      senderProfile,
      allowCodecChange:
          reason == _AdaptiveProfileApplyReason.receiverCodecFallback,
      allowBitrateChange: profile.adaptiveBitrate,
    )) {
      if (usesNetworkDiscovery) {
        await _startAdvertisingCurrentProfile(senderProfile);
      }
      if (activity != RelayActivity.streaming || role != RelayRole.sender) {
        return;
      }
      if (isUsbTunnelTransport) {
        await _engine.prepareUsbSender(senderProfile);
      } else {
        await _engine.prepareSender(
          senderProfile,
          networkBindAddress: _networkBindAddress,
        );
      }
      _appliedSenderProfile = senderProfile;
      _rememberAutoResolvedCodec(senderProfile);
    }
  }

  bool _canUpdateActiveSenderProfileWithoutRestart(
    AudioProfile nextProfile, {
    bool allowCodecChange = false,
    bool allowBitrateChange = false,
  }) {
    final currentProfile = _appliedSenderProfile;
    if (currentProfile == null) {
      return false;
    }

    return (allowCodecChange || currentProfile.codec == nextProfile.codec) &&
        currentProfile.outputBackend == nextProfile.outputBackend &&
        currentProfile.sampleRate == nextProfile.sampleRate &&
        (allowCodecChange ||
            allowBitrateChange ||
            currentProfile.effectiveBitrateKbps ==
                nextProfile.effectiveBitrateKbps) &&
        currentProfile.captureBufferMs == nextProfile.captureBufferMs &&
        currentProfile.channels == nextProfile.channels;
  }

  void _resetAutoCodecSession() {
    _autoResolvedCodec = AudioCodec.pcm;
    _autoCodecStartedAt = null;
    _autoCodecQuietSince = null;
    _autoCodecLastSwitchAt = null;
    _autoCodecBaseline = null;
    _adaptiveFormatBaseline = null;
    _adaptiveFormatPressureScoreValue = 0;
    _adaptiveFormatQuietPolls = 0;
    _autoCodecApplyInFlight = false;
  }

  AudioProfile get _displayProfile {
    final appliedProfile = _appliedSenderProfile;
    if (role == RelayRole.sender && isStreaming && appliedProfile != null) {
      return appliedProfile;
    }

    final displayProfile = profile.codec == AudioCodec.auto
        ? _normalizeProfile(profile.copyWith(codec: _autoResolvedCodec))
        : profile;
    return _resolveSenderProfile(
      displayProfile,
      reason: _AdaptiveProfileApplyReason.display,
    );
  }

  AudioProfile _materializedSenderProfile(AudioProfile sourceProfile) {
    return _resolveSenderProfile(
      sourceProfile,
      reason: _AdaptiveProfileApplyReason.settings,
    );
  }

  AudioProfile _resolveSenderProfile(
    AudioProfile sourceProfile, {
    required _AdaptiveProfileApplyReason reason,
  }) {
    return _adaptiveStreamDecisionMatrix(sourceProfile, reason: reason).profile;
  }

  _AdaptiveStreamMatrixResult _adaptiveStreamDecisionMatrix(
    AudioProfile sourceProfile, {
    required _AdaptiveProfileApplyReason reason,
  }) {
    final pressureScore = _adaptiveFormatPressureScore();
    final currentProfile = _appliedSenderProfile;

    final codec =
        reason == _AdaptiveProfileApplyReason.liveBufferPolicy &&
            currentProfile != null
        ? currentProfile.codec
        : _effectiveSenderCodecFor(sourceProfile);
    final normalizedSource = _normalizeProfile(
      sourceProfile.copyWith(codec: codec),
    );

    if (reason == _AdaptiveProfileApplyReason.liveBufferPolicy &&
        currentProfile != null) {
      final profile = _normalizeProfile(
        normalizedSource.copyWith(
          codec: currentProfile.codec,
          outputBackend: currentProfile.outputBackend,
          sampleRate: currentProfile.sampleRate,
          bitrateKbps: currentProfile.bitrateKbps,
          adaptiveSampleRate: false,
          adaptiveBitrate: false,
          captureBufferMs: currentProfile.captureBufferMs,
          channels: currentProfile.channels,
        ),
      );
      return _AdaptiveStreamMatrixResult(
        profile: profile,
        codec: profile.codec,
        sampleRate: profile.sampleRate,
        bitrateKbps: profile.effectiveBitrateKbps,
        pressureScore: pressureScore,
      );
    }

    final sampleRate = _effectiveSampleRateFor(
      normalizedSource,
      pressureScore: pressureScore,
    );
    final sampleRateProfile = _normalizeProfile(
      normalizedSource.copyWith(sampleRate: sampleRate),
    );
    final bitrateKbps = _effectiveBitrateKbpsFor(
      sampleRateProfile,
      pressureScore: pressureScore,
    );
    final profile = _normalizeProfile(
      sampleRateProfile.copyWith(
        bitrateKbps: bitrateKbps,
        adaptiveSampleRate: false,
        adaptiveBitrate: false,
      ),
    );
    return _AdaptiveStreamMatrixResult(
      profile: profile,
      codec: profile.codec,
      sampleRate: profile.sampleRate,
      bitrateKbps: profile.effectiveBitrateKbps,
      pressureScore: pressureScore,
    );
  }

  int _effectiveSampleRateFor(
    AudioProfile sourceProfile, {
    required int pressureScore,
  }) {
    if (sourceProfile.codec == AudioCodec.opus) {
      return 48000;
    }
    if (!sourceProfile.adaptiveSampleRate) {
      return sourceProfile.sampleRate;
    }

    final currentProfile = _appliedSenderProfile;
    if (isStreaming && currentProfile != null) {
      return currentProfile.sampleRate;
    }

    if (pressureScore >= 4) {
      return 44100;
    }
    if (sourceProfile.mode == AudioPreset.music &&
        pressureScore <= 1 &&
        !isUsbTransport) {
      return 96000;
    }
    return 48000;
  }

  int _effectiveBitrateKbpsFor(
    AudioProfile sourceProfile, {
    required int pressureScore,
  }) {
    if (!sourceProfile.adaptiveBitrate) {
      return sourceProfile.bitrateKbps;
    }

    final range = _bitrateRangeFor(sourceProfile.codec);
    if (range == null) {
      return sourceProfile.bitrateKbps;
    }
    return _adaptiveBitrateKbps(
      sourceProfile,
      range,
      pressureScore: pressureScore,
    );
  }

  int _adaptiveBitrateKbps(
    AudioProfile sourceProfile,
    CodecBitrateRange range, {
    required int pressureScore,
  }) {
    final preferredKbps = _preferredAdaptiveBitrateKbps(sourceProfile, range);
    if (pressureScore >= 7) {
      return range.minKbps;
    }
    if (pressureScore >= 5) {
      return _snapBitrateKbps((range.minKbps + preferredKbps) / 2, range);
    }
    if (pressureScore >= 3) {
      return _snapBitrateKbps(
        range.minKbps * 0.25 + preferredKbps * 0.75,
        range,
      );
    }
    if (pressureScore >= 1) {
      return _snapBitrateKbps(
        range.minKbps * 0.125 + preferredKbps * 0.875,
        range,
      );
    }
    return _clampBitrateKbps(preferredKbps, range);
  }

  int _preferredAdaptiveBitrateKbps(
    AudioProfile sourceProfile,
    CodecBitrateRange range,
  ) {
    return _clampBitrateKbps(sourceProfile.bitrateKbps, range);
  }

  void _rememberAutoResolvedCodec(AudioProfile senderProfile) {
    if (profile.codec == AudioCodec.auto) {
      _autoResolvedCodec = senderProfile.codec;
    }
  }

  Future<void> _fallbackUnsupportedManualCodecFromMetrics(
    AudioRelayMetrics nextMetrics,
  ) async {
    final requestedCodec = profile.codec;
    final remoteSupportedCodecs = nextMetrics.remoteSupportedCodecs;
    if (role != RelayRole.sender ||
        !isStreaming ||
        requestedCodec == AudioCodec.auto ||
        requestedCodec == AudioCodec.pcm ||
        remoteSupportedCodecs.isEmpty ||
        remoteSupportedCodecs.contains(requestedCodec)) {
      return;
    }

    final fallbackProfile = _profileForCurrentRole(
      _normalizeProfile(profile.copyWith(codec: AudioCodec.pcm)),
    );
    profile = fallbackProfile;
    selectedPreset = profile.mode;
    noticeMessage =
        '${requestedCodec.label} is not supported by the receiver; switched to PCM.';
    _resetAdaptiveFormatBaselines();

    try {
      await _refreshActiveSenderProfile(
        fallbackProfile,
        reason: _AdaptiveProfileApplyReason.receiverCodecFallback,
      );
    } on PlatformException catch (error) {
      _fail(
        error.message ?? 'Unable to switch to a receiver-compatible codec.',
      );
    } on SocketException catch (error) {
      _fail('Unable to advertise receiver-compatible codec: ${error.message}');
    } on OSError catch (error) {
      _fail('Unable to advertise receiver-compatible codec: ${error.message}');
    }
  }

  AudioCodec _effectiveSenderCodecFor(AudioProfile sourceProfile) {
    if (sourceProfile.codec != AudioCodec.auto) {
      return sourceProfile.codec;
    }
    if (isStreaming && metrics.remoteSupportedCodecs.isEmpty) {
      return _autoResolvedCodec;
    }
    final remoteKnown = metrics.remoteSupportedCodecs.isNotEmpty;
    final candidates = _autoCodecLocalCandidates(
      remoteSupportedCodecs: metrics.remoteSupportedCodecs,
      requireRemoteSupport: isStreaming || remoteKnown,
    );
    final lowLatencyCodec = remoteKnown
        ? _preferredLowLatencyAutoCodec(sourceProfile, candidates)
        : null;
    if (lowLatencyCodec != null) {
      return lowLatencyCodec;
    }
    return candidates.contains(_autoResolvedCodec)
        ? _autoResolvedCodec
        : AudioCodec.pcm;
  }

  List<AudioCodec> _autoCodecLocalCandidates({
    Set<AudioCodec> remoteSupportedCodecs = const {},
    bool requireRemoteSupport = false,
  }) {
    final localCodecs = capabilities.supportedCodecs;
    final remoteKnown = remoteSupportedCodecs.isNotEmpty;
    final preferredOrder = [
      AudioCodec.pcm,
      AudioCodec.opus,
      AudioCodec.aac,
      AudioCodec.imaAdpcm,
      AudioCodec.g711MuLaw,
      AudioCodec.g711ALaw,
    ];

    final candidates = <AudioCodec>[
      for (final codec in preferredOrder)
        if (localCodecs.contains(codec) &&
            (!requireRemoteSupport ||
                (remoteKnown && remoteSupportedCodecs.contains(codec))))
          codec,
    ];
    if (candidates.isEmpty && localCodecs.contains(AudioCodec.pcm)) {
      return const [AudioCodec.pcm];
    }
    return candidates;
  }

  void _updateAutoCodecFromMetrics(AudioRelayMetrics nextMetrics) {
    if (role != RelayRole.sender ||
        !isStreaming ||
        profile.codec != AudioCodec.auto ||
        _autoCodecApplyInFlight) {
      return;
    }

    final candidates = _autoCodecLocalCandidates(
      remoteSupportedCodecs: nextMetrics.remoteSupportedCodecs,
      requireRemoteSupport: true,
    );
    if (candidates.length <= 1) {
      return;
    }

    final now = DateTime.now();
    _autoCodecStartedAt ??= now;
    _autoCodecBaseline ??= _AdaptiveMetricsSnapshot.fromMetrics(nextMetrics);

    final nextCodec = _chooseAutoCodec(nextMetrics, candidates);
    final isLowLatencyUpgrade = _isPreferredLowLatencyAutoCodec(
      profile,
      nextCodec,
    );
    final warmingUp = now.difference(_autoCodecStartedAt!) < _autoCodecWarmup;
    if (!isLowLatencyUpgrade &&
        (warmingUp || nextCodec == _autoResolvedCodec)) {
      _autoCodecQuietSince = null;
      return;
    }
    if (nextCodec == _autoResolvedCodec) {
      _autoCodecQuietSince = null;
      return;
    }

    final lastSwitchAt = _autoCodecLastSwitchAt;
    if (!isLowLatencyUpgrade &&
        lastSwitchAt != null &&
        now.difference(lastSwitchAt) < _autoCodecSwitchCooldown) {
      return;
    }

    if (!isLowLatencyUpgrade && !_isQuietForAutoCodecSwitch(nextMetrics)) {
      _autoCodecQuietSince = null;
      return;
    }

    if (!isLowLatencyUpgrade) {
      _autoCodecQuietSince ??= now;
      if (now.difference(_autoCodecQuietSince!) < _autoCodecQuietHold) {
        return;
      }
    }

    unawaited(_applyAutoCodecSwitch(nextCodec, nextMetrics));
  }

  AudioCodec _chooseAutoCodec(
    AudioRelayMetrics nextMetrics,
    List<AudioCodec> candidates,
  ) {
    final lowLatencyCodec = _preferredLowLatencyAutoCodec(profile, candidates);
    if (lowLatencyCodec != null) {
      return lowLatencyCodec;
    }

    final pressureScore = _autoCodecPressureScore(nextMetrics);
    if (pressureScore <= 1) {
      return AudioCodec.pcm;
    }

    final compressedPreference = profile.mode == AudioPreset.music
        ? [
            AudioCodec.aac,
            AudioCodec.opus,
            AudioCodec.imaAdpcm,
            AudioCodec.g711MuLaw,
            AudioCodec.g711ALaw,
          ]
        : [
            AudioCodec.opus,
            AudioCodec.aac,
            AudioCodec.imaAdpcm,
            AudioCodec.g711MuLaw,
            AudioCodec.g711ALaw,
          ];
    for (final codec in compressedPreference) {
      if (candidates.contains(codec)) {
        return codec;
      }
    }
    return AudioCodec.pcm;
  }

  AudioCodec? _preferredLowLatencyAutoCodec(
    AudioProfile sourceProfile,
    List<AudioCodec> candidates,
  ) {
    if (!_prefersLowLatencyCompression(sourceProfile)) {
      return null;
    }
    for (final codec in _lowLatencyAutoCodecPreference) {
      if (candidates.contains(codec)) {
        return codec;
      }
    }
    return null;
  }

  bool _isPreferredLowLatencyAutoCodec(
    AudioProfile sourceProfile,
    AudioCodec codec,
  ) {
    return _prefersLowLatencyCompression(sourceProfile) &&
        _lowLatencyAutoCodecPreference.contains(codec);
  }

  bool _prefersLowLatencyCompression(AudioProfile sourceProfile) {
    return sourceProfile.mode == AudioPreset.gaming ||
        sourceProfile.packetTimeMs <= 2 ||
        sourceProfile.playbackBufferMs <= 28;
  }

  int _adaptiveFormatPressureScore() {
    return _adaptiveFormatPressureScoreValue;
  }

  int _adaptiveFormatPressureScoreFromEvents(int eventDelta) {
    if (eventDelta >= 40) {
      return 7;
    }
    if (eventDelta >= 20) {
      return 5;
    }
    if (eventDelta >= 8) {
      return 3;
    }
    return eventDelta >= 3 ? 1 : 0;
  }

  int _autoCodecPressureScore(AudioRelayMetrics nextMetrics) {
    final baseline = _autoCodecBaseline;
    var score = 0;
    final underrunsInWindow = nextMetrics.adaptiveUnderrunsInWindow ?? 0;
    final underrunsInBurst = nextMetrics.adaptiveUnderrunsInBurst ?? 0;
    if (underrunsInBurst >= 2 || underrunsInWindow >= 3) {
      score += 2;
    } else if (underrunsInBurst > 0 || underrunsInWindow > 0) {
      score += 1;
    }

    if (baseline != null) {
      final eventDelta = baseline.eventDelta(nextMetrics);
      if (eventDelta >= 6) {
        score += 2;
      } else if (eventDelta > 0) {
        score += 1;
      }
    }

    final activeBufferMs = nextMetrics.adaptivePlaybackBufferMs;
    if (activeBufferMs != null) {
      final growthMs = activeBufferMs - profile.playbackBufferMs;
      if (growthMs >= 16) {
        score += 2;
      } else if (growthMs >= 8) {
        score += 1;
      }
    }
    if (nextMetrics.adaptiveLimitReached == true) {
      score += 2;
    }
    final lowQueueSamples = nextMetrics.adaptiveLowQueueSamples ?? 0;
    if (lowQueueSamples >= 3) {
      score += 1;
    }
    final queueFill = nextMetrics.playbackQueueFillPercent;
    if (queueFill != null && queueFill < 35) {
      score += 1;
    }
    return score;
  }

  bool _isQuietForAutoCodecSwitch(AudioRelayMetrics nextMetrics) {
    final signal = muted ? 0 : nextMetrics.signalLevel ?? signalLevel;
    return signal <= _autoCodecQuietSignalThreshold;
  }

  Future<void> _applyAutoCodecSwitch(
    AudioCodec codec,
    AudioRelayMetrics nextMetrics,
  ) async {
    if (_autoCodecApplyInFlight ||
        role != RelayRole.sender ||
        activity != RelayActivity.streaming ||
        profile.codec != AudioCodec.auto ||
        codec == _autoResolvedCodec) {
      return;
    }

    _autoCodecApplyInFlight = true;
    try {
      final nextProfile = _resolveSenderProfile(
        _normalizeProfile(profile.copyWith(codec: codec)),
        reason: _AdaptiveProfileApplyReason.autoCodecSwitch,
      );
      if (!_canUpdateActiveSenderProfileWithoutRestart(
        nextProfile,
        allowCodecChange: true,
      )) {
        return;
      }
      if (usesNetworkDiscovery) {
        await _startAdvertisingCurrentProfile(nextProfile);
      }
      if (activity != RelayActivity.streaming || role != RelayRole.sender) {
        return;
      }
      if (isUsbTunnelTransport) {
        await _engine.prepareUsbSender(nextProfile);
      } else {
        await _engine.prepareSender(
          nextProfile,
          networkBindAddress: _networkBindAddress,
        );
      }
      _appliedSenderProfile = nextProfile;
      _autoResolvedCodec = codec;
      _autoCodecQuietSince = null;
      _autoCodecLastSwitchAt = DateTime.now();
      _autoCodecBaseline = _AdaptiveMetricsSnapshot.fromMetrics(nextMetrics);
      notifyListeners();
    } on PlatformException catch (error) {
      _fail(error.message ?? 'Unable to apply adaptive codec.');
    } on SocketException catch (error) {
      _fail('Unable to advertise adaptive codec: ${error.message}');
    } on OSError catch (error) {
      _fail('Unable to advertise adaptive codec: ${error.message}');
    } finally {
      _autoCodecApplyInFlight = false;
    }
  }

  Future<void> _refreshActiveReceiverProfile() async {
    if (role != RelayRole.receiver || activity != RelayActivity.streaming) {
      return;
    }

    final nextProfile = _receiverProfileFor(profile);
    try {
      await _engine.stopStream();
      if (isUsbTunnelTransport) {
        await _engine.prepareUsbReceiver(nextProfile);
      } else {
        final device = selectedDevice;
        if (device == null) {
          return;
        }
        await _engine.prepareReceiver(nextProfile);
        await _engine.connectToSender(device, nextProfile);
      }
      if (role != RelayRole.receiver || activity != RelayActivity.streaming) {
        return;
      }
      await _engine.startStream(nextProfile);
    } on PlatformException catch (error) {
      _fail(error.message ?? 'Unable to apply receiver output backend.');
    }
  }

  Future<void> _startAdvertisingCurrentProfile([
    AudioProfile? advertisedProfile,
  ]) async {
    await _refreshLocalAddress(requireUsable: true);
    final deviceProfile =
        advertisedProfile ??
        (role == RelayRole.sender
            ? _materializedSenderProfile(profile)
            : profile);
    final localDevice = RelayDevice(
      id: '$localDeviceName-$localAddress',
      name: localDeviceName,
      host: localAddress,
      port: DiscoveryService.audioPort,
      transport: transport,
      platform: _currentPlatform(),
      profile: deviceProfile,
      lastSeen: DateTime.now(),
    );
    return _discoveryService.startAdvertising(
      localDevice,
      scope: _discoveryNetworkScope,
    );
  }

  Future<void> _refreshLocalAddress({bool requireUsable = false}) async {
    final scope = _discoveryNetworkScope;
    localAddress = await _discoveryService.localIPv4Address(scope: scope);
    if (requireUsable && localAddress == scope.missingAddressLabel) {
      throw SocketException(scope.missingInterfaceMessage);
    }
  }

  String? get _networkBindAddress {
    if (!usesNetworkDiscovery) {
      return null;
    }
    final scope = _discoveryNetworkScope;
    return localAddress == scope.missingAddressLabel ? null : localAddress;
  }

  DiscoveryNetworkScope get _discoveryNetworkScope {
    return switch (transport) {
      RelayTransport.usbTethering => DiscoveryNetworkScope.usbTethering,
      RelayTransport.wifi => DiscoveryNetworkScope.wifi,
      RelayTransport.usb => DiscoveryNetworkScope.all,
    };
  }

  Future<void> _startNativeUsbReceiver() async {
    devices = const [];
    selectedDevice = null;
    final receiverProfile = _receiverProfileFor(profile);
    profile = receiverProfile;
    await _engine.prepareUsbReceiver(receiverProfile);
    await _engine.startStream(receiverProfile);
    activity = RelayActivity.streaming;
    _startMeters();
  }

  RelayDevice? get _nativeUsbSourceDevice {
    if (role != RelayRole.receiver || !isUsbTunnelTransport) {
      return null;
    }

    final peerPlatform = _nativeUsbPeerPlatform;
    final name = switch (peerPlatform) {
      DevicePlatform.windows => 'Windows USB host',
      DevicePlatform.android => 'Android USB source',
      DevicePlatform.unknown => 'USB audio source',
    };

    return RelayDevice(
      id: _nativeUsbSourceId,
      name: name,
      host: '127.0.0.1',
      port: DiscoveryService.audioPort,
      transport: RelayTransport.usb,
      platform: peerPlatform,
      profile: _receiverProfileFor(profile),
      lastSeen: DateTime.now(),
    );
  }

  DevicePlatform get _nativeUsbPeerPlatform {
    return switch (capabilities.platform.toLowerCase()) {
      'android' => DevicePlatform.windows,
      'windows' => DevicePlatform.android,
      _ => DevicePlatform.unknown,
    };
  }

  void _cancelPendingProfileApply() {
    _profileApplyTimer?.cancel();
    _profileApplyTimer = null;
    _profileApplyPending = false;
    _pendingProfileApplyReason = _AdaptiveProfileApplyReason.settings;
  }

  static RelayRole _defaultRole() {
    return Platform.isAndroid ? RelayRole.receiver : RelayRole.sender;
  }

  static Future<String> _defaultAppVersion() async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      return packageInfo.version;
    } catch (_) {
      return _fallbackAppVersion;
    }
  }

  static String _defaultDeviceName() {
    final hostname = Platform.localHostname.trim();
    if (hostname.isEmpty) {
      return Platform.isWindows ? 'Windows device' : 'Android device';
    }
    return hostname;
  }

  static String _formatByteSize(int sizeBytes) {
    if (sizeBytes <= 0) {
      return 'Unknown size';
    }

    const units = ['B', 'KB', 'MB', 'GB'];
    var value = sizeBytes.toDouble();
    var unitIndex = 0;
    while (value >= 1024 && unitIndex < units.length - 1) {
      value /= 1024;
      unitIndex += 1;
    }
    final decimals = value >= 10 || unitIndex == 0 ? 0 : 1;
    return '${value.toStringAsFixed(decimals)} ${units[unitIndex]}';
  }

  SoundPlaybackItem _soundboardItemForPath(String path) {
    final segments = path.split(RegExp(r'[\\/]'));
    final name = segments.last.trim();
    return SoundPlaybackItem(
      id: path,
      name: name.isEmpty ? 'Sound' : name,
      path: path,
    );
  }

  void _selectDefaultSoundboardOutputDevice() {
    final devices = soundboardOutputDevices;
    if (devices.isEmpty) {
      selectedSoundboardOutputDeviceId = null;
      return;
    }
    final selectedId = selectedSoundboardOutputDeviceId;
    if (selectedId != null &&
        devices.any((device) => device.id == selectedId)) {
      return;
    }
    selectedSoundboardOutputDeviceId = devices.first.id;
  }

  void _syncVirtualMicPassthrough() {
    final device = selectedSoundboardOutputDevice;
    final shouldEnable =
        canUseSoundboard &&
        soundboardTarget == SoundboardPlaybackTarget.micRoute &&
        device != null;
    final nextDeviceId = shouldEnable ? device.id : null;

    if (_virtualMicPassthroughEnabled == shouldEnable &&
        _virtualMicPassthroughOutputDeviceId == nextDeviceId) {
      return;
    }

    _virtualMicPassthroughEnabled = shouldEnable;
    _virtualMicPassthroughOutputDeviceId = nextDeviceId;
    unawaited(
      _engine
          .configureVirtualMicPassthrough(
            enabled: shouldEnable,
            outputDeviceId: nextDeviceId,
          )
          .catchError((Object error) {
            if (shouldEnable) {
              soundboardMessage = 'Unable to bridge your microphone.';
              notifyListeners();
            }
          }),
    );
  }

  void _stopVirtualMicPassthrough() {
    if (!_virtualMicPassthroughEnabled &&
        _virtualMicPassthroughOutputDeviceId == null) {
      return;
    }
    _virtualMicPassthroughEnabled = false;
    _virtualMicPassthroughOutputDeviceId = null;
    unawaited(
      _engine
          .configureVirtualMicPassthrough(enabled: false)
          .catchError((Object _) {}),
    );
  }

  static int _compareSoundboardCableRoutes(
    SoundboardOutputDevice left,
    SoundboardOutputDevice right,
  ) {
    final rankComparison = _soundboardCableRouteRank(
      left,
    ).compareTo(_soundboardCableRouteRank(right));
    if (rankComparison != 0) {
      return rankComparison;
    }
    if (left.isDefault != right.isDefault) {
      return left.isDefault ? -1 : 1;
    }
    return left.name.toLowerCase().compareTo(right.name.toLowerCase());
  }

  static bool _isDedicatedSoundboardCableRoute(SoundboardOutputDevice device) {
    final label = _soundboardCableRouteLabel(device);
    if (label.contains('16ch') || label.contains('16 ch')) {
      return false;
    }
    return label.contains('vb-audio virtual cable') ||
        label.contains('cable input') ||
        label.contains('cable in') ||
        (label.contains('virtual cable') && !label.contains('voicemeeter'));
  }

  static int _soundboardCableRouteRank(SoundboardOutputDevice device) {
    final label = _soundboardCableRouteLabel(device);
    if (label.contains('16ch') || label.contains('16 ch')) {
      return 99;
    }
    if (label.contains('cable input')) {
      return 0;
    }
    if (label.contains('speakers (vb-audio virtual cable)')) {
      return 1;
    }
    if (label.contains('cable in')) {
      return 2;
    }
    if (label.contains('vb-audio virtual cable') ||
        label.contains('virtual cable') && !label.contains('voicemeeter')) {
      return 3;
    }
    if (label.contains('voicemeeter')) {
      return 4;
    }
    return 5;
  }

  static String _soundboardCableRouteLabel(SoundboardOutputDevice device) {
    return '${device.name} ${device.id}'.toLowerCase();
  }

  static String _callMicrophoneNameForRoute(SoundboardOutputDevice device) {
    final name = device.name.trim();
    final label = _soundboardCableRouteLabel(device);
    if (label.contains('vb-audio virtual cable') ||
        label.contains('cable input') ||
        label.contains('cable in')) {
      return 'CABLE Output (VB-Audio Virtual Cable)';
    }
    if (name.isEmpty) {
      return 'Call microphone';
    }
    final inputName = name.replaceAll(
      RegExp('input', caseSensitive: false),
      'Output',
    );
    return inputName == name ? name : inputName;
  }

  static DevicePlatform _currentPlatform() {
    if (Platform.isWindows) {
      return DevicePlatform.windows;
    }
    if (Platform.isAndroid) {
      return DevicePlatform.android;
    }
    return DevicePlatform.unknown;
  }

  static String _durationLabel(Duration duration) {
    if (duration.inMinutes >= 1 && duration.inSeconds % 60 == 0) {
      return '${duration.inMinutes} min';
    }
    if (duration.inSeconds >= 1) {
      return '${duration.inSeconds} sec';
    }
    return 'a moment';
  }

  AudioCodec get _bitrateTargetCodec {
    if (profile.codec != AudioCodec.auto) {
      return profile.codec;
    }
    if (_hasConfigurableBitrate(_autoResolvedCodec)) {
      return _autoResolvedCodec;
    }
    if (capabilities.supportsCodec(AudioCodec.opus)) {
      return AudioCodec.opus;
    }
    if (capabilities.supportsCodec(AudioCodec.aac)) {
      return AudioCodec.aac;
    }
    return _autoResolvedCodec;
  }

  bool _hasConfigurableBitrate(AudioCodec codec) {
    return codec == AudioCodec.opus || codec == AudioCodec.aac;
  }

  CodecBitrateRange? _bitrateRangeFor(AudioCodec codec) {
    final nativeRange = capabilities.codecBitrateRanges[codec];
    if (nativeRange != null &&
        nativeRange.minKbps > 0 &&
        nativeRange.maxKbps >= nativeRange.minKbps) {
      return nativeRange;
    }
    return switch (codec) {
      AudioCodec.opus => const CodecBitrateRange(minKbps: 64, maxKbps: 256),
      AudioCodec.aac => const CodecBitrateRange(minKbps: 96, maxKbps: 192),
      _ => null,
    };
  }

  int _snapBitrateKbps(double value, CodecBitrateRange range) {
    const stepKbps = 8;
    final clamped = value.clamp(range.minKbps, range.maxKbps).toDouble();
    final snapped = (clamped / stepKbps).round() * stepKbps;
    return _clampBitrateKbps(snapped, range);
  }

  int _clampBitrateKbps(int value, CodecBitrateRange range) {
    return value.clamp(range.minKbps, range.maxKbps).toInt();
  }

  int _framesForMs(int milliseconds) {
    return (_displayProfile.sampleRate * milliseconds / 1000).round();
  }

  static String _formatSampleRate(int sampleRate) {
    if (sampleRate % 1000 == 0) {
      return '${sampleRate ~/ 1000} kHz';
    }
    return '${(sampleRate / 1000).toStringAsFixed(1)} kHz';
  }

  int _opusFrameSamplesForPacketTime(int milliseconds) {
    if (milliseconds <= 2) {
      return 120;
    }
    if (milliseconds <= 5) {
      return 240;
    }
    return 480;
  }

  int _clampBufferMs(double value) {
    return value.round().clamp(
      AudioProfile.minBufferMs,
      AudioProfile.maxBufferMs,
    );
  }

  String _detailFeelLabel() {
    if (profile.sampleRate >= 96000) {
      return 'Audio keeps the most high-frequency detail available in this app.';
    }
    if (profile.sampleRate >= 48000) {
      return 'Audio should sound full-range for games, video, and music.';
    }
    return 'Audio is efficient, with slightly less high-frequency headroom.';
  }

  String _latencyFeelLabel() {
    final effectiveLatencyMs =
        profile.captureBufferMs + profile.playbackBufferMs;
    if (effectiveLatencyMs <= 35 && profile.packetTimeMs <= 2) {
      return 'Input-to-speaker delay should feel very low.';
    }
    if (effectiveLatencyMs <= 80) {
      return 'Delay should be noticeable only in timing-sensitive use.';
    }
    return 'Delay will be obvious, but playback should be calmer.';
  }

  String _stabilityFeelLabel() {
    if (profile.playbackBufferMs >= 80) {
      if (isUsbTunnelTransport) {
        return 'The larger receiver buffer gives the phone more room if native USB scheduling stalls.';
      }
      if (isUsbTetheringTransport) {
        return 'The larger receiver buffer helps hide jitter on the tethered network link.';
      }
      return 'The larger receiver buffer helps hide Wi-Fi jitter and dropouts.';
    }
    if (profile.playbackBufferMs >= 35) {
      if (isUsbTunnelTransport) {
        return 'The receiver has a moderate cushion for normal native USB scheduling variation.';
      }
      if (isUsbTetheringTransport) {
        return 'The receiver has a moderate cushion for normal USB tethering jitter.';
      }
      return 'The receiver has a moderate cushion for normal Wi-Fi jitter.';
    }
    if (isUsbTunnelTransport) {
      return 'The small receiver buffer needs a stable native USB path to avoid pops.';
    }
    if (isUsbTetheringTransport) {
      return 'The small receiver buffer needs a stable tethered network link to avoid pops.';
    }
    return 'The small receiver buffer needs a clean network to avoid pops.';
  }

  String _networkLoadFeelLabel() {
    if (profile.effectiveBitrateKbps >= 2500) {
      if (isUsbTunnelTransport) {
        return 'Native USB load is high, so keep packet time low only on a stable cable.';
      }
      if (isUsbTetheringTransport) {
        return 'Tethered network load is high, so keep packet time low only on a stable cable.';
      }
      return 'Network load is high, so use this near a strong router.';
    }
    if (profile.effectiveBitrateKbps >= 1400) {
      if (isUsbTunnelTransport) {
        return 'Native USB load is moderate for PCM audio.';
      }
      if (isUsbTetheringTransport) {
        return 'Tethered network load is moderate for PCM audio.';
      }
      return 'Network load is moderate for modern Wi-Fi.';
    }
    if (isUsbTunnelTransport) {
      return 'Native USB load is light, which helps reliability.';
    }
    if (isUsbTetheringTransport) {
      return 'Tethered network load is light, which helps reliability.';
    }
    return 'Network load is light, which helps reliability.';
  }
}

class _AdaptiveStreamMatrixResult {
  const _AdaptiveStreamMatrixResult({
    required this.profile,
    required this.codec,
    required this.sampleRate,
    required this.bitrateKbps,
    required this.pressureScore,
  });

  final AudioProfile profile;
  final AudioCodec codec;
  final int sampleRate;
  final int bitrateKbps;
  final int pressureScore;
}

class _AdaptiveMetricsSnapshot {
  const _AdaptiveMetricsSnapshot({
    required this.underruns,
    required this.droppedPackets,
    required this.lostPackets,
    required this.trims,
  });

  final int underruns;
  final int droppedPackets;
  final int lostPackets;
  final int trims;

  factory _AdaptiveMetricsSnapshot.fromMetrics(AudioRelayMetrics metrics) {
    return _AdaptiveMetricsSnapshot(
      underruns: metrics.underrunCount ?? 0,
      droppedPackets: metrics.droppedPacketCount ?? 0,
      lostPackets: metrics.lostPacketCount ?? 0,
      trims: metrics.trimCount ?? 0,
    );
  }

  int eventDelta(AudioRelayMetrics metrics) {
    return _positiveDelta(metrics.underrunCount, underruns) +
        _positiveDelta(metrics.droppedPacketCount, droppedPackets) +
        _positiveDelta(metrics.lostPacketCount, lostPackets) +
        _positiveDelta(metrics.trimCount, trims);
  }

  int transportEventDelta(AudioRelayMetrics metrics) {
    return _positiveDelta(metrics.droppedPacketCount, droppedPackets) +
        _positiveDelta(metrics.lostPacketCount, lostPackets);
  }

  int _positiveDelta(int? current, int previous) {
    final delta = (current ?? 0) - previous;
    return delta > 0 ? delta : 0;
  }
}
