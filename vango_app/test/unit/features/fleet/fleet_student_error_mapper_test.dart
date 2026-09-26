import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:vango_app/features/fleet/services/fleet_student_error_mapper.dart';

void main() {
  test(
    'classifies only recognized structured RPC codes as definitive outcomes',
    () {
      for (final code in [
        'invalid_input',
        'registration_failed',
        'email_unverified',
      ]) {
        expect(
          FleetStudentErrorMapper.classifyWriteFailure(
            PostgrestException(message: 'private SQL', code: code),
          ),
          FleetStudentWriteFailureKind.definitiveRejection,
        );
      }
      for (final code in ['forbidden', 'not_found', 'unauthenticated']) {
        expect(
          FleetStudentErrorMapper.classifyWriteFailure(
            PostgrestException(message: 'private SQL', code: code),
          ),
          FleetStudentWriteFailureKind.accessUnavailable,
        );
      }
      expect(
        FleetStudentErrorMapper.classifyWriteFailure(
          const PostgrestException(
            message: 'private',
            code: 'idempotency_conflict',
          ),
        ),
        FleetStudentWriteFailureKind.idempotencyConflict,
      );
    },
  );
  test('transport malformed receipts and raw text do not prove rollback', () {
    for (final error in [
      TimeoutException('timeout'),
      ClientException('network'),
      const FormatException('receipt'),
      const PostgrestException(message: 'invalid_input', code: '502'),
      StateError('registration_failed'),
    ]) {
      expect(
        FleetStudentErrorMapper.classifyWriteFailure(error),
        FleetStudentWriteFailureKind.unknownOutcome,
      );
      expect(
        FleetStudentErrorMapper.message(error),
        isNot(contains('private')),
      );
    }
  });
  test('maps domain codes to safe actionable feedback', () {
    expect(
      FleetStudentErrorMapper.message(
        const PostgrestException(message: 'private', code: 'invalid_input'),
      ),
      'Revise os dados e a cobertura da frota antes de tentar novamente.',
    );
    expect(
      FleetStudentErrorMapper.message(
        const PostgrestException(message: 'private', code: 'unauthenticated'),
      ),
      'Entre novamente para continuar.',
    );
  });
}
