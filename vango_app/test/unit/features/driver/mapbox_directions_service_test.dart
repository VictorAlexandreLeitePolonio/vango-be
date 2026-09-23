import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:vango_app/core/config/mapbox_config.dart';
import 'package:vango_app/features/driver/services/mapbox_directions_service.dart';

void main() {
  setUp(() {
    MapboxDirectionsService.clearCache();
  });

  tearDown(() {
    MapboxDirectionsService.clearCache();
  });

  const testCoords = [
    LatLng(-23.5615, -46.6698),
    LatLng(-23.5601, -46.6575),
    LatLng(-23.5745, -46.6405),
  ];

  test('parses Mapbox Directions API response correctly', () async {
    final mockResponse = {
      'code': 'Ok',
      'routes': [
        {
          'distance': 7450.5,
          'duration': 1320.0,
          'geometry': {
            'coordinates': [
              [-46.6698, -23.5615],
              [-46.6575, -23.5601],
              [-46.6405, -23.5745],
            ],
          },
        }
      ],
    };

    int requestCount = 0;
    final client = MockClient((request) async {
      requestCount++;
      return http.Response(jsonEncode(mockResponse), 200);
    });

    final service = MapboxDirectionsService(
      client: client,
      config: const MapboxConfig(accessToken: 'mock-token'),
    );

    final result = await service.getDrivingRoute(
      cacheKey: 'trip-1',
      coordinates: testCoords,
    );

    expect(requestCount, 1);
    expect(result.isFromCache, false);
    expect(result.totalDistanceMeters, 7450.5);
    expect(result.totalDurationSeconds, 1320.0);
    expect(result.polylinePoints.length, 3);
    expect(result.polylinePoints.first.latitude, -23.5615);
  });

  test('uses cache on subsequent calls and strictly avoids new HTTP requests', () async {
    final mockResponse = {
      'code': 'Ok',
      'routes': [
        {
          'distance': 5000.0,
          'duration': 600.0,
          'geometry': {
            'coordinates': [
              [-46.6698, -23.5615],
              [-46.6405, -23.5745],
            ],
          },
        }
      ],
    };

    int requestCount = 0;
    final client = MockClient((request) async {
      requestCount++;
      return http.Response(jsonEncode(mockResponse), 200);
    });

    final service = MapboxDirectionsService(
      client: client,
      config: const MapboxConfig(accessToken: 'mock-token'),
    );

    // First call: makes HTTP request
    final firstResult = await service.getDrivingRoute(
      cacheKey: 'trip-cached',
      coordinates: testCoords,
    );
    expect(requestCount, 1);
    expect(firstResult.isFromCache, false);

    // Second call with same cacheKey: MUST use cache without making any HTTP request
    final secondResult = await service.getDrivingRoute(
      cacheKey: 'trip-cached',
      coordinates: testCoords,
    );
    expect(requestCount, 1); // requestCount stays 1!
    expect(secondResult.isFromCache, true);
    expect(secondResult.totalDistanceMeters, firstResult.totalDistanceMeters);
  });

  test('falls back gracefully on network error without throwing', () async {
    final client = MockClient((request) async {
      throw Exception('Network unreachable');
    });

    final service = MapboxDirectionsService(
      client: client,
      config: const MapboxConfig(accessToken: 'mock-token'),
    );

    final result = await service.getDrivingRoute(
      cacheKey: 'trip-error',
      coordinates: testCoords,
    );

    expect(result.polylinePoints.length, testCoords.length);
    expect(result.totalDistanceMeters, greaterThan(0));
    expect(result.totalDurationSeconds, 1200.0);
  });
}
