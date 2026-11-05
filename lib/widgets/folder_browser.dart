// folder_browser.dart
//
// Folders for the Videos and Live sessions lists — compact.
//
// Top level: one strip of small folder chips (wraps only when needed):
//   📁 FeG Karlsruhe… 1   📁 Human Translations 1   📁 NASA Astronaut… 2
//   📁 Uzbek ASR Tests 2   +2 empty   ＋ New folder
//   Not in a folder · 8
//   [cards…]
//
// Inside a folder:
//   ← Videos  ›  📂 Prof. John Lennox · 2          [Rename] [Delete]
//
// Click a chip to open the folder; right-click / long-press it for
// Rename / Delete. Chips (and "← Videos" in the path bar) accept dragged
// cards.

import 'package:flutter/material.dart';

class FolderInfo {
  const FolderInfo(this.name, this.count);
  final String name;
  final int count; // items of *this* list in the folder
}

/// Compact folder chips for the top level of a list.
class FolderGrid extends StatefulWidget {
  const FolderGrid({
    super.key,
    required this.folders,
    required this.itemSingular,
    required this.itemPlural,
    required this.onOpen,
    required this.onCreate,
    required this.onRename,
    required this.onDelete,
    required this.onDropItem,
  });

  final List<FolderInfo> folders;
  final String itemSingular; // "video" / "session" (tooltips only)
  final String itemPlural; // "videos" / "sessions"
  final ValueChanged<String> onOpen;
  final VoidCallback onCreate;
  final ValueChanged<String> onRename;
  final ValueChanged<String> onDelete;

  /// A card (its id) was dropped on folder [folder].
  final void Function(String folder, String itemId) onDropItem;

  @override
  State<FolderGrid> createState() => _FolderGridState();
}

class _FolderGridState extends State<FolderGrid> {
  bool _showEmpty = false;

  @override
  Widget build(BuildContext context) {
    final used = widget.folders.where((f) => f.count > 0).toList();
    final empty = widget.folders.where((f) => f.count == 0).toList();

    _FolderChip chip(FolderInfo f, {bool dim = false}) => _FolderChip(
          info: f,
          dim: dim,
          tooltip: '${f.name}\n${f.count} '
              '${f.count == 1 ? widget.itemSingular : widget.itemPlural}'
              ' · right-click for Rename / Delete',
          onOpen: () => widget.onOpen(f.name),
          onRename: () => widget.onRename(f.name),
          onDelete: () => widget.onDelete(f.name),
          onDrop: (id) => widget.onDropItem(f.name, id),
        );

    return Wrap(
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final f in used) chip(f),
        if (_showEmpty)
          for (final f in empty) chip(f, dim: true),
        if (empty.isNotEmpty)
          _SmallAction(
            icon: _showEmpty ? Icons.expand_less : Icons.more_horiz,
            label: _showEmpty ? 'Hide empty' : '+${empty.length} empty',
            tooltip: _showEmpty
                ? 'Hide folders without ${widget.itemPlural}'
                : 'Show ${empty.length} folder${empty.length == 1 ? '' : 's'} '
                    'without ${widget.itemPlural}',
            onTap: () => setState(() => _showEmpty = !_showEmpty),
          ),
        _SmallAction(
          icon: Icons.create_new_folder_outlined,
          label: 'New folder',
          tooltip: 'New folder',
          onTap: widget.onCreate,
        ),
      ],
    );
  }
}

Widget _sectionTitle(String text, int? count) => Row(
      children: [
        Text(
          text,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: Colors.blueGrey.shade800,
          ),
        ),
        if (count != null) ...[
          const SizedBox(width: 6),
          Text('· $count',
              style: TextStyle(fontSize: 13, color: Colors.blueGrey.shade400)),
        ],
      ],
    );

/// "Not in a folder · 8" heading above the loose items at top level.
class FolderSectionTitle extends StatelessWidget {
  const FolderSectionTitle({super.key, required this.text, this.count});
  final String text;
  final int? count;

