import 'dart:convert';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vango_app/core/config/mapbox_config.dart';
import 'package:vango_app/features/shared/services/mapbox_geocoding_service.dart';

Map<String, Object?> addressFeature() => {
  'place_type': ['address'],
  'place_name': 'Rua Recife',
  'text': 'Rua Recife',
  'center': [-34.9, -8.0],
};

void main() {
  testWidgets('enforces five-second timeout and never retains late responses', (
    tester,
  ) async {
    final pending = Completer<http.Response>();
    var calls = 0;
    final service = MapboxGeocodingService(
      client: MockClient((_) {
        calls++;
        return calls == 1
            ? pending.future
            : Future.value(http.Response('{"features":[]}', 200));
      }),
    );
    Object? failure;
    var settled = false;
    final search = service
        .searchAddresses('address')
        .then(
          (_) {
            settled = true;
          },
          onError: (Object error) {
            failure = error;
            settled = true;
          },
        );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 4999));
    expect(settled, isFalse);
    await tester.pump(const Duration(milliseconds: 1));
    await search;
    expect(
      failure,
      isA<MapboxGeocodingException>().having(
        (e) => e.failure,
        'failure',
        MapboxGeocodingFailure.timeout,
      ),
    );
    MapboxGeocodingService.clearCache();
    pending.complete(
      http.Response(
        jsonEncode({
          'features': [addressFeature()],
        }),
        200,
      ),
    );
    await tester.pump();
    expect(await service.searchAddresses('address'), isEmpty);
    expect(calls, 2);
  });

  test('rejects non-finite coordinates decoded from overflow JSON', () async {
    final body = jsonEncode({
      'features': [addressFeature()],
    }).replaceFirst('-34.9', '1e999');
    final service = MapboxGeocodingService(
      client: MockClient((_) async => http.Response(body, 200)),
    );
    await expectLater(
      service.searchAddresses('address'),
      throwsA(isA<MapboxGeocodingException>()),
    );
  });

  test(
    'does not expose sensitive application output across outcomes',
    () async {
      final output = <String>[];
      final original = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        output.add(message ?? '');
      };
      addTearDown(() => debugPrint = original);
      await runZoned(
        () async {
          var calls = 0;
          final service = MapboxGeocodingService(
            config: const MapboxConfig(accessToken: 'SENTINEL_TOKEN'),
            client: MockClient((_) async {
              calls++;
              if (calls == 1) {
                throw http.ClientException(
                  'SENTINEL_URL SENTINEL_CONTACT SENTINEL_QUERY',
                );
              }
              if (calls == 2) return http.Response('SENTINEL_BODY', 200);
              return http.Response(
                jsonEncode({
                  'features': [
                    {
                      ...addressFeature(),
                      'place_name': 'SENTINEL_ADDRESS',
                      'center': [12.3456789, -23.456789],
                    },
                  ],
                }),
                200,
              );
            }),
          );
          for (var attempt = 0; attempt < 4; attempt++) {
            try {
              await service.searchAddresses('SENTINEL_QUERY');
            } on MapboxGeocodingException catch (error) {
              expect(error.toString(), isNot(contains('SENTINEL')));
            }
          }
          expect(calls, 4);
        },
        zoneSpecification: ZoneSpecification(
          print: (_, _, _, String line) {
            output.add(line);
          },
        ),
      );
      expect(output.join(), isNot(contains('SENTINEL')));
      expect(output.join(), isNot(contains('12.3456789')));
    },
  );

  test('rejects conflicting municipality or region context', () async {
    for (final context in [
      [
        {'id': 'place.1', 'text': 'Recife'},
        {'id': 'place.2', 'text': 'Olinda'},
      ],
      [
        {'id': 'region.1', 'short_code': 'BR-PE'},
        {'id': 'region.2', 'short_code': 'BR-SP'},
      ],
    ]) {
      final service = MapboxGeocodingService(
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'features': [
                {...addressFeature(), 'context': context},
              ],
            }),
            200,
          ),
        ),
      );
      await expectLater(
        service.searchAddresses('address'),
        throwsA(isA<MapboxGeocodingException>()),
      );
    }
  });

  test('rejects blank street or display names', () async {
    for (final malformed in [
      {'text': ' '},
      {'place_name': ''},
      {'text': null},
    ]) {
      final service = MapboxGeocodingService(
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'features': [
                {...addressFeature(), ...malformed},
              ],
            }),
            200,
          ),
        ),
      );
      await expectLater(
        service.searchAddresses('address'),
        throwsA(isA<MapboxGeocodingException>()),
      );
    }
  });

  test('keeps valid rows when another row has malformed metadata', () async {
    for (final malformed in [
      {'text': 42},
      {'place_name': false},
      {'address': []},
      {'context': 'wrong'},
    ]) {
      final service = MapboxGeocodingService(
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'features': [
                {...addressFeature(), ...malformed},
                addressFeature(),
              ],
            }),
            200,
          ),
        ),
      );
      expect(await service.searchAddresses('address'), hasLength(1));
    }
  });

  test('propagates typed timeout failure', () async {
    final service = MapboxGeocodingService(
      client: MockClient((_) async => throw TimeoutException('sensitive')),
    );
    await expectLater(
      service.searchAddresses('address'),
      throwsA(
        isA<MapboxGeocodingException>().having(
          (e) => e.failure,
          'failure',
          MapboxGeocodingFailure.timeout,
        ),
      ),
    );
  });

  test('propagates provider status failures', () async {
    for (final status in [401, 429, 500]) {
      final service = MapboxGeocodingService(
        client: MockClient((_) async => http.Response('secret body', status)),
      );
      await expectLater(
        service.searchAddresses('address'),
        throwsA(
          isA<MapboxGeocodingException>()
              .having(
                (e) => e.failure,
                'failure',
                MapboxGeocodingFailure.provider,
              )
              .having((e) => e.statusCode, 'status', status),
        ),
      );
    }
  });

  test('rejects malformed successful envelopes', () async {
    for (final body in [
      'invalid',
      '[]',
      '{}',
      '{"features":null}',
      '{"features":{}}',
      '{"features":[42]}',
    ]) {
      final service = MapboxGeocodingService(
        client: MockClient((_) async => http.Response(body, 200)),
      );
      await expectLater(
        service.searchAddresses('address'),
        throwsA(
          isA<MapboxGeocodingException>().having(
            (e) => e.failure,
            'failure',
            MapboxGeocodingFailure.invalidResponse,
          ),
        ),
      );
    }
  });

  test('does not fabricate missing address metadata', () async {
    final service = MapboxGeocodingService(
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'features': [
              {
                'id': 'address.1',
                'place_type': ['address'],
                'place_name': 'Real street',
                'text': 'Real street',
                'center': [0, 0],
                'context': [],
              },
            ],
          }),
          200,
        ),
      ),
    );
    final result = (await service.searchAddresses('real street')).single;
    expect([
      result.streetNumber,
      result.neighborhood,
      result.cityName,
      result.cityIbgeCode,
      result.stateCode,
      result.postalCode,
    ], everyElement(isEmpty));
  });

  test(
    'uses honest administrative context without order-dependent fallback',
    () async {
      final service = MapboxGeocodingService(
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'features': [
                {
                  'id': 'address.1',
                  'place_type': ['address'],
                  'place_name': 'Rua Recife',
                  'text': 'Rua Recife',
                  'center': [-34.9, -8.0],
                  'context': [
                    {'id': 'neighborhood.1', 'text': 'Boa Viagem'},
                    {'id': 'locality.1', 'text': 'Less precise'},
                    {'id': 'district.1', 'text': 'Wrong city'},
                    {'id': 'place.1', 'text': 'Recife'},
                    {'id': 'region.1', 'short_code': ' br-pe '},
                    {'id': 'postcode.1', 'text': '51000-000'},
                  ],
                },
              ],
            }),
            200,
          ),
        ),
      );
      final result = (await service.searchAddresses('Rua Recife')).single;
      expect(result.cityName, 'Recife');
      expect(result.stateCode, 'PE');
      expect(result.neighborhood, 'Boa Viagem');
      expect(result.postalCode, '51000-000');
      expect(result.cityIbgeCode, isEmpty);
    },
  );

  test('requests only addresses without fixed geographic bias', () async {
    final service = MapboxGeocodingService(
      client: MockClient((request) async {
        expect(request.url.queryParameters['types'], 'address');
        expect(request.url.queryParameters.containsKey('proximity'), isFalse);
        return http.Response('{"features":[]}', 200);
      }),
    );
    expect(await service.searchAddresses('Rua Recife'), isEmpty);
  });

  test('rejects non-address and coarse accuracy features', () async {
    for (final variant in [
      {
        'place_type': ['place'],
      },
      {
        'place_type': ['poi'],
      },
      {
        'properties': {'accuracy': 'street'},
      },
      {
        'properties': {'accuracy': 'intersection'},
      },
      {
        'properties': {'accuracy': 'approximate'},
      },
    ]) {
      final feature = <String, Object?>{
        'id': 'address.1',
        'place_type': ['address'],
        'text': 'Real street',
        'place_name': 'Real street',
        'center': [0, 0],
        ...variant,
      };
      final service = MapboxGeocodingService(
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'features': [feature],
            }),
            200,
          ),
        ),
      );
      await expectLater(
        service.searchAddresses('address'),
        throwsA(isA<MapboxGeocodingException>()),
      );
    }
  });

  test(
    'filters invalid coordinates while preserving exact valid points',
    () async {
      for (final center in [
        [181, 0],
        [0, 91],
        [-181, 0],
        [0, -91],
        [null, 0],
        ['1', 0],
        [0],
        null,
      ]) {
        final valid = {
          'place_type': ['address'],
          'text': 'Real street',
          'place_name': 'Real street',
          'center': [-180, 90],
        };
        final service = MapboxGeocodingService(
          client: MockClient(
            (_) async => http.Response(
              jsonEncode({
                'features': [
                  {...valid, 'center': center},
                  valid,
                ],
              }),
              200,
            ),
          ),
        );
        final result = (await service.searchAddresses('address')).single;
        expect(result.longitude, -180);
        expect(result.latitude, 90);
      }
    },
  );

  setUp(() {
    MapboxGeocodingService.clearCache();
  });

  tearDown(() {
    MapboxGeocodingService.clearCache();
  });

  const config = MapboxConfig(accessToken: 'test_token');

  test(
    'returns empty list without network call for queries shorter than 3 chars',
    () async {
      int calls = 0;
      final client = MockClient((request) async {
        calls++;
        return http.Response('{}', 200);
      });

      final service = MapboxGeocodingService(client: client, config: config);
      final results = await service.searchAddresses('ab');

      expect(results, isEmpty);
      expect(calls, 0);
    },
  );

  test('parses Mapbox geocoding features and context correctly', () async {
    final mockResponse = {
      'type': 'FeatureCollection',
      'features': [
        {
          'id': 'address.12345',
          'place_type': ['address'],
          'place_name':
              'Rua Oscar Freire, 1000, Cerqueira César, São Paulo, SP, Brasil',
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
    expect(
      suggestion.placeName,
      'Rua Oscar Freire, 1000, Cerqueira César, São Paulo, SP, Brasil',
    );
    expect(suggestion.street, 'Rua Oscar Freire');
    expect(suggestion.streetNumber, '1000');
    expect(suggestion.neighborhood, 'Cerqueira César');
    expect(suggestion.cityName, 'São Paulo');
    expect(suggestion.stateCode, 'SP');
    expect(suggestion.postalCode, '01426-001');
    expect(suggestion.latitude, -23.5615);
    expect(suggestion.longitude, -46.6698);
  });

  test('does not retain temporary provider results', () async {
    final mockResponse = {
      'type': 'FeatureCollection',
      'features': [
        {
          'id': 'address.1',
          'place_type': ['address'],
          'place_name': 'Alameda Santos, 1000, Cerqueira César, São Paulo',
          'text': 'Alameda Santos',
          'center': [-46.6575, -23.5601],
          'context': [],
        },
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

    expect(calls, 2);
    expect(first.length, second.length);
    expect(first.first.placeName, second.first.placeName);
  });

  test('propagates typed transport failure', () async {
    final client = MockClient((request) async {
      throw http.ClientException('https://secret.test/address?token=sentinel');
    });

    final service = MapboxGeocodingService(client: client, config: config);
    await expectLater(
      service.searchAddresses('Av Paulista'),
      throwsA(
        isA<MapboxGeocodingException>().having(
          (e) => e.failure,
          'failure',
          MapboxGeocodingFailure.transport,
        ),
      ),
    );
  });
}
