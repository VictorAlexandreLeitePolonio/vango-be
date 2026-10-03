import 'package:flutter_test/flutter_test.dart';
import 'package:vango_app/features/fleet/models/fleet_student_submission_state.dart';
import 'package:vango_app/features/fleet/services/fleet_student_error_mapper.dart';
import 'fleet_student_registration_test.dart' as fixtures;

void main() {
  test(
    'retains exactly one immutable command through double submit unknown and retry',
    () {
      final state = FleetStudentSubmissionState(
        userId: 'user',
        fleetId: 'fleet',
      );
      final draft = fixtures.registration();
      expect(state.begin('command-one', draft), isTrue);
      expect(state.begin('command-two', fixtures.registration()), isFalse);
      state.fail(FleetStudentWriteFailureKind.unknownOutcome);
      expect(state.phase, FleetStudentSubmissionPhase.unknown);
      expect(state.begin('command-two', fixtures.registration()), isFalse);
      expect(state.retry(), isTrue);
      expect(state.command?.id, 'command-one');
      expect(state.command?.registration, same(draft));
      state.commit((studentId: 'student', enrollmentId: 'enrollment'));
      expect(state.phase, FleetStudentSubmissionPhase.committed);
      expect(state.retry(), isFalse);
      expect(state.begin('command-two', fixtures.registration()), isFalse);
    },
  );
  test(
    'definitive rejection permits correction but conflict never replaces the command',
    () {
      final state = FleetStudentSubmissionState(
        userId: 'user',
        fleetId: 'fleet',
      );
      state.begin('one', fixtures.registration());
      state.fail(FleetStudentWriteFailureKind.definitiveRejection);
      expect(state.begin('two', fixtures.registration()), isTrue);
      state.fail(FleetStudentWriteFailureKind.idempotencyConflict);
      expect(state.conflict, isTrue);
      expect(state.retry(), isFalse);
      expect(state.begin('three', fixtures.registration()), isFalse);
    },
  );
  test('identity loss clears payload and ignores late confirmed result', () {
    final state = FleetStudentSubmissionState(userId: 'user', fleetId: 'fleet');
    state.begin('one', fixtures.registration());
    state.invalidate();
    state.commit((studentId: 'student', enrollmentId: 'enrollment'));
    expect(state.command, isNull);
    expect(state.receipt, isNull);
    expect(state.begin('two', fixtures.registration()), isFalse);
  });
}
