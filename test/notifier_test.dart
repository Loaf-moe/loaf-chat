import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/model/arrival.dart';
import 'package:loaf_native/ui/model/chime.dart';
import 'package:loaf_native/ui/shell/notifier.dart';

void main() {
  group('decide', () {
    test('focused on that channel: nothing; it is read', () {
      expect(
        decide(focused: true, open: true, desktop: true),
        NoticeAction.none,
      );
      expect(
        decide(focused: true, open: true, desktop: false),
        NoticeAction.none,
      );
    });
    test('focused elsewhere: the chime', () {
      expect(
        decide(focused: true, open: false, desktop: true),
        NoticeAction.chime,
      );
      expect(
        decide(focused: true, open: false, desktop: false),
        NoticeAction.chime,
      );
    });
    test('desktop, unfocused: a desktop notification, open channel or not', () {
      expect(
        decide(focused: false, open: true, desktop: true),
        NoticeAction.desktopNotice,
      );
      expect(
        decide(focused: false, open: false, desktop: true),
        NoticeAction.desktopNotice,
      );
    });
    test('phone, backgrounded: push carries it', () {
      expect(
        decide(focused: false, open: false, desktop: false),
        NoticeAction.push,
      );
    });
  });

  group('Notifier', () {
    late StreamController<Arrival> arrivals;
    late FakeChime chime;
    var sound = true;
    var focused = true;
    String? open;
    var elapsed = Duration.zero;
    final notices = <(Arrival, bool)>[];

    Notifier make() => Notifier(
      arrivals: arrivals.stream,
      chime: chime,
      soundOn: () => sound,
      openRoom: () => open,
      focused: () => focused,
      desktop: true,
      elapsed: () => elapsed,
      notice: (a, {required sound}) => notices.add((a, sound)),
    );

    setUp(() {
      arrivals = StreamController<Arrival>();
      chime = FakeChime();
      sound = true;
      focused = true;
      open = '!open';
      elapsed = Duration.zero;
      notices.clear();
    });

    var id = 0;

    Future<void> arrive(String room) async {
      arrivals.add(Arrival(roomId: room, eventId: '\$${id++}'));
      await pumpEventQueue();
    }

    test('a message elsewhere chimes', () async {
      final n = make();
      addTearDown(n.dispose);
      await arrive('!other');
      expect(chime.plays, 1);
    });

    test('a message in the open channel does not', () async {
      final n = make();
      addTearDown(n.dispose);
      await arrive('!open');
      expect(chime.plays, 0);
    });

    test('with sound off, nothing plays', () async {
      sound = false;
      final n = make();
      addTearDown(n.dispose);
      await arrive('!other');
      expect(chime.plays, 0);
    });

    test(
      'unfocused on a desktop, a notification instead of the chime',
      () async {
        focused = false;
        final n = make();
        addTearDown(n.dispose);
        await arrive('!other');
        expect(chime.plays, 0);
        expect(notices.single.$1.roomId, '!other');
        expect(notices.single.$2, isTrue);
      },
    );

    test('unfocused, the open channel notifies too', () async {
      focused = false;
      final n = make();
      addTearDown(n.dispose);
      await arrive('!open');
      expect(notices, hasLength(1));
    });

    test(
      'one throttle for chimes and notifications: a burst sounds once',
      () async {
        final n = make();
        addTearDown(n.dispose);
        await arrive('!other'); // chimes
        focused = false;
        await arrive('!other'); // a notice, within the second: silent
        elapsed = const Duration(seconds: 1);
        await arrive('!other'); // a notice, a second on: sounds
        expect(chime.plays, 1);
        expect([for (final (_, sound) in notices) sound], [false, true]);
      },
    );

    test('with sound off, notices are silent', () async {
      sound = false;
      focused = false;
      final n = make();
      addTearDown(n.dispose);
      await arrive('!other');
      expect(notices.single.$2, isFalse);
    });

    test('a burst chimes once', () async {
      final n = make();
      addTearDown(n.dispose);
      for (var i = 0; i < 5; i++) {
        await arrive('!other');
        elapsed += const Duration(milliseconds: 150);
      }
      expect(chime.plays, 1);
    });

    test('a second later it chimes again', () async {
      final n = make();
      addTearDown(n.dispose);
      await arrive('!other');
      elapsed += const Duration(seconds: 1);
      await arrive('!other');
      expect(chime.plays, 2);
    });

    test('after a burst it chimes again once a second has passed', () async {
      final n = make();
      addTearDown(n.dispose);
      for (var i = 0; i < 5; i++) {
        await arrive('!other');
        elapsed += const Duration(milliseconds: 150);
      }
      expect(chime.plays, 1);
      // 750 ms in; the burst began at 0, so 250 ms more makes a second.
      elapsed += const Duration(milliseconds: 250);
      await arrive('!other');
      expect(chime.plays, 2);
    });

    test(
      'a message in the open channel does not hold back the next chime',
      () async {
        final n = make();
        addTearDown(n.dispose);
        await arrive('!open');
        await arrive('!other');
        expect(chime.plays, 1);
      },
    );

    test('after dispose it hears nothing', () async {
      make().dispose();
      await arrive('!other');
      expect(chime.plays, 0);
    });
  });
}
