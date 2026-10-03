import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:vango_app/features/driver/models/route_stop.dart';
import 'package:geolocator/geolocator.dart';
import 'package:vango_app/features/driver/screens/driver_route_screen.dart';
import 'package:vango_app/features/driver/services/driver_location_service.dart';
import 'package:vango_app/features/driver/services/driver_route_service.dart';
import 'package:vango_app/features/driver/services/mapbox_directions_service.dart';
import 'package:vango_app/features/driver/services/trip_telemetry_uploader.dart';

import '../../../unit/features/driver/driver_location_service_test.dart'
    show FakeGeolocator, position;
import '../../../unit/features/driver/driver_trip_test.dart'
    show tripProjection;
import '../../../unit/features/fleet/fleet_planning_service_test.dart'
    show planningClient, testId;

class StubDirectionsService extends MapboxDirectionsService {
  @override
  Future<DirectionsResult> getDrivingRoute({
    required String cacheKey,
    required List<LatLng> coordinates,
  }) async {
    return DirectionsResult(
      polylinePoints: coordinates,
      totalDistanceMeters: 7400,
      totalDurationSeconds: 1320,
      isFromCache: false,
    );
  }
}

class CountingLocationService extends DriverLocationService {
  CountingLocationService() : super(geolocator: FakeGeolocator());

  int startCalls = 0;
  int stopCalls = 0;
  bool _tracking = false;

  @override
  bool get isTracking => _tracking;

  @override
  Future<GpsAvailability> startTracking({
    required List<LatLng> routePoints,
    List<RouteStop> pendingStops = const [],
    LocationTrackingMode mode = LocationTrackingMode.deviceGps,
  }) async {
    startCalls++;
    _tracking = true;
    return GpsAvailability.available;
  }

  /// Counts only real stops (tracking -> idle), not idempotent no-ops.
  @override
  void stopTracking() {
    if (_tracking) stopCalls++;
    _tracking = false;
  }
}

/// One scripted fake-backend reply for an RPC call.
class FakeRpcResponse {
  const FakeRpcResponse.ok(this.body) : status = 200;

  FakeRpcResponse.error(
    this.status,
    String code, [
    String message = 'backend detail',
  ]) : body = <String, dynamic>{'code': code, 'message': message};

  final int status;
  final Object body;
}

/// A scripted reply the test releases through a completer, to keep a command
/// in flight while the test interacts with the disabled screen.
class PendingRpc {
  final completer = Completer<FakeRpcResponse>();

  void respond(FakeRpcResponse response) => completer.complete(response);
}

/// Scripted fake backend routed by RPC path, with ordered call recording.
class RouteScreenHarness {
  final location = CountingLocationService();
  final calls = <({String rpc, Map<String, dynamic> body})>[];

  final Map<String, List<Object>> _script = {};

  void when(String rpc, List<Object> results) =>
      _script[rpc] = results.toList();

  void whenIfAbsent(String rpc, List<Object> results) =>
      _script.putIfAbsent(rpc, () => results.toList());

  List<Map<String, dynamic>> bodiesOf(String rpc) => [
    for (final call in calls)
      if (call.rpc == rpc) call.body,
  ];

  Future<http.Response> handle(http.Request request) async {
    final rpc = request.url.path.split('/').last;
    final body = request.body.isEmpty
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(jsonDecode(request.body) as Map);
    calls.add((rpc: rpc, body: body));
    final queue = _script[rpc];
    if (queue == null || queue.isEmpty) {
      return http.Response(
        jsonEncode({
          'code': 'unexpected_rpc',
          'message': 'no scripted response',
        }),
        500,
        headers: {'content-type': 'application/json'},
        request: request,
      );
    }
    final next = queue.removeAt(0);
    final FakeRpcResponse response;
    if (next is PendingRpc) {
      response = await next.completer.future;
    } else if (next is Future<FakeRpcResponse>) {
      response = await next;
    } else {
      response = next as FakeRpcResponse;
    }
    return http.Response(
      jsonEncode(response.body),
      response.status,
      headers: {'content-type': 'application/json'},
      request: request,
    );
  }
}

