import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../../../core/config/mapbox_config.dart';
import '../models/fleet_planning.dart';
import '../controllers/fleet_planning_controller.dart';

/// Explicit point confirmation; map movement alone never selects an endpoint.
class RoutePointPicker extends StatefulWidget {
  const RoutePointPicker({
    super.key,
    required this.controller,
    this.initial,
    this.showTiles = true,
  });
  final FleetPlanningController controller;
  final PlanningPoint? initial;
  final bool showTiles;
  @override
  State<RoutePointPicker> createState() => _RoutePointPickerState();
}

class _RoutePointPickerState extends State<RoutePointPicker> {
  late final _label = TextEditingController(text: widget.initial?.label);
  late final _latitude = TextEditingController(
    text: widget.initial?.latitude.toString(),
  );
  late final _longitude = TextEditingController(
    text: widget.initial?.longitude.toString(),
  );
  late LatLng? _selected = widget.initial == null
      ? null
      : LatLng(widget.initial!.latitude, widget.initial!.longitude);
  String? _error;
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_contextChanged);
  }

  void _contextChanged() {
    if (!widget.controller.active) {
      _label.clear();
      _latitude.clear();
      _longitude.clear();
      setState(() {
        _selected = null;
        _error = null;
      });
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_contextChanged);
    _label.dispose();
    _latitude.dispose();
    _longitude.dispose();
    super.dispose();
  }

  void _select(LatLng point) {
    setState(() {
      _selected = point;
      _latitude.text = point.latitude.toStringAsFixed(6);
      _longitude.text = point.longitude.toStringAsFixed(6);
      _error = null;
    });
  }

  void _coordinates() {
    final lat = double.tryParse(_latitude.text.replaceAll(',', '.')),
        lon = double.tryParse(_longitude.text.replaceAll(',', '.'));
    if (lat == null ||
        lon == null ||
        !lat.isFinite ||
        !lon.isFinite ||
        lat.abs() > 90 ||
        lon.abs() > 180) {
      setState(() => _error = 'Informe coordenadas válidas.');
      return;
    }
    _select(LatLng(lat, lon));
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.controller.active) {
      return Scaffold(
        appBar: AppBar(title: const Text('Selecionar ponto')),
        body: const Center(
          child: Text('Seu acesso à frota não está disponível.'),
        ),
      );
    }
    const config = MapboxConfig.fromEnvironment();
    return Scaffold(
      appBar: AppBar(title: const Text('Selecionar ponto')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Toque no mapa ou informe coordenadas. Confirme o ponto antes de salvar a rota.',
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 220,
              child: FlutterMap(
                options: MapOptions(
                  initialCenter: _selected ?? const LatLng(-22.9, -47.1),
                  initialZoom: 12,
                  onTap: (_, point) => _select(point),
                ),
                children: [
                  if (widget.showTiles && config.hasToken)
                    TileLayer(
                      urlTemplate: config.streetsTileUrl,
                      userAgentPackageName: 'com.vango.vangoapp',
                    ),
                  if (_selected case final point?)
                    MarkerLayer(
                      markers: [
                        Marker(
                          point: point,
                          child: const Icon(
                            Icons.location_pin,
                            size: 40,
                            semanticLabel: 'Ponto selecionado',
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
            TextFormField(
              controller: _label,
              decoration: const InputDecoration(labelText: 'Nome do ponto'),
              onChanged: (_) => setState(() {}),
            ),
            TextFormField(
              controller: _latitude,
              decoration: const InputDecoration(labelText: 'Latitude'),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
                signed: true,
              ),
              onChanged: (_) => setState(() => _selected = null),
            ),
            TextFormField(
              controller: _longitude,
              decoration: const InputDecoration(labelText: 'Longitude'),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
                signed: true,
              ),
              onChanged: (_) => setState(() => _selected = null),
            ),
            if (_error case final error?) Text(error),
            OutlinedButton(
              onPressed: _coordinates,
              child: const Text('Selecionar coordenadas'),
            ),
            if (_selected case final point?)
              Text(
                'Selecionado: ${point.latitude.toStringAsFixed(6)}, ${point.longitude.toStringAsFixed(6)}',
              ),
            FilledButton(
              onPressed: _selected == null || _label.text.trim().isEmpty
                  ? null
                  : () => Navigator.pop<PlanningPoint>(context, (
                      latitude: _selected!.latitude,
                      longitude: _selected!.longitude,
                      label: _label.text.trim(),
                    )),
              child: const Text('Confirmar ponto'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancelar'),
            ),
          ],
        ),
      ),
    );
  }
}
