import 'package:vango_app/features/fleet/models/fleet_command_id.dart';

/// Remembers command ids of logical actions whose outcome is unknown so a
/// retry reuses them.
class TripCommandLedger {
  TripCommandLedger({String Function()? newId})
    : _newId = newId ?? createFleetCommandId;

  final String Function() _newId;
  final Map<String, String> _pending = {};

  /// Returns the pending id for [actionKey] or creates (and remembers) a new
  /// one.
  String idFor(String actionKey) => _pending.putIfAbsent(actionKey, _newId);

  /// Forgets [actionKey] after a definitive outcome (success or rejection).
  void resolve(String actionKey) => _pending.remove(actionKey);

  /// Whether [actionKey] still awaits a definitive outcome.
  bool isPending(String actionKey) => _pending.containsKey(actionKey);
}
