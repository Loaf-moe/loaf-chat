/// Windows toasts: Dart over `dart:ffi` into the Rust crate `rust/`, which
/// `hook/build.dart` builds as a DLL. Nothing here throws on a missing
/// DLL until [ToastNotifier] is made, so importing it is safe anywhere.
library;

import 'dart:async';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

const _asset = 'package:loaf_notify/loaf_notify_win.dart';

/// Called by Rust on a WinRT thread; `NativeCallable.listener` posts it to
/// the isolate. Both strings are Dart's to free.
typedef _ClickC = Void Function(Pointer<Utf8> roomId, Pointer<Utf8> eventId);

@Native<Pointer<Void> Function(Pointer<NativeFunction<_ClickC>>)>(
  symbol: 'loaf_notify_new',
  assetId: _asset,
)
external Pointer<Void> _new(Pointer<NativeFunction<_ClickC>> click);

@Native<Void Function(Pointer<Void>)>(
  symbol: 'loaf_notify_free',
  assetId: _asset,
)
external void _free(Pointer<Void> notifier);

@Native<Void Function(Pointer<Utf8>)>(
  symbol: 'loaf_notify_string_free',
  assetId: _asset,
)
external void _stringFree(Pointer<Utf8> s);

@Native<Int32 Function()>(symbol: 'loaf_notify_register', assetId: _asset)
external int _register();

@Native<
  Int32 Function(
    Pointer<Void>,
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Utf8>,
  )
>(symbol: 'loaf_notify_show', assetId: _asset)
external int _show(
  Pointer<Void> notifier,
  Pointer<Utf8> title,
  Pointer<Utf8> body,
  Pointer<Utf8> roomId,
  Pointer<Utf8> eventId,
  Pointer<Utf8> avatar,
);

@Native<Int32 Function(Pointer<Void>, Pointer<Utf8>)>(
  symbol: 'loaf_notify_withdraw',
  assetId: _asset,
)
external int _withdraw(Pointer<Void> notifier, Pointer<Utf8> roomId);

@Native<Int32 Function()>(symbol: 'loaf_notify_blocked', assetId: _asset)
external int _blocked();

/// The status for "no notifier": the DLL's `loaf_notify_new` failed.
const noNotifier = -4;

/// One Rust notifier. Methods return the DLL's status: 0 is fine, below 0
/// is a failure ([noNotifier] if there was never a notifier), and for
/// [blocked] 1 means the user blocked this app's toasts.
class ToastNotifier {
  /// Throws if the DLL isn't there (any OS but Windows).
  ToastNotifier() {
    _click = NativeCallable<_ClickC>.listener(_onClick);
    try {
      _handle = _new(_click.nativeFunction);
    } on Object {
      // No DLL: don't leave a listener keeping the isolate alive.
      _click.close();
      rethrow;
    }
  }

  late final NativeCallable<_ClickC> _click;
  late Pointer<Void> _handle;
  final _clicks = StreamController<(String, String)>.broadcast();

  /// `(roomId, eventId)` of each clicked toast.
  Stream<(String, String)> get clicks => _clicks.stream;

  // Asynchronous, so the strings are copied here and handed back.
  void _onClick(Pointer<Utf8> room, Pointer<Utf8> event) {
    final click = (room.toDartString(), event.toDartString());
    _stringFree(room);
    _stringFree(event);
    if (!_clicks.isClosed) _clicks.add(click);
  }

  /// Registers the app's name and icon with Windows.
  int register() => _register();

  int show({
    required String title,
    required String body,
    required String roomId,
    required String eventId,
    String? avatarPath,
  }) {
    if (_handle == nullptr) return noNotifier;
    return using((arena) {
      return _show(
        _handle,
        title.toNativeUtf8(allocator: arena),
        body.toNativeUtf8(allocator: arena),
        roomId.toNativeUtf8(allocator: arena),
        eventId.toNativeUtf8(allocator: arena),
        avatarPath == null
            ? nullptr
            : avatarPath.toNativeUtf8(allocator: arena),
      );
    });
  }

  int withdraw(String roomId) {
    if (_handle == nullptr) return noNotifier;
    return using((arena) {
      return _withdraw(_handle, roomId.toNativeUtf8(allocator: arena));
    });
  }

  int blocked() => _blocked();

  /// Frees the notifier, which first switches its click callback off (so
  /// once that returns no new call begins, even from a toast still in
  /// Action Center), then closes the listener. A click already posted to
  /// the isolate when `close()` runs is dropped, and its two strings leak.
  void dispose() {
    if (_handle != nullptr) _free(_handle);
    _handle = nullptr;
    _click.close();
    unawaited(_clicks.close());
  }
}
