import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_colors.dart';
import '../../auth/services/auth_service.dart';
import '../models/fleet_command_id.dart';
import '../models/fleet_planning.dart';
import '../models/fleet_student_transport.dart';
import '../services/fleet_planning_error_mapper.dart';
import '../services/fleet_planning_service.dart';
import '../services/fleet_service.dart';

const _weekdayLabels = {
  1: 'Seg',
  2: 'Ter',
  3: 'Qua',
  4: 'Qui',
  5: 'Sex',
  6: 'Sáb',
  7: 'Dom',
};
const _directionLabels = {'going': 'Ida', 'return': 'Volta'};
const _shiftLabels = {
  'morning': 'Manhã',
  'afternoon': 'Tarde',
  'evening': 'Noite',
  'full_time': 'Integral',
};

String _displayDate(String civil) =>
    '${civil.substring(8, 10)}/${civil.substring(5, 7)}/${civil.substring(0, 4)}';

/// Weekly transport plan of one owner-registered student, read and written via RPCs.
class FleetStudentTransportScreen extends StatefulWidget {
  const FleetStudentTransportScreen({
    super.key,
    required this.fleetId,
    required this.userId,
    required this.student,
    required this.authService,
    this.service,
    this.clock = DateTime.now,
  });

  final String fleetId, userId;
  final OwnerEnrolledStudent student;
  final AuthService authService;
  final FleetPlanningService? service;

  /// Injected so tests can pin "today"; production uses the device clock.
  final DateTime Function() clock;

  @override
  State<FleetStudentTransportScreen> createState() =>
      _FleetStudentTransportScreenState();
}

