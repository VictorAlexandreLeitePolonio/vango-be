import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../shared/widgets/vango_button.dart';
import '../models/driver_trip.dart';
import '../models/route_stop.dart';

/// Live lifecycle panel: every action is driven by the persisted projection
/// (`nextActionStop` / `isOutbound` / `canFinish`), never by local mutation.
class DriverActiveTripPanel extends StatelessWidget {
  const DriverActiveTripPanel({
    super.key,
    required this.trip,
    required this.onBoardStop,
    required this.onMarkAbsent,
    required this.onDropOff,
    required this.onSchoolArrival,
    required this.onSchoolBoarding,
    required this.onFinishTrip,
    this.isBusy = false,
  });

  final DriverTrip trip;
  final ValueChanged<RouteStop> onBoardStop;
  final ValueChanged<RouteStop> onMarkAbsent;
  final ValueChanged<RouteStop> onDropOff;
  final VoidCallback onSchoolArrival;
  final VoidCallback onSchoolBoarding;
  final VoidCallback onFinishTrip;

  /// True while a backend command is in flight; every button disables.
  final bool isBusy;

  /// Whether the per-student absence button is offered on [home]'s row:
  /// only while that student is still pending and the school has not been
  /// reached yet on the return direction.
  bool _offersAbsence(DriverTrip trip, RouteStop home) {
    if (home.status != StopStatus.pending) return false;
    if (trip.isOutbound) return false;
    final school = trip.schoolStop;
    return school == null || school.status != StopStatus.reached;
  }

  Widget _absenceButton(RouteStop stop) => OutlinedButton.icon(
    onPressed: isBusy ? null : () => onMarkAbsent(stop),
    icon: const Icon(
      Icons.person_off_outlined,
      size: 18,
      color: AppColors.errorRed,
    ),
    label: const Text(
      'Ausente',
      style: TextStyle(color: AppColors.errorRed, fontWeight: FontWeight.w600),
    ),
    style: OutlinedButton.styleFrom(
      side: const BorderSide(color: AppColors.errorRed),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    ),
  );

  Widget _mainButton(String text, VoidCallback? onPressed) =>
      VanGoButton(text: text, onPressed: isBusy ? null : onPressed);

  Widget _actionArea(DriverTrip trip) {
    if (trip.canFinish) return _mainButton('Finalizar viagem', onFinishTrip);
    final action = trip.nextActionStop;
    if (action == null) {
      return Center(
        child: Text(
          'Aguardando atualização da viagem.',
          style: AppTextStyles.bodySmall.copyWith(color: AppColors.textMuted),
        ),
      );
    }
    if (trip.isOutbound && action.kind == StopKind.school) {
      return _mainButton('Confirmar chegada na escola', onSchoolArrival);
    }
    if (!trip.isOutbound && action.kind == StopKind.school) {
      return _mainButton('Embarcar presentes', onSchoolBoarding);
    }
    if (!trip.isOutbound && action.kind == StopKind.home) {
      return _mainButton('Desembarcou', () => onDropOff(action));
    }
    // Outbound home stop: absence on the side, boarding as the main action.
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: isBusy ? null : () => onMarkAbsent(action),
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
            onPressed: isBusy ? null : () => onBoardStop(action),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final actionStop = trip.nextActionStop;
    final isDestination = actionStop?.isSchoolDestination ?? false;

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
                          actionStop?.name ?? 'Todas as paradas concluídas',
                          style: AppTextStyles.heading3.copyWith(fontSize: 18),
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 10),

            if (actionStop != null) ...[
              Padding(
                padding: const EdgeInsets.only(left: 38),
                child: Text(
                  actionStop.address,
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
              style: AppTextStyles.caption.copyWith(color: AppColors.textMuted),
            ),
            const SizedBox(height: 16),

            // Per-student stop list with contextual absence actions.
            for (final home in trip.stops.where(
              (s) => s.kind == StopKind.home,
            )) ...[
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${home.name} — ${_homeStatusLabel(home.status)}',
                        style: AppTextStyles.bodySmall.copyWith(
                          color: home.status == StopStatus.pending
                              ? AppColors.textDark
                              : AppColors.textMuted,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (_offersAbsence(trip, home)) ...[
                      const SizedBox(width: 8),
                      _absenceButton(home),
                    ],
                  ],
                ),
              ),
            ],
            const SizedBox(height: 16),

            _actionArea(trip),
          ],
        ),
      ),
    );
  }

  /// pt-BR label of a home stop's operational state.
  static String _homeStatusLabel(StopStatus status) => switch (status) {
    StopStatus.pending => 'aguardando',
    StopStatus.boarded => 'Embarcou',
    StopStatus.droppedOff => 'Desembarcou',
    StopStatus.absent => 'Ausente',
    StopStatus.reached => 'Concluída',
  };
}
