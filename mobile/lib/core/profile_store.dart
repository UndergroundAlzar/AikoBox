/// Profiles on disk, and subscription downloading.
///
/// Ports `src/main/config/profile.ts` (the parts that have an Android meaning)
/// plus the guards in `src/main/config/remoteResource.ts`.
///
/// ## N7 — subscription handling is hostile-input handling
///
/// A subscription URL is attacker-controlled by definition: the user pastes it
/// from a web page. Everything below is a guard, not a nicety.
///
/// * HTTPS only. No plaintext subscription fetch, ever.
/// * The redirect chain is walked by hand — `followRedirects: false`, at most
///   [maxRedirects] hops — because a client that follows redirects internally
///   cannot be asked to veto an individual hop.
/// * No HTTPS→HTTP downgrade on any hop.
/// * No cross-origin hop while carrying credentials (an `Authorization` header
///   or userinfo in the URL).
/// * A byte cap enforced while streaming, so a hostile server cannot exhaust
///   the phone's memory before we notice.
/// * HTML bodies and media content types are refused: an airport's login page
///   is not a subscription.
/// * Every error message is redacted through `redactUrl` and never carries a
///   token, a password or a query string.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aikobox_subscription/aikobox_subscription.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:yaml/yaml.dart';
import 'package:yaml_edit/yaml_edit.dart';

import 'config_store.dart';
import 'models.dart';
import 'paths.dart';

/// Stable, machine-readable reasons a subscription fetch failed. The UI maps
/// these to l10n keys; [SubscriptionException.message] is only a fallback and
/// is already redacted.
enum SubscriptionErrorCode {
  invalidUrl,
  notHttps,
  redirectDowngrade,
  redirectCrossOriginWithCredentials,
  tooManyRedirects,
  httpStatus,
  timeout,
  network,
  tooLarge,
  htmlResponse,
  emptyResponse,
  unusableContent,
  outOfBounds,
  notModifiedWithoutCache,
}

/// A subscription fetch that failed, with the reason in a form the UI can
/// localise and a message that is safe to show verbatim.
class SubscriptionException implements Exception {
  const SubscriptionException(this.code, this.message, {this.statusCode});

  final SubscriptionErrorCode code;

  /// Already redacted: no tokens, no passwords, no query strings.
  final String message;
  final int? statusCode;

  @override
  String toString() => 'SubscriptionException(${code.name}): $message';
}

/// The `{current, items}` index, stored as `<appSupport>/profile.yaml`.
/// Port of `IProfileConfig`.
class ProfileConfig {
  const ProfileConfig({this.current, this.items = const <ProfileItem>[]});

  factory ProfileConfig.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'];
    return ProfileConfig(
      current: json['current']?.toString(),
      items: <ProfileItem>[
        if (rawItems is List)
          for (final entry in rawItems)
            if (entry is Map)
              ProfileItem.fromJson(<String, dynamic>{
                for (final field in entry.entries)
                  field.key.toString(): field.value,
              }),
      ],
    );
  }

  static const ProfileConfig empty = ProfileConfig();

  final String? current;
  final List<ProfileItem> items;

  ProfileItem? get currentItem {
    final id = current;
    if (id == null) return null;
    for (final item in items) {
      if (item.id == id) return item;
    }
    return null;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    if (current != null) 'current': current,
    'items': items.map((item) => item.toJson()).toList(growable: false),
  };

  ProfileConfig copyWith({
    String? current,
    bool clearCurrent = false,
    List<ProfileItem>? items,
  }) => ProfileConfig(
    current: clearCurrent ? null : (current ?? this.current),
    items: items ?? this.items,
  );
}

