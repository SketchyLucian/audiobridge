import 'dart:io';

import 'package:flutter/services.dart';

abstract interface class UpdateInstaller {
  Future<void> openReleasePage(Uri url);

  Future<void> installPackage(File packageFile);
}

class MethodChannelUpdateInstaller implements UpdateInstaller {
  const MethodChannelUpdateInstaller();

  static const MethodChannel _channel = MethodChannel(
    'audio_bridge/native_engine',
  );

  @override
  Future<void> openReleasePage(Uri url) {
    return _invoke('openExternalUrl', {'url': url.toString()});
  }

  @override
  Future<void> installPackage(File packageFile) {
    return _invoke('installUpdatePackage', {'path': packageFile.path});
  }

  Future<void> _invoke(String method, Map<String, Object?> arguments) async {
    await _channel.invokeMethod<void>(method, arguments);
  }
}
