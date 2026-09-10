import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

class AuthErrorMapper {
  AuthErrorMapper._();

  static String message(Object error) {
    if (error is AuthRetryableFetchException || error is TimeoutException) {
      return 'Não foi possível conectar ao servidor. Verifique sua internet.';
    }

    if (error is AuthException) {
      switch (error.code) {
        case 'invalid_credentials':
        case 'invalid_grant':
        case 'email_not_confirmed':
          return 'E-mail ou senha incorretos.';
        case 'email_exists':
        case 'user_already_exists':
          return 'Este e-mail já está cadastrado.';
        case 'weak_password':
          return 'A senha não atende aos requisitos mínimos.';
        case 'over_request_rate_limit':
        case 'over_email_send_rate_limit':
          return 'Muitas tentativas. Aguarde um momento e tente novamente.';
      }

      if (error.statusCode == '429') {
        return 'Muitas tentativas. Aguarde um momento e tente novamente.';
      }
    }

    return 'Não foi possível concluir a operação. Tente novamente.';
  }
}
