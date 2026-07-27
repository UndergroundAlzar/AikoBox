import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../security/redaction.dart';
import 'profile.dart';

const maxProfileBytes = 4 * 1024 * 1024;
typedef HostResolver = Future<List<InternetAddress>> Function(String host);

class DownloadedProfile {
  const DownloadedProfile(this.response, this.finalUri);

  final http.StreamedResponse response;
  final Uri finalUri;
}

class ProfileImportService {
  ProfileImportService({
    http.Client? client,
    this.timeout = const Duration(seconds: 15),
    this.maxRedirects = 3,
    this.totalTimeout = const Duration(seconds: 30),
    DateTime Function()? clock,
    this.fileStore,
    HostResolver? hostResolver,
  }) : _client = client ?? http.Client(),
       _clock = clock ?? DateTime.now,
       _hostResolver = hostResolver ?? InternetAddress.lookup;

  final http.Client _client;
  final Duration timeout;
  final int maxRedirects;
  final Duration totalTimeout;
  final DateTime Function() _clock;
  final ProfileFileStore? fileStore;
  final HostResolver _hostResolver;

  Future<void> discard(Profile profile) async {
    await fileStore?.delete(profile);
  }

  Future<Profile> fromStream({
    required Stream<List<int>> stream,
    required String suggestedName,
    ProfileSource source = ProfileSource.localFile,
    String? sourceHost,
  }) async {
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      bytes.add(chunk);
      if (bytes.length > maxProfileBytes) {
        throw const ProfileImportException('配置超过 4 MiB 限制');
      }
    }
    return fromBytes(
      bytes: bytes.takeBytes(),
      suggestedName: suggestedName,
      source: source,
      sourceHost: sourceHost,
    );
  }

  Future<Profile> fromBytes({
    required Uint8List bytes,
    required String suggestedName,
    ProfileSource source = ProfileSource.localFile,
    String? sourceHost,
  }) async {
    if (bytes.length > maxProfileBytes) {
      throw const ProfileImportException('配置超过 4 MiB 限制');
    }
    late final String decoded;
    try {
      decoded = utf8.decode(bytes, allowMalformed: false);
    } on FormatException {
      throw const ProfileImportException('配置不是有效的 UTF-8 文本');
    }
    final profile = _build(
      decoded,
      suggestedName: suggestedName,
      source: source,
      sourceHost: sourceHost,
    );
    return fileStore == null ? profile : fileStore!.persist(profile);
  }

  Future<Profile> fromPasted(String input, {String? suggestedName}) async {
    return fromBytes(
      bytes: Uint8List.fromList(utf8.encode(input)),
      suggestedName: suggestedName ?? '粘贴的配置',
      source: ProfileSource.pasted,
    );
  }

  Future<Profile> fromHttpsUrl(String input) async {
    final uri = Uri.tryParse(input.trim());
    if (uri == null ||
        uri.scheme.toLowerCase() != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw const ProfileImportException('只允许不含账号信息的 HTTPS 地址');
    }

    try {
      return await _fromHttpsUrl(uri).timeout(totalTimeout);
    } on TimeoutException {
      throw const ProfileImportException('下载超时，请检查网络后重试');
    }
  }

  Future<Profile> _fromHttpsUrl(Uri uri) async {
    try {
      final downloaded = await _download(uri);
      final response = downloaded.response;
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw ProfileImportException('下载失败（HTTP ${response.statusCode}）');
      }
      final contentLength = response.contentLength;
      if (contentLength != null && contentLength > maxProfileBytes) {
        throw const ProfileImportException('配置超过 4 MiB 限制');
      }
      final bytes = <int>[];
      await for (final chunk in response.stream.timeout(timeout)) {
        bytes.addAll(chunk);
        if (bytes.length > maxProfileBytes) {
          throw const ProfileImportException('配置超过 4 MiB 限制');
        }
      }
      return fromBytes(
        bytes: Uint8List.fromList(bytes),
        suggestedName: downloaded.finalUri.host,
        source: ProfileSource.httpsUrl,
        sourceHost: downloaded.finalUri.host,
      );
    } on ProfileImportException {
      rethrow;
    } on TimeoutException {
      throw const ProfileImportException('下载超时，请检查网络后重试');
    } on Object catch (error) {
      throw ProfileImportException('导入失败：${redactSensitive(error.toString())}');
    }
  }

  Future<DownloadedProfile> _download(Uri initialUri) async {
    var currentUri = initialUri;
    for (var redirectCount = 0; ; redirectCount += 1) {
      await _requirePublicHost(currentUri.host);
      final request = http.Request('GET', currentUri)..followRedirects = false;
      final response = await _client.send(request).timeout(timeout);
      if (!_isRedirect(response.statusCode)) {
        return DownloadedProfile(response, currentUri);
      }
      final location = response.headers['location'];
      if (location == null || redirectCount >= maxRedirects) {
        await response.stream.drain<void>();
        throw const ProfileImportException('HTTPS 重定向过多或缺少目标地址');
      }
      final nextUri = currentUri.resolve(location);
      if (nextUri.scheme.toLowerCase() != 'https' ||
          nextUri.host.isEmpty ||
          nextUri.userInfo.isNotEmpty) {
        await response.stream.drain<void>();
        throw const ProfileImportException('拒绝跳转到不安全的地址');
      }
      await response.stream.drain<void>();
      currentUri = nextUri;
    }
  }

  Future<void> _requirePublicHost(String host) async {
    final normalized = host.toLowerCase();
    if (normalized == 'localhost' || normalized.endsWith('.localhost')) {
      throw const ProfileImportException('拒绝访问本机或私有网络地址');
    }
    final literal = InternetAddress.tryParse(host);
    final addresses = literal == null ? await _hostResolver(host) : [literal];
    if (addresses.isEmpty || addresses.any((address) => !_isPublic(address))) {
      throw const ProfileImportException('拒绝访问本机或私有网络地址');
    }
  }

  bool _isPublic(InternetAddress address) {
    final bytes = address.rawAddress;
    if (address.type == InternetAddressType.IPv4) {
      final a = bytes[0];
      final b = bytes[1];
      return a != 0 &&
          a != 10 &&
          a != 127 &&
          !(a == 100 && b >= 64 && b <= 127) &&
          !(a == 169 && b == 254) &&
          !(a == 172 && b >= 16 && b <= 31) &&
          !(a == 192 && b == 168) &&
          !(a == 192 && b == 0) &&
          !(a == 192 && b == 88) &&
          !(a == 198 && (b == 18 || b == 19 || b == 51)) &&
          !(a == 203 && b == 0) &&
          a < 224;
    }
    if (bytes.length != 16) {
      return false;
    }
    final isGlobalUnicast = (bytes[0] & 0xE0) == 0x20;
    final isDocumentation =
        bytes[0] == 0x20 &&
        bytes[1] == 0x01 &&
        bytes[2] == 0x0D &&
        bytes[3] == 0xB8;
    final isSpecialPurpose2001 =
        bytes[0] == 0x20 &&
        bytes[1] == 0x01 &&
        bytes[2] <= 0x01;
    final isDocumentation3fff =
        bytes[0] == 0x3F &&
        bytes[1] == 0xFF &&
        bytes[2] < 0x10;
    return isGlobalUnicast &&
        !isDocumentation &&
        !isSpecialPurpose2001 &&
        !isDocumentation3fff;
  }

  bool _isRedirect(int statusCode) {
    return statusCode == 301 ||
        statusCode == 302 ||
        statusCode == 303 ||
        statusCode == 307 ||
        statusCode == 308;
  }

  Profile _build(
    String raw, {
    required String suggestedName,
    required ProfileSource source,
    String? sourceHost,
  }) {
    if (raw.trim().isEmpty) {
      throw const ProfileImportException('配置内容为空');
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, Object?>) {
        throw const FormatException('root must be an object');
      }
      final normalized = jsonEncode(decoded);
      if (utf8.encode(normalized).length > maxProfileBytes) {
        throw const ProfileImportException('规范化后的配置超过 4 MiB 限制');
      }
      final now = _clock().toUtc();
      return Profile(
        id: '${now.microsecondsSinceEpoch}-${normalized.hashCode.abs()}',
        name: _cleanName(suggestedName),
        json: normalized,
        source: source,
        createdAt: now,
        sourceHost: sourceHost,
      );
    } on FormatException {
      throw const ProfileImportException('不是有效的 sing-box JSON 配置');
    }
  }

  String _cleanName(String value) {
    final clean = value
        .replaceAll(RegExp(r'\.json$', caseSensitive: false), '')
        .trim();
    return clean.isEmpty ? '未命名配置' : clean;
  }
}

