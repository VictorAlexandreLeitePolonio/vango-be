import 'dart:async';
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../shared/widgets/vango_button.dart';
import '../models/driver_trip.dart';
import '../models/route_stop.dart';
import '../models/trip_command_ledger.dart';
import '../services/driver_location_service.dart';
import '../services/driver_route_service.dart';
import '../services/trip_command_error_mapper.dart';
import '../services/trip_telemetry_uploader.dart';
import '../widgets/driver_active_trip_panel.dart';
import '../widgets/mapbox_route_map.dart';

/// Driver route dashboard screen featuring Mapbox navigation, active trip lifecycle
/// (start, student boarding, student absence, finish), real-time telemetry streaming (GPS/simulation),
/// and intelligent proximity alerts when approaching student pickup points.
class DriverRouteScreen extends StatefulWidget {
  const DriverRouteScreen({
    super.key,
    required this.tripId,
    this.routeService,
    this.locationService,
    this.telemetryUploader,
  });

  /// Persisted trip to load through the authorized `get_trip` projection.
  final String tripId;

  /// Optional injected route calculation service (defaults to standard instance).
  final DriverRouteService? routeService;

  /// Optional injected telemetry and GPS tracking service (defaults to standard instance).
  final DriverLocationService? locationService;

  /// Optional injected GPS uploader (defaults to one sending through
  /// [routeService]).
  final TripTelemetryUploader? telemetryUploader;

  @override
  State<DriverRouteScreen> createState() => _DriverRouteScreenState();
}

class _DriverRouteScreenState extends State<DriverRouteScreen> {
  late final DriverRouteService _routeService;
  late final DriverLocationService _locationService;
  late final TripTelemetryUploader _uploader;
  StreamSubscription<VanTelemetryUpdate>? _telemetrySub;

  DriverTrip? _trip;
  bool _isLoading = true;
  String? _errorMessage;

  /// Remembers command ids of actions whose outcome is unknown so a retry
  /// reuses them (backend idempotency).
  final _ledger = TripCommandLedger();

  /// True while a backend command is in flight; action buttons disable.
  bool _isSubmitting = false;

  LatLng? _liveVanPos;
  double _vanHeading = 0.0;
  double _vanSpeedKmh = 0.0;
  RouteStop? _approachingStop;
  LocationTrackingMode _selectedTrackingMode = LocationTrackingMode.deviceGps;

  // True once a real (non-simulated) fix arrived in the current tracking
  // session; the pill only claims "GPS Ativo" after that.
  bool _hasRealFix = false;

  @override
  void initState() {
    super.initState();
    _routeService = widget.routeService ?? DriverRouteService();
    _locationService = widget.locationService ?? DriverLocationService();
    _uploader =
        widget.telemetryUploader ??
        TripTelemetryUploader(send: _routeService.ingestTripLocations);
    _locationService.availability.addListener(_onTelemetryHealthChanged);
    _uploader.state.addListener(_onTelemetryHealthChanged);
    _telemetrySub = _locationService.telemetryStream.listen((telemetry) {
      if (!mounted) return;
      if (!telemetry.isSimulated) _uploader.add(telemetry);
      setState(() {
        _hasRealFix = _hasRealFix || !telemetry.isSimulated;
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
    _locationService.availability.removeListener(_onTelemetryHealthChanged);
    _uploader.state.removeListener(_onTelemetryHealthChanged);
    _uploader.stop();
    _locationService.dispose();
    super.dispose();
  }

  Future<void> _loadRoute({bool forceRefresh = false}) async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    // The persisted trip is the source of truth: always reload it from the
    // backend so reopening the screen restores the real status.
    DriverTrip trip;
    try {
      trip = await _routeService.getTrip(widget.tripId);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Não foi possível carregar esta viagem.';
        _isLoading = false;
      });
      return;
    }
    // Route geometry is best-effort: a directions failure keeps the trip
    // usable with its stop list instead of hiding it behind an error.
    try {
      trip = await _routeService.calculateAndOptimizeRoute(
        forceRefresh: forceRefresh,
      );
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _trip = trip;
      _isLoading = false;
    });
    _syncTelemetry();
  }

  void _onTelemetryHealthChanged() {
    if (!mounted) return;
    // The backend refused this trip's telemetry: stop GPS too, so nothing
    // claims to be live anymore.
    if (_uploader.state.value == TelemetrySyncState.rejected) {
      _locationService.stopTracking();
      _hasRealFix = false;
    }
    setState(() {});
  }

