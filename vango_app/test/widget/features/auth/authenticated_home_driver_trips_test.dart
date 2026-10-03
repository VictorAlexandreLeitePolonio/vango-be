import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:vango_app/core/routes/app_routes.dart';
import 'package:vango_app/features/auth/models/access_context.dart';
import 'package:vango_app/features/auth/screens/authenticated_home_screen.dart';
import 'package:vango_app/features/driver/services/driver_route_service.dart';

import '../../../support/fake_auth_service.dart';
import '../../../unit/features/driver/driver_trip_test.dart'
    show tripProjection;
import '../../../unit/features/fleet/fleet_planning_service_test.dart'
    show planningClient, testId;

/// Fake `list_service_day` backend: [tripsByFleet] per fleet, or a failure.
typedef ServiceDayHandler =
    http.Response Function(String fleetId, http.Request request);

http.Response serviceDay(
  http.Request request,
  List<Map<String, dynamic>> trips,
) => http.Response(
  jsonEncode({'fleet_id': 'x', 'service_date': '2026-10-05', 'trips': trips}),
  200,
  headers: {'content-type': 'application/json'},
  request: request,
);

Future<List<String>> pumpDriverHome(
  WidgetTester tester,
  ServiceDayHandler handler, {
  List<FleetAccess> fleetAccess = const [
    FleetAccess(fleetId: 'fleet-a', roles: {AccountRole.driver}),
  ],
}) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final requestedFleets = <String>[];
  final client = await tester.runAsync(
    () => planningClient((request) async {
      final fleetId =
          (jsonDecode(request.body) as Map<String, dynamic>)['p_fleet_id']
              as String;
      requestedFleets.add(fleetId);
      return handler(fleetId, request);
    }),
  );
  addTearDown(client!.dispose);
  final auth = FakeAuthService.signedIn(userId: testId);
  addTearDown(auth.dispose);

  await tester.pumpWidget(
    MaterialApp(
      home: AuthenticatedHomeScreen(
        authService: auth,
        accessContext: AccessContext(
          onboardingIntent: null,
          accountRoles: const {AccountRole.driver},
          dependentStudentIds: const [],
          adultStudentId: null,
          fleetAccess: fleetAccess,
        ),
        driverRouteService: DriverRouteService(client: client),
      ),
      routes: {
        AppRoutes.driverRoute: (context) =>
            Text('route:${ModalRoute.of(context)!.settings.arguments}'),
      },
    ),
  );
  await settle(tester);
  return requestedFleets;
}

Future<void> settle(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('empty service day renders a real empty state', (tester) async {
    await pumpDriverHome(tester, (_, request) => serviceDay(request, const []));

    expect(find.text('Nenhuma viagem para hoje'), findsOneWidget);
  });

  testWidgets('lists trips of every operational fleet', (tester) async {
    final fleets = await pumpDriverHome(
      tester,
      (fleetId, request) => serviceDay(request, [
        fleetId == 'fleet-a'
            ? tripProjection(id: 'own', driverUserId: testId)
            : tripProjection(
                id: 'other',
                driverUserId: 'another-driver',
                plannedStartAt: '2026-10-05T15:00:00+00:00',
              ),
      ]),
      fleetAccess: const [
        FleetAccess(fleetId: 'fleet-b', roles: {AccountRole.owner}),
        FleetAccess(fleetId: 'fleet-a', roles: {AccountRole.driver}),
        FleetAccess(fleetId: 'fleet-g', roles: {AccountRole.guardian}),
      ],
    );

    expect(fleets, ['fleet-a', 'fleet-b']);
    // Own trip is operable; the other driver's trip is read-only.
    expect(find.text('Iniciar viagem'), findsOneWidget);
    expect(find.text('Ver viagem'), findsOneWidget);
  });

  testWidgets('opening a trip navigates with its persisted id', (tester) async {
    await pumpDriverHome(
      tester,
      (_, request) => serviceDay(request, [
        tripProjection(id: 'trip-9', driverUserId: testId),
      ]),
    );

    await tester.tap(find.text('Iniciar viagem'));
    await tester.pumpAndSettle();

    expect(find.text('route:trip-9'), findsOneWidget);
  });

  testWidgets('backend failure renders error and retry reloads', (
    tester,
  ) async {
    var fail = true;
    await pumpDriverHome(
      tester,
      (_, request) => fail
          ? http.Response(
              jsonEncode({'code': 'forbidden', 'message': 'Forbidden'}),
              403,
              headers: {'content-type': 'application/json'},
              request: request,
            )
          : serviceDay(request, const []),
    );

    expect(
      find.text('Não foi possível carregar suas viagens.'),
      findsOneWidget,
    );

    fail = false;
    await tester.tap(find.text('Tentar novamente'));
    await settle(tester);

    expect(find.text('Nenhuma viagem para hoje'), findsOneWidget);
  });
}
