/// One unread message: its id, when it was sent (ms since epoch), whether
/// it mentions you, and whether it was still encrypted when counted, so it
/// can be looked at again once its key arrives.
class TallyEntry {
  const TallyEntry(
    this.id,
    this.ts, {
    this.mention = false,
    this.locked = false,
  });

  final String id;
  final int ts;
  final bool mention;
  final bool locked;

  List<Object> toJson() => [
    id,
    ts,
    if (mention || locked) mention,
    if (locked) locked,
  ];

  factory TallyEntry.fromJson(List<Object?> json) => TallyEntry(
    json[0]! as String,
    json[1]! as int,
    mention: json.length > 2 && json[2] == true,
    locked: json.length > 3 && json[3] == true,
  );
}

/// A room's unread messages, oldest first: every message from someone
/// else after your read receipt. At most [cap] are kept. Past that the
/// oldest drop and [capped] says there were more, which the badge shows as
/// `99+`.
class RoomTally {
  RoomTally({List<TallyEntry> entries = const [], this.capped = false})
    : _entries = [...entries];

  static const cap = 99;

  final List<TallyEntry> _entries;

  /// More unread messages than [cap] came before the first entry.
  bool capped;

  /// [cap] + 1 when capped: a number the badge draws as `99+`.
  int get count => capped ? cap + 1 : _entries.length;

  int get mentions => _entries.where((e) => e.mention).length;

  bool get isEmpty => _entries.isEmpty && !capped;

  List<TallyEntry> get entries => List.unmodifiable(_entries);

  void add(TallyEntry entry) {
    if (_entries.any((e) => e.id == entry.id)) return;
    _entries.add(entry);
    if (_entries.length > cap) {
      _entries.removeAt(0);
      capped = true;
    }
  }

  /// Your receipt is on [eventId], placed at [ts]. A counted event reads it
  /// and everything before it. An event never counted (a reaction, your
  /// own message, something read on another device) reads by time:
  /// whatever was sent by then. Whether anything changed.
  bool readUpTo(String eventId, int ts) {
    final before = _entries.length;
    final at = _entries.indexWhere((e) => e.id == eventId);
    if (at >= 0) {
      _entries.removeRange(0, at + 1);
    } else {
      _entries.removeWhere((e) => e.ts <= ts);
    }
    // The receipt landed inside what is counted, so nothing older is unread
    // any more. With nothing counted at all it is newer than everything.
    final uncapped = capped && (_entries.length != before || _entries.isEmpty);
    if (uncapped) capped = false;
    return _entries.length != before || uncapped;
  }

  void clear() {
    _entries.clear();
    capped = false;
  }

  /// A message deleted while unread. Whether it was counted.
  bool remove(String eventId) {
    final before = _entries.length;
    _entries.removeWhere((e) => e.id == eventId);
    return _entries.length != before;
  }

  /// Swaps the entry with [entry]'s id for [entry], in place. Whether there
  /// was one.
  bool replace(TallyEntry entry) {
    final at = _entries.indexWhere((e) => e.id == entry.id);
    if (at < 0) return false;
    _entries[at] = entry;
    return true;
  }

  Map<String, Object?> toJson() => {
    'e': [for (final e in _entries) e.toJson()],
    if (capped) 'capped': true,
  };

  factory RoomTally.fromJson(Map<String, Object?> json) => RoomTally(
    entries: [
      for (final e in json['e'] as List? ?? const [])
        TallyEntry.fromJson((e as List).cast<Object?>()),
    ],
    capped: json['capped'] == true,
  );
}
