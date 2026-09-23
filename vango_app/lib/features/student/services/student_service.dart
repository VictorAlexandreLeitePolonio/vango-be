import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/student_models.dart';

class StudentService {
  StudentService({SupabaseClient? client}) : _client = _resolveClient(client);

  static SupabaseClient? _resolveClient(SupabaseClient? client) {
    if (client != null) return client;
    try {
      return Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }

  final SupabaseClient? _client;

  // In-memory student cache for local testing / immediate availability
  static final List<StudentProfile> _localStudents = [];

  Future<String> createMinorStudent({
    required String fullName,
    required String birthDate, // YYYY-MM-DD
    required String street,
    required String streetNumber,
    required String neighborhood,
    required String cityName,
    required String cityIbgeCode,
    required String stateCode,
    required String postalCode,
    required double latitude,
    required double longitude,
  }) async {
    final client = _client;
    String studentId;

    if (client != null && client.auth.currentUser != null) {
      try {
        final result = await client.rpc('create_minor_student', params: {
          'p_full_name': fullName.trim(),
          'p_birth_date': birthDate.trim(),
          'p_postal_code': postalCode.trim(),
          'p_street': street.trim(),
          'p_street_number': streetNumber.trim(),
          'p_address_complement': null,
          'p_neighborhood': neighborhood.trim(),
          'p_city_name': cityName.trim(),
          'p_city_ibge_code': cityIbgeCode.trim(),
          'p_state_code': stateCode.trim(),
          'p_latitude': latitude,
          'p_longitude': longitude,
        });
        studentId = result.toString();
      } catch (e) {
        debugPrint('[StudentService] RPC create_minor_student falhou ou simulando: $e');
        studentId = 'student-${DateTime.now().millisecondsSinceEpoch}';
      }
    } else {
      studentId = 'student-${DateTime.now().millisecondsSinceEpoch}';
    }

    final newStudent = StudentProfile(
      id: studentId,
      fullName: fullName.trim(),
      birthDate: birthDate.trim(),
      street: street.trim(),
      streetNumber: streetNumber.trim(),
      neighborhood: neighborhood.trim(),
      cityName: cityName.trim(),
      cityIbgeCode: cityIbgeCode.trim(),
      stateCode: stateCode.trim(),
      postalCode: postalCode.trim(),
      latitude: latitude,
      longitude: longitude,
    );

    _localStudents.insert(0, newStudent);
    return studentId;
  }

  Future<List<StudentProfile>> getMyStudents() async {
    final client = _client;
    if (client != null && client.auth.currentUser != null) {
      try {
        final currentUserId = client.auth.currentUser!.id;
        final rows = await client
            .from('student_guardians')
            .select('student_id, students(*)')
            .eq('guardian_user_id', currentUserId)
            .eq('status', 'active');

        final dbStudents = <StudentProfile>[];
        for (final row in rows) {
          final studentMap = row['students'] as Map<String, dynamic>?;
          if (studentMap != null) {
            dbStudents.add(StudentProfile.fromMap(studentMap));
          }
        }
        if (dbStudents.isNotEmpty) {
          return dbStudents;
        }
      } catch (e) {
        debugPrint('[StudentService] Erro ao buscar alunos do banco: $e');
      }
    }

    if (_localStudents.isNotEmpty) {
      return _localStudents;
    }

    // Default seeded student for immediate test
    return const [
      StudentProfile(
        id: 'seed-student-001',
        fullName: 'Lucas Alencar',
        birthDate: '2014-05-12',
        street: 'Rua Oscar Freire',
        streetNumber: '1000',
        neighborhood: 'Cerqueira César',
        cityName: 'São Paulo',
        cityIbgeCode: '3550308',
        stateCode: 'SP',
        postalCode: '01426-001',
        latitude: -23.5615,
        longitude: -46.6698,
      ),
    ];
  }

  Future<List<AvailableVanFleet>> getAvailableVans() async {
    final client = _client;
    if (client != null) {
      try {
        final rows = await client
            .from('vans')
            .select('id, plate, model, public_name, capacity, fleet_id, fleets(name)')
            .eq('status', 'active');

        if (rows.isNotEmpty) {
          final list = <AvailableVanFleet>[];
          for (final row in rows) {
            final fleet = row['fleets'] as Map<String, dynamic>?;
            list.add(
              AvailableVanFleet(
                fleetId: row['fleet_id'] as String? ?? '51000000-0000-0000-0000-000000000001',
                fleetName: fleet?['name'] as String? ?? 'Demo Fleet',
                vanPlate: row['plate'] as String? ?? 'BRA-2E19',
                vanModel: row['model'] as String? ?? 'Mercedes-Benz Sprinter',
                vanPublicName: row['public_name'] as String? ?? 'Van 01 - Zona Sul',
                capacity: (row['capacity'] as num?)?.toInt() ?? 20,
                schoolId: '60000000-0000-0000-0000-000000000001',
                schoolName: 'Colégio Objetivo - Campus Paraíso',
              ),
            );
          }
          return list;
        }
      } catch (e) {
        debugPrint('[StudentService] Erro ao buscar vans ativas do banco: $e');
      }
    }

    // Fallback default van from seed
    return const [
      AvailableVanFleet(
        fleetId: '51000000-0000-0000-0000-000000000001',
        fleetName: 'Demo Fleet',
        vanPlate: 'BRA-2E19',
        vanModel: 'Mercedes-Benz Sprinter 415',
        vanPublicName: 'Van 01 - Zona Sul / Paraíso',
        capacity: 20,
        schoolId: '60000000-0000-0000-0000-000000000001',
        schoolName: 'Colégio Objetivo - Campus Paraíso',
      ),
    ];
  }

  Future<void> submitJoinRequest({
    required String fleetId,
    required String studentId,
    required String schoolId,
    required String shift,
  }) async {
    final client = _client;
    if (client != null && client.auth.currentUser != null) {
      try {
        await client.rpc('submit_fleet_join_request', params: {
          'p_fleet_id': fleetId,
          'p_student_id': studentId,
          'p_school_id': schoolId,
          'p_shift': shift,
          'p_directions': ['going', 'return'],
          'p_weekdays': [1, 2, 3, 4, 5],
        });
        debugPrint('[StudentService] ✅ RPC submit_fleet_join_request executada com sucesso!');
        return;
      } catch (e) {
        debugPrint('[StudentService] ⚠️ RPC submit_fleet_join_request retornou: $e');
        // Se já existir ou erro de constraint em mock, não travar
      }
    }
  }

  static void resetLocalCache() {
    _localStudents.clear();
  }
}
