import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:vango_app/core/routes/app_routes.dart';
import 'package:vango_app/features/auth/models/access_context.dart';
import 'package:vango_app/features/fleet/screens/fleet_owner_dashboard_screen.dart';
import 'package:vango_app/features/fleet/services/fleet_service.dart';
import 'package:vango_app/features/fleet/screens/fleet_student_registration_screen.dart';
import 'package:vango_app/features/fleet/services/fleet_student_error_mapper.dart';
import '../../../unit/features/fleet/fleet_student_registration_test.dart'
    as fixtures;

import '../../../support/fake_auth_service.dart';

void main() {
  testWidgets('student tab loads while marketplace read remains pending', (
    tester,
  ) async {
    final auth = FakeAuthService.signedIn(
      userId: 'user-1',
      accessContext: _context('fleet-a'),
    );
    final fleet = _RecordingFleetService()
      ..pendingRequests = Completer<List<PendingJoinRequest>>();
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
    await tester.tap(find.text('Alunos (0)'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      find.text('Nenhum aluno matriculado na frota ainda.'),
      findsOneWidget,
    );
    fleet.pendingRequests!.complete([]);
    await tester.pumpAndSettle();
  });
  testWidgets(
    'authorized empty student tab opens registration with exact fleet dependencies',
    (tester) async {
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
      await tester.tap(find.text('Alunos (0)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cadastrar aluno'));
      await tester.pumpAndSettle();
      final screen = tester.widget<FleetStudentRegistrationScreen>(
        find.byType(FleetStudentRegistrationScreen),
      );
      expect(screen.fleetId, 'fleet-a');
      expect(screen.userId, 'user-1');
      expect(screen.fleetService, same(fleet));
      expect(screen.submissionState, isNotNull);
    },
  );
  testWidgets(
    'committed registration refreshes only authoritative students and retries read failure',
    (tester) async {
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
      await tester.tap(find.text('Alunos (0)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cadastrar aluno'));
      await tester.pumpAndSettle();
      final screen = tester.widget<FleetStudentRegistrationScreen>(
        find.byType(FleetStudentRegistrationScreen),
      );
      screen.submissionState!.begin('command', fixtures.registration());
      screen.submissionState!.commit((
        studentId: 'student',
        enrollmentId: 'enrollment',
      ));
      fleet.studentError = StateError('network');
      fleet.readError = StateError('marketplace');
      Navigator.of(
        tester.element(find.byType(FleetStudentRegistrationScreen)),
      ).pop(true);
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Aluno cadastrado. Não foi possível atualizar a lista. Tente novamente.',
        ),
        findsOneWidget,
      );
      final otherReads = fleet.readFleetIds.length - fleet.studentReads;
      fleet.studentError = null;
      fleet.students = [
        (
          id: 'server-student',
          fullName: 'Nome canônico do servidor',
          address: 'Rua canônica',
        ),
      ];
      await tester.tap(find.text('Tentar novamente'));
      await tester.pumpAndSettle();
      expect(find.text('Nome canônico do servidor'), findsOneWidget);
      expect(find.text('Ana Silva'), findsNothing);
      expect(fleet.readFleetIds.length - fleet.studentReads, otherReads);
      expect(find.text('Cadastrar aluno'), findsOneWidget);
    },
  );
  testWidgets(
    'back from unknown outcome preserves the same command on reopen',
    (tester) async {
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
      await tester.tap(find.text('Alunos (0)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cadastrar aluno'));
      await tester.pumpAndSettle();
      final state = tester
          .widget<FleetStudentRegistrationScreen>(
            find.byType(FleetStudentRegistrationScreen),
          )
          .submissionState!;
      state.begin('original', fixtures.registration());
      state.fail(FleetStudentWriteFailureKind.unknownOutcome);
      Navigator.of(
        tester.element(find.byType(FleetStudentRegistrationScreen)),
      ).pop();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Retomar confirmação do cadastro'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FleetStudentRegistrationScreen>(
              find.byType(FleetStudentRegistrationScreen),
            )
            .submissionState,
        same(state),
      );
      expect(state.command!.id, 'original');
      expect(fleet.studentReads, 1);
    },
  );
  testWidgets(
    'backend access revocation hides previously authorized student data',
    (tester) async {
      final auth = FakeAuthService.signedIn(
        userId: 'user-1',
        accessContext: _context('fleet-a'),
      );
      final fleet = _RecordingFleetService()
        ..studentError = const PostgrestException(
          message: 'private',
          code: 'forbidden',
        );
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
    },
  );
  testWidgets(
    'older retry response cannot overwrite a newer canonical student list',
    (tester) async {
      final auth = FakeAuthService.signedIn(
        userId: 'user-1',
        accessContext: _context('fleet-a'),
      );
      final fleet = _RecordingFleetService()
        ..studentError = StateError('network');
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
      await tester.tap(find.text('Alunos (0)'));
      await tester.pumpAndSettle();
      final older = Completer<List<OwnerEnrolledStudent>>(),
          newer = Completer<List<OwnerEnrolledStudent>>();
      fleet.studentError = null;
      fleet.queuedStudentReads.addAll([older, newer]);
      await tester.tap(find.text('Tentar novamente'));
      await tester.tap(find.text('Tentar novamente'));
      await tester.pump();
      newer.complete([
        (
          id: 'new',
          fullName: 'Latest canonical student',
          address: 'Current address',
        ),
      ]);
      await tester.pumpAndSettle();
      older.complete([
        (id: 'old', fullName: 'Stale student', address: 'Old address'),
      ]);
      await tester.pumpAndSettle();
      expect(find.text('Latest canonical student'), findsOneWidget);
      expect(find.text('Stale student'), findsNothing);
    },
  );
  testWidgets(
    'changing fleet clears committed refresh feedback from the prior fleet',
    (tester) async {
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
      await tester.tap(find.text('Alunos (0)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cadastrar aluno'));
      await tester.pumpAndSettle();
      final state = tester
          .widget<FleetStudentRegistrationScreen>(
            find.byType(FleetStudentRegistrationScreen),
          )
          .submissionState!;
      state.begin('one', fixtures.registration());
      state.commit((studentId: 'student', enrollmentId: 'enrollment'));
      fleet.studentError = StateError('network');
      Navigator.of(
        tester.element(find.byType(FleetStudentRegistrationScreen)),
      ).pop(true);
      await tester.pumpAndSettle();
      auth.accessContext = _context('fleet-b');
      await tester.pumpWidget(
        MaterialApp(
          home: FleetOwnerDashboardScreen(
            fleetId: 'fleet-b',
            userId: 'user-1',
            authService: auth,
            fleetService: fleet,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Aluno cadastrado. Não foi possível atualizar a lista. Tente novamente.',
        ),
        findsNothing,
      );
      expect(find.text('Não foi possível carregar a frota'), findsOneWidget);
    },
  );
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
    expect(fleet.readFleetIds, ['fleet-a', 'fleet-a', 'fleet-a']);
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
  final queuedStudentReads = <Completer<List<OwnerEnrolledStudent>>>[];
  int studentReads = 0;
  Object? studentError;
  List<OwnerEnrolledStudent> students = [];
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
    studentReads++;
    if (studentError case final error?) throw error;
    return queuedStudentReads.isNotEmpty
        ? queuedStudentReads.removeAt(0).future
        : students;
  }
}
