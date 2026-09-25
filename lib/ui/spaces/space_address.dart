/// Reading a space's address out of whatever someone pasted.
library;

/// `localpart:server`, with the server allowed a port.
final _addressBody = RegExp(r'^[^\s:#!@]+:[A-Za-z0-9.\-]+(:\d+)?$');

/// The alias (`#bakers:loaf.moe`) or room id (`!abc:loaf.moe`) in [input],
/// or null if it is not one yet. Accepts an alias with or without its `#`,
/// and matrix.to links, encoded or not. Anything else — a user id, a bare
/// word, another site's link — is not a space address.
String? parseSpaceAddress(String input) {
  var text = input.trim();
  final link = RegExp(
    r'^(?:https?://)?matrix\.to/#/(.+)$',
    caseSensitive: false,
  ).firstMatch(text);
  if (link != null) {
    // Links carry routing hints (?via=…) that are not part of the address.
    text = Uri.decodeComponent(link.group(1)!.split('?').first);
  } else if (text.contains('/')) {
    return null;
  }

  final sigil = text.isEmpty ? '' : text[0];
  if (sigil == '@') return null;
  if (sigil == '#' || sigil == '!') {
    return _addressBody.hasMatch(text.substring(1)) ? text : null;
  }
  return _addressBody.hasMatch(text) ? '#$text' : null;
}
