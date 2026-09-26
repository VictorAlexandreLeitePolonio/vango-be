import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:vango_app/features/fleet/models/fleet_student_registration.dart';
import 'package:vango_app/features/fleet/services/fleet_service.dart';
import 'package:vango_app/features/fleet/services/fleet_student_error_mapper.dart';

const fleetId = '10000000-0000-4000-8000-000000000011';
const commandId = '10000000-0000-4000-8000-000000000012';
const studentId = '10000000-0000-4000-8000-000000000013';
const enrollmentId = '10000000-0000-4000-8000-000000000014';

FleetStudentRegistration registration(FleetStudentType type) =>
    FleetStudentRegistration(
      studentType: type,
      fullName: ' Synthetic student ',
      birthDate: DateTime(type == FleetStudentType.minor ? 2012 : 1990, 3, 2),
      postalCode: ' 51000000 ',
      street: ' Rua Recife ',
      streetNumber: ' 12 ',
      neighborhood: ' Boa Viagem ',
      city: const FleetServiceCity(
        cityIbgeCode: '2611606',
        cityName: 'Recife',
        stateCode: 'PE',
      ),
      latitude: -8.123,
      longitude: -34.987,
      schoolId: '10000000-0000-4000-8000-000000000015',
      shift: FleetStudentShift.fullTime,
      contactFullName: ' Synthetic contact ',
      contactEmail: ' CONTACT@EXAMPLE.COM ',
    );

Future<SupabaseClient> clientFor(MockClientHandler handler) async {
  final client = SupabaseClient(
    'https://synthetic.supabase.co',
    'test-key',
    httpClient: MockClient(handler),
  );
  await client.auth.recoverSession(
    jsonEncode(
      Session(
        accessToken: 'synthetic-token',
        refreshToken: 'synthetic-refresh',
        tokenType: 'bearer',
        user: User(
          id: 'synthetic-user',
          appMetadata: const {},
          userMetadata: const {},
          aud: 'authenticated',
          createdAt: '2026-01-01T00:00:00Z',
        ),
      ).toJson(),
    ),
  );
  return client;
}

http.Response jsonResponse(
  http.Request request,
  Object body, {
  int status = 200,
}) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
  request: request,
);

