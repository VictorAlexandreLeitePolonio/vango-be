import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../../core/config/mapbox_config.dart';

class MapboxPlaceSuggestion {
  const MapboxPlaceSuggestion({
    required this.placeName,
    required this.street,
    required this.streetNumber,
    required this.neighborhood,
    required this.cityName,
    required this.cityIbgeCode,
    required this.stateCode,
    required this.postalCode,
    required this.latitude,
    required this.longitude,
  });

  final String placeName;
  final String street;
  final String streetNumber;
  final String neighborhood;
  final String cityName;
  final String cityIbgeCode;
  final String stateCode;
  final String postalCode;
  final double latitude;
  final double longitude;
}

class MapboxGeocodingService {
  MapboxGeocodingService({
    http.Client? client,
    MapboxConfig? config,
  })  : _client = client ?? http.Client(),
        _config = config ?? const MapboxConfig.fromEnvironment();

  final http.Client _client;
  final MapboxConfig _config;

  static final Map<String, List<MapboxPlaceSuggestion>> _cache = {};

  Future<List<MapboxPlaceSuggestion>> searchAddresses(String query) async {
    final trimmed = query.trim();
    if (trimmed.length < 3) return [];

    final cacheKey = trimmed.toLowerCase();
    if (_cache.containsKey(cacheKey)) {
      debugPrint('[MapboxGeocoding] ⚡ Sugestões recuperadas do cache local.');
      return _cache[cacheKey]!;
    }

    final encoded = Uri.encodeComponent(trimmed);
    final uri = Uri.parse(
      'https://api.mapbox.com/geocoding/v5/mapbox.places/$encoded.json'
      '?country=BR&language=pt&proximity=-46.655,-23.565&types=address,poi,place'
      '&access_token=${_config.accessToken}',
    );

    debugPrint('[MapboxGeocoding] 🌐 Consultando autocomplete Mapbox para: "$trimmed"');

    try {
      final response = await _client.get(uri).timeout(const Duration(seconds: 5));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final features = data['features'] as List<dynamic>? ?? [];

        final suggestions = <MapboxPlaceSuggestion>[];

        for (final item in features) {
          if (item is! Map<String, dynamic>) continue;

          final placeName = item['place_name'] as String? ?? '';
          final text = item['text'] as String? ?? '';
          final addressNum = item['address'] as String? ?? '';
          final center = item['center'] as List<dynamic>?;

          if (center == null || center.length < 2) continue;

          final lon = (center[0] as num).toDouble();
          final lat = (center[1] as num).toDouble();

          String neighborhood = '';
          String cityName = 'São Paulo';
          String stateCode = 'SP';
          String postalCode = '01000-000';

          final contextList = item['context'] as List<dynamic>? ?? [];
          for (final ctx in contextList) {
            if (ctx is! Map<String, dynamic>) continue;
            final id = ctx['id'] as String? ?? '';
            final name = ctx['text'] as String? ?? '';

            if (id.startsWith('neighborhood') || id.startsWith('locality')) {
              neighborhood = name;
            } else if (id.startsWith('place')) {
              cityName = name;
            } else if (id.startsWith('region')) {
              final shortCode = ctx['short_code'] as String? ?? '';
              stateCode = shortCode.replaceFirst('BR-', '');
              if (stateCode.isEmpty) stateCode = 'SP';
            } else if (id.startsWith('postcode')) {
              postalCode = name;
            }
          }

          suggestions.add(
            MapboxPlaceSuggestion(
              placeName: placeName,
              street: text,
              streetNumber: addressNum.isNotEmpty ? addressNum : 'S/N',
              neighborhood: neighborhood.isNotEmpty ? neighborhood : 'Centro',
              cityName: cityName,
              cityIbgeCode: '3550308', // Default SP IBGE code for local MVP
              stateCode: stateCode,
              postalCode: postalCode,
              latitude: lat,
              longitude: lon,
            ),
          );
        }

        _cache[cacheKey] = suggestions;
        return suggestions;
      }
    } catch (e) {
      debugPrint('[MapboxGeocoding] ❌ Erro ao buscar endereços no Mapbox: $e');
    }

    return [];
  }

  static void clearCache() {
    _cache.clear();
  }
}
