import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../../../core/config/mapbox_config.dart';

class DirectionsResult {
  const DirectionsResult({
    required this.polylinePoints,
    required this.totalDistanceMeters,
    required this.totalDurationSeconds,
    this.isFromCache = false,
  });

  final List<LatLng> polylinePoints;
  final double totalDistanceMeters;
  final double totalDurationSeconds;
  final bool isFromCache;
}

class MapboxDirectionsService {
  MapboxDirectionsService({http.Client? client, MapboxConfig? config})
    : _client = client ?? http.Client(),
      _config = config ?? const MapboxConfig.fromEnvironment();

  final http.Client _client;
  final MapboxConfig _config;

  /// In-memory cache to strictly preserve the user's free tier quota.
  static final Map<String, DirectionsResult> _cache = {};

  /// Retrieves the driving directions for the given sequence of coordinates.
  /// If a cached result exists for [cacheKey], returns it immediately without
  /// performing any network request.
  Future<DirectionsResult> getDrivingRoute({
    required String cacheKey,
    required List<LatLng> coordinates,
  }) async {
    if (_cache.containsKey(cacheKey)) {
      final cached = _cache[cacheKey]!;
      debugPrint(
        '[MapboxDirections] ⚡ Rota recuperada do CACHE LOCAL (0 requisições gastas na API).',
      );
      return DirectionsResult(
        polylinePoints: cached.polylinePoints,
        totalDistanceMeters: cached.totalDistanceMeters,
        totalDurationSeconds: cached.totalDurationSeconds,
        isFromCache: true,
      );
    }

    if (coordinates.length < 2) {
      return DirectionsResult(
        polylinePoints: coordinates,
        totalDistanceMeters: 0,
        totalDurationSeconds: 0,
      );
    }

    // Mapbox expects coordinates in longitude,latitude order separated by ';'
    final coordsParam = coordinates
        .map(
          (c) =>
              '${c.longitude.toStringAsFixed(6)},${c.latitude.toStringAsFixed(6)}',
        )
        .join(';');

    final uri = Uri.parse(
      'https://api.mapbox.com/directions/v5/mapbox/driving/$coordsParam'
      '?geometries=geojson&overview=full&steps=false&access_token=${_config.accessToken}',
    );

    debugPrint(
      '[MapboxDirections] 🌐 Disparando requisição real para Mapbox Directions API...',
    );

    try {
      final response = await _client
          .get(uri)
          .timeout(const Duration(seconds: 8));

      debugPrint(
        '[MapboxDirections] 📡 Resposta HTTP recebida: status ${response.statusCode}',
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final routes = data['routes'] as List<dynamic>?;

        if (routes != null && routes.isNotEmpty) {
          final primaryRoute = routes.first as Map<String, dynamic>;
          final distance =
              (primaryRoute['distance'] as num?)?.toDouble() ?? 0.0;
          final duration =
              (primaryRoute['duration'] as num?)?.toDouble() ?? 0.0;

          final geometry = primaryRoute['geometry'] as Map<String, dynamic>?;
          final coordsList = geometry?['coordinates'] as List<dynamic>?;

          final polylinePoints = <LatLng>[];
          if (coordsList != null) {
            for (final item in coordsList) {
              if (item is List && item.length >= 2) {
                final lon = (item[0] as num).toDouble();
                final lat = (item[1] as num).toDouble();
                polylinePoints.add(LatLng(lat, lon));
              }
            }
          }

          debugPrint(
            '[MapboxDirections] ✅ Rota calculada com sucesso pela API real do Mapbox! '
            'Distância: ${(distance / 1000).toStringAsFixed(1)}km, '
            'Duração: ${(duration / 60).round()}min, '
            'Pontos de rua (polyline): ${polylinePoints.length}',
          );

          final result = DirectionsResult(
            polylinePoints: polylinePoints.isNotEmpty
                ? polylinePoints
                : coordinates,
            totalDistanceMeters: distance,
            totalDurationSeconds: duration,
            isFromCache: false,
          );

          _cache[cacheKey] = result;
          return result;
        }
      } else {
        // Status only: the body and URL echo stop coordinates (home addresses).
        debugPrint(
          '[MapboxDirections] ⚠️ API do Mapbox retornou status diferente de 200: ${response.statusCode}',
        );
      }
    } catch (e) {
      // Type only: client exceptions embed the request URI (coordinates, token).
      debugPrint(
        '[MapboxDirections] ❌ Exceção na requisição do Mapbox: ${e.runtimeType}',
      );
    }

    // No invented straight-line route or fixed duration: callers treat the
    // geometry as unavailable, and the failure is not cached so a later
    // refresh retries the API.
    throw const DirectionsUnavailableException();
  }

  static void clearCache() {
    _cache.clear();
  }
}

/// Mapbox Directions could not produce a route (network error or non-200).
class DirectionsUnavailableException implements Exception {
  const DirectionsUnavailableException();

  @override
  String toString() => 'DirectionsUnavailableException';
}
