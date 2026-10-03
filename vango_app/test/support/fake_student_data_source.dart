import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:vango_app/features/student/services/student_service.dart';

/// In-memory [StudentDataSource] used by unit and widget tests.
///
/// Every backend call either returns the configured rows or throws [error],
/// so tests can drive success, empty and failure states deterministically.
class FakeStudentDataSource implements StudentDataSource {
  FakeStudentDataSource({
    this.currentUserId = 'guardian-1',
    this.studentRows = const [],
    this.vanRows = const [],
    this.createdStudentId = 'student-uuid-1',
    this.error,
  });

  @override
  String? currentUserId;
  List<Map<String, dynamic>> studentRows;
  List<Map<String, dynamic>> vanRows;
  Object createdStudentId;

  /// When set, every backend call throws this error.
  Object? error;

  Map<String, dynamic>? lastCreateParams;
  Map<String, dynamic>? lastJoinParams;

  @override
  Future<Object?> createMinorStudent(Map<String, dynamic> params) async {
    lastCreateParams = params;
    _throwIfFailing();
    return createdStudentId;
  }

  @override
  Future<List<Map<String, dynamic>>> fetchGuardianStudentRows(
    String guardianUserId,
  ) async {
    _throwIfFailing();
    return studentRows;
  }

  @override
  Future<List<Map<String, dynamic>>> fetchActiveVanRows() async {
    _throwIfFailing();
    return vanRows;
  }

  @override
  Future<void> submitFleetJoinRequest(Map<String, dynamic> params) async {
    lastJoinParams = params;
    _throwIfFailing();
  }

  void _throwIfFailing() {
    final failure = error;
    if (failure != null) throw failure;
  }
}

/// Builds a [PostgrestException] shaped like `private.raise_api_error`.
PostgrestException apiError(String code) =>
    PostgrestException(message: code, code: code);
