part of '../audio_relay_screen.dart';

class _SoundboardPanel extends StatelessWidget {
  const _SoundboardPanel({required this.controller});

  final AudioRelayController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selectedItem = controller.selectedSoundboardItem;
    final notice =
        controller.soundboardMessage ?? controller.soundboardRouteMessage;

    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _PanelTitle(
            icon: Icons.library_music_rounded,
            title: 'Soundboard',
            trailing: Text(controller.soundboardStatusLabel),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SegmentedButton<SoundboardPlaybackTarget>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(
                    value: SoundboardPlaybackTarget.micRoute,
                    icon: Icon(Icons.mic_external_on_rounded),
                    label: Text('Mic + speaker'),
                  ),
                  ButtonSegment(
                    value: SoundboardPlaybackTarget.stream,
                    icon: Icon(Icons.hub_rounded),
                    label: Text('Stream'),
                  ),
                ],
                selected: {controller.soundboardTarget},
                onSelectionChanged: controller.canUseSoundboard
                    ? (selection) {
                        controller.updateSoundboardTarget(selection.first);
                      }
                    : null,
              ),
              if (controller.soundboardTarget ==
                  SoundboardPlaybackTarget.micRoute) ...[
                ConstrainedBox(
                  constraints: const BoxConstraints(
                    minWidth: 260,
                    maxWidth: 460,
                  ),
                  child: _CallMicrophonePicker(controller: controller),
                ),
                Tooltip(
                  message: 'Refresh audio devices',
                  child: IconButton.filledTonal(
                    key: const ValueKey('refresh-soundboard-devices'),
                    onPressed: controller.canRefreshSoundboardDevices
                        ? controller.refreshSoundboardDevices
                        : null,
                    icon: Icon(
                      controller.soundboardDevicesRefreshing
                          ? Icons.hourglass_top_rounded
                          : Icons.refresh_rounded,
                    ),
                  ),
                ),
              ],
              if (controller.soundboardTarget ==
                      SoundboardPlaybackTarget.micRoute &&
                  controller.soundboardOutputDevices.isEmpty)
                OutlinedButton.icon(
                  onPressed: controller.canSetUpSoundboardCallMicrophone
                      ? controller.setUpSoundboardCallMicrophone
                      : null,
                  icon: Icon(
                    controller.soundboardSetupBusy
                        ? Icons.hourglass_top_rounded
                        : Icons.open_in_new_rounded,
                  ),
                  label: Text(
                    controller.soundboardSetupBusy
                        ? 'Opening page'
                        : 'Get VB-CABLE',
                  ),
                ),
            ],
          ),
          if (controller.soundboardTarget ==
                  SoundboardPlaybackTarget.micRoute &&
              controller.soundboardOutputDevices.isNotEmpty) ...[
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('Include physical microphone'),
                subtitle: const Text(
                  'Off by default to prevent speaker audio from echoing into '
                  'VB-CABLE. Use headphones when this is on.',
                ),
                value: controller.soundboardMicBridgeEnabled,
                onChanged: controller.canUseSoundboard
                    ? controller.updateSoundboardMicBridgeEnabled
                    : null,
              ),
            ),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilledButton.icon(
                onPressed: controller.canUseSoundboard
                    ? () {
                        _pickSoundFiles(context);
                      }
                    : null,
                icon: const Icon(Icons.add_rounded),
                label: const Text('Add sound'),
              ),
              Tooltip(
                message: 'Play selected sound',
                child: IconButton.filledTonal(
                  onPressed: controller.canPlaySelectedSound
                      ? controller.playSelectedSoundboardItem
                      : null,
                  icon: const Icon(Icons.play_arrow_rounded),
                ),
              ),
              Tooltip(
                message: 'Stop soundboard',
                child: IconButton.filledTonal(
                  onPressed: controller.canUseSoundboard
                      ? controller.stopSoundboard
                      : null,
                  icon: const Icon(Icons.stop_rounded),
                ),
              ),
              ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 220, maxWidth: 320),
                child: _SoundboardVolumeControl(controller: controller),
              ),
            ],
          ),
          if (notice != null) ...[
            const SizedBox(height: 10),
            Text(
              notice,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 12),
          if (controller.soundboardItems.isEmpty)
            _EmptySoundboard(enabled: controller.canUseSoundboard)
          else
            Column(
              children: [
                for (final item in controller.soundboardItems)
                  _SoundboardRow(
                    item: item,
                    selected: selectedItem?.id == item.id,
                    canPlay: controller.canPlaySoundboardItem(item),
                    onTap: () {
                      controller.selectSoundboardItem(item);
                    },
                    onPlay: () {
                      controller.playSoundboardItem(item);
                    },
                    onRemove: () {
                      controller.removeSoundboardItem(item);
                    },
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Future<void> _pickSoundFiles(BuildContext context) async {
    final files = await openFiles(
      acceptedTypeGroups: const [_soundboardAudioTypeGroup],
    );
    if (!context.mounted || files.isEmpty) {
      return;
    }
    controller.addSoundboardFiles(files.map((file) => file.path));
  }
}

class _CallMicrophonePicker extends StatelessWidget {
  const _CallMicrophonePicker({required this.controller});

  final AudioRelayController controller;

  @override
  Widget build(BuildContext context) {
    final devices = controller.soundboardOutputDevices;
    final selectedId =
        devices.any(
          (device) => device.id == controller.selectedSoundboardOutputDeviceId,
        )
        ? controller.selectedSoundboardOutputDeviceId
        : null;

    return DropdownButtonFormField<String>(
      initialValue: selectedId,
      isExpanded: true,
      decoration: const InputDecoration(
        isDense: true,
        border: OutlineInputBorder(),
        labelText: 'Call app microphone',
      ),
      hint: Text(devices.isEmpty ? 'No call microphone found' : 'Choose mic'),
      items: [
        for (final device in devices)
          DropdownMenuItem(
            value: device.id,
            child: Text(
              controller.callMicrophoneNameForSoundboardRoute(device),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: devices.isEmpty || !controller.canUseSoundboard
          ? null
          : controller.selectSoundboardOutputDevice,
    );
  }
}

class _SoundboardVolumeControl extends StatelessWidget {
  const _SoundboardVolumeControl({required this.controller});

  final AudioRelayController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      children: [
        Icon(Icons.graphic_eq_rounded, color: theme.colorScheme.secondary),
        const SizedBox(width: 8),
        Expanded(
          child: Slider(
            value: controller.soundboardVolume,
            onChanged: controller.canUseSoundboard
                ? controller.updateSoundboardVolume
                : null,
          ),
        ),
        SizedBox(
          width: 44,
          child: Text(
            '${(controller.soundboardVolume * 100).round()}%',
            textAlign: TextAlign.end,
            style: theme.textTheme.labelLarge,
          ),
        ),
      ],
    );
  }
}

class _SoundboardRow extends StatelessWidget {
  const _SoundboardRow({
    required this.item,
    required this.selected,
    required this.canPlay,
    required this.onTap,
    required this.onPlay,
    required this.onRemove,
  });

  final SoundPlaybackItem item;
  final bool selected;
  final bool canPlay;
  final VoidCallback onTap;
  final VoidCallback onPlay;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 58),
          child: Ink(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
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
                  Icons.audio_file_rounded,
                  color: selected
                      ? theme.colorScheme.primary
                      : theme.colorScheme.secondary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        item.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Text(
                        item.path,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Tooltip(
                  message: 'Play sound',
                  child: IconButton(
                    onPressed: canPlay ? onPlay : null,
                    icon: const Icon(Icons.play_arrow_rounded),
                  ),
                ),
                Tooltip(
                  message: 'Remove sound',
                  child: IconButton(
                    onPressed: onRemove,
                    icon: const Icon(Icons.close_rounded),
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

class _EmptySoundboard extends StatelessWidget {
  const _EmptySoundboard({required this.enabled});

  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(minHeight: 112),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            enabled ? Icons.library_music_rounded : Icons.music_off_rounded,
            color: theme.colorScheme.secondary,
          ),
          const SizedBox(height: 8),
          Text(
            enabled ? 'No sounds added' : 'Soundboard unavailable',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}
