import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/fleet_planning.dart';
import '../models/fleet_planning_commands.dart';

/// Authenticated planning and published-catalog RPC access; no widget writes tables.
class FleetPlanningService {
  FleetPlanningService({SupabaseClient? client})
    : _client = client ?? Supabase.instance.client;
  final SupabaseClient _client;

  /// Current identity lets the controller reject completions from another session.
  String? get currentUserId => _client.auth.currentUser?.id;
  SupabaseClient get _authenticated {
    if (currentUserId == null) {
      throw const AuthException('Authentication required');
    }
    return _client;
  }

  /// Reads the integrated owner projection and validates every known field.
  Future<FleetPlanning> load(String fleetId) async => FleetPlanning.fromJson(
    planningObject(
      await _authenticated.rpc(
        'get_fleet_planning',
        params: {'p_fleet_id': fleetId},
      ),
      'planning',
    ),
  );
  Future<String> _save(String rpc, Map<String, Object?> params) async =>
      planningId({'id': await _authenticated.rpc(rpc, params: params)}, 'id');

  /// Persists a revision-aware vehicle command.
  Future<String> saveVan(VanPlanningCommand command) =>
      _save('save_van', command.toRpcParams());

  /// Persists a revision-aware route command.
  Future<String> saveRoute(RoutePlanningCommand command) =>
      _save('save_route', command.toRpcParams());

  /// Persists a revision-aware recurring schedule command.
  Future<String> saveSchedule(SchedulePlanningCommand command) =>
      _save('save_route_schedule', command.toRpcParams());

  /// Explicitly enables the current owner as an operator, preserving role provenance.
  Future<List<String>> enableOwnerDriving(
    String fleetId,
    String commandId,
  ) async {
    final value = await _authenticated.rpc(
      'enable_owner_driving',
      params: {'p_fleet_id': fleetId, 'p_command_id': commandId},
    );
    if (value is! List ||
        value.any(
          (role) =>
              role is! String ||
              !['owner', 'driver', 'guardian', 'student'].contains(role),
        )) {
      throw const PlanningResponseFormatException('roles');
    }
    return List<String>.unmodifiable(value);
  }

  /// Links authoritative municipality metadata resolved by the server.
  Future<void> linkCity(
    String fleetId,
    String cityIbgeCode,
    String commandId,
  ) async {
    await _authenticated.rpc(
      'link_fleet_service_city',
      params: {
        'p_fleet_id': fleetId,
        'p_city_ibge_code': cityIbgeCode,
        'p_command_id': commandId,
      },
    );
  }

  /// Links a published institution after the city has been covered.
  Future<void> linkSchool(
    String fleetId,
    String schoolId,
    String commandId,
  ) async {
    await _authenticated.rpc(
      'link_fleet_service_school',
      params: {
        'p_fleet_id': fleetId,
        'p_school_id': schoolId,
        'p_command_id': commandId,
      },
    );
  }

  /// Lists the administratively loaded SP municipalities without fabricated options.
  Future<List<PlanningCity>> cities() async {
    final rows = await _authenticated
        .from('catalog_municipalities')
        .select('city_ibge_code,city_name,state_code')
        .order('city_name');
    return List.unmodifiable(rows.map(planningCity));
  }

  /// Reuses catalog search with a served municipality and optional institution type.
  Future<List<PlanningSchool>> searchSchools(
    String city,
    String query, {
    String? type,
    int offset = 0,
  }) async {
    final rows = await _authenticated.rpc(
      'search_schools',
      params: {
        'p_query': query.trim().isEmpty ? null : query.trim(),
        'p_city_ibge_code': city,
        'p_institution_type': type,
        'p_limit': 50,
        'p_offset': offset,
      },
    );
    if (rows is! List) throw const PlanningResponseFormatException('schools');
    return List.unmodifiable(
      rows.map((row) => planningSchool(planningObject(row, 'school'))),
    );
  }
}
