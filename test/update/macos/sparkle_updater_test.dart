import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/update/macos/sparkle.g.dart';
import 'package:loaf_native/update/macos/sparkle_updater.dart';
import 'package:loaf_native/update/updater.dart';

/// Sparkle's bridge, as Dart sees it.
class _Host extends SparkleHost {
  final calls = <String>[];

  /// What [check] answers with.
  Future<SparkleCheck> Function() answer = () async => SparkleCheck.upToDate;

  /// Thrown by every call, as if the native side refused.
  Object? fails;

  Future<void> _call(String name) async {
    calls.add(name);
    if (fails case final error?) throw error;
  }

  @override
  Future<void> start() => _call('start');

  @override
  Future<SparkleCheck> check() async {
    await _call('check');
    return answer();
  }

  @override
  Future<void> restart() => _call('restart');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late _Host host;

  /// What the Swift side would send, down the channel it sends on.
  Future<void> native(String event, [List<Object?>? args]) =>
      messenger.handlePlatformMessage(
        'dev.flutter.pigeon.loaf_native.SparkleEvents.$event',
        SparkleEvents.pigeonChannelCodec.encodeMessage(args),
        (_) {},
      );

  setUp(() => host = _Host());

  SparkleUpdater updater() {
    final u = SparkleUpdater(host: host);
    addTearDown(u.dispose);
    return u;
  }

  test('it starts the native updater once it is listening', () async {
    updater();
    await Future<void>.delayed(Duration.zero);
    expect(host.calls, ['start']);
  });

  test('native events become update states', () async {
    final u = updater();
    await native('preparing');
    expect(u.state, isA<UpdatePreparing>());
    await native('ready', ['0.1.2']);
    expect((u.state as UpdateReady).version, '0.1.2');
    await native('idle');
    expect(u.state, isA<UpdateIdle>());
  });

  test('ready may come without a version', () async {
    final u = updater();
    await native('ready', [null]);
    expect((u.state as UpdateReady).version, isNull);
  });

  test('restart is passed on only when ready', () async {
    final u = updater();
    await u.restart(const UpdateReady('0.1.2'));
    expect(host.calls, isNot(contains('restart')));
    await native('ready', ['0.1.2']);
    await u.restart(u.state as UpdateReady);
    expect(host.calls, contains('restart'));
    expect((u.state as UpdateApplying).version, '0.1.2');
  });

  test('a restart the native side refuses leaves it ready', () async {
    final u = updater();
    await native('ready', ['0.1.2']);
    host.fails = PlatformException(code: 'not-ready');
    await u.restart(u.state as UpdateReady);
    expect(u.state, isA<UpdateReady>());
  });

  test('no native side at all is just idle', () async {
    final u = SparkleUpdater();
    addTearDown(u.dispose);
    await Future<void>.delayed(Duration.zero);
    expect(u.state, isA<UpdateIdle>());
    expect(u.canCheck, isFalse);
  });

  test('an event arriving after dispose is dropped', () async {
    final u = SparkleUpdater(host: host);
    u.dispose();
    await native('ready', ['0.1.2']);
    expect(u.state, isA<UpdateIdle>());
  });

  group('a check by hand', () {
    test('is offered once Sparkle has started', () async {
      final u = updater();
      expect(u.canCheck, isFalse);
      await Future<void>.delayed(Duration.zero);
      expect(u.canCheck, isTrue);
    });

    test('is not offered when Sparkle did not start', () async {
      host.fails = PlatformException(code: 'no');
      final u = updater();
      await Future<void>.delayed(Duration.zero);
      expect(u.canCheck, isFalse);
    });

    test('nothing newer is up to date', () async {
      host.answer = () async => SparkleCheck.upToDate;
      expect(await updater().check(), UpdateCheck.upToDate);
      expect(host.calls, contains('check'));
    });

    test('a find waits for the download, then is ready', () async {
      host.answer = () async => SparkleCheck.found;
      final u = updater();
      final result = u.check();
      await Future<void>.delayed(Duration.zero);
      expect(u.state, isA<UpdatePreparing>());
      await native('ready', ['0.1.2']);
      expect(await result, UpdateCheck.ready);
    });

    test('a find whose download fails is a failure', () async {
      host.answer = () async => SparkleCheck.found;
      final u = updater();
      final result = u.check();
      await Future<void>.delayed(Duration.zero);
      await native('idle');
      expect(await result, UpdateCheck.failed);
    });

    test('a find already staged answers at once', () async {
      host.answer = () async => SparkleCheck.found;
      final u = updater();
      await native('ready', ['0.1.2']);
      expect(await u.check(), UpdateCheck.ready);
      expect(host.calls, isNot(contains('check')));
    });

    test('Sparkle failing is a failure', () async {
      host.answer = () async => SparkleCheck.failed;
      expect(await updater().check(), UpdateCheck.failed);
    });

    test('no answer from the native side is a failure', () async {
      host.answer = () async => throw PlatformException(code: 'no');
      expect(await updater().check(), UpdateCheck.failed);
    });

    test('a dispose mid-check does not leave it hanging', () async {
      host.answer = () async => SparkleCheck.found;
      final u = SparkleUpdater(host: host);
      final result = u.check();
      await Future<void>.delayed(Duration.zero);
      u.dispose();
      expect(await result, UpdateCheck.failed);
    });
  });
}
