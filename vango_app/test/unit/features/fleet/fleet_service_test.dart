import 'dart:convert';
import 'fleet_student_registration_test.dart' as fixtures;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:vango_app/features/fleet/services/fleet_service.dart';

void main() {
  test(
    'city options use exact projection fleet filter and stable name order',
    () async {
      final client = await _authenticatedClient((request) async {
        expect(request.url.path, endsWith('/fleet_service_cities'));
        expect(
          request.url.queryParameters['select'],
          'city_ibge_code,city_name,state_code',
        );
        expect(request.url.queryParameters['fleet_id'], 'eq.fleet-a');
        return http.Response(
          jsonEncode([
            {
              'city_ibge_code': '3550308',
              'city_name': 'São Paulo',
              'state_code': 'SP',
            },
            {
              'city_ibge_code': '3509502',
              'city_name': 'Campinas',
              'state_code': 'SP',
            },
          ]),
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      });
      addTearDown(client.dispose);
      final cities = await FleetService(
        client: client,
      ).getServiceCities('fleet-a');
      expect(cities.map((city) => city.cityIbgeCode), ['3509502', '3550308']);
    },
  );
  test(
    'school options use the authorized minimal RPC without municipal restriction',
    () async {
      final client = await _authenticatedClient((request) async {
        expect(request.url.path, endsWith('/rpc/list_fleet_service_schools'));
        expect(jsonDecode(request.body), {'p_fleet_id': 'fleet-a'});
        return http.Response(
          jsonEncode([
            {'id': '10000000-0000-4000-8000-000000000002', 'name': 'Z School'},
            {'id': '10000000-0000-4000-8000-000000000001', 'name': 'A School'},
          ]),
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      });
      addTearDown(client.dispose);
      final schools = await FleetService(
        client: client,
      ).getServiceSchools('fleet-a');
      expect(schools.map((school) => school.name), ['A School', 'Z School']);
    },
  );
  test(
    'registration sends one exact command and returns the server receipt',
    () async {
      var calls = 0;
      final client = await _authenticatedClient((request) async {
        calls++;
        expect(request.url.path, endsWith('/rpc/create_fleet_managed_student'));
        expect(
          jsonDecode(request.body),
          fixtures.registration().toRpcParams(
            fleetId: 'fleet-a',
            commandId: 'command-a',
          ),
        );
        return http.Response(
          jsonEncode([
            {
              'student_id': '10000000-0000-4000-8000-000000000001',
              'enrollment_id': '20000000-0000-4000-8000-000000000001',
            },
          ]),
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      });
      addTearDown(client.dispose);
      final receipt = await FleetService(client: client).registerStudent(
        fleetId: 'fleet-a',
        commandId: 'command-a',
        registration: fixtures.registration(),
      );
      expect(receipt.studentId, '10000000-0000-4000-8000-000000000001');
      expect(receipt.enrollmentId, '20000000-0000-4000-8000-000000000001');
      expect(calls, 1);
    },
  );
  test('malformed successful receipts fail without a second write', () async {
    for (final response in [
      [],
      [
        {'student_id': 'fake', 'enrollment_id': 'fake'},
      ],
      [{}, {}],
      {'student_id': 'fake'},
      [null],
    ]) {
      var calls = 0;
      final client = await _authenticatedClient((request) async {
        calls++;
        return http.Response(
          jsonEncode(response),
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      });
      await expectLater(
        FleetService(client: client).registerStudent(
          fleetId: 'fleet-a',
          commandId: 'command-a',
          registration: fixtures.registration(),
        ),
        throwsFormatException,
      );
      expect(calls, 1);
      await client.dispose();
    }
  });
  test(
    'coverage errors propagate and successful empty options stay empty',
    () async {
      for (final failed in [false, true]) {
        final client = await _authenticatedClient(
          (request) async => http.Response(
            failed
                ? jsonEncode({'code': 'forbidden', 'message': 'denied'})
                : '[]',
            failed ? 403 : 200,
            headers: {'content-type': 'application/json'},
            request: request,
          ),
        );
        final service = FleetService(client: client);
        if (failed) {
          await expectLater(
            service.getServiceCities('fleet-a'),
            throwsA(isA<PostgrestException>()),
          );
          await expectLater(
            service.getServiceSchools('fleet-a'),
            throwsA(isA<PostgrestException>()),
          );
        } else {
          expect(await service.getServiceCities('fleet-a'), isEmpty);
          expect(await service.getServiceSchools('fleet-a'), isEmpty);
        }
        await client.dispose();
      }
    },
  );
  test(
    'malformed coverage rows are rejected rather than offered as options',
    () async {
      for (final school in [false, true]) {
        final client = await _authenticatedClient(
          (request) async => http.Response(
            jsonEncode(
              school
                  ? [
                      {'id': 'invalid', 'name': ''},
                    ]
                  : [
                      {
                        'city_ibge_code': 'invalid',
                        'city_name': '',
                        'state_code': 'S',
                      },
                    ],
            ),
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          ),
        );
        final service = FleetService(client: client);
        await expectLater(
          school
              ? service.getServiceSchools('fleet-a')
              : service.getServiceCities('fleet-a'),
          throwsFormatException,
        );
        await client.dispose();
      }
    },
  );
  test('owner reads and decisions require an authenticated client', () async {
    final service = FleetService();

    await expectLater(service.getPendingRequests('fleet-a'), throwsStateError);
    await expectLater(service.getFleetDrivers('fleet-a'), throwsStateError);
    await expectLater(
      service.getOwnerEnrolledStudents('fleet-a'),
      throwsStateError,
    );
    await expectLater(
      service.decideRequest('request-a', true),
      throwsStateError,
    );
  });

  test('pending owner requests accept absent coordinates', () async {
    final client = await _authenticatedClient((request) async {
      expect(request.url.path, endsWith('/rpc/list_fleet_join_requests'));
      return http.Response(
        jsonEncode([
          {
            'id': 'request-a',
            'student_full_name': 'Aluno Teste',
            'school_name': 'Escola',
            'shift': 'Manhã',
            'street': 'Rua',
            'street_number': '1',
            'neighborhood': 'Centro',
            'city_name': 'Cidade',
            'latitude': null,
            'longitude': null,
            'created_at': '2026-09-24T10:00:00Z',
          },
        ]),
        200,
        headers: {'content-type': 'application/json'},
        request: request,
      );
    });
    addTearDown(client.dispose);

    final requests = await FleetService(
      client: client,
    ).getPendingRequests('fleet-a');
    expect(requests.single.studentFullName, 'Aluno Teste');
  });

  test('owner student list uses its fleet-scoped RPC projection', () async {
    final client = await _authenticatedClient((request) async {
      expect(request.url.path, endsWith('/rpc/list_fleet_students'));
      expect(jsonDecode(request.body), {'p_fleet_id': 'fleet-a'});
      return http.Response(
        jsonEncode([
          {
            'enrollment_id': 'enrollment-a',
            'student_id': 'student-a',
            'full_name': 'Aluno Teste',
            'street': 'Rua',
            'street_number': '1',
            'neighborhood': 'Centro',
            'city_name': 'Cidade',
            'school_id': 'school-a',
            'school_name': 'Escola',
            'shift': 'morning',
          },
          {
            'enrollment_id': 'enrollment-b',
            'student_id': 'student-b',
            'full_name': 'Sem Escola',
            'street': 'Rua',
            'street_number': '2',
            'neighborhood': 'Centro',
            'city_name': 'Cidade',
            'school_id': null,
            'school_name': null,
            'shift': null,
          },
        ]),
        200,
        headers: {'content-type': 'application/json'},
        request: request,
      );
    });
    addTearDown(client.dispose);

    final students = await FleetService(
      client: client,
    ).getOwnerEnrolledStudents('fleet-a');
    expect(students.first.fullName, 'Aluno Teste');
    expect(students.first.address, 'Rua, 1 - Centro, Cidade');
    expect(students.first.enrollmentId, 'enrollment-a');
    expect(students.first.schoolId, 'school-a');
    expect(students.first.schoolName, 'Escola');
    expect(students.first.shift, 'morning');
    expect(students.last.schoolId, isNull);
    expect(students.last.shift, isNull);
  });

  test(
    'driver membership remains visible when profile is hidden by RLS',
    () async {
      final client = await _authenticatedClient((request) async {
        expect(request.url.path, endsWith('/fleet_memberships'));
        return http.Response(
          jsonEncode([
            {'user_id': 'driver-a', 'profiles': null},
          ]),
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      });
      addTearDown(client.dispose);

      final drivers = await FleetService(
        client: client,
      ).getFleetDrivers('fleet-a');
      expect(drivers.single.id, 'driver-a');
      expect(drivers.single.name, 'Motorista');
    },
  );
}

Future<SupabaseClient> _authenticatedClient(MockClientHandler handler) async {
  final client = SupabaseClient(
    'https://example.supabase.co',
    'test-publishable-key',
    httpClient: MockClient(handler),
  );
  final user = User(
    id: 'user-1',
    appMetadata: const {},
    userMetadata: const {},
    aud: 'authenticated',
    createdAt: '2026-01-01T00:00:00Z',
  );
  final session = Session(
    accessToken: 'access-token',
    refreshToken: 'refresh-token',
    tokenType: 'bearer',
    user: user,
  );
  await client.auth.recoverSession(jsonEncode(session.toJson()));
  return client;
}
