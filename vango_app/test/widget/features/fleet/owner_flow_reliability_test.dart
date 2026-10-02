import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:vango_app/features/auth/models/access_context.dart';
import 'package:vango_app/features/fleet/models/fleet_student_registration.dart';
import 'package:vango_app/features/fleet/screens/fleet_owner_dashboard_screen.dart';
import 'package:vango_app/features/fleet/screens/fleet_student_registration_screen.dart';
import 'package:vango_app/features/fleet/services/fleet_service.dart';
import 'package:vango_app/features/shared/services/mapbox_geocoding_service.dart';
import 'package:vango_app/shared/widgets/mapbox_address_autocomplete_field.dart';

import '../../../support/fake_auth_service.dart';

class ReliabilityFleet extends FleetService {
  final commands = <String>[];
  final submitted = <FleetStudentRegistration>[];
  Object? writeError;
  bool failStudentRead = false;
  int studentReads = 0;
  int otherReads = 0;
  Completer<FleetStudentRegistrationReceipt>? pendingWrite;
  List<OwnerEnrolledStudent> students = [];

  @override
  Future<List<FleetServiceCity>> getServiceCities(String fleetId) async =>
      const [
        FleetServiceCity(
          cityIbgeCode: '2611606',
          cityName: 'Recife',
          stateCode: 'PE',
        ),
      ];
  @override
  Future<List<FleetServiceSchool>> getServiceSchools(String fleetId) async =>
      const [
        FleetServiceSchool(
          id: '10000000-0000-4000-8000-000000000001',
          name: 'Escola Sintética',
        ),
      ];
  @override
  Future<List<PendingJoinRequest>> getPendingRequests(String fleetId) async {
    otherReads++;
    throw StateError('unavailable unrelated section');
  }

  @override
  Future<List<FleetMemberDriver>> getFleetDrivers(String fleetId) async {
    otherReads++;
    throw StateError('unavailable unrelated section');
  }

  @override
  Future<List<OwnerEnrolledStudent>> getOwnerEnrolledStudents(
    String fleetId,
  ) async {
    studentReads++;
    if (failStudentRead) throw StateError('synthetic read failure');
    return students;
  }

  @override
  Future<FleetStudentRegistrationReceipt> registerStudent({
    required String fleetId,
    required String commandId,
    required FleetStudentRegistration registration,
  }) async {
    commands.add(commandId);
    submitted.add(registration);
    if (writeError case final error?) throw error;
    return pendingWrite?.future ??
        (
          studentId: '10000000-0000-4000-8000-000000000002',
          enrollmentId: '10000000-0000-4000-8000-000000000003',
        );
  }
}

FakeAuthService owner() => FakeAuthService.signedIn(
  userId: 'reliability-owner',
  accessContext: const AccessContext(
    onboardingIntent: null,
    accountRoles: {AccountRole.owner},
    dependentStudentIds: [],
    adultStudentId: null,
    fleetAccess: [
      FleetAccess(fleetId: 'reliability-fleet', roles: {AccountRole.owner}),
    ],
  ),
);

MapboxPlaceSuggestion point({String city = 'Recife', String state = 'PE'}) =>
    MapboxPlaceSuggestion(
      placeName: 'Rua Sintética, 12',
      street: 'Rua Sintética',
      streetNumber: '12',
      neighborhood: 'Boa Viagem',
      cityName: city,
      cityIbgeCode: '',
      stateCode: state,
      postalCode: '51000000',
      latitude: -8.123,
      longitude: -34.987,
    );

Widget form(FakeAuthService auth, ReliabilityFleet fleet) => MaterialApp(
  home: FleetStudentRegistrationScreen(
    fleetId: 'reliability-fleet',
    userId: 'reliability-owner',
    authService: auth,
    fleetService: fleet,
  ),
);

