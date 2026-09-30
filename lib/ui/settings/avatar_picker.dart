/// Choosing a picture for your profile, and getting it to a size a homeserver
/// and every avatar in the app can carry.
library;

import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';

/// The platform's own picker. Null when nothing was chosen.
Future<Uint8List?> pickAvatarBytes() async {
  // PHPicker on iOS 14+; the only route to the native picker there.
  if (defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.android) {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      // PHPicker needs no permission; this keeps the plugin from asking.
      requestFullMetadata: false,
    );
    return picked?.readAsBytes();
  }
  final file = await openFile(
    acceptedTypeGroups: const [
      XTypeGroup(
        label: 'pictures',
        extensions: ['png', 'jpg', 'jpeg', 'gif', 'webp', 'heic'],
        uniformTypeIdentifiers: ['public.image'],
      ),
    ],
  );
  return file?.readAsBytes();
}

/// Long side at most [max] px, re-encoded as PNG. Only ever shrinks, and the
/// shorter side follows so the picture keeps its shape.
Future<Uint8List> shrinkToPng(Uint8List bytes, {int max = 512}) async {
  // A first look, at full size, to learn which side is the long one.
  final probe = await ui.instantiateImageCodec(bytes);
  final first = (await probe.getNextFrame()).image;
  final width = first.width;
  final height = first.height;
  first.dispose();
  probe.dispose();

  final ui.Codec codec;
  if (width <= max && height <= max) {
    codec = await ui.instantiateImageCodec(bytes);
  } else if (width >= height) {
    codec = await ui.instantiateImageCodec(bytes, targetWidth: max);
  } else {
    codec = await ui.instantiateImageCodec(bytes, targetHeight: max);
  }
  final image = (await codec.getNextFrame()).image;
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) throw StateError('could not encode the picture');
    return data.buffer.asUint8List();
  } finally {
    image.dispose();
    codec.dispose();
  }
}
