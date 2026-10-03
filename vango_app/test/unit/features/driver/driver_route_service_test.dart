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

    test('reloading the same trip keeps its computed route geometry', () async {
      final client = await planningClient(
        (request) async =>
            jsonResponse(tripProjection(status: 'active'), request),
      );
      addTearDown(client.dispose);
      final service = DriverRouteService(
        client: client,
        directionsService: FakeDirectionsService(),
      );

      await service.getTrip('trip-1');
      final routed = await service.calculateAndOptimizeRoute();
      final reloaded = await service.getTrip('trip-1');

      expect(reloaded.polylinePoints, routed.polylinePoints);
      expect(reloaded.polylinePoints, isNotEmpty);
      expect(reloaded.totalDistanceMeters, 8500);
      expect(reloaded.totalDurationSeconds, 1500);
    });

    test(
      'exposes the authenticated user for operate permission checks',
      () async {
        final client = await planningClient((request) async => fail('none'));
        addTearDown(client.dispose);

        expect(DriverRouteService(client: client).currentUserId, testId);
      },
    );
  });

  group('route geometry', () {
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
  });

  group('trip lifecycle commands', () {
    test(
      'startTrip sends the exact body and reloads the persisted trip',
      () async {
        final bodies = <String, Map<String, dynamic>>{};
        final client = await planningClient((request) async {
          final name = request.url.path.split('/').last;
          bodies[name] = jsonDecode(request.body) as Map<String, dynamic>;
          if (name == 'start_trip') return jsonResponse('active', request);
          expect(name, 'get_trip');
          return jsonResponse(tripProjection(status: 'active'), request);
        });
        addTearDown(client.dispose);

        final trip = await DriverRouteService(
          client: client,
        ).startTrip('trip-1', 'cmd-1');

        expect(bodies['start_trip'], {
          'p_trip_id': 'trip-1',
          'p_command_id': 'cmd-1',
        });
        expect(bodies['get_trip'], {'p_trip_id': 'trip-1'});
        expect(trip.status, TripStatus.active);
      },
    );

    test('recordPassengerEvent sends the backend kind string', () async {
      final bodies = <String, Map<String, dynamic>>{};
      final client = await planningClient((request) async {
        final name = request.url.path.split('/').last;
        bodies[name] = jsonDecode(request.body) as Map<String, dynamic>;
        if (name == 'record_passenger_event') {
          return jsonResponse('boarded', request);
        }
        expect(name, 'get_trip');
        return jsonResponse(tripProjection(status: 'active'), request);
      });
      addTearDown(client.dispose);

      final trip = await DriverRouteService(client: client)
          .recordPassengerEvent(
            'trip-1',
            'student-1',
            PassengerEventKind.boarded,
            'cmd-2',
          );

      expect(bodies['record_passenger_event'], {
        'p_trip_id': 'trip-1',
        'p_student_id': 'student-1',
        'p_kind': 'boarded',
        'p_command_id': 'cmd-2',
      });
      expect(trip.status, TripStatus.active);
    });

    test('every passenger kind maps to its backend string', () {
      expect(PassengerEventKind.boarded.backend, 'boarded');
      expect(PassengerEventKind.absent.backend, 'absent');
      expect(PassengerEventKind.droppedOff.backend, 'dropped_off');
    });

    test('markStopReached sends only the stop id and the command', () async {
      final bodies = <String, Map<String, dynamic>>{};
      final client = await planningClient((request) async {
        final name = request.url.path.split('/').last;
        bodies[name] = jsonDecode(request.body) as Map<String, dynamic>;
        if (name == 'mark_trip_stop_reached') {
          return http.Response('', 200, headers: const {}, request: request);
        }
        expect(name, 'get_trip');
        return jsonResponse(tripProjection(status: 'active'), request);
      });
      addTearDown(client.dispose);

      final trip = await DriverRouteService(
        client: client,
      ).markStopReached('trip-1', 's-school', 'cmd-3');

      expect(bodies['mark_trip_stop_reached'], {
        'p_stop_id': 's-school',
        'p_command_id': 'cmd-3',
      });
      expect(trip.status, TripStatus.active);
    });

    test(
      'finishTrip sends cancel false, null reason and the command',
      () async {
        final bodies = <String, Map<String, dynamic>>{};
        final client = await planningClient((request) async {
          final name = request.url.path.split('/').last;
          bodies[name] = jsonDecode(request.body) as Map<String, dynamic>;
          if (name == 'finish_trip') return jsonResponse('completed', request);
          expect(name, 'get_trip');
          return jsonResponse(tripProjection(status: 'completed'), request);
        });
        addTearDown(client.dispose);

        final trip = await DriverRouteService(
          client: client,
        ).finishTrip('trip-1', 'cmd-4');

        expect(bodies['finish_trip'], {
          'p_trip_id': 'trip-1',
          'p_cancel': false,
          'p_reason': null,
          'p_command_id': 'cmd-4',
        });
        expect(trip.status, TripStatus.completed);
      },
    );

    test('backend rejections propagate without any reload', () async {
      var getTripCalls = 0;
      final client = await planningClient((request) async {
        if (request.url.path.endsWith('/rpc/start_trip')) {
          return jsonResponse(
            {'code': 'passengers_on_board', 'message': 'x'},
            request,
            409,
          );
        }
        getTripCalls++;
        return jsonResponse(tripProjection(), request);
      });
      addTearDown(client.dispose);

      await expectLater(
        DriverRouteService(client: client).startTrip('trip-1', 'cmd-1'),
        throwsA(
          isA<PostgrestException>().having(
            (e) => e.code,
            'code',
            'passengers_on_board',
          ),
        ),
      );
      expect(getTripCalls, 0);
    });
  });
}
