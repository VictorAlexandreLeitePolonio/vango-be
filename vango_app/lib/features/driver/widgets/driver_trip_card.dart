import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_text_styles.dart';
import '../models/driver_trip.dart';
import '../models/route_stop.dart';

/// Summary card of one persisted service-day trip.
///
/// [canOperate] is true only for the assigned driver of a non-terminal trip;
/// everyone else (e.g. the fleet owner) gets a read-only "Ver viagem" action.
class DriverTripCard extends StatelessWidget {
  const DriverTripCard({
    super.key,
    required this.trip,
    required this.canOperate,
    required this.onOpen,
  });

  final DriverTrip trip;
  final bool canOperate;
  final VoidCallback onOpen;

  /// pt-BR label for each backend trip state.
  static String statusLabel(TripStatus status) => switch (status) {
    TripStatus.scheduled => 'Agendada',
    TripStatus.confirmationClosed => 'Confirmações encerradas',
    TripStatus.active => 'Em andamento',
    TripStatus.completed => 'Concluída',
    TripStatus.cancelled => 'Cancelada',
  };

  String get _actionLabel {
    if (!canOperate) return 'Ver viagem';
    return trip.status == TripStatus.active
        ? 'Continuar viagem'
        : 'Iniciar viagem';
  }

  @override
  Widget build(BuildContext context) {
    final isTripActive = trip.status == TripStatus.active;
    final local = trip.plannedStartAt.toLocal();
    final startTime =
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
    final schoolCount = trip.stops
        .where((s) => s.kind == StopKind.school)
        .length;

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
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
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
                        'Hoje • $startTime',
                        style: AppTextStyles.caption.copyWith(
                          color: AppColors.primaryOrangeDark,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
                _buildStatusBadge(trip.status),
              ],
            ),
            const SizedBox(height: 14),

            // Title and Van info
            Text(trip.routeName, style: AppTextStyles.heading3),
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
                  value: '$schoolCount',
                  label: schoolCount == 1 ? 'Escola' : 'Escolas',
                ),
                Container(
                  width: 1,
                  height: 36,
                  color: AppColors.inputBorder.withValues(alpha: 0.8),
                ),
                _buildMetric(
                  icon: Icons.route_outlined,
                  value: trip.formattedDistance,
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
                  onPressed: onOpen,
                  icon: const Icon(
                    Icons.map_rounded,
                    color: Colors.white,
                    size: 20,
                  ),
                  label: Text(
                    _actionLabel,
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

  Widget _buildStatusBadge(TripStatus status) {
    final (background, foreground) = switch (status) {
      TripStatus.active => (
        AppColors.primaryOrange.withValues(alpha: 0.15),
        AppColors.primaryOrangeDark,
      ),
      TripStatus.completed => (
        AppColors.successGreen.withValues(alpha: 0.15),
        AppColors.successGreen,
      ),
      TripStatus.cancelled => (
        AppColors.errorRed.withValues(alpha: 0.15),
        AppColors.errorRed,
      ),
      TripStatus.scheduled || TripStatus.confirmationClosed => (
        AppColors.inputBorder.withValues(alpha: 0.5),
        AppColors.textMuted,
      ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        statusLabel(status),
        style: AppTextStyles.caption.copyWith(
          color: foreground,
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
          style: AppTextStyles.caption.copyWith(color: AppColors.textMuted),
        ),
      ],
    );
  }
}
