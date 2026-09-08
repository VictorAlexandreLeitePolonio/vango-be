# Ciclo 4 — Operação diária

**Data:** 7 de setembro de 2026
**Status:** aprovada em 2026-09-07; não implementada
**Implementation plan:** [Ciclo 4](../plans/2026-09-07-ciclo-4-operacao-diaria.md)
**Base:** Ciclo 3 validado; contratos de reservas e vigência aprovados.

## Objetivo e corte

Executar o transporte diário a partir da programação reservada, preservando passageiros, confirmações e histórico. Inclui calendário, geração idempotente, comandos de viagem, presença, substituições e ocorrências. Não inclui FCM, GPS ou chamada de provedor de rotas; notificações efetivas chegam no Ciclo 5, mapa e sincronização offline no Ciclo 6.

## Modelo proposto

| Entidade | Responsabilidade |
| --- | --- |
| `route_service_exceptions` | marcação de transporte por rota/data, autor e motivo; uma exceção por chave |
| `service_days` | agrupamento operacional por frota/data local, sem fundir estados de ida/volta |
| `trips` | execução de uma agenda direcional, data local, horários, recursos, estado, revisão e sequência operacional |
| `trip_passengers` | snapshot da reserva, confirmação separada da presença, autores e horários |
| `trip_stops` | pontos operacionais e ordem, snapshot independente do cadastro atual |
| `trip_assignments` | intervalos de atribuição, van/motorista anteriores e atuais, motivo e autor |
| `trip_events` | fatos operacionais imutáveis com ID de comando para repetição segura |
| `trip_incidents` | categoria, descrição, autor, horário e estado de resolução |
| `trip_incident_updates` | correção/complemento do relato sem sobrescrever o original |

`trips` é única por agenda e data de serviço. Usar referência à agenda, não somente à rota, para não colidir se horários distintos forem suportados. Todas as referências cruzadas incluem integridade de frota. Endereços completos não entram em eventos de auditoria.

Estados de viagem: `scheduled`, `confirmation_closed`, `active`, `completed`, `cancelled`. Confirmação: `pending`, `confirmed`, `declined`, `expired`. Presença: `waiting`, `boarded`, `dropped_off`, `absent`.

Participação removida por encerramento ou alteração permanece identificável no histórico, com motivo/horário, mas sai da lista executável. Não apagar o registro para representar retirada.

## Calendário e geração

A agenda semanal define o padrão. O dono marca se haverá transporte por rota/data, podendo aplicar a mesma decisão a todas as rotas da frota. Não calcular feriados automaticamente.

Marcar sem transporte cancela execuções ainda não iniciadas e produz evento para aviso aos participantes. Não cancela viagem ativa, não encerra vínculo e não libera reserva recorrente. Reativar uma data preserva o registro de cancelamento e exige atualização operacional auditada, sem duplicar execução nem restaurar confirmações silenciosamente.

Um job invocável cria as viagens do dia seguinte usando o fuso de cada agenda e as reservas vigentes. Não chama provedor de mapas. Repetir a geração não duplica dias, viagens, passageiros ou paradas. Reexecutar após falha recupera apenas o trabalho ausente, sem sobrescrever execução iniciada.

Novas aprovações e mudanças posteriores à geração reconciliam viagens ainda não iniciadas. Datas/horários usam `timestamptz` para instantes e fuso explícito para recorrência; testes incluem meia-noite e offsets diferentes. O agendador chama as mesmas funções testáveis, sem lógica de negócio exclusiva do Cron.

## Confirmações

Prazo padrão de 30 minutos antes da saída, configurável por rota. Até o prazo, adulto ou qualquer responsável ativo com acesso à frota pode confirmar/recusar. Última resposta confirmada pelo servidor prevalece; autor e horário ficam registrados. Não usar o helper de edição de aluno para excluir responsáveis secundários.

No prazo, `pending` torna-se `expired` e sai daquela execução, sem liberar vaga recorrente. Depois do prazo e antes da saída, somente dono autoriza mudança, com motivo e revisão de percurso. Não entram novos passageiros após a saída.

Início exige fechamento de confirmação consistente e lista executável definida; chamar o início após o horário não permite pular o fechamento. Viagem sem passageiros confirmados pode ser cancelada pelo operador autorizado, sem inventar embarques.

## Dois tipos de mudança

| Mudança | Vigência | Confirmação |
| --- | --- | --- |
| dias/sentidos solicitados | próximo dia de serviço em que todas as viagens afetadas ainda permitam confirmação | viagens alteradas exigem nova resposta; preserva as não afetadas |
| endereço ou escola | próxima viagem ainda não iniciada, inclusive já gerada | proposta técnica: mantém a participação confirmada quando aluno, dia e sentido permanecem iguais; não cria novo passageiro |

A segunda linha explicita a aplicação da correção do usuário: manter transporte e mudar somente o percurso. Ela não exige aprovação nem manda o aluno à fila, não altera a viagem ativa e não adia para outro dia apenas porque a confirmação fechou. Avisar o dono e atualizar a revisão operacional da próxima execução.

O recálculo deve observar a revisão de endereços, escolas e configuração, e não apenas a lista de passageiros. O Ciclo 6 implementa o cálculo; neste ciclo manter paradas/revisões e impedir início com ponto obrigatório ainda não resolvido. Na fase sem provedor, o dono define pontos e ordem manual, com indicação de ausência de ETA.

Mudança concorrente ao início usa o mesmo lock da viagem: se o início venceu, a execução ativa conserva seu snapshot e a mudança vale para a seguinte; se a edição venceu, o início valida a revisão nova. Não existe metade da viagem com um cadastro antigo e metade com o novo por corrida.

