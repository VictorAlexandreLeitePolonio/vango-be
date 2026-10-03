import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_auth_service.dart';
import 'package:vango_app/features/auth/models/access_context.dart';
import 'package:vango_app/features/auth/models/onboarding_intent.dart';
import 'package:vango_app/features/auth/screens/authenticated_home_screen.dart';
import 'package:vango_app/core/routes/app_routes.dart';
import 'package:vango_app/shared/widgets/vango_button.dart';

void main() {
  testWidgets('one owner fleet navigates with its ID and current user', (
    tester,
  ) async {
    final service = FakeAuthService.signedIn(userId: 'user-1');
    addTearDown(service.dispose);
    Object? routeArguments;

    await tester.pumpWidget(
      MaterialApp(
        home: AuthenticatedHomeScreen(
          authService: service,
          accessContext: _context(
            roles: {AccountRole.owner},
            fleetAccess: const [
              FleetAccess(fleetId: 'fleet-a', roles: {AccountRole.owner}),
            ],
          ),
        ),
        onGenerateRoute: (settings) {
          if (settings.name != AppRoutes.fleetDashboard) return null;
          routeArguments = settings.arguments;
          return MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Dashboard opened')),
          );
        },
      ),
    );

    expect(find.byType(DropdownButton<String>), findsNothing);
    final button = tester.widget<VanGoButton>(
      find.widgetWithText(VanGoButton, 'Acessar Gestão da Frota'),
    );
    expect(button.onPressed, isNotNull);
    await tester.tap(find.text('Acessar Gestão da Frota'));
    await tester.pumpAndSettle();
    expect(routeArguments, (fleetId: 'fleet-a', userId: 'user-1'));
  });

  testWidgets('owner role without fleet shows no management action', (
    tester,
  ) async {
    final service = FakeAuthService.signedIn(userId: 'user-1');
    addTearDown(service.dispose);
    await tester.pumpWidget(
      buildTestApp(
        AuthenticatedHomeScreen(
          authService: service,
          accessContext: _context(roles: {AccountRole.owner}),
        ),
      ),
    );
    expect(find.text('Nenhuma frota disponível para gestão'), findsOneWidget);
    expect(find.text('Acessar Gestão da Frota'), findsNothing);
  });

  testWidgets('multiple owner fleets are sorted and require selection', (
    tester,
  ) async {
    final service = FakeAuthService.signedIn(userId: 'user-1');
    addTearDown(service.dispose);
    Object? routeArguments;
    await tester.pumpWidget(
      MaterialApp(
        home: AuthenticatedHomeScreen(
          authService: service,
          accessContext: _context(
            roles: {AccountRole.owner},
            fleetAccess: const [
              FleetAccess(fleetId: 'fleet-c', roles: {AccountRole.owner}),
              FleetAccess(fleetId: 'fleet-b', roles: {AccountRole.owner}),
              FleetAccess(fleetId: 'fleet-b', roles: {AccountRole.owner}),
            ],
          ),
        ),
        onGenerateRoute: (settings) {
          if (settings.name != AppRoutes.fleetDashboard) return null;
          routeArguments = settings.arguments;
          return MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Dashboard opened')),
          );
        },
      ),
    );
    final selector = tester.widget<DropdownButton<String>>(
      find.byType(DropdownButton<String>),
    );
    expect(selector.items!.map((item) => item.value).toList(), [
      'fleet-b',
      'fleet-c',
    ]);
    expect(
      tester
          .widget<VanGoButton>(
            find.widgetWithText(VanGoButton, 'Acessar Gestão da Frota'),
          )
          .onPressed,
      isNull,
    );
    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('fleet-b').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Acessar Gestão da Frota'));
    await tester.pumpAndSettle();
    expect(routeArguments, (fleetId: 'fleet-b', userId: 'user-1'));
  });

  testWidgets('removed owner fleet clears the current selection', (
    tester,
  ) async {
    final service = FakeAuthService.signedIn(userId: 'user-1');
    addTearDown(service.dispose);
    Widget home(List<FleetAccess> fleetAccess) => MaterialApp(
      home: AuthenticatedHomeScreen(
        authService: service,
        accessContext: _context(
          roles: {AccountRole.owner},
          fleetAccess: fleetAccess,
        ),
      ),
    );
    await tester.pumpWidget(
      home(const [
        FleetAccess(fleetId: 'fleet-a', roles: {AccountRole.owner}),
        FleetAccess(fleetId: 'fleet-b', roles: {AccountRole.owner}),
      ]),
    );
    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('fleet-b').last);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<DropdownButton<String>>(find.byType(DropdownButton<String>))
          .value,
      'fleet-b',
    );

    await tester.pumpWidget(
      home(const [
        FleetAccess(fleetId: 'fleet-a', roles: {AccountRole.owner}),
        FleetAccess(fleetId: 'fleet-c', roles: {AccountRole.owner}),
      ]),
    );
    expect(
      tester
          .widget<DropdownButton<String>>(find.byType(DropdownButton<String>))
          .value,
      isNull,
    );
    expect(
      tester
          .widget<VanGoButton>(
            find.widgetWithText(VanGoButton, 'Acessar Gestão da Frota'),
          )
          .onPressed,
      isNull,
    );
  });

  final setupMessages = <OnboardingIntent, String>{
    OnboardingIntent.fleetOwner: 'Configure sua frota',
    OnboardingIntent.driver: 'Aguarde ou aceite um convite da frota',
    OnboardingIntent.guardian: 'Cadastre o aluno sob sua responsabilidade',
    OnboardingIntent.adultStudent: 'Complete seus dados de aluno',
  };

  for (final entry in setupMessages.entries) {
    testWidgets('${entry.key.apiValue} intent shows its setup guidance', (
      tester,
    ) async {
      final service = FakeAuthService.signedIn(userId: 'user-1');
      addTearDown(service.dispose);

      await tester.pumpWidget(
        buildTestApp(
          AuthenticatedHomeScreen(
            authService: service,
            accessContext: _context(intent: entry.key),
          ),
        ),
      );

      expect(find.text(entry.value), findsOneWidget);
      expect(find.text('Painel da frota'), findsNothing);
      expect(find.text('Minhas viagens'), findsNothing);
      expect(find.text('Meus alunos'), findsNothing);
      expect(find.text('Meu transporte'), findsNothing);
    });
  }

  final roleTitles = <AccountRole, String>{
    AccountRole.owner: 'Painel da frota',
    AccountRole.driver: 'Minhas viagens',
    AccountRole.guardian: 'Meus alunos',
    AccountRole.student: 'Meu transporte',
  };

  for (final entry in roleTitles.entries) {
    testWidgets('${entry.key.name} role shows its protected destination', (
      tester,
    ) async {
      final service = FakeAuthService.signedIn(userId: 'user-1');
      addTearDown(service.dispose);

      await tester.pumpWidget(
        buildTestApp(
          AuthenticatedHomeScreen(
            authService: service,
            accessContext: _context(
              intent: OnboardingIntent.guardian,
              roles: {entry.key},
            ),
          ),
        ),
      );

      expect(find.text(entry.value), findsOneWidget);
    });
  }

  testWidgets('switches between multiple effective roles', (tester) async {
    final service = FakeAuthService.signedIn(userId: 'user-1');
    addTearDown(service.dispose);

    await tester.pumpWidget(
      buildTestApp(
        AuthenticatedHomeScreen(
          authService: service,
          accessContext: _context(
            roles: {AccountRole.owner, AccountRole.driver},
          ),
        ),
      ),
    );

    expect(find.text('Painel da frota'), findsOneWidget);
    expect(find.byType(DropdownButton<AccountRole>), findsOneWidget);

    await tester.tap(find.byType(DropdownButton<AccountRole>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Motorista').last);
    await tester.pumpAndSettle();

    expect(find.text('Minhas viagens'), findsOneWidget);
  });

  testWidgets('shows the current account and exposes sign out', (tester) async {
    final service = FakeAuthService.signedIn(userId: 'user-1');
    addTearDown(service.dispose);

    await tester.pumpWidget(
      buildTestApp(
        AuthenticatedHomeScreen(
          authService: service,
          accessContext: _context(roles: {AccountRole.owner}),
        ),
      ),
    );

    expect(find.text('user@example.com'), findsOneWidget);
    expect(find.text('Sair'), findsOneWidget);

    await tester.tap(find.text('Sair'));
    await tester.pump();

    expect(service.signOutCalls, 1);
  });
}

AccessContext _context({
  OnboardingIntent? intent,
  Set<AccountRole> roles = const {},
  List<FleetAccess> fleetAccess = const [],
}) {
  return AccessContext(
    onboardingIntent: intent,
    accountRoles: roles,
    dependentStudentIds: const [],
    adultStudentId: null,
    fleetAccess: fleetAccess,
  );
}
