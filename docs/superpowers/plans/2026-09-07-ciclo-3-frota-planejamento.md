# Ciclo 3 — Frota e planejamento Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Garantir vagas na aprovação de transporte, com frota, agendas, fila por antiguidade, alterações e publicação validada primeiro localmente.

**Architecture:** PostgreSQL/RPC concentra reservas e transições; Data API expõe somente leituras autorizadas. Reutilizar Auth, fontes de papéis, helpers privados e auditoria dos Ciclos 1–2. Toda evolução usa migrations novas e preserva histórico.

**Tech Stack:** Supabase Auth, PostgreSQL 17, PL/pgSQL, RLS, pgTAP, Supabase CLI, Python stdlib/psql para concorrência local.

**Spec:** `docs/superpowers/specs/2026-09-07-ciclo-3-frota-planejamento-design.md`, aprovada em 2026-09-07.

## Global Constraints

- A aprovação reserva todos os dias e sentidos na mesma transação; não existe aprovação parcial.
- `pending` e `waitlisted`, pedidos novos e alterações, disputam a mesma fila por `created_at, id`.
- Entre pedidos integralmente compatíveis, prevalece o mais antigo; dono aceita ou recusa.
- Convite de transporte aceito cria pedido pendente, sem matrícula nem reserva.
- Até três preferências de van, informativas; dias, sentidos, escola e turno são obrigatórios.
- Capacidade por execução, sem reutilização por trecho ou faltas ocasionais.
- Papel `driver` explícito, inclusive para dono; convite por mesmo e-mail confirmado.
- Placa única entre cadastros ativos globais; bloqueio de inativação/saída/suspensão/remoção de papel com atribuições.
- Dias/sentidos mudam por aprovação e vigência; endereço/escola preservam transporte e sinalizam revisão.
- Não criar viagens, GPS, Edge Functions, push, importador nem código Flutter neste ciclo.
- Local é homologação; publicar somente após validação local, sem staging remoto, reset remoto ou seed fictício em produção.
- Criar migrations via `supabase migration new`; a saída da CLI determina o caminho exato. Nomes abaixo são sufixos, nunca timestamps inventados.
- RED → GREEN → refactor por comportamento; não escrever toda a suíte vermelha antes de implementar.
- Não alterar `package.json`, lockfiles ou `.gitignore` preexistentes sem necessidade comprovada. Não acrescentar servidor Node.js.
- Commit/push só com autorização explícita; registrar resultados em `deliverables.md` apenas após execução real.

## Baseline, arquivos e contratos comuns

Baseline observado: commit `0756869` implementa Ciclo 2; `5b10dfc` acrescenta pesquisa. A CLI não estava no PATH na elaboração deste plano; a instalação registrada historicamente não é prova de disponibilidade atual.

| Arquivo novo ou existente | Responsabilidade |
| --- | --- |
| migrations com sufixos `cycle_3_vans`, `cycle_3_drivers`, `cycle_3_routes`, `cycle_3_reservations`, `cycle_3_queue`, `cycle_3_schedule_changes`, `cycle_3_projections` | uma fatia de domínio por migration |
| `supabase/tests/_planning.psql` | fixtures transacionais do ciclo |
| `supabase/tests/database/017_vans.test.sql` a `023_planning_privacy.test.sql` | contratos abaixo |
| `supabase/tests/concurrency/planning.py` | duas conexões reais, teste exclusivamente local |
| `supabase/tests/concurrency/planning_setup.psql` e `planning_cleanup.psql` | dados fictícios exclusivos do teste de concorrência |
| `docs/operations/ciclo-3-production.md` | preflight, publicação, recuperação e evidências reais |
| `README.md`, `be-tech-plan.md`, `deliverables.md` | estado e contratos entregues |

Helpers existentes a reutilizar: `private.raise_api_error(text,text,integer)`, `private.has_fleet_role(uuid,uuid,text)`, `private.current_user_email_confirmed()`, `private.ensure_enrollment_membership(uuid,uuid,text,uuid)` e mecanismos de fontes de papéis.

Novos helpers privados:

