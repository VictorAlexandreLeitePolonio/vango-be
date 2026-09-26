import 'package:supabase_flutter/supabase_flutter.dart';

/// A write rejection differs from an unconfirmed transport outcome.
enum PlanningFailure { rejected, accessLost, conflict, uncertain }

/// Maps structured backend failures to safe owner-facing recovery messages.
abstract final class PlanningErrorMapper {
  /// Unknown responses may represent committed writes and must retain command identity.
  static PlanningFailure kind(Object error) {
    if (error is AuthException) return PlanningFailure.accessLost;
    return switch (error is PostgrestException ? error.code : null) {
      'unauthenticated' ||
      'forbidden' ||
      'not_found' ||
      '42501' => PlanningFailure.accessLost,
      'idempotency_conflict' => PlanningFailure.conflict,
      'revision_conflict' ||
      'schedule_conflict' ||
      'resource_in_use' ||
      'capacity_exceeded' ||
      'plate_conflict' ||
      'invalid_input' ||
      'email_unverified' ||
      'membership_conflict' ||
      'invalid_transition' => PlanningFailure.rejected,
      _ => PlanningFailure.uncertain,
    };
  }

  /// Never exposes provider or SQL text.
  static String message(Object error) => switch (error is PostgrestException
      ? error.code
      : null) {
    'revision_conflict' =>
      'Esta configuração foi alterada. Recarregue e revise antes de salvar.',
    'schedule_conflict' => 'Este horário conflita com outra rota.',
    'resource_in_use' => 'Este recurso já está em uso por uma programação.',
    'capacity_exceeded' => 'A capacidade disponível não atende à programação.',
    'plate_conflict' => 'Já existe uma van com esta placa.',
    'invalid_input' => 'Revise os campos e a cobertura da frota.',
    'email_unverified' => 'Confirme seu e-mail para configurar a frota.',
    'unauthenticated' ||
    'forbidden' ||
    'not_found' ||
    '42501' => 'Seu acesso à frota não está disponível.',
    'idempotency_conflict' =>
      'Este envio conflita com outro comando. Recarregue e confira os dados salvos.',
    _ => 'Não foi possível confirmar o envio. Tente verificar novamente.',
  };
}
