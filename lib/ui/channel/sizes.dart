/// File sizes as people read them, and what is said when a file is too big
/// to send. Shared by the composer, which can tell before anything is read,
/// and the Matrix timeline, which hears it from the server.
library;

/// Bytes as Finder says them: 1000s, one decimal at most.
String formatSize(int bytes) {
  String one(double n) {
    final s = n.toStringAsFixed(1);
    return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
  }

  if (bytes < 1000) return '$bytes B';
  if (bytes < 1000000) return '${one(bytes / 1000)} KB';
  return '${one(bytes / 1000000)} MB';
}

/// Why [name] won't send: its [size] against the server's [limit], or,
/// where the server (or a proxy before it) refused without saying a limit,
/// just that it was too big.
String tooBigToSend(String name, int size, int? limit) => limit == null
    ? '$name (${formatSize(size)}) is too big for this server'
    : "$name is ${formatSize(size)}, over this server's ${formatSize(limit)} limit";