```sql
private.lock_planning() returns void
private.validate_schedule(p_schedule jsonb) returns void
private.schedule_windows(p_schedule_id uuid, p_from date, p_until date)
  returns table(service_date date, window tstzrange)
private.find_request_allocation(p_request_id uuid, p_effective_on date)
  returns jsonb
private.apply_request_allocation(p_request_id uuid, p_allocations jsonb,
  p_effective_on date) returns uuid
private.assert_driver_releasable(p_fleet_id uuid, p_user_id uuid) returns void
private.assert_van_releasable(p_van_id uuid) returns void
```

`find_request_allocation` retorna array de `{schedule_id: uuid, weekday: integer}` com atendimento completo, ou SQL NULL; não grava nem escolhe prioridade. `apply_request_allocation` consome o conjunto já validado e retorna vínculo, novo ou existente. Helpers não são endpoints da Data API.

Controle de concorrência mínimo: todos os comandos que alteram planejamento adquirem `private.lock_planning()` primeiro; depois locks de frotas/recursos/solicitações em ordem de UUID. Implementar com advisory lock transacional único:

```sql
select pg_advisory_xact_lock(71303, 1);
-- ponytail: serializa alterações de planejamento entre frotas;
-- trocar por locks ordenados por recurso se a contenção medida exigir.
```

O mesmo lock deve anteceder os locks atuais nos comandos legados afetados, inclusive aceite de convite e criação/encerramento de vínculo. Leituras comuns não adquirem esse lock. Essa escolha prioriza correção para o MVP; não declarar escalabilidade ilimitada.

Agendas têm `valid_from` e `valid_until` inclusivos e finitos, tornando a validação exaustiva por datas implementável. Não usar um horizonte de 30 dias para aprovar uma recorrência além dele. `ends_next_day` distingue fim no dia seguinte. A janela inclui margem/deslocamento e usa limites `[)`.

## Task 1: Revalidar ambiente e entregar vans isoladas

**Files:** Inspect `supabase/config.toml`, migrations dos Ciclos 0–2 e `CONTRIBUTING.md`; Create `017_vans.test.sql`, `_planning.psql` e migration `cycle_3_vans`.

**Interfaces:** Consumes `fleets`, perfis/papéis; Produces:

```sql
public.save_van(p_fleet_id uuid, p_van_id uuid, p_plate text,
  p_model text, p_public_name text, p_capacity integer) returns uuid
public.deactivate_van(p_van_id uuid, p_reason text) returns text
```

`p_van_id` NULL cria; existente edita. Placa normalizada remove espaços/hífens e usa uppercase, validando padrão brasileiro antigo ou Mercosul. Não aceitar string vazia, capacidade menor que 1 ou maior que 100, modelo/nome vazios. O limite técnico 100 evita valores absurdos; capacidade normal continua configurável perto de 30.

- [ ] **Step 1 — Conferir ambiente sem instalar dependências no repo.**

```bash
git status --short --branch
command -v supabase
supabase --version
supabase test db --help
supabase db reset --help
supabase migration new --help
supabase db push --help
```

Se faltar CLI/Docker, restaurar a ferramenta de desenvolvimento fora do projeto antes da implementação. Não inferir que o npm instalado pelo usuário é a CLI. Depois executar `supabase status`, `supabase db reset --local` e `supabase test db`. Baseline esperado: 17 arquivos/176 testes segundo entrega anterior; divergência precisa ser explicada, não ocultada.

- [ ] **Step 2 — Escrever o primeiro RED em `017_vans.test.sql`.**

```sql
begin;
create extension if not exists pgtap with schema extensions;
\ir ../_helpers.psql
select plan(1);
select has_table('public', 'vans', 'vans existe');
select * from finish();
rollback;
```

Run: `supabase test db supabase/tests/database/017_vans.test.sql`. Esperado: FAIL por tabela ausente, não por erro de conexão.

- [ ] **Step 3 — Gerar migration e implementar schema mínimo.**

Run: `supabase migration new cycle_3_vans`. Na migration, criar `vans(id uuid PK, fleet_id uuid FK, plate text, model text, public_name text, capacity integer, status text, created_at, updated_at, deactivated_at)`; status `active|inactive`. Declarar `unique(id,fleet_id)`, RLS, FKs `restrict`, grants de SELECT restritos e nenhum DML direto. Núcleo:

