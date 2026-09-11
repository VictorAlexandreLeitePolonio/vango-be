import 'dart:async';
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../shared/widgets/vango_button.dart';
import '../models/driver_trip.dart';
import '../models/route_stop.dart';
import '../services/driver_location_service.dart';
import '../services/driver_route_service.dart';
import '../widgets/driver_active_trip_panel.dart';
import '../widgets/mapbox_route_map.dart';

/// Driver route dashboard screen featuring Mapbox navigation, active trip lifecycle
/// (start, student boarding, student absence, finish), real-time telemetry streaming (GPS/simulation),
/// and intelligent proximity alerts when approaching student pickup points.
class DriverRouteScreen extends StatefulWidget {
  const DriverRouteScreen({
    super.key,
    this.routeService,
    this.locationService,
  });

  /// Optional injected route calculation service (defaults to standard instance).
  final DriverRouteService? routeService;

  /// Optional injected telemetry and GPS tracking service (defaults to standard instance).
  final DriverLocationService? locationService;

  @override
  State<DriverRouteScreen> createState() => _DriverRouteScreenState();
}


class _DriverRouteScreenState extends State<DriverRouteScreen> {
  late final DriverRouteService _routeService;
  late final DriverLocationService _locationService;
  StreamSubscription<VanTelemetryUpdate>? _telemetrySub;

  DriverTrip? _trip;
  bool _isLoading = true;
  String? _errorMessage;

  LatLng? _liveVanPos;
  double _vanHeading = 0.0;
  double _vanSpeedKmh = 0.0;
  RouteStop? _approachingStop;
  LocationTrackingMode _selectedTrackingMode = LocationTrackingMode.simulation;

  @override
  void initState() {
    super.initState();
    _routeService = widget.routeService ?? DriverRouteService();
    _locationService = widget.locationService ?? DriverLocationService();
    _telemetrySub = _locationService.telemetryStream.listen((telemetry) {
      if (!mounted) return;
      setState(() {
        _liveVanPos = telemetry.position;
        _vanHeading = telemetry.headingDegrees;
        _vanSpeedKmh = telemetry.speedKmh;
        _approachingStop = telemetry.approachingStop;
      });
    });
    _loadRoute();
  }

  @override
  void dispose() {
    _telemetrySub?.cancel();
    _locationService.dispose();
    super.dispose();
  }

