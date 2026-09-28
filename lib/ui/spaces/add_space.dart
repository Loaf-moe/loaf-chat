/// What the rail's "+" opens: join a space by its address, find one in a
/// server's public directory, or make your own. Anything you would join is
/// previewed first, the way an invite is.
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../model/models.dart';
import '../platform.dart';
import '../rooms/rooms.dart' show SpaceNotFound;
import '../theme/loaf_theme.dart';
import '../widgets/adaptive_panel.dart';
import '../widgets/loaf_button.dart';
import 'space_address.dart';
import 'space_directory.dart';

/// What the panel asks the shell to do.
sealed class AddSpaceResult {
  const AddSpaceResult();
}

/// Join this space: add it to the rail and open it.
class JoinSpace extends AddSpaceResult {
  const JoinSpace(this.space);
  final Space space;
}

/// You are already in it: just go there.
class OpenSpace extends AddSpaceResult {
  const OpenSpace(this.id);
  final String id;
}

/// Make a new space with this name, `#general` and a voice channel.
class CreateSpace extends AddSpaceResult {
  const CreateSpace(this.name);
  final String name;
}

Future<AddSpaceResult?> showAddSpace(
  BuildContext context, {
  required Set<String> joined,
  required SpaceDirectory directory,
}) => showAdaptivePanel(
  context,
  maxHeight: 620,
  child: AddSpacePanel(joined: joined, directory: directory),
);

enum _Step { menu, link, explore, preview, create }

class AddSpacePanel extends StatefulWidget {
  const AddSpacePanel({
    super.key,
    required this.joined,
    required this.directory,
  });

  /// Ids of the spaces you are in, which open rather than join.
  final Set<String> joined;

  /// Where a server's public spaces and a typed address are looked up.
  final SpaceDirectory directory;

  @override
  State<AddSpacePanel> createState() => _AddSpacePanelState();
}

class _AddSpacePanelState extends State<AddSpacePanel> {
  static const _servers = ['loaf.moe', 'matrix.org'];

  var _step = _Step.menu;

  /// Where the preview was reached from, for its back arrow.
  var _previewFrom = _Step.explore;
  SpacePreview? _previewing;

  final _link = TextEditingController();
  final _search = TextEditingController();
  final _name = TextEditingController();
  final _otherServer = TextEditingController();
  var _server = 'loaf.moe';
  var _typingServer = false;

  /// Each server's public spaces, fetched once and kept until retried.
  final _exploreSnapshots = <String, AsyncSnapshot<List<SpacePreview>>>{};

  /// The address the latest lookup was for, so a slow earlier answer for an
  /// address you have since edited away from can't overwrite a later one.
  String? _linkFor;
  AsyncSnapshot<SpacePreview>? _linkSnapshot;

  @override
  void initState() {
    super.initState();
    _link.addListener(_onLinkChanged);
    for (final c in [_search, _name, _otherServer]) {
      c.addListener(() => setState(() {}));
    }
  }

  @override
  void dispose() {
    for (final c in [_link, _search, _name, _otherServer]) {
      c.dispose();
    }
    super.dispose();
  }

  /// A lookup only fires once the text is a complete address; a partial
  /// one (or the same address already looked up) shows whatever it showed
  /// before.
  void _onLinkChanged() => setState(() {
    final address = parseSpaceAddress(_link.text);
    if (address != null && address != _linkFor) _lookUp(address);
  });

  void _lookUp(String address) {
    _linkFor = address;
    setState(() => _linkSnapshot = const AsyncSnapshot.waiting());
    widget.directory
        .lookUp(address)
        .then(
          (preview) {
            if (!mounted || _linkFor != address) return;
            setState(
              () => _linkSnapshot = AsyncSnapshot.withData(
                ConnectionState.done,
                preview,
              ),
            );
          },
          onError: (Object error) {
            if (!mounted || _linkFor != address) return;
            setState(
              () => _linkSnapshot = AsyncSnapshot.withError(
                ConnectionState.done,
                error,
              ),
            );
          },
        );
  }

