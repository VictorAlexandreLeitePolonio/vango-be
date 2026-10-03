import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:vango_app/features/driver/services/driver_location_service.dart';
import 'package:vango_app/features/driver/services/trip_telemetry_uploader.dart';

final startedAt = DateTime.utc(2026, 10, 5, 9, 0);

VanTelemetryUpdate sample(
  int secondsAfterStart, {
  bool simulated = false,
  double? accuracy = 8,
  double heading = 90,
  double speedKmh = 36,
}) => VanTelemetryUpdate(
  position: const LatLng(-23.5, -46.6),
  headingDegrees: heading,
  speedKmh: speedKmh,
  timestamp: startedAt.add(Duration(seconds: secondsAfterStart)),
  accuracyMeters: accuracy,
  isSimulated: simulated,
);

/// Records every RPC call and answers with the queued outcomes in order
/// (`null` = success).
class FakeSender {
  final calls = <Map<String, dynamic>>[];
  final outcomes = <Object?>[];

  Future<void> call(Map<String, dynamic> params) async {
    calls.add(params);
    if (outcomes.isEmpty) return;
    final outcome = outcomes.removeAt(0);
    if (outcome != null) throw outcome;
  }

  List<int> sequences(int call) => [
    for (final p in calls[call]['p_points'] as List) (p as Map)['sequence'],
  ];
}

void main() {
  late FakeSender sender;
  late DateTime now;

  TripTelemetryUploader uploader({
    Duration interval = const Duration(hours: 1),
  }) => TripTelemetryUploader(
    send: sender.call,
    now: () => now,
    flushInterval: interval,
  )..start(tripId: 'trip-1', assignmentId: 'asg-1', startedAt: startedAt);

  setUp(() {
    sender = FakeSender();
    now = startedAt.add(const Duration(seconds: 10));
  });

  test('maps a GPS sample to the exact ingest payload', () async {
    final up = uploader()..add(sample(5, heading: 360, speedKmh: 36));
    expect(up.isActive, isTrue);
    await up.flush();

    expect(sender.calls.single, {
      'p_trip_id': 'trip-1',
      'p_assignment_id': 'asg-1',
      'p_live': true,
      'p_points': [
        {
          'sequence': 5000,
          'captured_at': '2026-10-05T09:00:05.000Z',
          'latitude': -23.5,
          'longitude': -46.6,
          'accuracy': 8.0,
          'speed': 10.0,
          'heading': 0.0,
        },
      ],
    });
    expect(up.state.value, TelemetrySyncState.synced);
    up.stop();
  });

  test('sequence is deterministic across uploader instances', () async {
    final first = uploader()..add(sample(7));
    await first.flush();
    first.stop();
    final second = uploader()..add(sample(7));
    await second.flush();
    second.stop();

    expect(sender.sequences(0), [7000]);
    expect(sender.sequences(1), [7000]);
  });

  test('flushes as soon as 20 points are queued', () async {
    now = startedAt.add(const Duration(seconds: 25));
    final up = uploader();
    for (var i = 1; i <= 20; i++) {
      up.add(sample(i));
    }
    await Future<void>.delayed(Duration.zero);

    expect(sender.calls, hasLength(1));
    expect(sender.sequences(0), hasLength(20));
    up.stop();
  });

  test('flushes on the timer', () async {
    final up = uploader(interval: const Duration(milliseconds: 10))
      ..add(sample(5));
    await Future<void>.delayed(const Duration(milliseconds: 40));

    expect(sender.calls, hasLength(1));
    up.stop();
  });

  test('drops points older than 25 s at flush time', () async {
    now = startedAt.add(const Duration(seconds: 40));
    final up = uploader()
      ..add(sample(10))
      ..add(sample(20));
    await up.flush();

    expect(sender.sequences(0), [20000]);
    up.stop();
  });

  test('ignores simulated, pre-start and accuracy-less samples', () async {
    final up = uploader()
      ..add(sample(5, simulated: true))
      ..add(sample(-1))
      ..add(sample(0))
      ..add(sample(6, accuracy: null));
    await up.flush();

    expect(sender.calls, isEmpty);
    up.stop();
  });

  test('re-queues the batch on rate limit and network failures', () async {
    sender.outcomes.addAll([
      const PostgrestException(message: 'GPS', code: 'rate_limited'),
      Exception('offline'),
    ]);
    final up = uploader()..add(sample(5));

    await up.flush();
    expect(up.state.value, TelemetrySyncState.failing);
    up.add(sample(6));
    await up.flush();
    expect(up.state.value, TelemetrySyncState.failing);
    await up.flush();

    expect(sender.sequences(2), [5000, 6000]);
    expect(up.state.value, TelemetrySyncState.synced);
    up.stop();
  });

  test('drops a batch the backend can never accept', () async {
    sender.outcomes.add(
      const PostgrestException(message: 'GPS', code: 'idempotency_conflict'),
    );
    final up = uploader()..add(sample(5));
    await up.flush();
    await up.flush();

    expect(sender.calls, hasLength(1));
    up.stop();
  });

  test('stops uploading when the backend rejects the trip', () async {
    sender.outcomes.add(
      const PostgrestException(message: 'GPS', code: 'invalid_transition'),
    );
    final up = uploader()..add(sample(5));
    await up.flush();
    up.add(sample(6));
    await up.flush();

    expect(sender.calls, hasLength(1));
    expect(up.state.value, TelemetrySyncState.rejected);
    up.stop();
  });

  test('stop discards the queue and cancels the timer', () async {
    final up = uploader(interval: const Duration(milliseconds: 10))
      ..add(sample(5))
      ..stop();
    await Future<void>.delayed(const Duration(milliseconds: 40));

    expect(sender.calls, isEmpty);
    expect(up.state.value, TelemetrySyncState.idle);
    expect(up.isActive, isFalse);
  });
}
