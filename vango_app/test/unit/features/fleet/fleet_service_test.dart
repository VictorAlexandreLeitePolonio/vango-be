import 'package:flutter_test/flutter_test.dart';
import 'package:vango_app/features/fleet/services/fleet_service.dart';

void main() {
  setUp(() {
    FleetService.resetLocalData();
  });

  tearDown(() {
    FleetService.resetLocalData();
  });

  const testFleetId = '51000000-0000-0000-0000-000000000001';

  test('getPendingRequests returns initial pending join requests', () async {
    final service = FleetService();
    final requests = await service.getPendingRequests(testFleetId);

    expect(requests.isNotEmpty, true);
    final req = requests.first;
    expect(req.id, 'req-001-carlos');
    expect(req.studentFullName, 'Carlos Eduardo Oliveira');
    expect(req.schoolName, 'Colégio Objetivo - Campus Paraíso');
    expect(req.shift, 'Manhã');
    expect(req.fullAddress, contains('Rua Bela Cintra, 1400'));
  });

  test('approving a join request removes it from pending and enrolls the student', () async {
    final service = FleetService();

    final initialPending = await service.getPendingRequests(testFleetId);
    expect(initialPending.any((r) => r.id == 'req-001-carlos'), true);

    final initialEnrolled = await service.getEnrolledStudents(testFleetId);
    final initialEnrolledCount = initialEnrolled.length;

    // Approve Carlos
    await service.decideRequest('req-001-carlos', true);

    final updatedPending = await service.getPendingRequests(testFleetId);
    expect(updatedPending.any((r) => r.id == 'req-001-carlos'), false);

    final updatedEnrolled = await service.getEnrolledStudents(testFleetId);
    expect(updatedEnrolled.length, initialEnrolledCount + 1);
    expect(updatedEnrolled.any((s) => s.fullName == 'Carlos Eduardo Oliveira'), true);
  });

  test('rejecting a join request removes it from pending without enrolling the student', () async {
    final service = FleetService();

    final initialEnrolled = await service.getEnrolledStudents(testFleetId);
    final initialEnrolledCount = initialEnrolled.length;

    // Reject Carlos
    await service.decideRequest('req-001-carlos', false);

    final updatedPending = await service.getPendingRequests(testFleetId);
    expect(updatedPending.any((r) => r.id == 'req-001-carlos'), false);

    final updatedEnrolled = await service.getEnrolledStudents(testFleetId);
    expect(updatedEnrolled.length, initialEnrolledCount);
    expect(updatedEnrolled.any((s) => s.fullName == 'Carlos Eduardo Oliveira'), false);
  });

  test('getFleetDrivers returns drivers list with status and van', () async {
    final service = FleetService();
    final drivers = await service.getFleetDrivers(testFleetId);

    expect(drivers.isNotEmpty, true);
    expect(drivers.first.name, 'Carlos Seed Driver');
    expect(drivers.first.status, contains('Van 01 (BRA-2E19)'));
  });

  test('getEnrolledStudents returns student items with valid geographic coordinates', () async {
    final service = FleetService();
    final students = await service.getEnrolledStudents(testFleetId);

    expect(students.length, greaterThanOrEqualTo(2));
    for (final s in students) {
      expect(s.fullName.isNotEmpty, true);
      expect(s.address.isNotEmpty, true);
      expect(s.latitude, inInclusiveRange(-90.0, 90.0));
      expect(s.longitude, inInclusiveRange(-180.0, 180.0));
    }
  });
}