class _FleetStudentTransportScreenState
    extends State<FleetStudentTransportScreen> {
  late final FleetPlanningService _service =
      widget.service ?? FleetPlanningService();
  StreamSubscription<AuthState>? _auth;
  FleetPlanning? _planning;
  Object? _readError;
  bool _loading = true, _submitting = false, _denied = false;
  late String _effectiveOn = civilDate(
    DateTime(_today.year, _today.month, _today.day + 1),
  );
  Map<TransportSlot, String> _selection = {};
  // Bumped whenever the selection is replaced programmatically, so dropdowns
  // (which only read initialValue once) are rebuilt with the new values.
  int _formVersion = 0;
  String? _message;
  // Identity of the last unconfirmed command; reused only for the same payload.
  String? _pendingKey, _pendingCommandId;
  int _readGeneration = 0;

  DateTime get _today {
    final now = widget.clock();
    return DateTime(now.year, now.month, now.day);
  }

  String? get _schoolId => widget.student.schoolId;
  String? get _shift => widget.student.shift;

  @override
  void initState() {
    super.initState();
    _auth = widget.authService.authStateChanges.listen((_) {
      if (widget.authService.currentSession?.user.id != widget.userId) {
        _deny();
      }
    });
    _load(prefill: true);
  }

  @override
  void dispose() {
    _auth?.cancel();
    super.dispose();
  }

  void _deny() {
    if (!mounted) return;
    setState(() {
      _denied = true;
      _planning = null;
      _selection = {};
      _pendingKey = _pendingCommandId = null;
    });
  }

  /// Every read and write re-checks the opening session and owner role.
  Future<void> _ensureAccess() async {
    if (widget.authService.currentSession?.user.id != widget.userId) {
      throw const AuthException('Session changed');
    }
    final access = await widget.authService.getMyAccessContext();
    if (!access.ownerFleetIds.contains(widget.fleetId)) {
      throw const PostgrestException(
        message: 'Owner access required',
        code: 'forbidden',
      );
    }
  }

  Future<void> _load({bool prefill = false}) async {
    final read = ++_readGeneration;
    setState(() {
      _loading = true;
      _readError = null;
    });
    try {
      await _ensureAccess();
      final planning = await _service.load(widget.fleetId);
      if (!mounted || _denied || read != _readGeneration) return;
      setState(() {
        _planning = planning;
        if (prefill) {
          _selection = allocationsInEffect(
            planning,
            widget.student.enrollmentId,
            _effectiveOn,
          );
        }
        _dropIncompatible();
        _formVersion++;
      });
    } catch (error) {
      if (!mounted || read != _readGeneration) return;
      if (PlanningErrorMapper.kind(error) == PlanningFailure.accessLost) {
        _deny();
        return;
      }
      setState(() => _readError = error);
    } finally {
      if (mounted && read == _readGeneration) {
        setState(() => _loading = false);
      }
    }
  }

  List<TransportOption> _options(TransportSlot slot) {
    final planning = _planning, school = _schoolId, shift = _shift;
    if (planning == null || school == null || shift == null) return const [];
    return compatibleTransportOptions(
      planning,
      schoolId: school,
      shift: shift,
      slot: slot,
      effectiveOn: _effectiveOn,
    );
  }

  /// A choice that is no longer compatible (date or planning changed) is discarded.
  void _dropIncompatible() {
    _selection.removeWhere(
      (slot, scheduleId) =>
          !_options(slot).any((option) => option.schedule.id == scheduleId),
    );
  }

  Future<void> _pickDate() async {
    final today = _today;
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime.parse(_effectiveOn),
      firstDate: today,
      lastDate: DateTime(today.year + 1, today.month, today.day),
      helpText: 'Início da programação',
    );
    if (picked == null || !mounted) return;
    setState(() {
      _effectiveOn = civilDate(picked);
      _dropIncompatible();
      _formVersion++;
    });
  }

  Future<void> _submit() async {
    final planning = _planning, school = _schoolId;
    if (planning == null || school == null || _selection.isEmpty) return;
    if (_submitting) return;
    final revision = planning.enrollmentRevisions[widget.student.enrollmentId];
    if (revision == null) {
      setState(
        () => _message =
            'Este aluno não está mais ativo na frota. Recarregue a lista de alunos.',
      );
      return;
    }
    final draft = StudentTransportDraft(
      enrollmentId: widget.student.enrollmentId,
      schoolId: school,
      allocations: _selection,
      effectiveOn: _effectiveOn,
      expectedRoutingRevision: revision,
    );
    // An unconfirmed write is retried with the same id (backend replays the
    // receipt); any change to the payload is a new logical command.
    final key = draft.payloadKey;
    final commandId = key == _pendingKey
        ? _pendingCommandId!
        : createFleetCommandId();
    _pendingKey = key;
    _pendingCommandId = commandId;
    setState(() {
      _submitting = true;
      _message = null;
    });
    try {
      await _ensureAccess();
      await _service.assignStudentTransport(draft, commandId);
      if (!mounted) return;
      _pendingKey = _pendingCommandId = null;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Programação salva.')));
      await _load(); // the saved plan always comes from the backend projection
    } catch (error) {
      if (!mounted) return;
      final kind = PlanningErrorMapper.kind(error);
      if (kind == PlanningFailure.accessLost) {
        _deny();
        return;
      }
      if (kind != PlanningFailure.uncertain) {
        _pendingKey = _pendingCommandId = null;
      }
      setState(() => _message = PlanningErrorMapper.message(error));
      if (error is PostgrestException && error.code == 'revision_conflict') {
        await _load();
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.backgroundWhite,
      appBar: AppBar(title: const Text('Programar transporte')),
      body: _body(),
    );
  }

  Widget _body() {
    if (_denied) {
      return const Center(
        child: Text('Seu acesso à frota não está disponível.'),
      );
    }
    final planning = _planning;
    if (planning == null) {
      if (_loading) return const Center(child: CircularProgressIndicator());
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Não foi possível carregar o planejamento.'),
            ElevatedButton(
              onPressed: () => _load(prefill: true),
              child: const Text('Tentar novamente'),
            ),
          ],
        ),
      );
    }
    final student = widget.student;
    final ready = _schoolId != null && _shift != null;
    final slots = [
      for (final slot in transportSlots)
        if (_options(slot).isNotEmpty) slot,
    ];
    // All slots are built eagerly (not a lazy ListView) so every dropdown is
    // reachable by key and scrollable into view without prior interaction.
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            student.fullName,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
          ),
          Text('Escola: ${student.schoolName ?? 'não definida'}'),
          Text('Turno: ${_shiftLabels[student.shift] ?? 'não definido'}'),
          const SizedBox(height: 16),
          if (!ready)
            const Text(
              'Defina a escola e o turno do aluno antes de programar o transporte.',
            )
          else ...[
            if (_readError != null)
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Não foi possível atualizar a programação salva.',
                      style: TextStyle(color: AppColors.errorRed),
                    ),
                  ),
                  TextButton(
                    onPressed: _load,
                    child: const Text('Tentar novamente'),
                  ),
                ],
              ),
            ..._saved(planning),
            const SizedBox(height: 16),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Início da programação'),
              subtitle: Text(_displayDate(_effectiveOn)),
              trailing: TextButton(
                onPressed: _submitting ? null : _pickDate,
                child: const Text('Alterar data'),
              ),
            ),
            if (slots.isEmpty)
              const Text(
                'Nenhuma rota compatível com a escola e o turno deste aluno nesta data. Configure rotas e horários no planejamento da frota.',
              )
            else
              for (final slot in slots) _slotField(slot),
            if (_message != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _message!,
                  style: const TextStyle(color: AppColors.errorRed),
                ),
              ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _selection.isEmpty || _submitting ? null : _submit,
              child: Text(_submitting ? 'Salvando...' : 'Salvar programação'),
            ),
          ],
        ],
      ),
    );
  }

  List<Widget> _saved(FleetPlanning planning) {
    final names = {for (final route in planning.routes) route.id: route.name};
    final rows = savedStudentReservations(
      planning,
      widget.student.enrollmentId,
      civilDate(_today),
    );
    return [
      const Text(
        'Programação salva',
        style: TextStyle(fontWeight: FontWeight.bold),
      ),
      if (rows.isEmpty)
        const Text(
          'Nenhuma programação salva.',
          style: TextStyle(color: AppColors.textMuted),
        ),
      for (final row in rows)
        Text(
          '${_weekdayLabels[row['weekday']]} · '
          '${_directionLabels[row['direction']]} · '
          '${names[row['route_id']] ?? 'Rota'} · '
          '${_displayDate(row['valid_from']! as String)} a '
          '${_displayDate(row['valid_until']! as String)}',
        ),
    ];
  }

  Widget _slotField(TransportSlot slot) {
    final options = _options(slot);
    return KeyedSubtree(
      key: ValueKey('transport-slot-${slot.weekday}-${slot.direction}'),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: DropdownButtonFormField<String?>(
          key: ValueKey('${slot.weekday}-${slot.direction}-$_formVersion'),
          initialValue: _selection[slot],
          isExpanded: true,
          decoration: InputDecoration(
            labelText:
                '${_weekdayLabels[slot.weekday]} · ${_directionLabels[slot.direction]}',
          ),
          items: [
            const DropdownMenuItem<String?>(
              value: null,
              child: Text('Sem transporte'),
            ),
            for (final option in options)
              DropdownMenuItem<String?>(
                value: option.schedule.id,
                child: Text(
                  '${option.route.name} · ${option.schedule.startsAt.substring(0, 5)}',
                ),
              ),
          ],
          onChanged: _submitting
              ? null
              : (value) => setState(() {
                  if (value == null) {
                    _selection.remove(slot);
                  } else {
                    _selection[slot] = value;
                  }
                }),
        ),
      ),
    );
  }
}
