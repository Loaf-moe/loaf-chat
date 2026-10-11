import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/matrix/call_members.dart';
import 'package:matrix/matrix.dart';

const _ada = '@ada:example.com';
const _bo = '@bo:example.com';

const _hour = 3600000;
final _noon = DateTime.utc(2026, 10, 11, 12);
final _noonMs = _noon.millisecondsSinceEpoch;

var _events = 0;

/// A membership as Element Call writes one, started at [sent] unless
/// [created] says otherwise. [content] replaces or adds fields; a null
/// value removes one.
MatrixEvent _membership({
  String sender = _ada,
  String device = 'DEVICE',
  int? sent,
  int? created,
  int expires = 4 * _hour,
  Map<String, Object?> content = const {},
}) {
  final body = <String, Object?>{
    'application': 'm.call',
    'call_id': '',
    'device_id': device,
    'expires': expires,
    'created_ts': ?created,
    'focus_active': {'type': 'livekit', 'focus_selection': 'multi_sfu'},
    'scope': 'm.room',
  };
  for (final MapEntry(:key, :value) in content.entries) {
    if (value == null) {
      body.remove(key);
    } else {
      body[key] = value;
    }
  }
  return _event(sender, device, body, sent: sent);
}

MatrixEvent _event(
  String sender,
  String device,
  Map<String, Object?> content, {
  int? sent,
}) => MatrixEvent.fromJson({
  'type': callMemberType,
  'state_key': '_${sender}_${device}_m.call',
  'sender': sender,
  'content': content,
  'event_id': '\$c${_events++}',
  'origin_server_ts': sent ?? _noonMs - _hour,
});

void main() {
  test('someone with a membership is in the call', () {
    final here = callOccupancy([_membership()], _noon);

    expect(here.userIds, [_ada]);
  });

  test('someone whose membership was emptied has left', () {
    final here = callOccupancy([_event(_ada, 'DEVICE', const {})], _noon);

    expect(here.userIds, isEmpty);
  });

  test('a membership past its expiry counts for nobody', () {
    final here = callOccupancy([
      _membership(sent: _noonMs - 5 * _hour, expires: 4 * _hour),
    ], _noon);

    expect(here.userIds, isEmpty);
  });

  test('a membership expires at its last millisecond, not after it', () {
    final here = callOccupancy([
      _membership(sent: _noonMs - 4 * _hour, expires: 4 * _hour),
    ], _noon);

    expect(here.userIds, isEmpty);
  });

  test('without a created time, expiry runs from when it was sent', () {
    final here = callOccupancy([
      _membership(sent: _noonMs - 3 * _hour, expires: 4 * _hour),
    ], _noon);

    expect(here.userIds, [_ada]);
  });

  test('a created time, when given, is what expiry runs from', () {
    final here = callOccupancy([
      _membership(
        created: _noonMs - 5 * _hour,
        sent: _noonMs - _hour,
        expires: 4 * _hour,
      ),
    ], _noon);

    expect(here.userIds, isEmpty);
  });

  test('a membership that names no expiry lasts four hours', () {
    final here = callOccupancy([
      _membership(sent: _noonMs - _hour, content: {'expires': null}),
    ], _noon);

    expect(here.nextExpiry, _noon.add(const Duration(hours: 3)));
  });

  test('times written with a fraction count as the numbers they are', () {
    final here = callOccupancy([
      _membership(
        content: {'created_ts': _noonMs - _hour + 0.0, 'expires': 4.0 * _hour},
      ),
    ], _noon);

    expect(here.nextExpiry, _noon.add(const Duration(hours: 3)));
  });

  test('a membership whose device has an empty name still counts', () {
    final here = callOccupancy([_membership(device: '')], _noon);

    expect(here.userIds, [_ada]);
  });

  test('someone in the call on two devices is listed once', () {
    final here = callOccupancy([
      _membership(device: 'PHONE'),
      _membership(device: 'LAPTOP'),
    ], _noon);

    expect(here.userIds, [_ada]);
  });

  test('whoever joined first is listed first', () {
    final here = callOccupancy([
      _membership(sender: _bo, sent: _noonMs - _hour),
      _membership(sender: _ada, sent: _noonMs - 2 * _hour),
    ], _noon);

    expect(here.userIds, [_ada, _bo]);
  });

  test('two who joined at the same moment are listed by user id', () {
    final here = callOccupancy([
      _membership(sender: _bo),
      _membership(sender: _ada),
    ], _noon);

    expect(here.userIds, [_ada, _bo]);
  });

  group('a membership that is not a room call counts for nobody:', () {
    const cases = <String, Map<String, Object?>>{
      'another application': {'application': 'm.game'},
      'no application': {'application': null},
      'a call of its own inside the room': {'call_id': 'side'},
      'no call id': {'call_id': null},
      'no device': {'device_id': null},
      'no focus': {'focus_active': null},
      'a focus of no type': {'focus_active': <String, Object?>{}},
      'an expiry that is not a number': {'expires': '14400000'},
      'an expiry of nothing': {'expires': 0},
      'an expiry before it began': {'expires': -1},
      'a created time that is not a number': {'created_ts': 'noon'},
    };
    for (final MapEntry(key: name, value: content) in cases.entries) {
      test(name, () {
        final here = callOccupancy([_membership(content: content)], _noon);

        expect(here.userIds, isEmpty);
      });
    }
  });

  test('the next expiry is the soonest among those in the call', () {
    final here = callOccupancy([
      _membership(sender: _ada, sent: _noonMs - _hour, expires: 4 * _hour),
      _membership(sender: _bo, sent: _noonMs - _hour, expires: 2 * _hour),
    ], _noon);

    expect(here.nextExpiry, _noon.add(const Duration(hours: 1)));
  });

  test('an expired membership is not the next expiry', () {
    final here = callOccupancy([
      _membership(sender: _ada, sent: _noonMs - _hour, expires: 4 * _hour),
      _membership(sender: _bo, sent: _noonMs - 5 * _hour, expires: 4 * _hour),
    ], _noon);

    expect(here.nextExpiry, _noon.add(const Duration(hours: 3)));
  });

  test('an empty call has no next expiry', () {
    final here = callOccupancy(const [], _noon);

    expect(here.nextExpiry, isNull);
  });
}
