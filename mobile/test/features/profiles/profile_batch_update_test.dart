import 'package:aikobox_mobile/core/models.dart';
import 'package:aikobox_mobile/features/profiles/data/profile_batch_update.dart';
import 'package:flutter_test/flutter_test.dart';

ProfileItem _remote(String id, {String name = ''}) => ProfileItem(
  id: id,
  type: 'remote',
  name: name.isEmpty ? id : name,
  url: 'https://example.com/$id',
);

ProfileItem _local(String id) =>
    ProfileItem(id: id, type: 'local', name: id);

void main() {
  group('isBatchUpdatable', () {
    test('only a remote profile with a URL qualifies', () {
      expect(isBatchUpdatable(_remote('a')), isTrue);
      expect(isBatchUpdatable(_local('b')), isFalse);
      expect(
        isBatchUpdatable(const ProfileItem(id: 'c', type: 'remote', name: 'c')),
        isFalse,
      );
      expect(
        isBatchUpdatable(
          const ProfileItem(id: 'd', type: 'remote', name: 'd', url: '   '),
        ),
        isFalse,
      );
    });
  });

  group('runProfileBatchUpdate', () {
    test('skips local profiles', () async {
      final visited = <String>[];
      final result = await runProfileBatchUpdate(
        <ProfileItem>[_remote('a'), _local('b'), _remote('c')],
        null,
        (item) async => visited.add(item.id),
      );
      expect(visited, <String>['a', 'c']);
      expect(result.total, 2);
      expect(result.succeeded, 2);
    });

    test('refreshes the active profile last', () async {
      final visited = <String>[];
      await runProfileBatchUpdate(
        <ProfileItem>[_remote('a'), _remote('b'), _remote('c')],
        'a',
        (item) async => visited.add(item.id),
      );
      // 'a' would restart the running core, which would abort the rest.
      expect(visited, <String>['b', 'c', 'a']);
    });

    test('runs strictly one at a time', () async {
      var inFlight = 0;
      var maxInFlight = 0;
      await runProfileBatchUpdate(
        <ProfileItem>[_remote('a'), _remote('b'), _remote('c')],
        null,
        (item) async {
          inFlight++;
          if (inFlight > maxInFlight) maxInFlight = inFlight;
          await Future<void>.delayed(Duration.zero);
          inFlight--;
        },
      );
      expect(maxInFlight, 1);
    });

    test('one failure does not stop the others', () async {
      final visited = <String>[];
      final result = await runProfileBatchUpdate(
        <ProfileItem>[_remote('a'), _remote('b'), _remote('c')],
        null,
        (item) async {
          visited.add(item.id);
          if (item.id == 'b') throw Exception('HTTP 500 server error');
        },
      );
      expect(visited, <String>['a', 'b', 'c']);
      expect(result.total, 3);
      expect(result.succeeded, 2);
      expect(result.failed, 1);
      expect(result.failures.single.id, 'b');
      expect(result.isPartial, isTrue);
    });

    test('reports progress before each profile', () async {
      final progress = <String>[];
      await runProfileBatchUpdate(
        <ProfileItem>[_remote('a'), _remote('b')],
        null,
        (item) async {},
        onProgress: (item, index, total) =>
            progress.add('${item.id}:$index/$total'),
      );
      expect(progress, <String>['a:0/2', 'b:1/2']);
    });

    test('an empty run reports nothing to do', () async {
      final result = await runProfileBatchUpdate(
        <ProfileItem>[_local('a')],
        null,
        (item) async {},
      );
      expect(result.isEmpty, isTrue);
      expect(result.allSucceeded, isFalse);
      expect(result.allFailed, isFalse);
    });

    test('a failure with no name falls back to the id', () async {
      final result = await runProfileBatchUpdate(
        <ProfileItem>[
          const ProfileItem(
            id: 'abc',
            type: 'remote',
            name: '  ',
            url: 'https://example.com/x',
          ),
        ],
        null,
        (item) async => throw Exception('boom'),
      );
      expect(result.failures.single.name, 'abc');
    });
  });

  group('classifyProfileFailure', () {
    test('authentication', () {
      expect(
        classifyProfileFailure(Exception('HTTP 401 Unauthorized')),
        ProfileBatchFailureKind.authentication,
      );
      expect(
        classifyProfileFailure(Exception('server returned 403')),
        ProfileBatchFailureKind.authentication,
      );
      expect(
        classifyProfileFailure(
          Exception(
            'SubscriptionException(redirectCrossOriginWithCredentials): x',
          ),
        ),
        ProfileBatchFailureKind.authentication,
      );
    });

    test('not found', () {
      expect(
        classifyProfileFailure(Exception('The URL was not found (HTTP 404)')),
        ProfileBatchFailureKind.notFound,
      );
    });

    test('network', () {
      expect(
        classifyProfileFailure(Exception('The server timed out')),
        ProfileBatchFailureKind.network,
      );
      expect(
        classifyProfileFailure(Exception('SocketException: refused')),
        ProfileBatchFailureKind.network,
      );
      expect(
        classifyProfileFailure(
          Exception('SubscriptionException(tooManyRedirects): x'),
        ),
        ProfileBatchFailureKind.network,
      );
    });

    test('invalid content', () {
      expect(
        classifyProfileFailure(Exception('YAML parse failure at line 3')),
        ProfileBatchFailureKind.invalidContent,
      );
      expect(
        classifyProfileFailure(
          Exception('SubscriptionException(htmlResponse): a login page'),
        ),
        ProfileBatchFailureKind.invalidContent,
      );
    });

    test('backoff', () {
      expect(
        classifyProfileFailure(Exception('update backoff in effect')),
        ProfileBatchFailureKind.backoff,
      );
    });

    test('anything else is unknown', () {
      expect(
        classifyProfileFailure(Exception('something odd happened')),
        ProfileBatchFailureKind.unknown,
      );
    });

    test('authentication wins over network when both words appear', () {
      // A 401 that also mentions a timeout is still an auth problem: retrying
      // it without a token will fail the same way.
      expect(
        classifyProfileFailure(Exception('401 unauthorized after timeout')),
        ProfileBatchFailureKind.authentication,
      );
    });
  });
}
