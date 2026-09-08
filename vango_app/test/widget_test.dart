import 'package:flutter_test/flutter_test.dart';

import 'package:vango_app/main.dart';

void main() {
  testWidgets('App should render WelcomeScreen', (WidgetTester tester) async {
    await tester.pumpWidget(const VanGoApp());

    // Verify that the welcome screen loads with expected action buttons
    expect(find.text('Sign In'), findsOneWidget);
    expect(find.text('Create Account'), findsOneWidget);
  });
}