  /// Kicks off a server's directory once, folding a mock's synchronous
  /// answer straight into the map so it shows with no extra frame: only an
  /// answer that truly arrives later triggers a rebuild.
  void _loadServer(String server) {
    if (_exploreSnapshots.containsKey(server)) return;
    _exploreSnapshots[server] = const AsyncSnapshot.waiting();
    var settledSync = true;
    widget.directory
        .publicSpaces(server)
        .then(
          (spaces) {
            _exploreSnapshots[server] = AsyncSnapshot.withData(
              ConnectionState.done,
              spaces,
            );
            if (!settledSync && mounted) setState(() {});
          },
          onError: (Object error) {
            _exploreSnapshots[server] = AsyncSnapshot.withError(
              ConnectionState.done,
              error,
            );
            if (!settledSync && mounted) setState(() {});
          },
        );
    settledSync = false;
  }

  void _retryExplore(String server) => setState(() {
    _exploreSnapshots.remove(server);
    _loadServer(server);
  });

  void _go(_Step step) => setState(() => _step = step);

  void _back() => _go(switch (_step) {
    _Step.preview => _previewFrom,
    _ => _Step.menu,
  });

  void _preview(SpacePreview entry) => setState(() {
    _previewing = entry;
    _previewFrom = _step;
    _step = _Step.preview;
  });

  /// Join, or open if you are already in it.
  void _choose(SpacePreview entry) => Navigator.pop(
    context,
    widget.joined.contains(entry.space.id)
        ? OpenSpace(entry.space.id)
        : JoinSpace(entry.space),
  );

