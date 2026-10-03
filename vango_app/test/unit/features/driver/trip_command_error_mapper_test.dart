import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:vango_app/features/driver/services/trip_command_error_mapper.dart';

PostgrestException postgrest(String? code) =>
    PostgrestException(message: 'secret backend detail', code: code);

void main() {
  group('TripCommandErrorMapper.kind', () {
    test('definitive rejections drop the pending command id', () {
      for (final code in [
        'confirmation_closed',
        'invalid_transition',
        'passengers_on_board',
        'resource_in_use',
        'idempotency_conflict',
        'invalid_input',
        'email_unverified',
      ]) {
        expect(
          TripCommandErrorMapper.kind(postgrest(code)),
          TripCommandFailure.rejected,
          reason: code,
        );
      }
    });

    test('access loss is definitive and session scoped', () {
      for (final code in [
        'unauthenticated',
        'forbidden',
        'not_found',
        '42501',
      ]) {
        expect(
          TripCommandErrorMapper.kind(postgrest(code)),
          TripCommandFailure.accessLost,
          reason: code,
        );
      }
      expect(
        TripCommandErrorMapper.kind(
          const AuthException('session expired', statusCode: '401'),
        ),
        TripCommandFailure.accessLost,
      );
    });

    test('unknown outcomes may have committed and stay uncertain', () {
      for (final error in <Object>[
        postgrest('queue_priority'),
        postgrest(null),
        const SocketException('offline'),
        TimeoutException('timeout'),
        const FormatException('bad json'),
        StateError('anything'),
      ]) {
        expect(
          TripCommandErrorMapper.kind(error),
          TripCommandFailure.uncertain,
          reason: error.toString(),
        );
      }
    });

    test('kind is keyed only by the code, never by the message text', () {
      expect(
        TripCommandErrorMapper.kind(
          PostgrestException(
            message: 'confirmation_closed',
            code: 'weird_code',
          ),
        ),
        TripCommandFailure.uncertain,
      );
    });
  });

  group('TripCommandErrorMapper.message', () {
    test('maps every rejection code to its pt-BR message', () {
      for (final (code, text) in [
        (
          'confirmation_closed',
          'Aguarde o encerramento das confirmações para iniciar a viagem.',
        ),
        (
          'invalid_transition',
          'Esta ação não está disponível no estado atual da viagem.',
        ),
        (
          'passengers_on_board',
          'Há alunos sem desembarque ou ausência registrados.',
        ),
        (
          'resource_in_use',
          'A van ou o motorista já estão em outra viagem ativa.',
        ),
        (
          'idempotency_conflict',
          'Este comando conflita com outro já registrado. Recarregue a viagem.',
        ),
        (
          'invalid_input',
          'Não foi possível registrar a ação. Recarregue a viagem.',
        ),
        ('email_unverified', 'Confirme seu e-mail para operar viagens.'),
      ]) {
        expect(
          TripCommandErrorMapper.message(postgrest(code)),
          text,
          reason: code,
        );
      }
    });

    test('maps access loss codes to the access message', () {
      for (final code in [
        'unauthenticated',
        'forbidden',
        'not_found',
        '42501',
      ]) {
        expect(
          TripCommandErrorMapper.message(postgrest(code)),
          'Você não tem acesso a esta viagem.',
          reason: code,
        );
      }
    });

    test('maps uncertain outcomes to the retry message', () {
      expect(
        TripCommandErrorMapper.message(postgrest('queue_priority')),
        'Não foi possível confirmar a ação. Tente novamente.',
      );
      expect(
        TripCommandErrorMapper.message(const SocketException('offline')),
        'Não foi possível confirmar a ação. Tente novamente.',
      );
    });

    test('message never contains the backend message text', () {
      for (final code in [
        'confirmation_closed',
        'invalid_transition',
        'passengers_on_board',
        'resource_in_use',
        'idempotency_conflict',
        'invalid_input',
        'email_unverified',
        'unauthenticated',
        'forbidden',
        'not_found',
        '42501',
        'queue_priority',
        null,
      ]) {
        expect(
          TripCommandErrorMapper.message(postgrest(code)),
          isNot(contains('secret')),
          reason: '$code',
        );
      }
    });
  });
}
