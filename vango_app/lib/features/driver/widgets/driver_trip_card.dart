import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_text_styles.dart';
import '../models/driver_trip.dart';

class DriverTripCard extends StatelessWidget {
  const DriverTripCard({
    super.key,
    required this.trip,
    required this.onViewRoute,
  });

  final DriverTrip trip;
  final VoidCallback onViewRoute;

  @override
  Widget build(BuildContext context) {
    final isTripActive = trip.status == TripStatus.inProgress;
    final isTripCompleted = trip.status == TripStatus.completed;

    return Container(
      decoration: BoxDecoration(
        color: AppColors.cardBackground,
        borderRadius: BorderRadius.circular(24),
        boxShadow: const [
          BoxShadow(
            color: AppColors.shadowMedium,
            blurRadius: 18,
            offset: Offset(0, 6),
          ),
        ],
        border: Border.all(
          color: isTripActive
              ? AppColors.primaryOrange
              : AppColors.inputBorder.withValues(alpha: 0.6),
          width: isTripActive ? 2 : 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Status and Shift Badge
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppColors.primaryGold.withValues(alpha: 0.25),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.wb_sunny_rounded,
                        size: 14,
                        color: AppColors.primaryOrangeDark,
                      ),
                      const SizedBox(width: 5),
                      Text(
                        'Hoje • ${trip.shift}',
                        style: AppTextStyles.caption.copyWith(
                          color: AppColors.primaryOrangeDark,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
                _buildStatusBadge(isTripActive, isTripCompleted),
              ],
            ),
            const SizedBox(height: 14),

            // Title and Van info
            Text(
              trip.title,
              style: AppTextStyles.heading3,
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                const Icon(
                  Icons.airport_shuttle_rounded,
                  size: 16,
                  color: AppColors.textMuted,
                ),
                const SizedBox(width: 6),
                Text(
                  'Van ${trip.vanPlate}',
                  style: AppTextStyles.bodySmall.copyWith(
                    color: AppColors.textMuted,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),

            const Divider(color: AppColors.inputBorder, height: 1),
            const SizedBox(height: 16),

            // Route Highlights Summary
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildMetric(
                  icon: Icons.people_outline_rounded,
                  value: '${trip.totalStudents}',
                  label: 'Alunos',
                ),
                Container(
                  width: 1,
                  height: 36,
                  color: AppColors.inputBorder.withValues(alpha: 0.8),
                ),
                _buildMetric(
                  icon: Icons.school_outlined,
                  value: '1',
                  label: 'Destino',
                ),
                Container(
                  width: 1,
                  height: 36,
                  color: AppColors.inputBorder.withValues(alpha: 0.8),
                ),
                _buildMetric(
                  icon: Icons.route_outlined,
                  value: trip.formattedDistance != '-- km'
                      ? trip.formattedDistance
                      : '~7.4 km',
                  label: 'Distância',
                ),
              ],
            ),
            const SizedBox(height: 20),

            // Primary Action Button
            SizedBox(
              width: double.infinity,
              height: 50,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: AppColors.primaryGradient,
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: const [
                    BoxShadow(
                      color: AppColors.shadowLight,
                      blurRadius: 10,
                      offset: Offset(0, 4),
                    ),
                  ],
                ),
                child: ElevatedButton.icon(
                  onPressed: onViewRoute,
                  icon: const Icon(
                    Icons.map_rounded,
                    color: Colors.white,
                    size: 20,
                  ),
                  label: Text(
                    isTripActive ? 'Continuar Percurso' : 'Ver rota do dia',
                    style: AppTextStyles.buttonLarge.copyWith(
                      color: Colors.white,
                      fontSize: 16,
                    ),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.transparent,
                    shadowColor: Colors.transparent,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusBadge(bool isActive, bool isCompleted) {
    if (isActive) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: AppColors.primaryOrange.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: const BoxDecoration(
                color: AppColors.primaryOrange,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              'Em andamento',
              style: AppTextStyles.caption.copyWith(
                color: AppColors.primaryOrangeDark,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      );
    }

    if (isCompleted) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: AppColors.successGreen.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          'Concluída',
          style: AppTextStyles.caption.copyWith(
            color: AppColors.successGreen,
            fontWeight: FontWeight.bold,
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.inputBorder.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        'Agendada',
        style: AppTextStyles.caption.copyWith(
          color: AppColors.textMuted,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _buildMetric({
    required IconData icon,
    required String value,
    required String label,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: AppColors.primaryNavy),
            const SizedBox(width: 4),
            Text(
              value,
              style: AppTextStyles.bodyLarge.copyWith(
                fontWeight: FontWeight.bold,
                color: AppColors.textDark,
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: AppTextStyles.caption.copyWith(
            color: AppColors.textMuted,
          ),
        ),
      ],
    );
  }
}