/// Recursively converts `YamlMap` / `YamlList` into plain Dart collections.
///
/// `package:yaml` hands back views that are not `Map<String, dynamic>`, and
/// both the converter and the YAML emitter need real collections.
Object? plainifyYaml(Object? value) {
  if (value is YamlMap) {
    return <String, dynamic>{
      for (final entry in value.nodes.entries)
        entry.key.toString(): plainifyYaml(entry.value.value),
    };
  }
  if (value is YamlList) {
    return <dynamic>[
      for (final entry in value.nodes) plainifyYaml(entry.value),
    ];
  }
  if (value is YamlScalar) return value.value;
  if (value is Map) {
    return <String, dynamic>{
      for (final entry in value.entries)
        entry.key.toString(): plainifyYaml(entry.value),
    };
  }
  if (value is List) {
    return <dynamic>[for (final entry in value) plainifyYaml(entry)];
  }
  return value;
}

/// Parses a Clash YAML document into a plain map. An empty document yields an
/// empty map; anything that is not a mapping is a hard error.
Map<String, dynamic> parseClashYaml(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return <String, dynamic>{};
  final decoded = plainifyYaml(loadYaml(text));
  if (decoded == null) return <String, dynamic>{};
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('Profile is not a YAML mapping');
  }
  return decoded;
}

/// Emits a plain Dart structure as YAML.
String encodeYaml(Object? value) {
  final editor = YamlEditor('');
  editor.update(const <Object?>[], plainifyYaml(value));
  final text = editor.toString();
  return text.endsWith('\n') ? text : '$text\n';
}

/// Conditional-GET validators for one profile.
///
/// [identity] is a hash of the complete request context — URL, token, user
/// agent — so a cached ETag can never be replayed against a different request.
/// The URL and the token themselves are deliberately not persisted.
class HttpCacheMetadata {
  const HttpCacheMetadata({
    required this.identity,
    required this.fetchedAt,
    this.etag,
    this.lastModified,
  });

  static HttpCacheMetadata? tryParse(String raw, String expectedIdentity) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      if (decoded['url'] != expectedIdentity) return null;
      final fetchedAt = decoded['fetchedAt'];
      if (fetchedAt is! num) return null;
      return HttpCacheMetadata(
        identity: expectedIdentity,
        fetchedAt: fetchedAt.toInt(),
        etag: decoded['etag'] is String ? decoded['etag'] as String : null,
        lastModified: decoded['lastModified'] is String
            ? decoded['lastModified'] as String
            : null,
      );
    } catch (_) {
      return null;
    }
  }

  final String identity;
  final int fetchedAt;
  final String? etag;
  final String? lastModified;

  Map<String, String> get conditionalHeaders => <String, String>{
    'If-None-Match': ?etag,
    'If-Modified-Since': ?lastModified,
  };

  Map<String, dynamic> toJson() => <String, dynamic>{
    'url': identity,
    'fetchedAt': fetchedAt,
    if (etag != null) 'etag': etag,
    if (lastModified != null) 'lastModified': lastModified,
  };
}

/// One completed subscription download.
class SubscriptionFetch {
  const SubscriptionFetch({
    required this.body,
    required this.headers,
    required this.notModified,
  });

  final String body;
  final Map<String, String> headers;
  final bool notModified;
}

/// Profiles on disk plus subscription downloading.
class ProfileStore {
  ProfileStore({
    required this.dirs,
    http.Client? httpClient,
    this.defaultUserAgent = 'AikoBox/0.1.0',
    this.maxBodyBytes = 16 * 1024 * 1024,
    this.maxRedirects = 5,
  }) : _client = httpClient ?? http.Client(),
       _ownsClient = httpClient == null;

  /// Opens the store at the standard location.
  static Future<ProfileStore> open({
    http.Client? httpClient,
    String? userAgent,
  }) async {
    final dirs = await AikoDirs.ensure();
    return ProfileStore(
      dirs: dirs,
      httpClient: httpClient,
      defaultUserAgent: userAgent ?? 'AikoBox/0.1.0',
    );
  }

  final AikoDirs dirs;

