import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/fleet_student_registration.dart';

class PendingJoinRequest {
  const PendingJoinRequest({
    required this.id,
    required this.studentFullName,
    required this.schoolName,
    required this.shift,
    required this.street,
    required this.streetNumber,
    required this.neighborhood,
    required this.cityName,
    required this.createdAt,
  });

  final String id;
  final String studentFullName;
  final String schoolName;
  final String shift;
  final String street;
  final String streetNumber;
  final String neighborhood;
  final String cityName;
  final String createdAt;

  String get fullAddress => '$street, $streetNumber - $neighborhood, $cityName';
}

class FleetMemberDriver {
  const FleetMemberDriver({
    required this.id,
    required this.name,
    required this.email,
    required this.status,
  });

  final String id;
  final String name;
  final String email;
  final String status;
}

class EnrolledStudentItem {
  const EnrolledStudentItem({
    required this.id,
    required this.fullName,
    required this.address,
    required this.latitude,
    required this.longitude,
  });

  final String id;
  final String fullName;
  final String address;
  final double latitude;
  final double longitude;
}

/// Owner-visible enrolled student, including the enrollment that receives transport.
typedef OwnerEnrolledStudent = ({
  String id,
  String enrollmentId,
  String fullName,
  String address,
  String? schoolId,
  String? schoolName,
  String? shift,
});

/// Reads owner fleet data through authenticated Supabase queries.
class FleetService {
  FleetService({SupabaseClient? client}) : _client = _resolveClient(client);

  final SupabaseClient? _client;

  static SupabaseClient? _resolveClient(SupabaseClient? client) {
    if (client != null) return client;
    try {
      return Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }

  SupabaseClient get _authenticatedClient {
    final client = _client;
    if (client == null || client.auth.currentUser == null) {
      throw StateError('Authenticated fleet access required');
    }
    return client;
  }

  static final _uuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );

  static String _optionString(Map row, String key) {
    final value = row[key];
    if (value is! String || value.trim().isEmpty) {
      throw const FormatException('Invalid coverage option');
    }
    return value;
  }

  /// Returns the selected fleet's covered municipalities without fallback.
  Future<List<FleetServiceCity>> getServiceCities(String fleetId) async {
    final rows = await _authenticatedClient
        .from('fleet_service_cities')
        .select('city_ibge_code,city_name,state_code')
        .eq('fleet_id', fleetId);
    final cities = rows.map((row) {
      final code = _optionString(row, 'city_ibge_code');
      final name = _optionString(row, 'city_name');
      final state = _optionString(row, 'state_code');
      if (!RegExp(r'^\d{7}$').hasMatch(code) ||
          !RegExp(r'^[A-Z]{2}$').hasMatch(state)) {
        throw const FormatException('Invalid city option');
      }
      return FleetServiceCity(
        cityIbgeCode: code,
        cityName: name,
        stateCode: state,
      );
    }).toList();
    cities.sort((a, b) {
      final order = a.cityName.toLowerCase().compareTo(
        b.cityName.toLowerCase(),
      );
      return order == 0 ? a.cityIbgeCode.compareTo(b.cityIbgeCode) : order;
    });
    return cities;
  }

  /// Returns minimal active covered-school options through the owner RPC.
  Future<List<FleetServiceSchool>> getServiceSchools(String fleetId) async {
    final rows = await _authenticatedClient.rpc(
      'list_fleet_service_schools',
      params: {'p_fleet_id': fleetId},
    );
    if (rows is! List) throw const FormatException('Invalid school options');
    final schools = rows.map((entry) {
      if (entry is! Map) throw const FormatException('Invalid school option');
      final id = _optionString(entry, 'id');
      final name = _optionString(entry, 'name');
      if (!_uuid.hasMatch(id)) {
        throw const FormatException('Invalid school option');
      }
      return FleetServiceSchool(id: id, name: name);
    }).toList();
    schools.sort((a, b) {
      final order = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      return order == 0 ? a.id.compareTo(b.id) : order;
    });
    return schools;
  }

  /// Sends one immutable command and accepts only a single valid receipt.
  Future<FleetStudentRegistrationReceipt> registerStudent({
    required String fleetId,
    required String commandId,
    required FleetStudentRegistration registration,
  }) async {
    final rows = await _authenticatedClient.rpc(
      'create_fleet_managed_student',
      params: registration.toRpcParams(fleetId: fleetId, commandId: commandId),
    );
    if (rows is! List || rows.length != 1 || rows.single is! Map) {
      throw const FormatException('Invalid registration receipt');
    }
    final row = rows.single as Map;
    final studentId = row['student_id'];
    final enrollmentId = row['enrollment_id'];
    if (studentId is! String ||
        enrollmentId is! String ||
        !_uuid.hasMatch(studentId) ||
        !_uuid.hasMatch(enrollmentId)) {
      throw const FormatException('Invalid registration receipt');
    }
    return (studentId: studentId, enrollmentId: enrollmentId);
  }