  /// Keeps GPS and uploads in step with the trip: on while it is active and
  /// operated by the signed-in driver (also when reopening the screen), off
  /// otherwise.
  Future<void> _syncTelemetry() async {
    final trip = _trip;
    final userId = _routeService.currentUserId;
    if (trip == null ||
        trip.status != TripStatus.active ||
        !trip.isOperableBy(userId)) {
      _stopTelemetry();
      return;
    }

    final assignmentId = trip.currentAssignmentIdFor(userId);
    final startedAt = trip.startedAt;
    if (assignmentId != null && startedAt != null && !_uploader.isActive) {
      _uploader.start(
        tripId: trip.id,
        assignmentId: assignmentId,
        startedAt: startedAt,
      );
    }
    if (_locationService.isTracking) return;
    _hasRealFix = false;
    await _locationService.startTracking(
      routePoints: trip.polylinePoints,
      pendingStops: trip.pendingStops,
      mode: _selectedTrackingMode,
    );
    if (mounted) setState(() {});
  }

  void _stopTelemetry() {
    _locationService.stopTracking();
    _uploader.stop();
    _hasRealFix = false;
  }

  /// "Ativar GPS": opens the OS screen that can fix the failure, then retries.
  Future<void> _handleEnableGps() async {
    await _locationService.openGpsSettings();
    await _syncTelemetry();
  }