## Execução e presença

Motorista atribuído inicia e opera sua viagem; dono administra a própria frota. Estados de presença seguem `waiting → boarded → dropped_off` ou `waiting → absent`, sem marcar desembarque de quem não embarcou. Correções autorizadas preservam eventos originais e não podem criar presença incompatível com a participação.

Conclusão e cancelamento são bloqueados enquanto existir alguém `boarded`. Registrar desembarque real antes de encerrar; uma interrupção inclui ocorrência. Registrar ausência resolve passageiros esperados que não embarcaram. Não concluir com passageiros ainda aguardando sem resolução explícita da lista.

Início, substituição e encerramento exigem conexão. Cada comando repetível aceita identificador idempotente e retorna o resultado anterior apenas quando operação, autor e payload coincidirem. Colisão com outro payload é conflito, não sucesso.

`trip_events` conserva sequência autoritativa, autoria, capturado/em recebido quando aplicável e versão de atribuição. O Ciclo 4 implementa comandos online; o Ciclo 6 acrescenta recepção de lotes offline usando esse histórico. Não criar fila Flutter neste repositório.

## Substituições e proteção de recursos

Antes da saída ou em emergência durante viagem ativa, o dono troca van/motorista com motivo obrigatório. Validar papel `driver`, associação ativa, capacidade contratada e ausência de conflito de janela; não usar apenas o número de embarcados para aceitar uma van menor que a reserva.

A troca conserva a viagem, passageiros e estados e registra intervalos de atribuição. Não altera os padrões recorrentes. O novo motorista passa a operar e o anterior deixa de emitir comandos atuais. No Ciclo 6, transmissão e canais seguem a mesma troca.

Inativar van, suspender/sair/remover `driver` exige resolver atribuições futuras e viagens ativas. Uma troca válida remove o recurso antigo da atribuição atual, mas não de sua parte histórica. Checagens de recursos e início precisam de locks compartilhados com o Ciclo 3.

Uma viagem que excede a janela planejada não pode permitir início simultâneo de outra com o mesmo motorista/van. A regra real de exclusividade ativa complementa a agenda prevista.

## Ocorrências e encerramento de vínculo

Dono e motorista atribuído registram trânsito, atraso, acidente, falha mecânica, desvio ou outra ocorrência. Motorista não aguarda aprovação. Complementos/correções são append-only; resolução conserva o relato original.

Dono, principal ou adulto encerra vínculo com motivo; secundário não. Se o aluno participa de viagem ativa, rejeitar integralmente o encerramento. Caso contrário, terminar reservas futuras e retirar de execuções não iniciadas, preservando snapshots e fontes de papéis não derivadas desse vínculo. Não encerrar a associação inteira apenas porque uma matrícula terminou.

## Contratos e eventos

O plano detalhará argumentos e retornos de:

- marcar transporte por rota/data ou conjunto de rotas;
- listar operação do dia por papel;
- gerar viagens, reconciliar alterações e fechar confirmações (internos);
- confirmar/recusar e autorizar exceção pré-saída;
- iniciar/concluir/cancelar viagem;
- registrar embarque, desembarque ou ausência;
- substituir recursos;
- registrar/complementar/resolver ocorrência;
- consultar histórico permitido.

Eventos produzidos na transação servirão ao Ciclo 5: confirmação aberta/próxima do prazo, início, embarque, desembarque, chegada à escola, cancelamento, ocorrência, alteração relevante. Um evento não significa que push foi enviado.

Erros estáveis: códigos existentes mais `confirmation_closed`, `trip_active`, `passengers_on_board`, `resource_in_use`, `route_unresolved`, `stale_version` e `idempotency_conflict`. Não retornar dados de outra frota em conflito global.

## Segurança e testes

Projeções para dono/motorista apresentam somente alunos daquela operação. Responsável/adulto vê somente os seus passageiros. Não ampliar acesso direto à tabela global `students` nem usar somente o papel `guardian` para autorizar histórico.

Testar RED/GREEN, dois tenants e concorrência para:

- calendário, exceções e geração repetida/recuperação;
- prazo exato, responsável secundário, última resposta e exceção do dono;
- reconciliação das duas classes de mudança e corrida com início;
- início único, recurso já em viagem ativa e passageiro não confirmado;
- sequência de presença, duplicação e cancelamento com embarcados;
- substituição com motivo, capacidade, agenda e preservação de histórico;
- comandos antigos de suspensão/inativação/saída sem bypass;
- encerramento por papel e liberação de reservas/viagens futuras;
- ocorrências imutáveis e auditoria sem PII.

## Local → produção

Reset, testes e jobs invocáveis rodam localmente primeiro, sem esperar o relógio. Conferir migrations do zero, suíte completa, lint/advisors, grants e quality gate. Não criar staging remoto.

Publicar migrations e configurar jobs após inspeção do destino e plano de recuperação. Não rodar geração massiva ou teste destrutivo em dados reais. Verificar um fluxo controlado, unicidades e execução do Cron no ambiente publicado. Manter jobs desativados até os contratos e a configuração estarem conferidos; falha deve ser visível ao operador.

Ainda sem push e mapa: o Ciclo 4 não declara envio de notificações ou rastreamento entregue. Documentar os eventos produzidos para os ciclos dependentes.

## Referências

- Spec do Ciclo 3 e `be-tech-plan.md`, seções 6.5–6.7.
- `CONTRIBUTING.md`, testes, migrações e definição de pronto.
- [Supabase Cron](https://supabase.com/docs/guides/cron), consultado em 2026-09-07.
