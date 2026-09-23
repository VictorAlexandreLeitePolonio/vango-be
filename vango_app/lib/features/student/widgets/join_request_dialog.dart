import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../shared/widgets/vango_button.dart';
import '../models/student_models.dart';
import '../services/student_service.dart';

class JoinRequestDialog extends StatefulWidget {
  const JoinRequestDialog({
    super.key,
    required this.van,
    required this.students,
    required this.studentService,
  });

  final AvailableVanFleet van;
  final List<StudentProfile> students;
  final StudentService studentService;

  @override
  State<JoinRequestDialog> createState() => _JoinRequestDialogState();
}

class _JoinRequestDialogState extends State<JoinRequestDialog> {
  StudentProfile? _selectedStudent;
  String _selectedShift = 'morning';
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    _selectedStudent = widget.students.firstOrNull;
  }

  Future<void> _handleConfirm() async {
    final student = _selectedStudent;
    if (student == null) return;

    setState(() => _isSubmitting = true);

    try {
      await widget.studentService.submitJoinRequest(
        fleetId: widget.van.fleetId,
        studentId: student.id,
        schoolId: widget.van.schoolId,
        shift: _selectedShift,
      );

      if (!mounted) return;
      setState(() => _isSubmitting = false);
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _isSubmitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Erro ao enviar solicitação: $e'),
          backgroundColor: AppColors.errorRed,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      backgroundColor: AppColors.cardBackground,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppColors.primaryGold.withValues(alpha: 0.25),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.airport_shuttle_rounded,
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
                        'Solicitar Vaga',
                        style: AppTextStyles.heading3.copyWith(fontSize: 18),
                      ),
                      Text(
                        widget.van.vanPublicName,
                        style: AppTextStyles.bodySmall.copyWith(
                          color: AppColors.textMuted,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),

            // Aluno
            Text(
              'Selecione o Aluno:',
              style: AppTextStyles.bodyMedium.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppColors.inputBorder),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<StudentProfile>(
                  value: _selectedStudent,
                  isExpanded: true,
                  items: widget.students.map((st) {
                    return DropdownMenuItem(
                      value: st,
                      child: Text(st.fullName),
                    );
                  }).toList(),
                  onChanged: (st) {
                    if (st != null) setState(() => _selectedStudent = st);
                  },
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Turno
            Text(
              'Turno:',
              style: AppTextStyles.bodyMedium.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppColors.inputBorder),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: _selectedShift,
                  isExpanded: true,
                  items: const [
                    DropdownMenuItem(value: 'morning', child: Text('Manhã')),
                    DropdownMenuItem(value: 'afternoon', child: Text('Tarde')),
                    DropdownMenuItem(value: 'full_day', child: Text('Integral')),
                  ],
                  onChanged: (shift) {
                    if (shift != null) setState(() => _selectedShift = shift);
                  },
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Escola
            Text(
              'Escola de Destino:',
              style: AppTextStyles.bodyMedium.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                const Icon(Icons.school_outlined, size: 18, color: AppColors.textMuted),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    widget.van.schoolName,
                    style: AppTextStyles.bodySmall.copyWith(color: AppColors.textDark),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),

            // Ações
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    style: OutlinedButton.styleFrom(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: const Text('Cancelar'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: VanGoButton(
                    text: 'Confirmar Pedido',
                    isLoading: _isSubmitting,
                    onPressed: _handleConfirm,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
