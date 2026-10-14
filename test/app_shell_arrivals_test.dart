/// The shell's reaction to a message arriving, from the sync down: a real
/// client over the fake server, real rooms, the real shell, and fakes only
/// where the chime plays and the desktop shows a notification. Every
/// device setting and state the decision reads, where it changes the
/// outcome: which channel is open, whether the app is in front, which
/// platform, and the three toggles.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/model/message_route.dart';

import 'shell_harness.dart';

void main() {
  group('an arrival', () {
    // The decision table's four cells, each with the settings that change
    // its outcome; the table itself, every cell, is pinned in
    // notifier_test. What a case expects: chimes, notices, and for a
    // notice its sound and body.
    for (final (
          name,
          focused,
          open,
          phone,
          sound,
          notifications,
          showText,
          chimes,
          notices,
        )
        in <(String, bool, bool, bool, bool, bool, bool, int, int)>[
          (
            'in front, the open channel: nothing',
            true,
            true,
            false,
            true,
            true,
            true,
            0,
            0,
          ),
          (
            'in front, the open channel, on a phone: nothing',
            true,
            true,
            true,
            true,
            true,
            true,
            0,
            0,
          ),
          (
            'in front, another channel: the chime',
            true,
            false,
            false,
            true,
            true,
            true,
            1,
            0,
          ),
          (
            'in front, another channel, on a phone: the chime',
            true,
            false,
            true,
            true,
            true,
            true,
            1,
            0,
          ),
          (
            'in front, another channel, sound off: nothing',
            true,
            false,
            false,
            false,
            true,
            true,
            0,
            0,
          ),
          (
            'in the background on a desktop: a notice',
            false,
            false,
            false,
            true,
            true,
            true,
            0,
            1,
          ),
          (
            'in the background on a desktop, the open channel: a notice too',
            false,
            true,
            false,
            true,
            true,
            true,
            0,
            1,
          ),
          (
            'in the background on a desktop, sound off: a silent notice',
            false,
            false,
            false,
            false,
            true,
            true,
            0,
            1,
          ),
          (
            'in the background on a desktop, text off: a notice saying only that',
            false,
            false,
            false,
            true,
            true,
            false,
            0,
            1,
          ),
          (
            'in the background on a desktop, notifications off: nothing',
            false,
            false,
            false,
            true,
            false,
            true,
            0,
            0,
          ),
          (
            'in the background on a phone: nothing',
            false,
            false,
            true,
            true,
            true,
            true,
            0,
            0,
          ),
          (
            'in the background on a phone, the open channel: nothing',
            false,
            true,
            true,
            true,
            true,
            true,
            0,
            0,
          ),
        ]) {
      final roomId = open ? kitchen : pantry;
      testWidgets(
        name,
        (tester) => run(
          tester,
          phone: phone,
          focused: focused,
          sound: sound,
          notifications: notifications,
          showText: showText,
          body: (shell) async {
            await openChannel(tester, kitchen, phone: phone);
            await arrive(
              tester,
              shell,
              roomId,
              [msg(r'$m')],
              done: () =>
                  shell.chime.plays >= chimes &&
                  shell.desktop.shown.length >= notices,
            );
            expect(shell.chime.plays, chimes);
            expect(shell.desktop.shown.length, notices);
            if (notices == 1) {
              final notice = shell.desktop.shown.single;
              expect(notice.sound, sound);
              expect(notice.body, showText ? 'hi' : 'new message');
              expect(
                notice.title,
                'Ada in #${open ? 'kitchen' : 'pantry'} · Bakery',
              );
              expect(notice.route, MessageRoute(roomId, r'$m'));
            }
          },
        ),
      );
    }
  });

  group('a burst', () {
    testWidgets(
      'in front, two messages in one sync chime once',
      (tester) => run(
        tester,
        body: (shell) async {
          await openChannel(tester, kitchen);
          await arrive(tester, shell, pantry, [
            msg(r'$a'),
            msg(r'$b'),
          ], done: () => shell.chime.plays >= 1);
          expect(shell.chime.plays, 1);
        },
      ),
    );

    testWidgets(
      'in the background, the second notice is silent',
      (tester) => run(
        tester,
        focused: false,
        body: (shell) async {
          await openChannel(tester, kitchen);
          await arrive(tester, shell, pantry, [
            msg(r'$a'),
            msg(r'$b'),
          ], done: () => shell.desktop.shown.length >= 2);
          expect(shell.desktop.shown.map((n) => n.sound), [true, false]);
          expect(shell.chime.plays, 0);
        },
      ),
    );

    testWidgets(
      'in the background with sound off, no notice sounds',
      (tester) => run(
        tester,
        focused: false,
        sound: false,
        body: (shell) async {
          await openChannel(tester, kitchen);
          await arrive(tester, shell, pantry, [
            msg(r'$a'),
            msg(r'$b'),
          ], done: () => shell.desktop.shown.length >= 2);
          expect(shell.desktop.shown.map((n) => n.sound), [false, false]);
          expect(shell.chime.plays, 0);
        },
      ),
    );
  });

  group('the shell opening', () {
    for (final notifications in [true, false]) {
      testWidgets(
        'on a desktop with notifications ${notifications ? 'on' : 'off'}, '
        'the desktop is ${notifications ? '' : 'not '}prepared',
        (tester) => run(
          tester,
          notifications: notifications,
          body: (shell) async {
            expect(shell.desktop.prepared, notifications ? 1 : 0);
          },
        ),
      );
    }
  });
}