```sql
create unique index vans_active_plate_key on public.vans(plate)
where status = 'active';
alter table public.vans enable row level security;
revoke all on public.vans from anon, authenticated;
```

Implementar RPCs com owner, e-mail confirmado, lock de planejamento, motivo e auditoria; a trava de referências será ampliada na Task 3. SQLSTATE `PGRST` com `plate_conflict`, sem identificar outra frota.

- [ ] **Step 4 — GREEN e próximos REDs, um por vez.**

```bash
supabase db reset --local
supabase test db supabase/tests/database/017_vans.test.sql
```

Acrescentar sucessivamente: criar como owner, anonimato negado, outro tenant negado, placa duplicada normalizada, capacidade inválida e edição sem privilégio. Usar `pg_temp.seed_foundation()` e JWT `40000000-0000-0000-0000-000000000001` para owner A; repetir criação na frota B prova unicidade global.

## Task 2: Convites de motorista e comandos de associação

**Files:** Create `018_drivers.test.sql`, migration `cycle_3_drivers`; Modify `_planning.psql`. Ler migrations `20260906201646` e `20260906211805`, sem editá-las.

**Interfaces:** Consumes convites/fontes; Produces `public.accept_driver_invitation(p_token text) returns uuid` (membership). `create_fleet_invitation(uuid,text,text)` passa a aceitar `driver`. Decline/cancel/get mantêm contratos.

- [ ] **Step 1 — RED do aceite sem aluno.** Acrescentar fixture transacional com owner A e destinatário confirmado criado via helper existente. Guardar token em tabela temporária, nunca em log.

```sql
select has_function('public', 'accept_driver_invitation', array['text'],
  'aceite de equipe não exige aluno');
select throws_ok(
  $$select public.accept_driver_invitation('token-inexistente')$$,
  'PGRST', null, 'token inválido não concede papel');
```

Run: `supabase test db supabase/tests/database/018_drivers.test.sql`; primeiro falha por função inexistente.

- [ ] **Step 2 — Implementar aceite na migration nova.**

```sql
alter table public.fleet_invitations
drop constraint fleet_invitations_role_valid;
alter table public.fleet_invitations add constraint fleet_invitations_role_valid
check (role in ('guardian','student','driver'));
```

Reutilizar SHA-256, expiração de 14 dias e e-mail confirmado. Aceite exige convite `driver`, cria/reativa associação sem reativar suspensa, acrescenta fonte `manual` e sincroniza papéis efetivos pelo mecanismo existente. Não chamar aceite de transporte, não inserir aluno/pedido/vínculo. Convite expirado persiste estado e retorna NULL, coerente com aceite existente.

- [ ] **Step 3 — GREEN, depois matriz negativa.**

```bash
supabase db reset --local
supabase test db supabase/tests/database/018_drivers.test.sql
```

Testar e-mail diferente, não confirmado, aceite repetido, convite guardian no endpoint driver, associação suspensa, preservação de owner. Conferir que contagens de `students`, `fleet_join_requests` e `fleet_enrollments` não mudam. Incluir controle de último owner nos comandos legados.

## Task 3: Rotas, escolas, agendas e conflitos

**Files:** Create `019_routes.test.sql`, migration `cycle_3_routes`; Modify `_planning.psql`.

**Interfaces:** Consumes vans/driver; Produces:

```sql
public.save_route(p_fleet_id uuid, p_route_id uuid, p_config jsonb) returns uuid
public.save_route_schedule(p_route_id uuid, p_schedule_id uuid,
  p_schedule jsonb) returns uuid
public.set_route_status(p_route_id uuid, p_status text, p_reason text) returns text
```

`p_config`: `name:text`, `direction:going|return`, `shift:morning|afternoon|evening|full_time`, `paired_route_id:uuid|null`, `van_id:uuid`, `driver_user_id:uuid`, `proximity_minutes:int` (1–60, default 10), `origin:{latitude:number,longitude:number,label:text}`, `destination` com mesma forma, `schools:[{school_id:uuid,position:int}]`. `p_schedule`: `weekdays:int[]` distintos 1–7, `starts_at:HH:MM`, `ends_at:HH:MM`, `ends_next_day:boolean`, `timezone:text`, `valid_from:date`, `valid_until:date`, `confirmation_minutes:int` 0–1440. Validar chaves/tipos e rejeitar referências incompatíveis.

