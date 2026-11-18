import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:placeframe_mobile/api.dart';
import 'package:placeframe_mobile/map_picker.dart';

MapInfo _map(String id, String name, String created, String folder) =>
    MapInfo({'id': id, 'name': name, 'created_at': created, 'active': true})..folder = folder;

void main() {
  testWidgets('maps are listed in folders, newest first, and can be selected', (tester) async {
    final maps = [
      _map('a', 'House v1', '2026-11-10T10:00:00Z', 'houses/first'),
      _map('b', 'House v2', '2026-11-12T10:00:00Z', 'houses/first'),
      _map('c', 'Old test', '2026-11-01T10:00:00Z', 'tests'),
      _map('d', 'Loose map', '2026-11-05T10:00:00Z', ''),
    ];
    final selected = <String>{'b'};
    Set<String>? reported;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: MapPicker(maps: maps, selected: selected, onChanged: (ids) => reported = ids))));

    expect(find.text('houses/first / House v2'), findsOneWidget); // the field shows the selection with its folder
    await tester.tap(find.byType(MapPicker));
    await tester.pumpAndSettle();

    // A drop-down: the list opens below the field.
    expect(tester.getTopLeft(find.text('houses')).dy, greaterThan(tester.getBottomLeft(find.byType(InputDecorator)).dy));
    // Folders by their newest map ("houses" before "tests"); the folder holding the selection is open.
    final houses = tester.getTopLeft(find.text('houses')).dy, tests = tester.getTopLeft(find.text('tests')).dy;
    expect(houses, lessThan(tests));
    final v2 = tester.getTopLeft(find.text('House v2')).dy, v1 = tester.getTopLeft(find.text('House v1')).dy;
    expect(v2, lessThan(v1)); // newest first

    await tester.tap(find.text('House v1'));
    await tester.pumpAndSettle();
    expect(reported, {'b', 'a'});

    await tester.tapAt(const Offset(5, 590)); // outside the field and the list
    await tester.pumpAndSettle();
    expect(find.text('houses'), findsNothing);
  });
}
