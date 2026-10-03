import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:vango_app/features/fleet/services/fleet_planning_error_mapper.dart';

void main() {
  test(
    'structured conflicts reject while unknown transport remains uncertain',
    () {
      expect(
        PlanningErrorMapper.kind(
          const PostgrestException(
            message: 'internal',
            code: 'revision_conflict',
          ),
        ),
        PlanningFailure.rejected,
      );
      expect(
        PlanningErrorMapper.kind(Exception('revision_conflict')),
        PlanningFailure.uncertain,
      );
      expect(
        PlanningErrorMapper.message(
          const PostgrestException(
            message: 'secret',
            code: 'revision_conflict',
          ),
        ),
        isNot(contains('secret')),
      );
    },
  );
  test('domain errors stay safe and distinct from transport uncertainty', () {
    for (final code in [
      'revision_conflict',
      'schedule_conflict',
      'resource_in_use',
      'capacity_exceeded',
      'plate_conflict',
      'invalid_input',
      'email_unverified',
      'unauthenticated',
      'forbidden',
      'not_found',
      '42501',
      'idempotency_conflict',
    ]) {
      final error = PostgrestException(
        message: 'secret SQL detail',
        code: code,
      );
      expect(PlanningErrorMapper.message(error), isNot(contains('secret')));
      expect(PlanningErrorMapper.kind(error), isNot(PlanningFailure.uncertain));
    }
  });
  test('direct allocation codes are safe pt-BR rejections', () {
    for (final (code, text) in [
      (
        'effective_date_conflict',
        'A data de início não está disponível para esta programação. Escolha outra data.',
      ),
      (
        'invalid_transition',
        'Esta ação não está disponível no estado atual do cadastro.',
      ),
      ('schedule_conflict', 'Este horário conflita com outra programação.'),
    ]) {
      final error = PostgrestException(message: 'secret', code: code);
      expect(PlanningErrorMapper.kind(error), PlanningFailure.rejected);
      expect(PlanningErrorMapper.message(error), text);
    }
    // allocation_failed is an unexpected 500: keep the command id and verify again.
    expect(
      PlanningErrorMapper.kind(
        const PostgrestException(message: 'x', code: 'allocation_failed'),
      ),
      PlanningFailure.uncertain,
    );
  });
}
