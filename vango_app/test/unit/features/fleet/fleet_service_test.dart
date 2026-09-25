import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:vango_app/features/fleet/services/fleet_service.dart';

void main() {
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
            'student_id': 'student-a',
            'full_name': 'Aluno Teste',
            'street': 'Rua',
            'street_number': '1',
            'neighborhood': 'Centro',
            'city_name': 'Cidade',
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
    expect(students.single.fullName, 'Aluno Teste');
    expect(students.single.address, 'Rua, 1 - Centro, Cidade');
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
