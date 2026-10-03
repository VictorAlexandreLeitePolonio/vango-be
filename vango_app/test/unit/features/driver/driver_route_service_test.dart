import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:vango_app/features/driver/models/driver_trip.dart';
import 'package:vango_app/features/driver/models/route_stop.dart';
import 'package:vango_app/features/driver/services/driver_route_service.dart';
import 'package:vango_app/features/driver/services/mapbox_directions_service.dart';

import '../fleet/fleet_planning_service_test.dart' show planningClient, testId;
import 'driver_trip_test.dart' show tripProjection;

class FakeDirectionsService extends MapboxDirectionsService {
  final seen = <List<LatLng>>[];

  @override
  Future<DirectionsResult> getDrivingRoute({
    required String cacheKey,
    required List<LatLng> coordinates,
  }) async {
    seen.add(coordinates);
    return DirectionsResult(
      polylinePoints: coordinates,
      totalDistanceMeters: 8500,
      totalDurationSeconds: 1500,
      isFromCache: false,
    );
  }
}

http.Response jsonResponse(
  Object body,
  http.Request request, [
  int status = 200,
]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
  request: request,
);

void main() {
  group('listTrips', () {
    test(
      'returns an empty list when the user has no operational fleets',
      () async {
        final client = await planningClient((request) async {
          fail('no request expected');
        });
        addTearDown(client.dispose);

        final trips = await DriverRouteService(
          client: client,
        ).listTrips(fleetIds: const [], serviceDate: DateTime(2026, 10, 5));

        expect(trips, isEmpty);
      },
    );

    test(
      'reads each fleet service day and sorts trips by planned start',
      () async {
        final params = <Map<String, dynamic>>[];
        final client = await planningClient((request) async {
          expect(request.url.path, endsWith('/rpc/list_service_day'));
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          params.add(body);
          final trips = body['p_fleet_id'] == 'fleet-a'
              ? [
                  tripProjection(
                    id: 'late',
                    plannedStartAt: '2026-10-05T12:00:00+00:00',
                  ),
                ]
              : [
                  tripProjection(
                    id: 'early',
                    plannedStartAt: '2026-10-05T09:00:00+00:00',
                  ),
                ];
          return jsonResponse({
            'fleet_id': body['p_fleet_id'],
            'service_date': body['p_service_date'],
            'trips': trips,
          }, request);
        });
        addTearDown(client.dispose);

        final trips = await DriverRouteService(client: client).listTrips(
          fleetIds: const ['fleet-a', 'fleet-b'],
          serviceDate: DateTime(2026, 10, 5, 23, 59),
        );

        expect(params, [
          {'p_fleet_id': 'fleet-a', 'p_service_date': '2026-10-05'},
          {'p_fleet_id': 'fleet-b', 'p_service_date': '2026-10-05'},
        ]);
        expect(trips.map((t) => t.id), ['early', 'late']);
      },
    );

    test(
      'propagates backend failures instead of returning a fallback trip',
      () async {
        final client = await planningClient(
          (request) async => jsonResponse(
            {'code': 'forbidden', 'message': 'Forbidden'},
            request,
            403,
          ),
        );
        addTearDown(client.dispose);

        expect(
          DriverRouteService(client: client).listTrips(
            fleetIds: const ['fleet-a'],
            serviceDate: DateTime(2026, 10, 5),
          ),
          throwsA(
            isA<PostgrestException>().having(
              (e) => e.code,
              'code',
              'forbidden',
            ),
          ),
        );
      },
    );
  });

  group('getTrip', () {
    test(
      'loads the persisted trip by id, including an active status',
      () async {
        final client = await planningClient((request) async {
          expect(request.url.path, endsWith('/rpc/get_trip'));
          expect(jsonDecode(request.body), {'p_trip_id': 'trip-1'});
          return jsonResponse(tripProjection(status: 'active'), request);
        });
        addTearDown(client.dispose);

        final trip = await DriverRouteService(client: client).getTrip('trip-1');

        expect(trip.id, 'trip-1');
        expect(trip.status, TripStatus.active);
      },
    );

    test(
      'exposes the authenticated user for operate permission checks',
      () async {
        final client = await planningClient((request) async => fail('none'));
        addTearDown(client.dispose);

        expect(DriverRouteService(client: client).currentUserId, testId);
      },
    );
  });

  group('route geometry and local lifecycle', () {
    Future<DriverRouteService> loadedService(
      FakeDirectionsService directions,
    ) async {
      final client = await planningClient(
        (request) async => jsonResponse(tripProjection(), request),
      );
      addTearDown(client.dispose);
      final service = DriverRouteService(
        client: client,
        directionsService: directions,
      );
      await service.getTrip('trip-1');
      return service;
    }

    test('routes only through stops that have coordinates', () async {
      final directions = FakeDirectionsService();
      final service = await loadedService(directions);

      final trip = await service.calculateAndOptimizeRoute();

      // The school stop in the fixture has no coordinates.
      expect(directions.seen.single, hasLength(3));
      expect(trip.formattedDistance, '8.5 km');
      expect(trip.formattedDuration, '25 min');
    });

    test('requires a loaded trip before route calculation', () async {
      final client = await planningClient((request) async => fail('none'));
      addTearDown(client.dispose);

      expect(
        DriverRouteService(client: client).calculateAndOptimizeRoute(),
        throwsStateError,
      );
    });

    test('start, board and finish update the loaded trip', () async {
      final service = await loadedService(FakeDirectionsService());

      var trip = await service.startTrip();
      expect(trip.status, TripStatus.active);

      trip = await service.updateStopStatus('s-home', StopStatus.boarded);
      expect(
        trip.stops.firstWhere((s) => s.id == 's-home').status,
        StopStatus.boarded,
      );

      trip = await service.finishTrip();
      expect(trip.status, TripStatus.completed);
      expect(
        trip.stops
            .where((s) => s.isSchoolDestination)
            .every((s) => s.isCompleted),
        isTrue,
      );
    });
  });
}
