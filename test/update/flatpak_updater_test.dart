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
  Completer<void> installing = Completer();
  Object? spawnFails;

  @override
  Future<int> version() async =>
      missing ? throw StateError('no portal') : portalVersion;

  @override
  Stream<UpdateCommits> watch() => commits.stream;

  @override
  Future<void> update() {
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
    portal.installing.complete();
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
    portal.installing.complete();
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
}