- [ ] **Step 1 — RED da janela de agenda.**

```sql
select has_function('private','schedule_windows',array['uuid','date','date'],
  'agenda produz intervalos com fuso');
select throws_ok(
  $$select private.validate_schedule('{"weekdays":[8]}'::jsonb)$$,
  'PGRST', null, 'dia inválido rejeitado');
```

Run: `supabase test db supabase/tests/database/019_routes.test.sql`.

- [ ] **Step 2 — Gerar migration e implementar modelo/algoritmo.**

Criar `routes` conforme config, `route_schools(route_id,fleet_id,school_id,position)` e `route_schedules(id,route_id,fleet_id,weekdays,starts_at,ends_at,ends_next_day,timezone,valid_from,valid_until,confirmation_minutes,status)`. FKs compostas garantem tenant. Par exige sentido oposto na mesma frota; escola exige catálogo ativo. `status` é `active|inactive`.

Gerar instantes para cada data real na interseção finita das vigências. Para cada dia `d`, usar:

```sql
tstzrange(
  (d::date + starts_at) at time zone timezone,
  ((d::date + case when ends_next_day then 1 else 0 end) + ends_at)
    at time zone timezone,
  '[)'
)
```

Rejeitar fim não posterior ao início. Comparar sobreposição `&&` de janelas reais, incluindo datas adjacentes por cruzamento de meia-noite. Motorista é global por `profiles.id`, van por ID/placa ativa; não revelar outra frota. Fim já inclui margem, sem adicionar intervalo global.

`assert_driver_releasable` procura agendas/rotas futuras; `assert_van_releasable` faz equivalente. Recriar os corpos de `set_fleet_member_roles` e `set_fleet_membership_status` em migration nova, chamando guardas antes de remover `driver`, suspender ou sair; conservar toda lógica de fontes e último owner.

- [ ] **Step 3 — GREEN e casos de fronteira.**

```bash
supabase db reset --local
supabase test db supabase/tests/database/019_routes.test.sql
```

Testar `[08:00,09:00)` versus `[09:00,10:00)` permitido; início 08:59 conflita; dois fusos, meia-noite, segunda/terça, vigências sem interseção e motorista em frota B. Testar inativação de van e remoção de driver atribuídos: falha sem alterar estado. Alterar capacidade não pode quebrar reserva a partir da Task 4.

## Task 4: Reservas e contrato de aprovação integral

**Files:** Create `020_reservations.test.sql`, migration `cycle_3_reservations`; Modify `_planning.psql`, `014_enrollments.test.sql`, `015_fleet_invitations.test.sql` e `016_cycle_2_audit_privacy.test.sql` para novo contrato. Esses três testes são os callers existentes identificados na elaboração.

**Interfaces:** Produces:

```sql
public.approve_transport_request(p_request_id uuid, p_allocations jsonb,
  p_effective_on date) returns uuid
public.set_transport_request_status(p_request_id uuid, p_status text,
  p_reason text) returns text
```

Status aceitos no segundo comando: `waitlisted|rejected`. `p_allocations` é o array definido nos contratos comuns; deve cobrir exatamente cada combinação solicitada de dia/sentido, sem duplicar ou acrescentar passageiros. `p_effective_on` precisa pertencer à vigência das agendas; aprovação inicial não permite uso em viagem já iniciada no Ciclo 4.

- [ ] **Step 1 — RED da antiga aprovação sem reserva.** Manter fixture do teste 014 e trocar apenas a expectativa do caminho legado:

```sql
select throws_ok(
  $$select public.decide_fleet_join_request(
    (select id from enrollment_test_ids where kind='minor-request'),'approved')$$,
  'PGRST', null, 'contrato legado não aprova sem alocação');
```

