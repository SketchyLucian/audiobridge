import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../application/audio_relay_controller.dart';
import '../data/discovery_service.dart';
import '../domain/audio_relay_models.dart';
import '../domain/update_models.dart';

part 'widgets/soundboard_panel.dart';
part 'widgets/audio_settings_panel.dart';

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

const _soundboardAudioTypeGroup = XTypeGroup(
  label: 'Audio',
  extensions: ['wav', 'mp3', 'm4a', 'aac', 'wma', 'flac'],
);

class AudioRelayScreen extends StatefulWidget {
  const AudioRelayScreen({super.key, this.controller});

  final AudioRelayController? controller;

  @override
  State<AudioRelayScreen> createState() => _AudioRelayScreenState();
}

class _AudioRelayScreenState extends State<AudioRelayScreen> {
  late final AudioRelayController controller;
  late final AppLifecycleListener _lifecycleListener;
  late final bool _ownsController;

  @override
  void initState() {
    super.initState();
    controller = widget.controller ?? AudioRelayController();
    _ownsController = widget.controller == null;
    _lifecycleListener = AppLifecycleListener(
      onStateChange: (state) {
        if (state == AppLifecycleState.inactive ||
            state == AppLifecycleState.paused ||
            state == AppLifecycleState.hidden ||
            state == AppLifecycleState.detached) {
          unawaited(controller.flushPreferences());
        }
      },
      onExitRequested: () async {
        await controller.flushPreferences();
        return AppExitResponse.exit;
      },
    );
    if (_ownsController) {
      controller.initialize();
    }
  }

  @override
  void dispose() {
    _lifecycleListener.dispose();
    if (_ownsController) {
      unawaited(controller.flushPreferences());
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
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
              bottom: const TabBar(
                tabs: [
                  Tab(
                    key: ValueKey('relay-tab'),
                    icon: Icon(Icons.settings_input_antenna_rounded),
                    text: 'Relay',
                  ),
                  Tab(
                    key: ValueKey('soundboard-tab'),
                    icon: Icon(Icons.library_music_rounded),
                    text: 'Soundboard',
                  ),
                ],
              ),
            ),
            body: SafeArea(
              child: TabBarView(
                children: [
                  _RelayWorkspace(controller: controller),
                  _SoundboardWorkspace(controller: controller),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _RelayWorkspace extends StatelessWidget {
  const _RelayWorkspace({required this.controller});

  final AudioRelayController controller;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 820;

        return _WorkspaceScrollView(
          children: [
            _Header(controller: controller),
            const SizedBox(height: 16),
            _UpdatePanel(controller: controller),
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
        );
      },
    );
  }
}

class _SoundboardWorkspace extends StatelessWidget {
  const _SoundboardWorkspace({required this.controller});

  final AudioRelayController controller;

  @override
  Widget build(BuildContext context) {
    return _WorkspaceScrollView(
      children: [
        _Header(controller: controller),
        const SizedBox(height: 16),
        _SoundboardPanel(controller: controller),
      ],
    );
  }
}

class _WorkspaceScrollView extends StatelessWidget {
  const _WorkspaceScrollView({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1180),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
      ),
    );
  }
}

class _UpdatePanel extends StatelessWidget {
  const _UpdatePanel({required this.controller});

  final AudioRelayController controller;

  @override
  Widget build(BuildContext context) {
    final progress = controller.updateDownloadProgress;

    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _PanelTitle(
            icon: Icons.system_update_alt_rounded,
            title: 'Updates',
            trailing: Text(controller.updateCurrentVersionLabel),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 240, maxWidth: 520),
                child: _ReadoutValue(
                  icon: Icons.verified_rounded,
                  value: controller.updateStatusLabel,
                  label: controller.updateDetailLabel,
                  labelMaxLines: 2,
                ),
              ),
              ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 200, maxWidth: 300),
                child: _ReadoutValue(
                  icon: Icons.new_releases_rounded,
                  value: controller.updateLatestVersionLabel,
                  label: controller.updateLatestVersionDetailLabel,
                ),
              ),
              ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 240, maxWidth: 420),
                child: _ReadoutValue(
                  icon: Icons.inventory_2_rounded,
                  value: controller.updatePackageLabel,
                  label: controller.updatePackageDetailLabel,
                  labelMaxLines: 2,
                ),
              ),
              FilledButton.icon(
                onPressed: controller.canRunUpdateAction
                    ? controller.runUpdateAction
                    : null,
                icon: Icon(switch (controller.updateStatus) {
                  AppUpdateStatus.available => Icons.download_rounded,
                  AppUpdateStatus.ready => Icons.system_update_alt_rounded,
                  AppUpdateStatus.checking ||
                  AppUpdateStatus.downloading ||
                  AppUpdateStatus.installing => Icons.sync_rounded,
                  _ => Icons.refresh_rounded,
                }),
                label: Text(controller.updateActionLabel),
              ),
              OutlinedButton.icon(
                onPressed: controller.canOpenUpdateReleasePage
                    ? controller.openUpdateReleasePage
                    : null,
                icon: const Icon(Icons.open_in_new_rounded),
                label: const Text('Release'),
              ),
            ],
          ),
          if (progress != null) ...[
            const SizedBox(height: 10),
            LinearProgressIndicator(value: progress.clamp(0, 1).toDouble()),
          ],
        ],
      ),
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
            segments: [
              const ButtonSegment(
                value: RelayTransport.wifi,
                icon: Icon(Icons.wifi_rounded),
                label: Text('Wi-Fi'),
              ),
              if (controller.supportsTransport(RelayTransport.usbTethering))
                const ButtonSegment(
                  value: RelayTransport.usbTethering,
                  icon: Icon(Icons.settings_ethernet_rounded),
                  label: Text('USB tether'),
                ),
              if (controller.supportsTransport(RelayTransport.usb))
                const ButtonSegment(
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
          if (controller.canSelectCaptureOutputDevice) ...[
            const SizedBox(height: 14),
            _CaptureOutputDevicePicker(controller: controller),
          ],
          if (controller.errorMessage != null) ...[
            const SizedBox(height: 14),
            _ErrorBanner(message: controller.errorMessage!),
          ],
          if (controller.noticeMessage != null) ...[
            const SizedBox(height: 14),
            _NoticeBanner(message: controller.noticeMessage!),
          ],
          const SizedBox(height: 20),
          ListenableBuilder(
            listenable: controller.metricsListenable,
            builder: (context, _) {
              return _SignalMeter(
                value: controller.signalLevel,
                muted: controller.muted,
              );
            },
          ),
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
          ListenableBuilder(
            listenable: controller.metricsListenable,
            builder: (context, _) {
              return Wrap(
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
              );
            },
          ),
        ],
      ),
    );
  }
}

