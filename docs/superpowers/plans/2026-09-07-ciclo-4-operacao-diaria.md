# Ciclo 4 — Operação diária Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Operar viagens diárias com confirmação, presença, substituição, calendário e histórico consistente, publicando depois de homologar localmente.

**Architecture:** RPCs PostgreSQL aplicam transições e produzem eventos na mesma transação. Cron chama funções internas idempotentes, e as viagens usam snapshots de reservas/cadastro. Eventos alimentarão FCM no Ciclo 5; comandos de presença serão estendidos para sincronização offline no Ciclo 6.

**Tech Stack:** Supabase PostgreSQL 17, pgTAP, pg_cron, Auth/RLS e Supabase CLI.

**Spec:** `docs/superpowers/specs/2026-09-07-ciclo-4-operacao-diaria-design.md`, aprovada em 2026-09-07.

## Global Constraints

- Depende dos contratos e reservas do plano do Ciclo 3; não implementar um segundo sistema de matrícula.
- Calendário por rota/data; agenda semanal é padrão; sem cálculo automático de feriados.
- Dias desativados não chamam cálculo de percurso nem liberam reserva recorrente.
- Sem resposta até o prazo: `expired`; último adulto/responsável autorizado a responder prevalece.
- Após prazo e antes da saída, somente dono altera participação com motivo; após início, não entram passageiros novos.
- Bloquear conclusão/cancelamento com embarcado e preservar histórico de substituições/ocorrências.
- Mudança de dias/sentidos exige reconfirmação e vigência futura; cadastro vale na próxima não iniciada, conserva participação e não altera ativa.
- Início, substituição e encerramento exigem conexão.
- Dono/principal/adulto encerram vínculo, com motivo; bloquear se aluno participa de viagem ativa.
- Sem código Flutter, FCM, GPS ou provedor de mapas neste ciclo. Ordem manual e pontos válidos permitem a operação inicial.
- Migrations novas via CLI; TDD estrito; local → produção, sem staging remoto nem reset/seed remoto.
- Não declarar avisos entregues só por gravar eventos. Sem commit/push automático.

## Arquivos e interfaces

| Arquivo | Responsabilidade |
| --- | --- |
| migrations `cycle_4_calendar`, `cycle_4_generation`, `cycle_4_confirmations`, `cycle_4_presence`, `cycle_4_substitutions`, `cycle_4_incidents`, `cycle_4_reconciliation`, `cycle_4_jobs` | fatias transacionais |
| `supabase/tests/_operations.psql` | fixture que consome `_planning.psql` |
| `supabase/tests/database/024_calendar.test.sql` a `031_operation_jobs.test.sql` | testes por task |
| `supabase/tests/concurrency/operations.py` | corridas sobre início, edição e atribuições |
| `supabase/tests/concurrency/operations_setup.psql`, `operations_cleanup.psql` | fixtures exclusivas locais |
| `docs/operations/ciclo-4-production.md` | implantação e recuperação de jobs |

Todo teste SQL usa `begin`, pgTAP, `\ir ../_helpers.psql`, `\ir ../_planning.psql`, `\ir ../_operations.psql`, plano de assertions, `finish()` e `rollback`. `_operations.psql` fica fora da descoberta `.sql` da CLI.

Fixture `pg_temp.seed_cycle_4() returns void`: chama `pg_temp.seed_cycle_3()`, usa agendas válidas em setembro de 2026, aprova uma ida e uma volta, chama geração para `2026-09-14` e grava IDs em `operation_ids(kind text primary key,id uuid)`: `going`, `return`, `passenger`, `school-stop`, `home-stop`. IDs são capturados dos retornos, não assumidos. Horários de teste são instantes UTC explícitos.

Helpers internos deste ciclo:

```sql
private.generate_trips(p_service_date date, p_now timestamptz) returns integer
private.close_confirmations(p_now timestamptz) returns integer
private.reconcile_enrollment_trips(p_enrollment_id uuid, p_kind text,
  p_effective_on date, p_now timestamptz) returns integer
private.append_trip_event(p_trip_id uuid, p_command_id uuid, p_kind text,
  p_payload jsonb, p_occurred_at timestamptz) returns bigint
private.assert_trip_ready(p_trip_id uuid) returns void
private.run_daily_operations(p_now timestamptz) returns void
```