Adicionar no teste novo uma solicitação com ida/volta e alocação somente ida; esperar erro e zero matrículas/reservas criadas. Fixture de cada teste fica entre `begin`/`rollback`; ampliar `_planning.psql` com `pg_temp.seed_cycle_3() returns void` que chama `seed_foundation()` e `seed_cycle_2_users()`, cria escola fictícia, menor pelo principal `60000000-0000-0000-0000-000000000001` e agendas ida/volta, usando tabela temporária `planning_ids(kind text primary key,id uuid)` para IDs retornados. Chaves obrigatórias: `minor`, `school`, `van`, `going-route`, `return-route`, `going-schedule`, `return-schedule`, `request`. Agenda válida de 2026-09-01 a 2026-12-31, segunda a sexta, ida 08:00–09:00, volta 16:00–17:00, America/Sao_Paulo, prazo 30min, escola/origem/destino com coordenadas fictícias válidas. Um único pedido inclui ambos os sentidos e cinco dias; testes de fila acrescentam alunos/pedidos distintos `first` e `second`.

- [ ] **Step 2 — Implementar schema e transação.**

Criar `route_student_schedules(id,fleet_id,enrollment_id,schedule_id,weekday,direction,valid_from,valid_until)` com FK composta e checks. Ampliar pedidos com `request_kind new|change`, `enrollment_id` opcional, `effective_on` opcional; ampliar status/check de datas para manter espera sem decisão final. Substituir índice de único pedido pendente por único aberto `where status in ('pending','waitlisted')` por aluno/frota. Ampliar vínculo com `school_id`, `shift`, `routing_revision bigint default 1`.

```sql
select private.lock_planning();
-- Na RPC, depois de autorizar e bloquear pedido:
select private.apply_request_allocation(p_request_id, p_allocations, p_effective_on);
```

Dentro do helper: validar integralidade, contar reservas sobrepostas por execução/dia real, validar conflito global de aluno, criar vínculo/fontes com helpers existentes, inserir reservas e aprovar pedido/auditoria. Não tratar `unique_violation` de qualquer origem como simples matrícula duplicada; mapear constraint conhecida.

Manter assinatura legada `decide_fleet_join_request(uuid,text)`: `approved` retorna `allocation_required`; `rejected` usa o comando novo. Aceite de convite guardian/student conserva assinatura mas retorna pedido `pending`; remover criação de matrícula/papéis daquele corpo. Notificar quebra de retorno ao Flutter.

- [ ] **Step 3 — GREEN e extensão de integridade.**

```bash
supabase db reset --local
supabase test db supabase/tests/database/020_reservations.test.sql
supabase test db supabase/tests/database/014_enrollments.test.sql
supabase test db supabase/tests/database/015_fleet_invitations.test.sql
```

Atualizar a preparação dos demais testes que precisam de matrícula para aprovar por alocação válida, sem relaxar asserts de privacidade/fontes. Validar duas frotas, pedido integral, aluno com outro turno permitido, mesmo dia/turno/sentido negado, capacidade contratada e mudança de capacidade/rota rejeitada quando quebra reserva.

## Task 5: Fila conjunta e preferências sem prioridade arbitrária

**Files:** Create `021_transport_queue.test.sql`, migration `cycle_3_queue`.

**Interfaces:** Consumes aprovação; Produces:

```sql
public.list_transport_queue(p_fleet_id uuid, p_limit integer, p_offset integer)
  returns table(request_id uuid, request_kind text, status text,
    created_at timestamptz, fully_serviceable boolean)
public.set_request_van_preferences(p_request_id uuid, p_van_ids uuid[]) returns void
```

- [ ] **Step 1 — RED da prioridade entre `pending` e `waitlisted`.** No `seed_cycle_3`, criar pedidos `first` e `second`, usando o servidor para criação e ajustando a data somente como administrador da fixture. Guardar IDs em `planning_ids`.

```sql
select results_eq(
  $$select request_id from public.list_transport_queue(
    '41000000-0000-0000-0000-000000000001',50,0)$$,
  $$select id from planning_ids where kind in ('first','second') order by kind$$,
  'fila inclui pendentes e espera por antiguidade');
```

Run: `supabase test db supabase/tests/database/021_transport_queue.test.sql`.

- [ ] **Step 2 — Implementar busca de alocação e prioridade na aprovação.**

