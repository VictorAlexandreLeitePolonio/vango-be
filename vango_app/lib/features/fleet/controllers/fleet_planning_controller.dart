import 'package:flutter/foundation.dart';
import '../models/fleet_planning.dart';
import '../models/fleet_planning_commands.dart';
import '../services/fleet_planning_service.dart';
import '../services/fleet_planning_error_mapper.dart';

/// Explicit write state, independent of refreshing a committed configuration.
enum PlanningWriteOutcome { idle, submitting, uncertain, rejected, committed }

/// Owns one authenticated fleet context and preserves immutable retries.
class FleetPlanningController extends ChangeNotifier {
  FleetPlanningController({
    required this.service,
    required this.userId,
    required this.fleetId,
    required this.refreshAccess,
  });
  final FleetPlanningService service;
  final String userId, fleetId;
  final Future<void> Function() refreshAccess;
  FleetPlanning? planning;
  Object? error, readError, catalogError;
  List<PlanningCity> catalogCities = [];
  List<PlanningSchool> schoolResults = [];
  bool catalogLoading = false;
  int _catalogGeneration = 0;
  bool loading = false, active = true;
  PlanningWriteOutcome outcome = PlanningWriteOutcome.idle;
  Future<void> Function()? _pending;
  int _epoch = 0, _readGeneration = 0;
  bool _disposed = false, _conflict = false;

  /// Uncertain writes must be resolved before a different command is accepted.
  bool get canSubmit =>
      active &&
      !_conflict &&
      outcome != PlanningWriteOutcome.submitting &&
      outcome != PlanningWriteOutcome.uncertain;
  bool _current(int epoch) {
    if (_disposed || !active || epoch != _epoch) return false;
    if (service.currentUserId != userId) {
      clearContext();
      return false;
    }
    return true;
  }

  /// Refreshes access and persisted data; it never repeats a committed write.
  Future<void> load() async {
    final epoch = _epoch, read = ++_readGeneration;
    if (!_current(epoch)) return;
    loading = true;
    readError = null;
    notifyListeners();
    try {
      await refreshAccess();
      if (!_current(epoch) || read != _readGeneration) return;
      final result = await service.load(fleetId);
      if (!_current(epoch) || read != _readGeneration) return;
      planning = result;
      if (_conflict) {
        _conflict = false;
        outcome = PlanningWriteOutcome.idle;
        error = null;
      }
    } catch (failure) {
      if (!_current(epoch) || read != _readGeneration) return;
      if (PlanningErrorMapper.kind(failure) == PlanningFailure.accessLost) {
        clearContext();
        return;
      }
      readError = failure;
    } finally {
      if (_current(epoch) && read == _readGeneration) {
        loading = false;
        notifyListeners();
      }
    }
  }

  Future<void> _catalog<T>(
    Future<List<T>> Function() fetch,
    void Function(List<T>) apply,
  ) async {
    final epoch = _epoch, generation = ++_catalogGeneration;
    if (!_current(epoch)) return;
    catalogLoading = true;
    catalogError = null;
    notifyListeners();
    try {
      final result = await fetch();
      if (!_current(epoch) || generation != _catalogGeneration) return;
      apply(result);
    } catch (failure) {
      if (!_current(epoch) || generation != _catalogGeneration) return;
      if (PlanningErrorMapper.kind(failure) == PlanningFailure.accessLost) {
        clearContext();
        return;
      }
      catalogError = failure;
    } finally {
      if (_current(epoch) && generation == _catalogGeneration) {
        catalogLoading = false;
        notifyListeners();
      }
    }
  }

  /// Loads authoritative municipality options in the current session only.
  Future<void> loadCities() =>
      _catalog(service.cities, (values) => catalogCities = values);

  /// Searches a served municipality; later searches supersede earlier responses.
  Future<void> searchSchools(
    String city,
    String query, {
    String? type,
    int offset = 0,
  }) {
    schoolResults = [];
    return _catalog(
      () => service.searchSchools(city, query, type: type, offset: offset),
      (values) => schoolResults = values,
    );
  }

  /// Opens another independent draft only after the previous write is resolved.
  bool beginDraft() {
    if (!canSubmit || !_current(_epoch)) return false;
    outcome = PlanningWriteOutcome.idle;
    error = null;
    notifyListeners();
    return true;
  }

  Future<void> _submit(Future<void> Function() send) async {
    if (!canSubmit || !_current(_epoch)) return;
    _pending = send;
    await _dispatch();
  }

  Future<void> _dispatch() async {
    final epoch = _epoch, send = _pending;
    if (send == null || !_current(epoch)) return;
    outcome = PlanningWriteOutcome.submitting;
    error = null;
    notifyListeners();
    try {
      await send();
      if (!_current(epoch)) return;
      outcome = PlanningWriteOutcome.committed;
      _pending = null;
      notifyListeners();
      await load();
    } catch (failure) {
      if (!_current(epoch)) return;
      final kind = PlanningErrorMapper.kind(failure);
      if (kind == PlanningFailure.accessLost) {
        clearContext();
        return;
      }
      error = failure;
      _conflict = kind == PlanningFailure.conflict;
      outcome = kind == PlanningFailure.uncertain
          ? PlanningWriteOutcome.uncertain
          : PlanningWriteOutcome.rejected;
      if (outcome != PlanningWriteOutcome.uncertain) _pending = null;
      notifyListeners();
    }
  }

  /// Retries only the captured command whose response was uncertain.
  Future<void> retryPending() async {
    if (outcome == PlanningWriteOutcome.uncertain) await _dispatch();
  }

  /// Saves a van only in this controller's fleet.
  Future<void> saveVan(VanPlanningCommand command) {
    if (command.fleetId != fleetId) throw StateError('Fleet context mismatch');
    return _submit(() async {
      await service.saveVan(command);
    });
  }

  /// Saves an explicitly configured route in this fleet.
  Future<void> saveRoute(RoutePlanningCommand command) {
    if (command.fleetId != fleetId) throw StateError('Fleet context mismatch');
    return _submit(() async {
      await service.saveRoute(command);
    });
  }

  /// Saves a schedule for a route from the loaded projection.
  Future<void> saveSchedule(SchedulePlanningCommand command) {
    if (planning?.routes.any((r) => r.id == command.routeId) != true) {
      throw StateError('Route context mismatch');
    }
    return _submit(() async {
      await service.saveSchedule(command);
    });
  }

  /// Explicitly enables driving; load refreshes access before exposing operators.
  Future<void> enableOwnerDriving(String commandId) => _submit(() async {
    await service.enableOwnerDriving(fleetId, commandId);
  });

  /// Links a municipality with a durable command ID.
  Future<void> linkCity(String code, String commandId) =>
      _submit(() => service.linkCity(fleetId, code, commandId));

  /// Links an institution with a durable command ID.
  Future<void> linkSchool(String id, String commandId) =>
      _submit(() => service.linkSchool(fleetId, id, commandId));

  /// Invalidates all drafts, pending work and late completions after access loss.
  void clearContext() {
    if (_disposed) return;
    _epoch++;
    _readGeneration++;
    _catalogGeneration++;
    catalogCities = [];
    schoolResults = [];
    catalogError = null;
    catalogLoading = false;
    active = false;
    planning = null;
    _pending = null;
    error = null;
    readError = null;
    loading = false;
    _conflict = false;
    outcome = PlanningWriteOutcome.idle;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    _pending = null;
    super.dispose();
  }
}