`p_kind` da reconciliação é `schedule|address|school|ended`. O registro de eventos inclui autor de `auth.uid()` ou autor interno nulo, horário recebido, sequência por viagem, hash do payload e resultado. `command_id` único dentro da viagem; mesmo ID/tipo/autor/payload retorna mesmo resultado, payload diferente gera `idempotency_conflict`.

## Task 1: Calendário e estrutura da execução

**Files:** Create `024_calendar.test.sql`, migration `cycle_4_calendar`, `_operations.psql` inicial; Inspect entrega real do Ciclo 3.

**Interfaces:** Produces:

```sql
public.set_service_enabled(p_fleet_id uuid, p_route_ids uuid[],
  p_service_date date, p_enabled boolean, p_reason text) returns integer
```

Array NULL significa todas as rotas autorizadas da frota; array vazio é inválido; nenhuma rota pode pertencer a outro tenant.

- [ ] **Step 1 — Revalidar baseline e criar RED.**

```bash
git status --short
supabase status
supabase db reset --local
supabase test db
```

No teste novo:

```sql
select has_table('public','route_service_exceptions','exceção por rota/data');
select has_table('public','trips','execução possui identidade própria');
```

Run: `supabase test db supabase/tests/database/024_calendar.test.sql`; FAIL por ausência das tabelas.

- [ ] **Step 2 — Criar schema com identidade e RLS.**

Run: `supabase migration new cycle_4_calendar`. Criar:

```text
route_service_exceptions(fleet_id,route_id,service_date,enabled,reason,updated_by,updated_at)
service_days(id,fleet_id,service_date)
trips(id,fleet_id,service_day_id,route_id,schedule_id,service_date,
      planned_start_at,reserved_until,confirmation_deadline,status,
      van_id,driver_user_id,started_at,ended_at,revision,event_sequence)
```

Unicidades `(route_id,service_date)`, `(fleet_id,service_date)` e `(schedule_id,service_date)`. Estados de `trips`: `scheduled|confirmation_closed|active|completed|cancelled`; FKs compostas com tenant, timestamps reais coerentes. Reservar campos de revisão operacional usados de imediato, sem criar coluna GPS antecipada.

RPC owner usa lock de planejamento, atualiza exceções e cancela somente viagens não iniciadas. Uma viagem ativa conserva sua execução. Nesta task, registrar alterações em `audit_events`, que já existe. Reativação não duplica a chave e só devolve uma cancelada ao planejamento se nunca iniciou. Tasks 2–3 ampliam o mesmo comando para produzir `trip_events` e resetar confirmações após a criação dessas tabelas, sem referenciar uma tabela futura nesta migration.

- [ ] **Step 3 — GREEN e casos por rota/frota.**

```bash
supabase db reset --local
supabase test db supabase/tests/database/024_calendar.test.sql
```

Testar rota específica, todas as rotas, referência de outro tenant, repetição idempotente e preservação das reservas recorrentes. Nas tasks seguintes ampliar para viagem ativa e confirmação restaurada indevidamente.

## Task 2: Geração idempotente e snapshots

**Files:** Create `025_generation.test.sql`, migration `cycle_4_generation`; Modify `_operations.psql`.

**Interfaces:** Consumes agendas/reservas; Produces `generate_trips`, passageiros, paradas, atribuições e eventos.

- [ ] **Step 1 — RED de repetição.**

```sql
select lives_ok($$select private.generate_trips('2026-09-14','2026-09-13 12:00+00')$$,
  'gera dia seguinte sem provedor');
select is(private.generate_trips('2026-09-14','2026-09-13 12:01+00'),0,
  'segunda geração não cria outra execução');
```

Run: `supabase test db supabase/tests/database/025_generation.test.sql`.

- [ ] **Step 2 — Implementar materialização e ledger.**

Criar `trip_passengers(id,fleet_id,trip_id,enrollment_id,student_id,confirmation_status,operation_status,confirmation_by,confirmation_at,removed_at,removal_reason)`, `trip_stops(id,fleet_id,trip_id,kind,student_id,school_id,position,address_snapshot,latitude,longitude,reached_at)`, `trip_assignments(id,fleet_id,trip_id,van_id,driver_user_id,valid_from,valid_until,reason,actor_user_id)` e `trip_events(id bigint identity,fleet_id,trip_id,command_id,event_sequence,kind,actor_user_id,occurred_at,received_at,payload,payload_hash,result)`.

```sql
insert into public.service_days(fleet_id,service_date)
values (v_fleet_id,p_service_date)
on conflict (fleet_id,service_date) do nothing;
```