`find_request_allocation` enumera candidatos por combinação requerida dia/sentido, escola e turno. Ordena candidatos por ID, testa capacidade residual e conflitos, e faz busca com retorno quando uma escolha parcial impede completar outra combinação. Não concluir compatibilidade por somar vagas em dias distintos. Não excluir rotas por preferência de van.

```sql
select id from public.fleet_join_requests
where fleet_id = v_fleet_id and status in ('pending','waitlisted')
order by created_at, id;
```

Dentro do mesmo lock da aprovação, percorrer anteriores e chamar o helper; se algum for integralmente atendível na vigência aplicável, retornar `queue_priority`. Se não, permitir o pedido atual. Preferências persistem em tabela relacional com posição 1–3 e unicidade por pedido/van; só solicitante dono do pedido aberto altera.

- [ ] **Step 3 — GREEN e casos discriminantes.**

Testar primeiro ida/volta incompatível e segundo somente ida compatível; primeiro conserva data. Depois liberar volta e comprovar prioridade do primeiro. Acrescentar alocação alternativa em outra van para impedir burlar fila escolhendo uma rota conveniente. Recusa remove da fila; mudança de status pending→waitlisted não muda antiguidade; empate ordena por ID.

```bash
supabase db reset --local
supabase test db supabase/tests/database/021_transport_queue.test.sql
```

## Task 6: Trocas de programação, escola/endereço e encerramento

**Files:** Create `022_schedule_changes.test.sql`, migration `cycle_3_schedule_changes`; ler `20260906210854` e `20260906211528`.

**Interfaces:** Produces:

```sql
public.request_schedule_change(p_enrollment_id uuid, p_directions text[],
  p_weekdays smallint[]) returns uuid
public.update_enrollment_school(p_enrollment_id uuid, p_school_id uuid) returns uuid
private.next_change_date(p_request_id uuid, p_now timestamptz) returns date
```

`next_change_date` retorna primeira data de serviço posterior ao dia local atual cujas confirmações afetadas ainda estejam abertas; retorna NULL se agendas não cobrirem uma vigência possível. `end_fleet_enrollment(uuid,text)` mantém assinatura e amplia autores para owner/principal/adulto.

- [ ] **Step 1 — RED de preservação da reserva anterior.**

```sql
select has_function('public','request_schedule_change',
  array['uuid','text[]','smallint[]'],'mudança cria pedido próprio');
```

Após a função existir, fazer pedido de mudança em fixture com reserva ativa e provar que `route_student_schedules` permanece igual até aprovação. Run: `supabase test db supabase/tests/database/022_schedule_changes.test.sql`.

- [ ] **Step 2 — Implementar revisão e troca temporal.**

Pedido `change` referencia vínculo; copia escola/turno atuais e novo conjunto dias/sentidos. Apenas principal/adulto solicita. Aprovação reutiliza `approve_transport_request`, exige a data calculada e encerra reservas antigas no dia anterior, inserindo novas a partir da data. Em dia mantido, a mesma vaga não conta duas vezes:

```sql
update public.route_student_schedules
set valid_until = p_effective_on - 1
where enrollment_id = v_enrollment_id
  and valid_from < p_effective_on and valid_until >= p_effective_on;
```

Reservas futuras que ainda não começaram e são substituídas devem ser registradas como canceladas em vez de criar intervalo inválido; adicionar `cancelled_at` e excluir essas linhas do cálculo, preservando histórico. A fila usa `created_at` do pedido, nunca data da matrícula.

`update_enrollment_school` altera escola vigente e incrementa `routing_revision`, sem alterar escola no pedido histórico. `update_student` incrementa a revisão de vínculos ativos ao mudar endereço/coordenadas; dados de aluno continuam controlados por principal/adulto. Encerramento registra motivo, termina reservas futuras e preserva fontes manuais/outros dependentes. No Ciclo 4, integrar viagens ao mesmo ponto da transação.

- [ ] **Step 3 — GREEN e fronteiras temporais.**

Testar falta de vaga sem perda de reserva, troca integral futura, dia atual preservado, nenhuma data viável, escola sem mudança de turno/dias, endereço global impactando dois vínculos e snapshot do pedido intacto. Testar encerramento por principal/adulto e negação ao secundário.

