/// Registering this device with the push gateway, and taking it off again.
/// Without a pusher the homeserver sends nothing at all, so this is what
/// makes push happen; it is also the only place that names the gateway.
library;

import 'package:flutter/foundation.dart' show kReleaseMode;
// The SDK has a Pusher of its own — the wire object, not this.
import 'package:matrix/matrix.dart' hide Pusher;
import 'package:matrix/matrix.dart' as sdk show Pusher;

import 'ios_push.dart';

/// One Loaf Chat gateway serves every homeserver. The APNs key belongs to
/// the app, not to a server, so a per-homeserver gateway could not sign for
/// this app even if someone ran one.
const pushGateway = 'https://push.matrix.loaf.moe/_matrix/push/v1/notify';

/// What the homeserver is told to send, and whether to send at all.
class Pusher {
  Pusher({
    required this.client,
    required this.push,
    required this.enabled,
    this.release = kReleaseMode,
    this.gateway = pushGateway,
  });

  final Client client;
  final IosPush push;
  final bool Function() enabled;

  /// Debug builds get an APNs sandbox token the production gateway cannot
  /// send to, so they register nothing rather than register a dead one.
  final bool release;
  final String gateway;

  Future<void> sync() async {
    if (!release) return;
    final token = await push.pushToken();
    if (token == null) return;
    final id = PusherId(appId: 'moe.loaf.chat.ios', pushkey: token);
    try {
      if (enabled()) {
        await client.postPusher(
          sdk.Pusher(
            appId: id.appId,
            pushkey: token,
            appDisplayName: 'Loaf Chat',
            deviceDisplayName: client.deviceName ?? 'iPhone',
            kind: 'http',
            lang: 'en',
            // event_id_only: the gateway is told which message arrived,
            // never what it says. The extension fetches the rest itself.
            data: PusherData(url: Uri.parse(gateway), format: 'event_id_only'),
          ),
          // One pusher for this device, replaced rather than added to.
          append: false,
        );
      } else {
        await client.deletePusher(id);
      }
    } on Object catch (e) {
      // Push is a convenience; the app works without it. Tried again next
      // launch.
      Logs().w('[loaf] pusher', e);
    }
  }
}
