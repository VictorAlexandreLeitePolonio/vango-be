import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../shared/widgets/vango_button.dart';
import '../models/access_context.dart';
import '../models/onboarding_intent.dart';
import '../services/auth_error_mapper.dart';
import '../services/auth_service.dart';

import '../../driver/models/driver_trip.dart';
import '../../driver/services/driver_route_service.dart';
import '../../driver/widgets/driver_trip_card.dart';
import '../../../core/routes/app_routes.dart';

class AuthenticatedHomeScreen extends StatefulWidget {
  const AuthenticatedHomeScreen({
    super.key,
    required this.authService,
    required this.accessContext,
    this.driverRouteService,
  });

  final AuthService authService;
  final AccessContext accessContext;
  final DriverRouteService? driverRouteService;

  @override
  State<AuthenticatedHomeScreen> createState() =>
      _AuthenticatedHomeScreenState();
}

class _AuthenticatedHomeScreenState extends State<AuthenticatedHomeScreen> {
  bool _isSigningOut = false;
  AccountRole? _selectedRole;
  late final DriverRouteService _driverRouteService;
  DriverTrip? _driverTrip;

  @override
  void initState() {
    super.initState();
    _selectedRole = _availableRoles.firstOrNull;
    _driverRouteService = widget.driverRouteService ?? DriverRouteService();
    _loadDriverTrip();
  }

  Future<void> _loadDriverTrip() async {
    final trip = await _driverRouteService.getTodayTrip();
    if (mounted) {
      setState(() => _driverTrip = trip);
    }
  }

  @override
  void didUpdateWidget(covariant AuthenticatedHomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.accessContext.accountRoles.contains(_selectedRole)) {
      _selectedRole = _availableRoles.firstOrNull;
    }
  }

  List<AccountRole> get _availableRoles => AccountRole.values
      .where(widget.accessContext.accountRoles.contains)
      .toList();

  Future<void> _handleSignOut() async {
    if (_isSigningOut) return;

    setState(() => _isSigningOut = true);

    try {
      await widget.authService.signOut();
    } catch (error) {
      if (!mounted) return;

      setState(() => _isSigningOut = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AuthErrorMapper.message(error)),
          backgroundColor: AppColors.errorRed,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = widget.authService.currentSession?.user;
    final accountLabel = user?.email ?? user?.id ?? 'Conta autenticada';
    final availableRoles = _availableRoles;
    final selectedRole = _selectedRole;
    final contentTitle = selectedRole == null
        ? _setupMessage(widget.accessContext.onboardingIntent)
        : _roleTitle(selectedRole);

    final isDriver = selectedRole == AccountRole.driver ||
        (selectedRole == null &&
            widget.accessContext.onboardingIntent == OnboardingIntent.driver);

    return Scaffold(
      backgroundColor: AppColors.backgroundWhite,
      appBar: AppBar(title: const Text('VanGo')),
      body: SafeArea(
        child: SingleChildScrollView(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      contentTitle,
                      textAlign: TextAlign.center,
                      style: AppTextStyles.heading2,
                    ),
                    const SizedBox(height: 8),
                    Text(accountLabel, style: AppTextStyles.bodyMedium),
                    if (availableRoles.length > 1) ...[
                      const SizedBox(height: 20),
                      Semantics(
                        label: 'Perfil de acesso',
                        child: DropdownButton<AccountRole>(
                          value: selectedRole,
                          items: availableRoles.map((role) {
                            return DropdownMenuItem(
                              value: role,
                              child: Text(_roleLabel(role)),
                            );
                          }).toList(),
                          onChanged: (role) {
                            if (role != null) setState(() => _selectedRole = role);
                          },
                        ),
                      ),
                    ],
                    if (isDriver && _driverTrip != null) ...[
                      const SizedBox(height: 24),
                      DriverTripCard(
                        trip: _driverTrip!,
                        onViewRoute: () async {
                          await Navigator.pushNamed(context, AppRoutes.driverRoute);
                          _loadDriverTrip();
                        },
                      ),
                    ],
                    const SizedBox(height: 28),
                    VanGoButton(
                      text: 'Sair',
                      isLoading: _isSigningOut,
                      onPressed: _handleSignOut,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String _setupMessage(OnboardingIntent? intent) {
  return switch (intent) {
    OnboardingIntent.fleetOwner => 'Configure sua frota',
    OnboardingIntent.driver => 'Aguarde ou aceite um convite da frota',
    OnboardingIntent.guardian => 'Cadastre o aluno sob sua responsabilidade',
    OnboardingIntent.adultStudent => 'Complete seus dados de aluno',
    null => 'Complete a configuração da sua conta',
  };
}

String _roleTitle(AccountRole role) {
  return switch (role) {
    AccountRole.owner => 'Painel da frota',
    AccountRole.driver => 'Minhas viagens',
    AccountRole.guardian => 'Meus alunos',
    AccountRole.student => 'Meu transporte',
  };
}

String _roleLabel(AccountRole role) {
  return switch (role) {
    AccountRole.owner => 'Frota',
    AccountRole.driver => 'Motorista',
    AccountRole.guardian => 'Responsável',
    AccountRole.student => 'Aluno',
  };
}
