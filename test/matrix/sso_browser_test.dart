import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/matrix/sso_browser.dart';

Uri _page(Uri redirect) =>
    Uri.parse('https://matrix.loaf.test/_matrix/client/v3/login/sso/redirect/x')
        .replace(queryParameters: {'redirectUrl': redirect.toString()});

/// What the homeserver does at the end of SSO: send the browser to the
/// redirect URL with a login token added.
Future<int> _comeBack(Uri page, {String? token = 'tok'}) async {
  final redirect = Uri.parse(page.queryParameters['redirectUrl']!);
  final back = redirect.replace(queryParameters: {'loginToken': ?token});
  final client = HttpClient();
  try {
    final response = await (await client.getUrl(back)).close();
    await response.drain<void>();
    return response.statusCode;
  } finally {
    client.close();
  }
}

/// Waits for the browser to have been opened [times].
Future<void> _opened(List<Uri> opened, [int times = 1]) async {
  while (opened.length < times) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  group('loopback', () {
    test('the token the browser brings back resolves the sign-in', () async {
      final opened = <Uri>[];
      final browser = LoopbackSsoBrowser(
        open: (url) async {
          opened.add(url);
          return true;
        },
      );
      final pending = browser.signIn(_page);
      await _opened(opened);
      final redirect = Uri.parse(opened.single.queryParameters['redirectUrl']!);
      expect(redirect.host, '127.0.0.1');
      expect(await _comeBack(opened.single), 200);
      expect(await pending, 'tok');
    });

    test('a visit with no token is turned away and keeps waiting', () async {
      final opened = <Uri>[];
      final browser = LoopbackSsoBrowser(
        open: (url) async {
          opened.add(url);
          return true;
        },
      );
      final pending = browser.signIn(_page);
      await _opened(opened);
      expect(await _comeBack(opened.single, token: null), 404);
      expect(await _comeBack(opened.single), 200);
      expect(await pending, 'tok');
    });

    test('reopen opens the same page; cancel resolves null', () async {
      final opened = <Uri>[];
      final browser = LoopbackSsoBrowser(
        open: (url) async {
          opened.add(url);
          return true;
        },
      );
      final pending = browser.signIn(_page);
      await _opened(opened);
      browser.reopen();
      expect(opened, hasLength(2));
      expect(opened.last, opened.first);
      browser.cancel();
      expect(await pending, isNull);
      // The listener is gone with it.
      await expectLater(
        _comeBack(opened.first),
        throwsA(isA<SocketException>()),
      );
    });

    test('cancelling while the listener binds opens nothing', () async {
      final opened = <Uri>[];
      final browser = LoopbackSsoBrowser(
        open: (url) async {
          opened.add(url);
          return true;
        },
      );
      final pending = browser.signIn(_page);
      browser.cancel();
      expect(await pending, isNull);
      expect(opened, isEmpty);
    });

    test('a browser that will not open ends the attempt', () async {
      final browser = LoopbackSsoBrowser(open: (_) async => false);
      expect(await browser.signIn(_page), isNull);
    });
  });

  group('sheet', () {
    test('reads the token off the callback', () async {
      String? scheme;
      final browser = SheetSsoBrowser(
        authenticate: (url, s) async {
          scheme = s;
          final redirect = Uri.parse(url).queryParameters['redirectUrl'];
          expect(redirect, 'moe.loaf.native://sso');
          return '$redirect?loginToken=tok';
        },
      );
      expect(await browser.signIn(_page), 'tok');
      expect(scheme, SheetSsoBrowser.scheme);
    });

    test('closing the sheet is a cancel', () async {
      final browser = SheetSsoBrowser(
        authenticate: (_, _) async => throw PlatformException(code: 'CANCELED'),
      );
      expect(await browser.signIn(_page), isNull);
    });

    test('an answer after cancel is dropped', () async {
      final browser = SheetSsoBrowser(
        authenticate: (url, _) async {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return 'moe.loaf.native://sso?loginToken=late';
        },
      );
      final pending = browser.signIn(_page);
      browser.cancel();
      expect(await pending, isNull);
    });
  });
}
