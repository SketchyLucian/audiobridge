import 'package:flutter/material.dart';

import '../application/audio_relay_controller.dart';
import '../data/discovery_service.dart';
import '../domain/audio_relay_models.dart';

extension _AudioProfileDisplay on AudioProfile {
  String get sourceSampleRateText {
    if (sampleRate % 1000 == 0) {
      return '${sampleRate ~/ 1000} kHz';
    }
    return '${(sampleRate / 1000).toStringAsFixed(1)} kHz';
  }

  String get sourceChannelText {
    return switch (channels) {
      1 => 'Mono',
      2 => 'Stereo',
      _ => '$channels channels',
    };
  }

  String get sourceBitrateText => '$effectiveBitrateKbps kbps';

  String get sourcePacketTimeText => '$packetTimeMs ms';

  String get sourceSummaryText {
    return '${codec.label} · $sourceSampleRateText · $sourceChannelText · $sourceBitrateText';
  }
}

class AudioRelayScreen extends StatefulWidget {
  const AudioRelayScreen({super.key});

  @override
  State<AudioRelayScreen> createState() => _AudioRelayScreenState();
}

class _AudioRelayScreenState extends State<AudioRelayScreen> {
  late final AudioRelayController controller;

  @override
  void initState() {
    super.initState();
    controller = AudioRelayController();
    controller.initialize();
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final width = MediaQuery.sizeOf(context).width;
        final compact = width < 820;

        return Scaffold(
          appBar: AppBar(
            title: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.spatial_audio_off_rounded),
                SizedBox(width: 10),
                Text('AudioBridge'),
              ],
            ),
            actions: [
              Padding(
                padding: const EdgeInsets.only(right: 16),
                child: _StatusPill(activity: controller.activity),
              ),
            ],
          ),
          body: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1180),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _Header(controller: controller),
                      const SizedBox(height: 16),
                      if (compact)
                        Column(
                          children: [
                            _ControlPanel(controller: controller),
                            const SizedBox(height: 16),
                            _DevicesPanel(controller: controller),
                          ],
                        )
                      else
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              flex: 6,
                              child: _ControlPanel(controller: controller),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              flex: 5,
                              child: _DevicesPanel(controller: controller),
                            ),
                          ],
                        ),
                      const SizedBox(height: 16),
                      _SettingsPanel(controller: controller),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.controller});

  final AudioRelayController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final roleSupported = controller.canUseSelectedRole;

    return _Panel(
      child: Wrap(
        spacing: 16,
        runSpacing: 16,
        crossAxisAlignment: WrapCrossAlignment.center,
        alignment: WrapAlignment.spaceBetween,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  controller.localDeviceName,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${controller.capabilities.platform} · ${controller.localAddress}',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          SegmentedButton<RelayRole>(
            segments: const [
              ButtonSegment(
                value: RelayRole.sender,
                icon: Icon(Icons.desktop_windows_rounded),
                label: Text('Sender'),
              ),
              ButtonSegment(
                value: RelayRole.receiver,
                icon: Icon(Icons.phone_android_rounded),
                label: Text('Receiver'),
              ),
            ],
            selected: {controller.role},
            onSelectionChanged: controller.isBusy
                ? null
                : (selection) {
                    controller.setRole(selection.first);
                  },
          ),
          SegmentedButton<RelayTransport>(
            segments: const [
              ButtonSegment(
                value: RelayTransport.wifi,
                icon: Icon(Icons.wifi_rounded),
                label: Text('Wi-Fi'),
              ),
              ButtonSegment(
                value: RelayTransport.usbTethering,
                icon: Icon(Icons.settings_ethernet_rounded),
                label: Text('USB tether'),
              ),
              ButtonSegment(
                value: RelayTransport.usb,
                icon: Icon(Icons.usb_rounded),
                label: Text('Native USB'),
              ),
            ],
            selected: {controller.transport},
            onSelectionChanged: controller.isBusy
                ? null
                : (selection) {
                    controller.setTransport(selection.first);
                  },
          ),
          _CapabilityChip(
            supported: roleSupported,
            label: roleSupported ? 'Backend available' : 'Backend missing',
          ),
        ],
      ),
    );
  }
}

class _ControlPanel extends StatelessWidget {
  const _ControlPanel({required this.controller});

  final AudioRelayController controller;

