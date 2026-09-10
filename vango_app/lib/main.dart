import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'core/config/supabase_config.dart';
import 'core/routes/app_routes.dart';
import 'core/theme/app_theme.dart';
import 'features/auth/screens/welcome_screen.dart';
import 'features/auth/services/auth_service.dart';
import 'features/auth/widgets/auth_gate.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Transparent status bar to blend seamlessly with gradients
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
      statusBarBrightness: Brightness.light,
    ),
  );

  final config = SupabaseConfig.fromEnvironment()..validate();
  await Supabase.initialize(
    url: config.url,
    publishableKey: config.publishableKey,
  );

  runApp(VanGoApp(authService: SupabaseAuthService()));
}

/// Root widget for VanGo.
///
/// Configures theme, routes, and global settings.
class VanGoApp extends StatelessWidget {
  const VanGoApp({super.key, this.authService});

  final AuthService? authService;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VanGo',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      home: authService == null
          ? const WelcomeScreen()
          : AuthGate(authService: authService!),
      routes: AppRoutes.routes(authService: authService),
    );
  }
}