  Future<void> _loadRoute({bool forceRefresh = false}) async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final trip = await _routeService.calculateAndOptimizeRoute(
        forceRefresh: forceRefresh,
      );
      if (!mounted) return;
      setState(() {
        _trip = trip;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Erro ao carregar rota: $e';
        _isLoading = false;
      });
    }
  }

  Future<void> _handleStartTrip() async {
    final updatedTrip = await _routeService.startTrip();
    if (!mounted) return;
    setState(() => _trip = updatedTrip);

    if (updatedTrip.polylinePoints.isNotEmpty) {
      _locationService.startTracking(
        routePoints: updatedTrip.polylinePoints,
        pendingStops: updatedTrip.pendingStops,
        mode: _selectedTrackingMode,
      );
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(_selectedTrackingMode == LocationTrackingMode.deviceGps
            ? 'Percurso iniciado! GPS nativo ativado.'
            : 'Percurso iniciado! Simulação virtual ativada.'),
        backgroundColor: AppColors.successGreen,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _handleBoardStop(RouteStop stop) async {
    final updatedTrip = await _routeService.updateStopStatus(
      stop.id,
      StopStatus.boarded,
    );
    if (!mounted) return;
    setState(() {
      _trip = updatedTrip;
      if (_approachingStop?.id == stop.id) {
        _approachingStop = null;
      }
    });
    _locationService.updatePendingStops(updatedTrip.pendingStops);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Embarque de ${stop.name} confirmado!'),
        backgroundColor: AppColors.primaryOrangeDark,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _handleMarkAbsent(RouteStop stop) async {
    final updatedTrip = await _routeService.updateStopStatus(
      stop.id,
      StopStatus.absent,
    );
    if (!mounted) return;
    setState(() {
      _trip = updatedTrip;
      if (_approachingStop?.id == stop.id) {
        _approachingStop = null;
      }
    });
    _locationService.updatePendingStops(updatedTrip.pendingStops);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${stop.name} marcado como ausente.'),
        backgroundColor: AppColors.warningYellow,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _handleFinishTrip() async {
    _locationService.stopTracking();
    final updatedTrip = await _routeService.finishTrip();
    if (!mounted) return;
    setState(() {
      _trip = updatedTrip;
      _approachingStop = null;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Viagem finalizada com sucesso no destino escolar!'),
        backgroundColor: AppColors.successGreen,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.backgroundWhite,
      appBar: AppBar(
        title: const Text('Rota do Dia'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Recalcular trajeto',
            onPressed: () => _loadRoute(forceRefresh: true),
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: AppColors.primaryOrange),
            SizedBox(height: 16),
            Text(
              'Traçando melhor rota no Mapbox...',
              style: TextStyle(color: AppColors.textMuted),
            ),
          ],
        ),
      );
    }

    if (_errorMessage != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_errorMessage!, style: const TextStyle(color: AppColors.errorRed)),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () => _loadRoute(forceRefresh: true),
              child: const Text('Tentar novamente'),
            ),
          ],
        ),
      );
    }

    final trip = _trip!;
    final isTripActive = trip.status == TripStatus.inProgress;
    final isCompleted = trip.status == TripStatus.completed;

    // Determine current van marker position
    final currentVanPos = _liveVanPos ??
        (isTripActive && trip.nextPendingStop != null
            ? LatLng(
                trip.nextPendingStop!.latitude,
                trip.nextPendingStop!.longitude,
              )
            : trip.stops.isNotEmpty
                ? LatLng(trip.stops.first.latitude, trip.stops.first.longitude)
                : null);

    return Stack(
      children: [
        Column(
          children: [
            // Map view
            Expanded(
              flex: 5,
              child: Stack(
                children: [
                  MapboxRouteMap(
                    stops: trip.stops,
                    polylinePoints: trip.polylinePoints,
                    currentVanPosition: currentVanPos,
                    headingDegrees: _vanHeading,
                    autoFollowVan: isTripActive,
                  ),
                  // Floating route metrics badge
                  Positioned(
                    top: 16,
                    left: 16,
                    right: 16,
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.cardBackground,
                          borderRadius: BorderRadius.circular(16),
                          boxShadow: const [
                            BoxShadow(
                              color: AppColors.shadowMedium,
                              blurRadius: 12,
                              offset: Offset(0, 4),
                            ),
                          ],
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.directions_car_rounded,
                              size: 18,
                              color: AppColors.primaryOrangeDark,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              trip.formattedDistance,
                              style: AppTextStyles.bodyMedium.copyWith(
                                fontWeight: FontWeight.bold,
                                color: AppColors.textDark,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Container(
                              width: 1,
                              height: 16,
                              color: AppColors.inputBorder,
                            ),
                            const SizedBox(width: 12),
                            const Icon(
                              Icons.timer_outlined,
                              size: 18,
                              color: AppColors.primaryNavy,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              trip.formattedDuration,
                              style: AppTextStyles.bodyMedium.copyWith(
                                fontWeight: FontWeight.bold,
                                color: AppColors.textDark,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: AppColors.successGreen.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                'Melhor trajeto',
                                style: AppTextStyles.caption.copyWith(
                                  color: AppColors.successGreen,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 10,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),

                  // Floating GPS mode status pill
                  Positioned(
                    top: 68,
                    left: 16,
                    right: 16,
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                        decoration: BoxDecoration(
                          color: AppColors.cardBackground.withValues(alpha: 0.95),
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: const [
                            BoxShadow(
                              color: AppColors.shadowLight,
                              blurRadius: 8,
                              offset: Offset(0, 2),
                            ),
                          ],
                          border: Border.all(
                            color: _locationService.isTracking
                                ? AppColors.successGreen
                                : AppColors.inputBorder,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              _locationService.isTracking
                                  ? Icons.satellite_alt_rounded
                                  : Icons.gps_fixed_rounded,
                              size: 16,
                              color: _locationService.isTracking
                                  ? AppColors.successGreen
                                  : AppColors.textMuted,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              _locationService.isTracking
                                  ? '${_selectedTrackingMode == LocationTrackingMode.deviceGps ? 'GPS Ativo' : 'Simulação'} • ${_vanSpeedKmh.toStringAsFixed(0)} km/h'
                                  : 'Modo: ${_selectedTrackingMode == LocationTrackingMode.deviceGps ? 'GPS Real' : 'Simulação'}',
                              style: AppTextStyles.caption.copyWith(
                                fontWeight: FontWeight.bold,
                                color: _locationService.isTracking
                                    ? AppColors.successGreen
                                    : AppColors.textDark,
                              ),
                            ),
                            if (!_locationService.isTracking) ...[
                              const SizedBox(width: 8),
                              GestureDetector(
                                onTap: () {
                                  setState(() {
                                    _selectedTrackingMode =
                                        _selectedTrackingMode == LocationTrackingMode.simulation
                                            ? LocationTrackingMode.deviceGps
                                            : LocationTrackingMode.simulation;
                                  });
                                },
                                child: Text(
                                  'Alternar',
                                  style: AppTextStyles.caption.copyWith(
                                    color: AppColors.primaryOrangeDark,
                                    fontWeight: FontWeight.bold,
                                    decoration: TextDecoration.underline,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),

                  // Proximity alert banner
                  if (_approachingStop != null)
                    Positioned(
                      bottom: 12,
                      left: 16,
                      right: 16,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        decoration: BoxDecoration(
                          color: AppColors.primaryOrangeDark,
                          borderRadius: BorderRadius.circular(16),
                          boxShadow: const [
                            BoxShadow(
                              color: AppColors.shadowMedium,
                              blurRadius: 14,
                              offset: Offset(0, 4),
                            ),
                          ],
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.near_me_rounded, color: Colors.white, size: 24),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Text(
                                    'Próximo do embarque!',
                                    style: TextStyle(
                                      color: Colors.white70,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  Text(
                                    _approachingStop!.name,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 15,
                                      fontWeight: FontWeight.bold,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                            ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.white,
                                foregroundColor: AppColors.primaryOrangeDark,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 8,
                                ),
                              ),
                              onPressed: () => _handleBoardStop(_approachingStop!),
                              child: const Text(
                                'Embarcar',
                                style: TextStyle(fontWeight: FontWeight.bold),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),

            // Stops list timeline when scheduled or completed
            if (!isTripActive)
              Expanded(
                flex: 4,
                child: Container(
                  decoration: const BoxDecoration(
                    color: AppColors.cardBackground,
                    borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
                    boxShadow: [
                      BoxShadow(
                        color: AppColors.shadowMedium,
                        blurRadius: 16,
                        offset: Offset(0, -4),
                      ),
                    ],
                  ),
                  child: Column(
                    children: [
                      const SizedBox(height: 12),
                      Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: AppColors.inputBorder,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              'Paradas do Dia (${trip.stops.length})',
                              style: AppTextStyles.heading3.copyWith(fontSize: 18),
                            ),
                            Text(
                              '${trip.totalStudents} Alunos',
                              style: AppTextStyles.bodySmall.copyWith(
                                color: AppColors.textMuted,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: ListView.separated(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 8,
                          ),
                          itemCount: trip.stops.length,
                          separatorBuilder: (context, index) => const SizedBox(height: 8),
                          itemBuilder: (context, index) {
                            final stop = trip.stops[index];
                            return _buildStopTile(index + 1, stop);
                          },
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: isCompleted
                            ? Container(
                                width: double.infinity,
                                padding: const EdgeInsets.all(14),
                                decoration: BoxDecoration(
                                  color: AppColors.successGreen.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                child: const Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(Icons.check_circle_rounded, color: AppColors.successGreen),
                                    SizedBox(width: 8),
                                    Text(
                                      'Viagem Concluída',
                                      style: TextStyle(
                                        color: AppColors.successGreen,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 16,
                                      ),
                                    ),
                                  ],
                                ),
                              )
                            : VanGoButton(
                                text: 'Começar Percurso',
                                onPressed: _handleStartTrip,
                              ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),

        // Live trip panel when in progress
        if (isTripActive)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: DriverActiveTripPanel(
              trip: trip,
              onBoardStop: _handleBoardStop,
              onMarkAbsent: _handleMarkAbsent,
              onFinishTrip: _handleFinishTrip,
            ),
          ),
      ],
    );
  }

  Widget _buildStopTile(int order, RouteStop stop) {
    final isDestination = stop.isSchoolDestination;
    final isDone = stop.isCompleted;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDone
            ? AppColors.backgroundCream.withValues(alpha: 0.5)
            : AppColors.backgroundWhite,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isDone
              ? AppColors.successGreen.withValues(alpha: 0.4)
              : AppColors.inputBorder.withValues(alpha: 0.6),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: isDone
                  ? AppColors.successGreen
                  : isDestination
                      ? AppColors.primaryNavy
                      : AppColors.primaryOrange,
              shape: BoxShape.circle,
            ),
            child: Center(
              child: isDestination
                  ? const Icon(Icons.school_rounded, color: Colors.white, size: 16)
                  : isDone
                      ? const Icon(Icons.check, color: Colors.white, size: 16)
                      : Text(
                          '$order',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      stop.name,
                      style: AppTextStyles.bodyMedium.copyWith(
                        fontWeight: FontWeight.bold,
                        color: isDone ? AppColors.textMuted : AppColors.textDark,
                      ),
                    ),
                    Text(
                      stop.scheduledTime,
                      style: AppTextStyles.caption.copyWith(
                        color: AppColors.primaryOrangeDark,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  stop.address,
                  style: AppTextStyles.caption.copyWith(
                    color: AppColors.textMuted,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