  @override
  Widget build(BuildContext context) {
    final profile = controller.profile;

    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _PanelTitle(
            icon: controller.role == RelayRole.sender
                ? Icons.settings_input_component_rounded
                : Icons.speaker_rounded,
            title: controller.role == RelayRole.sender
                ? 'Audio source'
                : 'Audio playback',
            trailing: Text(controller.activity.label),
          ),
          const SizedBox(height: 18),
          _PrimaryControls(controller: controller),
          if (controller.errorMessage != null) ...[
            const SizedBox(height: 14),
            _ErrorBanner(message: controller.errorMessage!),
          ],
          const SizedBox(height: 20),
          _SignalMeter(value: controller.signalLevel, muted: controller.muted),
          const SizedBox(height: 18),
          Row(
            children: [
              Icon(
                controller.muted
                    ? Icons.volume_off_rounded
                    : Icons.volume_up_rounded,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Slider(
                  value: controller.volume,
                  onChanged: (value) {
                    controller.updateVolume(value);
                  },
                ),
              ),
              SizedBox(
                width: 48,
                child: Text(
                  '${(controller.volume * 100).round()}%',
                  textAlign: TextAlign.end,
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filledTonal(
                tooltip: controller.muted ? 'Unmute' : 'Mute',
                onPressed: () {
                  controller.updateMuted(!controller.muted);
                },
                icon: Icon(
                  controller.muted
                      ? Icons.volume_off_rounded
                      : Icons.volume_mute_rounded,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _MetricTile(
                icon: Icons.speed_rounded,
                label: controller.latencyMetricLabel,
                value: controller.liveLatencyLabel,
              ),
              _MetricTile(
                icon: Icons.tune_rounded,
                label: 'Buffering',
                value: controller.bufferingLabel,
              ),
              _MetricTile(
                icon: Icons.graphic_eq_rounded,
                label: 'Codec',
                value: controller.codecStatusLabel,
              ),
              _MetricTile(
                icon: Icons.surround_sound_rounded,
                label: 'Channels',
                value: profile.sourceChannelText,
              ),
              _MetricTile(
                icon: Icons.equalizer_rounded,
                label: 'Sample rate',
                value: profile.sourceSampleRateText,
              ),
              _MetricTile(
                icon: Icons.network_check_rounded,
                label: 'Bitrate',
                value: controller.streamBitrateLabel,
              ),
              _MetricTile(
                icon: Icons.av_timer_rounded,
                label: 'Packet',
                value: profile.sourcePacketTimeText,
              ),
              _MetricTile(
                icon: controller.isUsbTransport
                    ? Icons.usb_rounded
                    : Icons.memory_rounded,
                label: controller.transport.label,
                value: controller.transportHealthLabel,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PrimaryControls extends StatelessWidget {
  const _PrimaryControls({required this.controller});

  final AudioRelayController controller;

  @override
  Widget build(BuildContext context) {
    final connectionTarget = controller.connectionTarget;

    if (controller.role == RelayRole.sender) {
      return Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          if (controller.isStreaming)
            FilledButton.icon(
              onPressed: controller.stopStream,
              icon: const Icon(Icons.stop_rounded),
              label: const Text('Stop stream'),
            )
          else if (controller.activity == RelayActivity.advertising)
            FilledButton.icon(
              onPressed: controller.startSenderStream,
              icon: const Icon(Icons.play_arrow_rounded),
              label: const Text('Start audio'),
            )
          else
            FilledButton.icon(
              onPressed: controller.startDiscovery,
              icon: Icon(
                controller.isUsbTransport
                    ? Icons.usb_rounded
                    : Icons.sensors_rounded,
              ),
              label: Text(controller.primaryActionLabel),
            ),
          if (controller.isDiscovering || controller.isStreaming)
            OutlinedButton.icon(
              onPressed: controller.stopAll,
              icon: const Icon(Icons.power_settings_new_rounded),
              label: const Text('Stop hosting'),
            ),
        ],
      );
    }

    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        if (controller.isStreaming)
          FilledButton.icon(
            onPressed: controller.stopStream,
            icon: const Icon(Icons.link_off_rounded),
            label: const Text('Disconnect'),
          )
        else if (connectionTarget != null)
          FilledButton.icon(
            onPressed: () {
              controller.connectToDevice(connectionTarget);
            },
            icon: const Icon(Icons.cable_rounded),
            label: const Text('Connect'),
          )
        else
          FilledButton.icon(
            onPressed: controller.startDiscovery,
            icon: Icon(
              controller.isUsbTransport
                  ? Icons.usb_rounded
                  : Icons.radar_rounded,
            ),
            label: Text(controller.primaryActionLabel),
          ),
        if (controller.activity == RelayActivity.scanning)
          OutlinedButton.icon(
            onPressed: controller.stopAll,
            icon: const Icon(Icons.stop_circle_outlined),
            label: const Text('Stop scan'),
          ),
      ],
    );
  }
}

class _DevicesPanel extends StatelessWidget {
  const _DevicesPanel({required this.controller});

  final AudioRelayController controller;

  @override
  Widget build(BuildContext context) {
    final devices = controller.visibleDevices;

    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _PanelTitle(
            icon: Icons.hub_rounded,
            title: controller.endpointTitle,
            trailing: Text(
              controller.isUsbTunnelTransport
                  ? controller.transport.label
                  : '${devices.length} found',
            ),
          ),
          const SizedBox(height: 16),
          if (controller.role == RelayRole.sender)
            _EndpointDetails(controller: controller)
          else if (devices.isEmpty)
            _EmptyDevices(activity: controller.activity)
          else
            Column(
              children: [
                for (final device in devices)
                  _DeviceRow(
                    device: device,
                    selected: controller.isDeviceSelected(device),
                    onTap: () {
                      controller.selectDevice(device);
                    },
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class _EndpointDetails extends StatelessWidget {
  const _EndpointDetails({required this.controller});

  final AudioRelayController controller;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _EndpointRow(
          icon: controller.isUsbTransport
              ? Icons.usb_rounded
              : Icons.lan_rounded,
          label: controller.endpointHostLabel,
          value: controller.endpointHostValue,
        ),
        if (controller.usesNetworkDiscovery)
          _EndpointRow(
            icon: Icons.travel_explore_rounded,
            label: 'Discovery',
            value: 'UDP ${DiscoveryService.discoveryPort}',
          )
        else
          _EndpointRow(
            icon: Icons.sync_alt_rounded,
            label: 'Transport',
            value: controller.usbSetupLabel,
          ),
        _EndpointRow(
          icon: Icons.settings_ethernet_rounded,
          label: 'Audio',
          value: controller.endpointAudioValue,
        ),
        _EndpointRow(
          icon: Icons.devices_rounded,
          label: 'Role',
          value: controller.role.label,
        ),
      ],
    );
  }
}

class _SettingsPanel extends StatelessWidget {
  const _SettingsPanel({required this.controller});

  final AudioRelayController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final senderControlsSettings = controller.role == RelayRole.sender;
    final settingsLocked = !controller.canEditAudioSettings;

    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _PanelTitle(
            icon: Icons.tune_rounded,
            title: 'Audio settings',
            trailing: Text(
              senderControlsSettings
                  ? controller.presetLabel
                  : controller.settingsAuthorityLabel,
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: 10),
          if (!senderControlsSettings)
            _ReceiverAudioSettingsSummary(controller: controller)
          else
            _UnifiedAudioSettings(
              controller: controller,
              settingsLocked: settingsLocked,
            ),
        ],
      ),
    );
  }
}

class _ReceiverAudioSettingsSummary extends StatelessWidget {
  const _ReceiverAudioSettingsSummary({required this.controller});

  final AudioRelayController controller;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            _SettingValueChip(
              icon: Icons.speed_rounded,
              label: 'Sample rate',
              value: controller.sampleRateLabel,
            ),
            _SettingValueChip(
              icon: Icons.spatial_audio_rounded,
              label: 'Channels',
              value: controller.channelModeLabel,
            ),
            _SettingValueChip(
              icon: controller.isUsbTransport
                  ? Icons.usb_rounded
                  : Icons.wifi_rounded,
              label: 'Transport',
              value: controller.transport.label,
            ),
            _SettingValueChip(
              icon: Icons.graphic_eq_rounded,
              label: 'Format',
              value: controller.profileSummary,
            ),
          ],
        ),
        const SizedBox(height: 14),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: _SettingBlock(
            compact: true,
            title: 'Output backend',
            description:
                'This only affects playback on this receiver. Sender stream settings stay with the source.',
            child: _OutputBackendPicker(
              backend: controller.receiverOutputBackend,
              enabled: controller.canEditReceiverOutputBackend,
              onChanged: controller.updateOutputBackend,
              isSupported: controller.isOutputBackendSupported,
            ),
          ),
        ),
      ],
    );
  }
}