void main() {
  test(
    'owner empty read preserves the selected fleet and never fabricates students',
    () async {
      var calls = 0;
      final client = await clientFor((request) async {
        calls++;
        expect(request.url.path, '/rest/v1/rpc/list_fleet_students');
        expect(jsonDecode(request.body), {'p_fleet_id': fleetId});
        return jsonResponse(request, []);
      });
      addTearDown(client.dispose);
      expect(
        await FleetService(client: client).getOwnerEnrolledStudents(fleetId),
        isEmpty,
      );
      expect(calls, 1);
    },
  );

  for (final type in FleetStudentType.values) {
    test(
      'sends exact ${type.name} RPC parameters and accepts only server receipt',
      () async {
        var calls = 0;
        final client = await clientFor((request) async {
          calls++;
          expect(request.method, 'POST');
          expect(request.url.path, '/rest/v1/rpc/create_fleet_managed_student');
          expect(jsonDecode(request.body), {
            'p_fleet_id': fleetId,
            'p_command_id': commandId,
            'p_student_type': type.name,
            'p_full_name': 'Synthetic student',
            'p_birth_date': type == FleetStudentType.minor
                ? '2012-03-02'
                : '1990-03-02',
            'p_postal_code': '51000000',
            'p_street': 'Rua Recife',
            'p_street_number': '12',
            'p_address_complement': null,
            'p_neighborhood': 'Boa Viagem',
            'p_city_name': 'Recife',
            'p_city_ibge_code': '2611606',
            'p_state_code': 'PE',
            'p_latitude': -8.123,
            'p_longitude': -34.987,
            'p_school_id': '10000000-0000-4000-8000-000000000015',
            'p_shift': 'full_time',
            'p_contact_full_name': 'Synthetic contact',
            'p_contact_email': 'contact@example.com',
            'p_contact_phone': null,
          });
          return jsonResponse(request, [
            {'student_id': studentId, 'enrollment_id': enrollmentId},
          ]);
        });
        addTearDown(client.dispose);
        expect(
          await FleetService(client: client).registerStudent(
            fleetId: fleetId,
            commandId: commandId,
            registration: registration(type),
          ),
          (studentId: studentId, enrollmentId: enrollmentId),
        );
        expect(calls, 1);
      },
    );
  }

  test(
    'malformed successful writes remain unknown rather than claiming rollback',
    () async {
      for (final body in [
        [],
        [{}],
        [
          {'student_id': studentId},
        ],
        [
          {'student_id': studentId, 'enrollment_id': enrollmentId},
          {'student_id': studentId, 'enrollment_id': enrollmentId},
        ],
        {'student_id': studentId},
      ]) {
        var calls = 0;
        final client = await clientFor((request) async {
          calls++;
          return jsonResponse(request, body);
        });
        try {
          await FleetService(client: client).registerStudent(
            fleetId: fleetId,
            commandId: commandId,
            registration: registration(FleetStudentType.minor),
          );
          fail('Malformed success must not become a receipt');
        } on FormatException catch (error) {
          expect(
            FleetStudentErrorMapper.classifyWriteFailure(error),
            FleetStudentWriteFailureKind.unknownOutcome,
          );
        } finally {
          await client.dispose();
        }
        expect(calls, 1);
      }
    },
  );

  test(
    'retry after timeout makes another request with the original command and payload',
    () async {
      final bodies = <Object?>[];
      final client = await clientFor((request) async {
        bodies.add(jsonDecode(request.body));
        if (bodies.length == 1) {
          throw TimeoutException('synthetic transport failure');
        }
        return jsonResponse(request, [
          {'student_id': studentId, 'enrollment_id': enrollmentId},
        ]);
      });
      addTearDown(client.dispose);
      final service = FleetService(client: client);
      final draft = registration(FleetStudentType.minor);
      await expectLater(
        service.registerStudent(
          fleetId: fleetId,
          commandId: commandId,
          registration: draft,
        ),
        throwsA(isA<TimeoutException>()),
      );
      await service.registerStudent(
        fleetId: fleetId,
        commandId: commandId,
        registration: draft,
      );
      expect(bodies, hasLength(2));
      expect(bodies.first, bodies.last);
    },
  );

  test(
    'failed reads and writes emit no sensitive application diagnostics',
    () async {
      final output = <String>[];
      final original = debugPrint;
      debugPrint = (String? text, {int? wrapWidth}) {
        output.add(text ?? '');
      };
      addTearDown(() => debugPrint = original);
      final client = await clientFor(
        (request) async => jsonResponse(request, {
          'code': 'unknown_code',
          'message': 'SENTINEL_ADDRESS SENTINEL_EMAIL SENTINEL_TOKEN',
          'details': 'SENTINEL_COORDINATES',
        }, status: 500),
      );
      addTearDown(client.dispose);
      final service = FleetService(client: client);
      await runZoned(
        () async {
          for (final operation in [
            () => service.getOwnerEnrolledStudents(fleetId),
            () => service.registerStudent(
              fleetId: fleetId,
              commandId: commandId,
              registration: registration(FleetStudentType.minor),
            ),
          ]) {
            try {
              await operation();
              fail('Server failure must propagate');
            } on PostgrestException catch (error) {
              expect(
                FleetStudentErrorMapper.message(error),
                'Não foi possível cadastrar o aluno. Tente novamente.',
              );
              expect(
                FleetStudentErrorMapper.classifyWriteFailure(error),
                FleetStudentWriteFailureKind.unknownOutcome,
              );
              expect(
                FleetStudentErrorMapper.message(error),
                isNot(contains('SENTINEL')),
              );
            }
          }
        },
        zoneSpecification: ZoneSpecification(
          print: (_, _, _, String line) {
            output.add(line);
          },
        ),
      );
      expect(output.join(), isNot(contains('SENTINEL')));
    },
  );
}
