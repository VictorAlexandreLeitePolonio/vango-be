import 'package:flutter_test/flutter_test.dart';
import 'package:vango_app/features/student/services/student_service.dart';

void main() {
  setUp(() {
    StudentService.resetLocalCache();
  });

  tearDown(() {
    StudentService.resetLocalCache();
  });

  test('getMyStudents returns default seeded student initially', () async {
    final service = StudentService();
    final students = await service.getMyStudents();

    expect(students.length, 1);
    expect(students.first.fullName, 'Lucas Alencar');
    expect(students.first.cityName, 'São Paulo');
    expect(students.first.cityIbgeCode, '3550308');
  });

  test('createMinorStudent adds student to local list and returns generated id', () async {
    final service = StudentService();

    final studentId = await service.createMinorStudent(
      fullName: 'Enzo Gabriel Santos',
      birthDate: '2015-08-20',
      street: 'Alameda Campinas',
      streetNumber: '400',
      neighborhood: 'Jardins',
      cityName: 'São Paulo',
      cityIbgeCode: '3550308',
      stateCode: 'SP',
      postalCode: '01404-000',
      latitude: -23.5680,
      longitude: -46.6530,
    );

    expect(studentId.isNotEmpty, true);

    final students = await service.getMyStudents();
    expect(students.length, 1);
    expect(students.first.fullName, 'Enzo Gabriel Santos');
    expect(students.first.street, 'Alameda Campinas');
    expect(students.first.streetNumber, '400');
    expect(students.first.latitude, -23.5680);
    expect(students.first.longitude, -46.6530);
  });

  test('getAvailableVans returns active fleet vans', () async {
    final service = StudentService();
    final vans = await service.getAvailableVans();

    expect(vans.isNotEmpty, true);
    final van = vans.first;
    expect(van.vanPlate, 'BRA-2E19');
    expect(van.fleetName, 'Demo Fleet');
    expect(van.capacity, 20);
    expect(van.schoolName, 'Colégio Objetivo - Campus Paraíso');
  });

  test('submitJoinRequest runs smoothly without throwing', () async {
    final service = StudentService();

    expect(
      () => service.submitJoinRequest(
        fleetId: '51000000-0000-0000-0000-000000000001',
        studentId: 'seed-student-001',
        schoolId: '60000000-0000-0000-0000-000000000001',
        shift: 'Manhã',
      ),
      returnsNormally,
    );
  });
}
