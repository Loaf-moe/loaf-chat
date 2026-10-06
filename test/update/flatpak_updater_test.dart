import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/model/updater.dart';
import 'package:loaf_native/update/flatpak_portal.dart';
import 'package:loaf_native/update/flatpak_updater.dart';

class _Portal implements FlatpakPortal {
  int portalVersion = 2;
  bool missing = false;
  final commits = StreamController<UpdateCommits>();
  int updates = 0;
  int spawns = 0;
  Completer<bool> installing = Completer();
  Object? spawnFails;

  @override
  Future<int> version() async =>
      missing ? throw StateError('no portal') : portalVersion;

  @override
  Stream<UpdateCommits> watch() => commits.stream;

  @override
  Future<bool> update() {
    updates++;
    return installing.future;
  }

  @override
  Future<void> spawnLatest() async {
    if (spawnFails != null) throw spawnFails!;
    spawns++;
  }

  @override
  Future<void> close() async {}
}

const _installedAlready = UpdateCommits(running: 'a', local: 'b', remote: 'b');
const _onTheRemote = UpdateCommits(running: 'a', local: 'a', remote: 'b');
const _nothing = UpdateCommits(running: 'a', local: 'a', remote: 'a');

Future<void> _turn() => Future<void>.delayed(Duration.zero);

void main() {
  late _Portal portal;
  var quits = 0;
  String? feedVersion;

  Future<FlatpakUpdater> started() async {
    final u = FlatpakUpdater(
      portal: portal,
      version: () async => feedVersion,
      quit: () => quits++,
    );
    addTearDown(u.dispose);
    await u.start();
    return u;
  }

  setUp(() {
    portal = _Portal();
    quits = 0;
    feedVersion = '0.1.2';
  });

  test('a build the system already installed is ready at once', () async {
    final u = await started();
    portal.commits.add(_installedAlready);
    await _turn();
    expect((u.state as UpdateReady).version, '0.1.2');
    expect(portal.updates, 0);
  });

  test('a build on the remote is installed, then ready', () async {
    final u = await started();
    portal.commits.add(_onTheRemote);
    await _turn();
    expect(u.state, isA<UpdatePreparing>());
    expect(portal.updates, 1);
    portal.installing.complete(true);
    await _turn();
    expect((u.state as UpdateReady).version, '0.1.2');
  });

  test('the same update said twice is installed once', () async {
    final u = await started();
    portal.commits
      ..add(_onTheRemote)
      ..add(_onTheRemote);
    await _turn();
    portal.commits.add(_onTheRemote);
    await _turn();
    expect(portal.updates, 1);
    portal.installing.complete(true);
    await _turn();
    portal.commits.add(_installedAlready);
    await _turn();
    expect(portal.updates, 1);
    expect(u.state, isA<UpdateReady>());
  });

  test('an install the portal fails or refuses goes back to idle', () async {
    final u = await started();
    portal.commits.add(_onTheRemote);
    await _turn();
    portal.installing.completeError(StateError('NotSupported'));
    await _turn();
    expect(u.state, isA<UpdateIdle>());
  });

  test('matching commits are not an update', () async {
    final u = await started();
    portal.commits.add(_nothing);
    await _turn();
    expect(u.state, isA<UpdateIdle>());
  });

  test('without the feed it is ready with no version', () async {
    feedVersion = null;
    final u = await started();
    portal.commits.add(_installedAlready);
    await _turn();
    expect((u.state as UpdateReady).version, isNull);
  });

  test('a version lookup that throws is ready with no version', () async {
    final u = FlatpakUpdater(
      portal: portal,
      version: () async => throw StateError('offline'),
      quit: () => quits++,
    );
    addTearDown(u.dispose);
    await u.start();
    portal.commits.add(_installedAlready);
    await _turn();
    expect((u.state as UpdateReady).version, isNull);
  });

  test('a portal older than version 2 is never watched', () async {
    portal.portalVersion = 1;
    final u = await started();
    expect(portal.commits.hasListener, isFalse);
    expect(u.state, isA<UpdateIdle>());
  });

  test('no portal at all is just idle', () async {
    portal.missing = true;
    final u = await started();
    expect(portal.commits.hasListener, isFalse);
    expect(u.state, isA<UpdateIdle>());
  });

  test('restarting spawns the latest build and quits', () async {
    final u = await started();
    portal.commits.add(_installedAlready);
    await _turn();
    await u.restart();
    expect(portal.spawns, 1);
    expect(quits, 1);
    expect(u.state, isA<UpdateApplying>());
  });

  test('a spawn that fails leaves the update ready', () async {
    final u = await started();
    portal.commits.add(_installedAlready);
    await _turn();
    portal.spawnFails = StateError('no');
    await u.restart();
    expect(quits, 0);
    expect(u.state, isA<UpdateReady>());
  });

  group('a check by hand', () {
    test('is offered only once the portal is watched', () async {
      final u = FlatpakUpdater(portal: portal, version: () async => null);
      addTearDown(u.dispose);
      expect(u.canCheck, isFalse);
      await u.start();
      expect(u.canCheck, isTrue);
    });

    test('is not offered without a portal', () async {
      portal.missing = true;
      expect((await started()).canCheck, isFalse);
    });

    test('asks the portal to update, and is ready once it has', () async {
      final u = await started();
      final result = u.check();
      expect(u.state, isA<UpdatePreparing>());
      portal.installing.complete(true);
      expect(await result, UpdateCheck.ready);
      expect((u.state as UpdateReady).version, '0.1.2');
    });

    test('nothing to install is up to date', () async {
      final u = await started();
      final result = u.check();
      portal.installing.complete(false);
      expect(await result, UpdateCheck.upToDate);
      expect(u.state, isA<UpdateIdle>());
    });

    test('a refusal is a failure, back to idle', () async {
      final u = await started();
      final result = u.check();
      portal.installing.completeError(StateError('NotSupported'));
      expect(await result, UpdateCheck.failed);
      expect(u.state, isA<UpdateIdle>());
    });

    test('while the portal is already installing, waits on that', () async {
      final u = await started();
      portal.commits.add(_onTheRemote);
      await _turn();
      final result = u.check();
      portal.installing.complete(true);
      expect(await result, UpdateCheck.ready);
      expect(portal.updates, 1);
    });

    test('a portal saying nothing new is idle, not ready', () async {
      final u = await started();
      portal.commits.add(_onTheRemote);
      await _turn();
      portal.installing.complete(false);
      await _turn();
      expect(u.state, isA<UpdateIdle>());
    });
  });
}
