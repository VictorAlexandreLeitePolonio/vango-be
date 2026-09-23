import 'package:flutter/material.dart';

import '../../../core/routes/app_routes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../shared/widgets/vango_button.dart';
import '../models/student_models.dart';
import '../services/student_service.dart';
import '../widgets/join_request_dialog.dart';

class VansMarketplaceScreen extends StatefulWidget {
  const VansMarketplaceScreen({
    super.key,
    this.studentService,
  });

  final StudentService? studentService;

  @override
  State<VansMarketplaceScreen> createState() => _VansMarketplaceScreenState();
}

class _VansMarketplaceScreenState extends State<VansMarketplaceScreen> {
  late final StudentService _studentService;
  List<AvailableVanFleet> _vans = [];
  List<StudentProfile> _students = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _studentService = widget.studentService ?? StudentService();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    final vans = await _studentService.getAvailableVans();
    final students = await _studentService.getMyStudents();
    if (!mounted) return;
    setState(() {
      _vans = vans;
      _students = students;
      _isLoading = false;
    });
  }

  void _openJoinModal(AvailableVanFleet van) async {
    if (_students.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Cadastre um aluno antes de solicitar vaga na van.'),
          backgroundColor: AppColors.primaryOrangeDark,
          action: SnackBarAction(
            label: 'Cadastrar',
            textColor: Colors.white,
            onPressed: () async {
              await Navigator.pushNamed(context, AppRoutes.studentRegister);
              _loadData();
            },
          ),
        ),
      );
      return;
    }

    final sent = await showDialog<bool>(
      context: context,
      builder: (_) => JoinRequestDialog(
        van: van,
        students: _students,
        studentService: _studentService,
      ),
    );

    if (sent == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Solicitação enviada com sucesso ao dono da frota!'),
          backgroundColor: AppColors.successGreen,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.backgroundWhite,
      appBar: AppBar(
        title: const Text('Vans Disponíveis'),
        backgroundColor: Colors.transparent,
        actions: [
          IconButton(
            icon: const Icon(Icons.person_add_alt_1_rounded),
            tooltip: 'Cadastrar Aluno',
            onPressed: () async {
              await Navigator.pushNamed(context, AppRoutes.studentRegister);
              _loadData();
            },
          ),
        ],
      ),
      body: _isLoading
          ? const Center(
              child: CircularProgressIndicator(color: AppColors.primaryOrange),
            )
          : SafeArea(
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  // Banner informativo
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: AppColors.primaryGold.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: AppColors.primaryGold.withValues(alpha: 0.5),
                      ),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.verified_outlined,
                          color: AppColors.primaryOrangeDark,
                          size: 24,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'Encontre a melhor van escolar para a sua região e solicite a entrada do seu aluno.',
                            style: AppTextStyles.caption.copyWith(
                              color: AppColors.textDark,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),

                  Text(
                    'Vans Ativas em São Paulo',
                    style: AppTextStyles.heading3,
                  ),
                  const SizedBox(height: 12),

                  if (_vans.isEmpty)
                    const Center(
                      child: Padding(
                        padding: EdgeInsets.all(32),
                        child: Text('Nenhuma van disponível no momento.'),
                      ),
                    )
                  else
                    ..._vans.map((van) => _buildVanCard(van)),
                ],
              ),
            ),
    );
  }

  Widget _buildVanCard(AvailableVanFleet van) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: AppColors.cardBackground,
        borderRadius: BorderRadius.circular(20),
        boxShadow: const [
          BoxShadow(
            color: AppColors.shadowLight,
            blurRadius: 14,
            offset: Offset(0, 4),
          ),
        ],
        border: Border.all(color: AppColors.inputBorder.withValues(alpha: 0.6)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: AppColors.primaryOrange.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(14),
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
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              van.vanPublicName,
                              style: AppTextStyles.heading3.copyWith(fontSize: 18),
                            ),
                            Text(
                              '${van.vanModel} • Placa ${van.vanPlate}',
                              style: AppTextStyles.caption.copyWith(
                                color: AppColors.textMuted,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppColors.successGreen.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    'Disponível',
                    style: AppTextStyles.caption.copyWith(
                      color: AppColors.successGreen,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            const Divider(height: 1, color: AppColors.inputBorder),
            const SizedBox(height: 14),

            // Frota e Escola
            Row(
              children: [
                const Icon(Icons.business_outlined, size: 16, color: AppColors.textMuted),
                const SizedBox(width: 6),
                Text(
                  'Frota: ${van.fleetName}',
                  style: AppTextStyles.bodySmall.copyWith(fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                const Icon(Icons.airline_seat_recline_normal_rounded, size: 16, color: AppColors.textMuted),
                const SizedBox(width: 4),
                Text(
                  '${van.capacity} lugares',
                  style: AppTextStyles.caption.copyWith(color: AppColors.textMuted),
                ),
              ],
            ),
            const SizedBox(height: 8),

            Row(
              children: [
                const Icon(Icons.school_outlined, size: 16, color: AppColors.primaryOrangeDark),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Atende: ${van.schoolName}',
                    style: AppTextStyles.bodySmall.copyWith(
                      color: AppColors.textDark,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),

            // Botão "Desejo entrar nesta van"
            VanGoButton(
              text: 'Desejo entrar nesta van',
              onPressed: () => _openJoinModal(van),
            ),
          ],
        ),
      ),
    );
  }
}