  /// Returns pending join requests for the selected owner fleet.
  Future<List<PendingJoinRequest>> getPendingRequests(String fleetId) async {
    final rows = await _authenticatedClient.rpc(
      'list_fleet_join_requests',
      params: {
        'p_fleet_id': fleetId,
        'p_status': 'pending',
        'p_limit': 20,
        'p_offset': 0,
      },
    );
    if (rows is! List) {
      throw const FormatException('Invalid join request response');
    }
    return rows.map((entry) {
      final row = entry as Map<String, dynamic>;
      return PendingJoinRequest(
        id: row['id'] as String,
        studentFullName: row['student_full_name'] as String,
        schoolName: row['school_name'] as String,
        shift: row['shift'] as String,
        street: row['street'] as String,
        streetNumber: row['street_number'] as String,
        neighborhood: row['neighborhood'] as String,
        cityName: row['city_name'] as String,
        createdAt: row['created_at'] as String,
      );
    }).toList();
  }

  /// Applies an owner decision to a pending join request.
  Future<void> decideRequest(String requestId, bool approve) async {
    await _authenticatedClient.rpc(
      'decide_fleet_join_request',
      params: {
        'p_request_id': requestId,
        'p_decision': approve ? 'approved' : 'rejected',
      },
    );
  }

  /// Returns drivers belonging to the selected owner fleet.
  Future<List<FleetMemberDriver>> getFleetDrivers(String fleetId) async {
    final rows = await _authenticatedClient
        .from('fleet_memberships')
        .select(
          'user_id, profiles(full_name), fleet_membership_roles!inner(role)',
        )
        .eq('fleet_id', fleetId)
        .eq('fleet_membership_roles.role', 'driver');
    return rows.map((row) {
      final profile = row['profiles'] as Map<String, dynamic>?;
      return FleetMemberDriver(
        id: row['user_id'] as String,
        name: profile?['full_name'] as String? ?? 'Motorista',
        email: '',
        status: 'Ativo',
      );
    }).toList();
  }

  /// Preserves the driver route's existing fallback for enrolled students.
  Future<List<EnrolledStudentItem>> getEnrolledStudents(String fleetId) async {
    if (_client == null || _client.auth.currentUser == null) {
      return const [
        EnrolledStudentItem(
          id: 'stop-01-lucas',
          fullName: 'Lucas Alencar',
          address: 'Rua Oscar Freire, 1000 - Cerqueira César, São Paulo',
          latitude: -23.5615,
          longitude: -46.6698,
        ),
        EnrolledStudentItem(
          id: 'stop-02-mariana',
          fullName: 'Mariana Rios',
          address: 'Alameda Santos, 1800 - Cerqueira César, São Paulo',
          latitude: -23.5601,
          longitude: -46.6575,
        ),
      ];
    }
    try {
      final rows = await _client
          .from('fleet_enrollments')
          .select(
            'student_id, students(id, full_name, street, street_number, neighborhood, city_name, latitude, longitude)',
          )
          .eq('fleet_id', fleetId)
          .eq('status', 'active');
      final students = <EnrolledStudentItem>[];
      for (final row in rows) {
        final student = row['students'] as Map<String, dynamic>?;
        if (student == null) continue;
        final street = student['street'] as String? ?? '';
        final number = student['street_number'] as String? ?? '';
        final neighborhood = student['neighborhood'] as String? ?? '';
        final city = student['city_name'] as String? ?? 'São Paulo';
        students.add(
          EnrolledStudentItem(
            id: student['id'] as String? ?? '',
            fullName: student['full_name'] as String? ?? '',
            address: '$street, $number - $neighborhood, $city',
            latitude: (student['latitude'] as num?)?.toDouble() ?? -23.5615,
            longitude: (student['longitude'] as num?)?.toDouble() ?? -46.6698,
          ),
        );
      }
      return students;
    } catch (_) {
      return [];
    }
  }

  /// Returns enrolled students to the guarded owner dashboard without fallback.
  Future<List<OwnerEnrolledStudent>> getOwnerEnrolledStudents(
    String fleetId,
  ) async {
    final rows = await _authenticatedClient.rpc(
      'list_fleet_students',
      params: {'p_fleet_id': fleetId},
    );
    if (rows is! List) {
      throw const FormatException('Invalid owner student response');
    }
    return rows.map((entry) {
      final row = entry as Map<String, dynamic>;
      final street = row['street'] as String;
      final number = row['street_number'] as String;
      final neighborhood = row['neighborhood'] as String;
      final city = row['city_name'] as String;
      return (
        id: row['student_id'] as String,
        enrollmentId: row['enrollment_id'] as String,
        fullName: row['full_name'] as String,
        address: '$street, $number - $neighborhood, $city',
        schoolId: row['school_id'] as String?,
        schoolName: row['school_name'] as String?,
        shift: row['shift'] as String?,
      );
    }).toList();
  }
}
