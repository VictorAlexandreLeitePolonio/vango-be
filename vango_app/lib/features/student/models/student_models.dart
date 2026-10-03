/// Student linked to the signed-in guardian, as stored in `public.students`.
class StudentProfile {
  const StudentProfile({
    required this.id,
    required this.fullName,
    required this.birthDate,
    required this.street,
    required this.streetNumber,
    required this.neighborhood,
    required this.cityName,
    required this.cityIbgeCode,
    required this.stateCode,
    required this.postalCode,
    this.latitude,
    this.longitude,
  });

  final String id;
  final String fullName;
  final String birthDate;
  final String street;
  final String streetNumber;
  final String neighborhood;
  final String cityName;
  final String cityIbgeCode;
  final String stateCode;
  final String postalCode;

  /// Pickup coordinates; `null` when the backend has none (never defaulted).
  final double? latitude;
  final double? longitude;

  String get fullAddress =>
      '$street, $streetNumber - $neighborhood, $cityName - $stateCode';

  /// Builds a profile from a `students` row. Missing values stay empty
  /// instead of being replaced by invented locations.
  factory StudentProfile.fromMap(Map<String, dynamic> map) {
    return StudentProfile(
      id: map['id'] as String? ?? '',
      fullName: map['full_name'] as String? ?? '',
      birthDate: map['birth_date'] as String? ?? '',
      street: map['street'] as String? ?? '',
      streetNumber: map['street_number'] as String? ?? '',
      neighborhood: map['neighborhood'] as String? ?? '',
      cityName: map['city_name'] as String? ?? '',
      cityIbgeCode: map['city_ibge_code'] as String? ?? '',
      stateCode: map['state_code'] as String? ?? '',
      postalCode: map['postal_code'] as String? ?? '',
      latitude: (map['latitude'] as num?)?.toDouble(),
      longitude: (map['longitude'] as num?)?.toDouble(),
    );
  }
}

class AvailableVanFleet {
  const AvailableVanFleet({
    required this.fleetId,
    required this.fleetName,
    required this.vanPlate,
    required this.vanModel,
    required this.vanPublicName,
    required this.capacity,
    required this.schoolId,
    required this.schoolName,
  });

  final String fleetId;
  final String fleetName;
  final String vanPlate;
  final String vanModel;
  final String vanPublicName;
  final int capacity;
  final String schoolId;
  final String schoolName;
}

class SchoolOption {
  const SchoolOption({
    required this.id,
    required this.name,
    required this.address,
  });

  final String id;
  final String name;
  final String address;
}
