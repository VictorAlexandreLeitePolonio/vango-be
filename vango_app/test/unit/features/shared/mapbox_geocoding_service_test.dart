import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vango_app/core/config/mapbox_config.dart';
import 'package:vango_app/features/shared/services/mapbox_geocoding_service.dart';

void main() {
  setUp(() {
    MapboxGeocodingService.clearCache();
  });

  tearDown(() {
    MapboxGeocodingService.clearCache();
  });

  const config = MapboxConfig(accessToken: 'test_token');

  test('returns empty list without network call for queries shorter than 3 chars', () async {
    int calls = 0;
    final client = MockClient((request) async {
      calls++;
      return http.Response('{}', 200);
    });

    final service = MapboxGeocodingService(client: client, config: config);
    final results = await service.searchAddresses('ab');

    expect(results, isEmpty);
    expect(calls, 0);
  });

  test('parses Mapbox geocoding features and context correctly', () async {
    final mockResponse = {
      'type': 'FeatureCollection',
      'features': [
        {
          'id': 'address.12345',
          'place_name': 'Rua Oscar Freire, 1000, Cerqueira César, São Paulo, SP, Brasil',
          'text': 'Rua Oscar Freire',
          'address': '1000',
          'center': [-46.6698, -23.5615],
          'context': [
            {'id': 'neighborhood.1', 'text': 'Cerqueira César'},
            {'id': 'place.1', 'text': 'São Paulo'},
            {'id': 'region.1', 'text': 'São Paulo', 'short_code': 'BR-SP'},
            {'id': 'postcode.1', 'text': '01426-001'},
          ],
        },
      ],
    };

    int calls = 0;
    final client = MockClient((request) async {
      calls++;
      expect(request.url.queryParameters['access_token'], 'test_token');
      expect(request.url.queryParameters['country'], 'BR');
      return http.Response(jsonEncode(mockResponse), 200);
    });

    final service = MapboxGeocodingService(client: client, config: config);
    final results = await service.searchAddresses('Oscar Freire');

    expect(calls, 1);
    expect(results.length, 1);
    final suggestion = results.first;
    expect(suggestion.placeName, 'Rua Oscar Freire, 1000, Cerqueira César, São Paulo, SP, Brasil');
    expect(suggestion.street, 'Rua Oscar Freire');
    expect(suggestion.streetNumber, '1000');
    expect(suggestion.neighborhood, 'Cerqueira César');
    expect(suggestion.cityName, 'São Paulo');
    expect(suggestion.stateCode, 'SP');
    expect(suggestion.postalCode, '01426-001');
    expect(suggestion.latitude, -23.5615);
    expect(suggestion.longitude, -46.6698);
  });

  test('uses local cache on subsequent calls to prevent quota usage', () async {
    final mockResponse = {
      'type': 'FeatureCollection',
      'features': [
        {
          'id': 'address.1',
          'place_name': 'Alameda Santos, 1000, Cerqueira César, São Paulo',
          'text': 'Alameda Santos',
          'center': [-46.6575, -23.5601],
          'context': [],
        }
      ],
    };

    int calls = 0;
    final client = MockClient((request) async {
      calls++;
      return http.Response(jsonEncode(mockResponse), 200);
    });

    final service = MapboxGeocodingService(client: client, config: config);
    final first = await service.searchAddresses('Alameda Santos');
    final second = await service.searchAddresses('Alameda Santos');

    expect(calls, 1);
    expect(first.length, second.length);
    expect(first.first.placeName, second.first.placeName);
  });

  test('returns empty list gracefully on network error without throwing', () async {
    final client = MockClient((request) async {
      throw Exception('Network unreachable');
    });

    final service = MapboxGeocodingService(client: client, config: config);
    final results = await service.searchAddresses('Av Paulista');

    expect(results, isEmpty);
  });
}
