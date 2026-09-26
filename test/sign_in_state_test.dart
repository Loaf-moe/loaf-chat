import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/auth/sign_in_state.dart';
import 'package:loaf_native/ui/mock/accounts.dart';

void main() {
  group('serverNameFrom', () {
    test('takes a bare name, trimmed and lowercased', () {
      expect(serverNameFrom('loaf.moe'), 'loaf.moe');
      expect(serverNameFrom('  Loaf.MOE '), 'loaf.moe');
    });

    test('takes the host of a url, keeping a port', () {
      expect(
        serverNameFrom('https://matrix.loaf.moe/_matrix/'),
        'matrix.loaf.moe',
      );
      expect(serverNameFrom('HTTP://localhost:8008'), 'localhost:8008');
      expect(serverNameFrom('loaf.moe:8448'), 'loaf.moe:8448');
    });

    test('takes the domain of a full user id', () {
      expect(serverNameFrom('@chris:loaf.moe'), 'loaf.moe');
    });

    test('is null until there is a name in it', () {
      for (final input in [
        '',
        '  ',
        'loaf',
        'loaf.',
        '.moe',
        '@chris',
        '@chris:',
        '@:loaf.moe',
        'https://',
        'https:',
        'loaf moe.x',
      ]) {
        expect(serverNameFrom(input), isNull, reason: '"$input"');
      }
    });

    test('survives every prefix of what people type', () {
      // Half-typed input is the normal case: the matrix.to crash only showed
      // up typing character by character.
      const typed = {
        '@chris:loaf.moe': 'loaf.moe',
        'https://matrix.loaf.moe/path': 'matrix.loaf.moe',
        'loaf.moe:8448': 'loaf.moe:8448',
      };
      for (final MapEntry(key: full, value: want) in typed.entries) {
        for (var i = 0; i < full.length; i++) {
          serverNameFrom(full.substring(0, i));
        }
        expect(serverNameFrom(full), want);
      }
    });
  });

  group('serverFromUserId', () {
    test('only answers for a full id', () {
      expect(serverFromUserId('chris'), isNull);
      expect(serverFromUserId('@chris'), isNull);
      expect(serverFromUserId('@chris:'), isNull);
      expect(serverFromUserId('@chris:loaf.moe'), 'loaf.moe');
      expect(serverFromUserId('@chris:loaf.moe:8448'), 'loaf.moe:8448');
    });
  });

  test('each discovery failure says something different', () {
    expect(
      const ServerFailed(ServerProblem.unreachable).messageFor('x.test'),
      'nothing answered at x.test',
    );
    expect(
      const ServerFailed(ServerProblem.notMatrix).messageFor('x.test'),
      "x.test isn't a matrix server",
    );
    expect(
      const ServerFailed(
        ServerProblem.delegationBroken,
        delegatedTo: 'matrix.x.test',
      ).messageFor('x.test'),
      "x.test points to matrix.x.test, which didn't answer",
    );
  });

  test('the fixture servers cover every face', () {
    final loaf = mockServers['loaf.moe']! as ServerFound;
    expect(loaf.flows.providers, [loafMoeProvider]);
    expect(loaf.flows.password, isTrue);
    expect(
      (mockServers['many-doors.test']! as ServerFound).flows.providers.length,
      greaterThan(1),
    );
    expect(
      (mockServers['sso-only.test']! as ServerFound).flows.password,
      isFalse,
    );
    expect((mockServers['passwords.test']! as ServerFound).flows.sso, isFalse);
    expect(mockServers['example.com'], isA<ServerFailed>());
    expect(mockServers['broken.test'], isA<ServerFailed>());
  });

  test('a provider without an icon falls back to its initial', () {
    expect(const IdentityProvider('x', 'authentik').initial, 'A');
  });
}