Copiar apenas reservas vigentes/não canceladas, estado `pending/waiting`, escola vigente e endereço atual para snapshots privados. Instituições na ordem da rota; residências em ordem manual determinística inicial, marcada como não otimizada. Sem coordenadas obrigatórias resolvidas, viagem não pode iniciar; geração ainda deve ocorrer.

Transação por geração mantém dia/viagem/passagem coerentes; repetição não sobrescreve evento, parada de viagem iniciada ou confirmação existente. `append_trip_event` bloqueia viagem, verifica repetição e incrementa sequência atomicamente.

Ampliar `set_service_enabled` nesta migration para registrar cancelamento/reativação em `trip_events`; a Task 3 acrescenta invalidação explícita das confirmações na reativação. Cada extensão usa nova definição completa da RPC e conserva validações anteriores.

- [ ] **Step 3 — GREEN e snapshot real.**

```bash
supabase db reset --local
supabase test db supabase/tests/database/025_generation.test.sql
```

Testar duas agendas na mesma rota, ida e volta independentes, exceção sem transporte, fuso, matrícula encerrada e alteração do cadastro depois de viagem concluída sem mudar snapshot. Usar contagem de eventos para provar que repetição não gera aviso duplicado.

## Task 3: Confirmações, fechamento e exceção pré-saída

**Files:** Create `026_confirmations.test.sql`, migration `cycle_4_confirmations`.

**Interfaces:** Produces:

```sql
public.respond_trip(p_trip_id uuid,p_student_id uuid,p_confirm boolean,
  p_command_id uuid) returns text
public.override_trip_participation(p_trip_id uuid,p_student_id uuid,
  p_confirm boolean,p_reason text,p_command_id uuid) returns text
```

- [ ] **Step 1 — RED com responsável secundário e relógio explícito.**

```sql
select has_function('public','respond_trip',array['uuid','uuid','boolean','uuid'],
  'confirmação pertence a participantes autorizados');
select is(private.close_confirmations('2026-09-14 10:30+00'),1,
  'fecha somente a ida que venceu');
```

Fixture define ida às 08:00 America/Sao_Paulo, prazo 07:30 e volta 16:00. Usar helper interno com relógio controlável para os testes de limite; RPC pública usa `clock_timestamp()`, nunca aceita relógio arbitrário do cliente.

- [ ] **Step 2 — Implementar estados e permissões.**

Adulto próprio ou responsável ativo com associação elegível confirma até o prazo (`now < deadline`); no limite, tratar como fechado. Atualizar confirmação e evento juntos. Fechamento converte apenas pendentes:

```sql
update public.trip_passengers p set confirmation_status='expired'
where p.trip_id=v_trip_id and p.confirmation_status='pending'
  and p.removed_at is null;
```

Passar viagem para `confirmation_closed`. Override exige owner/motivo, viagem ainda não iniciada e passageiro com reserva; não é inserção livre de aluno sem vaga. Atualizar revisão do percurso. Após início, rejeitar ambos para inclusão/mudança de participação.

Na reativação de serviço nunca iniciado, atualizar confirmações para `pending` se prazo ainda aberto ou `expired` se já fechou, preservando respostas antigas em eventos. Não transformar cancelamento em confirmação automática; mudanças tardias seguem override do dono.

- [ ] **Step 3 — GREEN e testes de autoria.**

```bash
supabase db reset --local
supabase test db supabase/tests/database/026_confirmations.test.sql
```

Testar último responsável a responder, replay sem reordenar resposta mais nova, e-mail/papel inválido, deadline exato, owner após fechamento, motorista sem poder de override e ausência sem perda da reserva contratada.

## Task 4: Percurso manual, início, presença e encerramento

**Files:** Create `027_presence.test.sql`, migration `cycle_4_presence`.

**Interfaces:** Produces:

```sql
public.set_trip_stop(p_stop_id uuid,p_latitude numeric,p_longitude numeric,
  p_label text,p_expected_revision bigint) returns bigint
public.order_trip_stops(p_trip_id uuid,p_stop_ids uuid[],
  p_expected_revision bigint,p_reason text) returns bigint
public.start_trip(p_trip_id uuid,p_command_id uuid) returns text
public.record_passenger_event(p_trip_id uuid,p_student_id uuid,p_kind text,
  p_command_id uuid) returns text
public.finish_trip(p_trip_id uuid,p_cancel boolean,p_reason text,
  p_command_id uuid) returns text
public.mark_trip_stop_reached(p_stop_id uuid,p_command_id uuid) returns void
```