class _UnifiedAudioSettings extends StatelessWidget {
  const _UnifiedAudioSettings({
    required this.controller,
    required this.settingsLocked,
  });

  final AudioRelayController controller;
  final bool settingsLocked;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final narrow = width < 680;
    const columns = 2;
    final profile = controller.profile;
    final compact = width < 420;
    final restartRequiredLocked =
        !controller.canEditRestartRequiredAudioSettings;
    final liveControlsLocked = !controller.canEditLiveAudioSettings;

    final formatControls = [
      _SettingBlock(
        compact: true,
        title: 'Sample rate',
        description:
            'Higher can preserve more detail, but uses more bandwidth and CPU. 48 kHz is the safest default.',
        child: _SampleRatePicker(
          controller: controller,
          enabled: !restartRequiredLocked,
        ),
      ),
      _SettingBlock(
        compact: true,
        title: 'Channels',
        description: 'All modes keep left/right playback positioning.',
        child: _ReadoutValue(
          icon: Icons.surround_sound_rounded,
          value: 'Stereo',
          label: controller.channelModeLabel,
        ),
      ),
      _SettingBlock(
        compact: true,
        title: 'Bitrate',
        description: controller.bitrateTargetDescription,
        child: controller.bitrateTargetRange == null
            ? _ReadoutValue(
                icon: Icons.network_check_rounded,
                value: controller.streamBitrateLabel,
                label: controller.streamBitrateFormatLabel,
              )
            : _BitratePicker(
                controller: controller,
                enabled: !restartRequiredLocked,
              ),
      ),
      _SettingBlock(
        compact: true,
        title: 'Codec',
        description:
            'Auto uses Opus for low-latency modes when supported, then adapts conservative modes after link pressure is clear.',
        child: _CodecPicker(
          codec: profile.codec,
          enabled: !restartRequiredLocked,
          onChanged: controller.updateCodec,
          isSupported: controller.isCodecSupported,
        ),
      ),
    ];

