import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:vango_app/features/student/models/student_models.dart';
import 'package:vango_app/features/student/services/student_error_mapper.dart';
import 'package:vango_app/features/student/services/student_service.dart';

import '../../../support/fake_student_data_source.dart';

void main() {
  final throwsApiError = throwsA(isA<PostgrestException>());

  Matcher throwsCode(String code) =>
      throwsA(isA<PostgrestException>().having((e) => e.code, 'code', code));

  group('getMyStudents', () {
    test('returns an empty list instead of a seeded student', () async {
      final service = StudentService(dataSource: FakeStudentDataSource());

      expect(await service.getMyStudents(), isEmpty);
    });

    test('maps guardian rows and skips rows without a student', () async {
      final service = StudentService(
        dataSource: FakeStudentDataSource(
          studentRows: [
            {
              'student_id': 's-1',
              'students': {
                'id': 's-1',
                'full_name': 'Ana Souza',
                'birth_date': '2015-02-01',
                'street': 'Rua A',
                'street_number': '10',
                'neighborhood': 'Centro',
                'city_name': 'Campinas',
                'city_ibge_code': '3509502',
                'state_code': 'SP',
                'postal_code': '13010-000',
                'latitude': -22.9,
                'longitude': -47.06,
              },
            },
            {'student_id': 's-2', 'students': null},
          ],
        ),
      );

      final students = await service.getMyStudents();

      expect(students, hasLength(1));
      expect(students.single.fullName, 'Ana Souza');
      expect(students.single.cityName, 'Campinas');
      expect(students.single.latitude, -22.9);
    });

    test('throws unauthenticated when there is no signed-in user', () {
      final service = StudentService(
        dataSource: FakeStudentDataSource(currentUserId: null),
      );

      expect(service.getMyStudents(), throwsCode('unauthenticated'));
    });

    test('propagates backend failures', () {
      final service = StudentService(
        dataSource: FakeStudentDataSource(error: apiError('forbidden')),
      );

      expect(service.getMyStudents(), throwsCode('forbidden'));
    });
  });

  group('createMinorStudent', () {
    Future<String> create(StudentService service) => service.createMinorStudent(
      fullName: '  Enzo Santos ',
      birthDate: '2015-08-20',
      street: 'Alameda Campinas',
      streetNumber: '400',
      neighborhood: 'Jardins',
      cityName: 'São Paulo',
      cityIbgeCode: '3550308',
      stateCode: 'SP',
      postalCode: '01404-000',
      latitude: -23.568,
      longitude: -46.653,
    );

    test('returns the id created by the RPC with trimmed params', () async {
      final source = FakeStudentDataSource(createdStudentId: 'uuid-42');
      final service = StudentService(dataSource: source);

      expect(await create(service), 'uuid-42');
      expect(source.lastCreateParams!['p_full_name'], 'Enzo Santos');
      expect(source.lastCreateParams!['p_latitude'], -23.568);
    });

    test('propagates RPC failures instead of generating a local id', () {
      final service = StudentService(
        dataSource: FakeStudentDataSource(error: apiError('student_conflict')),
      );

      expect(create(service), throwsCode('student_conflict'));
    });

    test('throws unauthenticated when signed out', () {
      final service = StudentService(
        dataSource: FakeStudentDataSource(currentUserId: null),
      );

      expect(create(service), throwsCode('unauthenticated'));
    });
  });

  group('getAvailableVans', () {
    Map<String, dynamic> vanRow({
      List<Map<String, dynamic>> schools = const [],
    }) => {
      'id': 'van-1',
      'plate': 'ABC1D23',
      'model': 'Sprinter',
      'public_name': 'Van Norte',
      'capacity': 15,
      'fleet_id': 'fleet-1',
      'fleets': {
        'name': 'Frota Real',
        'fleet_service_schools': [
          for (final school in schools) {'schools': school},
        ],
      },
    };

    test('returns an empty list instead of a demo van', () async {
      final service = StudentService(dataSource: FakeStudentDataSource());

      expect(await service.getAvailableVans(), isEmpty);
    });

    test('creates one entry per school served by the van fleet', () async {
      final service = StudentService(
        dataSource: FakeStudentDataSource(
          vanRows: [
            vanRow(
              schools: [
                {'id': 'school-1', 'name': 'Escola Um'},
                {'id': 'school-2', 'name': 'Escola Dois'},
              ],
            ),
          ],
        ),
      );

      final vans = await service.getAvailableVans();

      expect(vans.map((v) => v.schoolId), ['school-1', 'school-2']);
      expect(vans.first.fleetId, 'fleet-1');
      expect(vans.first.fleetName, 'Frota Real');
      expect(vans.first.vanPlate, 'ABC1D23');
      expect(vans.first.capacity, 15);
    });

    test('skips vans whose fleet serves no school', () async {
      final service = StudentService(
        dataSource: FakeStudentDataSource(vanRows: [vanRow()]),
      );

      expect(await service.getAvailableVans(), isEmpty);
    });

    test('propagates backend failures', () {
      final service = StudentService(
        dataSource: FakeStudentDataSource(error: apiError('forbidden')),
      );

      expect(service.getAvailableVans(), throwsApiError);
    });
  });

  group('submitJoinRequest', () {
    Future<void> submit(StudentService service) => service.submitJoinRequest(
      fleetId: 'fleet-1',
      studentId: 'student-1',
      schoolId: 'school-1',
      shift: 'morning',
    );

    test('sends the join request params to the RPC', () async {
      final source = FakeStudentDataSource();
      await submit(StudentService(dataSource: source));

      expect(source.lastJoinParams!['p_fleet_id'], 'fleet-1');
      expect(source.lastJoinParams!['p_school_id'], 'school-1');
      expect(source.lastJoinParams!['p_shift'], 'morning');
    });

    test('propagates RPC failures instead of swallowing them', () {
      final service = StudentService(
        dataSource: FakeStudentDataSource(error: apiError('request_conflict')),
      );

      expect(submit(service), throwsCode('request_conflict'));
    });

    test('throws unauthenticated when signed out', () {
      final service = StudentService(
        dataSource: FakeStudentDataSource(currentUserId: null),
      );

      expect(submit(service), throwsCode('unauthenticated'));
    });
  });

  group('StudentProfile.fromMap', () {
    test(
      'keeps missing coordinates and city data empty instead of defaults',
      () {
        final student = StudentProfile.fromMap({
          'id': 's-1',
          'full_name': 'Ana',
        });

        expect(student.latitude, isNull);
        expect(student.longitude, isNull);
        expect(student.cityName, isEmpty);
        expect(student.cityIbgeCode, isEmpty);
        expect(student.stateCode, isEmpty);
        expect(student.postalCode, isEmpty);
      },
    );
  });

  group('StudentErrorMapper', () {
    test('maps backend codes to pt-BR messages', () {
      expect(
        StudentErrorMapper.message(apiError('request_conflict')),
        'Já existe uma solicitação pendente para este aluno.',
      );
      expect(
        StudentErrorMapper.message(apiError('unauthenticated')),
        'Sua sessão expirou. Entre novamente.',
      );
      expect(
        StudentErrorMapper.message(apiError('invalid_input')),
        'Dados inválidos. Revise as informações e tente novamente.',
      );
    });

    test('never exposes raw error text', () {
      final message = StudentErrorMapper.message(
        Exception('lat -23.5 Rua Secreta 123'),
      );

      expect(message, 'Não foi possível concluir a operação. Tente novamente.');
    });
  });
}
