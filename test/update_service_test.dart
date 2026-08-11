import 'package:audiorelay_clone/features/audio_relay/data/update_service.dart';
import 'package:audiorelay_clone/features/audio_relay/domain/update_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('GitHub release parser selects the Android APK asset', () {
    final service = GitHubUpdateService();

    final release = service.releaseFromPayload({
      'tag_name': 'v1.0.5',
      'name': 'v1.0.5',
      'html_url':
          'https://github.com/SketchyLucian/audiobridge-releases/releases/tag/v1.0.5',
      'assets': [
        {
          'name': 'AudioBridge-1.0.5-x64.msi',
          'size': 100,
          'browser_download_url':
              'https://github.com/SketchyLucian/audiobridge-releases/releases/download/v1.0.5/AudioBridge-1.0.5-x64.msi',
        },
        {
          'name': 'AudioBridge-1.0.5-android.apk',
          'size': 100,
          'browser_download_url':
              'https://github.com/SketchyLucian/audiobridge-releases/releases/download/v1.0.5/AudioBridge-1.0.5-android.apk',
        },
      ],
    }, target: AppUpdateTarget.android);

    expect(release?.version, '1.0.5');
    expect(release?.asset.name, 'AudioBridge-1.0.5-android.apk');
    expect(release?.asset.target, AppUpdateTarget.android);
  });

  test('GitHub release parser selects the Windows MSI asset', () {
    final service = GitHubUpdateService();

    final release = service.releaseFromPayload({
      'tag_name': 'v1.0.5',
      'name': 'v1.0.5',
      'html_url':
          'https://github.com/SketchyLucian/audiobridge-releases/releases/tag/v1.0.5',
      'assets': [
        {
          'name': 'AudioBridge-1.0.5-x64.msi',
          'size': 100,
          'browser_download_url':
              'https://github.com/SketchyLucian/audiobridge-releases/releases/download/v1.0.5/AudioBridge-1.0.5-x64.msi',
        },
        {
          'name': 'AudioBridge-1.0.5-android.apk',
          'size': 100,
          'browser_download_url':
              'https://github.com/SketchyLucian/audiobridge-releases/releases/download/v1.0.5/AudioBridge-1.0.5-android.apk',
        },
      ],
    }, target: AppUpdateTarget.windows);

    expect(release?.asset.name, 'AudioBridge-1.0.5-x64.msi');
    expect(release?.asset.target, AppUpdateTarget.windows);
  });

  test('GitHub release parser rejects off-repository download URLs', () {
    final service = GitHubUpdateService();

    expect(
      () => service.releaseFromPayload({
        'tag_name': 'v1.0.5',
        'name': 'v1.0.5',
        'html_url':
            'https://github.com/SketchyLucian/audiobridge-releases/releases/tag/v1.0.5',
        'assets': [
          {
            'name': 'AudioBridge-1.0.5-android.apk',
            'size': 100,
            'browser_download_url':
                'https://example.com/AudioBridge-1.0.5-android.apk',
          },
        ],
      }, target: AppUpdateTarget.android),
      throwsA(isA<AppUpdateException>()),
    );
  });

  test('GitHub release parser rejects the private source repository', () {
    final service = GitHubUpdateService();

    expect(
      () => service.releaseFromPayload({
        'tag_name': 'v1.0.5',
        'name': 'v1.0.5',
        'html_url':
            'https://github.com/SketchyLucian/audiobridge/releases/tag/v1.0.5',
        'assets': const [],
      }, target: AppUpdateTarget.windows),
      throwsA(isA<AppUpdateException>()),
    );
  });

  test('GitHub release parser rejects off-repository release pages', () {
    final service = GitHubUpdateService();

    expect(
      () => service.releaseFromPayload({
        'tag_name': 'v1.0.5',
        'name': 'v1.0.5',
        'html_url': 'https://example.com/releases/tag/v1.0.5',
        'assets': const [],
      }, target: AppUpdateTarget.android),
      throwsA(isA<AppUpdateException>()),
    );
  });

  test('GitHub release parser ignores malformed release tags', () {
    final service = GitHubUpdateService();

    final release = service.releaseFromPayload({
      'tag_name': 'v1.0.5-preview',
      'name': 'Preview',
      'html_url':
          'https://github.com/SketchyLucian/audiobridge-releases/releases/tag/v1.0.5-preview',
      'assets': const [],
    }, target: AppUpdateTarget.android);

    expect(release, isNull);
  });
}
