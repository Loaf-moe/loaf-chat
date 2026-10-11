import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:loaf_native/matrix/call_media.dart';
import 'package:loaf_native/matrix/call_members.dart';
import 'package:loaf_native/matrix/client_factory.dart';
import 'package:loaf_native/matrix/matrix_rooms.dart';
import 'package:loaf_native/ui/call/calls.dart';
import 'package:loaf_native/ui/model/models.dart';
import 'package:loaf_native/ui/settings/voice_settings.dart';
// The SDK's own call module has classes of the same names.
import 'package:matrix/matrix.dart' hide CallParticipant, CallSession;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'in_memory_call_media.dart';

const _me = '@test:fakeServer.notExisting';
const _device = 'GHTYAJCE';
const _mine = '$_me:$_device';
const _ada = '@ada:example.com';
const _oven = '!oven:example.com';
const _kiln = '!kiln:example.com';
const _hour = 3600000;
final _noon = DateTime.utc(2026, 10, 11, 12);
final _mediaUrl = Uri.parse('wss://sfu.example.com');

const _ovenChannel = Channel(id: _oven, name: 'oven', kind: ChannelKind.voice);
const _kilnChannel = Channel(id: _kiln, name: 'kiln', kind: ChannelKind.voice);

/// A token as the call server would issue for [identity] in [room]. Only
/// its claims are read.
String _jwt(String identity, String room) {
  final claims = base64Url.encode(
    utf8.encode(
      jsonEncode({
        'sub': identity,
        'video': {'room': room},
      }),
    ),
  );
  return 'head.$claims.signature';
}

http.Response _json(Object? body, [int status = 200]) =>
    http.Response(jsonEncode(body), status);

/// The fake homeserver with a call server beside it. [log] keeps the order
/// things were asked in.
class _Api extends FakeMatrixApi {
  _Api(this.log);

  final List<String> log;

  /// The homeserver names no call server.
  var noCallServer = false;

  /// What the call server answers, in place of access.
  http.Response? callServerAnswer;

  /// Held back until completed, when set: the call server's answer.
  Completer<void>? hold;

  /// The homeserver refuses to store a membership.
  var refuseMembership = false;

  /// Held back until completed, when set: the answer to a membership write.
  Completer<void>? holdMembership;

  /// How many of the next membership writes meet a dropped connection.
  var dropMemberships = 0;

  /// How many of the next membership writes are told to slow down.
  var limitMemberships = 0;

  @override
  FutureOr<http.Response> mockIntercept(http.Request request) async {
    final path = request.url.path;
    if (path == '/.well-known/matrix/client') {
      return noCallServer
          ? http.Response('not found', 404)
          : _json({
              'org.matrix.msc4143.rtc_foci': [
                {
                  'type': 'livekit',
                  'livekit_service_url': 'https://calls.example.com',
                },
              ],
            });
    }
    if (request.url.host == 'calls.example.com') {
      log.add('access');
      await hold?.future;
      final room = (jsonDecode(request.body) as Map)['room'] as String;
      return callServerAnswer ??
          _json({'url': '$_mediaUrl', 'jwt': _jwt(_mine, room)});
    }
    if (path.endsWith('/openid/request_token')) {
      return _json({
        'access_token': 'token',
        'token_type': 'Bearer',
        'matrix_server_name': 'fakeServer.notExisting',
        'expires_in': 3600,
      });
    }
    const marker = '/state/$callMemberType/';
    if (request.method == 'PUT' && path.contains(marker)) {
      final content = jsonDecode(request.body) as Map;
      log.add(content.isEmpty ? 'emptied membership' : 'wrote membership');
      await holdMembership?.future;
      if (dropMemberships > 0) {
        dropMemberships--;
        throw http.ClientException('connection dropped');
      }
      if (limitMemberships > 0) {
        limitMemberships--;
        return _json({
          'errcode': 'M_LIMIT_EXCEEDED',
          'error': 'slow down',
        }, 429);
      }
      return refuseMembership
          ? _json({'errcode': 'M_FORBIDDEN', 'error': 'not allowed'}, 403)
          : _json({'event_id': '\$w${log.length}'});
    }
    return super.mockIntercept(request);
  }
}

/// This device's media, saying in [log] when it connects and disconnects.
class _Logged implements CallMedia {
  _Logged(this._inner, this._log);

  final CallMedia _inner;
  final List<String> _log;

  /// Each time a connection was told which device to use.
  final deviceSets = <String>[];

  /// Each time a connection was told how loud to play someone, in order.
  final volumeSets = <(String, double)>[];

  /// The connection made last.
  CallConnection? last;

  @override
  Future<CallConnection> connect(Uri url, String jwt) async {
    _log.add('connected');
    return last = _LoggedConnection(
      await _inner.connect(url, jwt),
      _log,
      deviceSets,
      volumeSets,
    );
  }
}

class _LoggedConnection implements CallConnection {
  _LoggedConnection(this._inner, this._log, this._deviceSets, this._volumeSets);

