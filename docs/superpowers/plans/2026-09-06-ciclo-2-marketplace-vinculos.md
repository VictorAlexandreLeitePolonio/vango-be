# Ciclo 2 — Marketplace e vínculos Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Entregar o catálogo vazio de instituições, a cobertura comercial das frotas, alunos e responsáveis, marketplace, solicitações, convites e vínculos com isolamento multi-tenant, privacidade e auditoria.

**Architecture:** O Flutter usa a Data API somente para leituras e alterações simples protegidas por RLS. Database Functions executam criação de alunos, convites, transições, papéis derivados e vínculos. O banco guarda apenas hashes de tokens; não há Edge Functions, envio de e-mail nem importação de instituições neste ciclo.

**Tech Stack:** Supabase Auth, PostgreSQL 17, Data API/PostgREST, PL/pgSQL, RLS, pgTAP e Supabase CLI.

**Spec:** `docs/superpowers/specs/2026-09-06-ciclo-2-marketplace-vinculos-design.md`.

## Global Constraints

- Não inserir escolas ou faculdades em migration, `seed.sql`, fixture persistente ou script.
- Fixtures pgTAP devem ser fictícias, existir somente dentro da transação de teste e desaparecer no `rollback`.
- Não criar importador, integração externa, painel do catálogo, Edge Function, Cron, Realtime, Storage ou código Flutter.
- Não implementar vans, motoristas, rotas, agendas, capacidade, disponibilidade, preferências ou lista de espera.
- Preservar as migrations aplicadas dos Ciclos 0 e 1; toda mudança usa `supabase migration new`.
- Preservar `fleet_service_schools` como cobertura comercial; `route_schools` continua fora deste ciclo.
- Owners não criam alunos. O responsável principal cria menores; o aluno adulto cria o próprio registro.
- Convites duram 14 dias, armazenam somente SHA-256 do token e exigem o mesmo e-mail confirmado na aceitação.
- Uma solicitação aprovada ou convite aceito cria vínculo direto, sem estado intermediário e sem lista de espera.
- Papéis `guardian` e `student` derivados de vínculos precisam de proveniência para que a remoção preserve papéis manuais e outros dependentes.
- Tabelas transacionais negam escrita direta a `anon` e `authenticated`, exceto cobertura comercial, que owners administram pela Data API.
- Funções `security definer` usam `set search_path = ''`, nomes totalmente qualificados, grants mínimos e lock antes de transições.
- Nenhuma resposta pública ou auditoria expõe e-mail, token, endereço residencial ou coordenadas.
- Cada mudança de comportamento segue RED, GREEN e refactor, com o menor teste que prova o contrato.
- Não adicionar dependência, manifest, servidor Node.js ou camada paralela.
- Não fazer commit, push ou deployment remoto sem autorização explícita.
- Antes da declaração de conclusão, executar `software-quality-gate` sem permitir alterações no repositório e conferir `git status` antes e depois.

---

## Contrato de dados aprovado

### Tabelas novas

| Tabela | Responsabilidade |
| --- | --- |
| `schools` | catálogo global vazio de escolas e campi presenciais |
| `fleet_service_cities` | cidades cobertas comercialmente por uma frota |
| `fleet_service_schools` | instituições cobertas comercialmente por uma frota |
| `students` | menores e alunos adultos, independentes de tenant |
| `student_guardians` | responsáveis principal e secundários de menores |
| `student_guardian_invitations` | convite de responsável secundário |
| `fleet_join_requests` | solicitação imutável do marketplace ou histórico de convite aceito |
| `fleet_enrollments` | vínculo ativo ou encerrado entre frota e aluno |
| `fleet_invitations` | convite criado pelo owner para responsável ou aluno adulto |
| `fleet_membership_role_sources` | proveniência manual ou derivada dos papéis efetivos |

### Estados e unicidades

- Convites: `pending`, `accepted`, `declined`, `cancelled`, `expired`.
- Solicitações: `pending`, `approved`, `rejected`, `cancelled`.
- Vínculos: `active`, `ended`.
- Um convite pendente por contexto e e-mail normalizado.
- Uma solicitação pendente por aluno e frota.
- Um vínculo ativo por aluno e frota.
- Um `profile_id` por aluno adulto.
- Um responsável principal ativo por menor.

### RPCs públicas

