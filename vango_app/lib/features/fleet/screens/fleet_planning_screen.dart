import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../auth/services/auth_service.dart';
import '../controllers/fleet_planning_controller.dart';
import '../models/fleet_command_id.dart';
import '../services/fleet_planning_service.dart';
import '../services/fleet_planning_error_mapper.dart';
import '../widgets/van_planning_form.dart';
import '../widgets/route_planning_form.dart';
import '../widgets/route_schedule_form.dart';
import '../widgets/fleet_coverage_form.dart';

/// Persisted owner configuration, scoped to the opening user and fleet.
class FleetPlanningScreen extends StatefulWidget {
  const FleetPlanningScreen({
    super.key,
    required this.fleetId,
    required this.userId,
    required this.authService,
    this.service,
  });
  final String fleetId, userId;
  final AuthService authService;
  final FleetPlanningService? service;
  @override
  State<FleetPlanningScreen> createState() => _FleetPlanningScreenState();
}

class _FleetPlanningScreenState extends State<FleetPlanningScreen> {
  late FleetPlanningController _controller;
  StreamSubscription<AuthState>? _auth;
  @override
  void initState() {
    super.initState();
    _bind();
  }

  void _bind() {
    final auth = widget.authService,
        user = widget.userId,
        fleet = widget.fleetId;
    _controller = FleetPlanningController(
      service: widget.service ?? FleetPlanningService(),
      userId: widget.userId,
      fleetId: widget.fleetId,
      refreshAccess: () async {
        if (auth.currentSession?.user.id != user) {
          throw const AuthException('Session changed');
        }
        final access = await auth.getMyAccessContext();
        if (!access.ownerFleetIds.contains(fleet)) {
          throw const PostgrestException(
            message: 'Owner access required',
            code: 'forbidden',
          );
        }
      },
    );
    _auth = auth.authStateChanges.listen((event) {
      if (event.session?.user.id != user) _controller.clearContext();
    });
    unawaited(_controller.load());
  }