Map<String, dynamic> passengerRow(
  String studentId,
  String operationStatus, {
  String confirmationStatus = 'confirmed',
}) => {
  'id': 'p-$studentId',
  'student_id': studentId,
  'student_full_name': studentId == 'student-1' ? 'Ana Souza' : 'Beto Lima',
  'confirmation_status': confirmationStatus,
  'operation_status': operationStatus,
  'removed_at': null,
};

/// Outbound stops: origin, two homes, school, garage destination.
List<Map<String, dynamic>> outboundStops({required bool schoolReached}) => [
  {
    'id': 's-origin',
    'kind': 'origin',
    'position': 1,
    'address_snapshot': {'label': 'Garagem'},
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
    'reached_at': null,
  },
  {
    'id': 's-home-2',
    'kind': 'home',
    'student_id': 'student-2',
    'position': 1001,
    'address_snapshot': {
      'street': 'Rua B',
      'street_number': '20',
      'neighborhood': 'Centro',
      'city_name': 'Sorocaba',
    },
    'reached_at': null,
  },
  {
    'id': 's-school',
    'kind': 'school',
    'school_id': 'school-1',
    'position': 100001,
    'address_snapshot': {'name': 'Colégio Central', 'street': 'Rua B'},
    'reached_at': schoolReached ? '2026-10-05T10:00:00+00:00' : null,
  },
  {
    'id': 's-dest',
    'kind': 'destination',
    'position': 200000,
    'address_snapshot': {'label': 'Garagem'},
    'reached_at': null,
  },
];

/// Active outbound projection with per-student operation states.
Map<String, dynamic> outboundProjection(
  List<(String, String)> students, {
  required bool schoolReached,
}) => tripProjection(
  driverUserId: testId,
  status: 'active',
  passengers: [
    for (final (studentId, operationStatus) in students)
      passengerRow(studentId, operationStatus),
  ],
  stops: outboundStops(schoolReached: schoolReached),
);

/// Return-direction stops: the school at position 1000, homes after it.
List<Map<String, dynamic>> returnStops({
  required bool schoolReached,
  required List<({String id, String studentId, int position})> homes,
}) => [
  {
    'id': 's-school',
    'kind': 'school',
    'school_id': 'school-1',
    'position': 1000,
    'address_snapshot': {'name': 'Colégio Central', 'street': 'Rua B'},
    'reached_at': schoolReached ? '2026-10-05T16:05:00+00:00' : null,
  },
  for (final home in homes)
    {
      'id': home.id,
      'kind': 'home',
      'student_id': home.studentId,
      'position': home.position,
      'address_snapshot': {
        'street': 'Rua do Aluno',
        'street_number': '10',
        'neighborhood': 'Centro',
        'city_name': 'Sorocaba',
      },
      'reached_at': null,
    },
];

/// Pumps the route screen against a fake backend that routes by RPC path and
/// plays queued results; returns the harness for assertions.
Future<RouteScreenHarness> pumpRouteScreen(
  WidgetTester tester, {
  Map<String, dynamic>? projection,
  int status = 200,
  RouteScreenHarness? harness,
  DriverLocationService? locationService,
  TripTelemetryUploader? uploader,
}) async {
  tester.view.physicalSize = const Size(1080, 1920);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final h = harness ?? RouteScreenHarness();
  h.whenIfAbsent('get_trip', [
    if (status == 200)
      FakeRpcResponse.ok(projection ?? tripProjection(driverUserId: testId))
    else
      FakeRpcResponse.error(status, 'not_found'),
  ]);

  final client = await tester.runAsync(() => planningClient(h.handle));
  addTearDown(client!.dispose);

  await tester.pumpWidget(
    MaterialApp(
      home: DriverRouteScreen(
        tripId: 'trip-1',
        routeService: DriverRouteService(
          client: client,
          directionsService: StubDirectionsService(),
        ),
        locationService: locationService ?? h.location,
        telemetryUploader: uploader,
      ),
    ),
  );
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
  await tester.pumpAndSettle();
  return h;
}

