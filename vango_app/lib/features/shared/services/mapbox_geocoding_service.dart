import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

import '../../../core/config/mapbox_config.dart';

/// Safe categories exposed by address searches.
enum MapboxGeocodingFailure { timeout, transport, provider, invalidResponse }

/// Sanitized search failure with optional provider HTTP status.
class MapboxGeocodingException implements Exception {
  const MapboxGeocodingException(this.failure, {this.statusCode});
  final MapboxGeocodingFailure failure;
  final int? statusCode;

  @override
  String toString() => 'MapboxGeocodingException($failure, $statusCode)';
}

/// Immutable address suggestion containing only provider-supplied metadata.
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

/// Searches address points with sanitized failures and no result retention.
class MapboxGeocodingService {
  MapboxGeocodingService({http.Client? client, MapboxConfig? config})
    : _client = client ?? http.Client(),
      _config = config ?? const MapboxConfig.fromEnvironment();

  final http.Client _client;
  final MapboxConfig _config;

  /// Searches [query], returning usable points or a sanitized search failure.
  Future<List<MapboxPlaceSuggestion>> searchAddresses(String query) async {
    final trimmed = query.trim();
    if (trimmed.length < 3) return [];

    final encoded = Uri.encodeComponent(trimmed);
    final uri = Uri.parse(
      'https://api.mapbox.com/geocoding/v5/mapbox.places/$encoded.json'
      '?country=BR&language=pt&types=address'
      '&access_token=${_config.accessToken}',
    );

    try {
      final response = await _client
          .get(uri)
          .timeout(const Duration(seconds: 5));
      if (response.statusCode != 200) {
        throw MapboxGeocodingException(
          MapboxGeocodingFailure.provider,
          statusCode: response.statusCode,
        );
      }
      return _parseResponse(response.body);
    } on FormatException {
      throw const MapboxGeocodingException(
        MapboxGeocodingFailure.invalidResponse,
      );
    } on TypeError {
      throw const MapboxGeocodingException(
        MapboxGeocodingFailure.invalidResponse,
      );
    } on TimeoutException {
      throw const MapboxGeocodingException(MapboxGeocodingFailure.timeout);
    } on http.ClientException {
      throw const MapboxGeocodingException(MapboxGeocodingFailure.transport);
    }
  }

  List<MapboxPlaceSuggestion> _parseResponse(String body) {
    final data = jsonDecode(body);
    if (data is! Map<String, dynamic> || data['features'] is! List) {
      throw const MapboxGeocodingException(
        MapboxGeocodingFailure.invalidResponse,
      );
    }
    final features = data['features'] as List;
    final suggestions = features.map(_parseFeature).nonNulls.toList();
    if (features.isNotEmpty && suggestions.isEmpty) {
      throw const MapboxGeocodingException(
        MapboxGeocodingFailure.invalidResponse,
      );
    }
    return suggestions;
  }

  MapboxPlaceSuggestion? _parseFeature(Object? feature) {
    if (feature is! Map<String, dynamic>) return null;
    final types = feature['place_type'];
    if (types is! List || types.length != 1 || types.single != 'address') {
      return null;
    }
    final properties = feature['properties'];
    if (properties is Map &&
        [
          'street',
          'intersection',
          'approximate',
        ].contains(properties['accuracy'])) {
      return null;
    }
    if ([
      'place_name',
      'text',
      'address',
    ].any((key) => feature[key] != null && feature[key] is! String)) {
      return null;
    }
    final placeName = feature['place_name'] as String? ?? '';
    final street = feature['text'] as String? ?? '';
    if (placeName.trim().isEmpty || street.trim().isEmpty) return null;
    final center = feature['center'];
    if (center is! List ||
        center.length != 2 ||
        center[0] is! num ||
        center[1] is! num) {
      return null;
    }
    final longitude = (center[0] as num).toDouble();
    final latitude = (center[1] as num).toDouble();
    if (!longitude.isFinite ||
        !latitude.isFinite ||
        longitude.abs() > 180 ||
        latitude.abs() > 90) {
      return null;
    }
    final context = _parseContext(feature['context']);
    if (context == null) return null;
    return MapboxPlaceSuggestion(
      placeName: placeName,
      street: street,
      streetNumber: feature['address'] as String? ?? '',
      neighborhood: context.neighborhood,
      cityName: context.cityName,
      cityIbgeCode: '', // The provider supplies no authoritative IBGE code.
      stateCode: context.stateCode,
      postalCode: context.postalCode,
      latitude: latitude,
      longitude: longitude,
    );
  }

  ({String neighborhood, String cityName, String stateCode, String postalCode})?
  _parseContext(Object? rawContext) {
    if (rawContext != null && rawContext is! List) return null;
    var neighborhood = '';
    var cityName = '';
    var stateCode = '';
    var postalCode = '';
    final cities = <String>{};
    final regions = <String>{};
    for (final context in rawContext as List? ?? []) {
      if (context is! Map<String, dynamic>) continue;
      final id = context['id'] is String ? context['id'] as String : '';
      final name = context['text'] is String ? context['text'] as String : '';
      if (id.startsWith('neighborhood.')) {
        neighborhood = name;
      } else if (id.startsWith('place.')) {
        cities.add(name.trim().toLowerCase());
        cityName = name;
      } else if (id.startsWith('region.')) {
        final shortCode = context['short_code'] is String
            ? context['short_code'] as String
            : '';
        final normalized = shortCode.trim().toUpperCase();
        regions.add(normalized);
        stateCode =
            RegExp(
              r'^BR-(AC|AL|AP|AM|BA|CE|DF|ES|GO|MA|MT|MS|MG|PA|PB|PR|PE|PI|RJ|RN|RS|RO|RR|SC|SP|SE|TO)$',
            ).hasMatch(normalized)
            ? normalized.substring(3)
            : '';
      } else if (id.startsWith('postcode')) {
        postalCode = name;
      }
    }
    // Conflicting administrative context cannot identify a covered municipality.
    if (cities.length > 1 || regions.length > 1) return null;
    return (
      neighborhood: neighborhood,
      cityName: cityName,
      stateCode: stateCode,
      postalCode: postalCode,
    );
  }

  /// Compatibility hook: temporary endpoint results are never cached.
  static void clearCache() {}
}
