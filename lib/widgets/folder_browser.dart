// folder_browser.dart
//
// Explorer-style folders for the Videos and Live sessions lists.
//
// Top level:
//   Folders
//   ┌──────────────────┐ ┌──────────────────┐ ┌──────────────────┐
//   │ 📁 Prof. Lennox ⋮│ │ 📁 Uzbek ASR    ⋮│ │ ＋ New folder     │
//   │    2 videos      │ │    2 videos      │ │                  │
//   └──────────────────┘ └──────────────────┘ └──────────────────┘
//   ▸ 3 folders without videos
//
//   Not in a folder · 8
//   [cards…]
//
// Inside a folder:
//   ← Videos  ›  📁 Prof. John Lennox · 2          [Rename] [Delete]
//   [cards…]
//
// Folder tiles (and "Videos" in the path bar) accept dragged cards.

import 'package:flutter/material.dart';

class FolderInfo {
  const FolderInfo(this.name, this.count);
  final String name;
  final int count; // items of *this* list in the folder
}

/// Grid of folder tiles for the top level of a list.
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
  final String itemSingular; // "video" / "session"
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
    final narrow = MediaQuery.sizeOf(context).width < 600;
    final tileWidth = narrow ? double.infinity : 230.0;

    Widget tiles(List<FolderInfo> list, {bool withNew = false}) => Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final f in list)
              SizedBox(
                width: tileWidth,
                child: _FolderTile(
                  info: f,
                  countText: f.count == 0
                      ? 'empty'
                      : '${f.count} ${f.count == 1 ? widget.itemSingular : widget.itemPlural}',
                  onOpen: () => widget.onOpen(f.name),
                  onRename: () => widget.onRename(f.name),
                  onDelete: () => widget.onDelete(f.name),
                  onDrop: (id) => widget.onDropItem(f.name, id),
                ),
              ),
            if (withNew)
              SizedBox(
                width: tileWidth,
                child: _NewFolderTile(onTap: widget.onCreate),
              ),
          ],
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionTitle('Folders', used.length),
        const SizedBox(height: 8),
        tiles(used, withNew: true),
        if (empty.isNotEmpty) ...[
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => setState(() => _showEmpty = !_showEmpty),
              icon: Icon(_showEmpty ? Icons.expand_less : Icons.expand_more,
                  size: 18),
              label: Text(
                '${empty.length} folder${empty.length == 1 ? '' : 's'} '
                'without ${widget.itemPlural}',
              ),
              style: TextButton.styleFrom(
                foregroundColor: Colors.blueGrey.shade600,
                visualDensity: VisualDensity.compact,
              ),
            ),
          ),
          if (_showEmpty) ...[
            const SizedBox(height: 4),
            Opacity(opacity: 0.75, child: tiles(empty)),
          ],
        ],
      ],
    );
  }
}

Widget _sectionTitle(String text, int? count) => Row(
      children: [
        Text(
          text,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            color: Colors.blueGrey.shade800,
          ),
        ),
        if (count != null) ...[
          const SizedBox(width: 6),
          Text('· $count',
              style: TextStyle(fontSize: 14, color: Colors.blueGrey.shade400)),
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

class _FolderTile extends StatefulWidget {
  const _FolderTile({
    required this.info,
    required this.countText,
    required this.onOpen,
    required this.onRename,
    required this.onDelete,
    required this.onDrop,
  });

  final FolderInfo info;
  final String countText;
  final VoidCallback onOpen;
  final VoidCallback onRename;
  final VoidCallback onDelete;
  final ValueChanged<String> onDrop;

  @override
  State<_FolderTile> createState() => _FolderTileState();
}

class _FolderTileState extends State<_FolderTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final amber = Colors.amber.shade800;
    return DragTarget<String>(
      onWillAcceptWithDetails: (_) => true,
      onAcceptWithDetails: (d) => widget.onDrop(d.data),
      builder: (context, candidates, _) {
        final dropping = candidates.isNotEmpty;
        return MouseRegion(
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            decoration: BoxDecoration(
              color: dropping ? Colors.blue.shade50 : Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: dropping
                    ? Colors.blue.shade400
                    : (_hover ? Colors.amber.shade400 : Colors.grey.shade300),
                width: dropping ? 2 : 1,
              ),
              boxShadow: _hover
                  ? [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.06),
                        blurRadius: 10,
                        offset: const Offset(0, 3),
                      ),
                    ]
                  : const [],
            ),
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: widget.onOpen,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 2, 10),
                  child: Row(
                    children: [
                      Icon(dropping ? Icons.folder_open : Icons.folder,
                          color: amber, size: 30),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              widget.info.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w600, fontSize: 14),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              dropping ? 'Drop to move here' : widget.countText,
                              style: TextStyle(
                                fontSize: 12,
                                color: dropping
                                    ? Colors.blue.shade700
                                    : Colors.grey.shade600,
                              ),
                            ),
                          ],
                        ),
                      ),
                      PopupMenuButton<String>(
                        tooltip: 'Folder actions',
                        icon: Icon(Icons.more_vert,
                            size: 18, color: Colors.grey.shade600),
                        onSelected: (v) {
                          if (v == 'open') widget.onOpen();
                          if (v == 'rename') widget.onRename();
                          if (v == 'delete') widget.onDelete();
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(
                            value: 'open',
                            child: ListTile(
                              dense: true,
                              leading: Icon(Icons.folder_open),
                              title: Text('Open'),
                            ),
                          ),
                          PopupMenuItem(
                            value: 'rename',
                            child: ListTile(
                              dense: true,
                              leading: Icon(Icons.edit_outlined),
                              title: Text('Rename'),
                            ),
                          ),
                          PopupMenuItem(
                            value: 'delete',
                            child: ListTile(
                              dense: true,
                              leading:
                                  Icon(Icons.delete_outline, color: Colors.red),
                              title: Text('Delete folder'),
                            ),
                          ),
                        ],
                      ),
                    ],
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

class _NewFolderTile extends StatelessWidget {
  const _NewFolderTile({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.blueGrey.shade200),
          color: Colors.blueGrey.shade50.withValues(alpha: 0.5),
        ),
        child: Row(
          children: [
            Icon(Icons.create_new_folder_outlined,
                color: Colors.blueGrey.shade600, size: 26),
            const SizedBox(width: 10),
            Text('New folder',
                style: TextStyle(
                    color: Colors.blueGrey.shade700,
                    fontWeight: FontWeight.w600)),
          ],
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
