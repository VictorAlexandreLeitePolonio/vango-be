import 'dart:async';
import 'package:flutter/material.dart';
import '../controllers/fleet_planning_controller.dart';
import '../models/fleet_command_id.dart';
import 'planning_form_shell.dart';

/// Coverage entries are saved separately; linking a school never adds its city.
enum CoverageKind { city, school }

/// Selects authoritative municipalities or published institutions in served cities.
class FleetCoverageForm extends StatefulWidget {
  const FleetCoverageForm({
    super.key,
    required this.controller,
    required this.kind,
  });
  final FleetPlanningController controller;
  final CoverageKind kind;
  @override
  State<FleetCoverageForm> createState() => _FleetCoverageFormState();
}

class _FleetCoverageFormState extends State<FleetCoverageForm> {
  final _key = GlobalKey<FormState>();
  final _query = TextEditingController();
  String? _city, _school, _type;
  int _offset = 0;
  @override
  void initState() {
    super.initState();
    if (widget.kind == CoverageKind.city) {
      unawaited(widget.controller.loadCities());
    }
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    if (_city == null) return;
    setState(() => _school = null);
    await widget.controller.searchSchools(
      _city!,
      _query.text,
      type: _type,
      offset: _offset,
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final controller = widget.controller;
      final cities = widget.kind == CoverageKind.city
          ? controller.catalogCities
          : controller.planning?.cities ?? [];
      return PlanningFormShell(
        title: widget.kind == CoverageKind.city
            ? 'Adicionar cidade'
            : 'Adicionar instituição',
        controller: controller,
        formKey: _key,
        onSave: () => widget.kind == CoverageKind.city
            ? controller.linkCity(_city!, createFleetCommandId())
            : controller.linkSchool(_school!, createFleetCommandId()),
        children: [
          if (controller.catalogLoading) const LinearProgressIndicator(),
          if (controller.catalogError != null)
            Column(
              children: [
                const Text('Não foi possível consultar o catálogo.'),
                TextButton(
                  onPressed: widget.kind == CoverageKind.city
                      ? controller.loadCities
                      : _search,
                  child: const Text('Tentar novamente'),
                ),
              ],
            ),
          if (cities.isEmpty && !controller.catalogLoading)
            const Text(
              'Nenhum município disponível. O catálogo precisa ser publicado pela administração.',
            ),
          DropdownButtonFormField<String>(
            initialValue: _city,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Cidade'),
            items: [
              for (final city in cities)
                DropdownMenuItem(
                  value: city.cityIbgeCode,
                  child: Text(
                    '${city.cityName} — ${city.stateCode}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (value) {
              setState(() {
                _city = value;
                _school = null;
                _offset = 0;
              });
              if (widget.kind == CoverageKind.school) unawaited(_search());
            },
            validator: requiredPlanningText,
          ),
          if (widget.kind == CoverageKind.school) ...[
            DropdownButtonFormField<String>(
              initialValue: _type,
              decoration: const InputDecoration(
                labelText: 'Tipo de instituição',
              ),
              items: const [
                DropdownMenuItem<String>(value: null, child: Text('Todos')),
                DropdownMenuItem(value: 'school', child: Text('Escolas')),
                DropdownMenuItem(
                  value: 'higher_education',
                  child: Text('Faculdades / campus'),
                ),
              ],
              onChanged: (value) {
                setState(() {
                  _type = value;
                  _offset = 0;
                });
                unawaited(_search());
              },
            ),
            TextFormField(
              controller: _query,
              decoration: const InputDecoration(
                labelText: 'Nome da instituição',
              ),
              onFieldSubmitted: (_) {
                _offset = 0;
                unawaited(_search());
              },
            ),
            OutlinedButton(
              onPressed: controller.catalogLoading || _city == null
                  ? null
                  : () {
                      _offset = 0;
                      unawaited(_search());
                    },
              child: const Text('Buscar instituições'),
            ),
            if (_city != null &&
                !controller.catalogLoading &&
                controller.schoolResults.isEmpty &&
                controller.catalogError == null)
              const Text('Nenhuma instituição publicada encontrada.'),
            FormField<String>(
              validator: (_) =>
                  _school == null ? 'Selecione uma instituição.' : null,
              builder: (field) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final school in controller.schoolResults)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      selected: _school == school.id,
                      leading: Icon(
                        _school == school.id
                            ? Icons.radio_button_checked
                            : Icons.radio_button_off,
                      ),
                      title: Text(school.name),
                      subtitle: Text(
                        '${school.institutionType == 'school' ? 'Escola' : 'Faculdade / campus'} • ${school.city.cityName}\n${school.street}, ${school.streetNumber} • ${school.neighborhood}',
                      ),
                      onTap: () => setState(() => _school = school.id),
                    ),
                  if (field.errorText != null) Text(field.errorText!),
                ],
              ),
            ),
            Wrap(
              spacing: 12,
              children: [
                TextButton(
                  onPressed: controller.catalogLoading || _offset == 0
                      ? null
                      : () {
                          _offset -= 50;
                          unawaited(_search());
                        },
                  child: const Text('Anterior'),
                ),
                TextButton(
                  onPressed:
                      controller.catalogLoading ||
                          controller.schoolResults.length < 50
                      ? null
                      : () {
                          _offset += 50;
                          unawaited(_search());
                        },
                  child: const Text('Próxima'),
                ),
              ],
            ),
          ],
        ],
      );
    },
  );
}