  /// 16 MiB. The desktop allows 32; a phone that has to hold the body, the
  /// parsed YAML and the converted JSON at once does not.
  final int maxBodyBytes;

  /// Hops the redirect walker will take before refusing.
  final int maxRedirects;
  final String defaultUserAgent;

  final http.Client _client;
  final bool _ownsClient;
  final SerialTaskQueue _indexQueue = SerialTaskQueue();
  final Map<String, SerialTaskQueue> _contentQueues =
      <String, SerialTaskQueue>{};
  ProfileConfig? _cache;

  void close() {
    if (_ownsClient) _client.close();
  }

  SerialTaskQueue _queueFor(String id) =>
      _contentQueues.putIfAbsent(id, SerialTaskQueue.new);

  // -------------------------------------------------------------------------
  // The index
  // -------------------------------------------------------------------------

  /// Reads `profile.yaml`. A corrupt index yields an empty one rather than an
  /// unlaunchable app; the profile files themselves are untouched.
  Future<ProfileConfig> readConfig({bool force = false}) =>
      _indexQueue.enqueue(() async {
        final cached = _cache;
        if (cached != null && !force) return cached;
        final config = await _readConfigUnlocked();
        _cache = config;
        return config;
      });

  Future<ProfileConfig> _readConfigUnlocked() async {
    final file = dirs.profileConfigFile;
    if (!file.existsSync()) return ProfileConfig.empty;
    try {
      final decoded = plainifyYaml(loadYaml(await file.readAsString()));
      if (decoded is! Map<String, dynamic>) return ProfileConfig.empty;
      return ProfileConfig.fromJson(decoded);
    } catch (_) {
      return ProfileConfig.empty;
    }
  }

  /// Read-modify-write of the index under the queue.
  Future<ProfileConfig> updateConfig(
    FutureOr<ProfileConfig> Function(ProfileConfig current) updater,
  ) => _indexQueue.enqueue(() async {
    final current = await _readConfigUnlocked();
    final next = await updater(current);
    await writeFileAtomically(
      dirs.profileConfigFile,
      encodeYaml(next.toJson()),
    );
    _cache = next;
    return next;
  });

  Future<List<ProfileItem>> listItems({bool force = false}) async =>
      (await readConfig(force: force)).items;

  Future<ProfileItem?> item(String id) async {
    for (final candidate in (await readConfig()).items) {
      if (candidate.id == id) return candidate;
    }
    return null;
  }

  Future<ProfileItem?> currentItem() async => (await readConfig()).currentItem;

  /// Points `current` at [id]. Does not restart the core — the caller decides
  /// when a reload is appropriate.
  Future<ProfileConfig> setCurrent(String id) async {
    assertSafeProfileId(id);
    return updateConfig((config) {
      if (!config.items.any((item) => item.id == id)) {
        throw StateError('Profile $id does not exist');
      }
      return config.copyWith(current: id);
    });
  }

  // -------------------------------------------------------------------------
  // Profile content
  // -------------------------------------------------------------------------

  Future<String> readProfileText(String id) async {
    assertSafeProfileId(id);
    final file = dirs.profileFile(id);
    if (!file.existsSync()) {
      throw StateError('Profile $id has no stored content');
    }
    return file.readAsString();
  }

  /// Reads a profile and parses it as a Clash config map.
  Future<Map<String, dynamic>> readClashConfig(String id) async =>
      parseClashYaml(await readProfileText(id));

  /// Writes a profile's content atomically, serialised per profile id.
  Future<void> writeProfileText(String id, String content) {
    assertSafeProfileId(id);
    return _queueFor(id).enqueue(() async {
      if (!dirs.profilesDir.existsSync()) {
        await dirs.profilesDir.create(recursive: true);
      }
      await writeFileAtomically(dirs.profileFile(id), content);
    });
  }

  // -------------------------------------------------------------------------
  // Import / update
  // -------------------------------------------------------------------------