  @override
  Widget build(BuildContext context) {
    final (title, body) = switch (_step) {
      _Step.menu => ('add a space', _menu()),
      _Step.link => ('join with a link', _linkStep()),
      _Step.explore => ('explore', _explore()),
      // The card already names the space; the header says where you are.
      _Step.preview => (
        _previewFrom == _Step.link ? 'join with a link' : 'explore',
        _previewStep(),
      ),
      _Step.create => ('create a space', _create()),
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        LoafSpace.x4,
        LoafSpace.x2,
        LoafSpace.x4,
        LoafSpace.x4,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Header(title: title, onBack: _step == _Step.menu ? null : _back),
          const SizedBox(height: LoafSpace.x3),
          Expanded(child: body),
        ],
      ),
    );
  }

  // ── Steps ──────────────────────────────────────────────────────────────

  Widget _menu() => ListView(
    children: [
      _MenuRow(
        icon: LucideIcons.link,
        title: 'join with a link',
        subtitle: 'an address like #bakers:loaf.moe, or a matrix.to link',
        onTap: () => _go(_Step.link),
      ),
      _MenuRow(
        icon: LucideIcons.compass,
        title: 'explore public spaces',
        subtitle: 'see what loaf.moe and other servers list',
        onTap: () => _go(_Step.explore),
      ),
      _MenuRow(
        icon: LucideIcons.sparkles,
        title: 'create a space',
        subtitle: 'your own, starting with #general and a voice channel',
        onTap: () => _go(_Step.create),
      ),
    ],
  );

  Widget _linkStep() {
    final tokens = LoafTokens.of(context);
    final address = parseSpaceAddress(_link.text);
    final snapshot = address != null && _linkFor == address
        ? _linkSnapshot
        : null;
    return ListView(
      children: [
        _Field(
          controller: _link,
          hint: '#space:server or a matrix.to link',
          icon: LucideIcons.link,
        ),
        const SizedBox(height: LoafSpace.x4),
        if (snapshot != null)
          switch (snapshot.connectionState) {
            ConnectionState.waiting => const Center(
              child: CircularProgressIndicator(),
            ),
            _ when snapshot.hasError =>
              snapshot.error is SpaceNotFound
                  ? Text(
                      'no space at that address',
                      style: loafBody(
                        14,
                        500,
                      ).copyWith(color: tokens.textMuted),
                    )
                  : GestureDetector(
                      onTap: () => _lookUp(address!),
                      child: Text(
                        "couldn't reach that server. try again?",
                        style: loafBody(
                          14,
                          500,
                        ).copyWith(color: tokens.textMuted),
                      ),
                    ),
            _ => _PreviewCard(
              entry: snapshot.data!,
              joined: widget.joined.contains(snapshot.data!.space.id),
              onChoose: () => _choose(snapshot.data!),
            ),
          },
      ],
    );
  }

  Widget _explore() {
    final tokens = LoafTokens.of(context);
    final q = _search.text.trim().toLowerCase();
    _loadServer(_server);
    final snapshot = _exploreSnapshots[_server]!;
    final listed = [
      for (final entry in snapshot.data ?? const <SpacePreview>[])
        if (q.isEmpty ||
            entry.space.name.toLowerCase().contains(q) ||
            (entry.topic ?? '').toLowerCase().contains(q))
          entry,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: _Field(
                controller: _search,
                hint: 'search spaces',
                icon: LucideIcons.search,
                // Browsing is the point here: on a phone, a keyboard on
                // arrival would cover half the list.
                autofocus: isDesktop,
              ),
            ),
            const SizedBox(width: LoafSpace.x2),
            _ServerSwitch(
              server: _server,
              servers: _servers,
              onPick: (server) => setState(() {
                _typingServer = server == null;
                if (server != null) _server = server;
              }),
            ),
          ],
        ),
        if (_typingServer) ...[
          const SizedBox(height: LoafSpace.x2),
          _Field(
            controller: _otherServer,
            hint: 'a server, like example.org',
            icon: LucideIcons.server,
            onSubmitted: (value) => setState(() {
              _server = value.trim();
              _typingServer = false;
            }),
          ),
        ],
        const SizedBox(height: LoafSpace.x3),
        Expanded(
          child: switch (snapshot.connectionState) {
            ConnectionState.waiting => const Center(
              child: CircularProgressIndicator(),
            ),
            _ when snapshot.hasError => Center(
              child: GestureDetector(
                onTap: () => _retryExplore(_server),
                child: Text(
                  "couldn't reach $_server. try again?",
                  style: loafBody(14, 500).copyWith(color: tokens.textMuted),
                ),
              ),
            ),
            _ when listed.isEmpty => Center(
              child: Text(
                q.isEmpty
                    ? 'nothing listed on $_server'
                    : 'no spaces match "$q"',
                style: loafBody(14, 500).copyWith(color: tokens.textMuted),
              ),
            ),
            _ => ListView(
              children: [
                for (final entry in listed)
                  _DirectoryRow(
                    key: ValueKey('directory-${entry.space.id}'),
                    entry: entry,
                    joined: widget.joined.contains(entry.space.id),
                    onTap: () => widget.joined.contains(entry.space.id)
                        ? _choose(entry)
                        : _preview(entry),
                  ),
              ],
            ),
          },
        ),
      ],
    );
  }

  Widget _previewStep() {
    final entry = _previewing!;
    return ListView(
      children: [
        _PreviewCard(
          entry: entry,
          joined: widget.joined.contains(entry.space.id),
          onChoose: () => _choose(entry),
        ),
      ],
    );
  }

  Widget _create() {
    final tokens = LoafTokens.of(context);
    final name = _name.text.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: SpaceAvatar(name: name, color: spaceColorFor(name), size: 72),
        ),
        const SizedBox(height: LoafSpace.x4),
        _Field(controller: _name, hint: 'name your space', autofocus: true),
        const SizedBox(height: LoafSpace.x2),
        Text(
          'it starts with #general and a voice channel called hangout.',
          style: loafBody(13, 400).copyWith(color: tokens.textMuted),
        ),
        const Spacer(),
        LoafButton(
          label: 'create',
          onTap: name.isEmpty
              ? null
              : () => Navigator.pop(context, CreateSpace(name)),
        ),
      ],
    );
  }
}

// ── Pieces ─────────────────────────────────────────────────────────────────

/// Two-letter initials, as the rail shows a space.
String spaceInitials(String name) => name
    .trim()
    .split(RegExp(r'\s+'))
    .where((w) => w.isNotEmpty)
    .take(2)
    .map((w) => w.characters.first)
    .join()
    .toUpperCase();

const _spacePalette = [
  Color(0xFFD97B2A),
  Color(0xFF3B82F6),
  Color(0xFF8B5CF6),
  Color(0xFF4E9E76),
  Color(0xFFDB2777),
  Color(0xFF0891B2),
];

