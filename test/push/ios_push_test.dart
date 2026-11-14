// The iOS end of `moe.loaf.chat/notify`. The native side is
// ios/Runner/NotifyBridge.swift; these pin the contract between them, so a
// rename on either side fails here rather than silently stopping pushes.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/push/ios_push.dart';
import 'package:loaf_native/ui/model/message_route.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('moe.loaf.chat/notify');
  final calls = <MethodCall>[];
  Object? Function(MethodCall)? answer;

  void mock(bool on) => TestDefaultBinaryMessengerBinding
      .instance
      .defaultBinaryMessenger
      .setMockMethodCallHandler(
        channel,
        on
            ? (call) async {
                calls.add(call);
                return answer?.call(call);
              }
            : null,
      );

  setUp(() {
    calls.clear();
    answer = null;
    mock(true);
  });
  tearDown(() => mock(false));

  Future<void> fromNative(String method, Object? args) =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            channel.name,
            const StandardMethodCodec().encodeMethodCall(
              MethodCall(method, args),
            ),
            (_) {},
          );

  test('a click arrives as the message it was about', () async {
    final push = IosPush();
    final first = push.clicks.first;
    await fromNative('click', {'roomId': '!r:x', 'eventId': r'$e'});
    expect(await first, const MessageRoute('!r:x', r'$e'));
  });

  test('listening tells the native end someone is', () async {
    // A tap can launch the app before Dart listens; the native side holds
    // it until this says otherwise.
    IosPush().clicks.listen((_) {});
    await pumpEventQueue();
    expect(calls.map((c) => c.method), contains('ready'));
  });

  test('withdraw names the room and the moment', () async {
    await IosPush().withdraw(
      '!r',
      before: DateTime.fromMillisecondsSinceEpoch(5),
    );
    expect(calls.single.method, 'withdraw');
    expect(calls.single.arguments, {'roomId': '!r', 'before': 5});
  });

  test('withdraw without a moment takes back everything', () async {
    await IosPush().withdraw('!r');
    expect(calls.single.arguments, {'roomId': '!r', 'before': null});
  });

  test('a token comes back as the native end gives it', () async {
    answer = (c) => c.method == 'pushToken' ? 'ab12' : null;
    expect(await IosPush().pushToken(), 'ab12');
  });

  test('no native end is no token, not a crash', () async {
    mock(false);
    expect(await IosPush().pushToken(), isNull);
  });
}