  /// Stores a pasted or picked Clash YAML as a local profile.
  ///
  /// The payload goes through the same normaliser and the same bounds check as
  /// a downloaded one: a file the user picked is not more trustworthy than a
  /// file a server sent, it is just differently delivered.
  Future<ProfileItem> importLocal({
    required String name,
    required String content,
  }) async {
    final id = newProfileId();
    final clash = _normalize(content);
    await writeProfileText(id, encodeYaml(clash));
    final item = ProfileItem(
      id: id,
      type: 'local',
      name: name.trim().isEmpty ? 'Local File' : name.trim(),
      updated: DateTime.now().millisecondsSinceEpoch,
    );
    await _upsert(item);
    return item;
  }

  /// Downloads a subscription and stores it as a new remote profile.
  Future<ProfileItem> importRemote({
    required String url,
    String? name,
    String? authToken,
    String? userAgent,
    bool autoUpdate = false,
    int? intervalMinutes,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final id = newProfileId();
    final seed = ProfileItem(
      id: id,
      type: 'remote',
      name: (name ?? '').trim().isEmpty ? 'Remote File' : name!.trim(),
      url: url,
      autoUpdate: autoUpdate,
      interval: intervalMinutes,
      userAgent: userAgent,
    );
    final item = await _downloadInto(
      seed,
      authToken: authToken,
      timeout: timeout,
    );
    await _upsert(item);
    return item;
  }

  /// Re-downloads an existing remote profile in place.
  Future<ProfileItem> updateRemote(
    String id, {
    String? authToken,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final existing = await item(id);
    if (existing == null) throw StateError('Profile $id does not exist');
    if (!existing.isRemote || existing.url == null) {
      throw StateError('Profile $id is not a subscription');
    }
    final updated = await _downloadInto(
      existing,
      authToken: authToken,
      timeout: timeout,
    );
    await _upsert(updated);
    return updated;
  }

  /// Deletes a profile, its content, and its conditional-GET cache.
  ///
  /// If it was the current profile, `current` moves to whatever is left — or
  /// becomes null when nothing is.
  Future<ProfileConfig> remove(String id) async {
    assertSafeProfileId(id);
    final config = await updateConfig((current) {
      final remaining = current.items
          .where((item) => item.id != id)
          .toList(growable: false);
      if (current.current != id) {
        return current.copyWith(items: remaining);
      }
      return ProfileConfig(
        current: remaining.isEmpty ? null : remaining.first.id,
        items: remaining,
      );
    });
    await _queueFor(id).enqueue(() async {
      for (final file in <File>[
        dirs.profileFile(id),
        dirs.profileHttpCacheFile(id),
      ]) {
        try {
          if (file.existsSync()) await file.delete();
        } catch (_) {
          // A leftover file is not worth failing the delete over.
        }
      }
    });
    _contentQueues.remove(id);
    return config;
  }

  /// Renames a profile, or changes its auto-update settings.
  Future<ProfileItem> patchItem(
    String id,
    ProfileItem Function(ProfileItem current) updater,
  ) async {
    ProfileItem? result;
    await updateConfig((config) {
      final index = config.items.indexWhere((item) => item.id == id);
      if (index == -1) throw StateError('Profile $id does not exist');
      final next = updater(config.items[index]);
      result = next;
      final items = List<ProfileItem>.of(config.items);
      items[index] = next;
      return config.copyWith(items: items);
    });
    return result!;
  }

  Future<void> _upsert(ProfileItem item) => updateConfig((config) {
    final items = List<ProfileItem>.of(config.items);
    final index = items.indexWhere((existing) => existing.id == item.id);
    if (index == -1) {
      items.add(item);
    } else {
      items[index] = item;
    }
    return ProfileConfig(current: config.current ?? item.id, items: items);
  });

  Map<String, dynamic> _normalize(String body) {
    final Map<String, dynamic> clash;
    try {
      clash = normalizeSubscriptionPayload(body);
    } on SubscriptionFormatException catch (error) {
      throw SubscriptionException(
        SubscriptionErrorCode.unusableContent,
        error.message,
      );
    } on SubscriptionBoundsException catch (error) {
      throw SubscriptionException(
        SubscriptionErrorCode.outOfBounds,
        error.message,
      );
    } on FormatException catch (error) {
      throw SubscriptionException(
        SubscriptionErrorCode.unusableContent,
        'The subscription could not be parsed: ${error.message}',
      );
    }
    try {
      assertBoundedClashSubscription(clash);
    } on SubscriptionBoundsException catch (error) {
      throw SubscriptionException(
        SubscriptionErrorCode.outOfBounds,
        error.message,
      );
    }
    return clash;
  }

  Future<ProfileItem> _downloadInto(
    ProfileItem seed, {
    String? authToken,
    required Duration timeout,
  }) async {
    final url = seed.url!;
    final userAgent = seed.userAgent ?? defaultUserAgent;
    final identity = subscriptionRequestIdentity(
      profileId: seed.id,
      url: url,
      authToken: authToken,
      userAgent: userAgent,
    );
    final cacheFile = dirs.profileHttpCacheFile(seed.id);
    final cached = cacheFile.existsSync()
        ? HttpCacheMetadata.tryParse(await cacheFile.readAsString(), identity)
        : null;

    final effectiveTimeout =
        seed.updateTimeout != null && seed.updateTimeout! > 0
        ? Duration(seconds: seed.updateTimeout!.clamp(1, 300))
        : timeout;

    var result = await fetchSubscription(
      url: url,
      userAgent: userAgent,
      authToken: authToken,
      timeout: effectiveTimeout,
      conditionalHeaders:
          cached?.conditionalHeaders ?? const <String, String>{},
    );

    // A 304 is only usable when a cached body actually exists on disk.
    if (result.notModified && !dirs.profileFile(seed.id).existsSync()) {
      result = await fetchSubscription(
        url: url,
        userAgent: userAgent,
        authToken: authToken,
        timeout: effectiveTimeout,
      );
      if (result.notModified) {
        throw const SubscriptionException(
          SubscriptionErrorCode.notModifiedWithoutCache,
          'The server answered 304 but no cached subscription exists',
        );
      }
    }

    var item = seed;
    final headers = result.headers;

    if (!result.notModified) {
      final clash = _normalize(result.body);
      await writeProfileText(seed.id, encodeYaml(clash));
    }

    final disposition = headers['content-disposition'];
    if (disposition != null &&
        (item.name == 'Remote File' || item.name.isEmpty)) {
      item = item.copyWith(name: parseContentDispositionFilename(disposition));
    }
    final homePage = headers['profile-web-page-url'];
    if (homePage != null && homePage.startsWith('https://')) {
      item = item.copyWith(home: homePage);
    }
    final intervalHeader = headers['profile-update-interval'];
    if (intervalHeader != null) {
      final hours = double.tryParse(intervalHeader.trim());
      if (hours != null && hours > 0) {
        item = item.copyWith(
          interval: (hours * 60).ceil().clamp(1, 60 * 24 * 365),
        );
      }
    }
    final usage = SubscriptionUsage.tryParseHeader(
      headers['subscription-userinfo'],
    );
    if (usage != null) item = item.copyWith(extra: usage);

    item = item.copyWith(updated: DateTime.now().millisecondsSinceEpoch);

    try {
      await writeFileAtomically(
        cacheFile,
        jsonEncode(
          HttpCacheMetadata(
            identity: identity,
            fetchedAt: DateTime.now().millisecondsSinceEpoch,
            etag: headers['etag'] ?? cached?.etag,
            lastModified: headers['last-modified'] ?? cached?.lastModified,
          ).toJson(),
        ),
      );
    } catch (_) {
      // The cache is an optimisation; failing to persist it is not an error.
    }

    return item;
  }

  // -------------------------------------------------------------------------
  // The guarded fetch (N7)
  // -------------------------------------------------------------------------

  /// Downloads a subscription body with every N7 guard applied.
  ///
  /// The redirect chain is walked here rather than delegated, because each hop
  /// has to be vetted individually and no HTTP client exposes a veto callback
  /// that is reliable across platforms.
  Future<SubscriptionFetch> fetchSubscription({
    required String url,
    required String userAgent,
    String? authToken,
    Duration timeout = const Duration(seconds: 30),
    Map<String, String> conditionalHeaders = const <String, String>{},
  }) async {
    var current = _parseSubscriptionUrl(url);
    final origin = _originOf(current);
    var carriesCredentials =
        (authToken != null && authToken.isNotEmpty) ||
        current.userInfo.isNotEmpty;

    final deadline = DateTime.now().add(timeout);

    for (var hop = 0; hop <= maxRedirects; hop++) {
      final headers = <String, String>{
        'User-Agent': userAgent,
        'Accept-Encoding': 'identity',
        ...conditionalHeaders,
        if (authToken != null && authToken.isNotEmpty)
          'Authorization': authToken,
      };
      _assertHeaderValues(headers);

      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        throw const SubscriptionException(
          SubscriptionErrorCode.timeout,
          'The subscription server timed out',
        );
      }

      final http.StreamedResponse response;
      try {
        final request = http.Request('GET', current)
          ..followRedirects = false
          ..persistentConnection = false
          ..headers.addAll(headers);
        response = await _client.send(request).timeout(remaining);
      } on TimeoutException {
        throw const SubscriptionException(
          SubscriptionErrorCode.timeout,
          'The subscription server timed out',
        );
      } on SubscriptionException {
        rethrow;
      } catch (_) {
        throw SubscriptionException(
          SubscriptionErrorCode.network,
          'Could not reach ${redactUrl(current.toString())}',
        );
      }

      if (_isRedirect(response.statusCode)) {
        await response.stream.drain<void>();
        final location = response.headers['location'];
        if (location == null || location.trim().isEmpty) {
          throw const SubscriptionException(
            SubscriptionErrorCode.httpStatus,
            'The subscription server sent a redirect with no destination',
          );
        }
        if (hop == maxRedirects) {
          throw SubscriptionException(
            SubscriptionErrorCode.tooManyRedirects,
            'The subscription redirected more than $maxRedirects times',
          );
        }
        final next = _resolveRedirect(current, location);
        if (next.scheme != 'https') {
          throw const SubscriptionException(
            SubscriptionErrorCode.redirectDowngrade,
            'The subscription tried to redirect away from HTTPS',
          );
        }
        if (carriesCredentials && _originOf(next) != origin) {
          throw const SubscriptionException(
            SubscriptionErrorCode.redirectCrossOriginWithCredentials,
            'The subscription redirected to another site while carrying credentials',
          );
        }
        // Userinfo in a redirect target is never carried forward.
        current = next.replace(userInfo: '');
        carriesCredentials = authToken != null && authToken.isNotEmpty;
        continue;
      }

      if (response.statusCode == 304) {
        await response.stream.drain<void>();
        return SubscriptionFetch(
          body: '',
          headers: _lowercaseHeaders(response.headers),
          notModified: true,
        );
      }

      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.stream.drain<void>();
        throw SubscriptionException(
          SubscriptionErrorCode.httpStatus,
          describeSubscriptionHttpStatus(response.statusCode),
          statusCode: response.statusCode,
        );
      }

      final body = await _readCapped(response, deadline);
      final responseHeaders = _lowercaseHeaders(response.headers);
      assertUsableSubscriptionBody(body, responseHeaders['content-type']);
      return SubscriptionFetch(
        body: body,
        headers: responseHeaders,
        notModified: false,
      );
    }

    throw SubscriptionException(
      SubscriptionErrorCode.tooManyRedirects,
      'The subscription redirected more than $maxRedirects times',
    );
  }