class _CaptureOutputDevicePicker extends StatelessWidget {
  const _CaptureOutputDevicePicker({required this.controller});

  static const _systemDefaultValue = '';

  final AudioRelayController controller;

  @override
  Widget build(BuildContext context) {
    final devices = controller.captureOutputDevices;
    final selectedValue =
        controller.effectiveSelectedCaptureOutputDeviceId ??
        _systemDefaultValue;

    return Row(
      children: [
        Expanded(
          child: DropdownButtonFormField<String>(
            key: const ValueKey('capture-output-device-picker'),
            initialValue: selectedValue,
            isExpanded: true,
            decoration: const InputDecoration(
              isDense: true,
              border: OutlineInputBorder(),
              labelText: 'Capture output device',
              prefixIcon: Icon(Icons.speaker_group_rounded),
            ),
            items: [
              const DropdownMenuItem(
                value: _systemDefaultValue,
                child: Text(
                  'System default (follows Windows output)',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              for (final device in devices)
                DropdownMenuItem(
                  value: device.id,
                  child: Text(
                    device.isDefault ? '${device.name} (Default)' : device.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: controller.isBusy
                ? null
                : (value) {
                    unawaited(controller.selectCaptureOutputDevice(value));
                  },
          ),
        ),
        const SizedBox(width: 8),
        Tooltip(
          message: 'Refresh output devices',
          child: IconButton.filledTonal(
            key: const ValueKey('refresh-capture-output-devices'),
            onPressed: controller.canRefreshCaptureOutputDevices
                ? controller.refreshAudioDevices
                : null,
            icon: Icon(
              controller.soundboardDevicesRefreshing
                  ? Icons.hourglass_top_rounded
                  : Icons.refresh_rounded,
            ),
          ),
        ),
      ],
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
            onPressed: controller.isBusy
                ? null
                : () {
                    unawaited(controller.connectToDevice(connectionTarget));
                  },
            icon: Icon(
              controller.activity == RelayActivity.connecting
                  ? Icons.hourglass_top_rounded
                  : Icons.cable_rounded,
            ),
            label: Text(
              controller.activity == RelayActivity.connecting
                  ? 'Connecting'
                  : 'Connect',
            ),
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
                    onTap: controller.isBusy || controller.isStreaming
                        ? null
                        : () {
                            unawaited(controller.connectToDevice(device));
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

class _ReadoutValue extends StatelessWidget {
  const _ReadoutValue({
    required this.icon,
    required this.value,
    required this.label,
    this.labelMaxLines = 1,
  });

  final IconData icon;
  final String value;
  final String label;
  final int labelMaxLines;

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
                  maxLines: labelMaxLines,
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
      RelayActivity.connecting ||
      RelayActivity.reconnecting => theme.colorScheme.tertiary,
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
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final detailText = device.transport == RelayTransport.usb
        ? '${device.transport.label} · USB cable · ${device.profile.sourceSummaryText}'
        : '${device.transport.label} · ${device.host}:${device.port} · ${device.profile.sourceSummaryText}';

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        key: ValueKey('available-source-${device.id}'),
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
    this.titleTrailing,
    this.description,
    this.compact = false,
  });

  final String title;
  final Widget child;
  final Widget? titleTrailing;
  final String? description;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              title,
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            ?titleTrailing,
          ],
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

class _NoticeBanner extends StatelessWidget {
  const _NoticeBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.info_outline_rounded,
            color: theme.colorScheme.onTertiaryContainer,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onTertiaryContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
