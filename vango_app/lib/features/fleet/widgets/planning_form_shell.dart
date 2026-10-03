import 'package:flutter/material.dart';
import '../controllers/fleet_planning_controller.dart';
import '../services/fleet_planning_error_mapper.dart';

/// Shared submission feedback; each entity keeps its own form and draft.
class PlanningFormShell extends StatelessWidget {
  const PlanningFormShell({
    super.key,
    required this.title,
    required this.controller,
    required this.formKey,
    required this.children,
    required this.onSave,
  });
  final String title;
  final FleetPlanningController controller;
  final GlobalKey<FormState> formKey;
  final List<Widget> children;
  final Future<void> Function() onSave;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: Text(title)),
      body: !controller.active
          ? const Center(child: Text('Seu acesso à frota não está disponível.'))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Form(
                key: formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    AbsorbPointer(
                      absorbing:
                          !controller.canSubmit ||
                          controller.outcome == PlanningWriteOutcome.committed,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final child in children)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 16),
                              child: child,
                            ),
                        ],
                      ),
                    ),
                    if (controller.error case final error?)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Text(
                          PlanningErrorMapper.message(error),
                          semanticsLabel: PlanningErrorMapper.message(error),
                        ),
                      ),
                    if (controller.outcome == PlanningWriteOutcome.committed)
                      const Text('Configuração salva.'),
                    if (controller.readError != null) ...[
                      const Text(
                        'Os dados foram enviados, mas não foi possível atualizar a visualização.',
                      ),
                      OutlinedButton(
                        onPressed: controller.loading ? null : controller.load,
                        child: const Text('Atualizar visualização'),
                      ),
                    ],
                    if (controller.outcome == PlanningWriteOutcome.uncertain)
                      FilledButton(
                        onPressed: controller.retryPending,
                        child: const Text('Verificar envio novamente'),
                      )
                    else if (controller.outcome ==
                        PlanningWriteOutcome.committed)
                      FilledButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('Concluir'),
                      )
                    else
                      FilledButton(
                        onPressed: controller.canSubmit
                            ? () async {
                                if (formKey.currentState!.validate()) {
                                  await onSave();
                                }
                              }
                            : null,
                        child: Text(
                          controller.outcome == PlanningWriteOutcome.submitting
                              ? 'Salvando…'
                              : 'Salvar',
                        ),
                      ),
                    if (controller.outcome == PlanningWriteOutcome.rejected)
                      TextButton(
                        onPressed: () async {
                          Navigator.pop(context);
                          await controller.load();
                        },
                        child: const Text('Descartar rascunho e recarregar'),
                      ),
                  ],
                ),
              ),
            ),
    ),
  );
}

/// Required form text uses visible, safe Portuguese validation.
String? requiredPlanningText(String? value) =>
    value == null || value.trim().isEmpty ? 'Preencha este campo.' : null;