```text
search_schools(p_query text, p_city_ibge_code text, p_institution_type text, p_limit integer, p_offset integer)
search_marketplace(p_city_ibge_code text, p_school_id uuid, p_limit integer, p_offset integer)
list_fleet_join_requests(p_fleet_id uuid, p_status text, p_limit integer, p_offset integer)
get_fleet_invitation(p_token text)

create_minor_student(p_full_name text, p_birth_date date, p_postal_code text, p_street text, p_street_number text, p_address_complement text, p_neighborhood text, p_city_name text, p_city_ibge_code text, p_state_code text, p_latitude numeric, p_longitude numeric) returns uuid
create_adult_student(p_full_name text, p_birth_date date, p_postal_code text, p_street text, p_street_number text, p_address_complement text, p_neighborhood text, p_city_name text, p_city_ibge_code text, p_state_code text, p_latitude numeric, p_longitude numeric) returns uuid
update_student(p_student_id uuid, p_full_name text, p_birth_date date, p_postal_code text, p_street text, p_street_number text, p_address_complement text, p_neighborhood text, p_city_name text, p_city_ibge_code text, p_state_code text, p_latitude numeric, p_longitude numeric) returns uuid
create_student_guardian_invitation(p_student_id uuid, p_email text) returns text
respond_student_guardian_invitation(p_token text, p_accept boolean) returns text
remove_student_guardian(p_student_id uuid, p_guardian_user_id uuid) returns text
submit_fleet_join_request(p_fleet_id uuid, p_student_id uuid, p_school_id uuid, p_shift text, p_directions text[], p_weekdays smallint[]) returns uuid
cancel_fleet_join_request(p_request_id uuid) returns text
decide_fleet_join_request(p_request_id uuid, p_decision text) returns text
create_fleet_invitation(p_fleet_id uuid, p_email text, p_role text) returns text
accept_fleet_invitation(p_token text, p_student_id uuid, p_school_id uuid, p_shift text, p_directions text[], p_weekdays smallint[]) returns uuid
decline_fleet_invitation(p_token text) returns text
cancel_fleet_invitation(p_invitation_id uuid) returns text
end_fleet_enrollment(p_enrollment_id uuid, p_reason text) returns text
```

### Simplificações deliberadas

- A busca textual usa `unaccent` e `ILIKE`; o catálogo regional inicial não justifica motor de busca separado.
- Endereço é validado e copiado como snapshot na solicitação; não há geocodificação.
- Expiração é oportunista, sem Cron. RPCs textuais retornam `expired`; `get_fleet_invitation` retorna status `expired`; `accept_fleet_invitation` retorna `null` depois de persistir a expiração, pois lançar erro reverteria a atualização.
- A Data API administra cobertura com `INSERT` e `DELETE`; não há CRUD RPC para duas relações simples protegidas por RLS.

---

## Estrutura esperada ao final

```text
supabase/
├── migrations/
│   ├── <cli>_create_cycle_2_schema.sql
│   ├── <cli>_create_cycle_2_authorization.sql
│   ├── <cli>_create_marketplace_functions.sql
│   ├── <cli>_create_student_functions.sql
│   ├── <cli>_create_guardian_functions.sql
│   ├── <cli>_create_join_request_functions.sql
│   ├── <cli>_create_enrollment_functions.sql
│   ├── <cli>_create_fleet_invitation_functions.sql
│   └── <cli>_create_cycle_2_audit.sql  # somente se o RED da Task 10 exigir
└── tests/
    ├── _helpers.psql
    └── database/
        ├── 008_cycle_2_schema.test.sql
        ├── 009_cycle_2_authorization.test.sql
        ├── 010_marketplace.test.sql
        ├── 011_students.test.sql
        ├── 012_guardian_invitations.test.sql
        ├── 013_join_requests.test.sql
        ├── 014_enrollments.test.sql
        ├── 015_fleet_invitations.test.sql
        └── 016_cycle_2_audit_privacy.test.sql
```

Cada `<cli>` representa o timestamp real produzido por `supabase migration new`. Usar o caminho exato retornado pela CLI, sem criar timestamp manualmente.

---

### Task 1: Revalidar o baseline do Ciclo 1

**Files:**

- Inspect: `be-tech-plan.md`.
- Inspect: `CONTRIBUTING.md`.
- Inspect: `deliverables.md`.
- Inspect: `supabase/config.toml`.
- Inspect: `supabase/migrations/`.
- Inspect: `supabase/tests/database/`.

**Interfaces:**

- Consumes: commit local `9d42709` e migrations dos Ciclos 0 e 1.
- Produces: baseline verde e inventário de alterações locais preservado.

- [ ] **Step 1: Conferir branch, alterações e arquivos reais**

Run:

```bash
git status --short --branch
git diff --name-only
rg --files supabase -g '!**/.temp/**' -g '!**/.branches/**' | sort
```

Expected: branch `dev-polonio`; nenhum arquivo do usuário restaurado ou sobrescrito; spec e pesquisa permanecem não commitadas se ainda estiverem assim.

- [ ] **Step 2: Validar o banco do zero antes do primeiro RED**

Run:

```bash
supabase status
supabase db reset
supabase test db
supabase migration list --local
```

Expected: testes `000` a `007` passam e a última migration local é `20260905225950_create_foundation_audit.sql`.

- [ ] **Step 3: Confirmar o corte negativo**

