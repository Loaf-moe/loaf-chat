import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/model/updater.dart';

void main() {
  test('no updater is idle, and restarting it does nothing', () async {
    const updater = NoUpdater();
    updater.addListener(() => fail('it never changes'));
    await updater.restart();
    expect(updater.state, isA<UpdateIdle>());
  });

  test('a fake tells its listeners when its state is set', () {
    final updater = FakeUpdater();
    addTearDown(updater.dispose);
    var told = 0;
    updater.addListener(() => told++);
    updater.state = const UpdateReady('0.4.0');
    expect(told, 1);
    expect((updater.state as UpdateReady).version, '0.4.0');
  });

  test('restarting a fake is counted, and leaves it idle', () async {
    final updater = FakeUpdater(const UpdateReady('0.4.0'));
    addTearDown(updater.dispose);
    await updater.restart();
    expect(updater.restarts, 1);
    expect(updater.state, isA<UpdateIdle>());
  });
}