    final timingControls = [
      _SettingBlock(
        compact: true,
        title: 'Sender buffer',
        description:
            'Lower reduces capture delay. Higher gives the sender more room when the device is busy.',
        child: _SettingSlider(
          value: profile.captureBufferMs.toDouble(),
          min: AudioProfile.minBufferMs.toDouble(),
          max: AudioProfile.maxBufferMs.toDouble(),
          divisions: AudioProfile.maxBufferMs - AudioProfile.minBufferMs,
          valueLabel: '${profile.captureBufferMs} ms',
          detail: controller.captureBufferFramesLabel,
          onChanged: restartRequiredLocked
              ? null
              : controller.updateCaptureBuffer,
        ),
      ),
      _SettingBlock(
        compact: true,
        title: 'Receiver buffer',
        description:
            'Lower feels more immediate. Higher adds latency but prevents pops and dropouts on unstable links.',
        child: _SettingSlider(
          value: profile.playbackBufferMs.toDouble(),
          min: AudioProfile.minBufferMs.toDouble(),
          max: AudioProfile.maxBufferMs.toDouble(),
          divisions: AudioProfile.maxBufferMs - AudioProfile.minBufferMs,
          valueLabel: '${profile.playbackBufferMs} ms',
          detail: controller.receiverBufferDetailLabel,
          onChanged: liveControlsLocked
              ? null
              : controller.updatePlaybackBuffer,
        ),
      ),
      _SettingBlock(
        compact: true,
        title: 'Receiver adaptive buffer',
        description: 'Raises the live buffer on bursts or sustained low queue.',
        child: _SettingSwitch(
          value: profile.receiverAdaptiveBuffer,
          valueLabel: controller.receiverAdaptiveBufferLabel,
          detail: controller.receiverAdaptiveBufferDetailLabel,
          onChanged: liveControlsLocked
              ? null
              : controller.updateReceiverAdaptiveBuffer,
        ),
      ),
      if (profile.mode == AudioPreset.custom)
        _SettingBlock(
          compact: true,
          title: 'Adaptive cap',
          description:
              'Limits how far Custom mode may raise receiver buffering.',
          child: _SettingSlider(
            value: controller.customAdaptiveCapMs.toDouble(),
            min: AudioProfile.minBufferMs.toDouble(),
            max: AudioProfile.maxBufferMs.toDouble(),
            divisions: AudioProfile.maxBufferMs - AudioProfile.minBufferMs,
            valueLabel: '${controller.customAdaptiveCapMs} ms',
            detail: controller.customAdaptiveCapDetailLabel,
            onChanged: liveControlsLocked
                ? null
                : controller.updateAdaptiveBufferCap,
          ),
        ),
      _SettingBlock(
        compact: true,
        title: 'Packet time',
        description:
            'Lower sends smaller packets more often for lower delay. Higher reduces network overhead but adds delay.',
        child: _SettingSlider(
          value: profile.packetTimeMs.toDouble(),
          min: AudioProfile.minPacketTimeMs.toDouble(),
          max: AudioProfile.maxPacketTimeMs.toDouble(),
          divisions:
              AudioProfile.maxPacketTimeMs - AudioProfile.minPacketTimeMs,
          valueLabel: '${profile.packetTimeMs} ms',
          detail: controller.packetFramesLabel,
          onChanged: liveControlsLocked ? null : controller.updatePacketTime,
        ),
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _PresetPicker(
          controller: controller,
          settingsLocked: restartRequiredLocked,
          compact: compact,
        ),
        const SizedBox(height: 8),
        _AudibleQualityPreview(controller: controller),
        const SizedBox(height: 8),
        _LiveBufferPreview(controller: controller),
        const SizedBox(height: 8),
        _AdvancedSection(
          title: 'Format and bandwidth',
          controls: formatControls,
          columns: columns,
          narrow: narrow,
        ),
        const SizedBox(height: 8),
        _AdvancedSection(
          title: 'Latency and stability',
          controls: timingControls,
          columns: columns,
          narrow: narrow,
        ),
        const SizedBox(height: 8),
        _SupportedSettingsNote(text: controller.supportedAdvancedSettingsLabel),
      ],
    );
  }
}

