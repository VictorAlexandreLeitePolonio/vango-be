import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vango_app/features/shared/services/mapbox_geocoding_service.dart';
import 'package:vango_app/shared/widgets/mapbox_address_autocomplete_field.dart';

class ControlledGeocoder extends MapboxGeocodingService {
  final requests = <Completer<List<MapboxPlaceSuggestion>>>[];
  final queries = <String>[];

  @override
  Future<List<MapboxPlaceSuggestion>> searchAddresses(String query) {
    queries.add(query);
    final request = Completer<List<MapboxPlaceSuggestion>>();
    requests.add(request);
    return request.future;
  }
}

MapboxPlaceSuggestion suggestion(String name) => MapboxPlaceSuggestion(
  placeName: name,
  street: name,
  streetNumber: '1',
  neighborhood: '',
  cityName: 'Recife',
  cityIbgeCode: '',
  stateCode: 'PE',
  postalCode: '',
  latitude: -8,
  longitude: -34,
);

Widget field(
  TextEditingController controller,
  ControlledGeocoder service, {
  ValueChanged<MapboxPlaceSuggestion>? onSelected,
  ValueChanged<String>? onChanged,
}) => MaterialApp(
  home: Scaffold(
    body: MapboxAddressAutocompleteField(
      controller: controller,
      geocodingService: service,
      onAddressSelected: onSelected ?? (_) {},
      onChanged: onChanged,
    ),
  ),
);