Run:

```bash
rg -n "school|institution|student|guardian|join_request|enrollment|invitation" supabase/migrations supabase/seed.sql
```

Expected: nenhuma implementação parcial do Ciclo 2. Se houver, parar e reconciliar com a spec antes de editar.

---

### Task 2: Criar schema, constraints, índices e proveniência de papéis

**Files:**

- Modify: `supabase/tests/_helpers.psql`.
- Create: `supabase/tests/database/008_cycle_2_schema.test.sql`.
- Create: migration retornada por `supabase migration new create_cycle_2_schema`.

**Interfaces:**

- Consumes: `profiles`, `fleets`, `fleet_memberships`, `fleet_membership_roles` e `audit_events`.
- Produces: dez tabelas novas, extensões nativas, constraints, índices e fontes de papéis existentes.

- [ ] **Step 1: Acrescentar fixtures fictícias ao helper**

Adicionar `pg_temp.seed_cycle_2()` em PL/pgSQL sem alterar `pg_temp.seed_foundation()`. A função deve criar duas frotas, usuários confirmados e não confirmados, dois menores, um adulto e três instituições fictícias: uma escola ativa, uma faculdade ativa e uma escola inativa. Usar códigos IBGE reservados à fixture e nomes iniciados por `Teste`, sem cidades ou instituições reais.

- [ ] **Step 2: Escrever o teste estrutural vermelho**

Em `008_cycle_2_schema.test.sql`, provar com pgTAP:

- existência das dez tabelas;
- `schools` começa vazia após `supabase db reset`;
- enums textuais rejeitam valores fora do contrato;
- `provider = inep` aceita apenas `school` e `provider = emec` aceita apenas `higher_education`;
- código IBGE tem sete dígitos e UF duas letras maiúsculas;
- latitude e longitude são nulas em conjunto ou válidas em conjunto;
- FKs, índices e unicidades parciais existem;
- endereço snapshot não depende do endereço atual do aluno;
- fontes `manual` foram criadas para todos os papéis do Ciclo 1.

Run:

```bash
supabase test db supabase/tests/database/008_cycle_2_schema.test.sql
```

Expected: FAIL por ausência das tabelas.

- [ ] **Step 3: Criar a migration pela CLI**

Run:

```bash
supabase migration new create_cycle_2_schema
```

Na migration gerada:

- habilitar `pgcrypto` e `unaccent` em `extensions` com `create extension if not exists`;
- criar as dez tabelas do contrato;
- usar UUID com `gen_random_uuid()`, `timestamptz`, `NOT NULL`, `CHECK`, `FOREIGN KEY` e ações de remoção explícitas;
- usar `on delete restrict` para entidades históricas e `on delete cascade` somente em relações sem história própria;
- criar partial unique index para convite pendente, solicitação pendente, vínculo ativo e responsável principal ativo;
- criar índices em todas as FKs, `fleet_id`, `student_id`, `school_id`, status e hash de token;
- em `fleet_membership_role_sources`, usar `id`, `membership_id`, `role`, `source_type`, `enrollment_id` e `created_at`; aceitar `manual` com `enrollment_id is null` e `enrollment` com papel `guardian` ou `student` e `enrollment_id is not null`;
- criar índice único parcial `(membership_id, role)` para fonte `manual` e `(membership_id, role, enrollment_id)` para fonte `enrollment`;
- popular uma fonte `manual` para cada linha já existente em `fleet_membership_roles`;
- ampliar os CHECKs de `audit_events` com ações e entidades do Ciclo 2 sem remover valores do Ciclo 1.

Campos de `fleet_join_requests` devem incluir o snapshot completo: `postal_code`, `street`, `street_number`, `address_complement`, `neighborhood`, `city_name`, `city_ibge_code`, `state_code`, `latitude` e `longitude`.

- [ ] **Step 4: Recriar e provar GREEN**

Run:

```bash
supabase db reset
supabase test db supabase/tests/database/008_cycle_2_schema.test.sql
supabase test db
git diff --check
```

Expected: schema e suíte completa verdes; `supabase/seed.sql` continua sem instituições.

---

### Task 3: Autorizar Data API e preservar papéis manuais

**Files:**

- Create: `supabase/tests/database/009_cycle_2_authorization.test.sql`.
- Create: migration retornada por `supabase migration new create_cycle_2_authorization`.

**Interfaces:**

- Consumes: tabelas do Task 2 e helpers `private.is_active_fleet_member`/`private.has_fleet_role`.
- Produces: helpers de aluno/e-mail, grants, RLS e `set_fleet_member_roles` compatível com proveniência.

- [ ] **Step 1: Escrever testes RLS vermelhos com dois tenants**

Cobrir separadamente `SELECT`, `INSERT`, `UPDATE` e `DELETE`:

