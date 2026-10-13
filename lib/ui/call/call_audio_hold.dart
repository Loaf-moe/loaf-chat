/// Says when a call has the device's audio and when it lets go, for the
/// inline videos: on iOS the two share one audio session, and a video that
/// took it for playback, or gave it up, would take the call's sound with it.
library;

import 'calls.dart';

class CallAudioHold {
  CallAudioHold(this._calls, {required this._hold}) {
    _onChange();
    _calls.addListener(_onChange);
  }

  final Calls _calls;
  final void Function(bool held) _hold;
  var _held = false;

  void _onChange() {
    final held = _calls.inCall;
    if (held == _held) return;
    _held = held;
    _hold(held);
  }

  void dispose() => _calls.removeListener(_onChange);
}
