import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:vango_app/features/fleet/controllers/fleet_planning_controller.dart';
import 'package:vango_app/features/fleet/models/fleet_command_id.dart';
import 'package:vango_app/features/fleet/models/fleet_planning_commands.dart';
import 'package:vango_app/features/fleet/services/fleet_planning_service.dart';

/// Opt-in real persistence check against the owned disposable HTTP fixture.
void main() {
  const statusPath = String.fromEnvironment('VANGO_TEST_STATUS');
  test(
    'native planning client commits and reopens actual persisted configuration',
    () async {
      final status =
          jsonDecode(File(statusPath).readAsStringSync())
              as Map<String, dynamic>;
      final url = Uri.parse(status['API_URL'] as String);
      expect(url.host, anyOf('127.0.0.1', 'localhost'));
      expect(url.port, 56321);
      final client = SupabaseClient(
        url.toString(),
        status['ANON_KEY'] as String,
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      addTearDown(client.dispose);
      await client.auth.signInWithPassword(
        email: 'owner-a1@example.test',
        password: 'local-test-password',
      );
      const fleet = '41000000-0000-0000-0000-000000000001';
      final service = FleetPlanningService(client: client);
      final controller = FleetPlanningController(
        service: service,
        userId: client.auth.currentUser!.id,
        fleetId: fleet,
        refreshAccess: () async {
          await client.rpc('get_my_access_context');
        },
      );
      addTearDown(controller.dispose);
      await controller.load();
      expect(controller.readError, isNull);
      expect(controller.planning, isNotNull);
      final commandId = createFleetCommandId();
      final plate = 'NAT${DateTime.now().millisecondsSinceEpoch % 10000}'
          .padRight(7, '0');
      final command = VanPlanningCommand(
        fleetId: fleet,
        commandId: commandId,
        plate: plate,
        model: 'Native integration',
        publicName: 'Native persistence',
        capacity: 14,
      );
      await controller.saveVan(command);
      expect(controller.outcome, PlanningWriteOutcome.committed);
      expect(controller.readError, isNull);
      final reopened = await FleetPlanningService(client: client).load(fleet);
      final van = reopened.vans.singleWhere((van) => van.plate == plate);
      expect(van.capacity, 14);
      expect(await service.saveVan(command), van.id);
      final afterReplay = await service.load(fleet);
      expect(
        afterReplay.vans.where((entry) => entry.id == van.id),
        hasLength(1),
      );
      expect(afterReplay.reservations, reopened.reservations);
      expect(afterReplay.enrollmentRevisions, reopened.enrollmentRevisions);
    },
    skip: statusPath.isEmpty
        ? 'Set VANGO_TEST_STATUS for the owned local fixture'
        : false,
  );
}
