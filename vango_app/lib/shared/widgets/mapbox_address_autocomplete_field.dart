import 'dart:async';
import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text_styles.dart';
import '../../features/shared/services/mapbox_geocoding_service.dart';

/// Form field providing real-time Mapbox Search / Geocoding autocomplete suggestions
/// with 350ms debouncing, dropdown selection overlay, and coordinate extraction.
class MapboxAddressAutocompleteField extends StatefulWidget {
  const MapboxAddressAutocompleteField({
    super.key,
    required this.controller,
    required this.onAddressSelected,
    this.label = 'Endereço residencial',
    this.hint = 'Digite a rua e número (ex: Oscar Freire, 1000)',
    this.validator,
    this.geocodingService,
  });

  /// Text editing controller for the address input.
  final TextEditingController controller;

  /// Callback fired when the user selects a suggested place, providing coordinates and formatted name.
  final ValueChanged<MapboxPlaceSuggestion> onAddressSelected;

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
  late final MapboxGeocodingService _service;
  Timer? _debounceTimer;
  List<MapboxPlaceSuggestion> _suggestions = [];
  bool _isLoading = false;
  bool _showOverlay = false;

  @override
  void initState() {
    super.initState();
    _service = widget.geocodingService ?? MapboxGeocodingService();
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    super.dispose();
  }

  void _onTextChanged(String text) {
    _debounceTimer?.cancel();
    if (text.trim().length < 3) {
      if (_suggestions.isNotEmpty) {
        setState(() {
          _suggestions = [];
          _showOverlay = false;
        });
      }
      return;
    }

    _debounceTimer = Timer(const Duration(milliseconds: 400), () async {
      setState(() => _isLoading = true);
      final results = await _service.searchAddresses(text);
      if (!mounted) return;
      setState(() {
        _suggestions = results;
        _isLoading = false;
        _showOverlay = results.isNotEmpty;
      });
    });
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
            child: ListView.separated(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(vertical: 6),
              itemCount: _suggestions.length,
              separatorBuilder: (context, index) => const Divider(
                height: 1,
                color: AppColors.inputBorder,
              ),
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
                    widget.controller.text = suggestion.placeName;
                    widget.onAddressSelected(suggestion);
                    setState(() {
                      _showOverlay = false;
                      _suggestions = [];
                    });
                  },
                );
              },
            ),
          ),
      ],
    );
  }
}
