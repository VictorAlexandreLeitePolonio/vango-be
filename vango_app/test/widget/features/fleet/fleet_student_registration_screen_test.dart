import 'dart:async';
import 'package:vango_app/features/fleet/models/fleet_student_submission_state.dart';
import 'package:vango_app/features/fleet/services/fleet_student_error_mapper.dart';
import '../../../unit/features/fleet/fleet_student_registration_test.dart'
    as fixtures;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:vango_app/features/auth/models/access_context.dart';
import 'package:vango_app/features/fleet/models/fleet_student_registration.dart';
import 'package:vango_app/features/fleet/screens/fleet_student_registration_screen.dart';
import 'package:vango_app/features/fleet/services/fleet_service.dart';
import 'package:vango_app/features/shared/services/mapbox_geocoding_service.dart';
import 'package:vango_app/shared/widgets/mapbox_address_autocomplete_field.dart';
import '../../../support/fake_auth_service.dart';

AccessContext ownerContext(String fleetId) => AccessContext(
  onboardingIntent: null,
  accountRoles: const {AccountRole.owner},
  dependentStudentIds: const [],
  adultStudentId: null,
  fleetAccess: [
    FleetAccess(fleetId: fleetId, roles: const {AccountRole.owner}),
  ],
);

class RegistrationFleet extends FleetService {
  int reads = 0;
  final commands = <String>[];
  final drafts = <FleetStudentRegistration>[];
  Completer<FleetStudentRegistrationReceipt>? pendingWrite;
  Object? writeError;
  @override
  Future<FleetStudentRegistrationReceipt> registerStudent({
    required String fleetId,
    required String commandId,
    required FleetStudentRegistration registration,
  }) async {
    commands.add(commandId);
    drafts.add(registration);
    if (writeError case final error?) throw error;
    return pendingWrite?.future ??
        (
          studentId: '10000000-0000-4000-8000-000000000001',
          enrollmentId: '20000000-0000-4000-8000-000000000001',
        );
  }

  Object? readError;
  List<FleetServiceCity> cities = const [
    FleetServiceCity(
      cityIbgeCode: '3550308',
      cityName: 'São Paulo',
      stateCode: 'SP',
    ),
  ];
  List<FleetServiceSchool> schools = const [
    FleetServiceSchool(
      id: '10000000-0000-4000-8000-000000000001',
      name: 'Escola Municipal',
    ),
  ];
  @override
  Future<List<FleetServiceCity>> getServiceCities(String fleetId) async {
    reads++;
    if (readError case final error?) throw error;
    return cities;
  }

  @override
  Future<List<FleetServiceSchool>> getServiceSchools(String fleetId) async {
    reads++;
    if (readError case final error?) throw error;
    return schools;
  }
}

