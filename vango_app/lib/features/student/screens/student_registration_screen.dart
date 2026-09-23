import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../shared/widgets/mapbox_address_autocomplete_field.dart';
import '../../../shared/widgets/vango_button.dart';
import '../../../shared/widgets/vango_text_field.dart';
import '../../shared/services/mapbox_geocoding_service.dart';
import '../services/student_service.dart';

class StudentRegistrationScreen extends StatefulWidget {
  const StudentRegistrationScreen({
    super.key,
    this.studentService,
    this.geocodingService,
  });

  final StudentService? studentService;
  final MapboxGeocodingService? geocodingService;

  @override
  State<StudentRegistrationScreen> createState() =>
      _StudentRegistrationScreenState();
}

class _StudentRegistrationScreenState extends State<StudentRegistrationScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _birthDateController = TextEditingController(text: '2015-06-20');
  final _addressSearchController = TextEditingController();
  final _numberController = TextEditingController();
  final _neighborhoodController = TextEditingController();
  final _cityController = TextEditingController(text: 'São Paulo');

  late final StudentService _studentService;
  bool _isLoading = false;

  MapboxPlaceSuggestion? _selectedPlace;

  @override
  void initState() {
    super.initState();
    _studentService = widget.studentService ?? StudentService();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _birthDateController.dispose();
    _addressSearchController.dispose();
    _numberController.dispose();
    _neighborhoodController.dispose();
    _cityController.dispose();
    super.dispose();
  }

  void _onAddressSelected(MapboxPlaceSuggestion suggestion) {
    setState(() {
      _selectedPlace = suggestion;
      _addressSearchController.text = suggestion.street;
      if (suggestion.streetNumber != 'S/N') {
        _numberController.text = suggestion.streetNumber;
      }
      _neighborhoodController.text = suggestion.neighborhood;
      _cityController.text = suggestion.cityName;
    });
  }

  Future<void> _handleSubmit() async {
    if (!_formKey.currentState!.validate()) return;

    final place = _selectedPlace;
    if (place == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Selecione um endereço nas sugestões do Mapbox'),
          backgroundColor: AppColors.errorRed,
        ),
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      await _studentService.createMinorStudent(
        fullName: _nameController.text,
        birthDate: _birthDateController.text,
        street: place.street,
        streetNumber: _numberController.text.trim().isNotEmpty
            ? _numberController.text.trim()
            : place.streetNumber,
        neighborhood: _neighborhoodController.text.trim().isNotEmpty
            ? _neighborhoodController.text.trim()
            : place.neighborhood,
        cityName: _cityController.text.trim(),
        cityIbgeCode: place.cityIbgeCode,
        stateCode: place.stateCode,
        postalCode: place.postalCode,
        latitude: place.latitude,
        longitude: place.longitude,
      );

      if (!mounted) return;
      setState(() => _isLoading = false);

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Aluno cadastrado com sucesso!'),
          backgroundColor: AppColors.successGreen,
        ),
      );

      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Erro ao cadastrar aluno: $e'),
          backgroundColor: AppColors.errorRed,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.backgroundWhite,
      appBar: AppBar(
        title: const Text('Cadastrar Aluno'),
        backgroundColor: Colors.transparent,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Dados do Aluno',
                      style: AppTextStyles.heading2,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Informe os dados e o endereço de embarque do aluno.',
                      style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textMuted),
                    ),
                    const SizedBox(height: 24),

                    // Nome
                    VanGoTextField(
                      controller: _nameController,
                      label: 'Nome completo do aluno',
                      hint: 'Ex: Lucas Alencar',
                      prefixIcon: Icons.person_outline_rounded,
                      validator: (v) => (v == null || v.trim().length < 3)
                          ? 'Informe o nome do aluno'
                          : null,
                    ),
                    const SizedBox(height: 16),

                    // Data nascimento
                    VanGoTextField(
                      controller: _birthDateController,
                      label: 'Data de nascimento (AAAA-MM-DD)',
                      hint: 'Ex: 2015-06-20',
                      prefixIcon: Icons.calendar_today_outlined,
                      keyboardType: TextInputType.datetime,
                      validator: (v) => (v == null || !v.contains('-'))
                          ? 'Informe a data de nascimento válida'
                          : null,
                    ),
                    const SizedBox(height: 24),

                    Text(
                      'Endereço de Embarque (Mapbox)',
                      style: AppTextStyles.heading3.copyWith(fontSize: 18),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Digite para buscar com precisão no mapa do Mapbox.',
                      style: AppTextStyles.caption.copyWith(color: AppColors.textMuted),
                    ),
                    const SizedBox(height: 12),

                    // Mapbox Autocomplete
                    MapboxAddressAutocompleteField(
                      controller: _addressSearchController,
                      onAddressSelected: _onAddressSelected,
                      geocodingService: widget.geocodingService,
                      validator: (_) => _selectedPlace == null
                          ? 'Selecione uma localização nas sugestões'
                          : null,
                    ),
                    const SizedBox(height: 16),

                    // Número e Bairro
                    Row(
                      children: [
                        Expanded(
                          flex: 2,
                          child: VanGoTextField(
                            controller: _numberController,
                            label: 'Número',
                            hint: '1000',
                            prefixIcon: Icons.home_outlined,
                            keyboardType: TextInputType.number,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          flex: 3,
                          child: VanGoTextField(
                            controller: _neighborhoodController,
                            label: 'Bairro',
                            hint: 'Cerqueira César',
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),

                    // Cidade
                    VanGoTextField(
                      controller: _cityController,
                      label: 'Cidade',
                      hint: 'São Paulo',
                      prefixIcon: Icons.location_city_outlined,
                    ),
                    const SizedBox(height: 32),

                    // Botão salvar
                    VanGoButton(
                      text: 'Salvar Aluno',
                      isLoading: _isLoading,
                      onPressed: _handleSubmit,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
