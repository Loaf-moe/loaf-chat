/// Which server carries a homeserver's calls, and this device's way into one
/// room's call on it, asked for the way Element Call asks.
library;

import 'dart:convert';

import 'package:matrix/matrix.dart';

/// Where a call's media goes, and the token that lets this device in.
class SfuAccess {
  const SfuAccess(this.url, this.jwt);

  final Uri url;
  final String jwt;
}

/// Asked of a client with no account signed in.
class NotSignedIn implements Exception {
  const NotSignedIn();

  @override
  String toString() => 'NotSignedIn';
}

/// The homeserver names no LiveKit server for its calls.
class NoCallServer implements Exception {
  const NoCallServer(this.serverName);

  final String serverName;

  @override
  String toString() => 'NoCallServer: $serverName names no LiveKit focus';
}

/// The homeserver answered for its well-known file with neither the file
/// nor a plain "not found".
class WellKnownUnavailable implements Exception {
  const WellKnownUnavailable(this.status);

  final int status;

  @override
  String toString() => 'WellKnownUnavailable: $status';
}

/// The call server answered with something other than access.
class CallServerError implements Exception {
  const CallServerError(this.status, this.errcode);

  final int status;
  final String? errcode;

  @override
  String toString() => 'CallServerError: $status ${errcode ?? ''}';
}

/// The call server said yes in a shape that names no address or no token.
class CallServerMalformed implements Exception {
  const CallServerMalformed();

  @override
  String toString() => 'CallServerMalformed';
}

/// The LiveKit server your homeserver names for its calls: the first LiveKit
/// focus in its well-known file.
Future<Uri> callServer(Client client) async {
  final serverName = client.userID?.domain;
  if (serverName == null) throw const NotSignedIn();
  final response = await client.httpClient.get(
    Uri.https(serverName, '/.well-known/matrix/client'),
  );
  if (response.statusCode == 404) throw NoCallServer(serverName);
  if (response.statusCode != 200) {
    throw WellKnownUnavailable(response.statusCode);
  }
  final foci = _object(response.body)?['org.matrix.msc4143.rtc_foci'];
  if (foci is List) {
    for (final focus in foci) {
      if (focus is! Map || focus['type'] != 'livekit') continue;
      final server = _address(focus['livekit_service_url'], const {
        'https',
        'http',
      });
      if (server != null) return server;
    }
  }
  throw NoCallServer(serverName);
}

/// This device's access to [roomId]'s call on [server].
Future<SfuAccess> sfuAccess(Client client, Uri server, String roomId) async {
  final userId = client.userID;
  final deviceId = client.deviceID;
  if (userId == null || deviceId == null) throw const NotSignedIn();
  // Single use: the call server spends it checking who is asking.
  final openId = await client.requestOpenIdToken(userId, {});
  final response = await client.httpClient.post(
    Uri(
      scheme: server.scheme,
      userInfo: server.userInfo,
      host: server.host,
      port: server.hasPort ? server.port : null,
      pathSegments: [
        ...server.pathSegments.where((segment) => segment.isNotEmpty),
        'sfu',
        'get',
      ],
    ),
    headers: {'content-type': 'application/json'},
    body: jsonEncode({
      'room': roomId,
      'openid_token': openId.toJson(),
      'device_id': deviceId,
    }),
  );
  final answer = _object(response.body);
  if (response.statusCode != 200) {
    final errcode = answer?['errcode'];
    throw CallServerError(
      response.statusCode,
      errcode is String ? errcode : null,
    );
  }
  final url = _address(answer?['url'], const {'wss', 'ws', 'https', 'http'});
  final jwt = answer?['jwt'];
  if (url == null || jwt is! String || jwt.isEmpty) {
    throw const CallServerMalformed();
  }
  return SfuAccess(url, jwt);
}

/// [body] as a JSON object, or null when it is anything else.
Map<String, Object?>? _object(String body) {
  try {
    final json = jsonDecode(body);
    return json is Map<String, Object?> ? json : null;
  } on FormatException {
    return null;
  }
}

/// [value] as an address with a host, in one of [schemes], or null.
Uri? _address(Object? value, Set<String> schemes) {
  if (value is! String) return null;
  final uri = Uri.tryParse(value.trim());
  if (uri == null || uri.host.isEmpty || !schemes.contains(uri.scheme)) {
    return null;
  }
  return uri;
}