  Uri _parseSubscriptionUrl(String url) {
    final Uri parsed;
    try {
      parsed = Uri.parse(url.trim());
    } catch (_) {
      throw const SubscriptionException(
        SubscriptionErrorCode.invalidUrl,
        'The subscription link is not a valid URL',
      );
    }
    if (!parsed.hasScheme || parsed.host.isEmpty) {
      throw const SubscriptionException(
        SubscriptionErrorCode.invalidUrl,
        'The subscription link is not a valid URL',
      );
    }
    if (parsed.scheme != 'https') {
      throw const SubscriptionException(
        SubscriptionErrorCode.notHttps,
        'Subscriptions must use HTTPS',
      );
    }
    return parsed;
  }

  Uri _resolveRedirect(Uri from, String location) {
    try {
      return from.resolve(location.trim());
    } catch (_) {
      throw const SubscriptionException(
        SubscriptionErrorCode.invalidUrl,
        'The subscription redirected to an address that is not a valid URL',
      );
    }
  }

  Future<String> _readCapped(
    http.StreamedResponse response,
    DateTime deadline,
  ) async {
    final declared = response.contentLength;
    if (declared != null && declared > maxBodyBytes) {
      await response.stream.drain<void>();
      throw SubscriptionException(
        SubscriptionErrorCode.tooLarge,
        'The subscription is larger than the $maxBodyBytes-byte limit',
      );
    }
    final bytes = BytesBuilder(copy: false);
    try {
      await for (final chunk in response.stream) {
        bytes.add(chunk);
        if (bytes.length > maxBodyBytes) {
          throw SubscriptionException(
            SubscriptionErrorCode.tooLarge,
            'The subscription is larger than the $maxBodyBytes-byte limit',
          );
        }
        if (DateTime.now().isAfter(deadline)) {
          throw const SubscriptionException(
            SubscriptionErrorCode.timeout,
            'The subscription server timed out',
          );
        }
      }
    } on SubscriptionException {
      rethrow;
    } catch (_) {
      throw const SubscriptionException(
        SubscriptionErrorCode.network,
        'The connection dropped while downloading the subscription',
      );
    }
    try {
      return utf8.decode(bytes.takeBytes(), allowMalformed: true);
    } catch (_) {
      throw const SubscriptionException(
        SubscriptionErrorCode.unusableContent,
        'The subscription is not text',
      );
    }
  }

