import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';

import 'package:aikobox_android/profiles/profile.dart';
import 'package:aikobox_android/profiles/profile_import_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  DateTime clock() => DateTime.utc(2026, 7, 27);
  Future<List<InternetAddress>> publicResolver(String host) async => [
    InternetAddress('93.184.216.34'),
  ];

  test('imports and normalizes pasted JSON', () async {
    final store = _MemoryFileStore();
    final service = ProfileImportService(clock: clock, fileStore: store);
    final profile = await service.fromPasted('{"outbounds":[]}');

    expect(profile.source, ProfileSource.pasted);
    expect(profile.name, '粘贴的配置');
    expect(jsonDecode(profile.json), {'outbounds': <Object>[]});
    expect(profile.path, '/private/${profile.id}.json');
  });

  test('rejects invalid JSON and non-object roots', () async {
    final service = ProfileImportService(clock: clock);

    await expectLater(
      service.fromPasted('not-json'),
      throwsA(isA<ProfileImportException>()),
    );
    await expectLater(
      service.fromPasted('[]'),
      throwsA(isA<ProfileImportException>()),
    );
  });

  test('enforces the 4 MiB boundary before decoding', () async {
    final service = ProfileImportService(clock: clock);
    final oversized = Uint8List(maxProfileBytes + 1);

    await expectLater(
      service.fromBytes(bytes: oversized, suggestedName: 'large.json'),
      throwsA(
        isA<ProfileImportException>().having(
          (error) => error.message,
          'message',
          contains('4 MiB'),
        ),
      ),
    );
  });

  test('accepts HTTPS and records only the source host', () async {
    final client = MockClient((request) async {
      expect(request.url.host, 'example.com');
      expect(request.followRedirects, isFalse);
      return http.Response('{"route":{"rules":[]}}', 200);
    });
    final service = ProfileImportService(
      client: client,
      clock: clock,
      hostResolver: publicResolver,
    );

    final profile = await service.fromHttpsUrl(
      'https://example.com/private/config.json?token=secret',
    );

    expect(profile.sourceHost, 'example.com');
    expect(profile.name, 'example.com');
    expect(profile.json, isNot(contains('secret')));
  });

  test('rejects HTTP and URLs containing user info', () async {
    final service = ProfileImportService(clock: clock);

    await expectLater(
      service.fromHttpsUrl('http://example.com/config.json'),
      throwsA(isA<ProfileImportException>()),
    );
    await expectLater(
      service.fromHttpsUrl('https://user:pass@example.com/config.json'),
      throwsA(isA<ProfileImportException>()),
    );
  });

  test('rejects oversized streamed responses', () async {
    final client = MockClient.streaming((request, bodyStream) async {
      return http.StreamedResponse(
        Stream.value(List<int>.filled(maxProfileBytes + 1, 0x20)),
        200,
      );
    });
    final service = ProfileImportService(
      client: client,
      clock: clock,
      hostResolver: publicResolver,
    );

    await expectLater(
      service.fromHttpsUrl('https://example.com/config.json'),
      throwsA(isA<ProfileImportException>()),
    );
  });

  test('rejects redirects that downgrade to HTTP', () async {
    final client = MockClient((request) async {
      return http.Response(
        '',
        302,
        headers: {'location': 'http://example.com/insecure.json'},
      );
    });
    final service = ProfileImportService(
      client: client,
      clock: clock,
      hostResolver: publicResolver,
    );

    await expectLater(
      service.fromHttpsUrl('https://example.com/config.json'),
      throwsA(
        isA<ProfileImportException>().having(
          (error) => error.message,
          'message',
          contains('不安全'),
        ),
      ),
    );
  });

  test('reports a safe timeout without exposing the source URL', () async {
    final client = MockClient((request) async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      return http.Response('{}', 200);
    });
    final service = ProfileImportService(
      client: client,
      clock: clock,
      timeout: const Duration(milliseconds: 5),
      hostResolver: publicResolver,
    );

    await expectLater(
      service.fromHttpsUrl('https://example.com/config.json?token=top-secret'),
      throwsA(
        isA<ProfileImportException>()
            .having((error) => error.message, 'message', contains('超时'))
            .having(
              (error) => error.message,
              'message',
              isNot(contains('top-secret')),
            ),
      ),
    );
  });

  test('rejects local, private, link-local, and reserved literals', () async {
    final service = ProfileImportService(clock: clock);
    for (final host in [
      'localhost',
      '127.0.0.1',
      '10.0.0.1',
      '169.254.1.1',
      '172.16.0.1',
      '192.168.1.1',
      '192.0.2.1',
      '198.51.100.1',
      '203.0.113.1',
      '::1',
      'fe80::1',
      'fc00::1',
      '2001:db8::1',
      '2001::1',
      '2001:20::1',
      '3fff::1',
    ]) {
      await expectLater(
        service.fromHttpsUrl('https://[$host]/config.json'),
        throwsA(isA<ProfileImportException>()),
        reason: host,
      );
    }
  });

  test('rejects domains resolving to a private address', () async {
    final service = ProfileImportService(
      clock: clock,
      hostResolver: (_) async => [InternetAddress('192.168.1.8')],
    );

    await expectLater(
      service.fromHttpsUrl('https://internal.example/config.json'),
      throwsA(
        isA<ProfileImportException>().having(
          (error) => error.message,
          'message',
          contains('私有网络'),
        ),
      ),
    );
  });

  test('rechecks every redirect and records the final host', () async {
    final resolved = <String>[];
    final client = MockClient((request) async {
      if (request.url.host == 'start.example') {
        return http.Response(
          '',
          302,
          headers: {'location': 'https://final.example/profile.json'},
        );
      }
      return http.Response('{"outbounds":[]}', 200);
    });
    final service = ProfileImportService(
      client: client,
      clock: clock,
      hostResolver: (host) async {
        resolved.add(host);
        return [InternetAddress('93.184.216.34')];
      },
    );

    final profile = await service.fromHttpsUrl(
      'https://start.example/config.json',
    );

    expect(resolved, ['start.example', 'final.example']);
    expect(profile.sourceHost, 'final.example');
  });

  test('applies a total deadline across redirect hops', () async {
    var hop = 0;
    final client = MockClient((request) async {
      await Future<void>.delayed(const Duration(milliseconds: 8));
      hop += 1;
      return http.Response(
        '',
        302,
        headers: {'location': 'https://hop$hop.example/config.json'},
      );
    });
    final service = ProfileImportService(
      client: client,
      clock: clock,
      timeout: const Duration(seconds: 1),
      totalTimeout: const Duration(milliseconds: 15),
      hostResolver: publicResolver,
    );

    await expectLater(
      service.fromHttpsUrl('https://start.example/config.json'),
      throwsA(
        isA<ProfileImportException>().having(
          (error) => error.message,
          'message',
          contains('超时'),
        ),
      ),
    );
  });

  test('enforces actual streamed bytes even if metadata is smaller', () async {
    final service = ProfileImportService(clock: clock);

    await expectLater(
      service.fromStream(
        stream: Stream.value(List<int>.filled(maxProfileBytes + 1, 0x20)),
        suggestedName: 'misreported.json',
      ),
      throwsA(isA<ProfileImportException>()),
    );
  });
}

class _MemoryFileStore implements ProfileFileStore {
  final deleted = <String>[];
  @override
  Future<Profile> persist(Profile profile) async {
    return profile.copyWith(path: '/private/${profile.id}.json');
  }

  @override
  Future<void> delete(Profile profile) async {
    deleted.add(profile.id);
  }
}