Widget form(
  FakeAuthService auth,
  RegistrationFleet fleet, {
  FleetStudentSubmissionState? submission,
}) => MaterialApp(
  home: FleetStudentRegistrationScreen(
    fleetId: 'fleet-a',
    userId: 'user-1',
    authService: auth,
    fleetService: fleet,
    submissionState: submission,
  ),
);
void main() {
  testWidgets(
    'starts without personal data and exposes adult contact and mobile scroll',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final auth = FakeAuthService.signedIn(
        userId: 'user-1',
        accessContext: ownerContext('fleet-a'),
      );
      addTearDown(auth.dispose);
      await tester.pumpWidget(form(auth, RegistrationFleet()));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('fullName')), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('fullName')))
            .controller!
            .text,
        isEmpty,
      );
      expect(find.text('Selecionar data de nascimento'), findsOneWidget);
      await tester.tap(find.text('Menor de idade'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Adulto').last);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Contato do aluno'),
        400,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Nome do responsável'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'address selection binds location and any street or number edit invalidates it',
    (tester) async {
      final auth = FakeAuthService.signedIn(
        userId: 'user-1',
        accessContext: ownerContext('fleet-a'),
      );
      addTearDown(auth.dispose);
      await tester.pumpWidget(form(auth, RegistrationFleet()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cidade atendida'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('São Paulo / SP').last);
      await tester.pumpAndSettle();
      final field = tester.widget<MapboxAddressAutocompleteField>(
        find.byType(MapboxAddressAutocompleteField),
      );
      field.onAddressSelected(
        const MapboxPlaceSuggestion(
          placeName: 'Rua Um, 12',
          street: 'Rua Um',
          streetNumber: '12',
          neighborhood: 'Centro',
          cityName: 'São Paulo',
          cityIbgeCode: '',
          stateCode: 'SP',
          postalCode: '01001000',
          latitude: 0,
          longitude: 0,
        ),
      );
      await tester.pump();
      expect(find.text('Localização selecionada'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('streetNumber')));
      await tester.enterText(find.byKey(const Key('streetNumber')), '13');
      await tester.pump();
      expect(find.text('Localização selecionada'), findsNothing);
      await tester.drag(find.byType(ListView), const Offset(0, 400));
      await tester.pumpAndSettle();
      expect(
        find.text('Selecione novamente o endereço completo na busca.'),
        findsOneWidget,
      );
    },
  );
  testWidgets(
    'resumes retained unknown command even after coverage removal and locks double retry',
    (tester) async {
      final auth = FakeAuthService.signedIn(
        userId: 'user-1',
        accessContext: ownerContext('fleet-a'),
      );
      addTearDown(auth.dispose);
      final state = FleetStudentSubmissionState(
        userId: 'user-1',
        fleetId: 'fleet-a',
      );
      final draft = fixtures.registration();
      state.begin('original-command', draft);
      state.fail(FleetStudentWriteFailureKind.unknownOutcome);
      final fleet = RegistrationFleet()
        ..cities = []
        ..schools = []
        ..pendingWrite = Completer<FleetStudentRegistrationReceipt>();
      await tester.pumpWidget(form(auth, fleet, submission: state));
      await tester.pumpAndSettle();
      expect(find.text('Tentar confirmar novamente'), findsOneWidget);
      await tester.tap(find.text('Tentar confirmar novamente'));
      await tester.tap(find.text('Tentar confirmar novamente'));
      await tester.pump();
      expect(fleet.commands, ['original-command']);
      expect(fleet.drafts.single, same(draft));
      fleet.pendingWrite!.complete((
        studentId: '10000000-0000-4000-8000-000000000001',
        enrollmentId: '20000000-0000-4000-8000-000000000001',
      ));
      await tester.pumpAndSettle();
      expect(state.phase, FleetStudentSubmissionPhase.committed);
    },
  );
  testWidgets('blank draft blocks submission with field feedback', (
    tester,
  ) async {
    final auth = FakeAuthService.signedIn(
      userId: 'user-1',
      accessContext: ownerContext('fleet-a'),
    );
    addTearDown(auth.dispose);
    final fleet = RegistrationFleet();
    await tester.pumpWidget(form(auth, fleet));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Salvar cadastro'),
      500,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Salvar cadastro'));
    await tester.pumpAndSettle();
    expect(fleet.commands, isEmpty);
    expect(
      find.text('Preencha os campos obrigatórios e selecione o endereço.'),
      findsOneWidget,
    );
  });
  testWidgets(
    'valid minor draft dispatches selected coverage with one UUID command',
    (tester) async {
      final auth = FakeAuthService.signedIn(
        userId: 'user-1',
        accessContext: ownerContext('fleet-a'),
      );
      addTearDown(auth.dispose);
      final fleet = RegistrationFleet();
      await tester.pumpWidget(form(auth, fleet));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('fullName')), 'Ana Silva');
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
      await tester.tap(find.text('São Paulo / SP').last);
      await tester.pumpAndSettle();
      tester
          .widget<MapboxAddressAutocompleteField>(
            find.byType(MapboxAddressAutocompleteField),
          )
          .onAddressSelected(
            const MapboxPlaceSuggestion(
              placeName: 'Rua Um, 12',
              street: 'Rua Um',
              streetNumber: '12',
              neighborhood: 'Centro',
              cityName: 'São Paulo',
              cityIbgeCode: '',
              stateCode: 'SP',
              postalCode: '01001000',
              latitude: 0,
              longitude: 0,
            ),
          );
      await tester.pump();
      await tester.scrollUntilVisible(
        find.text('Escola atendida'),
        400,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Escola atendida'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Escola Municipal').last);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const Key('contactFullName')),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(
        find.byKey(const Key('contactFullName')),
        'Responsável',
      );
      await tester.ensureVisible(find.byKey(const Key('contactEmail')));
      await tester.enterText(
        find.byKey(const Key('contactEmail')),
        'parent@example.com',
      );
      await tester.scrollUntilVisible(
        find.text('Salvar cadastro'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Salvar cadastro'));
      await tester.pumpAndSettle();
      expect(fleet.commands, hasLength(1));
      expect(
        fleet.commands.single,
        matches(
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          ),
        ),
      );
      expect(fleet.drafts.single.city.cityIbgeCode, '3550308');
      expect(fleet.drafts.single.latitude, 0);
    },
  );
  testWidgets(
    'same-user refresh preserves draft but logout hides and clears it',
    (tester) async {
      final auth = FakeAuthService.signedIn(
        userId: 'user-1',
        accessContext: ownerContext('fleet-a'),
      );
      addTearDown(auth.dispose);
      await tester.pumpWidget(form(auth, RegistrationFleet()));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('fullName')),
        'Draft Student',
      );
      auth.emit(AuthChangeEvent.tokenRefreshed, nextSession: auth.session);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('fullName')))
            .controller!
            .text,
        'Draft Student',
      );
      auth.emit(AuthChangeEvent.signedOut);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('fullName')), findsNothing);
      expect(
        find.text('Seu acesso à frota não está disponível.'),
        findsOneWidget,
      );
    },
  );
  testWidgets(
    'same-user refresh preserves in-flight command and logout discards late receipt',
    (tester) async {
      for (final logout in [false, true]) {
        final auth = FakeAuthService.signedIn(
          userId: 'user-1',
          accessContext: ownerContext('fleet-a'),
        );
        addTearDown(auth.dispose);
        final state = FleetStudentSubmissionState(
          userId: 'user-1',
          fleetId: 'fleet-a',
        );
        state.begin('original', fixtures.registration());
        state.fail(FleetStudentWriteFailureKind.unknownOutcome);
        final fleet = RegistrationFleet()
          ..pendingWrite = Completer<FleetStudentRegistrationReceipt>();
        await tester.pumpWidget(form(auth, fleet, submission: state));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Tentar confirmar novamente'));
        await tester.pump();
        auth.emit(
          logout ? AuthChangeEvent.signedOut : AuthChangeEvent.tokenRefreshed,
          nextSession: logout ? null : auth.session,
        );
        await tester.pump();
        fleet.pendingWrite!.complete((
          studentId: '10000000-0000-4000-8000-000000000001',
          enrollmentId: '20000000-0000-4000-8000-000000000001',
        ));
        await tester.pumpAndSettle();
        expect(state.receipt, logout ? isNull : isNotNull);
        expect(state.command?.id, logout ? isNull : 'original');
        if (logout) {
          expect(
            tester.widget<PopScope>(find.byType(PopScope).first).canPop,
            isTrue,
          );
        }
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
  );
  testWidgets('failed options retry is distinct from genuinely empty coverage', (
    tester,
  ) async {
    final auth = FakeAuthService.signedIn(
      userId: 'user-1',
      accessContext: ownerContext('fleet-a'),
    );
    addTearDown(auth.dispose);
    final fleet = RegistrationFleet()..readError = StateError('network');
    await tester.pumpWidget(form(auth, fleet));
    await tester.pumpAndSettle();
    expect(
      find.text('Não foi possível carregar as opções. Tente novamente.'),
      findsOneWidget,
    );
    fleet.readError = null;
    fleet.cities = [];
    await tester.tap(find.text('Tentar novamente'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'A frota precisa ter cidades e escolas atendidas para cadastrar alunos.',
      ),
      findsOneWidget,
    );
  });
  testWidgets('ignores a calendar result opened under a previous account', (
    tester,
  ) async {
    final auth = FakeAuthService.signedIn(
      userId: 'user-1',
      accessContext: ownerContext('fleet-a'),
    );
    addTearDown(auth.dispose);
    final other = FakeAuthService.signedIn(
      userId: 'user-2',
      accessContext: ownerContext('fleet-a'),
    );
    addTearDown(other.dispose);
    final fleet = RegistrationFleet();
    await tester.pumpWidget(form(auth, fleet));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Selecionar data de nascimento'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      MaterialApp(
        home: FleetStudentRegistrationScreen(
          fleetId: 'fleet-a',
          userId: 'user-2',
          authService: other,
          fleetService: fleet,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Selecionar'));
    await tester.pumpAndSettle();
    expect(find.text('Selecionar data de nascimento'), findsOneWidget);
  });
  testWidgets(
    'account switch during write clears the command and unlocks the new form',
    (tester) async {
      final auth = FakeAuthService.signedIn(
        userId: 'user-1',
        accessContext: ownerContext('fleet-a'),
      );
      final other = FakeAuthService.signedIn(
        userId: 'user-2',
        accessContext: ownerContext('fleet-a'),
      );
      addTearDown(auth.dispose);
      addTearDown(other.dispose);
      final state = FleetStudentSubmissionState(
        userId: 'user-1',
        fleetId: 'fleet-a',
      );
      state.begin('original', fixtures.registration());
      state.fail(FleetStudentWriteFailureKind.unknownOutcome);
      final fleet = RegistrationFleet()
        ..pendingWrite = Completer<FleetStudentRegistrationReceipt>();
      await tester.pumpWidget(form(auth, fleet, submission: state));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tentar confirmar novamente'));
      await tester.pump();
      await tester.pumpWidget(
        MaterialApp(
          home: FleetStudentRegistrationScreen(
            fleetId: 'fleet-a',
            userId: 'user-2',
            authService: other,
            fleetService: fleet,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<PopScope>(find.byType(PopScope).first).canPop,
        isTrue,
      );
      expect(state.command, isNull);
      fleet.pendingWrite!.complete((
        studentId: '10000000-0000-4000-8000-000000000001',
        enrollmentId: '20000000-0000-4000-8000-000000000001',
      ));
      await tester.pumpAndSettle();
      expect(find.text('Selecionar data de nascimento'), findsOneWidget);
    },
  );
  testWidgets(
    'retrying options rebinds the selected city by stable coverage identity',
    (tester) async {
      final auth = FakeAuthService.signedIn(
        userId: 'user-1',
        accessContext: ownerContext('fleet-a'),
      );
      final fleet = RegistrationFleet();
      addTearDown(auth.dispose);
      await tester.pumpWidget(form(auth, fleet));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cidade atendida'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('São Paulo / SP').last);
      await tester.pumpAndSettle();
      auth.nextAccessError = StateError('offline');
      auth.emit(AuthChangeEvent.tokenRefreshed, nextSession: auth.session);
      await tester.pumpAndSettle();
      fleet.cities = [
        FleetServiceCity(
          cityIbgeCode: '3550308',
          cityName: 'São Paulo',
          stateCode: 'SP',
        ),
      ];
      await tester.tap(find.text('Tentar novamente'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('São Paulo / SP'), findsOneWidget);
    },
  );
  testWidgets(
    'selecting another building never inherits missing postal or neighborhood metadata',
    (tester) async {
      final auth = FakeAuthService.signedIn(
        userId: 'user-1',
        accessContext: ownerContext('fleet-a'),
      );
      final fleet = RegistrationFleet();
      addTearDown(auth.dispose);
      await tester.pumpWidget(form(auth, fleet));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cidade atendida'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('São Paulo / SP').last);
      await tester.pumpAndSettle();
      final field = tester.widget<MapboxAddressAutocompleteField>(
        find.byType(MapboxAddressAutocompleteField),
      );
      field.onAddressSelected(
        const MapboxPlaceSuggestion(
          placeName: 'Rua Um, 12',
          street: 'Rua Um',
          streetNumber: '12',
          neighborhood: 'Centro',
          cityName: 'São Paulo',
          cityIbgeCode: '',
          stateCode: 'SP',
          postalCode: '01001000',
          latitude: 0,
          longitude: 0,
        ),
      );
      await tester.pump();
      field.onAddressSelected(
        const MapboxPlaceSuggestion(
          placeName: 'Rua Dois, 50',
          street: 'Rua Dois',
          streetNumber: '50',
          neighborhood: '',
          cityName: 'São Paulo',
          cityIbgeCode: '',
          stateCode: 'SP',
          postalCode: '',
          latitude: 1,
          longitude: 1,
        ),
      );
      await tester.pump();
      await tester.scrollUntilVisible(
        find.byKey(const Key('postalCode')),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('postalCode')))
            .controller!
            .text,
        isEmpty,
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('neighborhood')))
            .controller!
            .text,
        isEmpty,
      );
    },
  );
  testWidgets('waits for owner authorization before reading any options', (
    tester,
  ) async {
    final auth = FakeAuthService.signedIn(userId: 'user-1')
      ..accessCompleter = Completer<AccessContext>();
    final fleet = RegistrationFleet();
    addTearDown(auth.dispose);
    await tester.pumpWidget(form(auth, fleet));
    expect(fleet.reads, 0);
    auth.accessCompleter!.complete(ownerContext('fleet-a'));
    await tester.pumpAndSettle();
    expect(fleet.reads, 2);
    expect(find.text('Cadastrar aluno'), findsOneWidget);
  });
  testWidgets('rejects direct construction outside current owner fleet', (
    tester,
  ) async {
    final auth = FakeAuthService.signedIn(
      userId: 'user-1',
      accessContext: ownerContext('fleet-b'),
    );
    final fleet = RegistrationFleet();
    addTearDown(auth.dispose);
    await tester.pumpWidget(form(auth, fleet));
    await tester.pumpAndSettle();
    expect(fleet.reads, 0);
    expect(
      find.text('Seu acesso à frota não está disponível.'),
      findsOneWidget,
    );
  });
}
