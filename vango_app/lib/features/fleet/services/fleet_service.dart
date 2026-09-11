import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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
    required this.latitude,
    required this.longitude,
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
  final double latitude;
  final double longitude;
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

class FleetService {
  FleetService({SupabaseClient? client}) : _client = _resolveClient(client);

  static SupabaseClient? _resolveClient(SupabaseClient? client) {
    if (client != null) return client;
    try {
      return Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }

  final SupabaseClient? _client;

  // Local state for immediate responsiveness
  static final List<PendingJoinRequest> _localPending = [
    const PendingJoinRequest(
      id: 'req-001-carlos',
      studentFullName: 'Carlos Eduardo Oliveira',
      schoolName: 'Colégio Objetivo - Campus Paraíso',
      shift: 'Manhã',
      street: 'Rua Bela Cintra',
      streetNumber: '1400',
      neighborhood: 'Consolação',
      cityName: 'São Paulo',
      latitude: -23.5558,
      longitude: -46.6627,
      createdAt: 'Hoje',
    ),
  ];

  static final List<EnrolledStudentItem> _localEnrolled = [
    const EnrolledStudentItem(
      id: 'stop-01-lucas',
      fullName: 'Lucas Alencar',
      address: 'Rua Oscar Freire, 1000 - Cerqueira César, São Paulo',
      latitude: -23.5615,
      longitude: -46.6698,
    ),
    const EnrolledStudentItem(
      id: 'stop-02-mariana',
      fullName: 'Mariana Rios',
      address: 'Alameda Santos, 1800 - Cerqueira César, São Paulo',
      latitude: -23.5601,
      longitude: -46.6575,
    ),
  ];

  Future<List<PendingJoinRequest>> getPendingRequests(String fleetId) async {
    final client = _client;
    if (client != null && client.auth.currentUser != null) {
      try {
        final rows = await client.rpc('list_fleet_join_requests', params: {
          'p_fleet_id': fleetId,
          'p_status': 'pending',
          'p_limit': 20,
          'p_offset': 0,
        });

        if (rows is List && rows.isNotEmpty) {
          return rows.map((row) {
            return PendingJoinRequest(
              id: row['id'] as String? ?? '',
              studentFullName: row['student_full_name'] as String? ?? 'Aluno',
              schoolName: row['school_name'] as String? ?? 'Escola',
              shift: row['shift'] as String? ?? 'Manhã',
              street: row['street'] as String? ?? '',
              streetNumber: row['street_number'] as String? ?? '',
              neighborhood: row['neighborhood'] as String? ?? '',
              cityName: row['city_name'] as String? ?? 'São Paulo',
              latitude: (row['latitude'] as num?)?.toDouble() ?? -23.5615,
              longitude: (row['longitude'] as num?)?.toDouble() ?? -46.6698,
              createdAt: 'Recente',
            );
          }).toList();
        }
      } catch (e) {
        debugPrint('[FleetService] Erro ao buscar solicitações pendentes via RPC: $e');
      }
    }

    return List.from(_localPending);
  }

  Future<void> decideRequest(String requestId, bool approve) async {
    final client = _client;
    final isUuid = RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
    ).hasMatch(requestId);

    if (client != null && client.auth.currentUser != null && isUuid) {
      try {
        await client.rpc('decide_fleet_join_request', params: {
          'p_request_id': requestId,
          'p_decision': approve ? 'approved' : 'rejected',
        });
        debugPrint('[FleetService] ✅ RPC decide_fleet_join_request executada: approve=$approve');
      } catch (e) {
        debugPrint('[FleetService] ⚠️ RPC decide_fleet_join_request: $e');
      }
    }

    final index = _localPending.indexWhere((r) => r.id == requestId);
    if (index != -1) {
      final removed = _localPending.removeAt(index);
      if (approve) {
        _localEnrolled.add(
          EnrolledStudentItem(
            id: 'student-${DateTime.now().millisecondsSinceEpoch}',
            fullName: removed.studentFullName,
            address: removed.fullAddress,
            latitude: removed.latitude,
            longitude: removed.longitude,
          ),
        );
      }
    }
  }

  Future<List<FleetMemberDriver>> getFleetDrivers(String fleetId) async {
    return const [
      FleetMemberDriver(
        id: '50000000-0000-0000-0000-000000000002',
        name: 'Carlos Seed Driver',
        email: 'seed-driver@example.test',
        status: 'Ativo • Van 01 (BRA-2E19)',
      ),
    ];
  }

  Future<List<EnrolledStudentItem>> getEnrolledStudents(String fleetId) async {
    final client = _client;
    if (client != null && client.auth.currentUser != null) {
      try {
        final rows = await client
            .from('fleet_enrollments')
            .select('student_id, students(id, full_name, street, street_number, neighborhood, city_name, latitude, longitude)')
            .eq('fleet_id', fleetId)
            .eq('status', 'active');

        if (rows.isNotEmpty) {
          final list = <EnrolledStudentItem>[];
          for (final row in rows) {
            final st = row['students'] as Map<String, dynamic>?;
            if (st != null) {
              final street = st['street'] as String? ?? '';
              final streetNum = st['street_number'] as String? ?? '';
              final neigh = st['neighborhood'] as String? ?? '';
              final city = st['city_name'] as String? ?? 'São Paulo';
              list.add(
                EnrolledStudentItem(
                  id: st['id'] as String? ?? '',
                  fullName: st['full_name'] as String? ?? '',
                  address: '$street, $streetNum - $neigh, $city',
                  latitude: (st['latitude'] as num?)?.toDouble() ?? -23.5615,
                  longitude: (st['longitude'] as num?)?.toDouble() ?? -46.6698,
                ),
              );
            }
          }
          if (list.isNotEmpty) return list;
        }
      } catch (e) {
        debugPrint('[FleetService] Erro ao buscar alunos matriculados: $e');
      }
    }

    return List.from(_localEnrolled);
  }

  static void resetLocalData() {
    _localPending
      ..clear()
      ..add(
        const PendingJoinRequest(
          id: 'req-001-carlos',
          studentFullName: 'Carlos Eduardo Oliveira',
          schoolName: 'Colégio Objetivo - Campus Paraíso',
          shift: 'Manhã',
          street: 'Rua Bela Cintra',
          streetNumber: '1400',
          neighborhood: 'Consolação',
          cityName: 'São Paulo',
          latitude: -23.5558,
          longitude: -46.6627,
          createdAt: 'Hoje',
        ),
      );
    _localEnrolled
      ..clear()
      ..addAll([
        const EnrolledStudentItem(
          id: 'stop-01-lucas',
          fullName: 'Lucas Alencar',
          address: 'Rua Oscar Freire, 1000 - Cerqueira César, São Paulo',
          latitude: -23.5615,
          longitude: -46.6698,
        ),
        const EnrolledStudentItem(
          id: 'stop-02-mariana',
          fullName: 'Mariana Rios',
          address: 'Alameda Santos, 1800 - Cerqueira César, São Paulo',
          latitude: -23.5601,
          longitude: -46.6575,
        ),
      ]);
  }
}
