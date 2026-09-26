import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:vango_app/features/fleet/controllers/fleet_planning_controller.dart';
import 'package:vango_app/features/fleet/models/fleet_planning.dart';
import 'package:vango_app/features/fleet/models/fleet_planning_commands.dart';
import 'package:vango_app/features/fleet/services/fleet_planning_service.dart';
import 'fleet_planning_test.dart';

class ControlledPlanningService extends FleetPlanningService {
  ControlledPlanningService()
    : super(
        client: SupabaseClient(
          'https://example.test',
          'test',
          authOptions: const AuthClientOptions(autoRefreshToken: false),
        ),
      );
  String? user = 'user';
  final requests = <VanPlanningCommand>[];
  final loadedFleets = <String>[];
  final result = Completer<String>();
  final schoolResult = Completer<List<PlanningSchool>>();
  @override
  Future<List<PlanningSchool>> searchSchools(
    String city,
    String query, {
    String? type,
    int offset = 0,
  }) => schoolResult.future;
  @override
  String? get currentUserId => user;
  @override
  Future<String> saveVan(VanPlanningCommand command) {
    requests.add(command);
    return result.future;
  }

  @override
  Future<FleetPlanning> load(String fleetId) async {
    loadedFleets.add(fleetId);
    return FleetPlanning.fromJson(planningFixture());
  }
}

class RecoveryPlanningService extends ControlledPlanningService {
  Object? writeFailure, readFailure, catalogFailure;
  int writes = 0;
  final searches = <Completer<List<PlanningSchool>>>[];
  Future<String> write() async {
    writes++;
    if (writeFailure case final Object error) {
      throw error;
    }
    return 'saved';
  }

  @override
  Future<String> saveVan(VanPlanningCommand command) {
    requests.add(command);
    return write();
  }

  @override
  Future<String> saveRoute(RoutePlanningCommand command) => write();
  @override
  Future<String> saveSchedule(SchedulePlanningCommand command) => write();
  @override
  Future<List<String>> enableOwnerDriving(String fleet, String command) async {
    await write();
    return ['owner', 'driver'];
  }

  @override
  Future<void> linkCity(String fleet, String city, String command) async {
    await write();
  }

  @override
  Future<void> linkSchool(String fleet, String school, String command) async {
    await write();
  }

  @override
  Future<FleetPlanning> load(String fleet) async {
    if (readFailure case final Object error) {
      throw error;
    }
    return super.load(fleet);
  }

  @override
  Future<List<PlanningCity>> cities() async {
    if (catalogFailure case final Object error) {
      throw error;
    }
    return FleetPlanning.fromJson(planningFixture()).cities;
  }

  @override
  Future<List<PlanningSchool>> searchSchools(
    String city,
    String query, {
    String? type,
    int offset = 0,
  }) {
    final result = Completer<List<PlanningSchool>>();
    searches.add(result);
    return result.future;
  }
}

