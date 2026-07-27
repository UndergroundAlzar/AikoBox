import 'dart:async';

import 'package:flutter/services.dart';

import '../security/redaction.dart';
import 'vpn_state.dart';

abstract interface class VpnBridge {
  Stream<VpnStatus> get statusEvents;

  Future<bool> prepareVpn();
  Future<void> checkProfile(String path);
  Future<void> start(String profilePath);
  Future<void> reload(String profilePath);
  Future<void> stop();
  Future<VpnStatus> getStatus();
}

class MethodChannelVpnBridge implements VpnBridge {
  const MethodChannelVpnBridge({
    this.methodChannel = const MethodChannel('com.aikobox.app/vpn'),
    this.eventChannel = const EventChannel('com.aikobox.app/vpn/events'),
  });

  final MethodChannel methodChannel;
  final EventChannel eventChannel;

  @override
  Stream<VpnStatus> get statusEvents {
    return eventChannel.receiveBroadcastStream().map((event) {
      if (event is! Map) {
        return const VpnStatus(state: VpnState.error, message: '收到无效的 VPN 状态');
      }
      return _safeStatus(event.cast<Object?, Object?>());
    });
  }

  @override
  Future<bool> prepareVpn() async {
    return await _invoke<bool>('prepareVpn') ?? false;
  }

  @override
  Future<void> checkProfile(String path) {
    return _invoke<void>('checkProfile', {'profilePath': path});
  }

  @override
  Future<void> start(String profilePath) {
    return _invoke<void>('start', {'profilePath': profilePath});
  }

  @override
  Future<void> reload(String profilePath) {
    return _invoke<void>('reload', {'profilePath': profilePath});
  }

  @override
  Future<void> stop() => _invoke<void>('stop');

  @override
  Future<VpnStatus> getStatus() async {
    final result = await _invoke<Map<Object?, Object?>>('getStatus');
    return _safeStatus(result ?? const {'state': 'stopped'});
  }

  VpnStatus _safeStatus(Map<Object?, Object?> value) {
    final safe = Map<Object?, Object?>.of(value);
    final message = safe['message'];
    if (message != null) {
      safe['message'] = redactSensitive(message.toString());
    }
    return VpnStatus.fromMap(safe);
  }

  Future<T?> _invoke<T>(String method, [Object? arguments]) async {
    try {
      return await methodChannel.invokeMethod<T>(method, arguments);
    } on PlatformException catch (error) {
      throw VpnBridgeException(redactSensitive(error.message ?? error.code));
    } on MissingPluginException {
      throw const VpnBridgeException('VPN 服务尚未安装或不可用');
    }
  }
}

class VpnBridgeException implements Exception {
  const VpnBridgeException(this.message);

  final String message;

  @override
  String toString() => message;
}
