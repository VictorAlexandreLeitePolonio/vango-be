import 'fleet_student_registration.dart';
import '../services/fleet_student_error_mapper.dart';

/// Lifecycle of one registration command retained by the owner dashboard.
enum FleetStudentSubmissionPhase {
  idle,
  submitting,
  unknown,
  rejected,
  committed,
}

/// Immutable command retained after an uncertain response.
typedef FleetStudentCommand = ({
  String id,
  FleetStudentRegistration registration,
});

/// In-memory command ownership, scoped to one authenticated user and fleet.
class FleetStudentSubmissionState {
  FleetStudentSubmissionState({required this.userId, required this.fleetId});
  final String userId, fleetId;
  FleetStudentSubmissionPhase _phase = FleetStudentSubmissionPhase.idle;
  FleetStudentCommand? _command;
  FleetStudentRegistrationReceipt? _receipt;
  bool _conflict = false;
  bool _invalidated = false;
  FleetStudentSubmissionPhase get phase => _phase;
  FleetStudentCommand? get command => _command;
  FleetStudentRegistrationReceipt? get receipt => _receipt;
  bool get conflict => _conflict;
  bool get invalidated => _invalidated;

  /// Starts one logical command only when no unresolved write exists.
  bool begin(String id, FleetStudentRegistration registration) {
    if (_invalidated ||
        (_phase != FleetStudentSubmissionPhase.idle &&
            _phase != FleetStudentSubmissionPhase.rejected)) {
      return false;
    }
    _command = (id: id, registration: registration);
    _phase = FleetStudentSubmissionPhase.submitting;
    return true;
  }

  /// Re-dispatches the original immutable command after an unknown outcome.
  bool retry() {
    if (_invalidated ||
        _conflict ||
        _phase != FleetStudentSubmissionPhase.unknown ||
        _command == null) {
      return false;
    }
    _phase = FleetStudentSubmissionPhase.submitting;
    return true;
  }

  /// Records a structured write failure without inventing rollback.
  void fail(FleetStudentWriteFailureKind kind) {
    if (_invalidated || _phase != FleetStudentSubmissionPhase.submitting) {
      return;
    }
    if (kind == FleetStudentWriteFailureKind.accessUnavailable) {
      invalidate();
      return;
    }
    _conflict = kind == FleetStudentWriteFailureKind.idempotencyConflict;
    _phase = kind == FleetStudentWriteFailureKind.definitiveRejection
        ? FleetStudentSubmissionPhase.rejected
        : FleetStudentSubmissionPhase.unknown;
  }

  /// Stores the validated receipt and prevents another dispatch.
  void commit(FleetStudentRegistrationReceipt value) {
    if (_invalidated || _phase != FleetStudentSubmissionPhase.submitting) {
      return;
    }
    _receipt = value;
    _phase = FleetStudentSubmissionPhase.committed;
  }

  /// Removes sensitive state after the security context is lost.
  void invalidate() {
    _invalidated = true;
    _command = null;
    _receipt = null;
    _conflict = false;
    _phase = FleetStudentSubmissionPhase.idle;
  }
}
