/// A DM's call, docked at the top of the conversation. A DM is a
/// conversation that sometimes has a call, so the call sits over it rather
/// than replacing it: compact by default, expanded to fill the
/// conversation, and on a computer, any height in between.
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../platform.dart';
import '../theme/loaf_theme.dart';
import 'call_controller.dart';
import 'call_view.dart';

class DmCallPanel extends StatefulWidget {
  const DmCallPanel({
    super.key = const ValueKey('dm-call-panel'),
    required this.calls,
    required this.expanded,
    required this.onToggleExpanded,
  });

  final CallController calls;

  /// Fills the conversation. The caller lays the panel out accordingly:
  /// expanded, it takes the space the timeline and composer had.
  final bool expanded;
  final VoidCallback onToggleExpanded;

  /// A phone's compact panel. A computer starts here and can be dragged.
  static const compactHeight = 240.0;

  @override
  State<DmCallPanel> createState() => _DmCallPanelState();
}

class _DmCallPanelState extends State<DmCallPanel> {
  double _height = DmCallPanel.compactHeight;

  /// Taller than this, the panel has room for the full grid rather than a
  /// single row.
  static const _gridFrom = 360.0;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    final expanded = widget.expanded;
    final view = CallView(
      calls: widget.calls,
      compact: !expanded && _height < _gridFrom,
      trailing: [
        TopBarButton(
          icon: expanded ? LucideIcons.minimize2 : LucideIcons.maximize2,
          tooltip: expanded ? 'Shrink' : 'Expand',
          onTap: widget.onToggleExpanded,
        ),
      ],
    );
    if (expanded) return view;

    final maxHeight = MediaQuery.sizeOf(context).height * 0.7;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: tokens.border)),
      ),
      child: Column(
        children: [
          SizedBox(
            height: _height.clamp(DmCallPanel.compactHeight, maxHeight),
            child: view,
          ),
          if (isDesktop)
            MouseRegion(
              cursor: SystemMouseCursors.resizeRow,
              child: GestureDetector(
                key: const ValueKey('dm-call-resize'),
                behavior: HitTestBehavior.opaque,
                onVerticalDragUpdate: (d) => setState(
                  () => _height = (_height + d.delta.dy).clamp(
                    DmCallPanel.compactHeight,
                    maxHeight,
                  ),
                ),
                child: SizedBox(
                  height: 10,
                  child: Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: tokens.borderStrong,
                        borderRadius: BorderRadius.circular(LoafRadius.full),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