/// A new space's colour, picked from its name so it does not jump around as
/// you type — only when the name changes enough to land elsewhere.
Color spaceColorFor(String name) => name.isEmpty
    ? _spacePalette.first
    : _spacePalette[name.toLowerCase().codeUnits.fold(0, (a, b) => a + b) %
          _spacePalette.length];

class SpaceAvatar extends StatelessWidget {
  const SpaceAvatar({
    super.key,
    required this.name,
    required this.color,
    this.size = 48,
  });

  final String name;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(size / 3),
    ),
    child: Text(
      spaceInitials(name),
      style: loafBody(size * 0.36, 600).copyWith(color: Colors.white),
    ),
  );
}

class _Header extends StatelessWidget {
  const _Header({required this.title, this.onBack});

  final String title;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return Row(
      children: [
        if (onBack != null) ...[
          IconButton(
            tooltip: 'Back',
            onPressed: onBack,
            icon: Icon(LucideIcons.arrowLeft, color: tokens.textMuted),
          ),
          const SizedBox(width: LoafSpace.x1),
        ],
        Expanded(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: loafDisplay(20, 600).copyWith(color: tokens.textStrong),
          ),
        ),
      ],
    );
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: LoafSpace.x2),
      child: Material(
        color: tokens.sunken,
        borderRadius: BorderRadius.circular(LoafRadius.lg),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(LoafRadius.lg),
          child: Padding(
            padding: const EdgeInsets.all(LoafSpace.x4),
            child: Row(
              children: [
                Icon(icon, size: 22, color: tokens.textStrong),
                const SizedBox(width: LoafSpace.x4),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: loafBody(
                          15,
                          600,
                        ).copyWith(color: tokens.textStrong),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: loafBody(
                          13,
                          400,
                        ).copyWith(color: tokens.textMuted),
                      ),
                    ],
                  ),
                ),
                Icon(
                  LucideIcons.chevronRight,
                  size: 18,
                  color: tokens.textMuted,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.controller,
    required this.hint,
    this.icon,
    this.autofocus = true,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final String hint;
  final IconData? icon;
  final bool autofocus;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    OutlineInputBorder border(Color color, [double width = 1]) =>
        OutlineInputBorder(
          borderRadius: BorderRadius.circular(LoafRadius.md),
          borderSide: BorderSide(color: color, width: width),
        );
    return TextField(
      controller: controller,
      autofocus: autofocus,
      onSubmitted: onSubmitted,
      style: loafBody(15, 400).copyWith(color: tokens.textStrong),
      decoration: InputDecoration(
        isDense: true,
        prefixIcon: icon == null
            ? null
            : Icon(icon, size: 18, color: tokens.textMuted),
        hintText: hint,
        hintStyle: loafBody(15, 400).copyWith(color: tokens.textMuted),
        filled: true,
        fillColor: tokens.sunken,
        border: border(tokens.border),
        enabledBorder: border(tokens.border),
        // Focus is not an alarm: a firmer outline, not the accent red.
        focusedBorder: border(tokens.borderStrong, 1.5),
      ),
    );
  }
}

/// Which server's directory you are looking at. Picking "another server…"
/// reports null, and the panel asks for a name.
class _ServerSwitch extends StatelessWidget {
  const _ServerSwitch({
    required this.server,
    required this.servers,
    required this.onPick,
  });

  final String server;
  final List<String> servers;
  final ValueChanged<String?> onPick;

  static const _other = '\u0000other';

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return PopupMenuButton<String>(
      tooltip: 'Server',
      color: tokens.card,
      onSelected: (value) => onPick(value == _other ? null : value),
      itemBuilder: (context) => [
        for (final s in servers)
          PopupMenuItem(
            value: s,
            child: Text(
              s,
              style: loafBody(14, 500).copyWith(color: tokens.textStrong),
            ),
          ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: _other,
          child: Text(
            'another server…',
            style: loafBody(14, 500).copyWith(color: tokens.textBody),
          ),
        ),
      ],
      child: Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: LoafSpace.x3),
        decoration: BoxDecoration(
          color: tokens.sunken,
          borderRadius: BorderRadius.circular(LoafRadius.md),
          border: Border.all(color: tokens.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              server,
              style: loafBody(14, 600).copyWith(color: tokens.textStrong),
            ),
            const SizedBox(width: LoafSpace.x1),
            Icon(LucideIcons.chevronDown, size: 16, color: tokens.textMuted),
          ],
        ),
      ),
    );
  }
}