  @override
  Widget build(BuildContext context) => _sectionTitle(text, count);
}

class _FolderChip extends StatelessWidget {
  const _FolderChip({
    required this.info,
    required this.tooltip,
    required this.onOpen,
    required this.onRename,
    required this.onDelete,
    required this.onDrop,
    this.dim = false,
  });

  final FolderInfo info;
  final String tooltip;
  final bool dim;
  final VoidCallback onOpen;
  final VoidCallback onRename;
  final VoidCallback onDelete;
  final ValueChanged<String> onDrop;

  Future<void> _menu(BuildContext context, Offset at) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    final v = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
          at & const Size(1, 1), Offset.zero & overlay.size),
      items: const [
        PopupMenuItem(value: 'open', child: Text('Open')),
        PopupMenuItem(value: 'rename', child: Text('Rename')),
        PopupMenuItem(
            value: 'delete',
            child: Text('Delete folder', style: TextStyle(color: Colors.red))),
      ],
    );
    if (v == 'open') onOpen();
    if (v == 'rename') onRename();
    if (v == 'delete') onDelete();
  }

  @override
  Widget build(BuildContext context) {
    return DragTarget<String>(
      onWillAcceptWithDetails: (_) => true,
      onAcceptWithDetails: (d) => onDrop(d.data),
      builder: (context, candidates, _) {
        final dropping = candidates.isNotEmpty;
        return Tooltip(
          message: dropping ? 'Drop to move into "${info.name}"' : tooltip,
          waitDuration: const Duration(milliseconds: 500),
          child: Opacity(
            opacity: dim && !dropping ? 0.6 : 1,
            child: GestureDetector(
              onSecondaryTapDown: (d) => _menu(context, d.globalPosition),
              onLongPressStart: (d) => _menu(context, d.globalPosition),
              child: Material(
                color: dropping ? Colors.blue.shade50 : Colors.white,
                shape: StadiumBorder(
                  side: BorderSide(
                    color: dropping ? Colors.blue.shade400 : Colors.grey.shade300,
                    width: dropping ? 2 : 1,
                  ),
                ),
                child: InkWell(
                  customBorder: const StadiumBorder(),
                  onTap: onOpen,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(10, 5, 6, 5),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(dropping ? Icons.folder_open : Icons.folder,
                            size: 18, color: Colors.amber.shade800),
                        const SizedBox(width: 6),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 190),
                          child: Text(
                            info.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 13, fontWeight: FontWeight.w500),
                          ),
                        ),
                        const SizedBox(width: 6),
                        // Just the number.
                        Container(
                          constraints: const BoxConstraints(minWidth: 20),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: Colors.amber.shade100,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            '${info.count}',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: Colors.amber.shade900,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _SmallAction extends StatelessWidget {
  const _SmallAction({
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: TextButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 18),
        label: Text(label, style: const TextStyle(fontSize: 13)),
        style: TextButton.styleFrom(
          foregroundColor: Colors.blueGrey.shade700,
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 8),
        ),
      ),
    );
  }
}

/// Path bar while a folder is open: "← Videos › 📁 Name · 2  [Rename] [Delete]".
/// "Videos" goes back and accepts dropped cards (= take them out of the folder).
class FolderPathBar extends StatelessWidget {
  const FolderPathBar({
    super.key,
    required this.rootLabel,
    required this.folder,
    required this.count,
    required this.onBack,
    required this.onRename,
    required this.onDelete,
    required this.onDropToRoot,
  });

  final String rootLabel;
  final String folder;
  final int count;
  final VoidCallback onBack;
  final VoidCallback onRename;
  final VoidCallback onDelete;
  final ValueChanged<String> onDropToRoot;

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < 600;
    final crumbStyle = TextStyle(
        fontSize: 15, fontWeight: FontWeight.w600, color: Colors.blue.shade700);

    final root = DragTarget<String>(
      onWillAcceptWithDetails: (_) => true,
      onAcceptWithDetails: (d) => onDropToRoot(d.data),
      builder: (context, candidates, _) => InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onBack,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: candidates.isNotEmpty ? Colors.blue.shade50 : null,
            borderRadius: BorderRadius.circular(8),
            border: candidates.isNotEmpty
                ? Border.all(color: Colors.blue.shade400)
                : null,
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.arrow_back, size: 18, color: Colors.blue.shade700),
            const SizedBox(width: 6),
            Text(candidates.isNotEmpty ? 'Take out of folder' : rootLabel,
                style: crumbStyle),
          ]),
        ),
      ),
    );

    return Container(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
      decoration: BoxDecoration(
        color: Colors.amber.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.amber.shade200),
      ),
      child: Row(
        children: [
          root,
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Icon(Icons.chevron_right, color: Colors.grey.shade500),
          ),
          Icon(Icons.folder_open, color: Colors.amber.shade800, size: 22),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '$folder · $count',
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
            ),
          ),
          if (narrow) ...[
            IconButton(
              tooltip: 'Rename folder',
              icon: const Icon(Icons.edit_outlined, size: 20),
              onPressed: onRename,
            ),
            IconButton(
              tooltip: 'Delete folder',
              icon: const Icon(Icons.delete_outline, size: 20, color: Colors.red),
              onPressed: onDelete,
            ),
          ] else ...[
            TextButton.icon(
              onPressed: onRename,
              icon: const Icon(Icons.edit_outlined, size: 16),
              label: const Text('Rename'),
            ),
            TextButton.icon(
              onPressed: onDelete,
              icon: const Icon(Icons.delete_outline, size: 16),
              label: const Text('Delete folder'),
              style: TextButton.styleFrom(foregroundColor: Colors.red),
            ),
          ],
        ],
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════
//  FolderColumn — all folders in one card: sorted A–Z, the open one
//  scrolled to the middle (as far as the list allows), "+" for a new
//  folder. The card is only as tall as its rows (up to [height]).
//
//   ┌────────────────────────────┐
//   │ 📥 Not in a folder    8 ⊕ │
//   │ 📁 Human Translations   1 │
//   │ 📂 Oktober 2026         1 │  ← open (highlighted)
//   │ 📁 Prof. John Lennox …  2 │
//   └────────────────────────────┘
//
//  Tap a row to open it. Right-click / long-press for Rename / Delete.
//  Rows accept dragged cards; "Not in a folder" takes them out.
// ═════════════════════════════════════════════════════════════════════
class FolderColumn extends StatefulWidget {
  const FolderColumn({
    super.key,
    required this.folders,
    required this.current,
    required this.rootLabel,
    required this.rootCount,
    required this.onSelect,
    required this.onCreate,
    required this.onRename,
    required this.onDelete,
    required this.onDropItem,
    this.height = 260,
  });