  final CallConnection _inner;
  final List<String> _log;
  final List<String> _deviceSets;
  final List<(String, double)> _volumeSets;

  @override
  Future<void> disconnect() {
    _log.add('disconnected');
    return _inner.disconnect();
  }

  @override
  CallLink get link => _inner.link;
  @override
  CallQuality get quality => _inner.quality;
  @override
  Map<String, CallPeer> get peers => _inner.peers;
  @override
  Future<void> setMicrophone(bool on) => _inner.setMicrophone(on);
  @override
  Future<void> setDeafened(bool deafened) => _inner.setDeafened(deafened);
  @override
  Future<void> setVolume(String identity, double volume) {
    _volumeSets.add((identity, volume));
    return _inner.setVolume(identity, volume);
  }

  @override
  String? get microphone => _inner.microphone;
  @override
  String? get speaker => _inner.speaker;
  @override
  Stream<void> get deviceChanges => _inner.deviceChanges;
  @override
  MicrophoneProcessing get processing => _inner.processing;
  @override
  Future<void> setMicrophoneProcessing(MicrophoneProcessing processing) {
    _deviceSets.add('processing');
    return _inner.setMicrophoneProcessing(processing);
  }

  @override
  Future<void> setMicrophoneDevice(String? id) {
    _deviceSets.add('microphone');
    return _inner.setMicrophoneDevice(id);
  }

  @override
  Future<void> setSpeakerDevice(String? id) {
    _deviceSets.add('speaker');
    return _inner.setSpeakerDevice(id);
  }

  @override
  void addListener(VoidCallback listener) => _inner.addListener(listener);
  @override
  void removeListener(VoidCallback listener) => _inner.removeListener(listener);
}

var _events = 0;

Map<String, Object?> _state(
  String type,
  Map<String, Object?> content, {
  String key = '',
  String sender = _me,
}) => {
  'type': type,
  'state_key': key,
  'sender': sender,
  'content': content,
  'event_id': '\$e${_events++}',
  'origin_server_ts': _noon.millisecondsSinceEpoch - _hour,
};

/// [user]'s membership of a call on [device], or their leaving it.
Map<String, Object?> _inCall(String user, String device, {bool left = false}) =>
    _state(
      callMemberType,
      left
          ? const {}
          : {
              'application': 'm.call',
              'call_id': '',
              'device_id': device,
              'expires': 4 * _hour,
              'focus_active': {
                'type': 'livekit',
                'focus_selection': 'multi_sfu',
              },
            },
      key: '_${user}_${device}_m.call',
      sender: user,
    );

Map<String, Object?> _member(String user) => _state(
  'm.room.member',
  {'membership': 'join', 'displayname': user},
  key: user,
  sender: user,
);

Future<void> _sync(
  Client client,
  String room,
  List<Map<String, Object?>> state, {
  String as = 'join',
}) => client.handleSync(
  SyncUpdate.fromJson({
    'next_batch': 'b${_events++}',
    'rooms': {
      as: {
        room: {
          'state': {'events': state},
        },
      },
    },
  }),
);

Future<void> _until(bool Function() done) async {
  final give = DateTime.now().add(const Duration(seconds: 10));
  while (!done() && DateTime.now().isBefore(give)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// Everything a test holds: this device's calls, and the world around it.
class _World {
  final log = <String>[];
  late final api = _Api(log);
  final server = InMemoryCallServer(_mediaUrl);
  final network = ValueNotifier(CallLink.connected);
  final quality = ValueNotifier(CallQuality.good);

  /// The microphone and the speaker chosen in settings.
  final voice = ValueNotifier(const VoiceSettings());
  late final Client client;
  late final Calls calls;
  late final _Logged _media;

  /// This device's connection to the call it joined last.
  CallConnection get connection => _media.last!;

  /// How loud the calls were told to play whom, in order.
  List<(String, double)> get volumes => _media.volumeSets;

  /// Signs in, joins the voice rooms, and opens the calls. [microphone] is
  /// whether this device has one; [already] is state the oven has before
  /// the calls open.
  Future<void> open({
    bool microphone = true,
    bool encrypted = false,
    List<Map<String, Object?>> already = const [],
    ValueListenable<Set<String>>? present,
    Set<String> broken = const {},
  }) async {
    client = await openClient(
      httpClient: api,
      databasePath: inMemoryDatabasePath,
    );
    addTearDown(client.dispose);
    FakeMatrixApi.client = client;
    await client.init(
      newToken: 'abcd',
      newHomeserver: Uri.parse('https://fakeServer.notExisting'),
      newUserID: _me,
      newDeviceID: _device,
      newDeviceName: 'loaf on test',
    );
    for (final room in [_oven, _kiln]) {
      await _sync(client, room, [
        _state('m.room.create', {'creator': _me, 'type': 'm.call'}),
        _member(_me),
        if (encrypted)
          _state('m.room.encryption', {'algorithm': 'm.megolm.v1.aes-sha2'}),
        if (room == _oven) ...already,
      ]);
    }
    _media = _Logged(
      InMemoryCallMedia(
        server,
        network: network,
        quality: quality,
        microphone: microphone,
        present: present,
        broken: broken,
      ),
      log,
    );
    final rooms = MatrixRooms(
      client,
      callMedia: _media,
      voice: voice,
      now: () => _noon,
    );
    addTearDown(rooms.dispose);
    calls = rooms.calls!;
  }

  /// Joins the oven's call and waits until it is live.
  Future<void> join() async {
    calls.joinVoice(_ovenChannel, spaceName: 'Bakery');
    await _until(() => calls.session?.phase == CallPhase.live);
  }

  /// Another device in [room]'s call, as the media and the room both
  /// have it.
  Future<CallConnection> other(
    String user,
    String device, {
    String room = _oven,
  }) async {
    await _sync(client, room, [_member(user), _inCall(user, device)]);
    return InMemoryCallMedia(server)
        .connect(_mediaUrl, _jwt('$user:$device', room));
  }

  /// A device in the oven's call that only watches.
  Future<CallConnection> watcher() =>
      InMemoryCallMedia(server).connect(_mediaUrl, _jwt('watcher', _oven));

  List<String> get names => [
    for (final p in calls.session?.participants ?? const <CallParticipant>[])
      p.member.id,
  ];
}

Future<_World> _open({
  bool microphone = true,
  bool encrypted = false,
  List<Map<String, Object?>> already = const [],
  ValueListenable<Set<String>>? present,
  Set<String> broken = const {},
}) async {
  final world = _World();
  await world.open(
    microphone: microphone,
    encrypted: encrypted,
    already: already,
    present: present,
    broken: broken,
  );
  return world;
}

/// Long enough for anything a sync set going to have happened.
Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 100));