class _PresetPicker extends StatelessWidget {
  const _PresetPicker({
    required this.controller,
    required this.settingsLocked,
    required this.compact,
  });

  final AudioRelayController controller;
  final bool settingsLocked;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        SegmentedButton<AudioPreset>(
          showSelectedIcon: false,
          segments: [
            ButtonSegment(
              value: AudioPreset.gaming,
              icon: compact ? null : const Icon(Icons.sports_esports_rounded),
              label: const Text('Gaming'),
            ),
            ButtonSegment(
              value: AudioPreset.balanced,
              icon: compact ? null : const Icon(Icons.balance_rounded),
              label: const Text('Balanced'),
            ),
            ButtonSegment(
              value: AudioPreset.music,
              icon: compact ? null : const Icon(Icons.music_note_rounded),
              label: const Text('Music'),
            ),
            ButtonSegment(
              value: AudioPreset.custom,
              icon: compact ? null : const Icon(Icons.tune_rounded),
              label: const Text('Custom'),
            ),
          ],
          selected: {controller.selectedPreset},
          onSelectionChanged: settingsLocked
              ? null
              : (selection) {
                  if (selection.isNotEmpty) {
                    controller.updatePreset(selection.first);
                  }
                },
        ),
        Tooltip(
          message: 'Save current settings as Custom',
          child: IconButton.filledTonal(
            onPressed: settingsLocked ? null : controller.saveCustomPreset,
            icon: const Icon(Icons.save_rounded),
          ),
        ),
      ],
    );
  }
}

class _AudibleQualityPreview extends StatelessWidget {
  const _AudibleQualityPreview({required this.controller});

  final AudioRelayController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.4),
        ),
        color: theme.colorScheme.primary.withValues(alpha: 0.06),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.hearing_rounded, color: theme.colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  controller.audibleQualityTitle,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  controller.audibleQualityDescription,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LiveBufferPreview extends StatelessWidget {
  const _LiveBufferPreview({required this.controller});

  final AudioRelayController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          _SettingValueChip(
            icon: Icons.flag_rounded,
            label: 'Requested',
            value: controller.playbackBufferLabel,
          ),
          _SettingValueChip(
            icon: Icons.av_timer_rounded,
            label: 'Receiver active',
            value: controller.activePlaybackBufferLabel,
          ),
          _SettingValueChip(
            icon: Icons.warning_amber_rounded,
            label: 'Underruns',
            value: '${controller.metrics.underrunCount ?? 0}',
          ),
          _SettingValueChip(
            icon: Icons.speed_rounded,
            label: 'Queue',
            value: controller.playbackQueueFillLabel,
          ),
          _SettingValueChip(
            icon: Icons.block_rounded,
            label: 'Cap',
            value: controller.adaptiveBufferCapLabel,
          ),
          _SettingValueChip(
            icon: Icons.tune_rounded,
            label: 'Receiver adaptive',
            value: controller.receiverAdaptiveBufferLabel,
          ),
        ],
      ),
    );
  }
}

class _AdvancedSection extends StatelessWidget {
  const _AdvancedSection({
    required this.title,
    required this.controls,
    required this.columns,
    required this.narrow,
  });