  final List<FolderInfo> folders;

  /// Open folder, or null for the top level ("Not in a folder").
  final String? current;
  final String rootLabel;
  final int rootCount;
  final ValueChanged<String?> onSelect;
  final VoidCallback onCreate;
  final ValueChanged<String> onRename;
  final ValueChanged<String> onDelete;

  /// A card (its id) dropped on a folder (null = take it out of its folder).
  final void Function(String? folder, String itemId) onDropItem;
  /// Maximum height of the list; it shrinks to fit when there are
  /// fewer folders (no empty space).
  final double height;

  @override
  State<FolderColumn> createState() => _FolderColumnState();
}

class _FolderColumnState extends State<FolderColumn> {
  static const double _rowH = 38;
  final ScrollController _ctrl = ScrollController();

  List<FolderInfo> get _sorted => [...widget.folders]
    ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

  int _indexOf(String? folder, List<FolderInfo> sorted) {
    if (folder == null) return 0;
    final i = sorted.indexWhere((f) => f.name == folder);
    return i < 0 ? 0 : i + 1; // row 0 = top level
  }

  /// Scroll so the open row sits in the middle — clamped at both ends,
  /// so the list never shows empty space above or below.
  void _center({bool animate = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_ctrl.hasClients) return;
      final pos = _ctrl.position;
      final idx = _indexOf(widget.current, _sorted);
      final target = (idx * _rowH - (pos.viewportDimension - _rowH) / 2)
          .clamp(0.0, pos.maxScrollExtent);
      if ((pos.pixels - target).abs() < 1) return;
      if (animate) {
        _ctrl.animateTo(target,
            duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      } else {
        _ctrl.jumpTo(target);
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _center(animate: false);
  }

  @override
  void didUpdateWidget(FolderColumn old) {
    super.didUpdateWidget(old);
    if (old.current != widget.current ||
        old.folders.length != widget.folders.length) {
      _center();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _menu(BuildContext context, Offset at, String name) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final v = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
          at & const Size(1, 1), Offset.zero & overlay.size),
      items: const [
        PopupMenuItem(value: 'open', child: Text('Open')),
        PopupMenuItem(value: 'rename', child: Text('Rename')),
        PopupMenuItem(
            value: 'delete',
            child: Text('Delete folder', style: TextStyle(color: Colors.red))),
      ],
    );
    if (v == 'open') widget.onSelect(name);
    if (v == 'rename') widget.onRename(name);
    if (v == 'delete') widget.onDelete(name);
  }

  // One text style for every folder name (as for the open one).
  static const _nameStyle = TextStyle(
    fontSize: 13.5,
    fontWeight: FontWeight.w700,
    color: Color(0xFF263238), // blueGrey 900
  );

  Widget _row(BuildContext context, String? folder, String label, int count,
      bool active) {
    return DragTarget<String>(
      onWillAcceptWithDetails: (_) => true,
      onAcceptWithDetails: (d) => widget.onDropItem(folder, d.data),
      builder: (context, candidates, _) {
        final dropping = candidates.isNotEmpty;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => widget.onSelect(folder),
          onSecondaryTapDown: folder == null
              ? null
              : (d) => _menu(context, d.globalPosition, folder),
          onLongPressStart: folder == null
              ? null
              : (d) => _menu(context, d.globalPosition, folder),
          child: Container(
            height: _rowH,
            margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: dropping
                  ? Colors.blue.shade50
                  : (active ? Colors.amber.shade50 : null),
              borderRadius: BorderRadius.circular(8),
              border: dropping
                  ? Border.all(color: Colors.blue.shade400)
                  : (active ? Border.all(color: Colors.amber.shade300) : null),
            ),
            child: Row(
              children: [
                Icon(
                  folder == null
                      ? Icons.inbox_outlined
                      : (active || dropping ? Icons.folder_open : Icons.folder),
                  size: 18,
                  color: folder == null
                      ? Colors.blueGrey.shade600
                      : Colors.amber.shade800,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _nameStyle,
                  ),
                ),
                Text(
                  '$count',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: active ? Colors.amber.shade900 : Colors.blueGrey.shade600,
                  ),
                ),
                // "+" for a new folder sits in the first row (no title line).
                if (folder == null) ...[
                  const SizedBox(width: 4),
                  SizedBox.square(
                    dimension: 28,
                    child: IconButton(
                      tooltip: 'New folder',
                      padding: EdgeInsets.zero,
                      iconSize: 20,
                      icon: Icon(Icons.add_circle_outline,
                          color: Colors.blue.shade700),
                      onPressed: widget.onCreate,
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final sorted = _sorted;
    final rows = <Widget>[
      _row(context, null, widget.rootLabel, widget.rootCount,
          widget.current == null),
      for (final f in sorted)
        _row(context, f.name, f.name, f.count, widget.current == f.name),
    ];
    // Exactly as tall as the rows (2 px margin each), up to the maximum.
    final listHeight =
        (rows.length * (_rowH + 2)).toDouble().clamp(0.0, widget.height);

    return Card(
      margin: EdgeInsets.zero,
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 4),
          SizedBox(
            height: listHeight,
            child: ListView(
              controller: _ctrl,
              padding: EdgeInsets.zero,
              itemExtent: _rowH + 2,
              children: rows,
            ),
          ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }
}
