import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/members/person_card.dart';
import 'package:loaf_native/ui/members/person_menu.dart';
import 'package:loaf_native/ui/model/models.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';
import 'package:loaf_native/ui/verify/verifier.dart';

final _desktop = TargetPlatformVariant.only(TargetPlatform.macOS);
final _mobile = TargetPlatformVariant.only(TargetPlatform.iOS);

const _grey = Color(0xFF888888);
const _ada = Member('@ada:loaf.moe', 'Ada', _grey, statusMessage: 'baking');
const _admin = Member('@zed:loaf.moe', 'zed', _grey, powerLevel: 100);
const _lou = Member(
  '@_ooye_lou:loaf.moe',
  'lou',
  _grey,
  bridge: Bridge.discord,
);

/// A button that opens the menu, at the pointer on a computer.
Future<void> _pump(
  WidgetTester tester, {
  Member member = _ada,
  bool isYou = false,
  PersonTrust? trust,
  bool canVerify = false,
  VoidCallback? onMessage,
  VoidCallback? onVerify,
  VoidCallback? onEditProfile,
  ({String from, VoidCallback run})? kick,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: loafDarkTheme(),
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: GestureDetector(
              onTapUp: (d) => showPersonMenu(
                context,
                member: member,
                isYou: isYou,
                trust: trust,
                canVerify: canVerify,
                position: d.globalPosition,
                onMessage: onMessage,
                onVerify: onVerify,
                onEditProfile: onEditProfile,
                kick: kick,
              ),
              onLongPress: () => showPersonMenu(
                context,
                member: member,
                isYou: isYou,
                trust: trust,
                canVerify: canVerify,
                onMessage: onMessage,
                onVerify: onVerify,
                onEditProfile: onEditProfile,
                kick: kick,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
}

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('on a computer the card leads the menu', variant: _desktop, (
    tester,
  ) async {
    await _pump(tester, onMessage: () {});
    await _open(tester);
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.byType(PersonCard), findsOneWidget);
    expect(find.text('message'), findsOneWidget);
  });

  testWidgets('on a phone the card heads the sheet', variant: _mobile, (
    tester,
  ) async {
    await _pump(tester, onMessage: () {});
    await tester.longPress(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.byType(PersonCard), findsOneWidget);
    expect(find.text('message'), findsOneWidget);
  });

  group('the card', () {
    testWidgets('names them, with id and status', variant: _desktop, (
      tester,
    ) async {
      await _pump(tester);
      await _open(tester);
      expect(find.text('Ada'), findsOneWidget);
      expect(find.text('@ada:loaf.moe'), findsOneWidget);
      expect(find.text('baking'), findsOneWidget);
    });

    testWidgets('an admin wears a role chip', variant: _desktop, (
      tester,
    ) async {
      await _pump(tester, member: _admin);
      await _open(tester);
      expect(find.byKey(const ValueKey('role-admin')), findsOneWidget);
      expect(find.text('admin'), findsOneWidget);
    });

    testWidgets('a member wears none', variant: _desktop, (tester) async {
      await _pump(tester);
      await _open(tester);
      expect(find.byKey(const ValueKey('role-member')), findsNothing);
    });

    testWidgets('a puppet wears the badge', variant: _desktop, (tester) async {
      await _pump(tester, member: _lou);
      await _open(tester);
      expect(find.bySemanticsLabel('from Discord'), findsOneWidget);
    });

    testWidgets('the trust line shows for someone else', variant: _desktop, (
      tester,
    ) async {
      await _pump(tester, trust: PersonTrust.verified);
      await _open(tester);
      expect(find.byKey(const ValueKey('trust-verified')), findsOneWidget);
    });

    testWidgets('and never for you', variant: _desktop, (tester) async {
      await _pump(tester, isYou: true, trust: PersonTrust.verified);
      await _open(tester);
      expect(find.byKey(const ValueKey('trust-verified')), findsNothing);
    });

    testWidgets('nor where there is no verifier', variant: _desktop, (
      tester,
    ) async {
      await _pump(tester);
      await _open(tester);
      expect(find.byKey(const ValueKey('trust-unverified')), findsNothing);
    });
  });

  group('the items', () {
    testWidgets('copy user id is always there', variant: _desktop, (
      tester,
    ) async {
      await _pump(tester);
      await _open(tester);
      expect(find.text('copy user id'), findsOneWidget);
      expect(find.text('message'), findsNothing);
      expect(find.text('verify'), findsNothing);
      expect(find.text('edit profile'), findsNothing);
      expect(find.textContaining('kick'), findsNothing);
    });

    testWidgets('each other item needs its callback', variant: _desktop, (
      tester,
    ) async {
      await _pump(
        tester,
        trust: PersonTrust.unverified,
        canVerify: true,
        onMessage: () {},
        onVerify: () {},
        onEditProfile: () {},
        kick: (from: 'The Starter Pack', run: () {}),
      );
      await _open(tester);
      expect(find.text('message'), findsOneWidget);
      expect(find.text('verify'), findsOneWidget);
      expect(find.text('copy user id'), findsOneWidget);
      expect(find.text('edit profile'), findsOneWidget);
      expect(find.text('kick from The Starter Pack'), findsOneWidget);
    });

    for (final (label, trust, canVerify) in [
      ('already verified', PersonTrust.verified, true),
      ('nothing to verify', PersonTrust.noIdentity, true),
      ('this session cannot vouch', PersonTrust.unverified, false),
    ]) {
      testWidgets('verify is withheld when $label', variant: _desktop, (
        tester,
      ) async {
        await _pump(
          tester,
          trust: trust,
          canVerify: canVerify,
          onVerify: () {},
        );
        await _open(tester);
        expect(find.text('verify'), findsNothing);
      });
    }

    testWidgets(
      'an unverified session says why it cannot vouch',
      variant: _desktop,
      (tester) async {
        await _pump(tester, trust: PersonTrust.unverified, onVerify: () {});
        await _open(tester);
        expect(
          find.textContaining('verify this session first'),
          findsOneWidget,
        );
      },
    );

    testWidgets('copy user id copies it and says so', variant: _desktop, (
      tester,
    ) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await _pump(tester);
      await _open(tester);
      await tester.tap(find.text('copy user id'));
      await tester.pumpAndSettle();
      expect(copied, '@ada:loaf.moe');
      expect(find.text('copied'), findsOneWidget);
    });

    for (final label in [
      'message',
      'verify',
      'edit profile',
      'kick from here',
    ]) {
      testWidgets(
        '$label calls back once the menu is gone',
        variant: _desktop,
        (tester) async {
          var menuGone = false;
          var called = false;
          void cb() {
            called = true;
            // Popped, though its exit may still be animating.
            menuGone = find
                .byType(PersonCard)
                .evaluate()
                .every((e) => ModalRoute.of(e)?.isActive == false);
          }

          await _pump(
            tester,
            trust: PersonTrust.unverified,
            canVerify: true,
            onMessage: label == 'message' ? cb : null,
            onVerify: label == 'verify' ? cb : null,
            onEditProfile: label == 'edit profile' ? cb : null,
            kick: label == 'kick from here' ? (from: 'here', run: cb) : null,
          );
          await _open(tester);
          await tester.tap(find.text(label));
          await tester.pumpAndSettle();
          expect(called, isTrue);
          expect(menuGone, isTrue);
        },
      );
    }
  });
}