  final String title;
  final List<Widget> controls;
  final int columns;
  final bool narrow;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 8),
        if (narrow)
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final control in controls) ...[
                control,
                if (control != controls.last) const SizedBox(height: 8),
              ],
            ],
          )
        else
          GridView.builder(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
              mainAxisExtent: 128,
            ),
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: controls.length,
            itemBuilder: (context, index) => controls[index],
          ),
      ],
    );
  }
}

class _SupportedSettingsNote extends StatelessWidget {
  const _SupportedSettingsNote({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.info_outline_rounded,
            color: theme.colorScheme.secondary,
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SampleRatePicker extends StatelessWidget {
  const _SampleRatePicker({required this.controller, required this.enabled});

  static const _adaptiveValue = 0;

  final AudioRelayController controller;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final options = controller.sampleRateOptions;
    final adaptiveEnabled = controller.canUseAdaptiveSampleRate;
    final selection = controller.profile.adaptiveSampleRate
        ? _adaptiveValue
        : controller.profile.sampleRate;

    return _DropdownWithDetail(
      detail: controller.sampleRateSettingDetailLabel,
      child: DropdownMenu<int>(
        width: double.infinity,
        enabled: enabled,
        initialSelection: selection,
        leadingIcon: const Icon(Icons.graphic_eq_rounded),
        requestFocusOnTap: false,
        onSelected: (value) {
          if (value == null) {
            return;
          }
          if (value == _adaptiveValue) {
            controller.updateAdaptiveSampleRate(true);
            return;
          }
          controller.updateSampleRate(value);
        },
        dropdownMenuEntries: [
          DropdownMenuEntry(
            value: _adaptiveValue,
            enabled: adaptiveEnabled,
            label: 'Adaptive',
            leadingIcon: const Icon(Icons.auto_mode_rounded),
            trailingIcon: Text(
              adaptiveEnabled
                  ? controller.appliedSampleRateLabel
                  : '48 kHz only',
              style: theme.textTheme.labelSmall?.copyWith(
                color: adaptiveEnabled
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          for (final option in options)
            DropdownMenuEntry(
              value: option,
              label: _formatSampleRate(option),
              leadingIcon: const Icon(Icons.speed_rounded),
            ),
        ],
      ),
    );
  }
}

class _BitratePicker extends StatelessWidget {
  const _BitratePicker({required this.controller, required this.enabled});

  static const _adaptiveValue = 0;

  final AudioRelayController controller;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final options = controller.bitrateTargetOptions;
    final selection = controller.profile.adaptiveBitrate
        ? _adaptiveValue
        : controller.bitrateTargetKbps;

    return _DropdownWithDetail(
      detail: controller.bitrateSettingDetailLabel,
      child: DropdownMenu<int>(
        width: double.infinity,
        enabled: enabled,
        initialSelection: selection,
        leadingIcon: const Icon(Icons.network_check_rounded),
        requestFocusOnTap: false,
        onSelected: (value) {
          if (value == null) {
            return;
          }
          if (value == _adaptiveValue) {
            controller.updateAdaptiveBitrate(true);
            return;
          }
          controller.updateBitrate(value.toDouble());
        },
        dropdownMenuEntries: [
          DropdownMenuEntry(
            value: _adaptiveValue,
            label: 'Adaptive',
            leadingIcon: const Icon(Icons.auto_mode_rounded),
            trailingIcon: Text(
              controller.appliedBitrateLabel,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ),
          for (final option in options)
            DropdownMenuEntry(
              value: option,
              label: '$option kbps',
              leadingIcon: const Icon(Icons.speed_rounded),
            ),
        ],
      ),
    );
  }
}

class _DropdownWithDetail extends StatelessWidget {
  const _DropdownWithDetail({required this.child, this.detail});

  final Widget child;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final detail = this.detail;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        child,
        if (detail != null) ...[
          const SizedBox(height: 6),
          Text(
            detail,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }
}

class _CodecPicker extends StatelessWidget {
  const _CodecPicker({
    required this.codec,
    required this.enabled,
    required this.onChanged,
    required this.isSupported,
  });

  final AudioCodec codec;
  final bool enabled;
  final ValueChanged<AudioCodec> onChanged;
  final bool Function(AudioCodec codec) isSupported;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final options = AudioCodec.values
        .where((option) => option.isImplemented && isSupported(option))
        .toList();

    return DropdownMenu<AudioCodec>(
      width: double.infinity,
      enabled: enabled,
      initialSelection: options.contains(codec) ? codec : options.firstOrNull,
      leadingIcon: const Icon(Icons.graphic_eq_rounded),
      requestFocusOnTap: false,
      onSelected: (value) {
        if (value != null && isSupported(value)) {
          onChanged(value);
        }
      },
      dropdownMenuEntries: [
        for (final option in options)
          DropdownMenuEntry(
            value: option,
            enabled: true,
            label: option.label,
            leadingIcon: Icon(_codecIcon(option)),
            trailingIcon: Text(
              'Available',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ),
      ],
    );
  }

  static IconData _codecIcon(AudioCodec codec) {
    return switch (codec) {
      AudioCodec.auto => Icons.auto_awesome_rounded,
      AudioCodec.pcm => Icons.blur_linear_rounded,
      AudioCodec.opus => Icons.compress_rounded,
      AudioCodec.aac => Icons.queue_music_rounded,
      AudioCodec.g711MuLaw ||
      AudioCodec.g711ALaw ||
      AudioCodec.imaAdpcm => Icons.multitrack_audio_rounded,
      _ => Icons.music_note_rounded,
    };
  }
}

String _formatSampleRate(int sampleRate) {
  if (sampleRate % 1000 == 0) {
    return '${sampleRate ~/ 1000} kHz';
  }
  return '${(sampleRate / 1000).toStringAsFixed(1)} kHz';
}

class _OutputBackendPicker extends StatelessWidget {
  const _OutputBackendPicker({
    required this.backend,
    required this.enabled,
    required this.onChanged,
    required this.isSupported,
  });

  final OutputAudioBackend backend;
  final bool enabled;
  final ValueChanged<OutputAudioBackend> onChanged;
  final bool Function(OutputAudioBackend backend) isSupported;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return DropdownMenu<OutputAudioBackend>(
      width: double.infinity,
      enabled: enabled,
      initialSelection: backend,
      leadingIcon: const Icon(Icons.output_rounded),
      requestFocusOnTap: false,
      onSelected: (value) {
        if (value != null && isSupported(value)) {
          onChanged(value);
        }
      },
      dropdownMenuEntries: [
        for (final option in OutputAudioBackend.values)
          DropdownMenuEntry(
            value: option,
            enabled: isSupported(option),
            label: option.label,
            leadingIcon: Icon(_outputBackendIcon(option)),
            trailingIcon: Text(
              isSupported(option) ? 'Available' : option.availabilityLabel,
              style: theme.textTheme.labelSmall?.copyWith(
                color: isSupported(option)
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }

  static IconData _outputBackendIcon(OutputAudioBackend backend) {
    return switch (backend) {
      OutputAudioBackend.auto => Icons.auto_mode_rounded,
      OutputAudioBackend.audioTrack => Icons.phone_android_rounded,
      OutputAudioBackend.oboe => Icons.developer_board_rounded,
      OutputAudioBackend.wasapiShared ||
      OutputAudioBackend.wasapiExclusive => Icons.desktop_windows_rounded,
    };
  }
}

class _SettingSlider extends StatelessWidget {
  const _SettingSlider({
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.valueLabel,
    required this.detail,
    required this.onChanged,
  });

  final double value;
  final double min;
  final double max;
  final int divisions;
  final String valueLabel;
  final String detail;
  final ValueChanged<double>? onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Row(
          children: [
            Expanded(
              child: Slider(
                value: value,
                min: min,
                max: max,
                divisions: divisions,
                onChanged: onChanged,
              ),
            ),
            SizedBox(
              width: 76,
              child: Text(
                valueLabel,
                textAlign: TextAlign.end,
                style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(left: 12, right: 76),
          child: Text(
            detail,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

class _SettingSwitch extends StatelessWidget {
  const _SettingSwitch({
    required this.value,
    required this.valueLabel,
    required this.detail,
    required this.onChanged,
  });

  final bool value;
  final String valueLabel;
  final String detail;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      constraints: const BoxConstraints(minHeight: 48),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  valueLabel,
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  detail,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

class _ReadoutValue extends StatelessWidget {
  const _ReadoutValue({
    required this.icon,
    required this.value,
    required this.label,
  });

  final IconData icon;
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      constraints: const BoxConstraints(minHeight: 48),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        children: [
          Icon(icon, color: theme.colorScheme.secondary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(padding: const EdgeInsets.all(12), child: child),
    );
  }
}

class _PanelTitle extends StatelessWidget {
  const _PanelTitle({required this.icon, required this.title, this.trailing});

  final IconData icon;
  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      children: [
        Icon(icon, color: theme.colorScheme.primary),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            title,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        if (trailing != null)
          DefaultTextStyle.merge(
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            child: trailing!,
          ),
      ],
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.activity});

  final RelayActivity activity;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = switch (activity) {
      RelayActivity.streaming => theme.colorScheme.primary,
      RelayActivity.connecting => theme.colorScheme.tertiary,
      RelayActivity.error => theme.colorScheme.error,
      RelayActivity.advertising ||
      RelayActivity.scanning => theme.colorScheme.secondary,
      RelayActivity.idle => theme.colorScheme.outline,
    };

    return Container(
      constraints: const BoxConstraints(minHeight: 32),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.4)),
        color: color.withValues(alpha: 0.08),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.circle, size: 9, color: color),
          const SizedBox(width: 8),
          Text(activity.label),
        ],
      ),
    );
  }
}

class _CapabilityChip extends StatelessWidget {
  const _CapabilityChip({required this.supported, required this.label});

  final bool supported;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = supported
        ? theme.colorScheme.primary
        : theme.colorScheme.error;

    return Container(
      constraints: const BoxConstraints(minHeight: 36),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: color.withValues(alpha: 0.08),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            supported
                ? Icons.check_circle_outline_rounded
                : Icons.error_outline_rounded,
            size: 18,
            color: color,
          ),
          const SizedBox(width: 8),
          Text(label),
        ],
      ),
    );
  }
}

class _SignalMeter extends StatelessWidget {
  const _SignalMeter({required this.value, required this.muted});

  final double value;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final activeColor = muted
        ? theme.colorScheme.outline
        : theme.colorScheme.primary;
    final label = muted
        ? 'Muted'
        : value <= 0.005
        ? 'No signal'
        : '${(value * 100).round()}%';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Signal', style: theme.textTheme.labelLarge),
            const Spacer(),
            Text(
              label,
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: LinearProgressIndicator(
            value: value.clamp(0, 1),
            minHeight: 12,
            color: activeColor,
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
          ),
        ),
      ],
    );
  }
}

class _MetricTile extends StatelessWidget {
  const _MetricTile({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      width: 150,
      constraints: const BoxConstraints(minHeight: 72),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        children: [
          Icon(icon, color: theme.colorScheme.secondary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DeviceRow extends StatelessWidget {
  const _DeviceRow({
    required this.device,
    required this.selected,
    required this.onTap,
  });

  final RelayDevice device;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final detailText = device.transport == RelayTransport.usb
        ? '${device.transport.label} · USB cable · ${device.profile.sourceSummaryText}'
        : '${device.transport.label} · ${device.host}:${device.port} · ${device.profile.sourceSummaryText}';

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Ink(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outlineVariant,
            ),
            color: selected
                ? theme.colorScheme.primary.withValues(alpha: 0.07)
                : Colors.transparent,
          ),
          child: Row(
            children: [
              Icon(
                device.platform == DevicePlatform.windows
                    ? Icons.desktop_windows_rounded
                    : Icons.devices_other_rounded,
                color: selected
                    ? theme.colorScheme.primary
                    : theme.colorScheme.secondary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      device.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      detailText,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (selected) const Icon(Icons.check_circle_rounded),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyDevices extends StatelessWidget {
  const _EmptyDevices({required this.activity});

  final RelayActivity activity;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(minHeight: 180),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            activity == RelayActivity.scanning
                ? Icons.radar_rounded
                : Icons.devices_rounded,
            size: 36,
            color: theme.colorScheme.secondary,
          ),
          const SizedBox(height: 10),
          Text(
            activity == RelayActivity.scanning
                ? 'Scanning LAN'
                : 'No sources found',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _EndpointRow extends StatelessWidget {
  const _EndpointRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      constraints: const BoxConstraints(minHeight: 48),
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: Row(
        children: [
          Icon(icon, color: theme.colorScheme.secondary),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.end,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingBlock extends StatelessWidget {
  const _SettingBlock({
    required this.title,
    required this.child,
    this.description,
    this.compact = false,
  });

  final String title;
  final Widget child;
  final String? description;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        if (description != null) ...[
          SizedBox(height: compact ? 2 : 4),
          Text(
            description!,
            maxLines: compact ? 2 : 3,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        SizedBox(height: compact ? 6 : 8),
        child,
      ],
    );
  }
}

class _SettingValueChip extends StatelessWidget {
  const _SettingValueChip({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      constraints: const BoxConstraints(minHeight: 44, minWidth: 140),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.secondary),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              Text(
                value,
                style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.error_outline_rounded,
            color: theme.colorScheme.onErrorContainer,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