void main() {
  group('joining', () {
    test('shows connecting at once, then live', () async {
      final world = await _open();

      world.calls.joinVoice(_ovenChannel, spaceName: 'Bakery');

      expect(world.calls.session?.phase, CallPhase.connecting);
      await _until(() => world.calls.session?.phase == CallPhase.live);
      expect(world.calls.session?.phase, CallPhase.live);
    });

    test('gets access, then connects, and only then says so', () async {
      final world = await _open();

      await world.join();

      expect(world.log, ['access', 'connected', 'wrote membership']);
    });

    test('keeps the channel and its space on the session', () async {
      final world = await _open();

      await world.join();

      expect(world.calls.session?.target.id, _oven);
      expect(world.calls.session?.spaceName, 'Bakery');
      expect(world.calls.session?.startedAt, _noon);
    });

    test('a second channel leaves the first', () async {
      final world = await _open();
      await world.join();

      world.calls.joinVoice(_kilnChannel, spaceName: 'Bakery');
      await _until(
        () =>
            world.calls.session?.target.id == _kiln &&
            world.calls.session?.phase == CallPhase.live,
      );

      expect(world.log, [
        'access',
        'connected',
        'wrote membership',
        'emptied membership',
        'disconnected',
        'access',
        'connected',
        'wrote membership',
      ]);
    });
  });

  group('who is in the call', () {
    test('someone there before you is a participant', () async {
      final world = await _open();
      await world.other(_ada, 'PHONE');

      await world.join();

      expect(world.names, [_ada]);
    });

    test('someone joining after you appears', () async {
      final world = await _open();
      await world.join();

      await world.other(_ada, 'PHONE');
      await _until(() => world.names.isNotEmpty);

      expect(world.names, [_ada]);
    });

    test('someone leaving goes', () async {
      final world = await _open();
      final ada = await world.other(_ada, 'PHONE');
      await world.join();

      await ada.disconnect();
      await _sync(world.client, _oven, [_inCall(_ada, 'PHONE', left: true)]);
      await _until(() => world.names.isEmpty);

      expect(world.names, isEmpty);
    });

    test('you are not among your own participants', () async {
      final world = await _open();
      await world.join();

      await _sync(world.client, _oven, [_inCall(_me, _device)]);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(world.names, isEmpty);
    });

    test('someone on two devices is one participant', () async {
      final world = await _open();
      await world.other(_ada, 'PHONE');
      await world.other(_ada, 'LAPTOP');

      await world.join();

      expect(world.names, [_ada]);
    });

    test('someone sending no microphone shows muted', () async {
      final world = await _open();
      await world.other(_ada, 'PHONE');

      await world.join();

      expect(world.calls.session!.participants.single.muted, isTrue);
    });

    test('someone sending their microphone shows unmuted', () async {
      final world = await _open();
      final ada = await world.other(_ada, 'PHONE');
      await world.join();

      await ada.setMicrophone(true);
      await _until(() => !world.calls.session!.participants.single.muted);

      expect(world.calls.session!.participants.single.muted, isFalse);
    });

    test('someone speaking shows speaking', () async {
      final world = await _open();
      final ada = await world.other(_ada, 'PHONE');
      await world.join();

      await ada.setMicrophone(true);
      await _until(() => world.calls.session!.participants.single.speaking);

      expect(world.calls.session!.participants.single.speaking, isTrue);
    });

    test('someone unmuted on one of two devices shows unmuted', () async {
      final world = await _open();
      await world.other(_ada, 'PHONE');
      final laptop = await world.other(_ada, 'LAPTOP');
      await world.join();

      await laptop.setMicrophone(true);
      await _until(() => !world.calls.session!.participants.single.muted);

      expect(world.calls.session!.participants.single.muted, isFalse);
    });
  });

  group('your microphone', () {
    test('is sent once you are in, when you joined unmuted', () async {
      final world = await _open();
      final watcher = await world.watcher();

      await world.join();
      await _until(() => watcher.peers[_mine]?.muted == false);

      expect(watcher.peers[_mine]?.muted, isFalse);
    });

    test('is not sent when you joined muted', () async {
      final world = await _open();
      final watcher = await world.watcher();
      world.calls.toggleMute();

      await world.join();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(watcher.peers[_mine]?.muted, isTrue);
    });

    test('is sent when you unmute', () async {
      final world = await _open();
      final watcher = await world.watcher();
      world.calls.toggleMute();
      await world.join();

      world.calls.toggleMute();
      await _until(() => watcher.peers[_mine]?.muted == false);

      expect(watcher.peers[_mine]?.muted, isFalse);
    });

    test('stops being sent when you mute', () async {
      final world = await _open();
      final watcher = await world.watcher();
      await world.join();
      await _until(() => watcher.peers[_mine]?.muted == false);

      world.calls.toggleMute();
      await _until(() => watcher.peers[_mine]?.muted == true);

      expect(world.calls.muted, isTrue);
      expect(watcher.peers[_mine]?.muted, isTrue);
    });

    test('that cannot open leaves you muted, and says it is blocked', () async {
      final world = await _open(microphone: false);

      await world.join();
      await _until(() => world.calls.micBlocked);

      expect(world.calls.muted, isTrue);
      expect(world.calls.micBlocked, isTrue);
    });

    test('stops being sent when you deafen', () async {
      final world = await _open();
      final watcher = await world.watcher();
      await world.join();
      await _until(() => watcher.peers[_mine]?.muted == false);

      world.calls.toggleDeafen();
      await _until(() => watcher.peers[_mine]?.muted == true);

      expect(world.calls.deafened, isTrue);
      expect(world.calls.muted, isTrue);
    });

    test('is sent again when you undeafen', () async {
      final world = await _open();
      final watcher = await world.watcher();
      await world.join();
      world.calls.toggleDeafen();
      await _until(() => watcher.peers[_mine]?.muted == true);

      world.calls.toggleDeafen();
      await _until(() => watcher.peers[_mine]?.muted == false);

      expect(world.calls.deafened, isFalse);
      expect(world.calls.muted, isFalse);
    });

    test('unmuting undeafens', () async {
      final world = await _open();
      await world.join();
      world.calls.toggleDeafen();

      world.calls.toggleMute();

      expect(world.calls.deafened, isFalse);
    });
  });

  group('your devices', () {
    const rode = AudioDevice('rode', 'RODE NT-USB');
    const sony = AudioDevice('sony', 'WH-1000XM3');
    const desk = AudioDevice('desk', 'Desk Speakers');

    test('a call uses the microphone and the speaker chosen', () async {
      final world = await _open();
      world.voice.value = const VoiceSettings(microphone: rode, speaker: desk);

      await world.join();
      await _until(() => world.connection.speaker != null);

      expect(world.connection.microphone, 'rode');
      expect(world.connection.speaker, 'desk');
    });

    test('with nothing chosen, a call uses the system default', () async {
      final world = await _open();
      final watcher = await world.watcher();

      await world.join();
      await _until(() => watcher.peers[_mine]?.muted == false);

      expect(world.connection.microphone, isNull);
      expect(world.connection.speaker, isNull);
    });

    test('the microphone chosen is in place before it is sent', () async {
      final world = await _open();
      final watcher = await world.watcher();
      world.voice.value = const VoiceSettings(microphone: rode);
      String? sentFrom;
      watcher.addListener(() {
        if (watcher.peers[_mine]?.muted == false) {
          sentFrom ??= world.connection.microphone;
        }
      });

      await world.join();
      await _until(() => sentFrom != null);

      expect(sentFrom, 'rode');
    });

    test('choosing another microphone during a call switches to it', () async {
      final world = await _open();
      world.voice.value = const VoiceSettings(microphone: rode);
      await world.join();
      await _until(() => world.connection.microphone == 'rode');

      world.voice.value = const VoiceSettings(microphone: sony);
      await _until(() => world.connection.microphone == 'sony');

      expect(world.connection.microphone, 'sony');
    });

    test('choosing another speaker during a call switches to it', () async {
      final world = await _open();
      await world.join();

      world.voice.value = const VoiceSettings(speaker: desk);
      await _until(() => world.connection.speaker == 'desk');

      expect(world.connection.speaker, 'desk');
    });

    test(
      'going back to the system default during a call switches to it',
      () async {
        final world = await _open();
        world.voice.value = const VoiceSettings(microphone: rode);
        await world.join();
        await _until(() => world.connection.microphone == 'rode');

        world.voice.value = const VoiceSettings();
        await _until(() => world.connection.microphone == null);

        expect(world.connection.microphone, isNull);
      },
    );

    test('a chosen microphone that goes away gives way to the system '
        'default', () async {
      final present = ValueNotifier({'rode'});
      final world = await _open(present: present);
      world.voice.value = const VoiceSettings(microphone: rode);
      await world.join();
      await _until(() => world.connection.microphone == 'rode');

      present.value = {};
      await _until(() => world.connection.microphone == null);

      expect(world.connection.microphone, isNull);
    });

    test('a chosen speaker that goes away gives way to the system '
        'default', () async {
      final present = ValueNotifier({'desk'});
      final world = await _open(present: present);
      world.voice.value = const VoiceSettings(speaker: desk);
      await world.join();
      await _until(() => world.connection.speaker == 'desk');

      present.value = {};
      await _until(() => world.connection.speaker == null);

      expect(world.connection.speaker, isNull);
    });

    test('a chosen microphone that comes back is used again', () async {
      final present = ValueNotifier(<String>{});
      final world = await _open(present: present);
      final watcher = await world.watcher();
      world.voice.value = const VoiceSettings(microphone: rode);
      await world.join();
      await _until(() => watcher.peers[_mine]?.muted == false);

      present.value = {'rode'};
      await _until(() => world.connection.microphone == 'rode');

      expect(world.connection.microphone, 'rode');
    });

    test('a speaker that cannot be played on leaves your microphone '
        'sent', () async {
      final world = await _open(broken: {'desk'});
      final watcher = await world.watcher();
      world.voice.value = const VoiceSettings(speaker: desk);

      await world.join();
      await _until(() => watcher.peers[_mine]?.muted == false);

      expect(watcher.peers[_mine]?.muted, isFalse);
      expect(world.calls.session?.phase, CallPhase.live);
    });

    test('a microphone that does not open on being chosen mutes you and '
        'says it is blocked', () async {
      final world = await _open(broken: {'sony'});
      final watcher = await world.watcher();
      await world.join();
      await _until(() => watcher.peers[_mine]?.muted == false);

      world.voice.value = const VoiceSettings(microphone: sony);
      await _until(() => world.calls.micBlocked);

      expect(world.calls.micBlocked, isTrue);
      expect(world.calls.muted, isTrue);
      expect(watcher.peers[_mine]?.muted, isTrue);
    });

    test('choosing another microphone lifts the block, still muted', () async {
      final world = await _open(broken: {'sony'});
      world.voice.value = const VoiceSettings(microphone: sony);
      await world.join();
      await _until(() => world.calls.micBlocked);

      world.voice.value = const VoiceSettings(microphone: rode);
      await _until(() => !world.calls.micBlocked);

      expect(world.calls.micBlocked, isFalse);
      expect(world.calls.muted, isTrue);
    });

    test('unmuting after the block is lifted sends the microphone', () async {
      final world = await _open(broken: {'sony'});
      final watcher = await world.watcher();
      world.voice.value = const VoiceSettings(microphone: sony);
      await world.join();
      await _until(() => world.calls.micBlocked);
      world.voice.value = const VoiceSettings(microphone: rode);
      await _until(() => !world.calls.micBlocked);

      world.calls.toggleMute();
      await _until(() => watcher.peers[_mine]?.muted == false);

      expect(watcher.peers[_mine]?.muted, isFalse);
    });

    test('a call opens the microphone with the processing chosen', () async {
      final world = await _open();
      final watcher = await world.watcher();
      world.voice.value = const VoiceSettings(
        echoCancellation: false,
        automaticGain: false,
        highPassFilter: true,
      );
      MicrophoneProcessing? sentWith;
      watcher.addListener(() {
        if (watcher.peers[_mine]?.muted == false) {
          sentWith ??= world.connection.processing;
        }
      });

      await world.join();
      await _until(() => sentWith != null);

      expect(
        sentWith,
        const MicrophoneProcessing(
          echoCancellation: false,
          automaticGain: false,
          highPassFilter: true,
        ),
      );
    });

    test('switching processing during a call applies it', () async {
      final world = await _open();
      await world.join();
      const quiet = MicrophoneProcessing(noiseSuppression: false);

      world.voice.value = const VoiceSettings(noiseSuppression: false);
      await _until(() => world.connection.processing == quiet);

      expect(world.connection.processing, quiet);
    });

    test(
      'processing switched outside a call is used by the next one',
      () async {
        final world = await _open();
        await world.join();
        await world.calls.leave();
        const raw = MicrophoneProcessing(echoCancellation: false);

        world.voice.value = const VoiceSettings(echoCancellation: false);
        await world.join();
        await _until(() => world.connection.processing == raw);

        expect(world.connection.processing, raw);
      },
    );

    test('muting leaves the devices and the processing alone', () async {
      final world = await _open();
      final watcher = await world.watcher();
      await world.join();
      await _until(() => watcher.peers[_mine]?.muted == false);
      world._media.deviceSets.clear();

      world.calls.toggleMute();
      await _until(() => watcher.peers[_mine]?.muted == true);

      expect(world._media.deviceSets, isEmpty);
    });

    test('a choice made outside a call is used by the next one', () async {
      final world = await _open();
      await world.join();
      await world.calls.leave();

      world.voice.value = const VoiceSettings(microphone: sony);
      await world.join();
      await _until(() => world.connection.microphone == 'sony');

      expect(world.connection.microphone, 'sony');
    });
  });

  group("each person's volume", () {
    const quiet = VoiceSettings(volumes: {_ada: 0.4});

    test('set before the call is used once it is live', () async {
      final world = await _open();
      world.voice.value = quiet;
      await world.other(_ada, 'ADADEVICE');

      await world.join();
      await _until(() => world.volumes.isNotEmpty);

      expect(world.volumes, [('$_ada:ADADEVICE', 0.4)]);
    });

    test('set during the call is used at once', () async {
      final world = await _open();
      await world.other(_ada, 'ADADEVICE');
      await world.join();

      world.voice.value = quiet;
      await _until(() => world.volumes.isNotEmpty);

      expect(world.volumes, [('$_ada:ADADEVICE', 0.4)]);
    });

    test('goes for each of their devices', () async {
      final world = await _open();
      await world.other(_ada, 'ADADEVICE');
      await world.other(_ada, 'ADAPHONE');
      await world.join();

      world.voice.value = quiet;
      await _until(() => world.volumes.length >= 2);

      expect(
        world.volumes,
        unorderedEquals([('$_ada:ADADEVICE', 0.4), ('$_ada:ADAPHONE', 0.4)]),
      );
    });

    test('goes for a device of theirs that joins later', () async {
      final world = await _open();
      world.voice.value = quiet;
      await world.join();

      await world.other(_ada, 'ADAPHONE');
      await _until(() => world.volumes.isNotEmpty);

      expect(world.volumes, [('$_ada:ADAPHONE', 0.4)]);
    });

    test('set back to 1 is used too', () async {
      final world = await _open();
      world.voice.value = quiet;
      await world.other(_ada, 'ADADEVICE');
      await world.join();
      await _until(() => world.volumes.isNotEmpty);

      world.voice.value = const VoiceSettings();
      await _until(() => world.volumes.length >= 2);

      expect(world.volumes.last, ('$_ada:ADADEVICE', 1.0));
    });

    test('is told once, however often the call hears from the room', () async {
      final world = await _open();
      world.voice.value = quiet;
      await world.other(_ada, 'ADADEVICE');
      await world.join();
      await _until(() => world.volumes.isNotEmpty);

      await world.other('@bo:example.com', 'BODEVICE');
      await _settle();

      expect(world.volumes, [('$_ada:ADADEVICE', 0.4)]);
    });

    test('changed, leaves the devices and the processing alone', () async {
      final world = await _open();
      final watcher = await world.watcher();
      await world.other(_ada, 'ADADEVICE');
      await world.join();
      await _until(() => watcher.peers[_mine]?.muted == false);
      world._media.deviceSets.clear();

      world.voice.value = quiet;
      await _until(() => world.volumes.isNotEmpty);
      await _settle();

      expect(world._media.deviceSets, isEmpty);
    });

    test('changed, leaves a blocked microphone blocked', () async {
      const sony = AudioDevice('sony', 'WH-1000XM3');
      final world = await _open(broken: {'sony'});
      world.voice.value = const VoiceSettings(microphone: sony);
      await world.other(_ada, 'ADADEVICE');
      await world.join();
      await _until(() => world.calls.micBlocked);

      world.voice.value = const VoiceSettings(
        microphone: sony,
        volumes: {_ada: 0.4},
      );
      await _until(() => world.volumes.isNotEmpty);
      await _settle();

      expect(world.calls.micBlocked, isTrue);
    });

    test('is left alone for someone never set', () async {
      final world = await _open();
      await world.other(_ada, 'ADADEVICE');

      await world.join();
      await _settle();

      expect(world.volumes, isEmpty);
    });

    test('is never set for your own devices', () async {
      final world = await _open();
      world.voice.value = const VoiceSettings(volumes: {_me: 0.4});
      await world.other(_me, 'MYPHONE');

      await world.join();
      await _settle();

      expect(world.volumes, isEmpty);
    });
  });

  group('leaving', () {
    test('clears the session at once', () async {
      final world = await _open();
      await world.join();

      world.calls.leave();

      expect(world.calls.session, isNull);
      expect(world.calls.inCall, isFalse);
    });

    test('is done once the room has been told and the media dropped', () async {
      final world = await _open();
      await world.join();

      await world.calls.leave();

      expect(world.log.skip(3), ['emptied membership', 'disconnected']);
    });

    test('while the join is still being written is done only once that '
        'is undone', () async {
      final world = await _open();
      final written = world.api.holdMembership = Completer();
      world.calls.joinVoice(_ovenChannel, spaceName: 'Bakery');
      await _until(() => world.log.contains('wrote membership'));

      final left = world.calls.leave();
      written.complete();
      await left;

      expect(world.log, [
        'access',
        'connected',
        'wrote membership',
        'emptied membership',
        'disconnected',
      ]);
    });

    test('with no call is done at once', () async {
      final world = await _open();

      await world.calls.leave();

      expect(world.log, isEmpty);
    });

    test('says so in the room before dropping the media', () async {
      final world = await _open();
      await world.join();

      world.calls.leave();
      await _until(() => world.log.last == 'disconnected');

      expect(world.log.skip(3), ['emptied membership', 'disconnected']);
    });

    test('empties the membership once, though a sync still shows it', () async {
      final world = await _open();
      await world.join();
      await _sync(world.client, _oven, [_inCall(_me, _device)]);

      world.calls.leave();
      await _until(() => world.log.last == 'disconnected');
      await _sync(world.client, _oven, const []);
      await _settle();

      expect(world.log.skip(3), ['emptied membership', 'disconnected']);
    });

    test('while still connecting ends with nothing connected', () async {
      final world = await _open();
      world.api.hold = Completer();
      world.calls.joinVoice(_ovenChannel, spaceName: 'Bakery');
      await _until(() => world.log.contains('access'));

      world.calls.leave();
      world.api.hold!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(world.log, ['access']);
      expect(world.calls.session, isNull);
    });

    test('the room leaves its call', () async {
      final world = await _open();
      await world.join();

      await _sync(world.client, _oven, const [], as: 'leave');
      await _until(() => world.calls.session == null);

      expect(world.calls.session, isNull);
    });
  });

  group('a join that fails', () {
    Future<_World> failing(void Function(_Api api) how) async {
      final world = await _open();
      how(world.api);
      world.calls.joinVoice(_ovenChannel, spaceName: 'Bakery');
      await _until(() => world.calls.session?.phase == CallPhase.failed);
      return world;
    }

    test('for want of a call server asks for nothing more', () async {
      final world = await failing((api) => api.noCallServer = true);

      expect(world.calls.session?.phase, CallPhase.failed);
      expect(world.log, isEmpty);
    });

    test('at the call server never connects', () async {
      final world = await failing(
        (api) => api.callServerAnswer = _json({'errcode': 'M_FORBIDDEN'}, 403),
      );

      expect(world.calls.session?.phase, CallPhase.failed);
      expect(world.log, ['access']);
    });

    test('at the media server writes no membership', () async {
      final world = await failing(
        (api) => api.callServerAnswer = _json({
          'url': 'wss://elsewhere.example.com',
          'jwt': _jwt(_mine, _oven),
        }),
      );

      expect(world.calls.session?.phase, CallPhase.failed);
      expect(world.log, ['access', 'connected']);
    });

    test('at the membership drops the media', () async {
      final world = await failing((api) => api.refuseMembership = true);

      expect(world.calls.session?.phase, CallPhase.failed);
      expect(world.log, [
        'access',
        'connected',
        'wrote membership',
        'disconnected',
      ]);
    });

    test('is not in a call', () async {
      final world = await failing((api) => api.noCallServer = true);

      expect(world.calls.inCall, isFalse);
    });

    test('joins when tried again', () async {
      final world = await failing((api) => api.noCallServer = true);
      world.api.noCallServer = false;

      world.calls.retry();
      await _until(() => world.calls.session?.phase == CallPhase.live);

      expect(world.calls.session?.phase, CallPhase.live);
    });

    test('goes away when dismissed', () async {
      final world = await failing((api) => api.noCallServer = true);

      world.calls.leave();

      expect(world.calls.session, isNull);
    });
  });

  group('an encrypted room', () {
    test('cannot be joined', () async {
      final world = await _open(encrypted: true);

      expect(world.calls.joinable(_ovenChannel), isFalse);
    });

    test('asked for anyway fails without asking for access', () async {
      final world = await _open(encrypted: true);

      world.calls.joinVoice(_ovenChannel, spaceName: 'Bakery');
      await _until(() => world.calls.session?.phase == CallPhase.failed);

      expect(world.calls.session?.phase, CallPhase.failed);
      expect(world.log, isEmpty);
    });
  });

  group('a room this device does not know yet', () {
    const unknown = Channel(
      id: '!later:example.com',
      name: 'later',
      kind: ChannelKind.voice,
    );

    test('is not held to be unjoinable', () async {
      final world = await _open();

      expect(world.calls.joinable(unknown), isTrue);
    });

    test('fails to join, without asking for access', () async {
      final world = await _open();

      world.calls.joinVoice(unknown, spaceName: 'Bakery');
      await _until(() => world.calls.session?.phase == CallPhase.failed);

      expect(world.calls.session?.phase, CallPhase.failed);
      expect(world.log, isEmpty);
    });
  });

  test('a room with no encryption can be joined', () async {
    final world = await _open();

    expect(world.calls.joinable(_ovenChannel), isTrue);
  });

  group('how good your link is', () {
    test('is as the media rates it', () async {
      final world = await _open();
      await world.join();

      world.quality.value = CallQuality.poor;

      expect(world.calls.quality, CallQuality.poor);
    });

    test('tells its listeners when the rating changes', () async {
      final world = await _open();
      await world.join();
      var told = 0;
      world.calls.addListener(() => told++);

      world.quality.value = CallQuality.poor;

      expect(told, greaterThan(0));
    });

    test('is unknown with no call', () async {
      final world = await _open();

      expect(world.calls.quality, CallQuality.unknown);
    });
  });

  group('the connection', () {
    test('dropping shows reconnecting', () async {
      final world = await _open();
      await world.join();

      world.network.value = CallLink.reconnecting;

      expect(world.calls.session?.phase, CallPhase.reconnecting);
    });

    test('coming back shows live', () async {
      final world = await _open();
      await world.join();
      world.network.value = CallLink.reconnecting;

      world.network.value = CallLink.connected;

      expect(world.calls.session?.phase, CallPhase.live);
    });

    test('lost for good fails the call and says so in the room', () async {
      final world = await _open();
      await world.join();

      world.network.value = CallLink.lost;
      await _until(() => world.log.last == 'disconnected');

      expect(world.calls.session?.phase, CallPhase.failed);
      expect(world.log.skip(3), ['emptied membership', 'disconnected']);
    });
  });

  group('a membership this device left behind', () {
    test('is emptied at launch', () async {
      final world = await _open(already: [_inCall(_me, _device)]);

      await _until(() => world.log.isNotEmpty);

      expect(world.log, ['emptied membership']);
    });

    test('is emptied when a later sync brings it', () async {
      final world = await _open();

      await _sync(world.client, _oven, [_inCall(_me, _device)]);
      await _until(() => world.log.isNotEmpty);

      expect(world.log, ['emptied membership']);
    });

    test('is emptied once, however many syncs still show it', () async {
      final world = await _open(already: [_inCall(_me, _device)]);
      await _until(() => world.log.isNotEmpty);

      await _sync(world.client, _oven, const []);
      await _sync(world.client, _oven, const []);
      await _settle();

      expect(world.log, ['emptied membership']);
    });

    test(
      'is tried again at the next sync after a dropped connection',
      () async {
        final world = _World()..api.dropMemberships = 1;
        await world.open(already: [_inCall(_me, _device)]);
        await _until(() => world.log.isNotEmpty);
        await _settle();

        await _sync(world.client, _oven, const []);
        await _until(() => world.log.length == 2);

        expect(world.log, ['emptied membership', 'emptied membership']);
      },
    );

    test('is tried again at the next sync when told to slow down', () async {
      final world = _World()..api.limitMemberships = 1;
      await world.open(already: [_inCall(_me, _device)]);
      await _until(() => world.log.isNotEmpty);
      await _settle();

      await _sync(world.client, _oven, const []);
      await _until(() => world.log.length == 2);

      expect(world.log, ['emptied membership', 'emptied membership']);
    });

    test('is not tried again once refused', () async {
      final world = _World()..api.refuseMembership = true;
      await world.open(already: [_inCall(_me, _device)]);
      await _until(() => world.log.isNotEmpty);
      await _settle();

      await _sync(world.client, _oven, const []);
      await _settle();

      expect(world.log, ['emptied membership']);
    });
  });

  test('a membership of another of your devices is left alone', () async {
    final world = await _open(already: [_inCall(_me, 'OTHERDEVICE')]);

    await _settle();

    expect(world.log, isEmpty);
  });

  test("someone else's membership is left alone", () async {
    final world = await _open(already: [_member(_ada), _inCall(_ada, 'PHONE')]);

    await _settle();

    expect(world.log, isEmpty);
  });

  test('your membership emptied from elsewhere is written again', () async {
    final world = await _open();
    await world.join();
    await _sync(world.client, _oven, [_inCall(_me, _device)]);

    await _sync(world.client, _oven, [_inCall(_me, _device, left: true)]);
    await _until(() => world.log.length > 3);

    expect(world.log.skip(3), ['wrote membership']);
  });

  test('an old emptied membership of yours is not taken for leaving', () async {
    final world = await _open();
    await _sync(world.client, _oven, [_inCall(_me, _device, left: true)]);

    await world.join();
    await _sync(world.client, _oven, const []);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(world.log, ['access', 'connected', 'wrote membership']);
  });
}
