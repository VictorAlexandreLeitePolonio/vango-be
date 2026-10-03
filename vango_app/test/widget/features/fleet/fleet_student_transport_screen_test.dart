import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:vango_app/features/auth/models/access_context.dart';
import 'package:vango_app/features/fleet/models/fleet_planning.dart';
import 'package:vango_app/features/fleet/models/fleet_student_transport.dart';
import 'package:vango_app/features/fleet/screens/fleet_student_transport_screen.dart';
import 'package:vango_app/features/fleet/services/fleet_planning_service.dart';
import 'package:vango_app/features/fleet/services/fleet_service.dart';
import '../../../support/fake_auth_service.dart';
import '../../../unit/features/fleet/fleet_planning_test.dart';
import '../../../unit/features/fleet/fleet_student_transport_test.dart'
    show
        reservationRow,
        enrollmentId,
        schoolId,
        goingSchedule,
        returnSchedule,
        goingRoute;

const OwnerEnrolledStudent transportStudent = (
  id: 'student-a',
  enrollmentId: enrollmentId,
  fullName: 'Ana Silva',
  address: 'Rua, 1 - Centro, Cidade',
  schoolId: schoolId,
  schoolName: 'Escola Ciclo 3',
  shift: 'morning',
);

DateTime monday() => DateTime(2026, 10, 5);

/// Records direct-allocation writes and serves a mutable planning projection.
class FakeTransportPlanningService extends FleetPlanningService {
  FakeTransportPlanningService()
    : super(
        client: SupabaseClient(
          'https://example.test',
          'test',
          authOptions: const AuthClientOptions(autoRefreshToken: false),
        ),
      );
  Map<String, dynamic> planningJson = planningFixture();
  Object? loadError;
  int loads = 0;
  final writes = <({StudentTransportDraft draft, String commandId})>[];

  /// Each entry is consumed by one write: `null` succeeds, anything else is thrown.
  final writeResults = <Object?>[];

  @override
  String? get currentUserId => 'user';

  @override
  Future<FleetPlanning> load(String fleetId) async {
    loads++;
    if (loadError case final error?) throw error;
    return FleetPlanning.fromJson(planningJson);
  }

  @override
  Future<int> assignStudentTransport(
    StudentTransportDraft draft,
    String commandId,
  ) async {
    writes.add((draft: draft, commandId: commandId));
    final result = writeResults.isEmpty ? null : writeResults.removeAt(0);
    if (result != null) throw result;
    return draft.expectedRoutingRevision + 1;
  }
}

AccessContext ownerOf(List<String> fleets) => AccessContext(
  onboardingIntent: null,
  accountRoles: const {AccountRole.owner},
  dependentStudentIds: const [],
  adultStudentId: null,
  fleetAccess: [
    for (final fleet in fleets)
      FleetAccess(fleetId: fleet, roles: const {AccountRole.owner}),
  ],
);