class _DirectoryRow extends StatelessWidget {
  const _DirectoryRow({
    super.key,
    required this.entry,
    required this.joined,
    required this.onTap,
  });

  final SpacePreview entry;
  final bool joined;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(LoafRadius.md),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: LoafSpace.x2,
          vertical: LoafSpace.x2,
        ),
        child: Row(
          children: [
            SpaceAvatar(
              name: entry.space.name,
              color: entry.space.color,
              size: 40,
            ),
            const SizedBox(width: LoafSpace.x3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.space.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: loafBody(15, 600).copyWith(color: tokens.textStrong),
                  ),
                  if (entry.topic != null)
                    Text(
                      entry.topic!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: loafBody(
                        13,
                        400,
                      ).copyWith(color: tokens.textMuted),
                    ),
                  Text(
                    _members(entry.memberCount),
                    style: loafBody(12, 500).copyWith(color: tokens.textMuted),
                  ),
                ],
              ),
            ),
            if (joined)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: LoafSpace.x2,
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(LoafRadius.full),
                  border: Border.all(color: tokens.borderStrong),
                ),
                child: Text(
                  'joined',
                  style: loafBody(11, 600).copyWith(color: tokens.textBody),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

String _members(int n) => n == 1 ? '1 member' : '$n members';

/// A space seen from outside, with whatever you can do about it: join,
/// open (already yours), or nothing but ask (invite-only).
class _PreviewCard extends StatelessWidget {
  const _PreviewCard({
    required this.entry,
    required this.joined,
    required this.onChoose,
  });

  final SpacePreview entry;
  final bool joined;
  final VoidCallback onChoose;

  static const _shownChannels = 5;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    final channels = entry.space.allChannels.toList();
    final shown = channels.take(_shownChannels);
    final more = channels.length - shown.length;
    return Container(
      padding: const EdgeInsets.all(LoafSpace.x4),
      decoration: BoxDecoration(
        color: tokens.sunken,
        borderRadius: BorderRadius.circular(LoafRadius.lg),
        border: Border.all(color: tokens.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SpaceAvatar(
                name: entry.space.name,
                color: entry.space.color,
                size: 52,
              ),
              const SizedBox(width: LoafSpace.x3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.space.name,
                      style: loafDisplay(
                        18,
                        600,
                      ).copyWith(color: tokens.textStrong),
                    ),
                    Text(
                      entry.alias,
                      style: loafBody(
                        12,
                        400,
                      ).copyWith(color: tokens.textMuted),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (entry.topic != null) ...[
            const SizedBox(height: LoafSpace.x3),
            Text(
              entry.topic!,
              style: loafBody(14, 400).copyWith(color: tokens.textBody),
            ),
          ],
          const SizedBox(height: LoafSpace.x2),
          Text(
            _members(entry.memberCount),
            style: loafBody(13, 500).copyWith(color: tokens.textMuted),
          ),
          if (!entry.inviteOnly && shown.isNotEmpty) ...[
            const SizedBox(height: LoafSpace.x3),
            for (final c in shown)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Icon(c.icon, size: 14, color: tokens.textMuted),
                    const SizedBox(width: LoafSpace.x2),
                    Text(
                      c.name,
                      style: loafBody(14, 400).copyWith(color: tokens.textBody),
                    ),
                  ],
                ),
              ),
            if (more > 0)
              Text(
                'and $more more',
                style: loafBody(13, 400).copyWith(color: tokens.textMuted),
              ),
          ],
          const SizedBox(height: LoafSpace.x4),
          if (entry.inviteOnly)
            Text(
              "this space is invite-only. ask someone inside for an invite.",
              style: loafBody(14, 500).copyWith(color: tokens.textMuted),
            )
          else
            SizedBox(
              width: double.infinity,
              child: LoafButton(
                label: joined ? 'open' : 'join',
                onTap: onChoose,
              ),
            ),
        ],
      ),
    );
  }
}
