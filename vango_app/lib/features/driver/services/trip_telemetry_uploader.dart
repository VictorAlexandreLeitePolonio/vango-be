import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

import 'driver_location_service.dart';

/// Sends one `ingest_trip_locations` call with the given RPC params.
typedef TelemetrySender = Future<void> Function(Map<String, dynamic> params);

/// Upload health shown next to the GPS pill.
enum TelemetrySyncState {
  /// Not started, or stopped.
  idle,

  /// A batch is in flight.
  syncing,

  /// The last batch was accepted.
  synced,

  /// The last batch failed; it is retried or was dropped.
  failing,

  /// The backend refused the trip/assignment; uploading stopped for good.
  rejected,
}

/// Batches real GPS samples of an active trip into live
/// `ingest_trip_locations` calls.
///
/// Rules mirror the backend contract: a batch fails as a whole when any point
/// is older than 30 s, so points older than [maxPointAge] are dropped at flush
/// time; new live points within 1 s are `rate_limited`, so batches go out on
/// [flushInterval] or at [maxBatchSize] points. There is no offline buffer.
class TripTelemetryUploader {
  /// [send] performs the RPC (normally `DriverRouteService.ingestTripLocations`);
  /// [now] is injectable for tests.
  TripTelemetryUploader({
    required TelemetrySender send,
    DateTime Function()? now,
    this.flushInterval = const Duration(seconds: 5),
    this.maxBatchSize = 20,
    this.maxPointAge = const Duration(seconds: 25),
  }) : _send = send,
       _now = now ?? DateTime.now;

  final TelemetrySender _send;
  final DateTime Function() _now;
  final Duration flushInterval;
  final int maxBatchSize;
  final Duration maxPointAge;

  /// Current upload health.
  final ValueNotifier<TelemetrySyncState> state = ValueNotifier(
    TelemetrySyncState.idle,
  );

  // Backend codes that make every future batch fail: stop uploading.
  static const _rejectedCodes = {
    'invalid_transition',
    'not_found',
    'forbidden',
    'unauthenticated',
    'email_unverified',
  };

  // Codes where resending the identical batch can never succeed: drop it.
  static const _droppedCodes = {'idempotency_conflict', 'invalid_input'};

  String? _tripId;
  String? _assignmentId;
  DateTime? _startedAt;
  Timer? _timer;
  bool _inFlight = false;
  int _lastSequence = 0;
  final _queue = <({DateTime capturedAt, Map<String, dynamic> point})>[];

  /// Whether [start] was called and uploading has not stopped since.
  bool get isActive => _tripId != null;

  /// Begins uploading for [tripId] under [assignmentId]; sequences are
  /// milliseconds since [startedAt] so a restarted app reproduces them.
  void start({
    required String tripId,
    required String assignmentId,
    required DateTime startedAt,
  }) {
    stop();
    _tripId = tripId;
    _assignmentId = assignmentId;
    _startedAt = startedAt;
    _timer = Timer.periodic(flushInterval, (_) => flush());
  }

  /// Queues a real GPS [sample]; flushes early once [maxBatchSize] is reached.
  void add(VanTelemetryUpdate sample) {
    final startedAt = _startedAt;
    if (startedAt == null || state.value == TelemetrySyncState.rejected) return;
    // Simulated or accuracy-less fixes are not real telemetry.
    if (sample.isSimulated || sample.accuracyMeters == null) return;

    final sequence = sample.timestamp.difference(startedAt).inMilliseconds;
    // Backend requires sequence > 0 and unique per assignment; a fix captured
    // in the same millisecond (or out of order) as the last one is skipped.
    if (sequence <= 0 || sequence <= _lastSequence) return;
    _lastSequence = sequence;

    final heading = sample.headingDegrees;
    final speedMs = sample.speedKmh / 3.6;
    _queue.add((
      capturedAt: sample.timestamp,
      point: {
        'sequence': sequence,
        'captured_at': sample.timestamp.toUtc().toIso8601String(),
        'latitude': sample.position.latitude,
        'longitude': sample.position.longitude,
        'accuracy': sample.accuracyMeters,
        'speed': speedMs.isFinite && speedMs >= 0 ? speedMs : null,
        // Backend accepts [0, 360); 360° and negative bearings wrap around.
        'heading': heading.isFinite ? heading % 360 : null,
      },
    ));
    if (_queue.length >= maxBatchSize) flush();
  }

  /// Sends the queued points now (no-op when empty or already sending).
  Future<void> flush() async {
    final tripId = _tripId;
    if (tripId == null || _inFlight) return;
    final cutoff = _now().subtract(maxPointAge);
    _queue.removeWhere((p) => p.capturedAt.isBefore(cutoff));
    if (_queue.isEmpty) return;

    final batch = List.of(_queue.take(200));
    _queue.removeRange(0, batch.length);
    _inFlight = true;
    state.value = TelemetrySyncState.syncing;
    try {
      await _send({
        'p_trip_id': tripId,
        'p_assignment_id': _assignmentId,
        'p_points': [for (final p in batch) p.point],
        'p_live': true,
      });
      if (_tripId == tripId) state.value = TelemetrySyncState.synced;
    } catch (error) {
      if (_tripId != tripId) return; // stopped meanwhile
      final code = error is PostgrestException ? error.code : null;
      if (_rejectedCodes.contains(code)) {
        _stopUploads();
        state.value = TelemetrySyncState.rejected;
      } else {
        // Transient (rate limit, 5xx, network): retry the identical points;
        // identical payloads are deduplicated by the backend.
        if (!_droppedCodes.contains(code)) _queue.insertAll(0, batch);
        state.value = TelemetrySyncState.failing;
      }
    } finally {
      _inFlight = false;
    }
  }

  /// Stops uploading and discards queued points (live points after the trip
  /// ends would be rejected anyway).
  void stop() {
    _stopUploads();
    state.value = TelemetrySyncState.idle;
  }

  void _stopUploads() {
    _timer?.cancel();
    _timer = null;
    _queue.clear();
    _tripId = null;
    _assignmentId = null;
    _startedAt = null;
    _lastSequence = 0;
  }
}
