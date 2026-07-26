/// The Dart half of the Dart ⇄ Kotlin contract (§4.4).
///
/// Channel names are fixed:
///
/// ```
/// MethodChannel  "aikobox/core"
/// EventChannel   "aikobox/core/status"   -> {state: String, error: String?}
/// EventChannel   "aikobox/core/logs"     -> {level: String, message: String, time: int}
/// ```
///
/// Everything else — traffic, connections, proxies, rules — is read over the
/// Clash API the core exposes at `experimental.clash_api`. See `clash_api.dart`.
library;

import 'dart:async';

import 'package:flutter/services.dart';

import 'models.dart';

/// A failure raised by the Android side, carrying the stable machine-readable
/// code that the UI branches on.
///
/// This deliberately fixes the desktop anti-pattern where `wrapAsync` resolved
/// errors into `{invokeError: string}`, making every `e is Error` branch in the
/// renderer dead code. Here a failure is a thrown exception with a code, and
/// nothing switches on message substrings.
class AikoCoreException implements Exception {
  const AikoCoreException(this.code, this.message, [this.details]);

  /// Reconstructs the exception from a `PlatformException` raised by
  /// `result.error(code, message, details)` on the Kotlin side.
  factory AikoCoreException.fromPlatform(PlatformException error) =>
      AikoCoreException(
        error.code.isEmpty ? codeUnknown : error.code,
        error.message ?? error.code,
        error.details?.toString(),
      );

  /// The config the core was handed does not parse or does not validate.
  static const String codeConfigInvalid = 'E_CONFIG_INVALID';

  /// The user declined the `VpnService.prepare()` consent dialog.
  static const String codeVpnPermissionDenied = 'E_VPN_PERMISSION_DENIED';

  /// The core process refused to come up, or failed its health gate.
  static const String codeCoreStartFailed = 'E_CORE_START_FAILED';

  /// `VpnService.Builder.establish()` returned null.
  static const String codeTunEstablishFailed = 'E_TUN_ESTABLISH_FAILED';

  /// The method exists in the contract but this build's host does not
  /// implement it — only ever seen on a mismatched debug pairing.
  static const String codeNotImplemented = 'E_NOT_IMPLEMENTED';

  /// Anything the host did not label.
  static const String codeUnknown = 'E_UNKNOWN';

  final String code;
  final String message;
  final String? details;

  @override
  String toString() => 'AikoCoreException($code): $message';
}

/// A `{state, error?}` frame from `EventChannel("aikobox/core/status")`.
class CoreStatusEvent {
  const CoreStatusEvent({required this.state, this.error});

  factory CoreStatusEvent.fromMap(Map<Object?, Object?> map) {
    final error = map['error']?.toString();
    return CoreStatusEvent(
      state: CoreState.fromWire(map['state']),
      error: error == null || error.isEmpty ? null : error,
    );
  }

  final CoreState state;
  final String? error;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CoreStatusEvent && other.state == state && other.error == error;

  @override
  int get hashCode => Object.hash(state, error);

  @override
  String toString() =>
      'CoreStatusEvent(${state.wireName}${error == null ? '' : ', $error'})';
}

/// The Kotlin surface, as an interface so the controller and the widget tests
/// can be driven without a live platform.
abstract class CoreChannel {
  /// `true` when VPN consent has already been granted for this app.
  Future<bool> prepareVpn();

  /// Shows the system consent dialog; `true` when the user accepted.
  Future<bool> requestVpnPermission();

  /// Starts the core with an already-validated sing-box config.
  ///
  /// At most one of [includePackages] / [excludePackages] may be non-empty —
  /// Android's `VpnService.Builder` rejects an allow-list and a deny-list at
  /// the same time.
  Future<void> start(
    String configJson, {
    List<String> includePackages,
    List<String> excludePackages,
  });

  Future<void> stop();

  /// Runs `Libbox.checkConfig`. Returns `null` when the config is valid, or the
  /// core's own error message when it is not. This is the N2 gate: it runs
  /// while the previous core is still serving traffic.
  Future<String?> checkConfig(String json);

  Future<String> coreVersion();

  /// The installed-package list backing the split-tunnel picker.
  Future<List<InstalledApp>> installedApps();

  /// The port `experimental.clash_api.external_controller` ended up on.
  Future<int> clashApiPort();

  /// The bearer token for that controller.
  Future<String> clashApiSecret();

  /// Core lifecycle transitions. Broadcast: many listeners, no replay.
  Stream<CoreStatusEvent> statusEvents();

  /// Core log lines. Broadcast: many listeners, no replay.
  Stream<LogLine> logEvents();
}

