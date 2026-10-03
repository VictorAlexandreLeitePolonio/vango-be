/// Age category validated again by the registration RPC.
enum FleetStudentType { minor, adult }

/// Available school attendance shifts.
enum FleetStudentShift { morning, afternoon, evening, fullTime }

/// Municipality explicitly covered by the selected fleet.
class FleetServiceCity {
  const FleetServiceCity({
    required this.cityIbgeCode,
    required this.cityName,
    required this.stateCode,
  });
  final String cityIbgeCode, cityName, stateCode;
}

/// Minimal authorized school projection.
class FleetServiceSchool {
  const FleetServiceSchool({required this.id, required this.name});
  final String id, name;
}

/// Identifiers returned by one confirmed registration transaction.
typedef FleetStudentRegistrationReceipt = ({
  String studentId,
  String enrollmentId,
});

/// Immutable registration draft and exact RPC payload.
class FleetStudentRegistration {
  const FleetStudentRegistration({
    required this.studentType,
    required this.fullName,
    required this.birthDate,
    required this.postalCode,
    required this.street,
    required this.streetNumber,
    required this.neighborhood,
    required this.city,
    required this.latitude,
    required this.longitude,
    required this.schoolId,
    required this.shift,
    required this.contactFullName,
    this.addressComplement,
    this.contactEmail,
    this.contactPhone,
  });
  final FleetStudentType studentType;
  final String fullName,
      postalCode,
      street,
      streetNumber,
      neighborhood,
      schoolId,
      contactFullName;
  final DateTime birthDate;
  final FleetServiceCity city;
  final double latitude, longitude;
  final FleetStudentShift shift;
  final String? addressComplement, contactEmail, contactPhone;

  /// Serializes the immutable command using civil dates.
  Map<String, Object?> toRpcParams({
    required String fleetId,
    required String commandId,
  }) => {
    'p_fleet_id': fleetId,
    'p_command_id': commandId,
    'p_student_type': studentType.name,
    'p_full_name': fullName.trim(),
    'p_birth_date':
        '${birthDate.year.toString().padLeft(4, '0')}-${birthDate.month.toString().padLeft(2, '0')}-${birthDate.day.toString().padLeft(2, '0')}',
    'p_postal_code': postalCode.trim(),
    'p_street': street.trim(),
    'p_street_number': streetNumber.trim(),
    'p_address_complement': _optional(addressComplement),
    'p_neighborhood': neighborhood.trim(),
    'p_city_name': city.cityName,
    'p_city_ibge_code': city.cityIbgeCode,
    'p_state_code': city.stateCode,
    'p_latitude': latitude,
    'p_longitude': longitude,
    'p_school_id': schoolId,
    'p_shift': shift == FleetStudentShift.fullTime ? 'full_time' : shift.name,
    'p_contact_full_name': contactFullName.trim(),
    'p_contact_email': _optional(contactEmail)?.toLowerCase(),
    'p_contact_phone': _optional(contactPhone),
  };
  static String? _optional(String? value) =>
      value == null || value.trim().isEmpty ? null : value.trim();

  /// Returns field feedback without granting authorization.
  Map<String, String> validate({required DateTime today}) {
    final errors = <String, String>{};
    final requiredFields = {
      'fullName': fullName,
      'postalCode': postalCode,
      'street': street,
      'streetNumber': streetNumber,
      'neighborhood': neighborhood,
      'schoolId': schoolId,
      'contactFullName': contactFullName,
    };
    for (final entry in requiredFields.entries) {
      if (entry.value.trim().isEmpty) {
        errors[entry.key] = 'Preencha este campo.';
      }
    }
    if (city.cityName.trim().isEmpty ||
        !RegExp(r'^\d{7}$').hasMatch(city.cityIbgeCode) ||
        !RegExp(r'^[A-Z]{2}$').hasMatch(city.stateCode)) {
      errors['city'] = 'Selecione uma cidade atendida pela frota.';
    }
    final email = _optional(contactEmail);
    if (email != null &&
        !RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(email)) {
      errors['contactEmail'] = 'Informe um e-mail válido.';
    }
    final date = DateTime(birthDate.year, birthDate.month, birthDate.day);
    final currentDate = DateTime(today.year, today.month, today.day);
    if (date.isAfter(currentDate)) {
      errors['birthDate'] = 'Selecione uma data de nascimento válida.';
    }
    // PostgreSQL age reaches eighteen on March 1 for a leap-day birth in a common year.
    final birthdayReached =
        today.month > birthDate.month ||
        (today.month == birthDate.month && today.day >= birthDate.day);
    final age = today.year - birthDate.year - (birthdayReached ? 0 : 1);
    if ((studentType == FleetStudentType.adult) != (age >= 18)) {
      errors['studentType'] = 'Confira o tipo de aluno e a data de nascimento.';
    }
    if (_optional(contactEmail) == null && _optional(contactPhone) == null) {
      errors['contact'] = 'Informe um e-mail ou telefone de contato.';
    }
    if (!latitude.isFinite ||
        !longitude.isFinite ||
        latitude < -90 ||
        latitude > 90 ||
        longitude < -180 ||
        longitude > 180) {
      errors['location'] = 'Selecione um endereço válido na busca.';
    }
    return errors;
  }
}
