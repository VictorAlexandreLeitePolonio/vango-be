import 'dart:async';
import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text_styles.dart';
import '../../features/shared/services/mapbox_geocoding_service.dart';

/// Form field providing real-time Mapbox Search / Geocoding autocomplete suggestions
/// with 400ms debouncing, dropdown selection overlay, and coordinate extraction.
class MapboxAddressAutocompleteField extends StatefulWidget {
  const MapboxAddressAutocompleteField({
    super.key,
    required this.controller,
    required this.onAddressSelected,
    this.label = 'Endereço residencial',
    this.hint = 'Digite a rua e número (ex: Oscar Freire, 1000)',
    this.validator,
    this.geocodingService,
    this.onChanged,
  });

  /// Text editing controller for the address input.
  final TextEditingController controller;

  /// Callback fired when the user selects a suggested place, providing coordinates and formatted name.
  final ValueChanged<MapboxPlaceSuggestion> onAddressSelected;

  /// Notifies the parent once for a user edit, before scheduling a search.
  final ValueChanged<String>? onChanged;

  /// Label displayed above the input field.
  final String label;

  /// Placeholder hint text.
  final String hint;

  /// Optional form validation callback.
  final String? Function(String?)? validator;

  /// Optional injected Mapbox geocoding service.
  final MapboxGeocodingService? geocodingService;

  @override
  State<MapboxAddressAutocompleteField> createState() =>
      _MapboxAddressAutocompleteFieldState();
}

class _MapboxAddressAutocompleteFieldState
    extends State<MapboxAddressAutocompleteField> {
  late MapboxGeocodingService _service;
  late String _observedText;
  Timer? _debounceTimer;
  int _generation = 0;
  List<MapboxPlaceSuggestion> _suggestions = [];
  bool _isLoading = false;
  bool _showOverlay = false;
  bool _hasError = false;
  bool _hasSearched = false;

  @override
  void initState() {
    super.initState();
    _service = widget.geocodingService ?? MapboxGeocodingService();
    _observedText = widget.controller.text;
    widget.controller.addListener(_controllerChanged);
  }

  @override
  void didUpdateWidget(covariant MapboxAddressAutocompleteField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_controllerChanged);
      _observedText = widget.controller.text;
      widget.controller.addListener(_controllerChanged);
    }
    if (oldWidget.geocodingService != widget.geocodingService) {
      _service = widget.geocodingService ?? MapboxGeocodingService();
    }
    if (oldWidget.controller != widget.controller ||
        oldWidget.geocodingService != widget.geocodingService) {
      _invalidate();
    }
  }

  @override
  void dispose() {
    ++_generation;
    _debounceTimer?.cancel();
    widget.controller.removeListener(_controllerChanged);
    super.dispose();
  }

  void _controllerChanged() {
    if (_observedText == widget.controller.text) return;
    _observedText = widget.controller.text;
    _invalidate();
  }

  void _invalidate() {
    ++_generation;
    _debounceTimer?.cancel();
    setState(() {
      _suggestions = [];
      _isLoading = false;
      _showOverlay = false;
      _hasSearched = false;
      _hasError = false;
    });
  }

  void _onTextChanged(String text) {
    _invalidate();
    final generation = _generation;
    widget.onChanged?.call(text);
    if (!mounted || generation != _generation) return;
    if (text.trim().length < 3) return;
    _debounceTimer = Timer(
      const Duration(milliseconds: 400),
      () => _search(text, generation),
    );
  }

  Future<void> _search(String query, int generation) async {
    if (!mounted || generation != _generation || query.trim().length < 3) {
      return;
    }
    setState(() {
      _isLoading = true;
      _hasError = false;
    });
    try {
      final results = await _service.searchAddresses(query);
      if (!mounted || generation != _generation) return;
      setState(() {
        _hasSearched = true;
        _suggestions = results;
        _isLoading = false;
        _showOverlay = results.isNotEmpty;
      });
    } catch (_) {
      // Never expose injected transport errors or provider payloads in UI/logs.
      if (!mounted || generation != _generation) return;
      setState(() {
        _suggestions = [];
        _isLoading = false;
        _showOverlay = false;
        _hasError = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextFormField(
          controller: widget.controller,
          onChanged: _onTextChanged,
          validator: widget.validator,
          style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textDark),
          decoration: InputDecoration(
            labelText: widget.label,
            hintText: widget.hint,
            prefixIcon: const Icon(
              Icons.location_on_outlined,
              color: AppColors.primaryOrange,
              size: 22,
            ),
            suffixIcon: _isLoading
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: AppColors.primaryOrange,
                      ),
                    ),
                  )
                : null,
          ),
        ),
        if (_hasSearched && !_isLoading && !_hasError && _suggestions.isEmpty)
          const Text('Nenhum endereço encontrado.'),
        if (_hasError) ...[
          const Text('Não foi possível buscar endereços. Tente novamente.'),
          TextButton(
            onPressed: () => _search(widget.controller.text, _generation),
            child: const Text('Tentar novamente'),
          ),
        ],
        if (_showOverlay && _suggestions.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(top: 6),
            constraints: const BoxConstraints(maxHeight: 220),
            decoration: BoxDecoration(
              color: AppColors.cardBackground,
              borderRadius: BorderRadius.circular(16),
              boxShadow: const [
                BoxShadow(
                  color: AppColors.shadowMedium,
                  blurRadius: 16,
                  offset: Offset(0, 4),
                ),
              ],
              border: Border.all(
                color: AppColors.inputBorder.withValues(alpha: 0.8),
              ),
            ),
            child: Material(
              color: AppColors.cardBackground,
              borderRadius: BorderRadius.circular(16),
              child: ListView.separated(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(vertical: 6),
                itemCount: _suggestions.length,
                separatorBuilder: (context, index) =>
                    const Divider(height: 1, color: AppColors.inputBorder),
                itemBuilder: (context, index) {
                  final suggestion = _suggestions[index];
                  return ListTile(
                    dense: true,
                    leading: const Icon(
                      Icons.place_rounded,
                      color: AppColors.primaryOrangeDark,
                      size: 20,
                    ),
                    title: Text(
                      suggestion.placeName,
                      style: AppTextStyles.bodySmall.copyWith(
                        color: AppColors.textDark,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: Text(
                      '${suggestion.neighborhood}, ${suggestion.cityName} - ${suggestion.stateCode}',
                      style: AppTextStyles.caption.copyWith(
                        color: AppColors.textMuted,
                        fontSize: 11,
                      ),
                    ),
                    onTap: () {
                      _invalidate();
                      widget.controller.text = suggestion.placeName;
                      widget.onAddressSelected(suggestion);
                    },
                  );
                },
              ),
            ),
          ),
      ],
    );
  }
}