- `anon` não lê nem escreve tabelas novas;
- usuário autenticado não escreve `schools`;
- membro ativo lê cobertura da própria frota;
- owner insere e remove cobertura da própria frota com `created_by = auth.uid()`;
- owner não altera cobertura de outro tenant mesmo conhecendo os UUIDs;
- instituição inativa não entra em `fleet_service_schools`;
- aluno ou responsável ativo lê seu aluno; owner não lê diretamente `students`;
- solicitante lê a própria solicitação; owner não recebe acesso direto ao snapshot;
- ninguém escreve diretamente em alunos, responsáveis, convites, solicitações, vínculos ou fontes de papéis.

Run:

```bash
supabase test db supabase/tests/database/009_cycle_2_authorization.test.sql
```

Expected: FAIL porque grants e policies ainda não existem.

- [ ] **Step 2: Criar helpers privados mínimos**

Criar, com `security definer`, `set search_path = ''` e execução revogada:

```text
private.current_user_email() returns text
private.current_user_email_confirmed() returns boolean
private.can_view_student(p_student_id uuid, p_user_id uuid) returns boolean
private.can_manage_student(p_student_id uuid, p_user_id uuid) returns boolean
private.sync_effective_membership_roles(p_membership_id uuid) returns void
```

`can_manage_student` aceita o próprio adulto ou o responsável principal ativo. `can_view_student` acrescenta responsáveis secundários ativos. Helpers de RLS usados por `authenticated` recebem somente o `EXECUTE` necessário.

- [ ] **Step 3: Habilitar RLS e grants mínimos**

- revogar todos os privilégios das dez tabelas para `anon` e `authenticated`;
- conceder `SELECT`, `INSERT` e `DELETE` apenas nas duas tabelas de cobertura conforme a matriz aprovada;
- conceder `SELECT` somente onde o usuário pode ler a linha completa sem violar finalidade;
- manter owner fora do `SELECT` direto de `students` e `fleet_join_requests`;
- usar policies por operação, sempre vinculadas a `auth.uid()`, tenant e status ativo;
- validar escola ativa no `WITH CHECK` de `fleet_service_schools`;
- impedir spoofing de `created_by` no `WITH CHECK`.

- [ ] **Step 4: Adaptar o RPC existente de papéis**

Substituir `public.set_fleet_member_roles(uuid, text[])` na nova migration para:

1. manter as validações e proteção do último owner do Ciclo 1;
2. alterar somente fontes `manual` da associação;
3. preservar fontes `enrollment` existentes;
4. recomputar `fleet_membership_roles` pela união das fontes;
5. auditar papéis efetivos anteriores e novos apenas quando mudarem.

Não editar `20260905225949_create_membership_rpcs.sql`.

- [ ] **Step 5: Provar autorização e regressão do Ciclo 1**

Run:

```bash
supabase db reset
supabase test db supabase/tests/database/009_cycle_2_authorization.test.sql
supabase test db supabase/tests/database/004_member_roles.test.sql
supabase test db supabase/tests/database/005_membership_status.test.sql
supabase test db
git diff --check
```

Expected: acesso cruzado negado e papéis manuais preservados.

---

### Task 4: Implementar cobertura auditada e buscas públicas

**Files:**

- Create: `supabase/tests/database/010_marketplace.test.sql`.
- Create: migration retornada por `supabase migration new create_marketplace_functions`.

**Interfaces:**

- Produces: `search_schools`, `search_marketplace` e auditoria de cobertura.
- Allows: `anon`, `authenticated` nas duas buscas; owners na cobertura pela Data API.

- [ ] **Step 1: Escrever o teste vermelho das buscas**

Cobrir:

- busca de escola por texto sem acento, cidade e tipo;
- somente instituições ativas e campos públicos;
- paginação com limite entre 1 e 50 e offset não negativo;
- rejeição de filtro inválido;
- marketplace retorna apenas frota `published` com as duas coberturas solicitadas;
- frota `draft`, escola inativa, cidade diferente ou apenas uma cobertura não aparecem;
- resultado não contém membros, endereço, vans, capacidade ou disponibilidade;
- `anon` executa as duas funções e não executa comandos privados;
- inserção e remoção de cobertura geram auditoria sanitizada.

- [ ] **Step 2: Implementar `search_schools`**

Retornar `id`, `institution_type`, `name`, `city_name`, `city_ibge_code`, `state_code` e endereço institucional. Comparar `extensions.unaccent(lower(name))` com `extensions.unaccent(lower(btrim(p_query)))`. Ordenar por `name, id`. Exigir ao menos `p_query` não vazio ou `p_city_ibge_code` válido.

- [ ] **Step 3: Implementar `search_marketplace`**

Exigir cidade válida, instituição ativa e limite válido. Fazer join de `fleets`, `fleet_service_cities` e `fleet_service_schools`; retornar somente `id`, `name`, `slug`, `description` e `logo_path`, ordenados por `name, id`.

