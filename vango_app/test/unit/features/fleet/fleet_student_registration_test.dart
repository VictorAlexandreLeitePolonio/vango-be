import 'package:flutter_test/flutter_test.dart';
import 'package:vango_app/features/fleet/models/fleet_student_registration.dart';

FleetStudentRegistration registration({
  DateTime? birthDate,
  FleetStudentType type = FleetStudentType.minor,
  double latitude = 0,
  double longitude = 0,
  String? email = ' OWNER@EXAMPLE.COM ',
  String? phone = ' ',
}) => FleetStudentRegistration(
  studentType: type,
  fullName: ' Ana Silva ',
  birthDate: birthDate ?? DateTime(2012, 2, 29),
  postalCode: '01001000',
  street: ' Rua Um ',
  streetNumber: ' 12 ',
  neighborhood: ' Centro ',
  city: const FleetServiceCity(
    cityIbgeCode: '3550308',
    cityName: 'São Paulo',
    stateCode: 'SP',
  ),
  latitude: latitude,
  longitude: longitude,
  schoolId: '10000000-0000-4000-8000-000000000001',
  shift: FleetStudentShift.fullTime,
  contactFullName: ' Responsável ',
  contactEmail: email,
  contactPhone: phone,
  addressComplement: ' ',
);

void main() {
  test(
    'serializes the exact RPC contract with civil date and normalized optional values',
    () {
      expect(
        registration().toRpcParams(fleetId: 'fleet', commandId: 'command'),
        {
          'p_fleet_id': 'fleet',
          'p_command_id': 'command',
          'p_student_type': 'minor',
          'p_full_name': 'Ana Silva',
          'p_birth_date': '2012-02-29',
          'p_postal_code': '01001000',
          'p_street': 'Rua Um',
          'p_street_number': '12',
          'p_address_complement': null,
          'p_neighborhood': 'Centro',
          'p_city_name': 'São Paulo',
          'p_city_ibge_code': '3550308',
          'p_state_code': 'SP',
          'p_latitude': 0.0,
          'p_longitude': 0.0,
          'p_school_id': '10000000-0000-4000-8000-000000000001',
          'p_shift': 'full_time',
          'p_contact_full_name': 'Responsável',
          'p_contact_email': 'owner@example.com',
          'p_contact_phone': null,
        },
      );
    },
  );
  test(
    'validates birthday boundaries using civil dates including leap day',
    () {
      final today = DateTime(2026, 2, 28);
      expect(
        registration(birthDate: DateTime(2008, 2, 28)).validate(today: today),
        contains('studentType'),
      );
      expect(
        registration(birthDate: DateTime(2008, 2, 29)).validate(today: today),
        isEmpty,
      );
      expect(
        registration(
          birthDate: DateTime(2008, 2, 29),
          type: FleetStudentType.adult,
        ).validate(today: DateTime(2026, 3, 1)),
        isEmpty,
      );
      expect(
        registration(birthDate: DateTime(2027)).validate(today: today),
        contains('birthDate'),
      );
    },
  );
  test(
    'rejects missing contact channels and non-finite or out-of-range coordinates',
    () {
      final today = DateTime(2026, 9, 26);
      expect(
        registration(email: ' ', phone: null).validate(today: today),
        contains('contact'),
      );
      for (final latitude in [double.nan, double.infinity, -91.0, 91.0]) {
        expect(
          registration(latitude: latitude).validate(today: today),
          contains('location'),
        );
      }
      for (final longitude in [double.nan, -181.0, 181.0]) {
        expect(
          registration(longitude: longitude).validate(today: today),
          contains('location'),
        );
      }
      expect(
        registration(latitude: -90, longitude: 180).validate(today: today),
        isEmpty,
      );
    },
  );

  test('rejects blank personal address and coverage fields', () {
    final draft = FleetStudentRegistration(
      studentType: FleetStudentType.minor,
      fullName: ' ',
      birthDate: DateTime(2012),
      postalCode: '',
      street: '',
      streetNumber: '',
      neighborhood: '',
      city: const FleetServiceCity(
        cityIbgeCode: 'invalid',
        cityName: '',
        stateCode: 'S',
      ),
      latitude: 0,
      longitude: 0,
      schoolId: '',
      shift: FleetStudentShift.morning,
      contactFullName: '',
      contactEmail: 'bad-email',
    );
    final errors = draft.validate(today: DateTime(2026));
    expect(
      errors.keys,
      containsAll([
        'fullName',
        'postalCode',
        'street',
        'streetNumber',
        'neighborhood',
        'city',
        'schoolId',
        'contactFullName',
        'contactEmail',
      ]),
    );
  });
}
