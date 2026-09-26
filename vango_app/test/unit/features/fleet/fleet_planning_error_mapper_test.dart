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
}