- [ ] **Step 4: Auditar cobertura com um trigger compartilhado**

Criar uma função privada de trigger usada pelas duas tabelas. Em `INSERT`/`DELETE`, registrar `service_city_added`, `service_city_removed`, `service_school_added` ou `service_school_removed`. Para cidade, usar `fleet_id` como `entity_id` e guardar apenas `city_ibge_code`; para escola, usar `school_id`. Nunca guardar nome, endereço ou coordenadas.

- [ ] **Step 5: Aplicar grants e validar**

Revogar `EXECUTE` de `public` e conceder apenas a `anon, authenticated` nas duas buscas. Executar:

```bash
supabase db reset
supabase test db supabase/tests/database/010_marketplace.test.sql
supabase test db
git diff --check
```

Expected: buscas e auditoria verdes sem qualquer carga real em `schools`.

---

### Task 5: Criar e atualizar alunos

**Files:**

- Create: `supabase/tests/database/011_students.test.sql`.
- Create: migration retornada por `supabase migration new create_student_functions`.

**Interfaces:**

- Produces: `create_minor_student`, `create_adult_student`, `update_student`.
- Error codes: `unauthenticated`, `email_unverified`, `forbidden`, `not_found`, `invalid_input`, `student_conflict`.

- [ ] **Step 1: Escrever testes vermelhos por comportamento**

Cobrir autenticação, e-mail confirmado, nome/data/endereço, idade exata de 18 anos, coordenadas pareadas, um adulto por perfil e owner sem permissão especial. Provar que criar menor também cria exatamente um responsável principal e que adulto não recebe `student_guardians`.

- [ ] **Step 2: Implementar validação comum sem API externa**

Usar um helper privado apenas se as três RPCs repetirem a mesma validação de endereço. Validar campos obrigatórios não vazios, CEP não vazio, IBGE com sete dígitos, UF com duas letras, data não futura e coordenadas pareadas dentro dos limites geográficos.

- [ ] **Step 3: Implementar criação transacional**

- menor: exigir idade abaixo de 18 anos, inserir `students` sem `profile_id` e criar o responsável principal ativo para `auth.uid()`;
- adulto: exigir 18 anos ou mais e inserir `profile_id = auth.uid()`;
- converter conflitos de unicidade em `student_conflict` com HTTP 409;
- conceder `EXECUTE` somente a `authenticated`.

- [ ] **Step 4: Implementar atualização e auditoria sanitizada**

`update_student` bloqueia a linha, exige `can_manage_student`, preserva `student_type`/`profile_id` e revalida idade compatível. Para cada frota com vínculo ativo, registrar `student_updated` com somente `changed_fields`, em ordem estável e sem valores.

- [ ] **Step 5: Validar**

Run:

```bash
supabase db reset
supabase test db supabase/tests/database/011_students.test.sql
supabase test db
git diff --check
```

Expected: criação, atualização, propriedade e auditoria verdes.

---

### Task 6: Implementar convites e remoção de responsável secundário

**Files:**

- Create: `supabase/tests/database/012_guardian_invitations.test.sql`.
- Create: migration retornada por `supabase migration new create_guardian_functions`.

**Interfaces:**

- Produces: `create_student_guardian_invitation`, `respond_student_guardian_invitation`, `remove_student_guardian`.
- Consumes: e-mail confirmado, token SHA-256, vínculos ativos e fontes de papel.

- [ ] **Step 1: Escrever testes vermelhos do ciclo completo**

Cobrir:

- apenas o principal convida e remove;
- e-mail é normalizado e token bruto não é persistido;
- expiração é exatamente 14 dias;
- duplicidade pendente no mesmo aluno/e-mail retorna `invitation_conflict`;
- outro e-mail, e-mail não confirmado e token desconhecido falham sem revelar dados;
- aceitar cria ou reativa a relação secundária;
- recusar, expirar ou repetir transição respeita estado; o status estrutural `cancelled` não ganha comando no convite de responsável porque o contrato aprovado não possui RPC para isso;
- convite vencido persiste `expired` e retorna `expired`;
- aceitar propaga papel `guardian` em todos os vínculos ativos;
- associação suspensa continua suspensa;
- remover apaga apenas fontes derivadas daquele aluno e preserva papel manual/outro dependente.

- [ ] **Step 2: Implementar criação segura do token**

Gerar 32 bytes aleatórios, retornar a codificação hexadecimal uma única vez e persistir `extensions.digest(token, 'sha256')`. Validar e-mail com formato mínimo e `lower(btrim(p_email))`. Não registrar e-mail ou token em auditoria.

- [ ] **Step 3: Implementar resposta ao convite**

