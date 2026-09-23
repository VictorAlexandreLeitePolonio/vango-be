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
    required this.latitude,
    required this.longitude,
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
  final double latitude;
  final double longitude;

  String get fullAddress =>
      '$street, $streetNumber - $neighborhood, $cityName - $stateCode';

  factory StudentProfile.fromMap(Map<String, dynamic> map) {
    return StudentProfile(
      id: map['id'] as String? ?? '',
      fullName: map['full_name'] as String? ?? '',
      birthDate: map['birth_date'] as String? ?? '',
      street: map['street'] as String? ?? '',
      streetNumber: map['street_number'] as String? ?? '',
      neighborhood: map['neighborhood'] as String? ?? '',
      cityName: map['city_name'] as String? ?? 'São Paulo',
      cityIbgeCode: map['city_ibge_code'] as String? ?? '3550308',
      stateCode: map['state_code'] as String? ?? 'SP',
      postalCode: map['postal_code'] as String? ?? '01000-000',
      latitude: (map['latitude'] as num?)?.toDouble() ?? -23.5615,
      longitude: (map['longitude'] as num?)?.toDouble() ?? -46.6698,
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