  @override
  void didUpdateWidget(covariant FleetPlanningScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.fleetId != widget.fleetId ||
        oldWidget.userId != widget.userId ||
        oldWidget.authService != widget.authService ||
        oldWidget.service != widget.service) {
      unawaited(_auth?.cancel());
      _controller.clearContext();
      _controller.dispose();
      _bind();
    }
  }

  @override
  void dispose() {
    unawaited(_auth?.cancel());
    _controller.dispose();
    super.dispose();
  }

  Future<void> _open(Widget Function() editor) async {
    if (!_controller.beginDraft()) return;
    await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => editor()),
    );
  }

  Widget _heading(String text) => Padding(
    padding: const EdgeInsets.only(top: 24, bottom: 8),
    child: Text(text, style: Theme.of(context).textTheme.titleLarge),
  );
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controller,
    builder: (context, _) {
      final planning = _controller.planning;
      return Scaffold(
        appBar: AppBar(
          title: const Text('Planejamento da frota'),
          actions: [
            IconButton(
              tooltip: 'Atualizar planejamento',
              onPressed: _controller.loading ? null : _controller.load,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        body: !_controller.active
            ? const Center(
                child: Text('Seu acesso à frota não está disponível.'),
              )
            : planning == null
            ? Center(
                child: _controller.loading
                    ? const CircularProgressIndicator()
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text(
                            'Não foi possível carregar o planejamento.',
                          ),
                          FilledButton(
                            onPressed: _controller.load,
                            child: const Text('Tentar novamente'),
                          ),
                        ],
                      ),
              )
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (_controller.loading) const LinearProgressIndicator(),
                  if (_controller.readError != null)
                    const Text(
                      'Não foi possível atualizar a visualização. Tente atualizar novamente.',
                    ),
                  if (_controller.error case final error?)
                    Text(PlanningErrorMapper.message(error)),
                  if (_controller.outcome == PlanningWriteOutcome.uncertain)
                    FilledButton(
                      onPressed: _controller.retryPending,
                      child: const Text('Verificar envio novamente'),
                    ),
                  _heading('Cidades atendidas'),
                  if (planning.cities.isEmpty)
                    const Text('Nenhuma cidade cadastrada.'),
                  for (final city in planning.cities)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text('${city.cityName} — ${city.stateCode}'),
                    ),
                  OutlinedButton(
                    onPressed: _controller.canSubmit
                        ? () => _open(
                            () => FleetCoverageForm(
                              controller: _controller,
                              kind: CoverageKind.city,
                            ),
                          )
                        : null,
                    child: const Text('Adicionar cidade'),
                  ),
                  _heading('Instituições atendidas'),
                  if (planning.schools.isEmpty)
                    const Text('Nenhuma instituição disponível vinculada.'),
                  for (final school in planning.schools)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(school.name),
                      subtitle: Text(
                        '${school.institutionType == 'school' ? 'Escola' : 'Faculdade / campus'} • ${school.city.cityName}\n${school.street}, ${school.streetNumber}',
                      ),
                    ),
                  OutlinedButton(
                    onPressed:
                        _controller.canSubmit && planning.cities.isNotEmpty
                        ? () => _open(
                            () => FleetCoverageForm(
                              controller: _controller,
                              kind: CoverageKind.school,
                            ),
                          )
                        : null,
                    child: const Text('Adicionar instituição'),
                  ),
                  _heading('Vans'),
                  if (planning.vans.isEmpty)
                    const Text('Nenhuma van cadastrada.'),
                  for (final van in planning.vans)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(van.publicName),
                      subtitle: Text(
                        '${van.plate} • ${van.capacity} lugares • ${van.status == 'active' ? 'Ativa' : 'Inativa'}',
                      ),
                      trailing: const Icon(Icons.edit_outlined),
                      onTap: _controller.canSubmit
                          ? () => _open(
                              () => VanPlanningForm(
                                controller: _controller,
                                initial: van,
                              ),
                            )
                          : null,
                    ),
                  OutlinedButton(
                    onPressed: _controller.canSubmit
                        ? () => _open(
                            () => VanPlanningForm(controller: _controller),
                          )
                        : null,
                    child: const Text('Adicionar van'),
                  ),
                  _heading('Motoristas'),
                  for (final driver in planning.drivers)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(driver.displayName ?? 'Motorista'),
                    ),
                  if (!planning.ownerOperator.isDriver)
                    OutlinedButton(
                      onPressed: _controller.canSubmit
                          ? () async {
                              if (_controller.beginDraft()) {
                                await _controller.enableOwnerDriving(
                                  createFleetCommandId(),
                                );
                              }
                            }
                          : null,
                      child: const Text('Também vou dirigir'),
                    ),
                  _heading('Rotas e horários'),
                  if (planning.routes.isEmpty)
                    const Text('Nenhuma rota cadastrada.'),
                  for (final route in planning.routes)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              title: Text(route.name),
                              subtitle: Text(
                                '${route.direction == 'going' ? 'Ida' : 'Volta'} • ${route.origin.label} → ${route.destination.label}',
                              ),
                              trailing: const Icon(Icons.edit_outlined),
                              onTap: _controller.canSubmit
                                  ? () => _open(
                                      () => RoutePlanningForm(
                                        controller: _controller,
                                        initial: route,
                                      ),
                                    )
                                  : null,
                            ),
                            for (final schedule in planning.schedules.where(
                              (s) => s.routeId == route.id,
                            ))
                              ListTile(
                                contentPadding: EdgeInsets.zero,
                                title: Text(
                                  '${schedule.startsAt.substring(0, 5)}–${schedule.endsAt.substring(0, 5)}${schedule.endsNextDay ? ' (dia seguinte)' : ''}',
                                ),
                                subtitle: Text(
                                  '${schedule.weekdays.map((d) => const ['Seg', 'Ter', 'Qua', 'Qui', 'Sex', 'Sáb', 'Dom'][d - 1]).join(', ')}\n${schedule.validFrom} a ${schedule.validUntil} • ${schedule.timezone}',
                                ),
                                onTap: _controller.canSubmit
                                    ? () => _open(
                                        () => RouteScheduleForm(
                                          controller: _controller,
                                          routeId: route.id,
                                          initial: schedule,
                                        ),
                                      )
                                    : null,
                              ),
                            TextButton(
                              onPressed: _controller.canSubmit
                                  ? () => _open(
                                      () => RouteScheduleForm(
                                        controller: _controller,
                                        routeId: route.id,
                                      ),
                                    )
                                  : null,
                              child: const Text('Adicionar horário'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  OutlinedButton(
                    onPressed: _controller.canSubmit
                        ? () => _open(
                            () => RoutePlanningForm(controller: _controller),
                          )
                        : null,
                    child: const Text('Adicionar rota'),
                  ),
                ],
              ),
      );
    },
  );
}