class ProfileImportException implements Exception {
  const ProfileImportException(this.message);

  final String message;

  @override
  String toString() => message;
}

abstract interface class ProfileFileStore {
  Future<Profile> persist(Profile profile);
  Future<void> delete(Profile profile);
}

class DeviceProfileFileStore implements ProfileFileStore {
  const DeviceProfileFileStore();

  @override
  Future<Profile> persist(Profile profile) async {
    final supportDirectory = await getApplicationSupportDirectory();
    final profilesDirectory = Directory(
      '${supportDirectory.path}${Platform.pathSeparator}profiles',
    );
    await profilesDirectory.create(recursive: true);
    final destination = File(
      '${profilesDirectory.path}${Platform.pathSeparator}${profile.id}.json',
    );
    final temporary = File('${destination.path}.tmp');
    final backup = File('${destination.path}.bak');
    try {
      await temporary.writeAsString(profile.json, encoding: utf8, flush: true);
      if (await destination.exists()) {
        await destination.rename(backup.path);
      }
      await temporary.rename(destination.path);
      if (await backup.exists()) {
        await backup.delete();
      }
      return profile.copyWith(path: destination.path);
    } on Object {
      if (await temporary.exists()) {
        await temporary.delete();
      }
      if (await backup.exists()) {
        if (await destination.exists()) {
          await destination.delete();
        }
        await backup.rename(destination.path);
      }
      rethrow;
    }
  }

  @override
  Future<void> delete(Profile profile) async {
    final path = profile.path;
    if (path == null) {
      return;
    }
    final supportDirectory = await getApplicationSupportDirectory();
    final root =
        '${Directory(supportDirectory.path).absolute.path}'
        '${Platform.pathSeparator}profiles${Platform.pathSeparator}';
    final file = File(path).absolute;
    if (file.path.startsWith(root) &&
        file.path.toLowerCase().endsWith('.json') &&
        await file.exists()) {
      await file.delete();
    }
  }
}
