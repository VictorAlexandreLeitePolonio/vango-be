import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../support/fake_auth_service.dart';
import 'package:vango_app/core/routes/app_routes.dart';
import 'package:vango_app/features/auth/models/access_context.dart';
import 'package:vango_app/features/auth/models/onboarding_intent.dart';
import 'package:vango_app/features/auth/widgets/auth_gate.dart';

void main() {
  testWidgets('shows public entry when there is no session', (tester) async {
    final service = FakeAuthService.signedOut();
    addTearDown(service.dispose);

    await tester.pumpWidget(buildTestApp(AuthGate(authService: service)));

    expect(
      find.text('Transporte escolar\nseguro e organizado'),
      findsOneWidget,
    );
  });

  testWidgets('authenticated named route loads effective access', (
    tester,
  ) async {
    final service = FakeAuthService.signedIn(userId: 'user-1');
    service.accessCompleter = Completer<AccessContext>();
    addTearDown(service.dispose);

    await tester.pumpWidget(
      MaterialApp(
        initialRoute: AppRoutes.authenticatedHome,
        routes: AppRoutes.routes(authService: service),
      ),
    );

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(service.accessContextCalls, 1);
  });

  testWidgets('shows loading while effective access is pending', (
    tester,
  ) async {
    final service = FakeAuthService.signedIn(userId: 'user-1');
    service.accessCompleter = Completer<AccessContext>();
    addTearDown(service.dispose);

    await tester.pumpWidget(buildTestApp(AuthGate(authService: service)));

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Painel da frota'), findsNothing);
  });

  testWidgets('does not reload the same restored session twice', (
    tester,
  ) async {
    final service = FakeAuthService.signedIn(userId: 'user-1');
    service.accessCompleter = Completer<AccessContext>();
    addTearDown(service.dispose);

    await tester.pumpWidget(buildTestApp(AuthGate(authService: service)));
    service.emit(AuthChangeEvent.initialSession, nextSession: service.session);
    await tester.pump();

    expect(service.accessContextCalls, 1);
  });

  testWidgets('retries access loading after an RPC failure', (tester) async {
    final service = FakeAuthService.signedIn(
      userId: 'user-1',
      accessContext: _accessContext(roles: {AccountRole.owner}),
    );
    service.nextAccessError = Exception('network unavailable');
    addTearDown(service.dispose);

    await tester.pumpWidget(buildTestApp(AuthGate(authService: service)));
    await tester.pumpAndSettle();

    expect(find.text('Não foi possível carregar seu acesso'), findsOneWidget);
    expect(find.text('Tentar novamente'), findsOneWidget);

    await tester.tap(find.text('Tentar novamente'));
    await tester.pumpAndSettle();

    expect(service.accessContextCalls, 2);
    expect(find.text('Sair'), findsOneWidget);
  });

  testWidgets('sign out returns to the public entry', (tester) async {
    final service = FakeAuthService.signedIn(
      userId: 'user-1',
      accessContext: _accessContext(roles: {AccountRole.owner}),
    );
    addTearDown(service.dispose);

    await tester.pumpWidget(buildTestApp(AuthGate(authService: service)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sair'));
    await tester.pump();

    expect(service.signOutCalls, 1);
    expect(
      find.text('Transporte escolar\nseguro e organizado'),
      findsOneWidget,
    );
  });

  testWidgets('ignores a pending access result after sign out', (tester) async {
    final service = FakeAuthService.signedIn(userId: 'user-1');
    final pendingAccess = Completer<AccessContext>();
    service.accessCompleter = pendingAccess;
    addTearDown(service.dispose);

    await tester.pumpWidget(buildTestApp(AuthGate(authService: service)));
    service.emit(AuthChangeEvent.signedOut);
    await tester.pump();

    pendingAccess.complete(_accessContext(roles: {AccountRole.owner}));
    await tester.pump();

    expect(
      find.text('Transporte escolar\nseguro e organizado'),
      findsOneWidget,
    );
    expect(find.text('Painel da frota'), findsNothing);
  });

  testWidgets('shows password reset after a recovery event', (tester) async {
    final service = FakeAuthService.signedIn(userId: 'user-1');
    addTearDown(service.dispose);
    final recoverySession = service.session;

    await tester.pumpWidget(buildTestApp(AuthGate(authService: service)));
    service.emit(
      AuthChangeEvent.passwordRecovery,
      nextSession: recoverySession,
    );
    await tester.pump();

    expect(find.text('Redefinir senha'), findsOneWidget);
  });
}

AccessContext _accessContext({
  OnboardingIntent? intent,
  Set<AccountRole> roles = const {},
}) {
  return AccessContext(
    onboardingIntent: intent,
    accountRoles: roles,
    dependentStudentIds: const [],
    adultStudentId: null,
    fleetAccess: const [],
  );
}
