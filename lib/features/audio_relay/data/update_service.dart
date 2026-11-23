import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../domain/update_models.dart';

abstract interface class AppUpdateService {
  Future<AppUpdateCheckResult> checkForUpdate({
    required String currentVersion,
    required AppUpdateTarget target,
  });

  Future<File> downloadUpdate(
    AppUpdateRelease release, {
    ValueChanged<double?>? onProgress,
  });
}

class AppUpdateException implements Exception {
  const AppUpdateException(this.message);

  final String message;

  @override
  String toString() => message;
}

class GitHubUpdateService implements AppUpdateService {
  GitHubUpdateService({
    this.owner = 'SketchyLucian',
    this.repo = 'audiobridge',
    HttpClient Function()? httpClientFactory,
    Directory? downloadDirectory,
  }) : _httpClientFactory = httpClientFactory ?? HttpClient.new,
       _downloadDirectory = downloadDirectory;

  final String owner;
  final String repo;
  final HttpClient Function() _httpClientFactory;
  final Directory? _downloadDirectory;

  static const _requestTimeout = Duration(seconds: 20);
  static const _maxInstallerBytes = 256 * 1024 * 1024;

  @override
  Future<AppUpdateCheckResult> checkForUpdate({
    required String currentVersion,
    required AppUpdateTarget target,
  }) async {
    if (target == AppUpdateTarget.unsupported) {
      return AppUpdateCheckResult(
        currentVersion: currentVersion,
        target: target,
      );
    }

    final payload = await _readJson(_latestReleaseUri);
    final release = releaseFromPayload(payload, target: target);
    if (release == null || !_isReleaseNewer(release.version, currentVersion)) {
      return AppUpdateCheckResult(
        currentVersion: currentVersion,
        target: target,
      );
    }

    return AppUpdateCheckResult(
      currentVersion: currentVersion,
      target: target,
      release: release,
    );
  }