void main() {
  for (final invalidate in [
    'short edit',
    'clear',
    'programmatic',
    'dispose',
    'city key',
  ]) {
    testWidgets('ignores late completion after $invalidate', (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      final service = ControlledGeocoder();
      await tester.pumpWidget(field(controller, service));
      await tester.enterText(find.byType(TextFormField), 'old query');
      await tester.pump(const Duration(milliseconds: 400));
      if (invalidate == 'short edit' || invalidate == 'clear') {
        await tester.enterText(
          find.byType(TextFormField),
          invalidate == 'clear' ? '' : 'a',
        );
      } else if (invalidate == 'programmatic') {
        controller.clear();
      } else if (invalidate == 'dispose') {
        await tester.pumpWidget(const SizedBox());
      } else {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: MapboxAddressAutocompleteField(
                key: const ValueKey('new-city'),
                controller: controller,
                geocodingService: service,
                onAddressSelected: (_) {},
              ),
            ),
          ),
        );
      }
      service.requests.single.complete([suggestion('Old result')]);
      await tester.pump();
      expect(find.text('Old result'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'ignores old completion during the new debounce and after selection',
    (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      final service = ControlledGeocoder();
      await tester.pumpWidget(field(controller, service));
      await tester.enterText(find.byType(TextFormField), 'old query');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.enterText(find.byType(TextFormField), 'new query');
      service.requests.first.complete([suggestion('Old result')]);
      await tester.pump();
      expect(find.text('Old result'), findsNothing);
      await tester.pump(const Duration(milliseconds: 400));
      service.requests.last.complete([suggestion('Selected result')]);
      await tester.pump();
      await tester.tap(find.text('Selected result'));
      await tester.pump();
      expect(find.byType(ListTile), findsNothing);
      expect(find.text('Nenhum endereço encontrado.'), findsNothing);
    },
  );

  testWidgets(
    'keeps error and retry accessible at narrow width and large text',
    (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      final service = ControlledGeocoder();
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: Scaffold(
              body: MapboxAddressAutocompleteField(
                controller: controller,
                geocodingService: service,
                onAddressSelected: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.enterText(find.byType(TextFormField), 'query');
      await tester.pump(const Duration(milliseconds: 400));
      service.requests.single.completeError(Exception('sensitive raw cause'));
      await tester.pump();
      expect(find.text('Tentar novamente'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.enterText(find.byType(TextFormField), 'a');
      await tester.pump();
      expect(find.text('Tentar novamente'), findsNothing);
      expect(service.queries, ['query']);
    },
  );

  testWidgets('parent may remove field synchronously from edit callback', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final service = ControlledGeocoder();
    var visible = true;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) => Scaffold(
            body: visible
                ? MapboxAddressAutocompleteField(
                    controller: controller,
                    geocodingService: service,
                    onAddressSelected: (_) {},
                    onChanged: (_) {
                      setState(() {
                        visible = false;
                      });
                    },
                  )
                : const SizedBox(),
          ),
        ),
      ),
    );
    await tester.enterText(find.byType(TextFormField), 'query');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(service.queries, isEmpty);
    expect(tester.takeException(), isNull);
  });

  for (final replaceController in [true, false]) {
    testWidgets(
      'invalidates pending request on ${replaceController ? 'controller' : 'service'} replacement',
      (tester) async {
        final controller = TextEditingController();
        final replacement = TextEditingController();
        addTearDown(controller.dispose);
        addTearDown(replacement.dispose);
        final service = ControlledGeocoder();
        final nextService = ControlledGeocoder();
        await tester.pumpWidget(field(controller, service));
        await tester.enterText(find.byType(TextFormField), 'old query');
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pumpWidget(
          field(
            replaceController ? replacement : controller,
            replaceController ? service : nextService,
          ),
        );
        service.requests.single.complete([suggestion('Old result')]);
        await tester.pump();
        expect(find.text('Old result'), findsNothing);
        await tester.enterText(find.byType(TextFormField), 'new query');
        await tester.pump(const Duration(milliseconds: 400));
        final active = replaceController ? service : nextService;
        expect(active.queries.last, 'new query');
        active.requests.last.complete([]);
        await tester.pump();
      },
    );
  }

  testWidgets(
    'notifies edits once and selection only through selection callback',
    (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      final service = ControlledGeocoder();
      final edits = <String>[];
      final selected = <MapboxPlaceSuggestion>[];
      await tester.pumpWidget(
        field(
          controller,
          service,
          onSelected: selected.add,
          onChanged: edits.add,
        ),
      );
      await tester.enterText(find.byType(TextFormField), 'street');
      expect(edits, ['street']);
      await tester.pump(const Duration(milliseconds: 400));
      service.requests.single.complete([suggestion('Selected address')]);
      await tester.pump();
      await tester.tap(find.text('Selected address'));
      await tester.pump();
      expect(selected, hasLength(1));
      expect(edits, ['street']);
      await tester.pump(const Duration(milliseconds: 400));
      expect(service.queries, ['street']);
      expect(find.text('Nenhum endereço encontrado.'), findsNothing);
      await tester.enterText(find.byType(TextFormField), 'a');
      expect(edits, ['street', 'a']);
    },
  );

  testWidgets('programmatic text changes invalidate pending results', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final service = ControlledGeocoder();
    await tester.pumpWidget(field(controller, service));
    await tester.enterText(find.byType(TextFormField), 'old query');
    await tester.pump(const Duration(milliseconds: 400));
    controller.text = 'replacement';
    service.requests.single.complete([suggestion('Old result')]);
    await tester.pump();
    expect(find.text('Old result'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.pump(const Duration(milliseconds: 400));
    expect(service.queries, ['old query']);
  });

  for (final lateFailure in [false, true]) {
    testWidgets(
      'ignores late ${lateFailure ? 'failure' : 'success'} after a newer result',
      (tester) async {
        final controller = TextEditingController();
        addTearDown(controller.dispose);
        final service = ControlledGeocoder();
        await tester.pumpWidget(field(controller, service));
        await tester.enterText(find.byType(TextFormField), 'old query');
        await tester.pump(const Duration(milliseconds: 400));
        await tester.enterText(find.byType(TextFormField), 'new query');
        await tester.pump(const Duration(milliseconds: 400));
        service.requests.last.complete([suggestion('New result')]);
        await tester.pump();
        if (lateFailure) {
          service.requests.first.completeError(Exception('sensitive'));
        } else {
          service.requests.first.complete([suggestion('Old result')]);
        }
        await tester.pump();
        expect(find.text('New result'), findsOneWidget);
        expect(find.text('Old result'), findsNothing);
        expect(find.text('Tentar novamente'), findsNothing);
      },
    );
  }

  testWidgets('distinguishes empty success from short-query idle', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final service = ControlledGeocoder();
    await tester.pumpWidget(field(controller, service));
    await tester.enterText(find.byType(TextFormField), 'Rua Recife');
    await tester.pump(const Duration(milliseconds: 400));
    service.requests.single.complete([]);
    await tester.pump();
    expect(find.text('Nenhum endereço encontrado.'), findsOneWidget);
    expect(find.text('Tentar novamente'), findsNothing);
    await tester.enterText(find.byType(TextFormField), 'ab');
    await tester.pump();
    expect(find.text('Nenhum endereço encontrado.'), findsNothing);
  });

  testWidgets('shows safe failure and retries the current search', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final service = ControlledGeocoder();
    final selected = <MapboxPlaceSuggestion>[];
    await tester.pumpWidget(
      field(controller, service, onSelected: selected.add),
    );
    await tester.enterText(find.byType(TextFormField), 'Rua Recife');
    await tester.pump(const Duration(milliseconds: 400));
    service.requests.single.completeError(
      const MapboxGeocodingException(
        MapboxGeocodingFailure.provider,
        statusCode: 429,
      ),
    );
    await tester.pump();
    expect(
      find.text('Não foi possível buscar endereços. Tente novamente.'),
      findsOneWidget,
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(selected, isEmpty);
    await tester.tap(find.text('Tentar novamente'));
    await tester.pump();
    expect(service.queries, ['Rua Recife', 'Rua Recife']);
    service.requests.last.complete([suggestion('Current result')]);
    await tester.pump();
    expect(find.text('Current result'), findsOneWidget);
  });
}