Future<void> fillForm(
  WidgetTester tester, {
  MapboxPlaceSuggestion? address,
}) async {
  await tester.enterText(find.byKey(const Key('fullName')), 'Nome enviado');
  await tester.tap(find.text('Selecionar data de nascimento'));
  await tester.pumpAndSettle();
  await tester.tap(find.byIcon(Icons.edit_outlined));
  await tester.pumpAndSettle();
  await tester.enterText(
    find.descendant(
      of: find.byType(DatePickerDialog),
      matching: find.byType(TextField),
    ),
    '02/03/2012',
  );
  await tester.tap(find.text('Selecionar'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Cidade atendida'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Recife / PE').last);
  await tester.pumpAndSettle();
  tester
      .widget<MapboxAddressAutocompleteField>(
        find.byType(MapboxAddressAutocompleteField),
      )
      .onAddressSelected(address ?? point());
  await tester.pump();
  await tester.scrollUntilVisible(
    find.text('Escola atendida'),
    300,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.tap(find.text('Escola atendida'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Escola Sintética').last);
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(
    find.byKey(const Key('contactFullName')),
    300,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.enterText(
    find.byKey(const Key('contactFullName')),
    'Responsável sintético',
  );
  await tester.ensureVisible(find.byKey(const Key('contactEmail')));
  await tester.enterText(
    find.byKey(const Key('contactEmail')),
    'synthetic@example.com',
  );
}

Future<void> submit(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(
    find.text('Salvar cadastro'),
    300,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.text('Salvar cadastro'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Salvar cadastro').hitTestable());
  await tester.pumpAndSettle();
}

void main() {
  for (final location in [
    point(city: 'Olinda'),
    point(city: ''),
    point(state: ''),
  ]) {
    testWidgets(
      'refuses incomplete or mismatched municipality ${location.cityName}/${location.stateCode}',
      (tester) async {
        final auth = owner();
        addTearDown(auth.dispose);
        final fleet = ReliabilityFleet();
        await tester.pumpWidget(form(auth, fleet));
        await tester.pumpAndSettle();
        await fillForm(tester, address: location);
        await submit(tester);
        expect(fleet.commands, isEmpty);
        expect(
          find.text('Preencha os campos obrigatórios e selecione o endereço.'),
          findsOneWidget,
        );
        expect(find.byType(FleetStudentRegistrationScreen), findsOneWidget);
      },
    );
  }

  for (final field in ['street', 'streetNumber']) {
    testWidgets(
      'editing $field after selection cannot submit the previous coordinates',
      (tester) async {
        final auth = owner();
        addTearDown(auth.dispose);
        final fleet = ReliabilityFleet();
        await tester.pumpWidget(form(auth, fleet));
        await tester.pumpAndSettle();
        await fillForm(tester);
        await tester.scrollUntilVisible(
          find.byKey(Key(field)),
          -300,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.enterText(
          find.byKey(Key(field)),
          field == 'street' ? 'Rua Alterada' : '99',
        );
        await submit(tester);
        expect(fleet.commands, isEmpty);
        expect(
          find.text('Preencha os campos obrigatórios e selecione o endereço.'),
          findsOneWidget,
        );
      },
    );
  }

  testWidgets(
    'definitive write rejection preserves entered data and never reports success',
    (tester) async {
      final auth = owner();
      addTearDown(auth.dispose);
      final fleet = ReliabilityFleet()
        ..writeError = const PostgrestException(
          message: 'SENTINEL_PRIVATE_ADDRESS',
          code: 'invalid_input',
        );
      await tester.pumpWidget(form(auth, fleet));
      await tester.pumpAndSettle();
      await fillForm(tester);
      await submit(tester);
      expect(fleet.commands, hasLength(1));
      expect(fleet.submitted.single.city.cityIbgeCode, '2611606');
      expect(fleet.submitted.single.latitude, -8.123);
      expect(find.byType(FleetStudentRegistrationScreen), findsOneWidget);
      expect(find.text('Aluno cadastrado.'), findsNothing);
      expect(find.textContaining('SENTINEL'), findsNothing);
      await tester.scrollUntilVisible(
        find.byKey(const Key('fullName')),
        -300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('fullName')))
            .controller!
            .text,
        'Nome enviado',
      );
    },
  );

  testWidgets(
    'late successful write after logout cannot show success in another session',
    (tester) async {
      final auth = owner();
      addTearDown(auth.dispose);
      final fleet = ReliabilityFleet()
        ..pendingWrite = Completer<FleetStudentRegistrationReceipt>();
      await tester.pumpWidget(form(auth, fleet));
      await tester.pumpAndSettle();
      await fillForm(tester);
      await tester.scrollUntilVisible(
        find.text('Salvar cadastro'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Salvar cadastro').hitTestable());
      await tester.pump();
      expect(fleet.commands, hasLength(1));
      await auth.signOut();
      await tester.pump();
      fleet.pendingWrite!.complete((
        studentId: '10000000-0000-4000-8000-000000000002',
        enrollmentId: '10000000-0000-4000-8000-000000000003',
      ));
      await tester.pumpAndSettle();
      expect(
        find.text('Seu acesso à frota não está disponível.'),
        findsOneWidget,
      );
      expect(find.text('Aluno cadastrado.'), findsNothing);
      expect(fleet.studentReads, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'unknown write survives token refresh and reopen then read-only retry renders server data',
    (tester) async {
      final auth = owner();
      addTearDown(auth.dispose);
      final fleet = ReliabilityFleet()
        ..writeError = TimeoutException('SENTINEL_TRANSPORT');
      await tester.pumpWidget(
        MaterialApp(
          home: FleetOwnerDashboardScreen(
            fleetId: 'reliability-fleet',
            userId: 'reliability-owner',
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
      await fillForm(tester);
      await submit(tester);
      expect(find.text('Tentar confirmar novamente'), findsOneWidget);
      expect(fleet.commands, hasLength(1));
      final command = fleet.commands.single;
      final originalDraft = fleet.submitted.single;
      auth.emit(
        AuthChangeEvent.tokenRefreshed,
        nextSession: auth.currentSession,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Voltar para a lista'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Retomar confirmação do cadastro'));
      await tester.pumpAndSettle();
      fleet.writeError = null;
      fleet.failStudentRead = true;
      await tester.tap(find.text('Tentar confirmar novamente'));
      await tester.pumpAndSettle();
      expect(fleet.commands, [command, command]);
      expect(fleet.submitted.last, same(originalDraft));
      expect(
        find.text(
          'Aluno cadastrado. Não foi possível atualizar a lista. Tente novamente.',
        ),
        findsOneWidget,
      );
      final otherReads = fleet.otherReads;
      fleet.failStudentRead = false;
      fleet.students = [
        (
          id: 'canonical-student',
          enrollmentId: 'canonical-enrollment',
          fullName: 'Nome canônico do servidor',
          address: 'Endereço canônico',
          schoolId: null,
          schoolName: null,
          shift: null,
        ),
      ];
      await tester.tap(find.text('Tentar novamente').last);
      await tester.pumpAndSettle();
      expect(find.text('Nome canônico do servidor'), findsOneWidget);
      expect(find.text('Nome enviado'), findsNothing);
      expect(fleet.commands, [command, command]);
      expect(fleet.otherReads, otherReads);
    },
  );
}