Bloquear o convite pelo hash. Validar estado, validade, e-mail confirmado e igualdade de e-mail. Em aceitação, fazer upsert da relação como secundária ativa; para cada vínculo ativo do aluno, criar/reativar associação da frota sem reativar associação suspensa, inserir fonte `enrollment` e sincronizar papel efetivo. Retornar `accepted`, `declined` ou `expired`.

- [ ] **Step 4: Implementar remoção e limpeza de acesso**

Impedir remoção do principal. Marcar secundário como `removed`, remover fontes vinculadas aos enrollments ativos daquele aluno e sincronizar cada associação afetada. Auditar `secondary_guardian_added`/`secondary_guardian_removed` uma vez por frota afetada, somente com IDs.

- [ ] **Step 5: Validar concorrência e suíte**

Executar duas aceitações concorrentes controladas em sessões SQL ou provar idempotência por constraint + lock. Depois:

```bash
supabase db reset
supabase test db supabase/tests/database/012_guardian_invitations.test.sql
supabase test db
git diff --check
```

Expected: uma transição efetiva, nenhum papel duplicado e nenhum vazamento.

---

### Task 7: Implementar solicitações do marketplace

**Files:**

- Create: `supabase/tests/database/013_join_requests.test.sql`.
- Create: migration retornada por `supabase migration new create_join_request_functions`.

**Interfaces:**

- Produces: `submit_fleet_join_request`, `cancel_fleet_join_request`, `list_fleet_join_requests`.
- Error codes: `invalid_input`, `forbidden`, `not_found`, `request_conflict`.

- [ ] **Step 1: Escrever testes vermelhos de submissão**

Cobrir:

- principal solicita para menor e adulto solicita para si;
- secundário e owner não podem solicitar pelo aluno;
- frota deve estar `published`;
- escola deve estar ativa e coberta;
- cidade do endereço atual deve estar coberta;
- turno, sentidos e dias devem ser válidos, únicos e não vazios;
- snapshot é copiado do aluno e não aceita endereço no payload;
- alteração posterior do aluno não muda a solicitação;
- segunda solicitação pendente para aluno/frota retorna `request_conflict`.

- [ ] **Step 2: Implementar submissão**

Validar autenticação e e-mail confirmado. Bloquear o aluno e a frota, validar autorização e cobertura, normalizar arrays em ordem estável e inserir solicitação `marketplace/pending` com snapshot completo. Auditar `join_request_created` com IDs, origem, turno, sentidos e dias; omitir endereço.

- [ ] **Step 3: Implementar cancelamento**

Bloquear por ID, responder `not_found` para linha invisível, aceitar somente solicitante e status `pending`, mudar para `cancelled` e auditar `join_request_cancelled`. Repetição retorna `invalid_transition`.

- [ ] **Step 4: Implementar projeção do owner**

`list_fleet_join_requests` exige owner ativo e retorna:

```text
id, student_id, student_full_name, school_id, school_name, origin, status,
shift, directions, weekdays, postal_code, street, street_number,
address_complement, neighborhood, city_name, city_ibge_code, state_code,
latitude, longitude, created_at, decided_at
```

Endereço aparece somente para `pending` ou para solicitação com vínculo `active`. Nos demais estados, todas as colunas de endereço e coordenadas retornam `null`. Paginar com limite de 1 a 50, ordenar por `created_at desc, id desc` e permitir filtro de status nulo ou válido.

- [ ] **Step 5: Validar**

Run:

```bash
supabase db reset
supabase test db supabase/tests/database/013_join_requests.test.sql
supabase test db
git diff --check
```

Expected: snapshot imutável, owner restrito ao tenant e endereço limitado à finalidade.

---

### Task 8: Aprovar, rejeitar e encerrar vínculos

**Files:**

- Create: `supabase/tests/database/014_enrollments.test.sql`.
- Create: migration retornada por `supabase migration new create_enrollment_functions`.

**Interfaces:**

- Produces: `decide_fleet_join_request`, `end_fleet_enrollment`.
- Consumes: fontes de papel, responsáveis ativos e solicitação pendente.

- [ ] **Step 1: Escrever testes vermelhos de decisão**

Cobrir owner correto, outro tenant, status não pendente, decisão fora de `approved|rejected`, repetição e UUID conhecido. Na aprovação, provar atomicamente:

- request muda para `approved`;
- enrollment ativo referencia `source_request_id` único;
- adulto recebe fonte/papel `student`;
- todos os responsáveis ativos do menor recebem fonte/papel `guardian`;
- associação `left` é reativada, associação `suspended` permanece suspensa;
- papéis `owner`/`driver` e fontes manuais permanecem;
- segunda aprovação concorrente não cria vínculo duplicado.

- [ ] **Step 2: Implementar decisão com locks estáveis**

Bloquear frota, solicitação e possível vínculo sempre na mesma ordem. Revalidar owner, status e ausência de vínculo ativo dentro do lock. Rejeição atualiza somente decisão e auditoria. Aprovação cria vínculo, fontes, papéis efetivos e auditoria na mesma transação.