```bash
supabase db reset --local
supabase test db supabase/tests/database/022_schedule_changes.test.sql
```

## Task 7: Projeções, auditoria e concorrência real

**Files:** Create `023_planning_privacy.test.sql`, migration `cycle_3_projections`, `supabase/tests/concurrency/planning.py`, `planning_setup.psql`, `planning_cleanup.psql`; Modify `_planning.psql`.

**Interfaces:** Produces `public.get_fleet_planning(p_fleet_id uuid) returns jsonb` e `public.get_my_transport() returns jsonb`. Primeiro exige owner/driver e filtra driver às rotas atribuídas; segundo retorna somente vínculos/alunos autorizados. Payloads têm `vans`, `routes`, `schedules`, `reservations` e revisões, sem tokens/PII de terceiros. Marketplace acrescenta vans por RPC `public.list_marketplace_vans(p_fleet_id uuid) returns table(id uuid,public_name text,model text,capacity integer)`, somente frota publicada, sem placa/motorista/posição.

- [ ] **Step 1 — RED negativo de leitura e exposição.**

```sql
select throws_ok(
 $$select public.get_fleet_planning('41000000-0000-0000-0000-000000000002')$$,
 'PGRST', null, 'owner A não lê planejamento B');
select ok(not has_table_privilege('anon','public.route_student_schedules','SELECT'),
 'reservas não são públicas');
```

Run: `supabase test db supabase/tests/database/023_planning_privacy.test.sql`. Implementar projeções explícitas; não serializar `%rowtype` de tabelas privadas para o público.

- [ ] **Step 2 — Provar serialização com processos reais.** O script Python stdlib usa `subprocess.Popen` de `psql`, duas transações e barreira por stdout (não um sleep como garantia). Aceita apenas `PGHOST=127.0.0.1|localhost|::1`, `PGPORT` local e senha por ambiente; sem DSN remoto.

```python
import os, subprocess, time
assert os.environ.get('PGHOST') in {'127.0.0.1', 'localhost', '::1'}
def session():
    return subprocess.Popen(['psql', '-X', '-v', 'ON_ERROR_STOP=1'],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, text=True)
def run(sql):
    return subprocess.run(['psql','-X','-At','-v','ON_ERROR_STOP=1','-c',sql],
        capture_output=True,text=True,check=True).stdout.strip()
def race(first_sql, second_sql):
    first, second = session(), session()
    try:
        first.stdin.write("begin; select private.lock_planning();\n\\echo LOCKED\n")
        first.stdin.flush()
        while first.stdout.readline().strip() != 'LOCKED':
            if first.poll() is not None: raise AssertionError('primeira sessão falhou')
        second.stdin.write("set application_name='vango-planning-race'; begin;\n"
            + second_sql + "\ncommit;\n")
        second.stdin.close()
        deadline = time.monotonic()+5
        while run("select count(*) from pg_stat_activity where "
            "application_name='vango-planning-race' and wait_event='advisory'") != '1':
            if time.monotonic()>deadline: raise AssertionError('comando não usou lock comum')
            time.sleep(0.05)
        first.stdin.write(first_sql+"\ncommit;\n")
        first.stdin.close()
        first.wait(timeout=10)
        second.wait(timeout=10)
        return first.returncode, second.returncode
    finally:
        for process in (first,second):
            if process.poll() is None: process.kill()
            process.wait()
```

Usar `race` com os SQLs reais de cada cenário, configurando JWT/role no comando de cada sessão. Para última vaga, A aprova primeiro pedido e B tenta o segundo com mesmas vagas: retorno A=0/B!=0 e consulta final comprova uma reserva. Para suspensão×atribuição, placa global e motorista entre frotas, inverter a ordem e comprovar o mesmo invariante final. Setup cria dados `@example.test` com IDs exclusivos, commits só no banco local; cleanup remove apenas esses IDs em ordem de FKs num `finally`. Não usar `pg_temp` entre conexões esperando dados compartilhados.

- [ ] **Step 3 — GREEN de RLS e concorrência.**

```bash
supabase test db supabase/tests/database/023_planning_privacy.test.sql
python3 supabase/tests/concurrency/planning.py
supabase test db
```

