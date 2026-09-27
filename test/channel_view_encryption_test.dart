import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/auth/loaf_session.dart';
import 'package:loaf_native/ui/channel/channel_view.dart';
import 'package:loaf_native/ui/channel/composer.dart';
import 'package:loaf_native/ui/channel/timeline.dart';
import 'package:loaf_native/ui/model/models.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';

const _them = Member('@them', 'them', Colors.blue);

/// Only what an encrypted room's conversation reads: whether it can be
/// written in, and its messages.
class _Timeline extends ChangeNotifier with ComposerAiming implements Timeline {
  _Timeline(this.messages);

  @override
  final Member you = const Member('@you', 'you', Colors.red);
  @override
  List<Message> messages;
  @override
  bool writable = false;
  @override
  bool get canLoadOlder => false;
  @override
  bool get loadingOlder => false;
  @override
  bool get loadOlderFailed => false;
  @override
  Stream<String> get failures => const Stream.empty();
  @override
  void loadOlder() {}
  @override
  void send(String text) {}
  @override
  void toggleReaction(String messageId, String emoji) {}
  @override
  void saveEdit(String messageId, String text) {}
  @override
  void delete(String messageId) {}
  @override
  void retry(String messageId) {}
  @override
  void discard(String messageId) {}

  void verified() {
    writable = true;
    notifyListeners();
  }
}

final _locked = Message(
  id: r'$sealed',
  author: _them,
  sentAt: DateTime(2026, 9, 27, 10),
  body: '',
  locked: true,
);

Future<_Timeline> _pump(
  WidgetTester tester, {
  DeviceTrust trust = DeviceTrust.unverified,
  VoidCallback? onVerify,
}) async {
  tester.view.physicalSize = const Size(800, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final timeline = _Timeline([_locked]);
  addTearDown(timeline.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: loafDarkTheme(),
      home: Scaffold(
        body: ChannelView(
          channel: const Channel(
            id: '!secret',
            name: 'secrets',
            kind: ChannelKind.room,
          ),
          timeline: timeline,
          trust: trust,
          onVerify: onVerify,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return timeline;
}

void main() {
  testWidgets('an unverified device is shown the way to send here', (
    tester,
  ) async {
    var asked = 0;
    await _pump(tester, onVerify: () => asked++);
    expect(find.byType(Composer), findsNothing);
    expect(find.text('verify this device to send here'), findsOneWidget);
    await tester.tap(find.text('verify'));
    expect(asked, 1);
  });

  testWidgets('an account with no identity is shown setting up', (
    tester,
  ) async {
    var asked = 0;
    await _pump(tester, trust: DeviceTrust.noIdentity, onVerify: () => asked++);
    expect(find.text('set up recovery to send here'), findsOneWidget);
    await tester.tap(find.text('set up'));
    expect(asked, 1);
  });

  testWidgets('verified, the composer comes, and a locked message says '
      'its key never came', (tester) async {
    final timeline = await _pump(tester);
    expect(
      find.text('encrypted · readable once this device is verified'),
      findsOneWidget,
    );
    timeline.verified();
    await tester.pumpAndSettle();
    expect(find.byType(Composer), findsOneWidget);
    expect(find.text('verify this device to send here'), findsNothing);
    expect(
      find.text('encrypted · the key for this never reached this device'),
      findsOneWidget,
    );
  });
}
