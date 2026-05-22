import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../domain/audio_relay_models.dart';

typedef RelayDeviceSeen = void Function(RelayDevice device);
typedef DiscoveryNetworkInterfacesProvider =
    Future<List<DiscoveryNetworkInterface>> Function();

enum DiscoveryNetworkScope {
  all,
  wifi,
  usbTethering;

  String get missingInterfaceMessage {
    return switch (this) {
      DiscoveryNetworkScope.usbTethering =>
        'No USB tethering IPv4 interface was found. Enable USB tethering on Android and keep the cable attached.',
      DiscoveryNetworkScope.wifi =>
        'No Wi-Fi IPv4 interface was found. Connect to Wi-Fi or switch transport.',
      DiscoveryNetworkScope.all => 'No usable IPv4 interface was found.',
    };
  }

  String get missingAddressLabel {
    return switch (this) {
      DiscoveryNetworkScope.usbTethering => 'No USB tether IP',
      DiscoveryNetworkScope.wifi => 'No Wi-Fi IP',
      DiscoveryNetworkScope.all => InternetAddress.loopbackIPv4.address,
    };
  }
}

class DiscoveryNetworkInterface {
  const DiscoveryNetworkInterface({
    required this.name,
    required this.addresses,
    this.description,
    this.index,
    this.addressMetadata = const [],
  });

  final String name;
  final String? description;
  final int? index;
  final List<InternetAddress> addresses;
  final List<DiscoveryNetworkAddress> addressMetadata;

  factory DiscoveryNetworkInterface.fromPlatformMap(
    Map<Object?, Object?> payload,
  ) {
    final addresses = payload['addresses'];
    final addressMetadata = payload['addressMetadata'];
    return DiscoveryNetworkInterface(
      name: payload['name']?.toString() ?? '',
      description: payload['description']?.toString(),
      index: payload['index'] is int ? payload['index'] as int : null,
      addresses: [
        if (addresses is List)
          for (final address in addresses)
            if (address != null) InternetAddress(address.toString()),
      ],
      addressMetadata: [
        if (addressMetadata is List)
          for (final item in addressMetadata)
            if (item is Map && item['address'] != null)
              DiscoveryNetworkAddress.fromPlatformMap(
                item.cast<Object?, Object?>(),
              ),
      ],
    );
  }
}

class DiscoveryNetworkAddress {
  const DiscoveryNetworkAddress({
    required this.address,
    this.prefixLength,
    this.broadcastAddress,
  });

  final InternetAddress address;
  final int? prefixLength;
  final InternetAddress? broadcastAddress;

  factory DiscoveryNetworkAddress.fromPlatformMap(
    Map<Object?, Object?> payload,
  ) {
    final prefixLength = payload['prefixLength'];
    final broadcastAddress = payload['broadcastAddress']?.toString();
    return DiscoveryNetworkAddress(
      address: InternetAddress(payload['address'].toString()),
      prefixLength: prefixLength is int ? prefixLength : null,
      broadcastAddress:
          broadcastAddress == null || broadcastAddress.trim().isEmpty
          ? null
          : InternetAddress(broadcastAddress),
    );
  }
}

class DiscoveryService {
  DiscoveryService({DiscoveryNetworkInterfacesProvider? interfacesProvider})
    : _interfacesProvider = interfacesProvider;

  static const int discoveryPort = 47884;
  static const int audioPort = 47885;
  static const MethodChannel _channel = MethodChannel(
    'audio_bridge/native_engine',
  );

  final DiscoveryNetworkInterfacesProvider? _interfacesProvider;
  List<RawDatagramSocket> _advertiseReceiveSockets = const [];
  List<StreamSubscription<RawSocketEvent>> _advertiseSubscriptions = const [];
  List<RawDatagramSocket> _advertiseSendSockets = const [];
  List<InternetAddress> _advertiseTargets = const [];
  List<DiscoveryNetworkAddress> _advertiseScopeAddresses = const [];
  List<RawDatagramSocket> _scanReceiveSockets = const [];
  List<RawDatagramSocket> _scanSendSockets = const [];
  List<StreamSubscription<RawSocketEvent>> _scanSubscriptions = const [];
  List<DiscoveryNetworkAddress> _scanScopeAddresses = const [];
  Timer? _beaconTimer;
  Timer? _scanProbeTimer;