Conferir auditoria dos comandos e ausência de DML direto, incluindo papéis suspensos e fonte manual que não autoriza aluno.

## Task 8: Validar localmente e publicar com recuperação

**Files:** Create `docs/operations/ciclo-3-production.md`; Modify `README.md`, `be-tech-plan.md`, `deliverables.md` somente com resultados reais.

**Interfaces:** Consumes release local validada; Produces schema/RPC publicados, versão e evidência, ou bloqueio explicitamente descrito.

- [ ] **Step 1 — Executar gate local.**

```bash
supabase db reset --local
supabase test db
supabase db lint --local --schema public,private --fail-on error
supabase db advisors --local --type all --level warn --fail-on error
git diff --check
git status --short
```

Validar flags com `--help` na CLI instalada. Executar `software-quality-gate` somente leitura e comparar `git status`. Guardar evidência de RED/GREEN por task; não prometer commits automáticos.

- [ ] **Step 2 — Preparar destino e preflight.** Em runbook, registrar projeto real selecionado, migrations esperadas, ponto de recuperação verificado, owner de operação e versão Flutter compatível. Credenciais entram por ambiente seguro, sem valores em docs. Inspecionar legado antes da alteração:

```sql
select count(*) as active_enrollments
from public.fleet_enrollments where status='active';
```

Se houver vínculos legados sem reservas, bloquear publicação até um plano de dados específico; não apagar nem inventar alocações. Se o schema ainda não existe no destino, registrar primeira implantação, incluindo migrations 0–2. Configurar confirmação de e-mail, SMTP de produção e callbacks reais iOS/Android; não enviar `config.toml` local cegamente.

- [ ] **Step 3 — Conferir dry-run e publicar.**

```bash
: "${SUPABASE_PROJECT_REF:?Defina o projeto de produção verificado}"
supabase link --project-ref "$SUPABASE_PROJECT_REF"
supabase migration list --linked
supabase db push --linked --dry-run
supabase db push --linked
supabase migration list --linked
```

Sem `--include-seed`, `--include-all` ou reset remoto. Se o dry-run diferir da release validada, interromper o rollout e corrigir a divergência. Não iniciar alteração de schema por SQL avulso remoto.

- [ ] **Step 4 — Verificar resultado publicado e documentar.** Confirmar grants/RLS, ausência de aprovação legada sem reserva, convite pendente e fluxo controlado entre dois usuários autorizados de teste operacional. Não executar pgTAP/cleanup local contra produção. Carga manual do catálogo é pré-requisito para abrir solicitações; validar antes de ativar o fluxo, sem transformar fixture em escola real.

Falha: interromper novas operações afetadas, preservar dados/evidência e aplicar correção forward; restauração só pelo procedimento validado e com impacto avaliado. Registrar separadamente local PASS, migrations publicadas e smoke PASS, com data/versão. Não marcar ciclo concluído se publicação ou smoke estiver pendente.

## Cobertura e passagem para o Ciclo 4

| Requisito da spec | Task |
| --- | --- |
| van/placa/capacidade | 1, 3, 4 |
| driver/convite/bloqueios | 2, 3, 7 |
| rotas/fuso/agenda/conflitos | 3, 7 |
| aprovação integral/legado | 4, 8 |
| fila/preferências | 5 |
| mudanças/cadastro/encerramento | 6 |
| RLS/auditoria/concorrência | 1–7 |
| local → produção | 8 |

O Ciclo 4 amplia os mesmos guardas para viagens, reconcilia geração com reservas e entrega avisos como eventos. Não criar tabelas ou callbacks vazios desse ciclo antecipadamente.

Referência de comandos: [Supabase CLI](https://supabase.com/docs/reference/cli/supabase-db-push), consultada em 2026-09-07; revalidar na execução.

## Registro de execução

Backend validado na release integrada em 2026-09-08: 850 assertions pgTAP, 45 testes Deno, 14 disputas PostgreSQL e WebSocket real. Evidência consolidada, publicação e pendências externas em [deliverables.md](../../../deliverables.md) e no runbook do ciclo. Os checklists acima descrevem a sequência de trabalho, não comprovam ativação de serviços externos.