- [ ] **Step 3: Escrever teste vermelho de encerramento**

Exigir motivo não vazio e owner da frota. Provar que `ended_at`, `ended_by`, `end_reason` e status mudam juntos; remover fontes do enrollment; manter papéis exigidos por outro enrollment ou por fonte manual; preservar associação; ocultar endereço na listagem.

- [ ] **Step 4: Implementar encerramento**

Bloquear enrollment e frota, aceitar apenas `active`, marcar `ended`, remover fontes daquele enrollment, sincronizar associações atingidas e auditar `enrollment_ended` com ID e `reason_recorded = true`. Limitar o motivo persistido no vínculo a 500 caracteres e não copiá-lo para a auditoria.

- [ ] **Step 5: Validar**

Run:

```bash
supabase db reset
supabase test db supabase/tests/database/014_enrollments.test.sql
supabase test db
git diff --check
```

Expected: vínculo único, decisão atômica e remoção de papel baseada em proveniência.

---

### Task 9: Implementar convite da frota com vínculo direto

**Files:**

- Create: `supabase/tests/database/015_fleet_invitations.test.sql`.
- Create: migration retornada por `supabase migration new create_fleet_invitation_functions`.

**Interfaces:**

- Produces: `create_fleet_invitation`, `get_fleet_invitation`, `accept_fleet_invitation`, `decline_fleet_invitation`, `cancel_fleet_invitation`.
- Result: aceitação cria request `invitation/approved` e enrollment ativo na mesma transação.

- [ ] **Step 1: Escrever testes vermelhos do convite**

Cobrir:

- somente owner ativo cria/cancela;
- papel aceito é `guardian` ou `student`;
- token, hash, normalização, 14 dias e conflito pendente;
- preview anônimo retorna somente frota pública do convite, papel, status e expiração, sem e-mail;
- callback com outro e-mail, e-mail não confirmado ou token inválido falha;
- `guardian` escolhe menor que administra; `student` usa o próprio aluno adulto;
- escola ativa, cobertura de escola e cidade são obrigatórias;
- aceitação cria request aprovada, enrollment, associação, fonte e papel;
- cancelamento, recusa, expiração e repetição respeitam a máquina de estados;
- convite vencido persiste `expired`; aceitação vencida retorna `null` sem criar request ou vínculo.

- [ ] **Step 2: Implementar criação e preview**

Reutilizar a geração/hasheamento de token já usada pelo convite de responsável somente se houver duplicação real. `get_fleet_invitation` localiza por hash, atualiza vencido para `expired` e retorna:

```text
fleet_id, fleet_name, fleet_slug, fleet_logo_path, role, status, expires_at
```

Conceder preview a `anon, authenticated`; comandos somente a `authenticated`.

- [ ] **Step 3: Implementar aceitação direta**

Bloquear convite, frota, aluno e possível vínculo. Validar e-mail, papel, aluno, escola, cobertura, turno, sentidos e dias. Inserir `fleet_join_requests` com origem `invitation`, status `approved`, snapshot do aluno e referência ao convite; criar enrollment e fontes de papel; marcar convite `accepted`. Auditar convite aceito e solicitação aprovada sem PII.

- [ ] **Step 4: Implementar recusa e cancelamento**

Destinatário autenticado com e-mail confirmado recusa convite pendente. Owner da mesma frota cancela convite pendente. Ambas bloqueiam a linha, atualizam datas/ator e auditam estado sem e-mail/token.

- [ ] **Step 5: Validar callback e vínculo**

Run:

```bash
supabase db reset
supabase test db supabase/tests/database/015_fleet_invitations.test.sql
supabase test db
git diff --check
```

Expected: usuário pode autenticar depois de receber o token, voltar ao convite e criar o vínculo direto com o mesmo e-mail confirmado.

---

### Task 10: Fechar auditoria, privacidade e regressão de tenant

**Files:**

- Create: `supabase/tests/database/016_cycle_2_audit_privacy.test.sql`.
- Create: migration retornada por `supabase migration new create_cycle_2_audit` somente se um ajuste de auditoria ainda for necessário.

**Interfaces:**

- Consumes: todos os fluxos do Ciclo 2.
- Produces: prova transversal de isolamento, finalidade e metadados sanitizados.

- [ ] **Step 1: Escrever a matriz de regressão**

Para dois tenants e UUIDs conhecidos, testar:

- owner A não lista, decide, cancela ou encerra recursos da frota B;
- responsável A não lê aluno, convite, request ou vínculo de B;
- `anon` acessa somente buscas e preview de convite por token válido;
- e-mail não confirmado não cria aluno, convite, request ou vínculo;
- endereço some da projeção do owner após rejeição, cancelamento ou encerramento;
- convites não expõem `email` nem `token_hash` por Data API/RPC;
- audit metadata nunca possui chaves `email`, `token`, `token_hash`, `postal_code`, `street`, `latitude`, `longitude` ou payload completo;
- cada ação sensível gera exatamente o evento esperado no tenant correto.

