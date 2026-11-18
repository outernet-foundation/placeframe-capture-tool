import 'package:material_ui/material_ui.dart';

import 'api.dart';

// The map picker: a field that shows the selection and drops down the maps as a tree of folders ("a/b"), like the
// web pages' map picker. Several maps can be selected. Maps are listed newest first; folders by their newest map.
// Tapping outside the list closes it.
class MapPicker extends StatefulWidget {
  const MapPicker({super.key, required this.maps, required this.selected, required this.onChanged, this.enabled = true});

  final List<MapInfo> maps;
  final Set<String> selected;
  final void Function(Set<String>) onChanged;
  final bool enabled;

  // "created 2026-11-17 14:02" in local time, from the map's created_at.
  static String created(MapInfo m) {
    final t = DateTime.tryParse(m.createdAt)?.toLocal();
    if (t == null) return 'created —';
    String two(int v) => v.toString().padLeft(2, '0');
    return 'created ${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }

  @override
  State<MapPicker> createState() => _MapPickerState();
}

class _MapPickerState extends State<MapPicker> {
  final _portal = OverlayPortalController();
  final _link = LayerLink();
  final _group = Object(); // the field and the list: a tap on either does not count as "outside"
  double _width = 0;

  static String _path(MapInfo m) => m.folder.isEmpty ? m.name : '${m.folder} / ${m.name}';

  void _toggle(String id, bool on) {
    final next = {...widget.selected};
    on ? next.add(id) : next.remove(id);
    widget.onChanged(next);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final chosen = widget.maps.where((m) => widget.selected.contains(m.id)).toList();
    final label = chosen.isEmpty
        ? 'Choose maps…'
        : chosen.length == 1
            ? _path(chosen.first)
            : '${_path(chosen.first)} + ${chosen.length - 1} more';
    return LayoutBuilder(builder: (context, box) {
      _width = box.maxWidth;
      return CompositedTransformTarget(
        link: _link,
        child: OverlayPortal(
          controller: _portal,
          overlayChildBuilder: _dropdown,
          child: TapRegion(
            groupId: _group,
            child: InkWell(
              onTap: widget.enabled && widget.maps.isNotEmpty ? () => setState(_portal.toggle) : null,
              child: InputDecorator(
                isFocused: _portal.isShowing,
                decoration: InputDecoration(
                    labelText: 'Maps',
                    border: const OutlineInputBorder(),
                    suffixIcon: Icon(_portal.isShowing ? Icons.arrow_drop_up : Icons.arrow_drop_down)),
                child: Text(label, overflow: TextOverflow.ellipsis),
              ),
            ),
          ),
        ),
      );
    });
  }

  // The list, attached under the field and as wide as it, at most 60% of the screen high.
  Widget _dropdown(BuildContext context) => CompositedTransformFollower(
        link: _link,
        targetAnchor: Alignment.bottomLeft,
        offset: const Offset(0, 4),
        child: Align(
          alignment: Alignment.topLeft,
          child: TapRegion(
            groupId: _group,
            onTapOutside: (_) => setState(_portal.hide),
            child: Material(
              elevation: 8,
              borderRadius: BorderRadius.circular(8),
              clipBehavior: Clip.antiAlias,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: _width, minWidth: _width, maxHeight: MediaQuery.sizeOf(context).height * 0.6),
                child: ListView(shrinkWrap: true, padding: const EdgeInsets.symmetric(vertical: 4), children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                    child: Text('${widget.selected.length} selected · newest first', style: Theme.of(context).textTheme.bodySmall),
                  ),
                  ..._children(context, _tree(widget.maps), 0),
                ]),
              ),
            ),
          ),
        ),
      );

  List<Widget> _children(BuildContext context, _Folder f, int depth) {
    final pad = EdgeInsets.only(left: 12.0 + 16 * depth, right: 8);
    return [
      for (final sub in f.folders)
        ExpansionTile(
          tilePadding: pad,
          dense: true,
          leading: const Icon(Icons.folder_outlined),
          title: Text(sub.name),
          subtitle: Text('${sub.count} map${sub.count == 1 ? '' : 's'}'),
          initiallyExpanded: sub.contains(widget.selected),
          children: _children(context, sub, depth + 1),
        ),
      for (final m in f.maps)
        CheckboxListTile(
          contentPadding: pad,
          dense: true,
          value: widget.selected.contains(m.id),
          onChanged: (v) => _toggle(m.id, v == true),
          title: Text(m.name),
          subtitle: Text('${MapPicker.created(m)}${m.active ? '' : ' · inactive'}'),
        ),
    ];
  }

  static _Folder _tree(List<MapInfo> maps) {
    final root = _Folder('');
    for (final m in maps) {
      var f = root;
      for (final part in m.folder.split('/').where((p) => p.isNotEmpty)) {
        f = f.sub(part);
      }
      f.maps.add(m);
    }
    root.sort();
    return root;
  }
}

class _Folder {
  _Folder(this.name);
  final String name;
  final List<_Folder> folders = [];
  final List<MapInfo> maps = [];

  _Folder sub(String n) => folders.where((f) => f.name == n).firstOrNull ?? (folders..add(_Folder(n))).last;
  int get count => maps.length + folders.fold(0, (s, f) => s + f.count);
  String get newest =>
      [...maps.map((m) => m.createdAt), ...folders.map((f) => f.newest)].fold('', (a, b) => b.compareTo(a) > 0 ? b : a);
  bool contains(Set<String> ids) => maps.any((m) => ids.contains(m.id)) || folders.any((f) => f.contains(ids));

  void sort() {
    maps.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    for (final f in folders) {
      f.sort();
    }
    folders.sort((a, b) => b.newest.compareTo(a.newest));
  }
}
