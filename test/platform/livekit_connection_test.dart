import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:loaf_native/matrix/call_media.dart';
import 'package:loaf_native/platform/livekit_media.dart';

/// A connection to a room that was never connected, so the link it reports
/// comes from the events alone, as LiveKit would send them.
({Room room, LiveKitConnection connection}) _open() {
  final room = Room();
  final connection = LiveKitConnection(room, null);
  // Torn down last in, first out: the room goes while the connection still
  // listens to it. Not disconnect(): a room never connected waits ten
  // seconds for an engine event it has already had.
  addTearDown(connection.dispose);
  addTearDown(room.dispose);
  return (room: room, connection: connection);
}

/// What LiveKit tells the room: delivered on its broadcast stream, so a
/// turn of the event loop later.
Future<void> _tell(Room room, RoomEvent event) async {
  // ignore: invalid_use_of_internal_member
  room.events.emit(event);
  await Future<void>.delayed(Duration.zero);
}

void main() {
  test('a fresh connection is connected', () {
    final (:room, :connection) = _open();

    expect(connection.link, CallLink.connected);
  });

  test('is reconnecting as soon as LiveKit sets about a reconnect', () async {
    final (:room, :connection) = _open();

    await _tell(
      room,
      const RoomAttemptReconnectEvent(
        attempt: 1,
        maxAttemptsRetry: 10,
        nextRetryDelaysInMs: 0,
      ),
    );

    expect(connection.link, CallLink.reconnecting);
  });

  test('is reconnecting while LiveKit restarts the connection', () async {
    final (:room, :connection) = _open();

    await _tell(room, const RoomReconnectingEvent());

    expect(connection.link, CallLink.reconnecting);
  });

  test('is reconnecting while LiveKit resumes the connection', () async {
    final (:room, :connection) = _open();

    await _tell(room, const RoomResumingEvent());

    expect(connection.link, CallLink.reconnecting);
  });

  test('is connected again once LiveKit has reconnected', () async {
    final (:room, :connection) = _open();
    await _tell(room, const RoomReconnectingEvent());

    await _tell(room, const RoomReconnectedEvent());

    expect(connection.link, CallLink.connected);
  });

  test('is lost only once LiveKit has given up', () async {
    final (:room, :connection) = _open();
    await _tell(room, const RoomReconnectingEvent());

    await _tell(
      room,
      RoomDisconnectedEvent(reason: DisconnectReason.reconnectAttemptsExceeded),
    );

    expect(connection.link, CallLink.lost);
  });

  test('a listener told of the change sees the new link', () async {
    final (:room, :connection) = _open();
    final seen = <CallLink>[];
    connection.addListener(() => seen.add(connection.link));

    await _tell(room, const RoomReconnectingEvent());

    expect(seen, contains(CallLink.reconnecting));
  });
}
