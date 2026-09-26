import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../auth/services/auth_service.dart';
import '../services/fleet_service.dart';
import '../services/fleet_student_error_mapper.dart';
import '../models/fleet_student_submission_state.dart';
import 'fleet_student_registration_screen.dart';

/// Owner dashboard bound to a fleet and the session that opened the route.
class FleetOwnerDashboardScreen extends StatefulWidget {
  const FleetOwnerDashboardScreen({
    super.key,
    this.fleetService,
    required this.fleetId,
    required this.userId,
    required this.authService,
  });

  final FleetService? fleetService;
  final String fleetId;
  final String userId;
  final AuthService authService;

  @override
  State<FleetOwnerDashboardScreen> createState() =>
      _FleetOwnerDashboardScreenState();
}

class _FleetOwnerDashboardScreenState extends State<FleetOwnerDashboardScreen>
    with SingleTickerProviderStateMixin {
  late final FleetService _fleetService;
  late final TabController _tabController;
  StreamSubscription<AuthState>? _authSubscription;
  int _requestId = 0;
  int _contextEpoch = 0;
  bool _committedRefresh = false;
  late FleetStudentSubmissionState _submission;

  List<PendingJoinRequest> _pendingRequests = [];
  List<FleetMemberDriver> _drivers = [];
  List<OwnerEnrolledStudent> _enrolledStudents = [];
  bool _isLoading = true;
  final _sectionLoading = [true, true, true];
  final _sectionErrors = [false, false, false];
  final _sectionGenerations = [0, 0, 0];
  bool _isDenied = false;
  bool _hasError = false;

  @override
  void initState() {
    super.initState();
    _fleetService = widget.fleetService ?? FleetService();
    _tabController = TabController(length: 3, vsync: this);
    _submission = FleetStudentSubmissionState(
      userId: widget.userId,
      fleetId: widget.fleetId,
    );
    _subscribeToAuth();
    unawaited(_checkAccess());
  }

  void _subscribeToAuth() {
    _authSubscription = widget.authService.authStateChanges.listen((state) {
      if (state.event == AuthChangeEvent.signedOut ||
          state.session?.user.id != widget.userId) {
        _denyAccess();
      } else {
        unawaited(_checkAccess());
      }
    });
  }

  @override
  void didUpdateWidget(covariant FleetOwnerDashboardScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.authService != widget.authService) {
      _authSubscription?.cancel();
      _subscribeToAuth();
    }
    if (oldWidget.fleetId != widget.fleetId ||
        oldWidget.userId != widget.userId ||
        oldWidget.authService != widget.authService) {
      _submission.invalidate();
      _committedRefresh = false;
      _contextEpoch++;
      _submission = FleetStudentSubmissionState(
        userId: widget.userId,
        fleetId: widget.fleetId,
      );
      unawaited(_checkAccess());
    }
  }

  @override
  void dispose() {
    _requestId += 1;
    _authSubscription?.cancel();
    _tabController.dispose();
    super.dispose();
  }

  void _clearData() {
    _pendingRequests = [];
    _drivers = [];
    _enrolledStudents = [];
  }

  void _denyAccess() {
    _requestId += 1;
    _contextEpoch++;
    _committedRefresh = false;
    _submission.invalidate();
    if (!mounted) return;
    setState(() {
      _clearData();
      _isLoading = false;
      _isDenied = true;
      _hasError = false;
    });
  }

  bool _isCurrent(int requestId) =>
      mounted &&
      requestId == _requestId &&
      widget.authService.currentSession?.user.id == widget.userId;

  Future<void> _checkAccess() async {
    final requestId = ++_requestId;
    if (widget.authService.currentSession?.user.id != widget.userId) {
      _denyAccess();
      return;
    }
    setState(() {
      _clearData();
      _isLoading = true;
      _isDenied = false;
      _hasError = false;
    });
    try {
      final access = await widget.authService.getMyAccessContext();
      if (!_isCurrent(requestId)) return;
      if (!access.ownerFleetIds.contains(widget.fleetId)) {
        _denyAccess();
        return;
      }
      await _loadData(requestId);
    } catch (_) {
      if (!_isCurrent(requestId)) return;
      setState(() {
        _clearData();
        _isLoading = false;
        _hasError = true;
      });
    }
  }

  Future<void> _loadData(int requestId) async {
    setState(() => _isLoading = false);
    await Future.wait([
      _loadSection(
        0,
        requestId,
        () => _fleetService.getPendingRequests(widget.fleetId),
        (rows) => _pendingRequests = rows,
      ),
      _loadSection(
        1,
        requestId,
        () => _fleetService.getFleetDrivers(widget.fleetId),
        (rows) => _drivers = rows,
      ),
      _loadSection(
        2,
        requestId,
        () => _fleetService.getOwnerEnrolledStudents(widget.fleetId),
        (rows) => _enrolledStudents = rows,
      ),
    ]);
  }

  Future<void> _loadSection<T>(
    int section,
    int requestId,
    Future<List<T>> Function() read,
    void Function(List<T>) apply,
  ) async {
    final generation = ++_sectionGenerations[section];
    setState(() {
      _sectionLoading[section] = true;
      _sectionErrors[section] = false;
    });
    try {
      final rows = await read();
      if (!_isCurrent(requestId) ||
          generation != _sectionGenerations[section]) {
        return;
      }
      setState(() {
        apply(rows);
        _sectionLoading[section] = false;
      });
    } catch (error) {
      if (!_isCurrent(requestId) ||
          generation != _sectionGenerations[section]) {
        return;
      }
      if (FleetStudentErrorMapper.classifyWriteFailure(error) ==
          FleetStudentWriteFailureKind.accessUnavailable) {
        _denyAccess();
        return;
      }
      setState(() {
        _sectionErrors[section] = true;
        _sectionLoading[section] = false;
      });
    }
  }

  Widget _section(int index, Widget Function() content) {
    if (_sectionLoading[index]) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_sectionErrors[index]) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              index == 2 && _committedRefresh
                  ? 'Aluno cadastrado. Não foi possível atualizar a lista. Tente novamente.'
                  : 'Não foi possível carregar a frota',
            ),
            ElevatedButton(
              onPressed: index == 2 ? _refreshStudents : _checkAccess,
              child: const Text('Tentar novamente'),
            ),
          ],
        ),
      );
    }
    return content();
  }

  Future<void> _handleDecision(String requestId, bool approve) async {
    final requestIdAtStart = _requestId;
    if (!_isCurrent(requestIdAtStart) || _isDenied) return;
    try {
      final access = await widget.authService.getMyAccessContext();
      if (!_isCurrent(requestIdAtStart)) return;
      if (!access.ownerFleetIds.contains(widget.fleetId)) {
        _denyAccess();
        return;
      }
      await _fleetService.decideRequest(requestId, approve);
      if (!_isCurrent(requestIdAtStart)) return;
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            approve
                ? 'Aluno aprovado e adicionado à frota!'
                : 'Solicitação recusada.',
          ),
          backgroundColor: approve
              ? AppColors.successGreen
              : AppColors.errorRed,
          behavior: SnackBarBehavior.floating,
        ),
      );
      unawaited(_checkAccess());
    } catch (_) {
      if (!_isCurrent(requestIdAtStart)) return;
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Não foi possível atualizar a solicitação'),
          backgroundColor: AppColors.errorRed,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isDenied) {
      return const Scaffold(
        body: Center(child: Text('Acesso à frota indisponível')),
      );
    }
    if (_hasError) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Não foi possível carregar a frota'),
              ElevatedButton(
                onPressed: _checkAccess,
                child: const Text('Tentar novamente'),
              ),
            ],
          ),
        ),
      );
    }
    return Scaffold(
      backgroundColor: AppColors.backgroundWhite,
      appBar: AppBar(
        title: const Text('Gestão da Frota'),
        backgroundColor: Colors.transparent,
        bottom: TabBar(
          controller: _tabController,
          labelColor: AppColors.primaryOrangeDark,
          unselectedLabelColor: AppColors.textMuted,
          indicatorColor: AppColors.primaryOrange,
          tabs: [
            Tab(
              text: 'Pedidos (${_pendingRequests.length})',
              icon: const Icon(Icons.notifications_active_outlined, size: 20),
            ),
            const Tab(
              text: 'Equipe',
              icon: Icon(Icons.directions_bus_outlined, size: 20),
            ),
            Tab(
              text: 'Alunos (${_enrolledStudents.length})',
              icon: const Icon(Icons.people_outline_rounded, size: 20),
            ),
          ],
        ),
      ),
      body: _isLoading
          ? const Center(
              child: CircularProgressIndicator(color: AppColors.primaryOrange),
            )
          : TabBarView(
              controller: _tabController,
              children: [
                _section(0, _buildRequestsTab),
                _section(1, _buildFleetTeamTab),
                _section(2, _buildEnrolledStudentsTab),
              ],
            ),
    );
  }

  Widget _buildRequestsTab() {
    if (_pendingRequests.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.check_circle_outline_rounded,
                size: 48,
                color: AppColors.successGreen,
              ),
              SizedBox(height: 12),
              Text(
                'Nenhuma solicitação pendente no momento.',
                style: TextStyle(color: AppColors.textMuted),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(20),
      itemCount: _pendingRequests.length,
      itemBuilder: (context, index) {
        final req = _pendingRequests[index];
        return Container(
          margin: const EdgeInsets.only(bottom: 16),
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: AppColors.cardBackground,
            borderRadius: BorderRadius.circular(20),
            boxShadow: const [
              BoxShadow(
                color: AppColors.shadowLight,
                blurRadius: 12,
                offset: Offset(0, 4),
              ),
            ],
            border: Border.all(
              color: AppColors.primaryOrange.withValues(alpha: 0.35),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    req.studentFullName,
                    style: AppTextStyles.heading3.copyWith(fontSize: 17),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.primaryGold.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      'Turno ${req.shift}',
                      style: AppTextStyles.caption.copyWith(
                        color: AppColors.primaryOrangeDark,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),

              Row(
                children: [
                  const Icon(
                    Icons.location_on_outlined,
                    size: 16,
                    color: AppColors.textMuted,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      req.fullAddress,
                      style: AppTextStyles.bodySmall.copyWith(
                        color: AppColors.textMuted,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),

              Row(
                children: [
                  const Icon(
                    Icons.school_outlined,
                    size: 16,
                    color: AppColors.textMuted,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      'Destino: ${req.schoolName}',
                      style: AppTextStyles.bodySmall.copyWith(
                        color: AppColors.textDark,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => _handleDecision(req.id, false),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: AppColors.errorRed),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Text(
                        'Recusar',
                        style: TextStyle(color: AppColors.errorRed),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: ElevatedButton(
                      onPressed: () => _handleDecision(req.id, true),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.successGreen,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      child: const Text(
                        'Aprovar Entrada',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildFleetTeamTab() {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text('Motoristas Vinculados', style: AppTextStyles.heading3),
        const SizedBox(height: 10),
        ..._drivers.map((driver) {
          return Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.cardBackground,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.inputBorder),
            ),
            child: Row(
              children: [
                const CircleAvatar(
                  backgroundColor: AppColors.primaryNavy,
                  child: Icon(Icons.person, color: Colors.white),
                ),
                const SizedBox(width: 14),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      driver.name,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    Text(
                      driver.email,
                      style: const TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 12,
                      ),
                    ),
                    Text(
                      driver.status,
                      style: const TextStyle(
                        color: AppColors.successGreen,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          );
        }),
      ],
    );
  }

  Future<void> _openRegistration() async {
    final epoch = _contextEpoch;
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => FleetStudentRegistrationScreen(
          fleetId: widget.fleetId,
          userId: widget.userId,
          authService: widget.authService,
          fleetService: _fleetService,
          submissionState: _submission,
        ),
      ),
    );
    if (!mounted ||
        epoch != _contextEpoch ||
        widget.authService.currentSession?.user.id != widget.userId) {
      return;
    }
    if (result == true && _submission.receipt != null) {
      _committedRefresh = true;
      await _refreshStudents();
    }
    if (mounted) setState(() {});
  }

  Future<void> _refreshStudents() async {
    final epoch = _contextEpoch;
    try {
      final access = await widget.authService.getMyAccessContext();
      if (!mounted ||
          epoch != _contextEpoch ||
          widget.authService.currentSession?.user.id != widget.userId) {
        return;
      }
      if (!access.ownerFleetIds.contains(widget.fleetId)) {
        _denyAccess();
        return;
      }
      await _loadSection(
        2,
        _requestId,
        () => _fleetService.getOwnerEnrolledStudents(widget.fleetId),
        (rows) => _enrolledStudents = rows,
      );
      if (!mounted || epoch != _contextEpoch) return;
      if (!_sectionErrors[2] && !_sectionLoading[2] && _committedRefresh) {
        setState(() {
          _committedRefresh = false;
          _submission = FleetStudentSubmissionState(
            userId: widget.userId,
            fleetId: widget.fleetId,
          );
        });
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Aluno cadastrado.')));
      }
    } catch (_) {
      if (!mounted || epoch != _contextEpoch) return;
      setState(() {
        _sectionErrors[2] = true;
        _sectionLoading[2] = false;
      });
    }
  }

  Widget _buildEnrolledStudentsTab() => Column(
    children: [
      Padding(
        padding: const EdgeInsets.all(16),
        child: ElevatedButton(
          onPressed: _openRegistration,
          child: Text(
            _submission.phase == FleetStudentSubmissionPhase.unknown
                ? 'Retomar confirmação do cadastro'
                : 'Cadastrar aluno',
          ),
        ),
      ),
      Expanded(child: _buildStudentList()),
    ],
  );

  Widget _buildStudentList() {
    if (_enrolledStudents.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.people_outline_rounded,
                size: 48,
                color: AppColors.textMuted,
              ),
              SizedBox(height: 12),
              Text(
                'Nenhum aluno matriculado na frota ainda.',
                style: TextStyle(color: AppColors.textMuted),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(20),
      itemCount: _enrolledStudents.length,
      itemBuilder: (context, index) {
        final st = _enrolledStudents[index];
        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.cardBackground,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.inputBorder),
          ),
          child: Row(
            children: [
              CircleAvatar(
                backgroundColor: AppColors.primaryOrange.withValues(
                  alpha: 0.15,
                ),
                child: Text(
                  '${index + 1}',
                  style: const TextStyle(
                    color: AppColors.primaryOrangeDark,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      st.fullName,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                    ),
                    Text(
                      st.address,
                      style: const TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
