import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../shared/widgets/vango_button.dart';
import '../models/driver_trip.dart';
import '../models/route_stop.dart';

class DriverActiveTripPanel extends StatelessWidget {
  const DriverActiveTripPanel({
    super.key,
    required this.trip,
    required this.onBoardStop,
    required this.onMarkAbsent,
    required this.onFinishTrip,
  });

  final DriverTrip trip;
  final ValueChanged<RouteStop> onBoardStop;
  final ValueChanged<RouteStop> onMarkAbsent;
  final VoidCallback onFinishTrip;

  @override
  Widget build(BuildContext context) {
    final nextStop = trip.nextPendingStop;
    final isDestination = nextStop?.isSchoolDestination ?? false;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: const BoxDecoration(
        color: AppColors.cardBackground,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        boxShadow: [
          BoxShadow(
            color: AppColors.shadowMedium,
            blurRadius: 20,
            offset: Offset(0, -4),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Drag handle
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: AppColors.inputBorder,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),

            // Header info
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: AppColors.primaryOrange.withValues(alpha: 0.15),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.navigation_rounded,
                        color: AppColors.primaryOrangeDark,
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          isDestination ? 'Destino Final' : 'Próxima Parada',
                          style: AppTextStyles.caption.copyWith(
                            color: AppColors.textMuted,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          nextStop?.name ?? 'Todas as paradas concluídas',
                          style: AppTextStyles.heading3.copyWith(fontSize: 18),
                        ),
                      ],
                    ),
                  ],
                ),
                Text(
                  nextStop?.scheduledTime ?? '',
                  style: AppTextStyles.bodyLarge.copyWith(
                    fontWeight: FontWeight.bold,
                    color: AppColors.primaryOrangeDark,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),

            if (nextStop != null) ...[
              Padding(
                padding: const EdgeInsets.only(left: 38),
                child: Text(
                  nextStop.address,
                  style: AppTextStyles.bodySmall.copyWith(
                    color: AppColors.textMuted,
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],

            // Progress info
            LinearProgressIndicator(
              value: trip.stops.isEmpty
                  ? 0
                  : trip.completedStudentsCount / trip.totalStudents,
              backgroundColor: AppColors.inputBorder.withValues(alpha: 0.6),
              valueColor: const AlwaysStoppedAnimation<Color>(
                AppColors.primaryOrange,
              ),
              borderRadius: BorderRadius.circular(4),
              minHeight: 6,
            ),
            const SizedBox(height: 8),
            Text(
              '${trip.completedStudentsCount} de ${trip.totalStudents} alunos embarcados',
              style: AppTextStyles.caption.copyWith(
                color: AppColors.textMuted,
              ),
            ),
            const SizedBox(height: 20),

            // Action buttons
            if (nextStop != null && !isDestination) ...[
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => onMarkAbsent(nextStop),
                      icon: const Icon(
                        Icons.person_off_outlined,
                        size: 18,
                        color: AppColors.errorRed,
                      ),
                      label: const Text(
                        'Ausente',
                        style: TextStyle(
                          color: AppColors.errorRed,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: AppColors.errorRed),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: VanGoButton(
                      text: 'Confirmar Embarque',
                      onPressed: () => onBoardStop(nextStop),
                    ),
                  ),
                ],
              ),
            ] else if (isDestination || nextStop == null) ...[
              VanGoButton(
                text: 'Chegada na Escola / Finalizar',
                onPressed: onFinishTrip,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