  void _assertHeaderValues(Map<String, String> headers) {
    for (final entry in headers.entries) {
      final value = entry.value;
      if (value.length > 8192 || _nonPrintableAscii.hasMatch(value)) {
        throw SubscriptionException(
          SubscriptionErrorCode.invalidUrl,
          'The request header "${entry.key}" is not valid',
        );
      }
    }
  }

  static Map<String, String> _lowercaseHeaders(
    Map<String, String> headers,
  ) => <String, String>{
    for (final entry in headers.entries) entry.key.toLowerCase(): entry.value,
  };

  static String _originOf(Uri uri) =>
      '${uri.scheme}://${uri.host}:${uri.hasPort ? uri.port : 443}';

  static bool _isRedirect(int status) =>
      status == 301 ||
      status == 302 ||
      status == 303 ||
      status == 307 ||
      status == 308;
}

final RegExp _nonPrintableAscii = RegExp(r'[^\x20-\x7E]');
final RegExp _htmlPrefix = RegExp(
  r'^\s*(?:<!doctype\s+html\b|<html\b|<head\b|<body\b)',
  caseSensitive: false,
);

/// Refuses bodies that are obviously not a subscription.
///
/// Port of `remoteResource.ts:assertRemoteText`. An airport that answers a
/// missing token with its own login page must fail loudly, not be stored as a
/// profile that later fails to convert.
void assertUsableSubscriptionBody(String content, String? contentType) {
  if (content.isEmpty) {
    throw const SubscriptionException(
      SubscriptionErrorCode.emptyResponse,
      'The subscription server returned nothing',
    );
  }
  if (content.contains('\u0000')) {
    throw const SubscriptionException(
      SubscriptionErrorCode.unusableContent,
      'The subscription server returned binary data',
    );
  }
  final mediaType = (contentType ?? '').split(';').first.trim().toLowerCase();
  if (mediaType == 'text/html' || mediaType == 'application/xhtml+xml') {
    throw const SubscriptionException(
      SubscriptionErrorCode.htmlResponse,
      'The subscription server returned a web page instead of a subscription',
    );
  }
  if (mediaType.startsWith('image/') ||
      mediaType.startsWith('audio/') ||
      mediaType.startsWith('video/') ||
      mediaType == 'application/pdf' ||
      mediaType == 'application/zip') {
    throw SubscriptionException(
      SubscriptionErrorCode.unusableContent,
      'The subscription server returned unsupported content "$mediaType"',
    );
  }
  final head = content.length > 2048 ? content.substring(0, 2048) : content;
  if (_htmlPrefix.hasMatch(head)) {
    throw const SubscriptionException(
      SubscriptionErrorCode.htmlResponse,
      'The subscription server returned an HTML error page',
    );
  }
}

