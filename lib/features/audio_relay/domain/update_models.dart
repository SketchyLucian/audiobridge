import 'dart:io';

enum AppUpdateTarget {
  android,
  windows,
  unsupported;

  factory AppUpdateTarget.current() {
    if (Platform.isAndroid) {
      return AppUpdateTarget.android;
    }
    if (Platform.isWindows) {
      return AppUpdateTarget.windows;
    }
    return AppUpdateTarget.unsupported;
  }

  String get artifactExtension {
    return switch (this) {
      AppUpdateTarget.android => '.apk',
      AppUpdateTarget.windows => '.msi',
      AppUpdateTarget.unsupported => '',
    };
  }

  String get platformLabel {
    return switch (this) {
      AppUpdateTarget.android => 'Android',
      AppUpdateTarget.windows => 'Windows',
      AppUpdateTarget.unsupported => Platform.operatingSystem,
    };
  }
}

enum AppUpdateStatus {
  idle,
  checking,
  current,
  available,
  downloading,
  ready,
  installing,
  failed,
}

class AppUpdateAsset {
  const AppUpdateAsset({
    required this.name,
    required this.downloadUrl,
    required this.sizeBytes,
    required this.target,
  });

  final String name;
  final Uri downloadUrl;
  final int sizeBytes;
  final AppUpdateTarget target;
}

class AppUpdateRelease {
  const AppUpdateRelease({
    required this.tagName,
    required this.version,
    required this.pageUrl,
    required this.asset,
    this.name,
    this.notes,
  });

  final String tagName;
  final String version;
  final String? name;
  final String? notes;
  final Uri pageUrl;
  final AppUpdateAsset asset;

  String get displayName {
    final releaseName = name?.trim();
    if (releaseName != null && releaseName.isNotEmpty) {
      return releaseName;
    }
    return tagName;
  }
}

class AppUpdateCheckResult {
  const AppUpdateCheckResult({
    required this.currentVersion,
    required this.target,
    this.release,
  });

  final String currentVersion;
  final AppUpdateTarget target;
  final AppUpdateRelease? release;

  bool get hasUpdate => release != null;
}
