import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:vango_app/core/routes/app_routes.dart';
import 'package:vango_app/features/auth/models/access_context.dart';
import 'package:vango_app/features/fleet/screens/fleet_owner_dashboard_screen.dart';
import 'package:vango_app/features/fleet/services/fleet_service.dart';

import '../../../support/fake_auth_service.dart';

void main() {
  testWidgets('dashboard waits for current owner access before reading', (
    tester,
  ) async {
    final auth = FakeAuthService.signedIn(userId: 'user-1');
    final pendingAccess = Completer<AccessContext>();
    final fleet = _RecordingFleetService();
    auth.accessCompleter = pendingAccess;
    addTearDown(auth.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: FleetOwnerDashboardScreen(
          fleetId: 'fleet-a',
          userId: 'user-1',
          authService: auth,
          fleetService: fleet,
        ),
      ),
    );
    expect(fleet.readFleetIds, isEmpty);
    pendingAccess.complete(_context('fleet-a'));
    await tester.pumpAndSettle();
    expect(fleet.readFleetIds, ['fleet-a', 'fleet-a', 'fleet-a']);
    expect(find.text('Gestão da Frota'), findsOneWidget);
  });

  testWidgets('dashboard denies a fleet without owner membership', (
    tester,
  ) async {
    final auth = FakeAuthService.signedIn(
      userId: 'user-1',
      accessContext: _context('fleet-b'),
    );
    final fleet = _RecordingFleetService();
    addTearDown(auth.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: FleetOwnerDashboardScreen(
          fleetId: 'fleet-a',
          userId: 'user-1',
          authService: auth,
          fleetService: fleet,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Acesso à frota indisponível'), findsOneWidget);
    expect(fleet.readFleetIds, isEmpty);
  });

  testWidgets(
    'missing and malformed route arguments never open the dashboard',
    (tester) async {
      final auth = FakeAuthService.signedIn(
        userId: 'user-1',
        accessContext: _context('fleet-a'),
      );
      addTearDown(auth.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: const Scaffold(),
          routes: AppRoutes.routes(authService: auth),
        ),
      );
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      for (final arguments in <Object?>[
        null,
        (fleetId: '', userId: 'user-1'),
        'fleet-a',
      ]) {
        navigator.pushNamed(AppRoutes.fleetDashboard, arguments: arguments);
        await tester.pumpAndSettle();
        expect(find.text('Acesso à frota indisponível'), findsOneWidget);
        expect(find.byType(FleetOwnerDashboardScreen), findsNothing);
        navigator.pop();
        await tester.pumpAndSettle();
      }
    },
  );

  testWidgets('sign out hides an open dashboard and discards a late read', (
    tester,
  ) async {
    final auth = FakeAuthService.signedIn(
      userId: 'user-1',
      accessContext: _context('fleet-a'),
    );
    final fleet = _RecordingFleetService();
    final pendingRead = Completer<List<PendingJoinRequest>>();
    fleet.pendingRequests = pendingRead;
    addTearDown(auth.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: FleetOwnerDashboardScreen(
          fleetId: 'fleet-a',
          userId: 'user-1',
          authService: auth,
          fleetService: fleet,
        ),
      ),
    );
    await tester.pump();
    auth.emit(AuthChangeEvent.signedOut);
    await tester.pump();
    expect(find.text('Acesso à frota indisponível'), findsOneWidget);
    pendingRead.complete(const []);
    await tester.pump();
    expect(find.text('Acesso à frota indisponível'), findsOneWidget);
    expect(fleet.readFleetIds, ['fleet-a']);
  });

  testWidgets('account switch denies the open dashboard', (tester) async {
    final auth = FakeAuthService.signedIn(
      userId: 'user-1',
      accessContext: _context('fleet-a'),
    );
    final other = FakeAuthService.signedIn(userId: 'user-2');
    final fleet = _RecordingFleetService();
    addTearDown(auth.dispose);
    addTearDown(other.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: FleetOwnerDashboardScreen(
          fleetId: 'fleet-a',
          userId: 'user-1',
          authService: auth,
          fleetService: fleet,
        ),
      ),
    );
    await tester.pumpAndSettle();
    auth.emit(AuthChangeEvent.signedIn, nextSession: other.session);
    await tester.pumpAndSettle();
    expect(find.text('Acesso à frota indisponível'), findsOneWidget);
  });

  testWidgets('owner access refresh removes dashboard data after role loss', (
    tester,
  ) async {
    final auth = FakeAuthService.signedIn(
      userId: 'user-1',
      accessContext: _context('fleet-a'),
    );
    final fleet = _RecordingFleetService();
    addTearDown(auth.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: FleetOwnerDashboardScreen(
          fleetId: 'fleet-a',
          userId: 'user-1',
          authService: auth,
          fleetService: fleet,
        ),
      ),
    );
    await tester.pumpAndSettle();
    auth.accessContext = _context('fleet-b');
    auth.emit(AuthChangeEvent.tokenRefreshed, nextSession: auth.session);
    await tester.pumpAndSettle();
    expect(find.text('Acesso à frota indisponível'), findsOneWidget);
    expect(fleet.readFleetIds, ['fleet-a', 'fleet-a', 'fleet-a']);
  });

  testWidgets('empty owner data shows empty states without sample records', (
    tester,
  ) async {
    final auth = FakeAuthService.signedIn(
      userId: 'user-1',
      accessContext: _context('fleet-a'),
    );
    addTearDown(auth.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: FleetOwnerDashboardScreen(
          fleetId: 'fleet-a',
          userId: 'user-1',
          authService: auth,
          fleetService: _RecordingFleetService(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('Nenhuma solicitação pendente no momento.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Equipe'));
    await tester.pumpAndSettle();
    expect(find.text('Van 01 - Zona Sul'), findsNothing);
    expect(find.text('Carlos Seed Driver'), findsNothing);
  });

  testWidgets('read failure shows retry rather than an empty state', (
    tester,
  ) async {
    final auth = FakeAuthService.signedIn(
      userId: 'user-1',
      accessContext: _context('fleet-a'),
    );
    final fleet = _RecordingFleetService()..readError = StateError('network');
    addTearDown(auth.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: FleetOwnerDashboardScreen(
          fleetId: 'fleet-a',
          userId: 'user-1',
          authService: auth,
          fleetService: fleet,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Não foi possível carregar a frota'), findsOneWidget);
    expect(find.text('Nenhuma solicitação pendente no momento.'), findsNothing);
    fleet.readError = null;
    await tester.tap(find.text('Tentar novamente'));
    await tester.pumpAndSettle();
    expect(
      find.text('Nenhuma solicitação pendente no momento.'),
      findsOneWidget,
    );
  });

  testWidgets('failed decision shows error without success feedback', (
    tester,
  ) async {
    final auth = FakeAuthService.signedIn(
      userId: 'user-1',
      accessContext: _context('fleet-a'),
    );
    final fleet = _RecordingFleetService()
      ..requests = const [
        PendingJoinRequest(
          id: 'request-a',
          studentFullName: 'Aluno Teste',
          schoolName: 'Escola',
          shift: 'Manhã',
          street: 'Rua',
          streetNumber: '1',
          neighborhood: 'Centro',
          cityName: 'Cidade',
          createdAt: 'Hoje',
        ),
      ]
      ..decisionError = StateError('network');
    addTearDown(auth.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: FleetOwnerDashboardScreen(
          fleetId: 'fleet-a',
          userId: 'user-1',
          authService: auth,
          fleetService: fleet,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Aprovar Entrada'));
    await tester.pumpAndSettle();
    expect(
      find.text('Não foi possível atualizar a solicitação'),
      findsOneWidget,
    );
    expect(find.text('Aluno aprovado e adicionado à frota!'), findsNothing);
  });
}

AccessContext _context(String fleetId) => AccessContext(
  onboardingIntent: null,
  accountRoles: const {AccountRole.owner},
  dependentStudentIds: const [],
  adultStudentId: null,
  fleetAccess: [
    FleetAccess(fleetId: fleetId, roles: const {AccountRole.owner}),
  ],
);

class _RecordingFleetService extends FleetService {
  final List<String> readFleetIds = [];
  Completer<List<PendingJoinRequest>>? pendingRequests;
  List<PendingJoinRequest> requests = const [];
  Object? readError;
  Object? decisionError;

  @override
  Future<List<PendingJoinRequest>> getPendingRequests(String fleetId) {
    readFleetIds.add(fleetId);
    if (readError case final error?) return Future.error(error);
    return pendingRequests?.future ?? Future.value(requests);
  }

  @override
  Future<void> decideRequest(String requestId, bool approve) async {
    if (decisionError case final error?) throw error;
  }

  @override
  Future<List<FleetMemberDriver>> getFleetDrivers(String fleetId) async {
    readFleetIds.add(fleetId);
    return const [];
  }

  @override
  Future<List<OwnerEnrolledStudent>> getOwnerEnrolledStudents(
    String fleetId,
  ) async {
    readFleetIds.add(fleetId);
    return const [];
  }
}
