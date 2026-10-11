import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:loaf_native/matrix/call_media.dart';

/// A media server held in memory: devices that connect to one room see each
/// other, and a device sending its microphone counts as speaking.
class InMemoryCallServer {
  InMemoryCallServer(this.url);

  final Uri url;
  final _rooms = <String, List<_Connection>>{};

  void _changed(String room) {
    for (final connection in [...?_rooms[room]]) {
      connection._notify();
    }
  }
}

/// One device's way to an [InMemoryCallServer]: its [network] and whether it
/// has a [microphone].
class InMemoryCallMedia implements CallMedia {
  InMemoryCallMedia(
    this.server, {
    ValueListenable<CallLink>? network,
    this.microphone = true,
  }) : network = network ?? ValueNotifier(CallLink.connected);

  final InMemoryCallServer server;
  final ValueListenable<CallLink> network;
  final bool microphone;

  @override
  Future<CallConnection> connect(Uri url, String jwt) async {
    if (url != server.url) throw CallMediaUnreachable('no server at $url');
    if (network.value != CallLink.connected) {
      throw const CallMediaUnreachable('no network');
    }
    final claims = _claims(jwt);
    final identity = claims?['sub'];
    final video = claims?['video'];
    final room = video is Map ? video['room'] : null;
    if (identity is! String || room is! String) {
      throw const CallMediaUnreachable('token names no one, or no room');
    }
    final connection = _Connection(this, identity, room);
    (server._rooms[room] ??= []).add(connection);
    network.addListener(connection._notify);
    server._changed(room);
    return connection;
  }

  static Map<String, Object?>? _claims(String jwt) {
    final parts = jwt.split('.');
    if (parts.length != 3) return null;
    try {
      final json = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
      );
      return json is Map<String, Object?> ? json : null;
    } on FormatException {
      return null;
    }
  }
}

class _Connection extends ChangeNotifier implements CallConnection {
  _Connection(this._media, this._identity, this._room);

  final InMemoryCallMedia _media;
  final String _identity;
  final String _room;
  var _microphone = false;
  var _gone = false;

  void _notify() {
    if (!_gone) notifyListeners();
  }

  @override
  CallLink get link => _gone ? CallLink.lost : _media.network.value;

  @override
  Map<String, CallPeer> get peers => {
    for (final other in _media.server._rooms[_room] ?? const <_Connection>[])
      if (!identical(other, this))
        other._identity: CallPeer(
          muted: !other._microphone,
          speaking: other._microphone,
        ),
  };

  @override
  Future<void> setMicrophone(bool on) async {
    if (on && !_media.microphone) {
      throw const MicrophoneUnavailable('this device has none');
    }
    _microphone = on;
    _media.server._changed(_room);
  }

  @override
  Future<void> setDeafened(bool deafened) async {}

  @override
  Future<void> disconnect() async {
    if (_gone) return;
    _gone = true;
    _media.network.removeListener(_notify);
    _media.server._rooms[_room]?.remove(this);
    _media.server._changed(_room);
  }
}
