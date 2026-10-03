import 'package:flutter_test/flutter_test.dart';
import 'package:vango_app/features/driver/models/driver_trip.dart';
import 'package:vango_app/features/driver/models/route_stop.dart';

/// Builds a `get_trip` owner/driver projection with overridable trip fields.
Map<String, dynamic> tripProjection({
  String id = 'trip-1',
  String status = 'scheduled',
  String driverUserId = 'driver-1',
  String plannedStartAt = '2026-10-05T09:30:00+00:00',
  List<Map<String, dynamic>>? passengers,
  List<Map<String, dynamic>>? stops,
}) => {
  'trip': {
    'id': id,
    'fleet_id': 'fleet-1',
    'route_id': 'route-1',
    'status': status,
    'planned_start_at': plannedStartAt,
    'driver_user_id': driverUserId,
    'route_name': 'Rota Manhã',
    'van_plate': 'ABC1D23',
    'van_public_name': 'Van Azul',
  },
  'passengers':
      passengers ??
      [
        {
          'id': 'p-1',
          'student_id': 'student-1',
          'student_full_name': 'Ana Souza',
          'confirmation_status': 'confirmed',
          'operation_status': 'waiting',
          'removed_at': null,
        },
      ],
  'stops':
      stops ??
      [
        {
          'id': 's-dest',
          'kind': 'destination',
          'position': 200000,
          'address_snapshot': {'label': 'Garagem'},
          'latitude': -23.6,
          'longitude': -46.7,
          'reached_at': null,
        },
        {
          'id': 's-origin',
          'kind': 'origin',
          'position': 1,
          'address_snapshot': {'label': 'Garagem'},
          'latitude': -23.6,
          'longitude': -46.7,
          'reached_at': '2026-10-05T09:31:00+00:00',
        },
        {
          'id': 's-home',
          'kind': 'home',
          'student_id': 'student-1',
          'position': 1000,
          'address_snapshot': {
            'street': 'Rua A',
            'street_number': '10',
            'neighborhood': 'Centro',
            'city_name': 'Sorocaba',
          },
          'latitude': -23.5,
          'longitude': -46.6,
          'reached_at': null,
        },
        {
          'id': 's-school',
          'kind': 'school',
          'school_id': 'school-1',
          'position': 100001,
          'address_snapshot': {'name': 'Colégio Central', 'street': 'Rua B'},
          'latitude': null,
          'longitude': null,
          'reached_at': null,
        },
      ],
};

void main() {
  group('TripStatus.fromBackend', () {
    test('maps every backend trip state', () {
      expect(TripStatus.fromBackend('scheduled'), TripStatus.scheduled);
      expect(
        TripStatus.fromBackend('confirmation_closed'),
        TripStatus.confirmationClosed,
      );
      expect(TripStatus.fromBackend('active'), TripStatus.active);
      expect(TripStatus.fromBackend('completed'), TripStatus.completed);
      expect(TripStatus.fromBackend('cancelled'), TripStatus.cancelled);
    });

    test('rejects unknown states instead of guessing', () {
      expect(() => TripStatus.fromBackend('paused'), throwsFormatException);
    });
  });

  group('DriverTrip.fromProjection', () {
    test('maps trip identity and backend labels', () {
      final trip = DriverTrip.fromProjection(tripProjection());

      expect(trip.id, 'trip-1');
      expect(trip.fleetId, 'fleet-1');
      expect(trip.routeName, 'Rota Manhã');
      expect(trip.vanPlate, 'ABC1D23');
      expect(trip.driverUserId, 'driver-1');
      expect(trip.status, TripStatus.scheduled);
      expect(trip.plannedStartAt, DateTime.utc(2026, 10, 5, 9, 30));
    });

    test('keeps backend stop ordering by position', () {
      final trip = DriverTrip.fromProjection(tripProjection());

      expect(trip.stops.map((s) => s.id), [
        's-origin',
        's-home',
        's-school',
        's-dest',
      ]);
    });

    test('resolves stop names from passengers and snapshots', () {
      final stops = DriverTrip.fromProjection(tripProjection()).stops;

      expect(stops[0].name, 'Partida');
      expect(stops[0].address, 'Garagem');
      expect(stops[1].name, 'Ana Souza');
      expect(stops[1].address, 'Rua A, 10 - Centro, Sorocaba');
      expect(stops[2].name, 'Colégio Central');
      expect(stops[3].name, 'Destino');
    });

    test('maps passenger and reached state onto stops', () {
      final stops = DriverTrip.fromProjection(
        tripProjection(
          passengers: [
            {
              'id': 'p-1',
              'student_id': 'student-1',
              'student_full_name': 'Ana Souza',
              'confirmation_status': 'confirmed',
              'operation_status': 'boarded',
              'removed_at': null,
            },
          ],
        ),
      ).stops;

      expect(stops[0].status, StopStatus.reached);
      expect(stops[1].status, StopStatus.boarded);
      expect(stops[1].kind, StopKind.home);
      expect(stops[2].status, StopStatus.pending);
    });

    test('maps every passenger operation status', () {
      StopStatus statusFor(String operationStatus) => DriverTrip.fromProjection(
        tripProjection(
          passengers: [
            {
              'id': 'p-1',
              'student_id': 'student-1',
              'student_full_name': 'Ana Souza',
              'confirmation_status': 'confirmed',
              'operation_status': operationStatus,
              'removed_at': null,
            },
          ],
        ),
      ).stops[1].status;

      expect(statusFor('waiting'), StopStatus.pending);
      expect(statusFor('boarded'), StopStatus.boarded);
      expect(statusFor('dropped_off'), StopStatus.droppedOff);
      expect(statusFor('absent'), StopStatus.absent);
      expect(() => statusFor('flying'), throwsFormatException);
    });

    test('excludes home stops of removed or declined passengers', () {
      final trip = DriverTrip.fromProjection(
        tripProjection(
          passengers: [
            {
              'id': 'p-1',
              'student_id': 'student-1',
              'student_full_name': 'Ana Souza',
              'confirmation_status': 'declined',
              'operation_status': 'waiting',
              'removed_at': null,
            },
          ],
        ),
      );

      expect(trip.stops.where((s) => s.kind == StopKind.home), isEmpty);
      expect(trip.totalStudents, 0);
    });

    test('keeps stops without coordinates but marks them unmappable', () {
      final school = DriverTrip.fromProjection(tripProjection()).stops[2];

      expect(school.hasCoordinates, isFalse);
      expect(school.latitude, isNull);
    });

    test('counts only home stops as students', () {
      final trip = DriverTrip.fromProjection(tripProjection());

      expect(trip.totalStudents, 1);
      expect(trip.completedStudentsCount, 0);
    });

    test('rejects a projection without trip identity', () {
      expect(
        () => DriverTrip.fromProjection({'passengers': [], 'stops': []}),
        throwsFormatException,
      );
    });
  });

  group('DriverTrip.isOperableBy', () {
    test('only the assigned driver operates a non-terminal trip', () {
      final trip = DriverTrip.fromProjection(tripProjection());

      expect(trip.isOperableBy('driver-1'), isTrue);
      expect(trip.isOperableBy('owner-1'), isFalse);
      expect(trip.isOperableBy(null), isFalse);
    });

    test('terminal trips are read-only for everyone', () {
      for (final status in ['completed', 'cancelled']) {
        final trip = DriverTrip.fromProjection(tripProjection(status: status));
        expect(trip.isOperableBy('driver-1'), isFalse, reason: status);
      }
    });
  });
}