void main() {
  const command = VanPlanningCommand(
    fleetId: 'fleet',
    commandId: 'command',
    plate: 'ABC1234',
    model: 'Model',
    publicName: 'Van',
    capacity: 12,
  );
  FleetPlanningController controllerFor(RecoveryPlanningService service) {
    final controller = FleetPlanningController(
      service: service,
      userId: 'user',
      fleetId: 'fleet',
      refreshAccess: () async {},
    );
    addTearDown(controller.dispose);
    return controller;
  }

  test(
    'unknown write retries immutable command and committed read failure never resends',
    () async {
      final service = RecoveryPlanningService()
        ..writeFailure = TimeoutException('unconfirmed');
      final controller = controllerFor(service);
      await controller.saveVan(command);
      expect(controller.outcome, PlanningWriteOutcome.uncertain);
      expect(controller.beginDraft(), isFalse);
      await controller.saveVan(command);
      expect(service.writes, 1);
      service.writeFailure = null;
      service.readFailure = TimeoutException('read');
      await controller.retryPending();
      expect(service.requests[0], same(service.requests[1]));
      expect(controller.outcome, PlanningWriteOutcome.committed);
      expect(controller.readError, isNotNull);
      await controller.retryPending();
      expect(service.writes, 2);
      service.readFailure = null;
      await controller.load();
      expect(service.writes, 2);
      expect(controller.planning, isNotNull);
      expect(controller.beginDraft(), isTrue);
      expect(controller.outcome, PlanningWriteOutcome.idle);
    },
  );
  test(
    'definitive conflict requires reload and current access loss clears all state',
    () async {
      final service = RecoveryPlanningService()
        ..writeFailure = const PostgrestException(
          message: 'private',
          code: 'idempotency_conflict',
        );
      final controller = controllerFor(service);
      await controller.load();
      await controller.loadCities();
      await controller.saveVan(command);
      expect(controller.canSubmit, isFalse);
      await controller.retryPending();
      expect(service.writes, 1);
      await controller.load();
      expect(controller.canSubmit, isTrue);
      service.writeFailure = const PostgrestException(
        message: 'private',
        code: 'revision_conflict',
      );
      await controller.saveVan(command);
      expect(controller.outcome, PlanningWriteOutcome.rejected);
      service.writeFailure = const PostgrestException(
        message: 'private',
        code: 'forbidden',
      );
      await controller.saveVan(command);
      expect(controller.active, isFalse);
      expect(controller.planning, isNull);
      expect(controller.catalogCities, isEmpty);
    },
  );
  test(
    'catalog search ignores older responses and handles access failures',
    () async {
      final service = RecoveryPlanningService(),
          controller = controllerFor(service);
      final old = controller.searchSchools('3550000', 'old');
      final current = controller.searchSchools('3550000', 'new');
      final schools = FleetPlanning.fromJson(planningFixture()).schools;
      service.searches[1].complete(schools);
      await current;
      service.searches[0].complete([]);
      await old;
      expect(controller.schoolResults, schools);
      expect(controller.catalogLoading, isFalse);
      service.catalogFailure = TimeoutException('catalog');
      await controller.loadCities();
      expect(controller.catalogError, isNotNull);
      service.catalogFailure = const AuthException('expired');
      await controller.loadCities();
      expect(controller.active, isFalse);
    },
  );
  test(
    'explicit adapters and configuration saves refresh persisted data',
    () async {
      final service = RecoveryPlanningService(),
          controller = controllerFor(service);
      await controller.load();
      final route = controller.planning!.routes.first;
      await controller.enableOwnerDriving('driver');
      await controller.linkCity('3550000', 'city');
      await controller.linkSchool('school', 'school');
      await controller.saveRoute(
        RoutePlanningCommand(
          fleetId: 'fleet',
          commandId: 'route',
          name: route.name,
          direction: route.direction,
          shift: route.shift,
          vanId: route.vanId,
          driverUserId: route.driverUserId,
          origin: route.origin,
          destination: route.destination,
          schoolIds: route.schools.map((s) => s.schoolId).toList(),
          proximityMinutes: 10,
        ),
      );
      await controller.saveSchedule(
        SchedulePlanningCommand(
          routeId: route.id,
          commandId: 'schedule',
          weekdays: [1],
          startsAt: '08:00',
          endsAt: '09:00',
          endsNextDay: false,
          timezone: 'America/Sao_Paulo',
          validFrom: '2026-10-01',
          validUntil: '2026-11-01',
          confirmationMinutes: 0,
        ),
      );
      expect(service.writes, 5);
      expect(service.loadedFleets, hasLength(6));
      expect(
        () => controller.saveVan(
          const VanPlanningCommand(
            fleetId: 'other',
            commandId: 'x',
            plate: 'ABC1234',
            model: 'm',
            publicName: 'v',
            capacity: 1,
          ),
        ),
        throwsStateError,
      );
      service.readFailure = const AuthException('revoked');
      await controller.load();
      expect(controller.active, isFalse);
    },
  );

  test(
    'double submit sends once and logout discards late completion',
    () async {
      final service = ControlledPlanningService();
      final controller = FleetPlanningController(
        service: service,
        userId: 'user',
        fleetId: 'fleet',
        refreshAccess: () async {},
      );
      addTearDown(controller.dispose);
      const command = VanPlanningCommand(
        fleetId: 'fleet',
        commandId: 'command',
        plate: 'ABC1234',
        model: 'Model',
        publicName: 'Van',
        capacity: 12,
      );
      final first = controller.saveVan(command);
      await controller.saveVan(command);
      expect(service.requests, hasLength(1));
      controller.clearContext();
      service.user = null;
      service.result.complete('id');
      await first;
      expect(controller.planning, isNull);
      expect(controller.outcome, PlanningWriteOutcome.idle);
    },
  );
  test(
    'catalog responses are discarded after the owning session changes',
    () async {
      final service = ControlledPlanningService();
      final controller = FleetPlanningController(
        service: service,
        userId: 'user',
        fleetId: 'fleet',
        refreshAccess: () async {},
      );
      addTearDown(controller.dispose);
      final request = controller.searchSchools('3550308', 'school');
      service.user = 'another-user';
      service.schoolResult.complete(
        FleetPlanning.fromJson(planningFixture()).schools,
      );
      await request;
      expect(controller.schoolResults, isEmpty);
      expect(controller.active, isFalse);
    },
  );
}