Future<void> pumpTransport(
  WidgetTester tester,
  FakeTransportPlanningService service, {
  OwnerEnrolledStudent student = transportStudent,
  List<String> ownedFleets = const ['fleet'],
  DateTime Function() clock = monday,
}) async {
  final auth = FakeAuthService.signedIn(
    userId: 'user',
    accessContext: ownerOf(ownedFleets),
  );
  addTearDown(auth.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: FleetStudentTransportScreen(
        fleetId: 'fleet',
        userId: 'user',
        student: student,
        authService: auth,
        service: service,
        clock: clock,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder slot(int weekday, String direction) =>
    find.byKey(ValueKey('transport-slot-$weekday-$direction'));

Future<void> choose(
  WidgetTester tester,
  int weekday,
  String direction,
  String label,
) async {
  await tester.ensureVisible(slot(weekday, direction));
  await tester.tap(slot(weekday, direction));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

Future<void> save(WidgetTester tester) async {
  await tester.ensureVisible(find.text('Salvar programação'));
  await tester.tap(find.text('Salvar programação'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'renders only slots with compatible schedules for school and shift',
    (tester) async {
      await pumpTransport(tester, FakeTransportPlanningService());
      expect(find.text('Programar transporte'), findsOneWidget);
      expect(find.text('Escola: Escola Ciclo 3'), findsOneWidget);
      expect(find.text('Turno: Manhã'), findsOneWidget);
      expect(find.text('06/10/2026'), findsOneWidget); // tomorrow suggested
      for (var weekday = 1; weekday <= 5; weekday++) {
        expect(slot(weekday, 'going'), findsOneWidget);
        expect(slot(weekday, 'return'), findsOneWidget);
      }
      expect(slot(6, 'going'), findsNothing);
      expect(slot(7, 'return'), findsNothing);

      await tester.tap(slot(1, 'going'));
      await tester.pumpAndSettle();
      expect(find.text('Ciclo 3 ida · 08:00'), findsWidgets);
      expect(find.text('Ciclo 3 volta · 16:00'), findsNothing);
    },
  );

  testWidgets('shows an empty state when no route serves the student shift', (
    tester,
  ) async {
    const OwnerEnrolledStudent student = (
      id: 'student-a',
      enrollmentId: enrollmentId,
      fullName: 'Ana Silva',
      address: 'Rua',
      schoolId: schoolId,
      schoolName: 'Escola Ciclo 3',
      shift: 'afternoon',
    );
    await pumpTransport(
      tester,
      FakeTransportPlanningService(),
      student: student,
    );
    expect(
      find.text(
        'Nenhuma rota compatível com a escola e o turno deste aluno nesta data. Configure rotas e horários no planejamento da frota.',
      ),
      findsOneWidget,
    );
    final button = tester.widget<ElevatedButton>(
      find.widgetWithText(ElevatedButton, 'Salvar programação'),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('blocks allocation when the enrollment has no school or shift', (
    tester,
  ) async {
    const OwnerEnrolledStudent student = (
      id: 'student-a',
      enrollmentId: enrollmentId,
      fullName: 'Ana Silva',
      address: 'Rua',
      schoolId: null,
      schoolName: null,
      shift: null,
    );
    await pumpTransport(
      tester,
      FakeTransportPlanningService(),
      student: student,
    );
    expect(find.text('Escola: não definida'), findsOneWidget);
    expect(
      find.text(
        'Defina a escola e o turno do aluno antes de programar o transporte.',
      ),
      findsOneWidget,
    );
    expect(find.text('Salvar programação'), findsNothing);
  });

  testWidgets(
    'a fresh screen renders and preselects the persisted allocation',
    (tester) async {
      final service = FakeTransportPlanningService()
        ..planningJson['reservations'] = [
          reservationRow(
            weekday: 1,
            direction: 'going',
            scheduleId: goingSchedule,
            routeId: goingRoute,
          ),
        ];
      await pumpTransport(tester, service);
      expect(find.text('Programação salva'), findsOneWidget);
      expect(
        find.text('Seg · Ida · Ciclo 3 ida · 06/10/2026 a 25/12/2026'),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: slot(1, 'going'),
          matching: find.text('Ciclo 3 ida · 08:00'),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('shows that nothing is saved yet', (tester) async {
    await pumpTransport(tester, FakeTransportPlanningService());
    expect(find.text('Nenhuma programação salva.'), findsOneWidget);
  });

  testWidgets('a non-owner never reads planning', (tester) async {
    final service = FakeTransportPlanningService();
    await pumpTransport(tester, service, ownedFleets: const []);
    expect(
      find.text('Seu acesso à frota não está disponível.'),
      findsOneWidget,
    );
    expect(service.loads, 0);
  });

  testWidgets('read failure offers a retry that loads again', (tester) async {
    final service = FakeTransportPlanningService()
      ..loadError = Exception('offline');
    await pumpTransport(tester, service);
    expect(
      find.text('Não foi possível carregar o planejamento.'),
      findsOneWidget,
    );
    service.loadError = null;
    await tester.tap(find.text('Tentar novamente'));
    await tester.pumpAndSettle();
    expect(slot(1, 'going'), findsOneWidget);
    expect(service.loads, 2);
  });

  testWidgets(
    'saves a multi-day allocation with the suggested date and reloads from backend',
    (tester) async {
      final service = FakeTransportPlanningService();
      await pumpTransport(tester, service);
      await choose(tester, 1, 'going', 'Ciclo 3 ida · 08:00');
      await choose(tester, 1, 'return', 'Ciclo 3 volta · 16:00');
      await choose(tester, 3, 'going', 'Ciclo 3 ida · 08:00');
      await save(tester);

      final write = service.writes.single;
      expect(write.draft.effectiveOn, '2026-10-06');
      expect(write.draft.schoolId, schoolId);
      expect(write.draft.expectedRoutingRevision, 1);
      expect(write.draft.allocations, {
        (weekday: 1, direction: 'going'): goingSchedule,
        (weekday: 1, direction: 'return'): returnSchedule,
        (weekday: 3, direction: 'going'): goingSchedule,
      });
      expect(find.text('Programação salva.'), findsOneWidget);
      expect(service.loads, 2);
    },
  );

  testWidgets('owner can replace the suggested start date', (tester) async {
    final service = FakeTransportPlanningService();
    await pumpTransport(tester, service);
    await tester.ensureVisible(find.text('Alterar data'));
    await tester.tap(find.text('Alterar data'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('12'));
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.text('12/10/2026'), findsOneWidget);

    await choose(tester, 1, 'going', 'Ciclo 3 ida · 08:00');
    await save(tester);
    expect(service.writes.single.draft.effectiveOn, '2026-10-12');
  });

  testWidgets(
    'a date outside schedule validity drops choices and shows the empty state',
    (tester) async {
      final service = FakeTransportPlanningService();
      // Today 2026-12-24 -> suggested 2026-12-25, the last valid schedule day.
      await pumpTransport(tester, service, clock: () => DateTime(2026, 12, 24));
      await choose(
        tester,
        5,
        'going',
        'Ciclo 3 ida · 08:00',
      ); // 2026-12-25 is a Friday
      await tester.ensureVisible(find.text('Alterar data'));
      await tester.tap(find.text('Alterar data'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('26')); // picker opens on December 2026
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(find.text('26/12/2026'), findsOneWidget);
      expect(find.textContaining('Nenhuma rota compatível'), findsOneWidget);
      final button = tester.widget<ElevatedButton>(
        find.widgetWithText(ElevatedButton, 'Salvar programação'),
      );
      expect(button.onPressed, isNull);
    },
  );

  testWidgets(
    'capacity conflict is shown, never reported as success, and a retry is a new command',
    (tester) async {
      final service = FakeTransportPlanningService()
        ..writeResults.add(
          const PostgrestException(message: 'full', code: 'capacity_exceeded'),
        );
      await pumpTransport(tester, service);
      await choose(tester, 1, 'going', 'Ciclo 3 ida · 08:00');
      await save(tester);
      expect(
        find.text('A capacidade disponível não atende à programação.'),
        findsOneWidget,
      );
      expect(find.text('Programação salva.'), findsNothing);

      await save(tester);
      expect(service.writes, hasLength(2));
      expect(
        service.writes.last.commandId,
        isNot(service.writes.first.commandId),
      );
    },
  );

  testWidgets('revision conflict reloads planning and keeps the owner choices', (
    tester,
  ) async {
    final service = FakeTransportPlanningService()
      ..writeResults.add(
        const PostgrestException(message: 'stale', code: 'revision_conflict'),
      );
    await pumpTransport(tester, service);
    await choose(tester, 2, 'going', 'Ciclo 3 ida · 08:00');
    await save(tester);
    expect(
      find.text(
        'Esta configuração foi alterada. Recarregue e revise antes de salvar.',
      ),
      findsOneWidget,
    );
    expect(service.loads, 2);
    expect(
      find.descendant(
        of: slot(2, 'going'),
        matching: find.text('Ciclo 3 ida · 08:00'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('stale or incompatible schedule and closed dates are surfaced', (
    tester,
  ) async {
    final service = FakeTransportPlanningService()
      ..writeResults.addAll(const [
        PostgrestException(message: 'gone', code: 'invalid_input'),
        PostgrestException(message: 'closed', code: 'effective_date_conflict'),
      ]);
    await pumpTransport(tester, service);
    await choose(tester, 1, 'going', 'Ciclo 3 ida · 08:00');
    await save(tester);
    expect(
      find.text('Revise os campos e a cobertura da frota.'),
      findsOneWidget,
    );
    await save(tester);
    expect(
      find.text(
        'A data de início não está disponível para esta programação. Escolha outra data.',
      ),
      findsOneWidget,
    );
    expect(find.text('Programação salva.'), findsNothing);
  });

  testWidgets(
    'an unconfirmed write reuses its command id until the payload changes',
    (tester) async {
      final service = FakeTransportPlanningService()
        ..writeResults.addAll([
          Exception('socket closed'),
          Exception('socket closed'),
        ]);
      await pumpTransport(tester, service);
      await choose(tester, 1, 'going', 'Ciclo 3 ida · 08:00');
      await save(tester);
      expect(
        find.text(
          'Não foi possível confirmar o envio. Tente verificar novamente.',
        ),
        findsOneWidget,
      );
      expect(find.text('Programação salva.'), findsNothing);

      await save(tester); // same payload -> same id
      expect(service.writes[1].commandId, service.writes[0].commandId);

      await choose(tester, 1, 'return', 'Ciclo 3 volta · 16:00');
      await save(tester); // changed payload -> new id, succeeds
      expect(service.writes[2].commandId, isNot(service.writes[0].commandId));
      expect(find.text('Programação salva.'), findsOneWidget);
    },
  );

  testWidgets('losing owner access during a write hides the plan', (
    tester,
  ) async {
    final service = FakeTransportPlanningService()
      ..writeResults.add(
        const PostgrestException(message: 'gone', code: 'not_found'),
      );
    await pumpTransport(tester, service);
    await choose(tester, 1, 'going', 'Ciclo 3 ida · 08:00');
    await save(tester);
    expect(
      find.text('Seu acesso à frota não está disponível.'),
      findsOneWidget,
    );
    expect(find.text('Salvar programação'), findsNothing);
  });
}
