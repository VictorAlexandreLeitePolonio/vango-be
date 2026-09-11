import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:vango_app/features/auth/services/auth_error_mapper.dart';

void main() {
  test('maps invalid credentials to a Portuguese message', () {
    final error = const AuthException(
      'invalid credentials',
      statusCode: '400',
      code: 'invalid_credentials',
    );

    expect(AuthErrorMapper.message(error), 'E-mail ou senha incorretos.');
  });

  test('maps an existing email to a Portuguese message', () {
    final error = const AuthException(
      'email already exists',
      statusCode: '422',
      code: 'email_exists',
    );

    expect(AuthErrorMapper.message(error), 'Este e-mail já está cadastrado.');
  });

  test('maps a weak password to a Portuguese message', () {
    final error = AuthWeakPasswordException(
      message: 'weak password',
      statusCode: '422',
      reasons: const ['password_too_short'],
    );

    expect(
      AuthErrorMapper.message(error),
      'A senha não atende aos requisitos mínimos.',
    );
  });

  test('maps rate limiting to a Portuguese message', () {
    final error = const AuthException(
      'too many requests',
      statusCode: '429',
      code: 'over_request_rate_limit',
    );

    expect(
      AuthErrorMapper.message(error),
      'Muitas tentativas. Aguarde um momento e tente novamente.',
    );
  });

  test('maps email rate limiting to a Portuguese message', () {
    final error = const AuthException(
      'too many email requests',
      statusCode: '429',
      code: 'over_email_send_rate_limit',
    );

    expect(
      AuthErrorMapper.message(error),
      'Muitas tentativas. Aguarde um momento e tente novamente.',
    );
  });

  test('maps an unknown auth error with status 429 to a rate message', () {
    final error = const AuthException(
      'too many requests',
      statusCode: '429',
      code: 'unknown_rate_limit_code',
    );

    expect(
      AuthErrorMapper.message(error),
      'Muitas tentativas. Aguarde um momento e tente novamente.',
    );
  });

  test('maps retryable auth errors to a network message', () {
    expect(
      AuthErrorMapper.message(AuthRetryableFetchException()),
      'Não foi possível conectar ao servidor. Verifique sua internet.',
    );
  });

  test('uses a generic message for unknown errors', () {
    expect(
      AuthErrorMapper.message(StateError('internal details')),
      'Não foi possível concluir a operação. Tente novamente.',
    );
  });
}
