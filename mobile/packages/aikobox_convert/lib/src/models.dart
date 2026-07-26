/// The public value types of the converter — §4.1 of the build contract.
library;

/// Where the app should reach the core's Clash-compatible control plane.
///
/// [listen] is always loopback: the control plane carries the full config and
/// live connection metadata, and nothing outside the device ever needs it.
class SingboxController {
  const SingboxController({
    required this.listen,
    required this.host,
    required this.port,
    required this.secret,
  });

  /// Value for `experimental.clash_api.external_controller`.
  final String listen;

  /// Host the app itself should connect to.
  final String host;

  final int port;

  final String secret;

  SingboxController copyWith({
    String? listen,
    String? host,
    int? port,
    String? secret,
  }) {
    return SingboxController(
      listen: listen ?? this.listen,
      host: host ?? this.host,
      port: port ?? this.port,
      secret: secret ?? this.secret,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'listen': listen,
        'host': host,
        'port': port,
        'secret': secret,
      };

  @override
  bool operator ==(Object other) =>
      other is SingboxController &&
      other.listen == listen &&
      other.host == host &&
      other.port == port &&
      other.secret == secret;

  @override
  int get hashCode => Object.hash(listen, host, port, secret);

  @override
  String toString() =>
      'SingboxController(listen: $listen, host: $host, port: $port, '
      'secret: ${secret.isEmpty ? '<none>' : '<redacted>'})';
}

/// Knobs that depend on where the emitted config will run.
///
/// Only `buildInbounds` and `route.default_mark` branch on [platform]; the rest
/// of the conversion is platform-independent.
class ConvertOptions {
  const ConvertOptions({
    this.platform = 'android',
    this.controllerSecret,
    this.autoRedirect = false,
  });

  /// `'android'` for this app; `'win32'`, `'linux'` or `'darwin'` when
  /// replaying the desktop golden cases.
  ///
  /// The empty string reproduces the TypeScript "platform not supplied" branch,
  /// where `tproxy-port` is emitted and `route.default_mark` is honoured.
  final String platform;

  /// Per-run secret used when the Clash profile does not carry one.
  final String? controllerSecret;

  /// Android only: permit `auto_redirect` on the tun inbound.
  ///
  /// This is a gate, not a switch. The profile still has to ask for
  /// `tun.auto-redirect`; this says the app is willing to grant it. A profile
  /// that asks while the app refuses gets a warning rather than silence.
  final bool autoRedirect;

  bool get platformUnspecified => platform.isEmpty;

  ConvertOptions copyWith({
    String? platform,
    String? controllerSecret,
    bool? autoRedirect,
  }) {
    return ConvertOptions(
      platform: platform ?? this.platform,
      controllerSecret: controllerSecret ?? this.controllerSecret,
      autoRedirect: autoRedirect ?? this.autoRedirect,
    );
  }

  @override
  String toString() =>
      'ConvertOptions(platform: $platform, autoRedirect: $autoRedirect)';
}

/// The outcome of a conversion.
///
/// [errors] is a safety mechanism, not a diagnostic. Every entry means the
/// emitted [config] would have routed traffic somewhere the profile did not
/// ask for — almost always straight out unproxied. A non-empty [errors] means
/// **do not start the core**, no matter how complete [config] looks.
class ConvertResult {
  const ConvertResult({
    required this.config,
    required this.warnings,
    required this.errors,
    required this.controller,
  });

  final Map<String, dynamic> config;
  final List<String> warnings;
  final List<String> errors;
  final SingboxController controller;

  /// True when the config is safe to hand to the core.
  bool get isUsable => errors.isEmpty;

  @override
  String toString() => 'ConvertResult(warnings: ${warnings.length}, '
      'errors: ${errors.length})';
}
