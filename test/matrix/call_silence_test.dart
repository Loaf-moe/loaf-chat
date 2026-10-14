import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/matrix/call_silence.dart';
import 'package:loaf_native/ui/model/models.dart';
import 'package:matrix/matrix.dart';

const _ada = '@ada:example.com';

var _events = 0;

MatrixEvent _entry(
  Map<String, Object?> content, {
  String key = '_$_ada',
  String type = callSilenceType,
}) => MatrixEvent(
  type: type,
  stateKey: key,
  content: content,
  eventId: '\$e${_events++}',
  senderId: '@mod:example.com',
  originServerTs: DateTime.utc(2026, 10, 11),
);

void main() {
  test('muted is muted', () {
    expect(
      callSilences([
        _entry({'muted': true}),
      ]),
      {_ada: CallSilence.muted},
    );
  });

  test('deafened is deafened', () {
    expect(
      callSilences([
        _entry({'deafened': true}),
      ]),
      {_ada: CallSilence.deafened},
    );
  });

  test('deafened wins over muted', () {
    expect(
      callSilences([
        _entry({'muted': true, 'deafened': true}),
      ]),
      {_ada: CallSilence.deafened},
    );
  });

  test('an emptied entry is nobody', () {
    expect(callSilences([_entry(const {})]), isEmpty);
  });

  test('both switched off is nobody', () {
    expect(
      callSilences([
        _entry({'muted': false, 'deafened': false}),
      ]),
      isEmpty,
    );
  });

  group('hanging up', () {
    test('keeps the standing silence beside the flag', () {
      expect(callHangUpContent(CallSilence.muted), {
        'muted': true,
        'deafened': false,
        'hung_up': true,
      });
      expect(callHangUpContent(CallSilence.deafened), {
        'muted': true,
        'deafened': true,
        'hung_up': true,
      });
      expect(callHangUpContent(null), {'hung_up': true});
    });

    test('is read back with the server\'s time', () {
      expect(
        callHangUps([
          _entry({'muted': true, 'hung_up': true}),
        ]),
        {_ada: DateTime.utc(2026, 10, 11)},
      );
    });

    test('is nobody without the flag', () {
      expect(
        callHangUps([
          _entry({'muted': true}),
        ]),
        isEmpty,
      );
      expect(
        callHangUps([
          _entry({'hung_up': 'yes'}),
        ]),
        isEmpty,
      );
      expect(
        callHangUps([
          _entry({'hung_up': true}, key: _ada),
        ]),
        isEmpty,
      );
    });

    test('is still a silence', () {
      expect(
        callSilences([
          _entry({'muted': true, 'deafened': false, 'hung_up': true}),
        ]),
        {_ada: CallSilence.muted},
      );
    });
  });

  group('is nobody when', () {
    final shapes = <String, MatrixEvent>{
      'the switch is no yes or no': _entry({'muted': 'yes'}),
      'the key is the bare user id': _entry({'muted': true}, key: _ada),
      'the key names no user': _entry({'muted': true}, key: '_ada'),
      'the key is empty': _entry({'muted': true}, key: ''),
      'it is another kind of event': _entry({
        'muted': true,
      }, type: 'org.example.other'),
    };
    for (final MapEntry(key: name, value: event) in shapes.entries) {
      test(name, () => expect(callSilences([event]), isEmpty));
    }
  });

  test('each person has their own entry', () {
    expect(
      callSilences([
        _entry({'muted': true}),
        _entry({'deafened': true}, key: '_@bo:example.com'),
      ]),
      {_ada: CallSilence.muted, '@bo:example.com': CallSilence.deafened},
    );
  });

  group('what is written', () {
    test('to mute reads back as muted', () {
      expect(callSilences([_entry(callSilenceContent(CallSilence.muted))]), {
        _ada: CallSilence.muted,
      });
    });

    test('to deafen reads back as deafened', () {
      expect(callSilences([_entry(callSilenceContent(CallSilence.deafened))]), {
        _ada: CallSilence.deafened,
      });
    });

    test('to lift reads back as nobody', () {
      expect(callSilences([_entry(callSilenceContent(null))]), isEmpty);
    });

    test('goes under the user id behind an underscore', () {
      expect(callSilenceKey(_ada), '_@ada:example.com');
    });
  });
}