`p_kind`: `boarded|dropped_off|absent`; clientes não escrevem `waiting` para apagar histórico. Alterar coordenada exige owner e viagem não iniciada; reordenar antes do início exige owner, durante viagem permite motorista atribuído entre paradas ainda autorizadas, conservando ordem de escolas e paradas realizadas.

- [ ] **Step 1 — RED de conclusão com embarcado.**

```sql
select throws_ok(
 $$select public.finish_trip((select id from operation_ids where kind='going'),
 false,null,'74000000-0000-0000-0000-000000000001')$$,
 'PGRST',null,'não conclui com passageiro a bordo');
```

Preparar fixture com viagem ativa e um `boarded` usando commands válidos conforme forem implementados. Run: `supabase test db supabase/tests/database/027_presence.test.sql`.

- [ ] **Step 2 — Implementar máquina de estados.**

```text
scheduled -> confirmation_closed -> active -> completed
scheduled|confirmation_closed -> cancelled
active -> cancelled somente com lista resolvida, ninguém boarded e ocorrência
waiting -> boarded -> dropped_off
waiting -> absent
```

`assert_trip_ready`: recursos ativos, sem outra viagem ativa do mesmo motorista/van, confirmação fechada, paradas necessárias resolvidas, escola/ordem coerentes e revisão atual. Início chama fechamento vencido de modo seguro ou rejeita início antecipado enquanto prazo está aberto. Não buscar provider no início.

Passageiro só embarca se confirmado e não removido. Conclusão exige lista resolvida; presença inválida dá `invalid_transition`. Nesta task, cancelamento ativo permanece rejeitado com `incident_required`; a Task 6 o habilita depois de criar ocorrências, conservando as travas de presença/motivo. Cancelamento pré-saída já funciona. Eventos `trip_started`, `student_boarded`, `student_dropped_off`, `student_absent`, `school_reached`, `trip_completed`, `trip_cancelled` produzem histórico; snapshots não são editáveis diretamente.

- [ ] **Step 3 — GREEN com replay.**

```bash
supabase db reset --local
supabase test db supabase/tests/database/027_presence.test.sql
```

Testar replay mesmo comando/resultado, ID reaproveitado com payload diverso, desembarque sem embarque, motorista não atribuído, no-show, van ainda ativa em viagem atrasada e ponto inválido. Não permitir que owner altere presença diretamente na tabela para contornar regras.

## Task 5: Substituição e bloqueios nos comandos existentes

**Files:** Create `028_substitutions.test.sql`, migration `cycle_4_substitutions`.

**Interfaces:** Produces `public.substitute_trip_resources(p_trip_id uuid,p_van_id uuid,p_driver_user_id uuid,p_reason text,p_command_id uuid) returns uuid` (nova atribuição). Ampliar `assert_driver_releasable` e `assert_van_releasable` do Ciclo 3.

- [ ] **Step 1 — RED de troca preservando passageiros.**

```sql
select has_function('public','substitute_trip_resources',
 array['uuid','uuid','uuid','text','uuid'],'troca emergencial mantém viagem');
```

Run: `supabase test db supabase/tests/database/028_substitutions.test.sql`.

- [ ] **Step 2 — Implementar transação owner-only.** Adquirir lock de planejamento antes de viagem; validar recursos, capacidade contratada, agenda e exclusividade ativa, motivo não vazio. Fechar atribuição anterior e criar nova no mesmo instante:

```sql
update public.trip_assignments set valid_until=v_now
where trip_id=p_trip_id and valid_until is null;
update public.trips set van_id=p_van_id,driver_user_id=p_driver_user_id,
revision=revision+1 where id=p_trip_id;
```

Não modificar `trip_passengers`, `routes` ou presença para simular troca. Guardas de inativação/suspensão/remoção/left agora buscam viagens ativas e futuras, incluindo agendadas após o fim da recorrência. Usar histórico antigo só para leitura, não como atribuição atual.

- [ ] **Step 3 — GREEN e negativa de suspensão.** Testar tentativa de suspender ativo sem mudança de papéis/GPS futuro, troca válida permitindo liberar recurso antigo, van menor rejeitada, driver sem papel, outra frota, motivo vazio e papel owner sem driver.

