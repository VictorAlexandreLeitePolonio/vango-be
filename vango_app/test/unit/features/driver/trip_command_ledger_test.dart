import 'package:flutter_test/flutter_test.dart';
import 'package:vango_app/features/driver/models/trip_command_ledger.dart';

void main() {
  group('TripCommandLedger', () {
    test('idFor mints one id per key and reuses pending ids', () {
      var sequence = 0;
      final ledger = TripCommandLedger(newId: () => 'cmd-${++sequence}');

      expect(ledger.idFor('start'), 'cmd-1');
      expect(ledger.idFor('start'), 'cmd-1');
      expect(ledger.idFor('finish'), 'cmd-2');
      expect(ledger.idFor('passenger:s1:boarded'), 'cmd-3');
      expect(ledger.idFor('stop:s-school'), 'cmd-4');
      expect(ledger.isPending('start'), isTrue);
      expect(ledger.isPending('finish'), isTrue);
      expect(ledger.isPending('passenger:s1:boarded'), isTrue);
      expect(ledger.isPending('stop:s-school'), isTrue);
    });

    test('resolve forgets the key so a new action mints a new id', () {
      var sequence = 0;
      final ledger = TripCommandLedger(newId: () => 'cmd-${++sequence}');

      expect(ledger.idFor('start'), 'cmd-1');
      ledger.resolve('start');
      expect(ledger.isPending('start'), isFalse);
      expect(ledger.idFor('start'), 'cmd-2');
    });

    test('resolving an unknown key is a no-op', () {
      final ledger = TripCommandLedger(newId: () => 'cmd-1');

      ledger.resolve('never-seen');
      expect(ledger.isPending('never-seen'), isFalse);
    });

    test('composite keys retry independently per sub-command', () {
      var sequence = 0;
      final ledger = TripCommandLedger(newId: () => 'cmd-${++sequence}');

      final stopId = ledger.idFor('stop:s-school');
      final firstStudent = ledger.idFor('passenger:s1:dropped_off');
      final secondStudent = ledger.idFor('passenger:s2:dropped_off');
      expect(stopId, isNot(firstStudent));
      expect(firstStudent, isNot(secondStudent));

      ledger.resolve('passenger:s1:dropped_off');
      expect(ledger.idFor('passenger:s1:dropped_off'), 'cmd-4');
      expect(ledger.idFor('passenger:s2:dropped_off'), 'cmd-3');
    });

    test('the default factory produces backend-shaped command ids', () {
      final ledger = TripCommandLedger();

      expect(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ).hasMatch(ledger.idFor('start')),
        isTrue,
      );
    });
  });
}
