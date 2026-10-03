import 'onboarding_intent.dart';

enum AccountRole { owner, driver, guardian, student }

class FleetAccess {
  const FleetAccess({required this.fleetId, required this.roles});

  final String fleetId;
  final Set<AccountRole> roles;
}

class AccessContext {
  const AccessContext({
    required this.onboardingIntent,
    required this.accountRoles,
    required this.dependentStudentIds,
    required this.adultStudentId,
    required this.fleetAccess,
  });

  final OnboardingIntent? onboardingIntent;
  final Set<AccountRole> accountRoles;
  final List<String> dependentStudentIds;
  final String? adultStudentId;
  final List<FleetAccess> fleetAccess;

  /// Returns active owner fleet IDs, deduplicated and sorted for display.
  List<String> get ownerFleetIds =>
      fleetAccess
          .where((access) => access.roles.contains(AccountRole.owner))
          .map((access) => access.fleetId)
          .toSet()
          .toList()
        ..sort();

  factory AccessContext.fromJson(Map<String, dynamic> json) {
    return AccessContext(
      onboardingIntent: _parseOnboardingIntent(json['onboarding_intent']),
      accountRoles: _parseRoles(json['account_roles'], 'account_roles'),
      dependentStudentIds: _parseStrings(
        json['dependent_student_ids'],
        'dependent_student_ids',
      ),
      adultStudentId: _parseNullableString(
        json['adult_student_id'],
        'adult_student_id',
      ),
      fleetAccess: _parseFleetAccess(json['fleet_access']),
    );
  }

  static OnboardingIntent? _parseOnboardingIntent(Object? value) {
    if (value == null) return null;
    if (value is! String) {
      throw const FormatException('Invalid onboarding_intent');
    }

    for (final intent in OnboardingIntent.values) {
      if (intent.apiValue == value) return intent;
    }
    throw const FormatException('Unknown onboarding_intent');
  }

  static Set<AccountRole> _parseRoles(Object? value, String field) {
    final values = _requireList(value, field);
    return values.map((role) {
      if (role is! String) throw FormatException('Invalid $field');
      return switch (role) {
        'owner' => AccountRole.owner,
        'driver' => AccountRole.driver,
        'guardian' => AccountRole.guardian,
        'student' => AccountRole.student,
        _ => throw FormatException('Unknown role in $field'),
      };
    }).toSet();
  }

  static List<String> _parseStrings(Object? value, String field) {
    final values = _requireList(value, field);
    return values.map((item) {
      if (item is! String) throw FormatException('Invalid $field');
      return item;
    }).toList();
  }

  static String? _parseNullableString(Object? value, String field) {
    if (value == null) return null;
    if (value is! String) throw FormatException('Invalid $field');
    return value;
  }

  static List<FleetAccess> _parseFleetAccess(Object? value) {
    final entries = _requireList(value, 'fleet_access');
    return entries.map((entry) {
      if (entry is! Map) {
        throw const FormatException('Invalid fleet_access');
      }
      final fleetId = entry['fleet_id'];
      if (fleetId is! String) {
        throw const FormatException('Invalid fleet_id');
      }
      return FleetAccess(
        fleetId: fleetId,
        roles: _parseRoles(entry['roles'], 'fleet_access.roles'),
      );
    }).toList();
  }

  static List<Object?> _requireList(Object? value, String field) {
    if (value is! List) throw FormatException('Invalid $field');
    return value;
  }
}
