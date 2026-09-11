import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:vango_app/features/auth/screens/forgot_password_screen.dart';
import 'package:vango_app/features/auth/screens/login_screen.dart';
import 'package:vango_app/features/auth/screens/register_screen.dart';
import 'package:vango_app/features/auth/screens/reset_password_screen.dart';
import 'package:vango_app/features/auth/screens/welcome_screen.dart';

import '../../../support/fake_auth_service.dart';

void main() {
  testWidgets('welcome screen describes the brand artwork', (tester) async {
    await tester.pumpWidget(buildTestApp(const WelcomeScreen()));
    await tester.pumpAndSettle();

    expect(find.bySemanticsLabel('Logo VanGo'), findsOneWidget);
    expect(
      find.bySemanticsLabel(
        'Van escolar conectando a escola ao destino por uma rota segura',
      ),
      findsOneWidget,
    );
  });

  testWidgets('welcome action card stays compact with bottom breathing room', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(buildTestApp(const WelcomeScreen()));
    await tester.pumpAndSettle();

    final card = find.byKey(const Key('welcomeActionCard'));
    final banner = find.byKey(const Key('onboardingBanner'));
    final logo = find.byKey(const Key('welcomeLogo'));
    final cardRect = tester.getRect(card);
    final bannerRect = tester.getRect(banner);
    final logoRect = tester.getRect(logo);

    expect(cardRect.height, lessThan(460));
    expect(1600 - cardRect.bottom, greaterThanOrEqualTo(40));
    expect(bannerRect.width, lessThan(cardRect.width));
    expect(bannerRect.width / bannerRect.height, closeTo(1.2, 0.01));
    expect(bannerRect.top - logoRect.bottom, lessThanOrEqualTo(12));
    expect(cardRect.top, greaterThan(bannerRect.bottom));
  });

  final service = FakeAuthService.signedOut();
  final screens = <String, Widget>{
    'login': LoginScreen(authService: service),
    'register': RegisterScreen(authService: service),
    'forgot password': ForgotPasswordScreen(authService: service),
    'reset password': ResetPasswordScreen(authService: service),
  };

  for (final entry in screens.entries) {
    testWidgets('${entry.key} form stays readable on wide screens', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(buildTestApp(entry.value));

      expect(tester.getSize(find.byType(Form)).width, lessThanOrEqualTo(440));
    });
  }

  tearDownAll(service.dispose);
}
