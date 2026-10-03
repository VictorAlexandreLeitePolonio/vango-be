import 'package:flutter/material.dart';
import '../controllers/fleet_planning_controller.dart';
import '../models/fleet_planning.dart';
import '../models/fleet_planning_commands.dart';
import '../models/fleet_command_id.dart';
import 'planning_form_shell.dart';
import 'route_point_picker.dart';
import 'fleet_school_selector.dart';

/// Independent route editor; no endpoint or operator is implicitly selected.
class RoutePlanningForm extends StatefulWidget {
  const RoutePlanningForm({super.key, required this.controller, this.initial});
  final FleetPlanningController controller;
  final PlanningRoute? initial;
  @override
  State<RoutePlanningForm> createState() => _RoutePlanningFormState();
}

class _RoutePlanningFormState extends State<RoutePlanningForm> {
  final _key = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.initial?.name);
  late final _proximity = TextEditingController(
    text: (widget.initial?.proximityMinutes ?? 10).toString(),
  );
  late String _direction = widget.initial?.direction ?? 'going',
      _shift = widget.initial?.shift ?? 'morning';
  late String? _van = widget.initial?.vanId,
      _driver = widget.initial?.driverUserId;
  late PlanningPoint? _origin = widget.initial?.origin,
      _destination = widget.initial?.destination;
  late List<String> _schools =
      widget.initial?.schools.map((s) => s.schoolId).toList() ?? [];
  @override
  void dispose() {
    _name.dispose();
    _proximity.dispose();
    super.dispose();
  }

  Future<void> _pick(bool origin) async {
    final point = await Navigator.push<PlanningPoint>(
      context,
      MaterialPageRoute(
        builder: (_) => RoutePointPicker(
          controller: widget.controller,
          initial: origin ? _origin : _destination,
        ),
      ),
    );
    if (!mounted || !widget.controller.active || point == null) return;
    setState(() {
      if (origin) {
        _origin = point;
      } else {
        _destination = point;
      }
    });
  }

  Widget _endpoint(bool origin, List<PlanningSchool> options) {
    final point = origin ? _origin : _destination;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OutlinedButton(
          onPressed: () => _pick(origin),
          child: Text(origin ? 'Selecionar origem' : 'Selecionar destino'),
        ),
        if (point != null)
          Text(
            '${point.label} (${point.latitude.toStringAsFixed(5)}, ${point.longitude.toStringAsFixed(5)})',
          ),
        DropdownButton<PlanningSchool>(
          isExpanded: true,
          hint: Text(
            origin
                ? 'Usar instituição como origem'
                : 'Usar instituição como destino',
          ),
          items: [
            for (final school in options)
              DropdownMenuItem(
                value: school,
                child: Text(
                  '${school.name} — ${school.city.cityName}',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: (school) {
            if (school == null) return;
            setState(() {
              final point = (
                latitude: school.latitude,
                longitude: school.longitude,
                label: school.name,
              );
              if (origin) {
                _origin = point;
              } else {
                _destination = point;
              }
            });
          },
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final planning = widget.controller.planning!;
    final vans = planning.vans.where((v) => v.status == 'active').toList();
    return PlanningFormShell(
      title: widget.initial == null ? 'Nova rota' : 'Editar rota',
      controller: widget.controller,
      formKey: _key,
      onSave: () => widget.controller.saveRoute(
        RoutePlanningCommand(
          fleetId: widget.controller.fleetId,
          commandId: createFleetCommandId(),
          id: widget.initial?.id,
          expectedRevision: widget.initial?.editRevision,
          name: _name.text.trim(),
          direction: _direction,
          shift: _shift,
          vanId: _van!,
          driverUserId: _driver!,
          origin: _origin!,
          destination: _destination!,
          schoolIds: _schools,
          proximityMinutes: int.parse(_proximity.text),
          pairedRouteId: widget.initial?.pairedRouteId,
        ),
      ),
      children: [
        TextFormField(
          controller: _name,
          decoration: const InputDecoration(labelText: 'Nome da rota'),
          validator: requiredPlanningText,
        ),
        DropdownButtonFormField<String>(
          initialValue: _direction,
          decoration: const InputDecoration(labelText: 'Sentido'),
          items: const [
            DropdownMenuItem(value: 'going', child: Text('Ida')),
            DropdownMenuItem(value: 'return', child: Text('Volta')),
          ],
          onChanged: (value) => setState(() => _direction = value!),
        ),
        DropdownButtonFormField<String>(
          initialValue: _shift,
          decoration: const InputDecoration(labelText: 'Turno'),
          items: const [
            DropdownMenuItem(value: 'morning', child: Text('Manhã')),
            DropdownMenuItem(value: 'afternoon', child: Text('Tarde')),
            DropdownMenuItem(value: 'evening', child: Text('Noite')),
            DropdownMenuItem(value: 'full_time', child: Text('Integral')),
          ],
          onChanged: (value) => setState(() => _shift = value!),
        ),
        DropdownButtonFormField<String>(
          initialValue: vans.any((v) => v.id == _van) ? _van : null,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Van'),
          items: [
            for (final van in vans)
              DropdownMenuItem(
                value: van.id,
                child: Text(
                  '${van.publicName} • ${van.plate}',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: (value) => _van = value,
          validator: requiredPlanningText,
        ),
        DropdownButtonFormField<String>(
          initialValue: planning.drivers.any((d) => d.userId == _driver)
              ? _driver
              : null,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Motorista'),
          items: [
            for (final driver in planning.drivers)
              DropdownMenuItem(
                value: driver.userId,
                child: Text(
                  driver.displayName ?? 'Motorista',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: (value) => _driver = value,
          validator: requiredPlanningText,
        ),
        if (planning.drivers.isEmpty)
          const Text(
            'Ative sua participação como motorista na tela de planejamento ou vincule um motorista à equipe.',
          ),
        FormField<bool>(
          validator: (_) => _origin == null || _destination == null
              ? 'Selecione e confirme origem e destino.'
              : null,
          builder: (field) => Column(
            children: [
              _endpoint(true, planning.schools),
              _endpoint(false, planning.schools),
              if (field.errorText != null) Text(field.errorText!),
            ],
          ),
        ),
        FormField<bool>(
          validator: (_) =>
              _schools.isEmpty ||
                  _schools.any((id) => !planning.schools.any((s) => s.id == id))
              ? 'Selecione instituições disponíveis.'
              : null,
          builder: (field) => Column(
            children: [
              FleetSchoolSelector(
                options: planning.schools,
                selected: _schools,
                onChanged: (ids) => setState(() => _schools = ids),
              ),
              if (field.errorText != null) Text(field.errorText!),
            ],
          ),
        ),
        TextFormField(
          controller: _proximity,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Aviso de proximidade (minutos)',
            helperText: 'Antecedência estimada para avisar sobre a chegada.',
          ),
          validator: (value) {
            final minutes = int.tryParse(value ?? '');
            return minutes == null || minutes < 1 || minutes > 60
                ? 'Informe de 1 a 60 minutos.'
                : null;
          },
        ),
      ],
    );
  }
}
