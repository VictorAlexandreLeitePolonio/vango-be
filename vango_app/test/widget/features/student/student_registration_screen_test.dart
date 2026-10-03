import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vango_app/features/shared/services/mapbox_geocoding_service.dart';
import 'package:vango_app/features/student/screens/student_registration_screen.dart';
import 'package:vango_app/features/student/services/student_service.dart';

import '../../../support/fake_student_data_source.dart';

class FakeGeocodingService extends MapboxGeocodingService {
  @override
  Future<List<MapboxPlaceSuggestion>> searchAddresses(String query) async {
    return [
      const MapboxPlaceSuggestion(
        placeName: 'Rua Bela Cintra, 1400, Consolação, São Paulo',
        street: 'Rua Bela Cintra',
        streetNumber: '1400',
        neighborhood: 'Consolação',
        cityName: 'São Paulo',
        cityIbgeCode: '',
        stateCode: 'SP',
        postalCode: '01415-001',
        latitude: -23.5558,
        longitude: -46.6627,
      ),
    ];
  }
}

void main() {
  testWidgets('renders all fields and labels in student registration', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: StudentRegistrationScreen()),
    );

    expect(find.text('Cadastrar Aluno'), findsOneWidget);
    expect(find.text('Dados do Aluno'), findsOneWidget);
    expect(find.text('Endereço de Embarque (Mapbox)'), findsOneWidget);
    expect(find.text('Salvar Aluno'), findsOneWidget);
    expect(find.byType(TextFormField), findsWidgets);
  });

  testWidgets(
    'shows validation message when attempting submit without selecting Mapbox address',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: StudentRegistrationScreen()),
      );

      // Fill student name (first TextFormField)
      final nameField = find.byType(TextFormField).first;
      await tester.enterText(nameField, 'Pedro Alvares');
      await tester.pump();

      // Scroll to submit button and tap
      final submitBtn = find.text('Salvar Aluno');
      await tester.ensureVisible(submitBtn);
      await tester.tap(submitBtn);
      await tester.pumpAndSettle();

      expect(
        find.text('Selecione uma localização nas sugestões'),
        findsOneWidget,
      );
    },
  );

  /// Fills the name, picks the fake Mapbox suggestion and taps submit.
  Future<void> fillAndSubmit(
    WidgetTester tester,
    StudentService service,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: StudentRegistrationScreen(
          geocodingService: FakeGeocodingService(),
          studentService: service,
        ),
      ),
    );

    final textFields = find.byType(TextFormField);
    await tester.enterText(textFields.first, 'Camila Silveira');

    // index 0: name, index 1: birthdate, index 2: address autocomplete
    await tester.enterText(textFields.at(2), 'Bela Cintra');
    await tester.pump(const Duration(milliseconds: 500)); // wait debounce
    await tester.pumpAndSettle();

    expect(
      find.text('Rua Bela Cintra, 1400, Consolação, São Paulo'),
      findsOneWidget,
    );
    await tester.tap(find.text('Rua Bela Cintra, 1400, Consolação, São Paulo'));
    await tester.pumpAndSettle();

    final submitBtn = find.text('Salvar Aluno');
    await tester.ensureVisible(submitBtn);
    await tester.tap(submitBtn);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'fills address from suggestion and successfully registers student',
    (tester) async {
      final source = FakeStudentDataSource();
      await fillAndSubmit(tester, StudentService(dataSource: source));

      expect(source.lastCreateParams!['p_full_name'], 'Camila Silveira');
      expect(source.lastCreateParams!['p_latitude'], -23.5558);
      expect(source.lastCreateParams!['p_city_name'], 'São Paulo');
    },
  );

  testWidgets(
    'shows a mapped pt-BR message when the backend rejects the student',
    (tester) async {
      final source = FakeStudentDataSource(error: apiError('student_conflict'));
      await fillAndSubmit(tester, StudentService(dataSource: source));

      expect(
        find.text(
          'Não foi possível cadastrar o aluno: dados em conflito com um cadastro existente.',
        ),
        findsOneWidget,
      );
      expect(find.text('Aluno cadastrado com sucesso!'), findsNothing);
    },
  );
}
