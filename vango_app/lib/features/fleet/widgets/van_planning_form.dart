import 'package:flutter/material.dart';
import '../controllers/fleet_planning_controller.dart';
import '../models/fleet_planning.dart';
import '../models/fleet_planning_commands.dart';
import '../models/fleet_command_id.dart';
import 'planning_form_shell.dart';

/// Independent vehicle editor, retaining the revision that opened the draft.
class VanPlanningForm extends StatefulWidget {
  const VanPlanningForm({super.key, required this.controller, this.initial});
  final FleetPlanningController controller;
  final PlanningVan? initial;
  @override
  State<VanPlanningForm> createState() => _VanPlanningFormState();
}

class _VanPlanningFormState extends State<VanPlanningForm> {
  final _key = GlobalKey<FormState>();
  late final _plate = TextEditingController(text: widget.initial?.plate);
  late final _model = TextEditingController(text: widget.initial?.model);
  late final _name = TextEditingController(text: widget.initial?.publicName);
  late final _capacity = TextEditingController(
    text: widget.initial?.capacity.toString(),
  );
  @override
  void dispose() {
    for (final field in [_plate, _model, _name, _capacity]) {
      field.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PlanningFormShell(
    title: widget.initial == null ? 'Nova van' : 'Editar van',
    controller: widget.controller,
    formKey: _key,
    onSave: () => widget.controller.saveVan(
      VanPlanningCommand(
        fleetId: widget.controller.fleetId,
        commandId: createFleetCommandId(),
        id: widget.initial?.id,
        expectedRevision: widget.initial?.editRevision,
        plate: _plate.text.trim(),
        model: _model.text.trim(),
        publicName: _name.text.trim(),
        capacity: int.parse(_capacity.text),
      ),
    ),
    children: [
      TextFormField(
        controller: _plate,
        decoration: const InputDecoration(labelText: 'Placa'),
        textCapitalization: TextCapitalization.characters,
        validator: (value) =>
            RegExp(r'^[A-Z]{3}[0-9][A-Z0-9][0-9]{2}$').hasMatch(
              (value ?? '').toUpperCase().replaceAll(RegExp(r'[\s-]'), ''),
            )
            ? null
            : 'Informe uma placa válida.',
      ),
      TextFormField(
        controller: _model,
        decoration: const InputDecoration(labelText: 'Modelo'),
        validator: requiredPlanningText,
      ),
      TextFormField(
        controller: _name,
        decoration: const InputDecoration(labelText: 'Nome da van'),
        validator: requiredPlanningText,
      ),
      TextFormField(
        controller: _capacity,
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(labelText: 'Capacidade'),
        validator: (value) {
          final capacity = int.tryParse(value ?? '');
          return capacity == null || capacity < 1 || capacity > 100
              ? 'Informe de 1 a 100 lugares.'
              : null;
        },
      ),
    ],
  );
}