```bash
supabase db reset --local
supabase test db supabase/tests/database/028_substitutions.test.sql
```

## Task 6: Ocorrências e consultas por papel

**Files:** Create `029_incidents.test.sql`, migration `cycle_4_incidents`.

**Interfaces:** Produces:

```sql
public.report_trip_incident(p_trip_id uuid,p_category text,p_description text,
  p_command_id uuid) returns uuid
public.update_trip_incident(p_incident_id uuid,p_note text,p_resolved boolean,
  p_command_id uuid) returns uuid
public.get_trip(p_trip_id uuid) returns jsonb
public.list_service_day(p_fleet_id uuid,p_service_date date) returns jsonb
```

- [ ] **Step 1 — RED de imutabilidade.**

```sql
select has_table('public','trip_incident_updates','correções preservam relato');
select ok(not has_table_privilege('authenticated','public.trip_events','DELETE'),
 'cliente não apaga evento');
```

Run: `supabase test db supabase/tests/database/029_incidents.test.sql`.

- [ ] **Step 2 — Implementar ocorrências.** Criar `trip_incidents(id,fleet_id,trip_id,category,description,actor_user_id,created_at,resolved_at)` e complementos `(id,fleet_id,incident_id,note,resolved,actor_user_id,created_at,command_id)`. Categorias `traffic|delay|accident|mechanical|detour|other`; validar textos com até 2000 caracteres. Motorista atribuído registra sem aprovação. Complementos append-only; resolução atualiza resumo, nunca substitui descrição original.

Consultas constroem JSON explícito: `trip`, `passengers`, `stops`, `incidents`, `events`, `revision`. Owner/driver autorizado recebe operação; responsável/adulto somente próprio aluno/ponto, sem endereços ou identidades de terceiros. Feed de frota é owner-only; driver consulta apenas execuções atribuídas.

Ampliar `finish_trip` para permitir cancelamento ativo somente quando houver ocorrência, motivo e lista resolvida sem embarcados. Retestar a negação e o aceite após ocorrência; a presença não é alterada para forçar cancelamento.

- [ ] **Step 3 — GREEN e dois tenants.**

```bash
supabase db reset --local
supabase test db supabase/tests/database/029_incidents.test.sql
```

Testar relato por motorista, tentativa de apagar/reescrever, complemento repetido, owner de outra frota e UUID de passageiro alheio nas projeções.

## Task 7: Reconciliação, vigência e encerramento de transporte

**Files:** Create `030_reconciliation.test.sql`, migration `cycle_4_reconciliation`; Modify corpos novos de comandos C3 em migration, sem editar migrations aplicadas.

**Interfaces:** Consumes `reconcile_enrollment_trips`, revisões C3 e `next_change_date`; Produces reconciliação dentro da aprovação/edição/encerramento, com locks comuns ao início.

- [ ] **Step 1 — RED de mudança cadastral sem tocar ativa.**

```sql
select lives_ok($$select private.reconcile_enrollment_trips(
 (select enrollment_id from public.trip_passengers limit 1),
 'address','2026-09-14','2026-09-14 11:05+00')$$,
 'endereço reconcilia somente próximas execuções');
```

Fixture: ida ativa e volta não iniciada com aluno confirmado. Esperar endereço antigo na ida, novo na volta e confirmação da volta preservada. Run: `supabase test db supabase/tests/database/030_reconciliation.test.sql`.

- [ ] **Step 2 — Implementar por classe de mudança.**

```sql
select id from public.trips
where id in (select trip_id from public.trip_passengers where enrollment_id=p_enrollment_id)
  and status in ('scheduled','confirmation_closed')
order by id for update;
```

`schedule`: determinar primeira data após hoje com todos prazos aplicáveis abertos; atualizar somente desde essa data, invalidar confirmação apenas das viagens alteradas. `address|school`: atualizar próximas não iniciadas, mesmo `confirmation_closed`, preservar participação, incrementar revisão e produzir evento para aviso; nunca mudar ativa/concluída. `ended`: bloquear se aluno participa de ativa, senão marcar remoção em futuras e terminar reservas/fontes na mesma transação.

Integrar no final dos comandos C3 antes do commit, não num job eventual que possa deixar viagem com ponto antigo. Lock global de planejamento seguido de viagens por UUID evita corrida com início; quando edição chega depois do início, preserva ativa e aplica à seguinte.

