import 'package:supabase_flutter/supabase_flutter.dart';

/// Distinguishes rejection from an outcome that may already have committed.
enum FleetStudentWriteFailureKind {
  definitiveRejection,
  accessUnavailable,
  idempotencyConflict,
  unknownOutcome,
}

/// Exposes safe registration messages without leaking SQL or transport details.
abstract final class FleetStudentErrorMapper {
  /// Classifies structured RPC codes; unrecognized errors remain uncertain.
  static FleetStudentWriteFailureKind classifyWriteFailure(Object error) =>
      switch (error is PostgrestException ? error.code : null) {
        'invalid_input' ||
        'registration_failed' ||
        'email_unverified' => FleetStudentWriteFailureKind.definitiveRejection,
        'unauthenticated' ||
        'forbidden' ||
        'not_found' => FleetStudentWriteFailureKind.accessUnavailable,
        'idempotency_conflict' =>
          FleetStudentWriteFailureKind.idempotencyConflict,
        _ => FleetStudentWriteFailureKind.unknownOutcome,
      };

  /// Returns safe pt-BR feedback for an RPC or read failure.
  static String message(Object error) => switch (error is PostgrestException
      ? error.code
      : null) {
    'unauthenticated' => 'Entre novamente para continuar.',
    'email_unverified' => 'Confirme seu e-mail para cadastrar alunos.',
    'forbidden' || 'not_found' => 'Seu acesso à frota não está disponível.',
    'invalid_input' =>
      'Revise os dados e a cobertura da frota antes de tentar novamente.',
    'idempotency_conflict' =>
      'Não foi possível confirmar este envio. Revise a lista de alunos antes de iniciar outro cadastro.',
    _ => 'Não foi possível cadastrar o aluno. Tente novamente.',
  };
}
