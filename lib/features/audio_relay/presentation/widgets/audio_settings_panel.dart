part of '../audio_relay_screen.dart';

class _SettingsPanel extends StatelessWidget {
  const _SettingsPanel({required this.controller});

  final AudioRelayController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final senderControlsSettings = controller.role == RelayRole.sender;

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
            _UnifiedAudioSettings(controller: controller),
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
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _SettingBlock(
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
              const SizedBox(height: 14),
              _SettingBlock(
                compact: true,
                title: 'Silent connection timeout',
                description:
                    'Never keeps this receiver connected through silence and screen lock. Choose a time to disconnect after audio packets stop.',
                child: _SilentConnectionTimeoutPicker(
                  timeout: controller.silentConnectionTimeout,
                  enabled: !controller.isBusy,
                  onChanged: controller.updateSilentConnectionTimeout,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _UnifiedAudioSettings extends StatelessWidget {
  const _UnifiedAudioSettings({required this.controller});

  final AudioRelayController controller;

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
    final audioModeLocked = !controller.canEditAudioMode;

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
        description:
            'Mono combines left and right to reduce bandwidth. Stereo preserves playback positioning.',
        child: _ChannelPicker(
          channels: profile.channels,
          enabled: !restartRequiredLocked,
          onChanged: controller.updateChannels,
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
            'Adaptive uses Opus for low-latency modes when supported, then adapts conservative modes after link pressure is clear.',
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
        titleTrailing: _InlineSettingToggle(
          label: 'Adaptive',
          value: profile.receiverAdaptiveBuffer,
          tooltip: controller.receiverAdaptiveBufferDetailLabel,
          onChanged: liveControlsLocked
              ? null
              : controller.updateReceiverAdaptiveBuffer,
        ),
        description: controller.receiverBufferDescription,
        child: _ReceiverBufferControl(
          controller: controller,
          locked: liveControlsLocked,
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
          settingsLocked: audioModeLocked,
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

    return ListenableBuilder(
      listenable: controller.metricsListenable,
      builder: (context, _) {
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
                label: 'Receiver buffer',
                value:
                    '${controller.activePlaybackBufferLabel} · ${controller.receiverAdaptiveBufferLabel}',
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
            ],
          ),
        );
      },
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
          LayoutBuilder(
            builder: (context, constraints) {
              if (controls.isEmpty) {
                return const SizedBox.shrink();
              }

              final columnCount = controls.length < columns
                  ? controls.length
                  : columns;
              const spacing = 10.0;
              final itemWidth =
                  (constraints.maxWidth - spacing * (columnCount - 1)) /
                  columnCount;

              return Wrap(
                spacing: spacing,
                runSpacing: spacing,
                children: [
                  for (final control in controls)
                    SizedBox(width: itemWidth, child: control),
                ],
              );
            },
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

class _ChannelPicker extends StatelessWidget {
  const _ChannelPicker({
    required this.channels,
    required this.enabled,
    required this.onChanged,
  });

  final int channels;
  final bool enabled;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<int>(
      key: const ValueKey('channel-picker'),
      expandedInsets: EdgeInsets.zero,
      showSelectedIcon: false,
      segments: const [
        ButtonSegment(
          value: 1,
          icon: Icon(Icons.speaker_rounded),
          label: Text('Mono', key: ValueKey('mono-channel-option')),
        ),
        ButtonSegment(
          value: 2,
          icon: Icon(Icons.surround_sound_rounded),
          label: Text('Stereo', key: ValueKey('stereo-channel-option')),
        ),
      ],
      selected: {channels},
      onSelectionChanged: enabled
          ? (selection) {
              onChanged(selection.first);
            }
          : null,
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

class _SilentConnectionTimeoutPicker extends StatelessWidget {
  const _SilentConnectionTimeoutPicker({
    required this.timeout,
    required this.enabled,
    required this.onChanged,
  });

  final Duration? timeout;
  final bool enabled;
  final ValueChanged<Duration?> onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownMenu<int>(
      key: const ValueKey('silent-connection-timeout-picker'),
      width: double.infinity,
      enabled: enabled,
      initialSelection: timeout?.inSeconds ?? 0,
      leadingIcon: const Icon(Icons.timer_off_outlined),
      requestFocusOnTap: false,
      onSelected: (seconds) {
        if (seconds == null) {
          return;
        }
        onChanged(seconds == 0 ? null : Duration(seconds: seconds));
      },
      dropdownMenuEntries: [
        for (final option
            in AudioRelayController.silentConnectionTimeoutOptions)
          DropdownMenuEntry(
            value: option?.inSeconds ?? 0,
            label: _timeoutLabel(option),
            leadingIcon: Icon(
              option == null
                  ? Icons.all_inclusive_rounded
                  : Icons.timer_outlined,
            ),
          ),
      ],
    );
  }

  static String _timeoutLabel(Duration? timeout) {
    if (timeout == null) {
      return 'Never';
    }
    if (timeout.inMinutes >= 1 && timeout.inSeconds % 60 == 0) {
      return '${timeout.inMinutes} min';
    }
    return '${timeout.inSeconds} sec';
  }
}

class _ReceiverBufferControl extends StatelessWidget {
  const _ReceiverBufferControl({
    required this.controller,
    required this.locked,
  });

  final AudioRelayController controller;
  final bool locked;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller.metricsListenable,
      builder: (context, _) {
        final profile = controller.profile;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _SettingSlider(
              value: profile.playbackBufferMs.toDouble(),
              min: AudioProfile.minBufferMs.toDouble(),
              max: AudioProfile.maxBufferMs.toDouble(),
              divisions: AudioProfile.maxBufferMs - AudioProfile.minBufferMs,
              valueLabel: controller.receiverBufferValueLabel,
              detail: controller.receiverBufferDetailLabel,
              onChanged: locked ? null : controller.updatePlaybackBuffer,
            ),
          ],
        );
      },
    );
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

class _InlineSettingToggle extends StatelessWidget {
  const _InlineSettingToggle({
    required this.label,
    required this.value,
    required this.tooltip,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final String tooltip;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = onChanged != null;
    final foregroundColor = enabled
        ? theme.colorScheme.onSurface
        : theme.colorScheme.onSurfaceVariant;
    final borderColor = value && enabled
        ? theme.colorScheme.secondary.withValues(alpha: 0.65)
        : theme.colorScheme.outlineVariant;
    final backgroundColor = value && enabled
        ? theme.colorScheme.secondaryContainer.withValues(alpha: 0.42)
        : Colors.transparent;

    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: enabled ? () => onChanged!(!value) : null,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            constraints: const BoxConstraints(minHeight: 28),
            padding: const EdgeInsets.only(left: 8, right: 2),
            decoration: BoxDecoration(
              color: backgroundColor,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: borderColor),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: foregroundColor,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                SizedBox(
                  width: 38,
                  height: 24,
                  child: IgnorePointer(
                    child: FittedBox(
                      fit: BoxFit.contain,
                      child: Switch(
                        value: value,
                        onChanged: enabled ? onChanged : null,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
