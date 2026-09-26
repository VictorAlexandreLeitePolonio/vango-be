import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:vango_app/features/fleet/models/fleet_planning.dart';

Map<String, dynamic> planningFixture() =>
    jsonDecode(File('test/fixtures/fleet_planning.json').readAsStringSync())
        as Map<String, dynamic>;

void main() {
  test('parses the integrated projection and tolerates nested additions', () {
    final json = planningFixture()..['future'] = true;
    (json['routes'] as List).first['future'] = {'nested': true};
    final planning = FleetPlanning.fromJson(json);
    expect(planning.routes, hasLength(2));
    expect(planning.schedules.first.startsAt, matches(r'^\d{2}:\d{2}:\d{2}$'));
    expect(planning.enrollmentRevisions, hasLength(2));
    expect(planning.routes.first.origin.latitude, isA<double>());
  });
  test('rejects missing required values and nonfinite coordinates', () {
    final json = planningFixture()..remove('reservations');
    expect(() => FleetPlanning.fromJson(json), throwsFormatException);
    final malformed = planningFixture();
    (malformed['routes'] as List).first['origin']['latitude'] = double.nan;
    expect(() => FleetPlanning.fromJson(malformed), throwsFormatException);
  });
}
