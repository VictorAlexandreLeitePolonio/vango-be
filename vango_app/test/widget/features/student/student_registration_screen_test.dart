import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vango_app/features/shared/services/mapbox_geocoding_service.dart';
import 'package:vango_app/features/student/screens/student_registration_screen.dart';
import 'package:vango_app/features/student/services/student_service.dart';

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
        cityIbgeCode: '3550308',
        stateCode: 'SP',
        postalCode: '01415-001',
        latitude: -23.5558,
        longitude: -46.6627,
      ),
    ];
  }
}

void main() {
  setUp(() {
    StudentService.resetLocalCache();
  });

  testWidgets('renders all fields and labels in student registration', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: StudentRegistrationScreen(),
      ),
    );

    expect(find.text('Cadastrar Aluno'), findsOneWidget);
    expect(find.text('Dados do Aluno'), findsOneWidget);
    expect(find.text('Endereço de Embarque (Mapbox)'), findsOneWidget);
    expect(find.text('Salvar Aluno'), findsOneWidget);
    expect(find.byType(TextFormField), findsWidgets);
  });

  testWidgets('shows validation message when attempting submit without selecting Mapbox address', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: StudentRegistrationScreen(),
      ),
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

    expect(find.text('Selecione uma localização nas sugestões'), findsOneWidget);
  });

  testWidgets('fills address from suggestion and successfully registers student', (tester) async {
    final fakeGeocoding = FakeGeocodingService();
    final studentService = StudentService();

    await tester.pumpWidget(
      MaterialApp(
        home: StudentRegistrationScreen(
          geocodingService: fakeGeocoding,
          studentService: studentService,
        ),
      ),
    );

    // 1. Fill Name
    final nameField = find.byType(TextFormField).first;
    await tester.enterText(nameField, 'Camila Silveira');

    // 2. Type query in autocomplete field (3rd TextFormField)
    final textFields = find.byType(TextFormField);
    // index 0: name, index 1: birthdate, index 2: address autocomplete
    final addressField = textFields.at(2);
    await tester.enterText(addressField, 'Bela Cintra');
    await tester.pump(const Duration(milliseconds: 500)); // wait debounce
    await tester.pumpAndSettle();

    // 3. Verify suggestion overlay appears and select it
    expect(find.text('Rua Bela Cintra, 1400, Consolação, São Paulo'), findsOneWidget);
    await tester.tap(find.text('Rua Bela Cintra, 1400, Consolação, São Paulo'));
    await tester.pumpAndSettle();

    // 4. Submit form
    final submitBtn = find.text('Salvar Aluno');
    await tester.ensureVisible(submitBtn);
    await tester.tap(submitBtn);
    await tester.pumpAndSettle();

    // Check student was created
    final students = await studentService.getMyStudents();
    expect(students.any((s) => s.fullName == 'Camila Silveira'), true);
  });
}