  @override
  Future<File> downloadUpdate(
    AppUpdateRelease release, {
    ValueChanged<double?>? onProgress,
  }) async {
    _validateDownloadUri(release.asset.downloadUrl);
    if (release.asset.sizeBytes <= 0 ||
        release.asset.sizeBytes > _maxInstallerBytes) {
      throw const AppUpdateException('The update file size looks unsafe.');
    }

    final directory =
        _downloadDirectory ??
        await Directory.systemTemp.createTemp('audiobridge_update_');
    await directory.create(recursive: true);
    final file = File(
      '${directory.path}${Platform.pathSeparator}${_safeFileName(release.asset.name)}',
    );

    final client = _newClient();
    IOSink? sink;
    try {
      final request = await client
          .getUrl(release.asset.downloadUrl)
          .timeout(_requestTimeout);
      final response = await request.close().timeout(_requestTimeout);
      if (response.statusCode != HttpStatus.ok) {
        throw AppUpdateException(
          'Unable to download update (${response.statusCode}).',
        );
      }

      final expectedSize = release.asset.sizeBytes;
      final totalBytes = response.contentLength > 0
          ? response.contentLength
          : expectedSize;
      var receivedBytes = 0;

      sink = file.openWrite();
      await for (final chunk in response) {
        receivedBytes += chunk.length;
        if (receivedBytes > _maxInstallerBytes) {
          throw const AppUpdateException('The update download is too large.');
        }
        sink.add(chunk);
        onProgress?.call(totalBytes > 0 ? receivedBytes / totalBytes : null);
      }
      await sink.close();
      sink = null;

      if (receivedBytes != expectedSize) {
        throw const AppUpdateException('The update download was incomplete.');
      }
      onProgress?.call(1);
      return file;
    } catch (_) {
      await sink?.close();
      if (await file.exists()) {
        await file.delete();
      }
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  @visibleForTesting
  AppUpdateRelease? releaseFromPayload(
    Map<String, Object?> payload, {
    required AppUpdateTarget target,
  }) {
    final tagName = payload['tag_name']?.toString().trim() ?? '';
    final version = _releaseVersionText(tagName);
    final pageUrl = Uri.tryParse(payload['html_url']?.toString() ?? '');
    if (tagName.isEmpty || version == null || pageUrl == null) {
      return null;
    }
    _validateReleasePageUri(pageUrl);

    final assets = payload['assets'];
    if (assets is! List) {
      return null;
    }

    for (final item in assets) {
      if (item is! Map) {
        continue;
      }
      final asset = _assetFromPayload(item.cast<Object?, Object?>(), target);
      if (asset != null) {
        return AppUpdateRelease(
          tagName: tagName,
          version: version,
          pageUrl: pageUrl,
          asset: asset,
          name: payload['name']?.toString(),
          notes: payload['body']?.toString(),
        );
      }
    }
    return null;
  }

  Uri get _latestReleaseUri {
    return Uri.https('api.github.com', '/repos/$owner/$repo/releases/latest');
  }

  HttpClient _newClient() {
    final client = _httpClientFactory();
    client.connectionTimeout = _requestTimeout;
    return client;
  }

  Future<Map<String, Object?>> _readJson(Uri uri) async {
    final client = _newClient();
    try {
      final request = await client.getUrl(uri).timeout(_requestTimeout);
      request.headers.set(
        HttpHeaders.acceptHeader,
        'application/vnd.github+json',
      );
      request.headers.set(HttpHeaders.userAgentHeader, 'AudioBridge updater');
      request.headers.set('X-GitHub-Api-Version', '2022-11-28');
      final response = await request.close().timeout(_requestTimeout);
      if (response.statusCode == HttpStatus.notFound) {
        throw const AppUpdateException(
          'No public GitHub release feed is available.',
        );
      }
      if (response.statusCode != HttpStatus.ok) {
        throw AppUpdateException(
          'Unable to check GitHub releases (${response.statusCode}).',
        );
      }

      final body = await utf8.decodeStream(response).timeout(_requestTimeout);
      final decoded = jsonDecode(body);
      if (decoded is! Map) {
        throw const AppUpdateException('GitHub returned an invalid release.');
      }
      return decoded.cast<String, Object?>();
    } on TimeoutException {
      throw const AppUpdateException('The update check timed out.');
    } on SocketException {
      throw const AppUpdateException('Unable to reach GitHub.');
    } on FormatException {
      throw const AppUpdateException('GitHub returned an invalid release.');
    } finally {
      client.close(force: true);
    }
  }

  AppUpdateAsset? _assetFromPayload(
    Map<Object?, Object?> payload,
    AppUpdateTarget target,
  ) {
    if (target == AppUpdateTarget.unsupported) {
      return null;
    }
    final name = payload['name']?.toString().trim() ?? '';
    final downloadUrl = Uri.tryParse(
      payload['browser_download_url']?.toString() ?? '',
    );
    final sizeBytes = _readInt(payload['size']);
    if (name.isEmpty ||
        downloadUrl == null ||
        !name.toLowerCase().endsWith(target.artifactExtension) ||
        sizeBytes <= 0 ||
        sizeBytes > _maxInstallerBytes) {
      return null;
    }
    _validateDownloadUri(downloadUrl);
    return AppUpdateAsset(
      name: name,
      downloadUrl: downloadUrl,
      sizeBytes: sizeBytes,
      target: target,
    );
  }

  void _validateDownloadUri(Uri uri) {
    final expectedPrefix = '/$owner/$repo/releases/download/';
    if (uri.scheme != 'https' ||
        uri.host != 'github.com' ||
        !uri.path.startsWith(expectedPrefix)) {
      throw const AppUpdateException('GitHub returned an unsafe update URL.');
    }
  }

  void _validateReleasePageUri(Uri uri) {
    final expectedPrefix = '/$owner/$repo/releases/tag/';
    if (uri.scheme != 'https' ||
        uri.host != 'github.com' ||
        !uri.path.startsWith(expectedPrefix)) {
      throw const AppUpdateException('GitHub returned an unsafe release page.');
    }
  }

  String _safeFileName(String name) {
    final sanitized = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final lowerName = sanitized.toLowerCase();
    final extension = lowerName.endsWith('.apk')
        ? '.apk'
        : lowerName.endsWith('.msi')
        ? '.msi'
        : '';
    if (extension.isEmpty) {
      throw const AppUpdateException('GitHub returned an unsafe update file.');
    }
    if (sanitized.length <= 96) {
      return sanitized;
    }
    final basename = sanitized.substring(
      0,
      min(sanitized.length - extension.length, 96 - extension.length),
    );
    return '$basename$extension';
  }

  static bool _isReleaseNewer(String releaseVersion, String currentVersion) {
    final release = _VersionNumber.tryParse(releaseVersion);
    final current = _VersionNumber.tryParse(currentVersion);
    if (release == null || current == null) {
      return false;
    }
    return release.compareTo(current) > 0;
  }

  static String? _releaseVersionText(String tagName) {
    return _VersionNumber.tryParse(tagName)?.text;
  }

  static int _readInt(Object? value) {
    if (value is int) {
      return value;
    }
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }
}

class _VersionNumber implements Comparable<_VersionNumber> {
  const _VersionNumber(this.major, this.minor, this.patch);

  final int major;
  final int minor;
  final int patch;

  String get text => '$major.$minor.$patch';

  static _VersionNumber? tryParse(String value) {
    final match = RegExp(
      r'^v?(\d+)\.(\d+)\.(\d+)(?:\+\d+)?$',
    ).firstMatch(value.trim());
    if (match == null) {
      return null;
    }
    return _VersionNumber(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
    );
  }

  @override
  int compareTo(_VersionNumber other) {
    final majorComparison = major.compareTo(other.major);
    if (majorComparison != 0) {
      return majorComparison;
    }
    final minorComparison = minor.compareTo(other.minor);
    if (minorComparison != 0) {
      return minorComparison;
    }
    return patch.compareTo(other.patch);
  }
}
