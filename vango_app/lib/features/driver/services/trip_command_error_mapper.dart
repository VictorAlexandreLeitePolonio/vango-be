import 'package:supabase_flutter/supabase_flutter.dart';

/// Definitive rejections drop the pending command id; uncertain outcomes keep
/// it for retry.
enum TripCommandFailure { rejected, accessLost, uncertain }

/// Maps structured backend failures to safe driver-facing recovery messages.
abstract final class TripCommandErrorMapper {
  /// Unknown responses may represent committed writes and must retain command
  /// identity.
  static TripCommandFailure kind(Object error) {
    if (error is AuthException) return TripCommandFailure.accessLost;
    return switch (error is PostgrestException ? error.code : null) {
      'unauthenticated' ||
      'forbidden' ||
      'not_found' ||
      '42501' => TripCommandFailure.accessLost,
      'confirmation_closed' ||
      'invalid_transition' ||
      'passengers_on_board' ||
      'resource_in_use' ||
      'idempotency_conflict' ||
      'invalid_input' ||
      'email_unverified' => TripCommandFailure.rejected,
      _ => TripCommandFailure.uncertain,
    };
  }

  /// Never exposes provider or SQL text.
  static String message(Object error) => switch (error is PostgrestException
      ? error.code
      : null) {
    'confirmation_closed' =>
      'Aguarde o encerramento das confirmações para iniciar a viagem.',
    'invalid_transition' =>
      'Esta ação não está disponível no estado atual da viagem.',
    'passengers_on_board' =>
      'Há alunos sem desembarque ou ausência registrados.',
    'resource_in_use' => 'A van ou o motorista já estão em outra viagem ativa.',
    'idempotency_conflict' =>
      'Este comando conflita com outro já registrado. Recarregue a viagem.',
    'invalid_input' =>
      'Não foi possível registrar a ação. Recarregue a viagem.',
    'email_unverified' => 'Confirme seu e-mail para operar viagens.',
    'unauthenticated' ||
    'forbidden' ||
    'not_found' ||
    '42501' => 'Você não tem acesso a esta viagem.',
    _ => 'Não foi possível confirmar a ação. Tente novamente.',
  };
}
