import 'package:flutter_test/flutter_test.dart';
import 'package:tmpl_plugin/tmpl_plugin.dart';
import 'package:tmpl_plugin/tmpl_plugin_platform_interface.dart';
import 'package:tmpl_plugin/tmpl_plugin_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockTmplPluginPlatform
    with MockPlatformInterfaceMixin
    implements TmplPluginPlatform {
  @override
  Future<String?> getPlatformVersion() => Future.value('42');
}

void main() {
  final TmplPluginPlatform initialPlatform = TmplPluginPlatform.instance;

  test('$MethodChannelTmplPlugin is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelTmplPlugin>());
  });

  test('getPlatformVersion', () async {
    TmplPlugin tmplPlugin = TmplPlugin();
    MockTmplPluginPlatform fakePlatform = MockTmplPluginPlatform();
    TmplPluginPlatform.instance = fakePlatform;

    expect(await tmplPlugin.getPlatformVersion(), '42');
  });
}