- [ ] **Step 2: Corrigir somente lacunas comprovadas**

Se o RED exigir mudança de schema, criar a migration `create_cycle_2_audit`. Se todos os comportamentos já estiverem cobertos, não criar migration vazia. Nunca editar migrations anteriores.

- [ ] **Step 3: Inspecionar grants, RLS e funções privilegiadas**

Run:

```bash
supabase db reset
supabase test db supabase/tests/database/016_cycle_2_audit_privacy.test.sql
supabase test db
supabase db lint --local --level warning
```

Consultar `pg_proc`, `information_schema.role_table_grants`, `pg_policies` e `pg_class.relrowsecurity` para confirmar:

- RLS habilitada em todas as tabelas novas;
- nenhuma escrita transacional direta;
- nenhum `EXECUTE` público acidental;
- nenhum `security definer` com `search_path` inseguro;
- policies e grants cobrem apenas a matriz aprovada.

- [ ] **Step 4: Verificar ausência de dados e escopo extra**

Run:

```bash
rg -n "Itapetininga|Sorocaba|São Miguel Arcanjo|Sao Miguel Arcanjo|Tatuí|Tatui|Capão Bonito|Capao Bonito|Pilar do Sul" supabase
rg -n "TODO|FIXME|console\.log|service_role" supabase docs/superpowers
git diff --check
```

Expected: nenhuma cidade/instituição real em `supabase`; nenhum segredo, log temporário ou placeholder novo.

---

### Task 11: Atualizar documentação somente após a validação técnica

**Files:**

- Modify: `README.md`.
- Modify: `be-tech-plan.md`.
- Modify: `deliverables.md`.
- Inspect: `docs/research/2026-09-06-catalogo-escolas-brasil.md`.
- Inspect: `docs/superpowers/specs/2026-09-06-ciclo-2-marketplace-vinculos-design.md`.

**Interfaces:**

- Produces: documentação fiel ao estado implementado, sem afirmar carga de catálogo ou app Flutter.

- [ ] **Step 1: Registrar somente fatos verificados**

- README: incluir comandos e recursos realmente entregues, sem instruir inserção manual de dados reais;
- plano técnico: marcar o corte executado e manter importação/carga como decisão futura;
- entregáveis: registrar arquivos, migrations, testes e resultados reais, incluindo limites conhecidos;
- não mudar a spec aprovada para esconder divergências; registrar qualquer diferença deliberada no `deliverables.md`.

- [ ] **Step 2: Revisar consistência do contrato**

Run:

```bash
rg -n "Ciclo 2|schools|fleet_service|student|guardian|join_request|enrollment|invitation" README.md be-tech-plan.md deliverables.md docs/superpowers
git diff --check
```

Expected: nomes, estados, assinaturas e exclusões são consistentes nos quatro documentos.

---

### Task 12: Executar a definição de pronto

**Files:**

- Inspect: todos os arquivos alterados.
- Do not create: configuração, relatório ou artefato de scanner dentro do repositório.

- [ ] **Step 1: Validar banco limpo e suíte completa**

Run:

```bash
supabase db reset
supabase test db
supabase db lint --local --level warning
supabase migration list --local
git diff --check
```

Expected: reset, 17 arquivos de teste (`000` a `016`), lint e migrations verdes.

- [ ] **Step 2: Rodar advisors locais/remotos somente quando configurados**

Executar os advisors disponíveis sem aplicar mudanças automáticas. Separar findings do Ciclo 2 de ruído preexistente. Não fazer deployment remoto.

- [ ] **Step 3: Executar a quality gate obrigatória**

Run antes:

```bash
git status --short --branch
```

Executar `software-quality-gate` em modo somente leitura, com tooling fora do repositório. A gate não pode instalar dependências, alterar manifests/lockfiles, criar testes, gravar configuração nem deixar gerados.

Run depois:

```bash
git status --short --branch
git diff --name-only
git diff --check
```

Expected: a gate não alterou o worktree.

- [ ] **Step 4: Conferir o corte final**

Checklist obrigatório:

- schema e relações existem, mas `schools` permanece vazia;
- nenhuma integração ou carga de instituição foi adicionada;
- requests e convites criam no máximo um vínculo ativo;
- callback depende do mesmo e-mail confirmado;
- endereço e dados de menores obedecem à finalidade;
- papéis derivados são removidos sem apagar papéis manuais ou de outros alunos;
- nenhum commit, push ou deployment foi feito sem nova autorização.

Somente depois desses itens o Ciclo 2 pode ser declarado implementado.
