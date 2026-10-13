/// The shell's reaction to a message arriving, from the sync down: a real
/// client over the fake server, real rooms, the real shell, and fakes only
/// where the chime plays and the desktop shows a notification. Every
/// device setting and every state the decision reads: which channel is
/// open, whether the app is in front, and which platform.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/model/message_route.dart';

import 'shell_harness.dart';

void main() {
  group('an arrival', () {
    for (final focused in [true, false]) {
      for (final open in [true, false]) {
        for (final phone in [false, true]) {
          for (final sound in [true, false]) {
            for (final notifications in [true, false]) {
              for (final showText in [true, false]) {
                final roomId = open ? kitchen : pantry;
                final chimes = focused && !open && sound ? 1 : 0;
                final notices = !focused && !phone && notifications ? 1 : 0;
                testWidgets(
                  '${focused ? 'in front' : 'in the background'}, '
                  '${open ? 'the open channel' : 'another channel'}, '
                  '${phone ? 'phone' : 'desktop'}, '
                  'sound ${sound ? 'on' : 'off'}, '
                  'notifications ${notifications ? 'on' : 'off'}, '
                  'text ${showText ? 'on' : 'off'}',
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
            }
          }
        }
      }
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