  Future<String> localIPv4Address({
    DiscoveryNetworkScope scope = DiscoveryNetworkScope.all,
  }) async {
    final addresses = await _localIPv4Addresses(scope);
    if (addresses.isNotEmpty) {
      return addresses.first.address.address;
    }

    return scope.missingAddressLabel;
  }

  Future<void> startAdvertising(
    RelayDevice device, {
    DiscoveryNetworkScope scope = DiscoveryNetworkScope.all,
  }) async {
    await stopAdvertising();

    final scopeAddresses = await _localIPv4Addresses(scope);
    if (scopeAddresses.isEmpty) {
      throw SocketException(scope.missingInterfaceMessage);
    }

    _advertiseScopeAddresses = scopeAddresses;
    _advertiseReceiveSockets = await _openReceiveSockets(scope, scopeAddresses);
    _advertiseSendSockets = await _openInterfaceSendSockets(scopeAddresses);
    _advertiseTargets = await _broadcastTargets(scopeAddresses);

    void sendBeacon([List<InternetAddress>? targets]) {
      final payload = utf8.encode(jsonEncode(device.toDiscoveryMap()));
      for (final activeSocket in _advertiseActiveSockets()) {
        for (final target in targets ?? _advertiseTargets) {
          activeSocket.send(payload, target, discoveryPort);
        }
      }
    }

    _advertiseSubscriptions = [
      for (final socket in _advertiseReceiveSockets)
        socket.listen((event) {
          if (event != RawSocketEvent.read) {
            return;
          }

          while (true) {
            final datagram = socket.receive();
            if (datagram == null) {
              break;
            }
            if (!_sourceMatchesScope(
              datagram.address,
              _advertiseScopeAddresses,
            )) {
              continue;
            }
            if (_isDiscoveryProbe(datagram.data)) {
              sendBeacon([datagram.address]);
            }
          }
        }),
    ];

    sendBeacon();
    _beaconTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      sendBeacon();
    });
  }

  Future<void> startScanning(
    RelayDeviceSeen onDeviceSeen, {
    DiscoveryNetworkScope scope = DiscoveryNetworkScope.all,
  }) async {
    await stopScanning();

    final scopeAddresses = await _localIPv4Addresses(scope);
    if (scopeAddresses.isEmpty) {
      throw SocketException(scope.missingInterfaceMessage);
    }

    _scanScopeAddresses = scopeAddresses;
    _scanReceiveSockets = await _openReceiveSockets(scope, scopeAddresses);
    _scanSendSockets = await _openInterfaceSendSockets(scopeAddresses);

    Future<void> sendProbe() async {
      final targets = await _broadcastTargets(scopeAddresses);
      for (final activeSocket in _scanActiveSockets()) {
        for (final target in targets) {
          activeSocket.send(_discoveryProbePayload, target, discoveryPort);
        }
      }
    }

    _scanSubscriptions = [
      for (final socket in _scanReceiveSockets)
        socket.listen((event) {
          if (event != RawSocketEvent.read) {
            return;
          }

          while (true) {
            final datagram = socket.receive();
            if (datagram == null) {
              break;
            }
            if (!_sourceMatchesScope(datagram.address, _scanScopeAddresses)) {
              continue;
            }

            final device = _decodeDevice(datagram);
            if (device != null) {
              onDeviceSeen(device);
            }
          }
        }),
    ];

    await sendProbe();
    _scanProbeTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      unawaited(sendProbe().catchError((Object _) {}));
    });
  }

  Future<List<RawDatagramSocket>> _openReceiveSockets(
    DiscoveryNetworkScope scope,
    List<DiscoveryNetworkAddress> scopeAddresses,
  ) async {
    final sockets = <RawDatagramSocket>[];
    for (final address in _receiveBindAddresses(scope, scopeAddresses)) {
      final socket = await RawDatagramSocket.bind(
        address,
        discoveryPort,
        reuseAddress: true,
      );
      socket.broadcastEnabled = true;
      sockets.add(socket);
    }
    return sockets;
  }

  @visibleForTesting
  List<InternetAddress> debugReceiveBindAddresses(
    DiscoveryNetworkScope scope,
    List<InternetAddress> scopeAddresses,
  ) {
    return _receiveBindAddresses(scope, [
      for (final address in scopeAddresses)
        DiscoveryNetworkAddress(address: address),
    ]);
  }

  @visibleForTesting
  InternetAddress? debugDirectedBroadcastAddress(
    DiscoveryNetworkAddress address,
  ) {
    final broadcastAddress = _directedBroadcastAddress(address);
    return broadcastAddress == null ? null : InternetAddress(broadcastAddress);
  }

  @visibleForTesting
  bool debugSourceMatchesScope(
    InternetAddress source,
    List<DiscoveryNetworkAddress> scopeAddresses,
  ) {
    return _sourceMatchesScope(source, scopeAddresses);
  }

  List<InternetAddress> _receiveBindAddresses(
    DiscoveryNetworkScope scope,
    List<DiscoveryNetworkAddress> scopeAddresses,
  ) {
    if (scope == DiscoveryNetworkScope.all || scopeAddresses.isNotEmpty) {
      // Broadcast packets sent to a network's directed broadcast address are
      // not reliably delivered to sockets bound to that interface's unicast IP,
      // notably on Android USB tethering. Bind wildcard and filter sources.
      return [InternetAddress.anyIPv4];
    }
    return const [];
  }

  Future<List<RawDatagramSocket>> _openInterfaceSendSockets(
    List<DiscoveryNetworkAddress> addresses,
  ) async {
    final sockets = <RawDatagramSocket>[];
    for (final networkAddress in addresses) {
      try {
        final socket = await RawDatagramSocket.bind(
          networkAddress.address,
          0,
          reuseAddress: true,
        );
        socket.broadcastEnabled = true;
        sockets.add(socket);
      } on SocketException {
        continue;
      } on OSError {
        continue;
      }
    }
    return sockets;
  }

  Future<List<InternetAddress>> _broadcastTargets(
    List<DiscoveryNetworkAddress> addresses,
  ) async {
    final targets = <String>{InternetAddress('255.255.255.255').address};
    for (final address in addresses) {
      final broadcastAddress = _directedBroadcastAddress(address);
      if (broadcastAddress != null) {
        targets.add(broadcastAddress);
      }
    }
    return [for (final target in targets) InternetAddress(target)];
  }

  Future<List<DiscoveryNetworkAddress>> _localIPv4Addresses(
    DiscoveryNetworkScope scope,
  ) async {
    final interfaces = await _loadNetworkInterfaces();
    final scopedInterfaces = _interfacesForScope(interfaces, scope);
    return [
      for (final networkInterface in scopedInterfaces)
        for (final address in networkInterface.addresses)
          if (_isUsableIPv4Address(address))
            _networkAddressFor(networkInterface, address),
    ];
  }

  Future<List<DiscoveryNetworkInterface>> _loadNetworkInterfaces() async {
    final provider = _interfacesProvider;
    if (provider != null) {
      return provider();
    }

    final platformInterfaces = await _loadPlatformNetworkInterfaces();
    if (platformInterfaces.isNotEmpty) {
      return platformInterfaces;
    }

    final interfaces = await NetworkInterface.list(
      includeLoopback: false,
      type: InternetAddressType.IPv4,
    );

    return [
      for (final networkInterface in interfaces)
        DiscoveryNetworkInterface(
          name: networkInterface.name,
          index: networkInterface.index,
          addresses: networkInterface.addresses,
        ),
    ];
  }

  DiscoveryNetworkAddress _networkAddressFor(
    DiscoveryNetworkInterface networkInterface,
    InternetAddress address,
  ) {
    for (final metadata in networkInterface.addressMetadata) {
      if (metadata.address.address == address.address) {
        return metadata;
      }
    }
    return DiscoveryNetworkAddress(address: address);
  }

  Future<List<DiscoveryNetworkInterface>>
  _loadPlatformNetworkInterfaces() async {
    try {
      final payload = await _channel.invokeListMethod<Object?>(
        'getNetworkInterfaces',
      );
      if (payload == null) {
        return const [];
      }
      return [
        for (final item in payload)
          if (item is Map)
            DiscoveryNetworkInterface.fromPlatformMap(
              item.cast<Object?, Object?>(),
            ),
      ];
    } on MissingPluginException {
      return const [];
    } on PlatformException {
      return const [];
    }
  }

  List<DiscoveryNetworkInterface> _interfacesForScope(
    List<DiscoveryNetworkInterface> interfaces,
    DiscoveryNetworkScope scope,
  ) {
    final usableInterfaces = [
      for (final networkInterface in interfaces)
        if (networkInterface.addresses.any(_isUsableIPv4Address))
          networkInterface,
    ];
    if (scope == DiscoveryNetworkScope.all) {
      return usableInterfaces;
    }

    if (scope == DiscoveryNetworkScope.usbTethering) {
      final likelyUsb = [
        for (final networkInterface in usableInterfaces)
          if (_usbTetherScore(networkInterface) >= 8) networkInterface,
      ];
      if (likelyUsb.isNotEmpty) {
        return likelyUsb;
      }
      return [
        for (final networkInterface in usableInterfaces)
          if (_usbTetherScore(networkInterface) >= 0 &&
              !_looksWireless(networkInterface))
            networkInterface,
      ];
    }

    final likelyWifi = [
      for (final networkInterface in usableInterfaces)
        if (_wifiScore(networkInterface) >= 8) networkInterface,
    ];
    if (likelyWifi.isNotEmpty) {
      return likelyWifi;
    }
    return [
      for (final networkInterface in usableInterfaces)
        if (_usbTetherScore(networkInterface) < 8 &&
            !_looksVirtualOrLoopback(networkInterface))
          networkInterface,
    ];
  }

  int _usbTetherScore(DiscoveryNetworkInterface networkInterface) {
    final label = _interfaceLabel(networkInterface);
    if (_looksVirtualOrLoopback(networkInterface) ||
        _looksWireless(networkInterface)) {
      return -20;
    }

    var score = 0;
    for (final keyword in _usbTetherKeywords) {
      if (label.contains(keyword)) {
        score += 8;
      }
    }
    if (label.contains('ethernet')) {
      score += 1;
    }
    return score;
  }

  int _wifiScore(DiscoveryNetworkInterface networkInterface) {
    final label = _interfaceLabel(networkInterface);
    if (_looksVirtualOrLoopback(networkInterface)) {
      return -20;
    }

    var score = 0;
    for (final keyword in _wifiKeywords) {
      if (label.contains(keyword)) {
        score += 8;
      }
    }
    return score;
  }

  bool _looksWireless(DiscoveryNetworkInterface networkInterface) {
    final label = _interfaceLabel(networkInterface);
    return _wifiKeywords.any(label.contains);
  }

  bool _looksVirtualOrLoopback(DiscoveryNetworkInterface networkInterface) {
    final label = _interfaceLabel(networkInterface);
    return _virtualInterfaceKeywords.any(label.contains);
  }

  String _interfaceLabel(DiscoveryNetworkInterface networkInterface) {
    return '${networkInterface.name} ${networkInterface.description ?? ''}'
        .toLowerCase();
  }

  bool _isUsableIPv4Address(InternetAddress address) {
    return address.type == InternetAddressType.IPv4 &&
        !address.isLoopback &&
        !address.address.startsWith('169.254.');
  }

  Future<void> stopAdvertising() async {
    _beaconTimer?.cancel();
    _beaconTimer = null;
    for (final subscription in _advertiseSubscriptions) {
      await subscription.cancel();
    }
    _advertiseSubscriptions = const [];
    for (final socket in _advertiseReceiveSockets) {
      socket.close();
    }
    _advertiseReceiveSockets = const [];
    for (final socket in _advertiseSendSockets) {
      socket.close();
    }
    _advertiseSendSockets = const [];
    _advertiseTargets = const [];
    _advertiseScopeAddresses = const [];
  }

  Future<void> stopScanning() async {
    _scanProbeTimer?.cancel();
    _scanProbeTimer = null;
    for (final subscription in _scanSubscriptions) {
      await subscription.cancel();
    }
    _scanSubscriptions = const [];
    for (final socket in _scanReceiveSockets) {
      socket.close();
    }
    _scanReceiveSockets = const [];
    for (final socket in _scanSendSockets) {
      socket.close();
    }
    _scanSendSockets = const [];
    _scanScopeAddresses = const [];
  }

  Future<void> dispose() async {
    await stopAdvertising();
    await stopScanning();
  }

  RelayDevice? _decodeDevice(Datagram datagram) {
    try {
      final decoded = jsonDecode(utf8.decode(datagram.data));
      if (decoded is! Map) {
        return null;
      }

      return RelayDevice.fromDiscoveryMap(
        decoded.cast<String, Object?>(),
        sourceHost: datagram.address.address,
      );
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  Iterable<RawDatagramSocket> _advertiseActiveSockets() {
    if (_advertiseSendSockets.isNotEmpty) {
      return _advertiseSendSockets;
    }
    return _advertiseReceiveSockets;
  }

  Iterable<RawDatagramSocket> _scanActiveSockets() {
    if (_scanSendSockets.isNotEmpty) {
      return _scanSendSockets;
    }
    return _scanReceiveSockets;
  }

  String? _directedBroadcastAddress(DiscoveryNetworkAddress networkAddress) {
    final explicitBroadcast = networkAddress.broadcastAddress;
    if (explicitBroadcast != null &&
        explicitBroadcast.type == InternetAddressType.IPv4) {
      return explicitBroadcast.address;
    }

    final prefixLength = networkAddress.prefixLength;
    final addressValue = _ipv4ToInt(networkAddress.address);
    if (prefixLength == null || addressValue == null) {
      return _classCBroadcastAddress(networkAddress.address);
    }
    if (prefixLength < 0 || prefixLength > 32) {
      return null;
    }

    final mask = prefixLength == 0
        ? 0
        : (0xFFFFFFFF << (32 - prefixLength)) & 0xFFFFFFFF;
    final broadcast = (addressValue | (~mask & 0xFFFFFFFF)) & 0xFFFFFFFF;
    return _ipv4FromInt(broadcast).address;
  }

  bool _sourceMatchesScope(
    InternetAddress source,
    List<DiscoveryNetworkAddress> scopeAddresses,
  ) {
    if (scopeAddresses.isEmpty) {
      return true;
    }
    return scopeAddresses.any((address) => _sameSubnet(address, source));
  }

  bool _sameSubnet(
    DiscoveryNetworkAddress networkAddress,
    InternetAddress source,
  ) {
    final prefixLength = networkAddress.prefixLength;
    final left = _ipv4ToInt(networkAddress.address);
    final right = _ipv4ToInt(source);
    if (prefixLength == null || left == null || right == null) {
      return _sameClassCSubnet(networkAddress.address, source);
    }
    if (prefixLength < 0 || prefixLength > 32) {
      return false;
    }

    final mask = prefixLength == 0
        ? 0
        : (0xFFFFFFFF << (32 - prefixLength)) & 0xFFFFFFFF;
    return (left & mask) == (right & mask);
  }

  String? _classCBroadcastAddress(InternetAddress address) {
    final octets = address.address.split('.');
    if (octets.length != 4 ||
        octets.any((octet) => int.tryParse(octet) == null)) {
      return null;
    }
    return '${octets[0]}.${octets[1]}.${octets[2]}.255';
  }

  bool _sameClassCSubnet(InternetAddress left, InternetAddress right) {
    final leftOctets = left.address.split('.');
    final rightOctets = right.address.split('.');
    if (leftOctets.length != 4 || rightOctets.length != 4) {
      return false;
    }
    return leftOctets[0] == rightOctets[0] &&
        leftOctets[1] == rightOctets[1] &&
        leftOctets[2] == rightOctets[2];
  }

  int? _ipv4ToInt(InternetAddress address) {
    if (address.type != InternetAddressType.IPv4) {
      return null;
    }
    final octets = address.address.split('.');
    if (octets.length != 4) {
      return null;
    }

    var value = 0;
    for (final octet in octets) {
      final parsed = int.tryParse(octet);
      if (parsed == null || parsed < 0 || parsed > 255) {
        return null;
      }
      value = (value << 8) | parsed;
    }
    return value;
  }

  InternetAddress _ipv4FromInt(int value) {
    return InternetAddress(
      '${(value >> 24) & 0xFF}.${(value >> 16) & 0xFF}.'
      '${(value >> 8) & 0xFF}.${value & 0xFF}',
    );
  }

  bool _isDiscoveryProbe(List<int> data) {
    return utf8.decode(data, allowMalformed: true) == _discoveryProbeMessage;
  }
}

const _discoveryProbeMessage = 'ABR_DISCOVER v1';
final _discoveryProbePayload = utf8.encode(_discoveryProbeMessage);

const _usbTetherKeywords = {
  'android',
  'mobile',
  'phone',
  'remote ndis',
  'rndis',
  'tether',
  'usb',
};

const _wifiKeywords = {'wi-fi', 'wifi', 'wireless', 'wlan', '802.11'};

const _virtualInterfaceKeywords = {
  'bluetooth',
  'docker',
  'hyper-v',
  'isatap',
  'loopback',
  'pseudo',
  'tap',
  'tailscale',
  'teredo',
  'virtual',
  'virtualbox',
  'vmware',
  'vpn',
  'wsl',
  'zerotier',
};
