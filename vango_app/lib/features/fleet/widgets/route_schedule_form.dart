import 'package:flutter/material.dart';
import '../controllers/fleet_planning_controller.dart';
import '../models/fleet_planning.dart';
import '../models/fleet_planning_commands.dart';
import '../models/fleet_command_id.dart';
import 'planning_form_shell.dart';

/// Independent recurring schedule editor using native civil date/time pickers.
class RouteScheduleForm extends StatefulWidget {
  const RouteScheduleForm({
    super.key,
    required this.controller,
    required this.routeId,
    this.initial,
  });
  final FleetPlanningController controller;
  final String routeId;
  final PlanningSchedule? initial;
  @override
  State<RouteScheduleForm> createState() => _RouteScheduleFormState();
}

class _RouteScheduleFormState extends State<RouteScheduleForm> {
  final _key = GlobalKey<FormState>();
  late final _start = TextEditingController(
    text: widget.initial?.startsAt.substring(0, 5),
  );
  late final _end = TextEditingController(
    text: widget.initial?.endsAt.substring(0, 5),
  );
  late final _from = TextEditingController(text: widget.initial?.validFrom);
  late final _until = TextEditingController(text: widget.initial?.validUntil);
  late final _timezone = TextEditingController(
    text: widget.initial?.timezone ?? 'America/Sao_Paulo',
  );
  late final _confirmation = TextEditingController(
    text: widget.initial?.confirmationMinutes.toString(),
  );
  late bool _overnight = widget.initial?.endsNextDay ?? false;
  late final Set<int> _days = widget.initial?.weekdays.toSet() ?? {};
  @override
  void dispose() {
    for (final field in [
      _start,
      _end,
      _from,
      _until,
      _timezone,
      _confirmation,
    ]) {
      field.dispose();
    }
    super.dispose();
  }

  Future<void> _time(TextEditingController field) async {
    final pieces = field.text.split(':');
    final time = await showTimePicker(
      context: context,
      initialTime: pieces.length == 2
          ? TimeOfDay(hour: int.parse(pieces[0]), minute: int.parse(pieces[1]))
          : TimeOfDay.now(),
    );
    if (!mounted || time == null || !widget.controller.active) return;
    setState(
      () => field.text =
          '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}',
    );
  }

  Future<void> _date(TextEditingController field) async {
    final date = await showDatePicker(
      context: context,
      initialDate: DateTime.tryParse(field.text) ?? DateTime.now(),
      firstDate: DateTime(1),
      lastDate: DateTime(9999, 12, 31),
    );
    if (!mounted || date == null || !widget.controller.active) return;
    setState(
      () => field.text =
          '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}',
    );
  }

  @override
  Widget build(BuildContext context) => PlanningFormShell(
    title: widget.initial == null ? 'Novo horário' : 'Editar horário',
    controller: widget.controller,
    formKey: _key,
    onSave: () => widget.controller.saveSchedule(
      SchedulePlanningCommand(
        routeId: widget.routeId,
        commandId: createFleetCommandId(),
        id: widget.initial?.id,
        expectedRevision: widget.initial?.editRevision,
        weekdays: _days.toList()..sort(),
        startsAt: _start.text,
        endsAt: _end.text,
        endsNextDay: _overnight,
        timezone: _timezone.text.trim(),
        validFrom: _from.text,
        validUntil: _until.text,
        confirmationMinutes: int.parse(_confirmation.text),
      ),
    ),
    children: [
      FormField<bool>(
        validator: (_) => _days.isEmpty ? 'Escolha ao menos um dia.' : null,
        builder: (field) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Dias da semana'),
            Wrap(
              spacing: 8,
              children: [
                for (var day = 1; day <= 7; day++)
                  FilterChip(
                    label: Text(
                      const [
                        'Seg',
                        'Ter',
                        'Qua',
                        'Qui',
                        'Sex',
                        'Sáb',
                        'Dom',
                      ][day - 1],
                    ),
                    selected: _days.contains(day),
                    onSelected: (selected) => setState(() {
                      if (selected) {
                        _days.add(day);
                      } else {
                        _days.remove(day);
                      }
                    }),
                  ),
              ],
            ),
            if (field.errorText != null) Text(field.errorText!),
          ],
        ),
      ),
      TextFormField(
        controller: _start,
        readOnly: true,
        decoration: const InputDecoration(
          labelText: 'Horário de início',
          suffixIcon: Icon(Icons.schedule),
        ),
        onTap: () => _time(_start),
        validator: requiredPlanningText,
      ),
      TextFormField(
        controller: _end,
        readOnly: true,
        decoration: const InputDecoration(
          labelText: 'Horário de término',
          suffixIcon: Icon(Icons.schedule),
        ),
        onTap: () => _time(_end),
        validator: (value) =>
            requiredPlanningText(value) ??
            (!_overnight &&
                    _start.text.isNotEmpty &&
                    value!.compareTo(_start.text) <= 0
                ? 'O término deve ser após o início.'
                : null),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Termina no dia seguinte'),
        value: _overnight,
        onChanged: (value) => setState(() => _overnight = value),
      ),
      TextFormField(
        controller: _timezone,
        decoration: const InputDecoration(labelText: 'Fuso horário'),
        validator: requiredPlanningText,
      ),
      TextFormField(
        controller: _from,
        readOnly: true,
        decoration: const InputDecoration(
          labelText: 'Válido a partir de',
          suffixIcon: Icon(Icons.calendar_month),
        ),
        onTap: () => _date(_from),
        validator: requiredPlanningText,
      ),
      TextFormField(
        controller: _until,
        readOnly: true,
        decoration: const InputDecoration(
          labelText: 'Válido até',
          suffixIcon: Icon(Icons.calendar_month),
        ),
        onTap: () => _date(_until),
        validator: (value) =>
            requiredPlanningText(value) ??
            (_from.text.isNotEmpty && value!.compareTo(_from.text) < 0
                ? 'A data final deve ser igual ou posterior à inicial.'
                : null),
      ),
      TextFormField(
        controller: _confirmation,
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(
          labelText: 'Antecedência da confirmação (minutos)',
          helperText: 'Prazo antes do início para confirmar presença.',
        ),
        validator: (value) {
          final minutes = int.tryParse(value ?? '');
          return minutes == null || minutes < 0 || minutes > 1440
              ? 'Informe de 0 a 1440 minutos.'
              : null;
        },
      ),
    ],
  );
}
