import 'package:flutter/material.dart';
import '../models/fleet_planning.dart';

/// Selects unique served institutions and orders them with accessible buttons.
class FleetSchoolSelector extends StatelessWidget {
  const FleetSchoolSelector({
    super.key,
    required this.options,
    required this.selected,
    required this.onChanged,
  });
  final List<PlanningSchool> options;
  final List<String> selected;
  final ValueChanged<List<String>> onChanged;
  String _name(String id) =>
      options.where((s) => s.id == id).firstOrNull?.name ??
      'Instituição indisponível';
  void _move(int index, int delta) {
    final ids = List<String>.of(selected);
    final id = ids.removeAt(index);
    ids.insert(index + delta, id);
    onChanged(ids);
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Text('Instituições e ordem das paradas'),
      for (final school in options)
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(school.name),
          subtitle: Text(
            '${school.city.cityName} • ${school.street}, ${school.streetNumber}',
          ),
          value: selected.contains(school.id),
          onChanged: (checked) => onChanged(
            checked == true
                ? [...selected, school.id]
                : selected.where((id) => id != school.id).toList(),
          ),
        ),
      for (var i = 0; i < selected.length; i++)
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text('${i + 1}. ${_name(selected[i])}'),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: 'Mover ${_name(selected[i])} para cima',
                onPressed: i == 0 ? null : () => _move(i, -1),
                icon: const Icon(Icons.arrow_upward),
              ),
              IconButton(
                tooltip: 'Mover ${_name(selected[i])} para baixo',
                onPressed: i == selected.length - 1 ? null : () => _move(i, 1),
                icon: const Icon(Icons.arrow_downward),
              ),
              IconButton(
                tooltip: 'Remover ${_name(selected[i])}',
                onPressed: () => onChanged(
                  selected.where((id) => id != selected[i]).toList(),
                ),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
    ],
  );
}
