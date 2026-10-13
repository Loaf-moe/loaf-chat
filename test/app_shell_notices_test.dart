/// What comes after a desktop notification is up, from the sync down: a
/// click brings its message on screen, and a room read here, read on
/// another device, or left takes its notifications down.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:loaf_native/notify/pick_notifications.dart';
import 'package:loaf_native/ui/channel/channel_view.dart';
import 'package:loaf_native/ui/channel/timeline.dart' show messageUnavailable;
import 'package:matrix/matrix.dart';

import 'shell_harness.dart';

/// The fake server, plus what the jump and the read marker need of it: a
/// message's context (each event [sent] through it, alone, nothing
/// further back), and a read marker answered and echoed as the receipt
/// the next sync brings, as a homeserver does.
class _Api extends FakeMatrixApi {
  final sent = <String, Map<String, Object?>>{};

  /// The client to echo receipts to; the test sets it once the shell is up.
  Client? client;

  static http.Response _json(Object body, [int status = 200]) =>
      http.Response(jsonEncode(body), status);

  @override
  FutureOr<http.Response> mockIntercept(http.Request request) async {
    final path = Uri.decodeComponent(request.url.path);
    final roomId = [kitchen, pantry].where((r) => path.contains('/rooms/$r/'));
    if (roomId.isEmpty) return super.mockIntercept(request);
    if (request.method == 'GET' && path.contains('/context/')) {
      final event = sent[path.split('/context/').last];
      if (event == null) {
        return _json({'errcode': 'M_NOT_FOUND', 'error': 'gone'}, 404);
      }
      return _json({
        'event': event,
        'events_before': <Object>[],
        'events_after': <Object>[],
        'state': <Object>[],
        'start': 'before',
        'end': 'after',
      });
    }
    if (request.method == 'GET' && path.endsWith('/messages')) {
      return _json({'start': 'top', 'chunk': <Object>[]});
    }
    if (request.method == 'POST' && path.endsWith('/read_markers')) {
      final read =
          (jsonDecode(request.body) as Map<String, Object?>)['m.read']
              as String;
      await deliver(
        client!,
        roomId.single,
        [],
        ephemeral: [receipt(read, ts: after + 1)],
      );
      return _json(<String, Object?>{});
    }
    return super.mockIntercept(request);
  }
}

/// Ada's message [id] in [roomId], which [api] will also serve as the
/// jump's context; waits for the notice it raises.
Future<void> _send(
  WidgetTester tester,
  Shell shell,
  _Api api,
  String roomId,
  String id,
) async {
  api.client = shell.client;
  final event = msg(id);
  api.sent[id] = {...event, 'room_id': roomId};
  final before = shell.desktop.shown.length;
  await arrive(tester, shell, roomId, [
    event,
  ], done: () => shell.desktop.shown.length > before);
  expect(shell.desktop.shown.length, before + 1);
}

Finder _header(String name) =>
    find.descendant(of: find.byType(ChannelView), matching: find.text(name));

void main() {
  group('a click', () {
    testWidgets('opens the channel at the message', (tester) async {
      final api = _Api();
      await run(
        tester,
        focused: false,
        api: api,
        routes: (desktop) => fronted(desktop.clicks),
        body: (shell) async {
          await openChannel(tester, kitchen);
          await _send(tester, shell, api, pantry, r'$m');

          focus(tester, focused: true);
          shell.desktop.click(shell.desktop.shown.single.route);
          await settle(tester);

          expect(_header('pantry'), findsOneWidget);
          expect(find.byKey(const ValueKey('jump-glow')), findsOneWidget);
          // The glow fades on its own; let it, so no timer outlives the tree.
          await tester.pump(const Duration(seconds: 2));
        },
      );
    });

    testWidgets('on a room you have since left says so, and stays put', (
      tester,
    ) async {
      final api = _Api();
      await run(
        tester,
        focused: false,
        api: api,
        routes: (desktop) => fronted(desktop.clicks),
        body: (shell) async {
          await openChannel(tester, kitchen);
          await _send(tester, shell, api, pantry, r'$m');
          final route = shell.desktop.shown.single.route;
          await react(
            tester,
            () => leaveRoom(shell.client, pantry),
            done: () => shell.desktop.withdrawn.contains(pantry),
          );

          focus(tester, focused: true);
          shell.desktop.click(route);
          await settle(tester);

          expect(find.text(messageUnavailable), findsOneWidget);
          expect(_header('kitchen'), findsOneWidget);
        },
      );
    });
  });

  group('a withdrawal', () {
    testWidgets('reading the channel here', (tester) async {
      final api = _Api();
      await run(
        tester,
        focused: false,
        api: api,
        body: (shell) async {
          await openChannel(tester, kitchen);
          await _send(tester, shell, api, pantry, r'$m');

          focus(tester, focused: true);
          await openChannel(tester, pantry);
          await settle(tester);
          expect(shell.desktop.withdrawn, [pantry]);
        },
      );
    });

    testWidgets('a receipt from another device', (tester) async {
      final api = _Api();
      await run(
        tester,
        focused: false,
        api: api,
        body: (shell) async {
          await openChannel(tester, kitchen);
          await _send(tester, shell, api, pantry, r'$m');

          await react(
            tester,
            () => deliver(
              shell.client,
              pantry,
              [],
              ephemeral: [receipt(r'$m', ts: after + 1)],
            ),
            done: () => shell.desktop.withdrawn.isNotEmpty,
          );
          expect(shell.desktop.withdrawn, [pantry]);
        },
      );
    });

    testWidgets('leaving the room', (tester) async {
      final api = _Api();
      await run(
        tester,
        focused: false,
        api: api,
        body: (shell) async {
          await openChannel(tester, kitchen);
          await _send(tester, shell, api, pantry, r'$m');

          await react(
            tester,
            () => leaveRoom(shell.client, pantry),
            done: () => shell.desktop.withdrawn.isNotEmpty,
          );
          expect(shell.desktop.withdrawn, [pantry]);
        },
      );
    });

    testWidgets('a receipt short of the newest message keeps the notice', (
      tester,
    ) async {
      final api = _Api();
      await run(
        tester,
        focused: false,
        api: api,
        body: (shell) async {
          await openChannel(tester, kitchen);
          await _send(tester, shell, api, pantry, r'$a');
          await _send(tester, shell, api, pantry, r'$b');

          await react(
            tester,
            () => deliver(
              shell.client,
              pantry,
              [],
              ephemeral: [receipt(r'$a', ts: after + 1)],
            ),
            done: () => true,
          );
          expect(shell.desktop.withdrawn, isEmpty);
        },
      );
    });

    testWidgets('one room read leaves the other room\'s notice up', (
      tester,
    ) async {
      final api = _Api();
      await run(
        tester,
        focused: false,
        api: api,
        body: (shell) async {
          await openChannel(tester, kitchen);
          await _send(tester, shell, api, kitchen, r'$k');
          await _send(tester, shell, api, pantry, r'$p');

          await react(
            tester,
            () => deliver(
              shell.client,
              pantry,
              [],
              ephemeral: [receipt(r'$p', ts: after + 1)],
            ),
            done: () => shell.desktop.withdrawn.isNotEmpty,
          );
          expect(shell.desktop.withdrawn, [pantry]);
        },
      );
    });
  });
}