  /// Runs one logical action; [steps] are (actionKey, command) pairs executed
  /// in order. Definitive outcomes drop the command id; uncertain outcomes
  /// keep it pending so [retry] (the same handler) reuses it.
  Future<bool> _runCommands(
    List<(String, Future<DriverTrip> Function(String commandId))> steps, {
    required String successMessage,
    required VoidCallback retry,
  }) async {
    if (steps.isEmpty || _isSubmitting) return false;
    setState(() => _isSubmitting = true);
    try {
      var latest = _trip;
      for (final (actionKey, command) in steps) {
        final commandId = _ledger.idFor(actionKey);
        try {
          latest = await command(commandId);
          _ledger.resolve(actionKey);
        } catch (error) {
          switch (TripCommandErrorMapper.kind(error)) {
            case TripCommandFailure.rejected:
            case TripCommandFailure.accessLost:
              // Definitive rejection: drop the id and show the mapped message.
              _ledger.resolve(actionKey);
              await _reloadTrip();
              if (!mounted) return false;
              _showSnack(
                TripCommandErrorMapper.message(error),
                AppColors.errorRed,
              );
              return false;
            case TripCommandFailure.uncertain:
              // The write may have committed: reload and check the projection.
              final reloaded = await _reloadTrip();
              if (!mounted) return false;
              if (reloaded != null && _isStepApplied(actionKey, reloaded)) {
                _ledger.resolve(actionKey);
                latest = reloaded;
                continue;
              }
              if (reloaded != null) setState(() => _trip = reloaded);
              _showUncertainSnack(retry);
              return false;
          }
        }
      }
      if (!mounted) return false;
      setState(() => _trip = latest);
      _showSnack(successMessage, AppColors.successGreen);
      return true;
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  /// Reloads the persisted trip without surfacing errors (best effort).
  Future<DriverTrip?> _reloadTrip() async {
    try {
      return await _routeService.getTrip(widget.tripId);
    } catch (_) {
      return null;
    }
  }

  /// Whether [actionKey] already appears applied on the reloaded [trip].
  bool _isStepApplied(String actionKey, DriverTrip trip) {
    if (actionKey == 'start') return trip.status == TripStatus.active;
    if (actionKey == 'finish') return trip.status == TripStatus.completed;
    if (actionKey.startsWith('passenger:')) {
      final parts = actionKey.split(':');
      if (parts.length != 3) return false;
      final status = switch (parts[2]) {
        'boarded' => StopStatus.boarded,
        'absent' => StopStatus.absent,
        'dropped_off' => StopStatus.droppedOff,
        _ => null,
      };
      if (status == null) return false;
      return trip.stops.any(
        (s) =>
            s.kind == StopKind.home &&
            s.studentId == parts[1] &&
            s.status == status,
      );
    }
    if (actionKey.startsWith('stop:')) {
      final stopId = actionKey.substring('stop:'.length);
      return trip.stops.any(
        (s) => s.id == stopId && s.status == StopStatus.reached,
      );
    }
    return false;
  }

  void _showSnack(String message, Color background) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: background,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _showUncertainSnack(VoidCallback retry) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text(
          'Não foi possível confirmar a ação. Tente novamente.',
        ),
        backgroundColor: AppColors.errorRed,
        behavior: SnackBarBehavior.floating,
        action: SnackBarAction(label: 'Tentar novamente', onPressed: retry),
      ),
    );
  }

  Future<void> _handleStartTrip() async {
    final trip = _trip;
    if (trip == null) return;
    final ok = await _runCommands(
      [('start', (commandId) => _routeService.startTrip(trip.id, commandId))],
      successMessage: 'Viagem iniciada.',
      retry: _handleStartTrip,
    );
    // Tracking only starts once the backend accepted the start.
    if (!ok || !mounted) return;
    // The command reload returns persisted state without geometry; refresh
    // the route (best effort) so tracking follows the same polyline as today.
    var geometry = _trip;
    try {
      geometry = await _routeService.calculateAndOptimizeRoute();
    } catch (_) {}
    if (!mounted) return;
    if (geometry != null) setState(() => _trip = geometry);
    _syncTelemetry();
  }

  Future<void> _handleBoardStop(RouteStop stop) async {
    final trip = _trip;
    final studentId = stop.studentId;
    if (trip == null || studentId == null) return;
    final ok = await _runCommands(
      [
        (
          'passenger:$studentId:boarded',
          (commandId) => _routeService.recordPassengerEvent(
            trip.id,
            studentId,
            PassengerEventKind.boarded,
            commandId,
          ),
        ),
      ],
      successMessage: 'Embarque de ${stop.name} registrado.',
      retry: () => _handleBoardStop(stop),
    );
    if (!ok || !mounted) return;
    setState(() {
      if (_approachingStop?.id == stop.id) _approachingStop = null;
    });
    _locationService.updatePendingStops(_trip!.pendingStops);
  }

  Future<void> _handleMarkAbsent(RouteStop stop) async {
    final trip = _trip;
    final studentId = stop.studentId;
    if (trip == null || studentId == null) return;
    final ok = await _runCommands(
      [
        (
          'passenger:$studentId:absent',
          (commandId) => _routeService.recordPassengerEvent(
            trip.id,
            studentId,
            PassengerEventKind.absent,
            commandId,
          ),
        ),
      ],
      successMessage: '${stop.name} marcado como ausente.',
      retry: () => _handleMarkAbsent(stop),
    );
    if (!ok || !mounted) return;
    setState(() {
      if (_approachingStop?.id == stop.id) _approachingStop = null;
    });
    _locationService.updatePendingStops(_trip!.pendingStops);
  }

  Future<void> _handleDropOff(RouteStop stop) async {
    final trip = _trip;
    final studentId = stop.studentId;
    if (trip == null || studentId == null) return;
    final ok = await _runCommands(
      [
        (
          'passenger:$studentId:dropped_off',
          (commandId) => _routeService.recordPassengerEvent(
            trip.id,
            studentId,
            PassengerEventKind.droppedOff,
            commandId,
          ),
        ),
      ],
      successMessage: 'Desembarque de ${stop.name} registrado.',
      retry: () => _handleDropOff(stop),
    );
    if (!ok || !mounted) return;
    setState(() {
      if (_approachingStop?.id == stop.id) _approachingStop = null;
    });
    _locationService.updatePendingStops(_trip!.pendingStops);
  }

  /// Outbound: the school stop is reached, then every boarded student drops.
  Future<void> _handleSchoolArrival() async {
    final trip = _trip;
    final school = trip?.schoolStop;
    if (trip == null || school == null) return;
    final steps = <(String, Future<DriverTrip> Function(String commandId))>[
      if (school.status != StopStatus.reached)
        (
          'stop:${school.id}',
          (commandId) =>
              _routeService.markStopReached(trip.id, school.id, commandId),
        ),
      for (final home in trip.stops)
        if (home.kind == StopKind.home &&
            home.status == StopStatus.boarded &&
            home.studentId != null)
          (
            'passenger:${home.studentId}:dropped_off',
            (commandId) => _routeService.recordPassengerEvent(
              trip.id,
              home.studentId!,
              PassengerEventKind.droppedOff,
              commandId,
            ),
          ),
    ];
    await _runCommands(
      steps,
      successMessage: 'Chegada na escola registrada.',
      retry: _handleSchoolArrival,
    );
  }

  /// Return: the school stop is reached, then every waiting student boards.
  Future<void> _handleSchoolBoarding() async {
    final trip = _trip;
    final school = trip?.schoolStop;
    if (trip == null || school == null) return;
    final steps = <(String, Future<DriverTrip> Function(String commandId))>[
      (
        'stop:${school.id}',
        (commandId) =>
            _routeService.markStopReached(trip.id, school.id, commandId),
      ),
      for (final home in trip.stops)
        if (home.kind == StopKind.home &&
            home.status == StopStatus.pending &&
            home.studentId != null)
          (
            'passenger:${home.studentId}:boarded',
            (commandId) => _routeService.recordPassengerEvent(
              trip.id,
              home.studentId!,
              PassengerEventKind.boarded,
              commandId,
            ),
          ),
    ];
    final ok = await _runCommands(
      steps,
      successMessage: 'Embarque na escola registrado.',
      retry: _handleSchoolBoarding,
    );
    if (!ok || !mounted) return;
    _locationService.updatePendingStops(_trip!.pendingStops);
  }

  Future<void> _handleFinishTrip() async {
    final trip = _trip;
    if (trip == null) return;
    final ok = await _runCommands(
      [('finish', (commandId) => _routeService.finishTrip(trip.id, commandId))],
      successMessage: 'Viagem finalizada.',
      retry: _handleFinishTrip,
    );
    // Tracking only stops once the backend accepted the finish.
    if (!ok || !mounted) return;
    setState(() => _approachingStop = null);
    // The trip is completed now, so this stops GPS and uploads.
    _syncTelemetry();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.backgroundWhite,
      appBar: AppBar(
        title: Text(_trip?.routeName ?? 'Viagem'),
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
              'Carregando viagem...',
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
            Text(
              _errorMessage!,
              style: const TextStyle(color: AppColors.errorRed),
            ),
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
    final isTripActive = trip.status == TripStatus.active;
    final isCompleted = trip.status == TripStatus.completed;
    final isCancelled = trip.status == TripStatus.cancelled;
    final canOperate = trip.isOperableBy(_routeService.currentUserId);

    // Van marker: live telemetry first, otherwise the next mappable pending
    // stop while active, otherwise the first mappable stop.
    final anchorStop = isTripActive
        ? trip.pendingStops.where((s) => s.hasCoordinates).firstOrNull
        : trip.mappableStops.firstOrNull;
    final currentVanPos =
        _liveVanPos ??
        (anchorStop == null
            ? null
            : LatLng(anchorStop.latitude!, anchorStop.longitude!));

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
                    stops: trip.mappableStops,
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
                                color: AppColors.successGreen.withValues(
                                  alpha: 0.15,
                                ),
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
                    child: Center(child: _buildGpsPill()),
                  ),

                  if (isTripActive && _gpsFailureReason != null)
                    Positioned(
                      top: 110,
                      left: 16,
                      right: 16,
                      child: _buildGpsBanner(_gpsFailureReason!),
                    ),

                  // Proximity alert banner
                  if (_approachingStop != null)
                    Positioned(
                      bottom: 12,
                      left: 16,
                      right: 16,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
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
                            const Icon(
                              Icons.near_me_rounded,
                              color: Colors.white,
                              size: 24,
                            ),
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
                            // Boarding is offered only for a still-pending
                            // outbound home stop.
                            if (trip.isOutbound &&
                                _approachingStop!.kind == StopKind.home &&
                                _approachingStop!.status == StopStatus.pending)
                              ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.white,
                                  foregroundColor: AppColors.primaryOrangeDark,
                                  minimumSize: const Size(80, 36),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 8,
                                  ),
                                ),
                                onPressed: _isSubmitting
                                    ? null
                                    : () => _handleBoardStop(_approachingStop!),
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
                    borderRadius: BorderRadius.vertical(
                      top: Radius.circular(28),
                    ),
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
                              style: AppTextStyles.heading3.copyWith(
                                fontSize: 18,
                              ),
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
                          separatorBuilder: (context, index) =>
                              const SizedBox(height: 8),
                          itemBuilder: (context, index) {
                            final stop = trip.stops[index];
                            return _buildStopTile(index + 1, stop);
                          },
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: isCancelled
                            ? _buildStateBanner(
                                'Viagem Cancelada',
                                Icons.cancel_rounded,
                                AppColors.errorRed,
                              )
                            : !isCompleted && !canOperate
                            ? Text(
                                'Somente o motorista designado pode operar esta viagem.',
                                textAlign: TextAlign.center,
                                style: AppTextStyles.bodySmall.copyWith(
                                  color: AppColors.textMuted,
                                ),
                              )
                            : isCompleted
                            ? Container(
                                width: double.infinity,
                                padding: const EdgeInsets.all(14),
                                decoration: BoxDecoration(
                                  color: AppColors.successGreen.withValues(
                                    alpha: 0.15,
                                  ),
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                child: const Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(
                                      Icons.check_circle_rounded,
                                      color: AppColors.successGreen,
                                    ),
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
              onDropOff: _handleDropOff,
              onSchoolArrival: _handleSchoolArrival,
              onSchoolBoarding: _handleSchoolBoarding,
              onFinishTrip: _handleFinishTrip,
              isBusy: _isSubmitting,
            ),
          ),
      ],
    );
  }

  /// pt-BR reason when real GPS could not start or broke; null while OK.
  String? get _gpsFailureReason =>
      switch (_locationService.availability.value) {
        GpsAvailability.serviceDisabled => 'serviço desativado',
        GpsAvailability.denied => 'permissão negada',
        GpsAvailability.deniedForever => 'permissão negada permanentemente',
        GpsAvailability.error => 'erro no GPS',
        GpsAvailability.available || null => null,
      };

  Widget _buildGpsPill() {
    final tracking = _locationService.isTracking;
    final simulated =
        _locationService.mode == LocationTrackingMode.simulation && tracking;
    final speed = '${_vanSpeedKmh.toStringAsFixed(0)} km/h';
    // "GPS Ativo" is earned by real fixes on a trip whose uploads were not
    // refused; until then the pill only says what it is waiting for.
    final live =
        tracking &&
        !simulated &&
        _hasRealFix &&
        _uploader.state.value != TelemetrySyncState.rejected;
    final modeLabel = _selectedTrackingMode == LocationTrackingMode.deviceGps
        ? 'GPS Real'
        : 'Simulação (demo)';
    final label = simulated
        ? 'Simulação (demo) • $speed'
        : live
        ? 'GPS Ativo • $speed'
        : tracking
        ? 'Aguardando GPS...'
        : 'Modo: $modeLabel';
    final highlight = live || simulated;

    return Container(
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
          color: highlight ? AppColors.successGreen : AppColors.inputBorder,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            highlight ? Icons.satellite_alt_rounded : Icons.gps_fixed_rounded,
            size: 16,
            color: highlight ? AppColors.successGreen : AppColors.textMuted,
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: AppTextStyles.caption.copyWith(
              fontWeight: FontWeight.bold,
              color: highlight ? AppColors.successGreen : AppColors.textDark,
            ),
          ),
          // The demo simulation toggle only exists in builds that allow it.
          if (!tracking && _locationService.allowSimulation) ...[
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
    );
  }

  /// Non-blocking warning: the trip keeps operating without live location.
  Widget _buildGpsBanner(String reason) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.errorRed.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.errorRed),
      ),
      child: Row(
        children: [
          const Icon(Icons.gps_off_rounded, color: AppColors.errorRed),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'GPS inativo: $reason',
              style: AppTextStyles.bodySmall.copyWith(
                color: AppColors.errorRed,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          TextButton(
            onPressed: _handleEnableGps,
            child: const Text('Ativar GPS'),
          ),
        ],
      ),
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
                  ? const Icon(
                      Icons.school_rounded,
                      color: Colors.white,
                      size: 16,
                    )
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
                        color: isDone
                            ? AppColors.textMuted
                            : AppColors.textDark,
                      ),
                    ),
                    Text(
                      _stopStatusLabel(stop.status),
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

  /// pt-BR label of a stop's operational state (empty while pending).
  static String _stopStatusLabel(StopStatus status) => switch (status) {
    StopStatus.pending => '',
    StopStatus.boarded => 'Embarcou',
    StopStatus.droppedOff => 'Desembarcou',
    StopStatus.absent => 'Ausente',
    StopStatus.reached => 'Concluída',
  };

  Widget _buildStateBanner(String text, IconData icon, Color color) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: color),
          const SizedBox(width: 8),
          Text(
            text,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.bold,
              fontSize: 16,
            ),
          ),
        ],
      ),
    );
  }
}
