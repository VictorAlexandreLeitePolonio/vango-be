import 'package:flutter_test/flutter_test.dart';

import 'package:vango_app/features/auth/models/access_context.dart';
import 'package:vango_app/features/auth/models/onboarding_intent.dart';

void main() {
  test('parses roles, dependents, adult student, and fleet access', () {
    final context = AccessContext.fromJson({
      'onboarding_intent': 'guardian',
      'account_roles': ['driver', 'guardian'],
      'dependent_student_ids': ['student-1'],
      'adult_student_id': null,
      'fleet_access': [
        {
          'fleet_id': 'fleet-1',
          'roles': ['driver'],
        },
      ],
    });

    expect(context.onboardingIntent, OnboardingIntent.guardian);
    expect(context.accountRoles, {AccountRole.driver, AccountRole.guardian});
    expect(context.dependentStudentIds, ['student-1']);
    expect(context.adultStudentId, isNull);
    expect(context.fleetAccess.single.fleetId, 'fleet-1');
    expect(context.fleetAccess.single.roles, {AccountRole.driver});
  });

  test('parses a nullable setup state', () {
    final context = AccessContext.fromJson({
      'onboarding_intent': null,
      'account_roles': <String>[],
      'dependent_student_ids': <String>[],
      'adult_student_id': null,
      'fleet_access': <Map<String, dynamic>>[],
    });

    expect(context.onboardingIntent, isNull);
    expect(context.accountRoles, isEmpty);
    expect(context.fleetAccess, isEmpty);
  });

  test('rejects an unknown effective role', () {
    expect(
      () => AccessContext.fromJson({
        'onboarding_intent': 'guardian',
        'account_roles': ['admin'],
        'dependent_student_ids': <String>[],
        'adult_student_id': null,
        'fleet_access': <Map<String, dynamic>>[],
      }),
      throwsFormatException,
    );
  });

  test('rejects a malformed fleet access entry', () {
    expect(
      () => AccessContext.fromJson({
        'onboarding_intent': 'driver',
        'account_roles': ['driver'],
        'dependent_student_ids': <String>[],
        'adult_student_id': null,
        'fleet_access': [
          {
            'fleet_id': 42,
            'roles': ['driver'],
          },
        ],
      }),
      throwsFormatException,
    );
  });
}
