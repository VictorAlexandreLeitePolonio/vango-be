import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:vango_app/features/fleet/models/fleet_planning_commands.dart';
import 'package:vango_app/features/fleet/models/fleet_student_transport.dart';
import 'fleet_planning_test.dart';
import 'package:vango_app/features/fleet/services/fleet_planning_service.dart';

const testId = '11111111-1111-4111-8111-111111111111';
Future<SupabaseClient> planningClient(MockClientHandler handler) async {
  final client = SupabaseClient(
    'https://example.supabase.co',
    'test-key',
    httpClient: MockClient(handler),
  );
  final user = User(
    id: testId,
    appMetadata: const {},
    userMetadata: const {},
    aud: 'authenticated',
    createdAt: '2026-01-01T00:00:00Z',
  );
  await client.auth.recoverSession(
    jsonEncode(
      Session(
        accessToken: 'test-token',
        refreshToken: 'test-refresh',
        tokenType: 'bearer',
        user: user,
      ).toJson(),
    ),
  );
  return client;
}

void main() {
  test(
    'creation sends exact overload keys including explicit null revisions',
    () async {
      final client = await planningClient((request) async {
        expect(request.url.path, endsWith('/rpc/save_van'));
        expect(jsonDecode(request.body), {
          'p_fleet_id': testId,
          'p_van_id': null,
          'p_plate': 'ABC1234',
          'p_model': 'Model',
          'p_public_name': 'Van',
          'p_capacity': 12,
          'p_command_id': testId,
          'p_expected_revision': null,
        });
        return http.Response(
          jsonEncode(testId),
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      });
      addTearDown(client.dispose);
      expect(
        await FleetPlanningService(client: client).saveVan(
          VanPlanningCommand(
            fleetId: testId,
            commandId: testId,
            plate: 'ABC1234',
            model: 'Model',
            publicName: 'Van',
            capacity: 12,
          ),
        ),
        testId,
      );
    },
  );
  test(
    'planning and catalog contracts retain immutable input and exact parameters',
    () async {
      final seen = <String, Map<String, dynamic>>{};
      final fixture = planningFixture();
      final client = await planningClient((request) async {
        final name = request.url.path.split('/').last;
        seen[name] = request.body.isEmpty
            ? {}
            : jsonDecode(request.body) as Map<String, dynamic>;
        final Object? result = switch (name) {
          'get_fleet_planning' => fixture,
          'catalog_municipalities' => fixture['service_cities'],
          'search_schools' => [
            for (final row in fixture['service_schools'] as List)
              {...row as Map<String, dynamic>, 'id': row['school_id']},
          ],
          'enable_owner_driving' => ['owner', 'driver'],
          'link_fleet_service_city' || 'link_fleet_service_school' => null,
          _ => testId,
        };
        return http.Response(
          jsonEncode(result),
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      });
      addTearDown(client.dispose);
      final service = FleetPlanningService(client: client);
      expect(service.currentUserId, testId);
      final data = await service.load(testId), route = data.routes.first;
      final schools = [data.schools.first.id];
      final routeCommand = RoutePlanningCommand(
        fleetId: testId,
        commandId: testId,
        name: route.name,
        direction: route.direction,
        shift: route.shift,
        vanId: route.vanId,
        driverUserId: route.driverUserId,
        origin: route.origin,
        destination: route.destination,
        schoolIds: schools,
        proximityMinutes: 10,
        id: route.id,
        expectedRevision: route.editRevision,
      );
      schools.clear();
      expect(await service.saveRoute(routeCommand), testId);
      expect(seen['save_route']!['p_expected_revision'], route.editRevision);
      expect((seen['save_route']!['p_config'] as Map)['schools'], hasLength(1));
      final weekdays = [1, 2];
      final command = SchedulePlanningCommand(
        routeId: route.id,
        commandId: testId,
        weekdays: weekdays,
        startsAt: '08:00',
        endsAt: '09:00',
        endsNextDay: false,
        timezone: 'America/Sao_Paulo',
        validFrom: '2026-10-01',
        validUntil: '2026-11-01',
        confirmationMinutes: 15,
      );
      weekdays.clear();
      expect(await service.saveSchedule(command), testId);
      expect(seen['save_route_schedule']!['p_schedule_id'], isNull);
      expect((seen['save_route_schedule']!['p_schedule'] as Map)['weekdays'], [
        1,
        2,
      ]);
      expect(await service.enableOwnerDriving(testId, testId), [
        'owner',
        'driver',
      ]);
      await service.linkCity(testId, '3550000', testId);
      await service.linkSchool(testId, testId, testId);
      expect(seen['link_fleet_service_city']!['p_city_ibge_code'], '3550000');
      expect(seen['link_fleet_service_school']!['p_school_id'], testId);
      expect(await service.cities(), isNotEmpty);
      expect(
        await service.searchSchools(
          '3550000',
          '  Colégio  ',
          type: 'school',
          offset: 50,
        ),
        isNotEmpty,
      );
      expect(seen['search_schools'], {
        'p_city_ibge_code': '3550000',
        'p_query': 'Colégio',
        'p_institution_type': 'school',
        'p_limit': 50,
        'p_offset': 50,
      });
      await service.searchSchools('3550000', ' ');
      expect(seen['search_schools']!['p_query'], isNull);
    },
  );
  test(
    'malformed success fails closed and anonymous reads never leave client',
    () async {
      final client = await planningClient(
        (request) async => http.Response(
          '{"unexpected":true}',
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        ),
      );
      addTearDown(client.dispose);
      final service = FleetPlanningService(client: client);
      await expectLater(
        service.enableOwnerDriving(testId, testId),
        throwsFormatException,
      );
      await expectLater(
        service.searchSchools('3550000', ''),
        throwsFormatException,
      );
      final anonymous = SupabaseClient(
        'https://example.test',
        'key',
        httpClient: MockClient(
          (_) async => throw StateError('Must not call network'),
        ),
      );
      addTearDown(anonymous.dispose);
      await expectLater(
        FleetPlanningService(client: anonymous).load(testId),
        throwsA(isA<AuthException>()),
      );
    },
  );
  group('assignStudentTransport', () {
    const enrollment = '30fb15de-8023-41ee-a1dc-16877cf93e35';
    const school = '65000000-0000-0000-0000-000000000001';
    const schedule = '50f207a3-848d-4610-998d-850453c2025d';
    final draft = StudentTransportDraft(
      enrollmentId: enrollment,
      schoolId: school,
      allocations: {(weekday: 1, direction: 'going'): schedule},
      effectiveOn: '2026-10-06',
      expectedRoutingRevision: 1,
    );

    http.Response receipt(
      http.Request request, {
      String command = testId,
      String enrollmentId = enrollment,
    }) => http.Response(
      jsonEncode([
        {
          'command_id': command,
          'enrollment_id': enrollmentId,
          'routing_revision': 2,
          'effective_on': '2026-10-06',
        },
      ]),
      200,
      headers: {'content-type': 'application/json'},
      request: request,
    );

    test(
      'sends the exact direct-allocation RPC and returns the new revision',
      () async {
        final client = await planningClient((request) async {
          expect(
            request.url.path,
            endsWith('/rpc/assign_fleet_student_transport'),
          );
          expect(jsonDecode(request.body), {
            'p_enrollment_id': enrollment,
            'p_school_id': school,
            'p_allocations': [
              {'schedule_id': schedule, 'weekday': 1, 'direction': 'going'},
            ],
            'p_effective_on': '2026-10-06',
            'p_command_id': testId,
            'p_expected_routing_revision': 1,
          });
          return receipt(request);
        });
        addTearDown(client.dispose);
        expect(
          await FleetPlanningService(
            client: client,
          ).assignStudentTransport(draft, testId),
          2,
        );
      },
    );

    test('rejects a receipt for another command or enrollment', () async {
      for (final mismatch in [
        (
          command: '22222222-2222-4222-8222-222222222222',
          enrollmentId: enrollment,
        ),
        (command: testId, enrollmentId: '22222222-2222-4222-8222-222222222222'),
      ]) {
        final client = await planningClient(
          (request) async => receipt(
            request,
            command: mismatch.command,
            enrollmentId: mismatch.enrollmentId,
          ),
        );
        addTearDown(client.dispose);
        await expectLater(
          FleetPlanningService(
            client: client,
          ).assignStudentTransport(draft, testId),
          throwsFormatException,
        );
      }
    });

    test('requires an authenticated session', () async {
      final service = FleetPlanningService(
        client: SupabaseClient('https://example.supabase.co', 'test-key'),
      );
      await expectLater(
        service.assignStudentTransport(draft, testId),
        throwsA(isA<AuthException>()),
      );
    });
  });
}
