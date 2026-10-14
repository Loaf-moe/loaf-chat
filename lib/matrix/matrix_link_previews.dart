/// What the links in messages lead to, as the homeserver tells it: the
/// homeserver fetches the page, so the page's site never sees this device.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';

import '../ui/model/link_previews.dart';
import 'matrix_avatar_images.dart';

/// How long a link that got no answer goes unasked.
const _hold = Duration(minutes: 1);

class MatrixLinkPreviews implements LinkPreviews {
  MatrixLinkPreviews(this.client, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final Client client;
  final DateTime Function() _now;

  final _known = <Uri, ValueNotifier<LinkPreviewState>>{};

  /// Links that got no answer, and when each may be asked about again.
  final _heldUntil = <Uri, DateTime>{};

  Future<bool>? _serverPreviews;
  var _disposed = false;

  @override
  ValueListenable<LinkPreviewState> of(Uri link) {
    if (_disposed) return ValueNotifier(const LinkPreviewNone());
    final known = _known[link];
    if (known == null) {
      final state = _known[link] = ValueNotifier(const LinkPreviewLoading());
      unawaited(_ask(link, state));
      return state;
    }
    final held = _heldUntil[link];
    if (held != null && !_now().isBefore(held)) {
      _heldUntil.remove(link);
      unawaited(_ask(link, known));
    }
    return known;
  }

  /// Rows already listening hear of each change, so nothing here changes
  /// [state] before the first await: [of] is called while rows build.
  Future<void> _ask(Uri link, ValueNotifier<LinkPreviewState> state) async {
    PreviewForUrl? reply;
    try {
      final previews = await (_serverPreviews ??= _askServer());
      if (_disposed) return;
      if (!previews) {
        state.value = const LinkPreviewNone();
        return;
      }
      state.value = const LinkPreviewLoading();
      reply = await client.getUrlPreview(link);
    } on MatrixException catch (e) {
      // Any other refusal is the server's last word on the link.
      if (e.error == MatrixError.M_LIMIT_EXCEEDED) _heldUntil[link] = _later;
    } on TypeError {
      // The SDK casts the reply's fields without checking them.
    } on Exception {
      // No answer, or one that is not the homeserver's: a proxy's page.
      _heldUntil[link] = _later;
    } catch (_) {
      if (!_disposed) state.value = const LinkPreviewNone();
      rethrow;
    }
    if (_disposed) return;
    final preview = reply == null ? null : _read(reply);
    state.value = preview == null
        ? const LinkPreviewNone()
        : LinkPreviewReady(preview);
  }

  DateTime get _later => _now().add(_hold);

  /// Whether the server previews anything. Only a server that says it does
  /// not is believed: one that says nothing of it may well.
  Future<bool> _askServer() async {
    try {
      final said = (await client.getCapabilities())
          .additionalProperties['io.element.msc4452.preview_url'];
      return !(said is Map && said['enabled'] == false);
    } on Exception {
      return true;
    } on TypeError {
      return true;
    }
  }

  LinkPreview? _read(PreviewForUrl reply) {
    final title = reply.additionalProperties['og:title'];
    final description = reply.additionalProperties['og:description'];
    final image = reply.ogImage;
    return LinkPreview.of(
      title: title is String ? title : null,
      description: description is String ? description : null,
      image: image != null && image.isScheme('mxc')
          ? MxcImage(client, image, size: timelineBuckets.first)
          : null,
    );
  }

  /// Answers still on their way are dropped. The states stay as they are:
  /// rows may still be listening.
  void dispose() => _disposed = true;
}
