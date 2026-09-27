/// Where SSO happens, split by platform as the spec says: the system's
/// sign-in window where one exists (iOS, macOS), the real browser only
/// where none does (Linux, Windows).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_to_front/window_to_front.dart';

abstract interface class SsoBrowser {
  /// Opens `urlFor(redirect)` and resolves with the `loginToken` the server
  /// sends back to [redirect], or null if the person gave up.
  Future<String?> signIn(Uri Function(Uri redirect) urlFor);

  /// Opens the pending page again, where that means anything.
  void reopen();

  /// Gives up on a pending [signIn], which resolves null.
  void cancel();
}

/// iOS and macOS use `ASWebAuthenticationSession`; Android a Custom Tab.
/// The sheet is modal, so reopening means nothing and cancelling only
/// drops whatever it later returns.
class SheetSsoBrowser implements SsoBrowser {
  SheetSsoBrowser({
    Future<String> Function(String url, String scheme)? authenticate,
  }) : _authenticate = authenticate ?? _system;

  static Future<String> _system(String url, String scheme) =>
      FlutterWebAuth2.authenticate(url: url, callbackUrlScheme: scheme);

  /// The bundle id, which no other app can claim on iOS.
  static const scheme = 'moe.loaf.native';

  final Future<String> Function(String url, String scheme) _authenticate;
  var _attempt = 0;

  @override
  Future<String?> signIn(Uri Function(Uri redirect) urlFor) async {
    final mine = ++_attempt;
    try {
      final back = await _authenticate(
        urlFor(Uri.parse('$scheme://sso')).toString(),
        scheme,
      );
      if (mine != _attempt) return null;
      return Uri.parse(back).queryParameters['loginToken'];
    } on PlatformException catch (e) {
      // Only a closed sheet is a cancel; anything else is a failure the
      // homeserver turns into an answer.
      if (e.code == 'CANCELED') return null;
      rethrow;
    }
  }

  @override
  void reopen() {}

  @override
  void cancel() => _attempt++;
}

/// Linux and Windows, which have no system sign-in window: the real
/// browser, returning to a one-shot listener on 127.0.0.1. A loopback
/// redirect needs no URL scheme registered with the OS, which Linux has no
/// single way to do.
class LoopbackSsoBrowser implements SsoBrowser {
  LoopbackSsoBrowser({
    Future<bool> Function(Uri url)? open,
    Future<void> Function()? onReturned,
  }) : _open = open ?? _launch,
       _onReturned = onReturned ?? _bringToFront;

  static Future<bool> _launch(Uri url) =>
      launchUrl(url, mode: LaunchMode.externalApplication);

  /// Brings the app back to the front once the browser hands a valid token
  /// back. A platform with no `window_to_front` implementation, or one
  /// that otherwise fails, just leaves the browser in front.
  static Future<void> _bringToFront() async {
    try {
      await WindowToFront.activate();
    } on Exception {
      // MissingPluginException implements Exception, so it is caught here
      // too: nothing registers the plugin on a platform that never asks.
    }
  }

  /// Whether the browser opened. A launcher that throws did not.
  Future<bool> _tryOpen(Uri page) async {
    try {
      return await _open(page);
    } on Exception {
      return false;
    }
  }

  final Future<bool> Function(Uri url) _open;
  final Future<void> Function() _onReturned;
  HttpServer? _server;
  Uri? _page;
  Completer<String?>? _done;

  @override
  Future<String?> signIn(Uri Function(Uri redirect) urlFor) async {
    cancel();
    final done = _done = Completer<String?>();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    // Cancelled while binding: this attempt is already over.
    if (!identical(_done, done)) {
      await server.close(force: true);
      return done.future;
    }
    _server = server;
    // Any local program can reach the port; only the page the server sent
    // the browser back to knows this path, so only it can sign loaf in.
    final path = '/sso/${_nonce()}';
    final page = _page = urlFor(
      Uri(scheme: 'http', host: '127.0.0.1', port: server.port, path: path),
    );
    server.listen((request) async {
      final token = request.uri.path == path
          ? request.uri.queryParameters['loginToken']
          : null;
      request.response.statusCode = token == null
          ? HttpStatus.notFound
          : HttpStatus.ok;
      if (token != null) {
        request.response
          ..headers.contentType = ContentType.html
          ..write(_donePage);
      }
      try {
        await request.response.close();
      } on Exception {
        // The browser hung up first; the token it brought still counts.
      }
      if (token != null && identical(_done, done)) {
        unawaited(_onReturned());
        _finish(token);
      }
    });
    if (!await _tryOpen(page) && identical(_done, done)) _finish(null);
    return done.future;
  }

  @override
  void reopen() {
    final page = _page;
    if (_done != null && page != null) unawaited(_tryOpen(page));
  }

  @override
  void cancel() => _finish(null);

  void _finish(String? token) {
    final done = _done;
    _done = null;
    _page = null;
    _server?.close(force: true);
    _server = null;
    done?.complete(token);
  }

  static final _random = Random.secure();

  /// 128 random bits, URL-safe.
  static String _nonce() => base64Url
      .encode(List<int>.generate(16, (_) => _random.nextInt(256)))
      .replaceAll('=', '');

  static const _donePage =
      '<!doctype html><meta charset="utf-8"><title>loaf</title>'
      '<body style="font-family:sans-serif;padding:3em">'
      "<p>you're signed in. you can close this tab and go back to loaf.</p>";
}
