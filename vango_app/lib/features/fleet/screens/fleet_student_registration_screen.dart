import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/fleet_student_registration.dart';
import '../services/fleet_student_error_mapper.dart';
import '../../../shared/widgets/mapbox_address_autocomplete_field.dart';
import '../../auth/services/auth_service.dart';
import '../../shared/services/mapbox_geocoding_service.dart';
import '../services/fleet_service.dart';
import '../models/fleet_student_submission_state.dart';

/// Owner-only form for one fleet-scoped registration command.
class FleetStudentRegistrationScreen extends StatefulWidget {
  const FleetStudentRegistrationScreen({
    super.key,
    required this.fleetId,
    required this.userId,
    required this.authService,
    this.fleetService,
    this.geocodingService,
    this.submissionState,
  });
  final String fleetId, userId;
  final AuthService authService;
  final FleetService? fleetService;
  final MapboxGeocodingService? geocodingService;
  final FleetStudentSubmissionState? submissionState;
  @override
  State<FleetStudentRegistrationScreen> createState() =>
      _FleetStudentRegistrationScreenState();
}

class _FleetStudentRegistrationScreenState
    extends State<FleetStudentRegistrationScreen> {
  final _fields = {
    for (final name in [
      'fullName',
      'street',
      'streetNumber',
      'neighborhood',
      'postalCode',
      'addressComplement',
      'contactFullName',
      'contactEmail',
      'contactPhone',
    ])
      name: TextEditingController(),
  };
  final _search = TextEditingController();
  DateTime? _birthDate;
  FleetStudentType _type = FleetStudentType.minor;
  FleetStudentShift _shift = FleetStudentShift.morning;
  MapboxPlaceSuggestion? _location;
  ({String street, String number})? _addressIdentity;
  String? _locationMessage;
  FleetServiceCity? _city;
  FleetServiceSchool? _school;
  late FleetService _fleet;
  late FleetStudentSubmissionState _submission;
  StreamSubscription<AuthState>? _authSubscription;
  List<FleetServiceCity> _cities = [];
  List<FleetServiceSchool> _schools = [];
  bool _loading = true, _denied = false, _dispatching = false;
  String? _feedback;
  String? _message;
  int _epoch = 0, _accessGeneration = 0;
  @override
  void initState() {
    super.initState();
    _bind();
  }

  void _bind() {
    _fleet = widget.fleetService ?? FleetService();
    _submission =
        widget.submissionState ??
        FleetStudentSubmissionState(
          userId: widget.userId,
          fleetId: widget.fleetId,
        );
    _authSubscription = widget.authService.authStateChanges.listen((state) {
      if (state.event == AuthChangeEvent.signedOut ||
          state.session?.user.id != widget.userId) {
        _deny();
      } else {
        unawaited(_checkAccess(loadOptions: false));
      }
    });
    unawaited(_checkAccess());
  }

  bool _current(int epoch) =>
      mounted &&
      epoch == _epoch &&
      widget.authService.currentSession?.user.id == widget.userId;
  void _deny() {
    _epoch++;
    _accessGeneration++;
    _submission.invalidate();
    _clearDraft();
    if (!mounted) return;
    setState(() {
      _denied = true;
      _loading = false;
      _dispatching = false;
      _cities = [];
      _schools = [];
    });
  }

  Future<void> _checkAccess({bool loadOptions = true}) async {
    final epoch = _epoch, generation = ++_accessGeneration;
    if (widget.authService.currentSession?.user.id != widget.userId ||
        _submission.userId != widget.userId ||
        _submission.fleetId != widget.fleetId ||
        _submission.invalidated) {
      _deny();
      return;
    }
    loadOptions = loadOptions || _loading;
    if (loadOptions) {
      setState(() {
        _loading = true;
        _message = null;
      });
    }
    try {
      final access = await widget.authService.getMyAccessContext();
      if (!_current(epoch) || generation != _accessGeneration) return;
      if (!access.ownerFleetIds.contains(widget.fleetId)) {
        _deny();
        return;
      }
      if (loadOptions &&
          (_submission.phase == FleetStudentSubmissionPhase.idle ||
              _submission.phase == FleetStudentSubmissionPhase.rejected)) {
        final cities = await _fleet.getServiceCities(widget.fleetId);
        final schools = await _fleet.getServiceSchools(widget.fleetId);
        if (!_current(epoch) || generation != _accessGeneration) return;
        setState(() {
          final previousCity = _city;
          _city = cities
              .where(
                (city) =>
                    city.cityIbgeCode == previousCity?.cityIbgeCode &&
                    city.cityName.trim().toLowerCase() ==
                        previousCity?.cityName.trim().toLowerCase() &&
                    city.stateCode == previousCity?.stateCode,
              )
              .firstOrNull;
          _school = schools
              .where((school) => school.id == _school?.id)
              .firstOrNull;
          if (previousCity != null && _city == null) _resetAddress();
          _cities = cities;
          _schools = schools;
          _loading = false;
        });
      } else {
        setState(() => _loading = false);
      }
    } catch (error) {
      if (!_current(epoch) || generation != _accessGeneration) return;
      if (FleetStudentErrorMapper.classifyWriteFailure(error) ==
          FleetStudentWriteFailureKind.accessUnavailable) {
        _deny();
        return;
      }
      setState(() {
        _loading = false;
        _message = 'Não foi possível carregar as opções. Tente novamente.';
      });
    }
  }

  @override
  void didUpdateWidget(covariant FleetStudentRegistrationScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.userId != widget.userId ||
        oldWidget.fleetId != widget.fleetId ||
        oldWidget.authService != widget.authService) {
      _submission.invalidate();
      _clearDraft();
      _epoch++;
      _authSubscription?.cancel();
      _denied = false;
      _bind();
    }
  }

  @override
  void dispose() {
    _epoch++;
    _authSubscription?.cancel();
    for (final field in _fields.values) {
      field.dispose();
    }
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_dispatching,
    child: Scaffold(
      appBar: AppBar(title: const Text('Cadastrar aluno')),
      body: _body(),
    ),
  );
  Widget _body() {
    if (_denied) {
      return const Center(
        child: Text('Seu acesso à frota não está disponível.'),
      );
    }
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_message != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_message!),
            TextButton(
              onPressed: _checkAccess,
              child: const Text('Tentar novamente'),
            ),
          ],
        ),
      );
    }
    if (_submission.phase == FleetStudentSubmissionPhase.unknown ||
        _submission.phase == FleetStudentSubmissionPhase.submitting ||
        _submission.phase == FleetStudentSubmissionPhase.committed) {
      return _confirmation();
    }
    if (_cities.isEmpty || _schools.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(20),
          child: Text(
            'A frota precisa ter cidades e escolas atendidas para cadastrar alunos.',
          ),
        ),
      );
    }
    return AbsorbPointer(absorbing: _dispatching, child: _buildForm());
  }

  Widget _confirmation() => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      Text(
        _submission.conflict
            ? FleetStudentErrorMapper.message(
                const PostgrestException(
                  message: '',
                  code: 'idempotency_conflict',
                ),
              )
            : _submission.phase == FleetStudentSubmissionPhase.committed
            ? 'Aluno cadastrado.'
            : 'Não foi possível confirmar o cadastro. Verifique sua conexão e tente novamente.',
      ),
      const SizedBox(height: 16),
      if (_submission.phase != FleetStudentSubmissionPhase.committed)
        const Text(
          'Você pode voltar. A confirmação ficará pendente nesta sessão. Ao encerrar o aplicativo, revise a lista antes de iniciar outro cadastro.',
        ),
      if (_dispatching)
        const Padding(
          padding: EdgeInsets.all(16),
          child: Center(child: CircularProgressIndicator()),
        ),
      if (!_submission.conflict &&
          _submission.phase != FleetStudentSubmissionPhase.committed)
        ElevatedButton(
          onPressed: _dispatching ? null : _submit,
          child: const Text('Tentar confirmar novamente'),
        ),
      TextButton(
        onPressed: _dispatching
            ? null
            : () => Navigator.of(context).pop(
                _submission.phase == FleetStudentSubmissionPhase.committed
                    ? true
                    : null,
              ),
        child: const Text('Voltar para a lista'),
      ),
    ],
  );
  void _resetAddress() {
    _search.clear();
    _location = null;
    _locationMessage = null;
    _addressIdentity = null;
    for (final name in [
      'street',
      'streetNumber',
      'neighborhood',
      'postalCode',
      'addressComplement',
    ]) {
      _fields[name]!.clear();
    }
  }

  void _clearDraft() {
    _dispatching = false;
    _message = null;
    _type = FleetStudentType.minor;
    _shift = FleetStudentShift.morning;
    for (final field in _fields.values) {
      field.clear();
    }
    _resetAddress();
    _birthDate = null;
    _city = null;
    _school = null;
    _location = null;
    _locationMessage = null;
    _feedback = null;
    MapboxGeocodingService.clearCache();
  }

  FleetStudentRegistration? _draft() {
    final location = _location,
        city = _city,
        school = _school,
        birthDate = _birthDate;
    if (location == null ||
        city == null ||
        school == null ||
        birthDate == null) {
      return null;
    }
    return FleetStudentRegistration(
      studentType: _type,
      fullName: _fields['fullName']!.text,
      birthDate: birthDate,
      postalCode: _fields['postalCode']!.text,
      street: _fields['street']!.text,
      streetNumber: _fields['streetNumber']!.text,
      neighborhood: _fields['neighborhood']!.text,
      city: city,
      latitude: location.latitude,
      longitude: location.longitude,
      schoolId: school.id,
      shift: _shift,
      contactFullName:
          _fields[_type == FleetStudentType.adult
                  ? 'fullName'
                  : 'contactFullName']!
              .text,
      addressComplement: _fields['addressComplement']!.text,
      contactEmail: _fields['contactEmail']!.text,
      contactPhone: _fields['contactPhone']!.text,
    );
  }

  String _commandId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  Future<void> _submit() async {
    if (_dispatching ||
        _denied ||
        _submission.conflict ||
        _submission.phase == FleetStudentSubmissionPhase.committed) {
      return;
    }
    final retry = _submission.phase == FleetStudentSubmissionPhase.unknown;
    final draft = retry ? _submission.command?.registration : _draft();
    if (!retry) {
      final errors = draft?.validate(today: DateTime.now());
      if (draft == null || errors!.isNotEmpty) {
        setState(
          () => _feedback = draft == null
              ? 'Preencha os campos obrigatórios e selecione o endereço.'
              : errors!.values.join(' '),
        );
        return;
      }
    }
    final epoch = _epoch;
    setState(() {
      _dispatching = true;
      _feedback = null;
    });
    var dispatched = false;
    try {
      if (!_current(epoch)) {
        _deny();
        return;
      }
      final access = await widget.authService.getMyAccessContext();
      if (!_current(epoch)) return;
      if (!access.ownerFleetIds.contains(widget.fleetId)) {
        _deny();
        return;
      }
      if (!(retry
          ? _submission.retry()
          : _submission.begin(_commandId(), draft!))) {
        return;
      }
      dispatched = true;
      setState(() {});
      final command = _submission.command!;
      final receipt = await _fleet.registerStudent(
        fleetId: widget.fleetId,
        commandId: command.id,
        registration: command.registration,
      );
      if (!_current(epoch)) return;
      _submission.commit(receipt);
      // A token refresh does not change the security epoch; role loss still does.
      final currentAccess = await widget.authService.getMyAccessContext();
      if (!_current(epoch)) return;
      if (!currentAccess.ownerFleetIds.contains(widget.fleetId)) {
        _deny();
        return;
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (!_current(epoch)) return;
      final kind = FleetStudentErrorMapper.classifyWriteFailure(error);
      if (kind == FleetStudentWriteFailureKind.accessUnavailable) {
        _deny();
        return;
      }
      if (dispatched) _submission.fail(kind);
      setState(() {
        _feedback = FleetStudentErrorMapper.message(error);
      });
    } finally {
      if (mounted && epoch == _epoch) setState(() => _dispatching = false);
    }
  }

  void _invalidateLocation() {
    setState(() {
      _location = null;
      _locationMessage = 'Selecione novamente o endereço completo na busca.';
    });
  }

  void _selectAddress(MapboxPlaceSuggestion suggestion) {
    final city = _city;
    if (city == null) return;
    if (suggestion.cityName.trim().toLowerCase() !=
            city.cityName.trim().toLowerCase() ||
        suggestion.stateCode.trim().toUpperCase() !=
            city.stateCode.trim().toUpperCase()) {
      setState(() {
        _location = null;
        _locationMessage =
            'O endereço deve pertencer à cidade e ao estado selecionados.';
      });
      return;
    }
    final previous = _addressIdentity;
    final sameAddress =
        previous == null ||
        (previous.street == suggestion.street.trim().toLowerCase() &&
            (previous.number == suggestion.streetNumber.trim() ||
                (previous.number.isEmpty &&
                    _fields['streetNumber']!.text.trim() ==
                        suggestion.streetNumber.trim())));
    setState(() {
      if (!sameAddress) {
        _fields['neighborhood']!.clear();
        _fields['postalCode']!.clear();
        _fields['addressComplement']!.clear();
        if (suggestion.streetNumber.isEmpty) _fields['streetNumber']!.clear();
      }
      _addressIdentity = (
        street: suggestion.street.trim().toLowerCase(),
        number: suggestion.streetNumber.trim(),
      );
      _fields['street']!.text = suggestion.street;
      if (suggestion.streetNumber.isNotEmpty) {
        _fields['streetNumber']!.text = suggestion.streetNumber;
      }
      if (suggestion.neighborhood.isNotEmpty) {
        _fields['neighborhood']!.text = suggestion.neighborhood;
      }
      if (suggestion.postalCode.isNotEmpty) {
        _fields['postalCode']!.text = suggestion.postalCode;
      }
      _location =
          suggestion.street.trim().isNotEmpty &&
              suggestion.streetNumber.trim().isNotEmpty &&
              suggestion.latitude.isFinite &&
              suggestion.longitude.isFinite &&
              suggestion.latitude.abs() <= 90 &&
              suggestion.longitude.abs() <= 180
          ? suggestion
          : null;
      _locationMessage = _location == null
          ? 'Complete o número e selecione novamente o endereço completo na busca.'
          : null;
    });
  }

  Widget _field(String name, String label, {TextInputType? keyboardType}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: TextField(
          key: Key(name),
          controller: _fields[name],
          onChanged: (value) {
            if (name == 'street' ||
                name == 'streetNumber' ||
                (name == 'neighborhood' &&
                    _location?.neighborhood.isNotEmpty == true &&
                    value.trim() != _location!.neighborhood.trim()) ||
                (name == 'postalCode' &&
                    _location?.postalCode.isNotEmpty == true &&
                    value.trim() != _location!.postalCode.trim())) {
              _invalidateLocation();
            }
          },
          keyboardType: keyboardType,
          textInputAction: TextInputAction.next,
          decoration: InputDecoration(
            labelText: label,
            border: const OutlineInputBorder(),
          ),
        ),
      );
  Future<void> _pickBirthday() async {
    final epoch = _epoch;
    final date = await showDatePicker(
      context: context,
      initialDate: _birthDate ?? DateTime.now(),
      firstDate: DateTime(1900),
      lastDate: DateTime.now(),
      helpText: 'Data de nascimento',
      cancelText: 'Cancelar',
      confirmText: 'Selecionar',
    );
    if (_current(epoch) && date != null) setState(() => _birthDate = date);
  }

  Widget _buildForm() => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      DropdownButtonFormField<FleetStudentType>(
        initialValue: _type,
        isExpanded: true,
        decoration: const InputDecoration(labelText: 'Tipo de aluno'),
        items: const [
          DropdownMenuItem(
            value: FleetStudentType.minor,
            child: Text('Menor de idade'),
          ),
          DropdownMenuItem(
            value: FleetStudentType.adult,
            child: Text('Adulto'),
          ),
        ],
        onChanged: (value) {
          if (value != null) setState(() => _type = value);
        },
      ),
      const SizedBox(height: 16),
      _field('fullName', 'Nome completo do aluno'),
      OutlinedButton(
        onPressed: _pickBirthday,
        child: Text(
          _birthDate == null
              ? 'Selecionar data de nascimento'
              : '${_birthDate!.day.toString().padLeft(2, '0')}/${_birthDate!.month.toString().padLeft(2, '0')}/${_birthDate!.year}',
        ),
      ),
      const SizedBox(height: 16),
      DropdownButtonFormField<FleetServiceCity>(
        initialValue: _city,
        isExpanded: true,
        decoration: const InputDecoration(labelText: 'Cidade atendida'),
        items: _cities
            .map(
              (city) => DropdownMenuItem(
                value: city,
                child: Text('${city.cityName} / ${city.stateCode}'),
              ),
            )
            .toList(),
        onChanged: (city) => setState(() {
          _city = city;
          _resetAddress();
        }),
      ),
      if (_city != null)
        MapboxAddressAutocompleteField(
          key: ValueKey('${widget.fleetId}/${_city!.cityIbgeCode}'),
          controller: _search,
          geocodingService: widget.geocodingService,
          onChanged: (_) => _invalidateLocation(),
          onAddressSelected: _selectAddress,
        ),
      if (_city != null)
        Text(
          _location != null
              ? 'Localização selecionada'
              : _locationMessage ?? 'Selecione o endereço completo na busca.',
        ),
      const SizedBox(height: 16),
      _field('street', 'Rua'),
      _field('streetNumber', 'Número'),
      _field('addressComplement', 'Complemento (opcional)'),
      _field('neighborhood', 'Bairro'),
      _field('postalCode', 'CEP'),
      DropdownButtonFormField<FleetServiceSchool>(
        initialValue: _school,
        isExpanded: true,
        decoration: const InputDecoration(labelText: 'Escola atendida'),
        items: _schools
            .map(
              (school) =>
                  DropdownMenuItem(value: school, child: Text(school.name)),
            )
            .toList(),
        onChanged: (school) => setState(() => _school = school),
      ),
      const SizedBox(height: 16),
      DropdownButtonFormField<FleetStudentShift>(
        initialValue: _shift,
        isExpanded: true,
        decoration: const InputDecoration(labelText: 'Turno'),
        items: const [
          DropdownMenuItem(
            value: FleetStudentShift.morning,
            child: Text('Manhã'),
          ),
          DropdownMenuItem(
            value: FleetStudentShift.afternoon,
            child: Text('Tarde'),
          ),
          DropdownMenuItem(
            value: FleetStudentShift.evening,
            child: Text('Noite'),
          ),
          DropdownMenuItem(
            value: FleetStudentShift.fullTime,
            child: Text('Integral'),
          ),
        ],
        onChanged: (shift) {
          if (shift != null) setState(() => _shift = shift);
        },
      ),
      const SizedBox(height: 16),
      Text(
        _type == FleetStudentType.minor
            ? 'Contato do responsável'
            : 'Contato do aluno',
      ),
      const SizedBox(height: 16),
      if (_type == FleetStudentType.minor)
        _field('contactFullName', 'Nome do responsável'),
      _field(
        'contactEmail',
        'E-mail de contato',
        keyboardType: TextInputType.emailAddress,
      ),
      _field(
        'contactPhone',
        'Telefone de contato',
        keyboardType: TextInputType.phone,
      ),
      const Text('Informe ao menos um canal de contato.'),
      const SizedBox(height: 16),
      if (_feedback != null) Text(_feedback!),
      ElevatedButton(
        onPressed: _dispatching ? null : _submit,
        child: Text(_dispatching ? 'Enviando...' : 'Salvar cadastro'),
      ),
    ],
  );
}