- [ ] **Step 3 — GREEN e concorrência.**

```bash
supabase db reset --local
supabase test db supabase/tests/database/030_reconciliation.test.sql
python3 supabase/tests/concurrency/operations.py
```

Implementar harness de duas sessões local, barreira por marcador como especificado no plano C3. Casos: início×cadastro, início×encerramento de vínculo, dois inícios do mesmo recurso, substituição×suspensão. Assert final: nenhum recurso duplicado ativo, nenhuma viagem ativa parcialmente reescrita. Cleanup só IDs de fixture, em `finally`.

## Task 8: Jobs idempotentes e publicação

**Files:** Create `031_operation_jobs.test.sql`, migration `cycle_4_jobs`, `docs/operations/ciclo-4-production.md`; Modify docs de estado após execução.

**Interfaces:** `run_daily_operations(p_now)` identifica amanhã em cada fuso, chama geração e fecha prazos vencidos. PostgreSQL Cron chama com relógio do servidor; authenticated não pode executar helper interno.

- [ ] **Step 1 — RED do job repetido e grants.**

```sql
select lives_ok($$select private.run_daily_operations('2026-09-13 23:59+00')$$,
 'job executável sem esperar relógio');
select lives_ok($$select private.run_daily_operations('2026-09-13 23:59+00')$$,
 'job repetido preserva unicidades');
```

- [ ] **Step 2 — Implementar função e registrar job.** Após validar suporte local, migration habilita `pg_cron` e registra nome estável. Job a cada minuto trata prazos; geração verifica se amanhã já está materializado. Não procurar feriados externos.

```sql
select cron.schedule('vango-daily-operations','* * * * *',
  $$select private.run_daily_operations(clock_timestamp());$$);
select cron.alter_job(
 (select jobid from cron.job where jobname='vango-daily-operations'),active:=false);
```

Instalação repetida não deve criar jobs duplicados: consultar `cron.job` por nome e atualizar/remover a versão anterior antes de agendar. O job nasce desativado; ativação explícita ocorre só após conferência local ou pós-publicação usando `cron.alter_job(jobid,active:=true)`, com assinatura verificada no ambiente. Testes invocam helper diretamente; inspeção do Cron é complementar. Registrar sucesso/falha sem payload privado.

- [ ] **Step 3 — Gate local e contrato publicado.**

```bash
supabase db reset --local
supabase test db
supabase db lint --local --schema public,private --fail-on error
supabase db advisors --local --type all --level warn --fail-on error
git diff --check
git status --short
```

Quality gate somente leitura. Em runbook: backup/recuperação, inspeção destino, migrations pendentes, horário de ativação do job, queries de saúde e versão cliente. Desativar execução do job durante conferência do rollout se houver dados operacionais; reativar somente com contratos verificados.

- [ ] **Step 4 — Publicar e verificar sem staging remoto.**

```bash
: "${SUPABASE_PROJECT_REF:?Projeto de produção verificado}"
supabase link --project-ref "$SUPABASE_PROJECT_REF"
supabase db push --linked --dry-run
supabase db push --linked
supabase migration list --linked
```

Verificar job único, permissões, geração sem duplicata e um fluxo controlado confirmação→início→embarque→desembarque→conclusão. Se falhar, suspender job afetado sem apagar viagens e aplicar correção versionada. Documentar local/publicado/smoke separadamente em `deliverables.md`; não registrar push/GPS como entregues.

## Cobertura

| Requisito | Task |
| --- | --- |
| calendário e exceções | 1, 8 |
| geração/snapshots | 2, 7 |
| confirmação/prazos | 3 |
| presença/estados/ordem manual | 4 |
| substituições e proteção de recursos | 5, 7 |
| ocorrências/projeções/histórico | 6 |
| duas vigências e encerramento | 7 |
| Cron, RLS e local → produção | 1–8 |

Referências: [Cron](https://supabase.com/docs/guides/cron) e [CLI](https://supabase.com/docs/reference/cli/supabase-db-push). Conferir `--help` antes de executar os comandos na versão instalada.

## Registro de execução

Backend validado na release integrada em 2026-09-08: 850 assertions pgTAP, 45 testes Deno, 14 disputas PostgreSQL e WebSocket real. Evidência consolidada, publicação e pendências externas em [deliverables.md](../../../deliverables.md) e no runbook do ciclo. Os checklists acima descrevem a sequência de trabalho, não comprovam ativação de serviços externos.