/// A short, safe description of an HTTP failure.
/// Port of `profile.ts:formatSubscriptionHttpStatusError`.
String describeSubscriptionHttpStatus(int status) {
  if (status == 401 || status == 403) {
    return 'The subscription server rejected the login or access token';
  }
  if (status == 404) return 'The subscription URL was not found (HTTP 404)';
  if (status == 407) return 'The proxy rejected the login';
  if (status == 408 || status == 504) {
    return 'The subscription server timed out';
  }
  if (status == 429) return 'Too many requests (rate limited)';
  if (status >= 500 && status <= 599) {
    return 'Subscription server error (HTTP $status)';
  }
  if (status >= 400 && status <= 499) {
    return 'The request was rejected (HTTP $status)';
  }
  return 'Unexpected HTTP status $status';
}

/// `attachment; filename=xxx.yaml` / `filename*=UTF-8''%e4%b8%ad`.
/// Port of `profile.ts:parseFilename`.
String parseContentDispositionFilename(String header) {
  final extended = RegExp(r"filename\*=[^']*''([^;]+)").firstMatch(header);
  if (extended != null) {
    try {
      return Uri.decodeComponent(extended.group(1)!.trim());
    } catch (_) {
      // Fall through to the plain form.
    }
  }
  final plain = RegExp(r'filename\s*=\s*"?([^";]+)"?').firstMatch(header);
  if (plain != null) {
    final value = plain.group(1)!.trim();
    if (value.isNotEmpty) return value;
  }
  return 'Remote File';
}

/// A stable hash of the complete request context.
///
/// Two updates with the same URL but different credentials, or the same
/// credentials but a different user agent, are different requests — so a cached
/// validator from one may never be replayed against the other. Secrets are
/// hashed with a domain-separating prefix and never stored in the clear.
/// Port of `profile.ts:subscriptionRequestIdentity`.
String subscriptionRequestIdentity({
  required String profileId,
  required String url,
  required String userAgent,
  String? authToken,
}) {
  String? hashSecret(String? value) => value == null || value.isEmpty
      ? null
      : sha256
            .convert(utf8.encode('aikobox-subscription-secret\u0000$value'))
            .toString();

  return sha256
      .convert(
        utf8.encode(
          jsonEncode(<String, dynamic>{
            'version': 1,
            'profileId': profileId,
            'url': url,
            'authorization': hashSecret(authToken),
            'userAgent': userAgent,
          }),
        ),
      )
      .toString();
}
