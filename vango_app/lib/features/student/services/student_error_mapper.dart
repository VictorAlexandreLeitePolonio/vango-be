import 'package:supabase_flutter/supabase_flutter.dart';

/// Maps student and marketplace backend errors to pt-BR UI copy.
///
/// Raw error text is never shown because it can carry personal data such as
/// names, addresses or coordinates.
class StudentErrorMapper {
  StudentErrorMapper._();

  static const _fallback =
      'Não foi possível concluir a operação. Tente novamente.';

  /// Returns a user-facing message for [error].
  ///
  /// Known `PostgrestException.code` values from `private.raise_api_error`
  /// get specific copy; anything else gets a generic message.
  static String message(Object error) {
    if (error is! PostgrestException) return _fallback;

    return switch (error.code) {
      'unauthenticated' => 'Sua sessão expirou. Entre novamente.',
      'email_unverified' => 'Confirme seu e-mail para continuar.',
      'forbidden' => 'Você não tem permissão para realizar esta ação.',
      'not_found' =>
        'Registro não encontrado. Atualize a página e tente novamente.',
      'student_conflict' =>
        'Não foi possível cadastrar o aluno: dados em conflito com um cadastro existente.',
      'request_conflict' =>
        'Já existe uma solicitação pendente para este aluno.',
      'enrollment_conflict' => 'Este aluno já está matriculado nesta frota.',
      'invalid_transition' =>
        'Esta frota não está aceitando solicitações no momento.',
      'invalid_input' =>
        'Dados inválidos. Revise as informações e tente novamente.',
      _ => _fallback,
    };
  }
}
