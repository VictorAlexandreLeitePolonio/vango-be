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
  String? _selectedFleetId;
  late final DriverRouteService _driverRouteService;
  DriverTrip? _driverTrip;

  @override
  void initState() {
    super.initState();
    _selectedRole = _availableRoles.firstOrNull;
    _selectedFleetId = widget.accessContext.ownerFleetIds.singleOrNull;
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
    final ownerFleetIds = widget.accessContext.ownerFleetIds;
    if (!ownerFleetIds.contains(_selectedFleetId)) {
      _selectedFleetId = ownerFleetIds.singleOrNull;
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
    final ownerFleetIds = widget.accessContext.ownerFleetIds;
    final contentTitle = selectedRole == null
        ? _setupMessage(widget.accessContext.onboardingIntent)
        : _roleTitle(selectedRole);

    final isDriver =
        selectedRole == AccountRole.driver ||
        (selectedRole == null &&
            widget.accessContext.onboardingIntent == OnboardingIntent.driver);

    final isFleetOwner =
        selectedRole == AccountRole.owner ||
        (selectedRole == null &&
            widget.accessContext.onboardingIntent ==
                OnboardingIntent.fleetOwner);

    final isGuardianOrStudent =
        selectedRole == AccountRole.guardian ||
        selectedRole == AccountRole.student ||
        (selectedRole == null &&
            (widget.accessContext.onboardingIntent ==
                    OnboardingIntent.guardian ||
                widget.accessContext.onboardingIntent ==
                    OnboardingIntent.adultStudent));

    return Scaffold(
      backgroundColor: AppColors.backgroundWhite,
      appBar: AppBar(title: const Text('VanGo')),
      body: SafeArea(
        child: SingleChildScrollView(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 20,
                ),
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
                            if (role != null) {
                              setState(() => _selectedRole = role);
                            }
                          },
                        ),
                      ),
                    ],
                    if (isDriver && _driverTrip != null) ...[
                      const SizedBox(height: 24),
                      DriverTripCard(
                        trip: _driverTrip!,
                        onViewRoute: () async {
                          await Navigator.pushNamed(
                            context,
                            AppRoutes.driverRoute,
                          );
                          _loadDriverTrip();
                        },
                      ),
                    ],
                    if (isFleetOwner) ...[
                      const SizedBox(height: 24),
                      Container(
                        padding: const EdgeInsets.all(22),
                        decoration: BoxDecoration(
                          color: AppColors.cardBackground,
                          borderRadius: BorderRadius.circular(24),
                          boxShadow: const [
                            BoxShadow(
                              color: AppColors.shadowLight,
                              blurRadius: 16,
                              offset: Offset(0, 4),
                            ),
                          ],
                          border: Border.all(
                            color: AppColors.primaryOrange.withValues(
                              alpha: 0.3,
                            ),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(10),
                                  decoration: BoxDecoration(
                                    color: AppColors.primaryOrange.withValues(
                                      alpha: 0.12,
                                    ),
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(
                                    Icons.admin_panel_settings_outlined,
                                    color: AppColors.primaryOrangeDark,
                                    size: 24,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Painel da Frota',
                                        style: AppTextStyles.heading3.copyWith(
                                          fontSize: 18,
                                        ),
                                      ),
                                      Text(
                                        'Aprove pedidos e veja sua equipe',
                                        style: AppTextStyles.caption.copyWith(
                                          color: AppColors.textMuted,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 18),
                            if (ownerFleetIds.isEmpty)
                              const Text('Nenhuma frota disponível para gestão')
                            else ...[
                              if (ownerFleetIds.length > 1) ...[
                                DropdownButton<String>(
                                  hint: const Text('Selecione uma frota'),
                                  value: _selectedFleetId,
                                  items: ownerFleetIds
                                      .map(
                                        (fleetId) => DropdownMenuItem(
                                          value: fleetId,
                                          child: Text(fleetId),
                                        ),
                                      )
                                      .toList(),
                                  onChanged: (fleetId) => setState(
                                    () => _selectedFleetId = fleetId,
                                  ),
                                ),
                                const SizedBox(height: 12),
                              ],
                              VanGoButton(
                                text: 'Acessar Gestão da Frota',
                                onPressed: _selectedFleetId == null
                                    ? null
                                    : () {
                                        final userId = widget
                                            .authService
                                            .currentSession
                                            ?.user
                                            .id;
                                        final fleetId = _selectedFleetId;
                                        if (userId == null ||
                                            fleetId == null ||
                                            !widget.accessContext.ownerFleetIds
                                                .contains(fleetId)) {
                                          return;
                                        }
                                        final OwnerFleetRouteArguments
                                        arguments = (
                                          fleetId: fleetId,
                                          userId: userId,
                                        );
                                        Navigator.pushNamed(
                                          context,
                                          AppRoutes.fleetDashboard,
                                          arguments: arguments,
                                        );
                                      },
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                    if (isGuardianOrStudent) ...[
                      const SizedBox(height: 24),
                      Container(
                        padding: const EdgeInsets.all(22),
                        decoration: BoxDecoration(
                          color: AppColors.cardBackground,
                          borderRadius: BorderRadius.circular(24),
                          boxShadow: const [
                            BoxShadow(
                              color: AppColors.shadowLight,
                              blurRadius: 16,
                              offset: Offset(0, 4),
                            ),
                          ],
                          border: Border.all(
                            color: AppColors.inputBorder.withValues(alpha: 0.8),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(10),
                                  decoration: BoxDecoration(
                                    color: AppColors.primaryGold.withValues(
                                      alpha: 0.25,
                                    ),
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(
                                    Icons.directions_bus_rounded,
                                    color: AppColors.primaryOrangeDark,
                                    size: 24,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Transporte Escolar',
                                        style: AppTextStyles.heading3.copyWith(
                                          fontSize: 18,
                                        ),
                                      ),
                                      Text(
                                        'Encontre vans ou gerencie alunos',
                                        style: AppTextStyles.caption.copyWith(
                                          color: AppColors.textMuted,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 18),
                            VanGoButton(
                              text: 'Buscar Vans Disponíveis',
                              onPressed: () {
                                Navigator.pushNamed(
                                  context,
                                  AppRoutes.vansMarketplace,
                                );
                              },
                            ),
                            const SizedBox(height: 12),
                            VanGoButton(
                              text: 'Cadastrar Novo Aluno',
                              isOutlined: true,
                              onPressed: () {
                                Navigator.pushNamed(
                                  context,
                                  AppRoutes.studentRegister,
                                );
                              },
                            ),
                          ],
                        ),
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
