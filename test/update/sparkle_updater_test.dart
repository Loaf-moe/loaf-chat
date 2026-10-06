import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/model/updater.dart';
import 'package:loaf_native/update/sparkle_updater.dart';

const _channel = MethodChannel('moe.loaf.chat/updater');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <String>[];

  /// What the Swift side would send.
  Future<void> native(String state, [String? version]) =>
      messenger.handlePlatformMessage(
        _channel.name,
        _channel.codec.encodeMethodCall(
          MethodCall('state', {'state': state, 'version': version}),
        ),
        (_) {},
      );

  setUp(() {
    calls.clear();
    messenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call.method);
      return null;
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(_channel, null));

  SparkleUpdater updater() {
    final u = SparkleUpdater();
    addTearDown(u.dispose);
    return u;
  }

  test('it starts the native updater once it is listening', () async {
    updater();
    await Future<void>.delayed(Duration.zero);
    expect(calls, ['start']);
  });

  test('native states become update states', () async {
    final u = updater();
    await native('preparing');
    expect(u.state, isA<UpdatePreparing>());
    await native('ready', '0.1.2');
    expect((u.state as UpdateReady).version, '0.1.2');
    await native('idle');
    expect(u.state, isA<UpdateIdle>());
  });

  test('a state it does not know is idle', () async {
    final u = updater();
    await native('ready', '0.1.2');
    await native('something new');
    expect(u.state, isA<UpdateIdle>());
  });

  test('restart is passed on only when ready', () async {
    final u = updater();
    await u.restart();
    expect(calls, isNot(contains('restart')));
    await native('ready', '0.1.2');
    await u.restart();
    expect(calls, contains('restart'));
    expect((u.state as UpdateApplying).version, '0.1.2');
  });

  test('a restart the native side refuses leaves it ready', () async {
    final u = updater();
    await native('ready', '0.1.2');
    messenger.setMockMethodCallHandler(
      _channel,
      (_) async => throw PlatformException(code: 'no'),
    );
    await u.restart();
    expect(u.state, isA<UpdateReady>());
  });

  test('no native side at all is just idle', () async {
    messenger.setMockMethodCallHandler(_channel, null);
    final u = updater();
    await Future<void>.delayed(Duration.zero);
    expect(u.state, isA<UpdateIdle>());
  });

  test('a state arriving after dispose is dropped', () async {
    final u = SparkleUpdater();
    u.dispose();
    await native('ready', '0.1.2');
    expect(u.state, isA<UpdateIdle>());
  });

  group('a check by hand', () {
    /// Answers `check` with [answer]; everything else as before.
    void answering(Object? Function() answer) =>
        messenger.setMockMethodCallHandler(_channel, (call) async {
          calls.add(call.method);
          return call.method == 'check' ? answer() : null;
        });

    test('is offered once Sparkle has started', () async {
      final u = updater();
      expect(u.canCheck, isFalse);
      await Future<void>.delayed(Duration.zero);
      expect(u.canCheck, isTrue);
    });

    test('is not offered when Sparkle did not start', () async {
      messenger.setMockMethodCallHandler(
        _channel,
        (_) async => throw PlatformException(code: 'no'),
      );
      final u = updater();
      await Future<void>.delayed(Duration.zero);
      expect(u.canCheck, isFalse);
    });

    test('nothing newer is up to date', () async {
      answering(() => 'upToDate');
      expect(await updater().check(), UpdateCheck.upToDate);
      expect(calls, contains('check'));
    });

    test('a find waits for the download, then is ready', () async {
      answering(() => 'found');
      final u = updater();
      final result = u.check();
      await Future<void>.delayed(Duration.zero);
      expect(u.state, isA<UpdatePreparing>());
      await native('ready', '0.1.2');
      expect(await result, UpdateCheck.ready);
    });

    test('a find whose download fails is a failure', () async {
      answering(() => 'found');
      final u = updater();
      final result = u.check();
      await Future<void>.delayed(Duration.zero);
      await native('idle');
      expect(await result, UpdateCheck.failed);
    });

    test('a find already staged answers at once', () async {
      answering(() => 'found');
      final u = updater();
      await native('ready', '0.1.2');
      expect(await u.check(), UpdateCheck.ready);
      expect(calls, isNot(contains('check')));
    });

    test('Sparkle failing is a failure', () async {
      answering(() => 'failed');
      expect(await updater().check(), UpdateCheck.failed);
    });

    test('no answer from the native side is a failure', () async {
      answering(() => throw PlatformException(code: 'no'));
      expect(await updater().check(), UpdateCheck.failed);
    });

    test('a dispose mid-check does not leave it hanging', () async {
      answering(() => 'found');
      final u = SparkleUpdater();
      final result = u.check();
      await Future<void>.delayed(Duration.zero);
      u.dispose();
      expect(await result, UpdateCheck.failed);
    });
  });
}