final _uuidPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

/// Lets in-flight commands finish, then settles frames.
Future<void> settleCommands(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
  await tester.pumpAndSettle();
}

/// Floating snackbars cover the bottom action buttons; tests clear them
/// between two taps on the same screen.
void clearSnackbars(WidgetTester tester) {
  final context = tester.element(find.byType(Scaffold));
  ScaffoldMessenger.of(context).clearSnackBars();
}

void main() {
  setUp(() {
    // The map's tile caching provider resolves a cache directory on rebuild;
    // provide it so start-related rebuilds do not fail the test.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => Directory.systemTemp.path,
        );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
  });

  testWidgets(
    'start persists through start_trip and reloads before the active panel',
    (tester) async {
      final harness = RouteScreenHarness()
        ..when('start_trip', [FakeRpcResponse.ok('active')])
        ..when('get_trip', [
          FakeRpcResponse.ok(tripProjection(driverUserId: testId)),
          FakeRpcResponse.ok(
            tripProjection(driverUserId: testId, status: 'active'),
          ),
        ]);
      await pumpRouteScreen(tester, harness: harness);

      await tester.tap(find.text('Começar Percurso'));
      await settleCommands(tester);

      final startBodies = harness.bodiesOf('start_trip');
      expect(startBodies, hasLength(1));
      expect(startBodies.single['p_trip_id'], 'trip-1');
      expect(
        _uuidPattern.hasMatch(startBodies.single['p_command_id'] as String),
        isTrue,
      );
      expect(find.text('Confirmar Embarque'), findsOneWidget);
      expect(find.text('Viagem iniciada.'), findsOneWidget);
      expect(harness.location.startCalls, 1);
      expect(harness.location.stopCalls, 0);
    },
  );

  testWidgets('a rejected start shows the mapped message and mints a new id', (
    tester,
  ) async {
    final harness = RouteScreenHarness()
      ..when('start_trip', [
        FakeRpcResponse.error(409, 'confirmation_closed'),
        FakeRpcResponse.error(409, 'confirmation_closed'),
      ])
      ..when('get_trip', [
        FakeRpcResponse.ok(tripProjection(driverUserId: testId)),
        FakeRpcResponse.ok(tripProjection(driverUserId: testId)),
        FakeRpcResponse.ok(tripProjection(driverUserId: testId)),
      ]);
    await pumpRouteScreen(tester, harness: harness);

    await tester.tap(find.text('Começar Percurso'));
    await settleCommands(tester);

    expect(
      find.text(
        'Aguarde o encerramento das confirmações para iniciar a viagem.',
      ),
      findsOneWidget,
    );
    expect(find.text('Confirmar Embarque'), findsNothing);
    clearSnackbars(tester);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Começar Percurso'));
    await settleCommands(tester);

    final ids = [
      for (final body in harness.bodiesOf('start_trip')) body['p_command_id'],
    ];
    expect(ids, hasLength(2));
    expect(ids[0], isNot(ids[1]));
  });

  testWidgets('an uncertain start retries with the same command id', (
    tester,
  ) async {
    final harness = RouteScreenHarness()
      ..when('start_trip', [
        FakeRpcResponse.error(500, 'unexpected_rpc'),
        FakeRpcResponse.ok('active'),
      ])
      ..when('get_trip', [
        FakeRpcResponse.ok(tripProjection(driverUserId: testId)),
        FakeRpcResponse.ok(tripProjection(driverUserId: testId)),
        FakeRpcResponse.ok(
          tripProjection(driverUserId: testId, status: 'active'),
        ),
      ]);
    await pumpRouteScreen(tester, harness: harness);

    await tester.tap(find.text('Começar Percurso'));
    await settleCommands(tester);

    expect(
      find.text('Não foi possível confirmar a ação. Tente novamente.'),
      findsOneWidget,
    );
    expect(find.text('Tentar novamente'), findsOneWidget);

    await tester.tap(find.text('Tentar novamente'));
    await settleCommands(tester);

    final ids = [
      for (final body in harness.bodiesOf('start_trip')) body['p_command_id'],
    ];
    expect(ids, hasLength(2));
    expect(ids[0], ids[1]);
    expect(find.text('Confirmar Embarque'), findsOneWidget);
  });

  testWidgets(
    'an uncertain start whose reload shows the trip active is resolved',
    (tester) async {
      final harness = RouteScreenHarness()
        ..when('start_trip', [FakeRpcResponse.error(500, 'unexpected_rpc')])
        ..when('get_trip', [
          FakeRpcResponse.ok(tripProjection(driverUserId: testId)),
          FakeRpcResponse.ok(
            tripProjection(driverUserId: testId, status: 'active'),
          ),
        ]);
      await pumpRouteScreen(tester, harness: harness);

      await tester.tap(find.text('Começar Percurso'));
      await settleCommands(tester);

      expect(find.text('Confirmar Embarque'), findsOneWidget);
      expect(find.text('Viagem iniciada.'), findsOneWidget);
      expect(harness.location.startCalls, 1);
    },
  );

  testWidgets(
    'boarding persists via record_passenger_event and shows Embarcou after reload',
    (tester) async {
      final harness = RouteScreenHarness()
        ..when('record_passenger_event', [FakeRpcResponse.ok('boarded')])
        ..when('get_trip', [
          FakeRpcResponse.ok(
            tripProjection(driverUserId: testId, status: 'active'),
          ),
          FakeRpcResponse.ok(
            tripProjection(
              driverUserId: testId,
              status: 'active',
              passengers: [passengerRow('student-1', 'boarded')],
            ),
          ),
        ]);
      await pumpRouteScreen(tester, harness: harness);

      await tester.tap(find.text('Confirmar Embarque'));
      await settleCommands(tester);

      expect(harness.bodiesOf('record_passenger_event').single, {
        'p_trip_id': 'trip-1',
        'p_student_id': 'student-1',
        'p_kind': 'boarded',
        'p_command_id': isNotEmpty,
      });
      expect(find.textContaining('Embarcou'), findsOneWidget);
      expect(find.text('Confirmar chegada na escola'), findsOneWidget);
    },
  );

  testWidgets('absence persists via record_passenger_event', (tester) async {
    final harness = RouteScreenHarness()
      ..when('record_passenger_event', [FakeRpcResponse.ok('absent')])
      ..when('get_trip', [
        FakeRpcResponse.ok(
          tripProjection(driverUserId: testId, status: 'active'),
        ),
        FakeRpcResponse.ok(
          tripProjection(
            driverUserId: testId,
            status: 'active',
            passengers: [passengerRow('student-1', 'absent')],
          ),
        ),
      ]);
    await pumpRouteScreen(tester, harness: harness);

    await tester.tap(find.text('Ausente'));
    await settleCommands(tester);

    expect(
      harness.bodiesOf('record_passenger_event').single['p_kind'],
      'absent',
    );
    expect(find.textContaining('Ausente'), findsWidgets);
  });

  testWidgets(
    'school arrival marks the stop then drops off every boarded student',
    (tester) async {
      final harness = RouteScreenHarness()
        ..when('mark_trip_stop_reached', [FakeRpcResponse.ok('reached')])
        ..when('record_passenger_event', [
          FakeRpcResponse.ok('dropped_off'),
          FakeRpcResponse.ok('dropped_off'),
        ])
        ..when('get_trip', [
          FakeRpcResponse.ok(
            outboundProjection([
              ('student-1', 'boarded'),
              ('student-2', 'boarded'),
            ], schoolReached: false),
          ),
          // Reload after the school stop was marked reached.
          FakeRpcResponse.ok(
            outboundProjection([
              ('student-1', 'boarded'),
              ('student-2', 'boarded'),
            ], schoolReached: true),
          ),
          // Reload after the first student's drop-off was accepted.
          FakeRpcResponse.ok(
            outboundProjection([
              ('student-1', 'dropped_off'),
              ('student-2', 'boarded'),
            ], schoolReached: true),
          ),
          // Reload after the second student's drop-off was accepted.
          FakeRpcResponse.ok(
            outboundProjection([
              ('student-1', 'dropped_off'),
              ('student-2', 'dropped_off'),
            ], schoolReached: true),
          ),
        ]);
      await pumpRouteScreen(tester, harness: harness);

      await tester.tap(find.text('Confirmar chegada na escola'));
      await settleCommands(tester);

      expect(
        harness.bodiesOf('mark_trip_stop_reached').single['p_stop_id'],
        's-school',
      );
      expect(harness.calls.map((call) => call.rpc).toList(), [
        'get_trip',
        'mark_trip_stop_reached',
        'get_trip',
        'record_passenger_event',
        'get_trip',
        'record_passenger_event',
        'get_trip',
      ]);
      expect(find.text('Finalizar viagem'), findsOneWidget);
    },
  );

  testWidgets(
    'a partial uncertain arrival retries only unresolved sub-commands',
    (tester) async {
      final harness = RouteScreenHarness()
        ..when('mark_trip_stop_reached', [FakeRpcResponse.ok('reached')])
        ..when('record_passenger_event', [
          FakeRpcResponse.ok('dropped_off'),
          FakeRpcResponse.error(500, 'unexpected_rpc'),
          FakeRpcResponse.ok('dropped_off'),
        ])
        ..when('get_trip', [
          FakeRpcResponse.ok(
            outboundProjection([
              ('student-1', 'boarded'),
              ('student-2', 'boarded'),
            ], schoolReached: false),
          ),
          // Reload after the school stop was marked reached.
          FakeRpcResponse.ok(
            outboundProjection([
              ('student-1', 'boarded'),
              ('student-2', 'boarded'),
            ], schoolReached: true),
          ),
          // Reload after the first student's drop-off was accepted.
          FakeRpcResponse.ok(
            outboundProjection([
              ('student-1', 'dropped_off'),
              ('student-2', 'boarded'),
            ], schoolReached: true),
          ),
          // Reload after the second student's drop-off came back uncertain.
          FakeRpcResponse.ok(
            outboundProjection([
              ('student-1', 'dropped_off'),
              ('student-2', 'boarded'),
            ], schoolReached: true),
          ),
          // Reload after the retry re-applied the second drop-off.
          FakeRpcResponse.ok(
            outboundProjection([
              ('student-1', 'dropped_off'),
              ('student-2', 'dropped_off'),
            ], schoolReached: true),
          ),
        ]);
      await pumpRouteScreen(tester, harness: harness);

      await tester.tap(find.text('Confirmar chegada na escola'));
      await settleCommands(tester);

      expect(
        find.text('Não foi possível confirmar a ação. Tente novamente.'),
        findsOneWidget,
      );
      final markCalls = harness.bodiesOf('mark_trip_stop_reached');
      final dropCallsSoFar = harness.bodiesOf('record_passenger_event');
      expect(markCalls, hasLength(1));
      expect(dropCallsSoFar, hasLength(2));

      await tester.tap(find.text('Tentar novamente'));
      await settleCommands(tester);

      final dropCalls = harness.bodiesOf('record_passenger_event');
      expect(harness.bodiesOf('mark_trip_stop_reached'), hasLength(1));
      expect(dropCalls, hasLength(3));
      // The second student's drop-off was retried with its original id.
      expect(dropCalls[1]['p_student_id'], 'student-2');
      expect(dropCalls[2]['p_student_id'], 'student-2');
      expect(dropCalls[1]['p_command_id'], dropCalls[2]['p_command_id']);
      expect(find.text('Finalizar viagem'), findsOneWidget);
    },
  );

  testWidgets(
    'return boarding boards every present student and home stops drop off',
    (tester) async {
      final harness = RouteScreenHarness()
        ..when('mark_trip_stop_reached', [FakeRpcResponse.ok('reached')])
        ..when('record_passenger_event', [
          FakeRpcResponse.ok('boarded'),
          FakeRpcResponse.ok('dropped_off'),
        ])
        ..when('get_trip', [
          FakeRpcResponse.ok(
            tripProjection(
              driverUserId: testId,
              status: 'active',
              passengers: [passengerRow('student-1', 'waiting')],
              stops: returnStops(
                schoolReached: false,
                homes: [
                  (id: 's-home-1', studentId: 'student-1', position: 100001),
                ],
              ),
            ),
          ),
          // Reload after the school stop was marked reached.
          FakeRpcResponse.ok(
            tripProjection(
              driverUserId: testId,
              status: 'active',
              passengers: [passengerRow('student-1', 'waiting')],
              stops: returnStops(
                schoolReached: true,
                homes: [
                  (id: 's-home-1', studentId: 'student-1', position: 100001),
                ],
              ),
            ),
          ),
          // Reload after the boarding was accepted.
          FakeRpcResponse.ok(
            tripProjection(
              driverUserId: testId,
              status: 'active',
              passengers: [passengerRow('student-1', 'boarded')],
              stops: returnStops(
                schoolReached: true,
                homes: [
                  (id: 's-home-1', studentId: 'student-1', position: 100001),
                ],
              ),
            ),
          ),
          // Reload after the drop-off was accepted.
          FakeRpcResponse.ok(
            tripProjection(
              driverUserId: testId,
              status: 'active',
              passengers: [passengerRow('student-1', 'dropped_off')],
              stops: returnStops(
                schoolReached: true,
                homes: [
                  (id: 's-home-1', studentId: 'student-1', position: 100001),
                ],
              ),
            ),
          ),
        ]);
      await pumpRouteScreen(tester, harness: harness);

      // While the school is not reached, the stop list offers per-student absence.
      expect(find.text('Ausente'), findsOneWidget);
      await tester.tap(find.text('Embarcar presentes'));
      await settleCommands(tester);

      expect(harness.calls[1].rpc, 'mark_trip_stop_reached');
      final boardedCalls = harness.bodiesOf('record_passenger_event');
      expect(boardedCalls.single['p_kind'], 'boarded');
      expect(find.text('Desembarcou'), findsOneWidget);

      clearSnackbars(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Desembarcou'));
      await settleCommands(tester);

      final dropCalls = harness.bodiesOf('record_passenger_event');
      expect(dropCalls, hasLength(2));
      expect(dropCalls.last['p_kind'], 'dropped_off');
      expect(find.text('Finalizar viagem'), findsOneWidget);
    },
  );

  testWidgets('a blocked finish shows the mapped message and keeps tracking', (
    tester,
  ) async {
    final harness = RouteScreenHarness()
      ..when('finish_trip', [FakeRpcResponse.error(409, 'passengers_on_board')])
      ..when('get_trip', [
        FakeRpcResponse.ok(
          tripProjection(
            driverUserId: testId,
            status: 'active',
            passengers: [passengerRow('student-1', 'dropped_off')],
          ),
        ),
        FakeRpcResponse.ok(
          tripProjection(
            driverUserId: testId,
            status: 'active',
            passengers: [passengerRow('student-1', 'dropped_off')],
          ),
        ),
      ]);
    await pumpRouteScreen(tester, harness: harness);

    await tester.tap(find.text('Finalizar viagem'));
    await settleCommands(tester);

    expect(
      find.text('Há alunos sem desembarque ou ausência registrados.'),
      findsOneWidget,
    );
    expect(find.text('Finalizar viagem'), findsOneWidget);
    expect(harness.location.stopCalls, 0);
  });

  testWidgets(
    'a successful finish reloads the completed trip and stops tracking',
    (tester) async {
      final harness = RouteScreenHarness()
        ..when('finish_trip', [FakeRpcResponse.ok('completed')])
        ..when('get_trip', [
          FakeRpcResponse.ok(
            tripProjection(
              driverUserId: testId,
              status: 'active',
              passengers: [passengerRow('student-1', 'dropped_off')],
            ),
          ),
          FakeRpcResponse.ok(
            tripProjection(
              driverUserId: testId,
              status: 'completed',
              passengers: [passengerRow('student-1', 'dropped_off')],
            ),
          ),
        ]);
      await pumpRouteScreen(tester, harness: harness);

      await tester.tap(find.text('Finalizar viagem'));
      await settleCommands(tester);

      expect(find.text('Viagem finalizada.'), findsOneWidget);
      expect(find.text('Viagem Concluída'), findsOneWidget);
      expect(harness.location.stopCalls, 1);
      // Reopening the active trip resumed tracking once (task 22).
      expect(harness.location.startCalls, 1);
    },
  );

  testWidgets('action buttons ignore taps while a command is in flight', (
    tester,
  ) async {
    final harness = RouteScreenHarness();
    final pending = PendingRpc();
    harness
      ..when('start_trip', [pending])
      ..when('get_trip', [
        FakeRpcResponse.ok(tripProjection(driverUserId: testId)),
        FakeRpcResponse.ok(
          tripProjection(driverUserId: testId, status: 'active'),
        ),
      ]);
    await pumpRouteScreen(tester, harness: harness);

    await tester.tap(find.text('Começar Percurso'));
    await tester.pumpAndSettle();
    // The command is still in flight; the button must not submit again.
    await tester.tap(find.text('Começar Percurso'), warnIfMissed: false);
    expect(harness.bodiesOf('start_trip'), hasLength(1));

    pending.respond(FakeRpcResponse.ok('active'));
    await settleCommands(tester);

    expect(harness.bodiesOf('start_trip'), hasLength(1));
    expect(find.text('Confirmar Embarque'), findsOneWidget);
  });

  testWidgets('a fresh pump shows persisted passenger events after a restart', (
    tester,
  ) async {
    final harness = RouteScreenHarness();
    await pumpRouteScreen(
      tester,
      projection: tripProjection(
        driverUserId: testId,
        status: 'active',
        passengers: [passengerRow('student-1', 'boarded')],
      ),
      harness: harness,
    );

    expect(harness.bodiesOf('start_trip'), isEmpty);
    expect(harness.bodiesOf('record_passenger_event'), isEmpty);
    expect(find.textContaining('Embarcou'), findsOneWidget);
    expect(find.text('Confirmar chegada na escola'), findsOneWidget);
  });

  testWidgets('access loss shows the access message', (tester) async {
    final harness = RouteScreenHarness()
      ..when('start_trip', [FakeRpcResponse.error(404, 'not_found')])
      ..when('get_trip', [
        FakeRpcResponse.ok(tripProjection(driverUserId: testId)),
        FakeRpcResponse.ok(tripProjection(driverUserId: testId)),
      ]);
    await pumpRouteScreen(tester, harness: harness);

    await tester.tap(find.text('Começar Percurso'));
    await settleCommands(tester);

    expect(find.text('Você não tem acesso a esta viagem.'), findsOneWidget);
    expect(find.text('Começar Percurso'), findsOneWidget);
  });

  testWidgets('trips of another driver are read-only', (tester) async {
    await pumpRouteScreen(
      tester,
      projection: tripProjection(driverUserId: 'someone-else'),
    );

    expect(find.text('Começar Percurso'), findsNothing);
    expect(
      find.text('Somente o motorista designado pode operar esta viagem.'),
      findsOneWidget,
    );
  });

  testWidgets('cancelled trips show their state without actions', (
    tester,
  ) async {
    await pumpRouteScreen(
      tester,
      projection: tripProjection(driverUserId: testId, status: 'cancelled'),
    );

    expect(find.text('Viagem Cancelada'), findsOneWidget);
    expect(find.text('Começar Percurso'), findsNothing);
  });

  testWidgets('backend failure renders a safe error with retry', (
    tester,
  ) async {
    await pumpRouteScreen(tester, status: 404);

    expect(find.text('Não foi possível carregar esta viagem.'), findsOneWidget);
    expect(find.textContaining('Trip not found'), findsNothing);
    expect(find.text('Tentar novamente'), findsOneWidget);
  });

  group('GPS telemetry', () {
    final startedAt = DateTime.now().toUtc().subtract(
      const Duration(minutes: 1),
    );
    Map<String, dynamic> activeTrip({
      String status = 'active',
      String operation = 'waiting',
    }) => tripProjection(
      driverUserId: testId,
      status: status,
      passengers: [passengerRow('student-1', operation)],
      startedAt: startedAt.toIso8601String(),
      assignments: [
        {'id': 'asg-1', 'driver_user_id': testId, 'valid_until': null},
      ],
    );

    testWidgets('simulation toggle is hidden in regular builds', (
      tester,
    ) async {
      await pumpRouteScreen(tester);

      expect(find.text('Alternar'), findsNothing);
      expect(find.text('Modo: GPS Real'), findsOneWidget);
    });

    testWidgets('demo builds can switch to the labeled simulation', (
      tester,
    ) async {
      await pumpRouteScreen(
        tester,
        locationService: DriverLocationService(
          geolocator: FakeGeolocator(),
          allowSimulation: true,
        ),
      );

      await tester.tap(find.text('Alternar'));
      await tester.pumpAndSettle();
      expect(find.text('Modo: Simulação (demo)'), findsOneWidget);
    });

    testWidgets('denied permission shows the banner and never GPS Ativo', (
      tester,
    ) async {
      await pumpRouteScreen(
        tester,
        projection: activeTrip(),
        locationService: DriverLocationService(
          geolocator: FakeGeolocator(permission: LocationPermission.denied),
        ),
      );

      expect(find.text('GPS inativo: permissão negada'), findsOneWidget);
      expect(find.text('Ativar GPS'), findsOneWidget);
      expect(find.textContaining('GPS Ativo'), findsNothing);
      // Operation is not blocked by a missing GPS.
      expect(find.text('Confirmar Embarque'), findsOneWidget);
    });

    testWidgets('opening an active trip streams real fixes to the backend', (
      tester,
    ) async {
      final geo = FakeGeolocator();
      final sent = <Map<String, dynamic>>[];
      final uploader = TripTelemetryUploader(send: (p) async => sent.add(p));
      await pumpRouteScreen(
        tester,
        projection: activeTrip(),
        locationService: DriverLocationService(geolocator: geo),
        uploader: uploader,
      );

      expect(find.textContaining('GPS Ativo'), findsNothing);
      geo.positions.add(position(DateTime.now().toUtc()));
      await tester.pump();
      await tester.runAsync(uploader.flush);
      await tester.pump();

      expect(find.textContaining('GPS Ativo'), findsOneWidget);
      expect(sent.single['p_trip_id'], 'trip-1');
      expect(sent.single['p_assignment_id'], 'asg-1');
      expect(sent.single['p_live'], isTrue);
      expect(sent.single['p_points'], hasLength(1));
    });

    testWidgets('finishing the trip stops GPS and uploads', (tester) async {
      final geo = FakeGeolocator();
      final uploader = TripTelemetryUploader(send: (_) async {});
      final harness = RouteScreenHarness()
        ..when('finish_trip', [FakeRpcResponse.ok('completed')])
        ..when('get_trip', [
          FakeRpcResponse.ok(activeTrip(operation: 'dropped_off')),
          FakeRpcResponse.ok(
            activeTrip(status: 'completed', operation: 'dropped_off'),
          ),
        ]);
      await pumpRouteScreen(
        tester,
        harness: harness,
        locationService: DriverLocationService(geolocator: geo),
        uploader: uploader,
      );
      expect(geo.positions.hasListener, isTrue);
      expect(uploader.isActive, isTrue);

      await tester.tap(find.text('Finalizar viagem'));
      await settleCommands(tester);

      expect(find.text('Viagem Concluída'), findsOneWidget);
      expect(geo.positions.hasListener, isFalse);
      expect(uploader.isActive, isFalse);
      expect(uploader.state.value, TelemetrySyncState.idle);
    });

    testWidgets('completed trips never start GPS', (tester) async {
      final geo = FakeGeolocator();
      await pumpRouteScreen(
        tester,
        projection: activeTrip(status: 'completed'),
        locationService: DriverLocationService(geolocator: geo),
      );

      expect(geo.positions.hasListener, isFalse);
      expect(find.textContaining('GPS inativo'), findsNothing);
    });
  });
}