/// The real implementation, bound to the channel names in §4.4.
class MethodChannelCoreChannel implements CoreChannel {
  MethodChannelCoreChannel({
    MethodChannel? methodChannel,
    EventChannel? statusChannel,
    EventChannel? logsChannel,
  }) : _method = methodChannel ?? const MethodChannel(methodChannelName),
       _statusChannel = statusChannel ?? const EventChannel(statusChannelName),
       _logsChannel = logsChannel ?? const EventChannel(logsChannelName);

  static const String methodChannelName = 'aikobox/core';
  static const String statusChannelName = 'aikobox/core/status';
  static const String logsChannelName = 'aikobox/core/logs';

  final MethodChannel _method;
  final EventChannel _statusChannel;
  final EventChannel _logsChannel;

  Stream<CoreStatusEvent>? _statusStream;
  Stream<LogLine>? _logStream;

  Future<T> _invoke<T>(String method, [Object? arguments]) async {
    try {
      final result = await _method.invokeMethod<T>(method, arguments);
      if (result == null) {
        throw AikoCoreException(
          AikoCoreException.codeUnknown,
          'aikobox/core.$method returned null',
        );
      }
      return result;
    } on PlatformException catch (error) {
      throw AikoCoreException.fromPlatform(error);
    } on MissingPluginException {
      throw AikoCoreException(
        AikoCoreException.codeNotImplemented,
        'aikobox/core.$method is not implemented by the host',
      );
    }
  }

  Future<void> _invokeVoid(String method, [Object? arguments]) async {
    try {
      await _method.invokeMethod<void>(method, arguments);
    } on PlatformException catch (error) {
      throw AikoCoreException.fromPlatform(error);
    } on MissingPluginException {
      throw AikoCoreException(
        AikoCoreException.codeNotImplemented,
        'aikobox/core.$method is not implemented by the host',
      );
    }
  }

  @override
  Future<bool> prepareVpn() => _invoke<bool>('prepareVpn');

  @override
  Future<bool> requestVpnPermission() => _invoke<bool>('requestVpnPermission');

  @override
  Future<void> start(
    String configJson, {
    List<String> includePackages = const <String>[],
    List<String> excludePackages = const <String>[],
  }) {
    if (includePackages.isNotEmpty && excludePackages.isNotEmpty) {
      throw ArgumentError(
        'VpnService.Builder accepts an allow-list or a deny-list, never both',
      );
    }
    return _invokeVoid('start', <String, dynamic>{
      'configJson': configJson,
      'includePackages': includePackages,
      'excludePackages': excludePackages,
    });
  }

  @override
  Future<void> stop() => _invokeVoid('stop');

  @override
  Future<String?> checkConfig(String json) async {
    try {
      return await _method.invokeMethod<String>(
        'checkConfig',
        <String, dynamic>{'json': json},
      );
    } on PlatformException catch (error) {
      // A host that reports invalidity as an error rather than as a return
      // value is still telling us the config is bad; surface its message.
      return error.message ?? error.code;
    } on MissingPluginException {
      throw AikoCoreException(
        AikoCoreException.codeNotImplemented,
        'aikobox/core.checkConfig is not implemented by the host',
      );
    }
  }

  @override
  Future<String> coreVersion() => _invoke<String>('coreVersion');

  @override
  Future<List<InstalledApp>> installedApps() async {
    final raw = await _invoke<List<Object?>>('installedApps');
    return <InstalledApp>[
      for (final entry in raw)
        if (entry is Map)
          InstalledApp.fromJson(<String, dynamic>{
            for (final e in entry.entries) e.key.toString(): e.value,
          }),
    ];
  }

  @override
  Future<int> clashApiPort() => _invoke<int>('clashApiPort');

  @override
  Future<String> clashApiSecret() async {
    try {
      return await _method.invokeMethod<String>('clashApiSecret') ?? '';
    } on PlatformException catch (error) {
      throw AikoCoreException.fromPlatform(error);
    } on MissingPluginException {
      throw AikoCoreException(
        AikoCoreException.codeNotImplemented,
        'aikobox/core.clashApiSecret is not implemented by the host',
      );
    }
  }

  @override
  Stream<CoreStatusEvent> statusEvents() => _statusStream ??= _statusChannel
      .receiveBroadcastStream()
      .map((event) => event is Map ? CoreStatusEvent.fromMap(event) : null)
      .where((event) => event != null)
      .cast<CoreStatusEvent>()
      .asBroadcastStream();

  @override
  Stream<LogLine> logEvents() => _logStream ??= _logsChannel
      .receiveBroadcastStream()
      .map(
        (event) => event is Map
            ? LogLine.fromChannelJson(<String, dynamic>{
                for (final e in event.entries) e.key.toString(): e.value,
              })
            : null,
      )
      .where((line) => line != null)
      .cast<LogLine>()
      .asBroadcastStream();
}
