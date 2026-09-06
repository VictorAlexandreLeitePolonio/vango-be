# Ciclo 1 — Fundação multi-tenant Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implementar a fundação multi-tenant do VanGo com perfis, frotas, associações, múltiplos papéis, auditoria, RLS e três RPCs transacionais.

**Architecture:** O Flutter acessará leituras e atualizações simples pela Data API, sempre com grants mínimos e RLS. Criação de frota e mudanças de associação ou papéis passarão por RPCs PostgreSQL; helpers privilegiados permanecerão no schema `private` e o projeto remoto só receberá migrations depois de toda a validação local.

**Tech Stack:** Supabase Auth, PostgreSQL 17, Data API/PostgREST, PL/pgSQL, RLS, pgTAP, Supabase CLI e Supabase MCP.

**Spec:** `be-tech-plan.md`, seções 4, 8, 9, 12 e 13; `CONTRIBUTING.md`, seções 2 a 7 e 13; decisões aprovadas no brainstorming do Ciclo 1 em 2026-09-05.

**Baseline remoto inspecionado:** em 2026-09-05, o Supabase MCP retornou zero tabelas em `public`/`private`, zero migrations e zero Edge Functions. Revalidar esse baseline antes de qualquer deployment porque ele pode mudar durante a implementação local.

## Global Constraints

- A frota é o tenant e nenhuma operação pode atravessar `fleet_id`.
- O Ciclo 1 cria somente `profiles`, `fleets`, `fleet_memberships`, `fleet_membership_roles` e `audit_events`.
- Novos usuários entram em outras frotas somente no Ciclo 2; neste ciclo, `create_fleet` cria apenas o primeiro owner.
- O trigger de `auth.users` cria um perfil mínimo; `full_name` começa nulo e é preenchido depois pela Data API.
- Acesso anônimo é negado em todas as tabelas e RPCs deste ciclo.
- Data API atende leituras e `PATCH` simples; RPC atende transações, papéis, status e proteção do último owner.
- Não criar Edge Functions, Cron jobs, canais Realtime, buckets, marketplace, vans, rotas, viagens, notificações ou mapa.
- Não confiar em `user_metadata`, papel ou tenant enviados pelo Flutter para autorização.
- Não expor `service_role`, secrets ou credenciais do projeto.
- RLS e grants explícitos devem ser entregues juntos; `authenticated` recebe somente operações e colunas necessárias.
- Funções `security definer` usam `set search_path = ''`, objetos totalmente qualificados e `EXECUTE` revogado por padrão; somente helpers usados por RLS recebem `EXECUTE` de `authenticated`, sem expor o schema `private` na Data API.
- Toda mudança de comportamento segue RED, GREEN e refactor com evidência registrada.
- Criar migrations exclusivamente com `supabase migration new`; nunca inventar timestamps.
- Não editar migrations já aplicadas; correções usam nova migration.
- Implementar e testar localmente antes do checkpoint para o remoto.
- Não fazer commit, push ou deployment remoto sem autorização explícita.
- Antes de declarar o ciclo concluído, executar `software-quality-gate` e verificar `git status` antes e depois.

---

## Contrato aprovado

### Data API

| Recurso | SELECT | INSERT | UPDATE | DELETE |
| --- | --- | --- | --- | --- |
| `profiles` | próprio perfil | negado | próprio `full_name`, `phone`, `avatar_path` | negado |
| `fleets` | associação ativa | negado | owner; colunas administrativas permitidas | negado |
| `fleet_memberships` | próprio vínculo ou owner da frota | negado | negado | negado |
| `fleet_membership_roles` | próprios papéis ou owner da frota | negado | negado | negado |
| `audit_events` | owner da frota | negado | negado | negado |

### RPCs

```text
create_fleet(
  p_name text,
  p_slug text,
  p_description text default null,
  p_logo_path text default null,
  p_status text default 'draft'
) returns uuid

set_fleet_member_roles(
  p_membership_id uuid,
  p_roles text[]
) returns text[]

set_fleet_membership_status(
  p_membership_id uuid,
  p_status text
) returns text
```

### Códigos de erro

| Código | Uso neste ciclo |
| --- | --- |
| `unauthenticated` | JWT ausente ou `auth.uid()` nulo |
| `email_unverified` | criação de frota antes da confirmação do e-mail |
| `forbidden` | usuário sem papel owner no tenant |
| `membership_conflict` | associação inválida ou conjunto de papéis inválido |
| `invalid_input` | nome, slug ou lista de papéis inválida |
| `invalid_status` | status não permitido para a operação |
| `last_owner` | tentativa de remover, suspender ou rebaixar o último owner ativo |
| `slug_conflict` | slug de frota já utilizado |

Erros RPC devem usar erro PostgREST com status HTTP coerente. Sucesso retorna o tipo declarado; não retornar `200` com `success: false`.

---

## Estrutura esperada ao final

```text
supabase/
├── config.toml
├── migrations/
│   ├── <cli>_create_foundation_tables.sql
│   ├── <cli>_create_profile_triggers.sql
│   ├── <cli>_create_authorization_helpers.sql
│   ├── <cli>_create_foundation_rls.sql
│   ├── <cli>_create_fleet_rpc.sql
│   ├── <cli>_create_membership_rpcs.sql
│   └── <cli>_create_foundation_audit.sql
├── seed.sql
└── tests/
    ├── _helpers.psql
    └── database/
        ├── 001_profiles.test.sql
        ├── 002_tenancy_rls.test.sql
        ├── 003_create_fleet.test.sql
        ├── 004_member_roles.test.sql
        ├── 005_membership_status.test.sql
        ├── 006_fleet_updates.test.sql
        └── 007_audit_events.test.sql
```

Cada `<cli>` representa o timestamp real produzido por `supabase migration new`. O executor deve usar o caminho exato retornado pela CLI, sem renomeá-lo manualmente.

---

### Task 1: Revalidar e congelar a base do Ciclo 0

**Files:**

- Inspect: `supabase/config.toml`.
- Inspect: `supabase/migrations/`.
- Inspect: `supabase/tests/database/`.
- Inspect: `deliverables.md`.
- Modify: `supabase/config.toml` somente em `api.auto_expose_new_tables`.

**Interfaces:**

- Consumes: Ciclo 0 implementado e testado por outro fluxo.
- Produces: base local verde e Data API configurada para exigir grants explícitos.

- [ ] **Step 1: Aguardar o encerramento do trabalho concorrente do Ciclo 0**

Não editar `supabase/` enquanto outro processo estiver implementando ou testando o Ciclo 0. Prosseguir somente quando não houver escrita concorrente.

- [ ] **Step 2: Inspecionar o resultado real sem restaurar ou sobrescrever arquivos**

Run:

```bash
git status --short --branch
rg --files supabase -g '!**/.temp/**' -g '!**/.branches/**' | sort
supabase --version
supabase status
```

Expected: estrutura do Ciclo 0 presente, stack local ativa ou pronta para subir e mudanças concorrentes preservadas.

- [ ] **Step 3: Validar o Ciclo 0 antes de construir sobre ele**

Run:

```bash
supabase db reset
supabase test db
supabase migration list --local
```

Expected: reset e testes passam; migrations registradas correspondem ao `deliverables.md`.

- [ ] **Step 4: Exigir grants explícitos no ambiente local**

Em `supabase/config.toml`, definir:

```toml
[api]
auto_expose_new_tables = false
```

Preservar as demais chaves geradas pela CLI.

- [ ] **Step 5: Recriar o ambiente com a configuração endurecida**

Run:

```bash
supabase stop
supabase start
supabase db reset
supabase test db
```

Expected: stack e testes continuam verdes com exposição automática desativada.

---

### Task 2: Criar as cinco tabelas, constraints e índices

**Files:**

- Create: `supabase/tests/_helpers.psql`.
- Create: `supabase/tests/database/001_profiles.test.sql`.
- Create: migration gerada por `supabase migration new create_foundation_tables`.

**Interfaces:**

- Consumes: schema `private` e pgTAP disponíveis pelo Ciclo 0.
- Produces: cinco tabelas relacionais sem rotas liberadas ao cliente.

- [ ] **Step 1: Criar o helper local de usuários de teste**

Create `supabase/tests/_helpers.psql` with:

```sql
create or replace function pg_temp.create_test_user(
  p_id uuid,
  p_email text,
  p_confirmed boolean default true
) returns void
language sql
as $$
  insert into auth.users (
    instance_id,
    id,
    aud,
    role,
    email,
    encrypted_password,
    email_confirmed_at,
    raw_app_meta_data,
    raw_user_meta_data,
    created_at,
    updated_at
  ) values (
    '00000000-0000-0000-0000-000000000000',
    p_id,
    'authenticated',
    'authenticated',
    p_email,
    extensions.crypt('local-test-password', extensions.gen_salt('bf')),
    case when p_confirmed then now() else null end,
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{}'::jsonb,
    now(),
    now()
  );
$$;

create or replace function pg_temp.seed_foundation()
returns void
language plpgsql
as $$
begin
  perform pg_temp.create_test_user('40000000-0000-0000-0000-000000000001', 'owner-a1@example.test');
  perform pg_temp.create_test_user('40000000-0000-0000-0000-000000000002', 'owner-a2@example.test');
  perform pg_temp.create_test_user('40000000-0000-0000-0000-000000000003', 'driver-a@example.test');
  perform pg_temp.create_test_user('40000000-0000-0000-0000-000000000004', 'guardian-a@example.test');
  perform pg_temp.create_test_user('40000000-0000-0000-0000-000000000005', 'owner-b@example.test');

  insert into public.fleets (id, name, slug, created_by)
  values
    ('41000000-0000-0000-0000-000000000001', 'Fleet A', 'fleet-a', '40000000-0000-0000-0000-000000000001'),
    ('41000000-0000-0000-0000-000000000002', 'Fleet B', 'fleet-b', '40000000-0000-0000-0000-000000000005');

  insert into public.fleet_memberships (id, fleet_id, user_id)
  values
    ('42000000-0000-0000-0000-000000000001', '41000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000001'),
    ('42000000-0000-0000-0000-000000000002', '41000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000002'),
    ('42000000-0000-0000-0000-000000000003', '41000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000003'),
    ('42000000-0000-0000-0000-000000000004', '41000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000004'),
    ('42000000-0000-0000-0000-000000000005', '41000000-0000-0000-0000-000000000002', '40000000-0000-0000-0000-000000000005');

  insert into public.fleet_membership_roles (membership_id, role)
  values
    ('42000000-0000-0000-0000-000000000001', 'owner'),
    ('42000000-0000-0000-0000-000000000002', 'owner'),
    ('42000000-0000-0000-0000-000000000003', 'driver'),
    ('42000000-0000-0000-0000-000000000004', 'guardian'),
    ('42000000-0000-0000-0000-000000000005', 'owner');
end;
$$;
```

- [ ] **Step 2: Escrever o primeiro teste estrutural RED**

Create `supabase/tests/database/001_profiles.test.sql` with:

```sql
begin;

create extension if not exists pgtap with schema extensions;

select plan(5);

select has_table('public', 'profiles', 'profiles table exists');
select has_table('public', 'fleets', 'fleets table exists');
select has_table('public', 'fleet_memberships', 'fleet memberships table exists');
select has_table('public', 'fleet_membership_roles', 'membership roles table exists');
select has_table('public', 'audit_events', 'audit events table exists');

select * from finish();

rollback;
```

- [ ] **Step 3: Executar e confirmar RED**

Run:

```bash
supabase test db supabase/tests/database/001_profiles.test.sql
```

Expected: FAIL porque as cinco tabelas ainda não existem.

- [ ] **Step 4: Criar a migration pela CLI**

Run:

```bash
supabase migration new create_foundation_tables
```

Expected: a CLI retorna o caminho que receberá o DDL abaixo.

- [ ] **Step 5: Criar `profiles` e `fleets`**

Write in the generated migration:

```sql
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text,
  phone text,
  avatar_path text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint profiles_full_name_not_blank
    check (full_name is null or btrim(full_name) <> '')
);

create table public.fleets (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  slug text not null,
  description text,
  logo_path text,
  status text not null default 'draft',
  created_by uuid not null references public.profiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint fleets_name_not_blank check (btrim(name) <> ''),
  constraint fleets_slug_format check (slug ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'),
  constraint fleets_slug_unique unique (slug),
  constraint fleets_status_valid check (status in ('draft', 'published', 'suspended', 'archived'))
);
```

- [ ] **Step 6: Criar associações, papéis e auditoria**

Append to the same migration:

```sql
create table public.fleet_memberships (
  id uuid primary key default gen_random_uuid(),
  fleet_id uuid not null references public.fleets(id) on delete restrict,
  user_id uuid not null references public.profiles(id) on delete restrict,
  status text not null default 'active',
  joined_at timestamptz not null default now(),
  suspended_at timestamptz,
  left_at timestamptz,
  constraint fleet_memberships_user_unique unique (fleet_id, user_id),
  constraint fleet_memberships_status_valid check (status in ('active', 'suspended', 'left')),
  constraint fleet_memberships_status_dates_valid check (
    (status = 'active' and suspended_at is null and left_at is null)
    or (status = 'suspended' and suspended_at is not null and left_at is null)
    or (status = 'left' and suspended_at is null and left_at is not null)
  )
);

create table public.fleet_membership_roles (
  membership_id uuid not null references public.fleet_memberships(id) on delete cascade,
  role text not null,
  constraint fleet_membership_roles_pkey primary key (membership_id, role),
  constraint fleet_membership_roles_role_valid check (role in ('owner', 'driver', 'guardian', 'student'))
);

create table public.audit_events (
  id uuid primary key default gen_random_uuid(),
  fleet_id uuid not null references public.fleets(id) on delete restrict,
  actor_user_id uuid references public.profiles(id) on delete set null,
  action text not null,
  entity_type text not null,
  entity_id uuid not null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  constraint audit_events_action_valid check (
    action in (
      'fleet_created',
      'fleet_updated',
      'member_roles_changed',
      'membership_status_changed'
    )
  ),
  constraint audit_events_entity_type_valid check (
    entity_type in ('fleet', 'fleet_membership')
  ),
  constraint audit_events_metadata_object check (jsonb_typeof(metadata) = 'object')
);

create index fleet_memberships_user_id_idx on public.fleet_memberships(user_id);
create index fleet_memberships_fleet_id_status_idx on public.fleet_memberships(fleet_id, status);
create index fleet_membership_roles_role_idx on public.fleet_membership_roles(role, membership_id);
create index audit_events_fleet_id_created_at_idx on public.audit_events(fleet_id, created_at desc);
create index audit_events_actor_user_id_idx on public.audit_events(actor_user_id);
```

- [ ] **Step 7: Aplicar do zero e confirmar GREEN estrutural**

Run:

```bash
supabase db reset
supabase test db supabase/tests/database/001_profiles.test.sql
```

Expected: 5 testes passam.

---

### Task 3: Criar o perfil mínimo e timestamps automáticos

**Files:**

- Modify: `supabase/tests/database/001_profiles.test.sql`.
- Create: migration gerada por `supabase migration new create_profile_triggers`.

**Interfaces:**

- Consumes: `auth.users`, `public.profiles` e schema `private`.
- Produces: perfil mínimo após cadastro e timestamps atualizados no banco.

- [ ] **Step 1: Acrescentar testes de comportamento ao arquivo de profiles**

Substituir o plano por 9 e adicionar antes de `finish()`:

```sql
\ir ../_helpers.psql

select pg_temp.create_test_user(
  '10000000-0000-0000-0000-000000000001',
  'profile-owner@example.test',
  false
);

select ok(
  exists (
    select 1
    from public.profiles
    where id = '10000000-0000-0000-0000-000000000001'
      and full_name is null
  ),
  'auth user receives a minimal profile'
);

select is(
  (
    select count(*)::integer
    from public.profiles
    where id = '10000000-0000-0000-0000-000000000001'
  ),
  1,
  'profile trigger creates exactly one row'
);

select throws_ok(
  $$update public.profiles set full_name = '   '
    where id = '10000000-0000-0000-0000-000000000001'$$,
  '23514',
  null,
  'blank full name is rejected'
);

select ok(
  (
    select created_at = updated_at
    from public.profiles
    where id = '10000000-0000-0000-0000-000000000001'
  ),
  'new profile starts with matching timestamps'
);
```

- [ ] **Step 2: Confirmar RED pela ausência do trigger**

Run:

```bash
supabase test db supabase/tests/database/001_profiles.test.sql
```

Expected: FAIL porque inserir em `auth.users` ainda não cria `profiles`.

- [ ] **Step 3: Criar a migration de triggers**

Run:

```bash
supabase migration new create_profile_triggers
```

- [ ] **Step 4: Implementar os triggers mínimos**

Write in the generated migration:

```sql
create function private.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := clock_timestamp();
  return new;
end;
$$;

create trigger profiles_set_updated_at
before update on public.profiles
for each row execute function private.set_updated_at();

create trigger fleets_set_updated_at
before update on public.fleets
for each row execute function private.set_updated_at();

create function private.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id)
  values (new.id);

  return new;
end;
$$;

revoke execute on function private.handle_new_user() from public, anon, authenticated;

create trigger on_auth_user_created
after insert on auth.users
for each row execute function private.handle_new_user();
```

- [ ] **Step 5: Recriar e confirmar GREEN**

Run:

```bash
supabase db reset
supabase test db supabase/tests/database/001_profiles.test.sql
```

Expected: 9 testes passam.

---

### Task 4: Criar helpers privados, grants e RLS

**Files:**

- Create: `supabase/tests/database/002_tenancy_rls.test.sql`.
- Create: migration gerada por `supabase migration new create_authorization_helpers`.
- Create: migration gerada por `supabase migration new create_foundation_rls`.

**Interfaces:**

- Consumes: cinco tabelas da fundação e perfis automáticos.
- Produces: leitura isolada por tenant, updates próprios e helpers reutilizáveis pelas RPCs.

- [ ] **Step 1: Criar o teste de isolamento**

Create `supabase/tests/database/002_tenancy_rls.test.sql` with:

```sql
begin;

create extension if not exists pgtap with schema extensions;
\ir ../_helpers.psql

select plan(8);

select pg_temp.create_test_user('20000000-0000-0000-0000-000000000001', 'owner-a@example.test');
select pg_temp.create_test_user('20000000-0000-0000-0000-000000000002', 'member-a@example.test');
select pg_temp.create_test_user('20000000-0000-0000-0000-000000000003', 'owner-b@example.test');

insert into public.fleets (id, name, slug, created_by)
values
  ('21000000-0000-0000-0000-000000000001', 'Fleet A', 'fleet-a', '20000000-0000-0000-0000-000000000001'),
  ('21000000-0000-0000-0000-000000000002', 'Fleet B', 'fleet-b', '20000000-0000-0000-0000-000000000003');

insert into public.fleet_memberships (id, fleet_id, user_id)
values
  ('22000000-0000-0000-0000-000000000001', '21000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001'),
  ('22000000-0000-0000-0000-000000000002', '21000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000002'),
  ('22000000-0000-0000-0000-000000000003', '21000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000003');

insert into public.fleet_membership_roles (membership_id, role)
values
  ('22000000-0000-0000-0000-000000000001', 'owner'),
  ('22000000-0000-0000-0000-000000000002', 'driver'),
  ('22000000-0000-0000-0000-000000000002', 'guardian'),
  ('22000000-0000-0000-0000-000000000003', 'owner');

select set_config(
  'request.jwt.claims',
  '{"sub":"20000000-0000-0000-0000-000000000002","role":"authenticated"}',
  true
);
set local role authenticated;

select is((select count(*)::integer from public.profiles), 1, 'member reads only own profile');
select is((select count(*)::integer from public.fleets), 1, 'member reads only own fleet');
select is((select count(*)::integer from public.fleet_memberships), 1, 'member reads only own membership');
select is((select count(*)::integer from public.fleet_membership_roles), 2, 'member reads own roles');

update public.profiles
set full_name = 'Member A'
where id = '20000000-0000-0000-0000-000000000002';

select is((select full_name from public.profiles), 'Member A', 'member updates own profile');

select throws_ok(
  $$insert into public.fleets (name, slug, created_by)
    values ('Blocked', 'blocked', '20000000-0000-0000-0000-000000000002')$$,
  '42501',
  null,
  'direct fleet insert is denied'
);

select is((select count(*)::integer from public.audit_events), 0, 'non-owner reads no audit events');

reset role;
select set_config('request.jwt.claims', '', true);
set local role anon;
select throws_ok(
  $$select count(*) from public.fleets$$,
  '42501',
  null,
  'anonymous cannot read fleets'
);

select * from finish();

rollback;
```

- [ ] **Step 2: Confirmar RED de grants ou RLS ausentes**

Run:

```bash
supabase test db supabase/tests/database/002_tenancy_rls.test.sql
```

Expected: FAIL porque helpers, grants e policies ainda não existem.

- [ ] **Step 3: Criar helpers de autorização**

Run:

```bash
supabase migration new create_authorization_helpers
```

Write in the generated migration:

```sql
create function private.is_active_fleet_member(
  p_fleet_id uuid,
  p_user_id uuid
) returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.fleet_memberships fm
    where fm.fleet_id = p_fleet_id
      and fm.user_id = p_user_id
      and fm.status = 'active'
  );
$$;

create function private.has_fleet_role(
  p_fleet_id uuid,
  p_user_id uuid,
  p_role text
) returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.fleet_memberships fm
    join public.fleet_membership_roles fmr on fmr.membership_id = fm.id
    where fm.fleet_id = p_fleet_id
      and fm.user_id = p_user_id
      and fm.status = 'active'
      and fmr.role = p_role
  );
$$;

create function private.is_last_active_owner(p_membership_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select
    exists (
      select 1
      from public.fleet_membership_roles current_role
      where current_role.membership_id = p_membership_id
        and current_role.role = 'owner'
    )
    and (
      select count(*)
      from public.fleet_memberships fm
      join public.fleet_membership_roles fmr on fmr.membership_id = fm.id
      where fm.fleet_id = (
        select target.fleet_id
        from public.fleet_memberships target
        where target.id = p_membership_id
      )
        and fm.status = 'active'
        and fmr.role = 'owner'
    ) = 1;
$$;

revoke execute on function private.is_active_fleet_member(uuid, uuid) from public, anon, authenticated;
revoke execute on function private.has_fleet_role(uuid, uuid, text) from public, anon, authenticated;
revoke execute on function private.is_last_active_owner(uuid) from public, anon, authenticated;
```

- [ ] **Step 4: Criar grants mínimos e policies**

Run:

```bash
supabase migration new create_foundation_rls
```

Write in the generated migration:

```sql
alter table public.profiles enable row level security;
alter table public.fleets enable row level security;
alter table public.fleet_memberships enable row level security;
alter table public.fleet_membership_roles enable row level security;
alter table public.audit_events enable row level security;

revoke all on table public.profiles from anon, authenticated;
revoke all on table public.fleets from anon, authenticated;
revoke all on table public.fleet_memberships from anon, authenticated;
revoke all on table public.fleet_membership_roles from anon, authenticated;
revoke all on table public.audit_events from anon, authenticated;

grant select on table public.profiles to authenticated;
grant update (full_name, phone, avatar_path) on table public.profiles to authenticated;
grant select on table public.fleets to authenticated;
grant update (name, slug, description, logo_path, status) on table public.fleets to authenticated;
grant select on table public.fleet_memberships to authenticated;
grant select on table public.fleet_membership_roles to authenticated;
grant select on table public.audit_events to authenticated;

grant usage on schema private to authenticated;
grant execute on function private.is_active_fleet_member(uuid, uuid) to authenticated;
grant execute on function private.has_fleet_role(uuid, uuid, text) to authenticated;

create policy profiles_select_own
on public.profiles for select
to authenticated
using ((select auth.uid()) = id);

create policy profiles_update_own
on public.profiles for update
to authenticated
using ((select auth.uid()) = id)
with check ((select auth.uid()) = id);

create policy fleets_select_active_members
on public.fleets for select
to authenticated
using (private.is_active_fleet_member(id, (select auth.uid())));

create policy fleets_update_owners
on public.fleets for update
to authenticated
using (private.has_fleet_role(id, (select auth.uid()), 'owner'))
with check (
  private.has_fleet_role(id, (select auth.uid()), 'owner')
  and status in ('draft', 'published', 'archived')
);

create policy memberships_select_own_or_owner
on public.fleet_memberships for select
to authenticated
using (
  user_id = (select auth.uid())
  or private.has_fleet_role(fleet_id, (select auth.uid()), 'owner')
);

create policy membership_roles_select_own_or_owner
on public.fleet_membership_roles for select
to authenticated
using (
  exists (
    select 1
    from public.fleet_memberships fm
    where fm.id = membership_id
      and (
        fm.user_id = (select auth.uid())
        or private.has_fleet_role(fm.fleet_id, (select auth.uid()), 'owner')
      )
  )
);

create policy audit_events_select_owners
on public.audit_events for select
to authenticated
using (private.has_fleet_role(fleet_id, (select auth.uid()), 'owner'));
```

- [ ] **Step 5: Recriar e confirmar GREEN**

Run:

```bash
supabase db reset
supabase test db supabase/tests/database/002_tenancy_rls.test.sql
```

Expected: 8 testes passam e nenhum usuário enxerga o tenant B por UUID conhecido.

---

### Task 5: Implementar `create_fleet`

**Files:**

- Create: `supabase/tests/database/003_create_fleet.test.sql`.
- Create: migration gerada por `supabase migration new create_fleet_rpc`.

**Interfaces:**

- Consumes: perfis automáticos, tabelas, helpers e grants.
- Produces: `public.create_fleet(...) returns uuid` para usuários autenticados com e-mail confirmado.

- [ ] **Step 1: Escrever testes RED da criação transacional**

Create `supabase/tests/database/003_create_fleet.test.sql` covering these exact assertions:

```sql
begin;

create extension if not exists pgtap with schema extensions;
\ir ../_helpers.psql

select plan(7);

select pg_temp.create_test_user('30000000-0000-0000-0000-000000000001', 'confirmed@example.test', true);
select pg_temp.create_test_user('30000000-0000-0000-0000-000000000002', 'unconfirmed@example.test', false);

select set_config(
  'request.jwt.claims',
  '{"sub":"30000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
set local role authenticated;

select lives_ok(
  $$select public.create_fleet('Fleet One', 'fleet-one', null, null, 'draft')$$,
  'confirmed user creates a fleet'
);

select is((select count(*)::integer from public.fleets), 1, 'one fleet is created');
select is((select count(*)::integer from public.fleet_memberships), 1, 'one membership is created');
select is((select count(*)::integer from public.fleet_membership_roles where role = 'owner'), 1, 'first owner role is created');
select is((select count(*)::integer from public.audit_events where action = 'fleet_created'), 1, 'creation is audited');

reset role;
select set_config(
  'request.jwt.claims',
  '{"sub":"30000000-0000-0000-0000-000000000002","role":"authenticated"}',
  true
);
set local role authenticated;

select throws_ok(
  $$select public.create_fleet('Blocked', 'blocked', null, null, 'draft')$$,
  'PGRST',
  null,
  'unconfirmed email is rejected'
);

reset role;
set local role anon;
select throws_ok(
  $$select public.create_fleet('Anonymous', 'anonymous', null, null, 'draft')$$,
  '42501',
  null,
  'anonymous cannot execute create_fleet'
);

select * from finish();

rollback;
```

- [ ] **Step 2: Confirmar RED pela função ausente**

Run:

```bash
supabase test db supabase/tests/database/003_create_fleet.test.sql
```

Expected: FAIL porque `public.create_fleet` não existe.

- [ ] **Step 3: Criar a migration da RPC**

Run:

```bash
supabase migration new create_fleet_rpc
```

- [ ] **Step 4: Implementar validação e transação**

Write in the generated migration:

```sql
create function public.create_fleet(
  p_name text,
  p_slug text,
  p_description text default null,
  p_logo_path text default null,
  p_status text default 'draft'
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_email_confirmed boolean;
  v_fleet_id uuid;
  v_membership_id uuid;
begin
  if v_user_id is null then
    raise sqlstate 'PGRST' using
      message = jsonb_build_object('code', 'unauthenticated', 'message', 'Authentication required')::text,
      detail = jsonb_build_object('status', 401)::text;
  end if;

  select u.email_confirmed_at is not null
  into v_email_confirmed
  from auth.users u
  where u.id = v_user_id;

  if v_email_confirmed is not true then
    raise sqlstate 'PGRST' using
      message = jsonb_build_object('code', 'email_unverified', 'message', 'Email confirmation required')::text,
      detail = jsonb_build_object('status', 403)::text;
  end if;

  if p_name is null or btrim(p_name) = ''
    or p_slug is null
    or p_slug !~ '^[a-z0-9]+(?:-[a-z0-9]+)*$' then
    raise sqlstate 'PGRST' using
      message = jsonb_build_object('code', 'invalid_input', 'message', 'Invalid fleet name or slug')::text,
      detail = jsonb_build_object('status', 400)::text;
  end if;

  if p_status is null or p_status not in ('draft', 'published') then
    raise sqlstate 'PGRST' using
      message = jsonb_build_object('code', 'invalid_status', 'message', 'Invalid initial fleet status')::text,
      detail = jsonb_build_object('status', 400)::text;
  end if;

  insert into public.fleets (
    name,
    slug,
    description,
    logo_path,
    status,
    created_by
  ) values (
    btrim(p_name),
    p_slug,
    p_description,
    p_logo_path,
    p_status,
    v_user_id
  )
  returning id into v_fleet_id;

  insert into public.fleet_memberships (fleet_id, user_id)
  values (v_fleet_id, v_user_id)
  returning id into v_membership_id;

  insert into public.fleet_membership_roles (membership_id, role)
  values (v_membership_id, 'owner');

  insert into public.audit_events (
    fleet_id,
    actor_user_id,
    action,
    entity_type,
    entity_id
  ) values (
    v_fleet_id,
    v_user_id,
    'fleet_created',
    'fleet',
    v_fleet_id
  );

  return v_fleet_id;
exception
  when unique_violation then
    raise sqlstate 'PGRST' using
      message = jsonb_build_object('code', 'slug_conflict', 'message', 'Fleet slug already exists')::text,
      detail = jsonb_build_object('status', 409)::text;
end;
$$;

revoke execute on function public.create_fleet(text, text, text, text, text) from public, anon;
grant execute on function public.create_fleet(text, text, text, text, text) to authenticated;
```

- [ ] **Step 5: Confirmar GREEN e atomicidade**

Run:

```bash
supabase db reset
supabase test db supabase/tests/database/003_create_fleet.test.sql
```

Expected: 7 testes passam; qualquer erro anterior ao retorno desfaz todas as inserções.

---

### Task 6: Implementar mudanças de papéis e status

**Files:**

- Create: `supabase/tests/database/004_member_roles.test.sql`.
- Create: `supabase/tests/database/005_membership_status.test.sql`.
- Create: migration gerada por `supabase migration new create_membership_rpcs`.

**Interfaces:**

- Consumes: associações existentes, papel owner e helper `private.is_last_active_owner`.
- Produces: `set_fleet_member_roles(...) returns text[]` e `set_fleet_membership_status(...) returns text`.

- [ ] **Step 1: Escrever o teste RED de papéis**

Create `supabase/tests/database/004_member_roles.test.sql` with:

```sql
begin;

create extension if not exists pgtap with schema extensions;
\ir ../_helpers.psql

select plan(7);
select pg_temp.seed_foundation();

select set_config(
  'request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
set local role authenticated;

select lives_ok(
  $$select public.set_fleet_member_roles(
    '42000000-0000-0000-0000-000000000003',
    array['guardian', 'driver']::text[]
  )$$,
  'owner replaces roles of an existing membership'
);

select results_eq(
  $$select role from public.fleet_membership_roles
    where membership_id = '42000000-0000-0000-0000-000000000003'
    order by role$$,
  $$values ('driver'::text), ('guardian'::text)$$,
  'roles are persisted without losing order-independent membership'
);

select throws_ok(
  $$select public.set_fleet_member_roles(
    '42000000-0000-0000-0000-000000000003',
    array['driver', 'driver']::text[]
  )$$,
  'PGRST', null, 'duplicate roles are rejected'
);

select throws_ok(
  $$select public.set_fleet_member_roles(
    '42000000-0000-0000-0000-000000000003',
    array[]::text[]
  )$$,
  'PGRST', null, 'empty roles are rejected'
);

reset role;
select set_config(
  'request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000003","role":"authenticated"}',
  true
);
set local role authenticated;

select throws_ok(
  $$select public.set_fleet_member_roles(
    '42000000-0000-0000-0000-000000000004',
    array['student']::text[]
  )$$,
  'PGRST', null, 'non-owner cannot change roles'
);

reset role;
select set_config(
  'request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
set local role authenticated;

select lives_ok(
  $$select public.set_fleet_member_roles(
    '42000000-0000-0000-0000-000000000002',
    array['driver']::text[]
  )$$,
  'one of two owners can lose owner role'
);

select throws_ok(
  $$select public.set_fleet_member_roles(
    '42000000-0000-0000-0000-000000000001',
    array['driver']::text[]
  )$$,
  'PGRST', null, 'last active owner cannot lose owner role'
);

select * from finish();
rollback;
```

- [ ] **Step 2: Escrever o teste RED de status**

Create `supabase/tests/database/005_membership_status.test.sql` with:

```sql
begin;

create extension if not exists pgtap with schema extensions;
\ir ../_helpers.psql

select plan(7);
select pg_temp.seed_foundation();

select set_config(
  'request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
set local role authenticated;

select lives_ok(
  $$select public.set_fleet_membership_status(
    '42000000-0000-0000-0000-000000000003', 'suspended'
  )$$,
  'owner suspends an existing member'
);

select ok(
  (select status = 'suspended' and suspended_at is not null and left_at is null
   from public.fleet_memberships
   where id = '42000000-0000-0000-0000-000000000003'),
  'suspension timestamps are coherent'
);

select lives_ok(
  $$select public.set_fleet_membership_status(
    '42000000-0000-0000-0000-000000000003', 'active'
  )$$,
  'owner reactivates a member'
);

select ok(
  (select status = 'active' and suspended_at is null and left_at is null
   from public.fleet_memberships
   where id = '42000000-0000-0000-0000-000000000003'),
  'reactivation clears status timestamps'
);

select lives_ok(
  $$select public.set_fleet_membership_status(
    '42000000-0000-0000-0000-000000000003', 'left'
  )$$,
  'owner marks a member as left'
);

reset role;
select set_config(
  'request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000004","role":"authenticated"}',
  true
);
set local role authenticated;

select throws_ok(
  $$select public.set_fleet_membership_status(
    '42000000-0000-0000-0000-000000000003', 'active'
  )$$,
  'PGRST', null, 'non-owner cannot change membership status'
);

reset role;
select set_config(
  'request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
set local role authenticated;

select public.set_fleet_membership_status(
  '42000000-0000-0000-0000-000000000002', 'suspended'
);

select throws_ok(
  $$select public.set_fleet_membership_status(
    '42000000-0000-0000-0000-000000000001', 'suspended'
  )$$,
  'PGRST', null, 'last active owner cannot be suspended'
);

select * from finish();
rollback;
```

- [ ] **Step 3: Confirmar RED das duas funções ausentes**

Run:

```bash
supabase test db supabase/tests/database/004_member_roles.test.sql
supabase test db supabase/tests/database/005_membership_status.test.sql
```

Expected: ambos falham pela ausência das RPCs.

- [ ] **Step 4: Criar a migration das RPCs de associação**

Run:

```bash
supabase migration new create_membership_rpcs
```

- [ ] **Step 5: Implementar `set_fleet_member_roles`**

Write in the generated migration:

```sql
create function public.set_fleet_member_roles(
  p_membership_id uuid,
  p_roles text[]
) returns text[]
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_fleet_id uuid;
  v_membership_status text;
  v_old_roles text[];
  v_new_roles text[];
begin
  if v_user_id is null then
    raise sqlstate 'PGRST' using
      message = jsonb_build_object('code', 'unauthenticated', 'message', 'Authentication required')::text,
      detail = jsonb_build_object('status', 401)::text;
  end if;

  select fm.fleet_id, fm.status
  into v_fleet_id, v_membership_status
  from public.fleet_memberships fm
  where fm.id = p_membership_id
  for update;

  if not found then
    raise sqlstate 'PGRST' using
      message = jsonb_build_object('code', 'membership_conflict', 'message', 'Membership not found')::text,
      detail = jsonb_build_object('status', 404)::text;
  end if;

  if v_membership_status <> 'active' then
    raise sqlstate 'PGRST' using
      message = jsonb_build_object('code', 'membership_conflict', 'message', 'Roles require an active membership')::text,
      detail = jsonb_build_object('status', 409)::text;
  end if;

  perform 1 from public.fleets f where f.id = v_fleet_id for update;

  if not private.has_fleet_role(v_fleet_id, v_user_id, 'owner') then
    raise sqlstate 'PGRST' using
      message = jsonb_build_object('code', 'forbidden', 'message', 'Owner role required')::text,
      detail = jsonb_build_object('status', 403)::text;
  end if;

  if p_roles is null or cardinality(p_roles) = 0 or array_position(p_roles, null) is not null then
    raise sqlstate 'PGRST' using
      message = jsonb_build_object('code', 'invalid_input', 'message', 'At least one role is required')::text,
      detail = jsonb_build_object('status', 400)::text;
  end if;

  select array_agg(distinct requested.role order by requested.role)
  into v_new_roles
  from unnest(p_roles) as requested(role);

  if cardinality(v_new_roles) <> cardinality(p_roles)
    or exists (
      select 1
      from unnest(v_new_roles) as requested(role)
      where requested.role not in ('owner', 'driver', 'guardian', 'student')
    ) then
    raise sqlstate 'PGRST' using
      message = jsonb_build_object('code', 'invalid_input', 'message', 'Roles must be unique and valid')::text,
      detail = jsonb_build_object('status', 400)::text;
  end if;

  select coalesce(array_agg(fmr.role order by fmr.role), array[]::text[])
  into v_old_roles
  from public.fleet_membership_roles fmr
  where fmr.membership_id = p_membership_id;

  if 'owner' = any(v_old_roles)
    and not ('owner' = any(v_new_roles))
    and private.is_last_active_owner(p_membership_id) then
    raise sqlstate 'PGRST' using
      message = jsonb_build_object('code', 'last_owner', 'message', 'The last active owner cannot be removed')::text,
      detail = jsonb_build_object('status', 409)::text;
  end if;

  delete from public.fleet_membership_roles
  where membership_id = p_membership_id;

  insert into public.fleet_membership_roles (membership_id, role)
  select p_membership_id, requested.role
  from unnest(v_new_roles) as requested(role);

  insert into public.audit_events (
    fleet_id, actor_user_id, action, entity_type, entity_id, metadata
  ) values (
    v_fleet_id,
    v_user_id,
    'member_roles_changed',
    'fleet_membership',
    p_membership_id,
    jsonb_build_object('previous_roles', v_old_roles, 'new_roles', v_new_roles)
  );

  return v_new_roles;
end;
$$;
```

- [ ] **Step 6: Implementar `set_fleet_membership_status`**

Append to the same migration:

```sql
create function public.set_fleet_membership_status(
  p_membership_id uuid,
  p_status text
) returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_fleet_id uuid;
  v_old_status text;
begin
  if v_user_id is null then
    raise sqlstate 'PGRST' using
      message = jsonb_build_object('code', 'unauthenticated', 'message', 'Authentication required')::text,
      detail = jsonb_build_object('status', 401)::text;
  end if;

  if p_status is null or p_status not in ('active', 'suspended', 'left') then
    raise sqlstate 'PGRST' using
      message = jsonb_build_object('code', 'invalid_status', 'message', 'Invalid membership status')::text,
      detail = jsonb_build_object('status', 400)::text;
  end if;

  select fm.fleet_id, fm.status
  into v_fleet_id, v_old_status
  from public.fleet_memberships fm
  where fm.id = p_membership_id
  for update;

  if not found then
    raise sqlstate 'PGRST' using
      message = jsonb_build_object('code', 'membership_conflict', 'message', 'Membership not found')::text,
      detail = jsonb_build_object('status', 404)::text;
  end if;

  perform 1 from public.fleets f where f.id = v_fleet_id for update;

  if not private.has_fleet_role(v_fleet_id, v_user_id, 'owner') then
    raise sqlstate 'PGRST' using
      message = jsonb_build_object('code', 'forbidden', 'message', 'Owner role required')::text,
      detail = jsonb_build_object('status', 403)::text;
  end if;

  if p_status <> 'active' and private.is_last_active_owner(p_membership_id) then
    raise sqlstate 'PGRST' using
      message = jsonb_build_object('code', 'last_owner', 'message', 'The last active owner cannot leave or be suspended')::text,
      detail = jsonb_build_object('status', 409)::text;
  end if;

  update public.fleet_memberships
  set status = p_status,
      suspended_at = case when p_status = 'suspended' then now() else null end,
      left_at = case when p_status = 'left' then now() else null end
  where id = p_membership_id;

  if v_old_status is distinct from p_status then
    insert into public.audit_events (
      fleet_id, actor_user_id, action, entity_type, entity_id, metadata
    ) values (
      v_fleet_id,
      v_user_id,
      'membership_status_changed',
      'fleet_membership',
      p_membership_id,
      jsonb_build_object('previous_status', v_old_status, 'new_status', p_status)
    );
  end if;

  return p_status;
end;
$$;

revoke execute on function public.set_fleet_member_roles(uuid, text[]) from public, anon;
revoke execute on function public.set_fleet_membership_status(uuid, text) from public, anon;
grant execute on function public.set_fleet_member_roles(uuid, text[]) to authenticated;
grant execute on function public.set_fleet_membership_status(uuid, text) to authenticated;
```

- [ ] **Step 7: Confirmar GREEN e executar a suíte acumulada**

Run:

```bash
supabase db reset
supabase test db
```

Expected: testes 001 a 005 passam, inclusive a proteção do último owner ativo; o lock da frota serializa mudanças concorrentes sobre owners.

---

### Task 7: Auditar updates da frota e tornar auditoria imutável

**Files:**

- Create: `supabase/tests/database/006_fleet_updates.test.sql`.
- Create: `supabase/tests/database/007_audit_events.test.sql`.
- Create: migration gerada por `supabase migration new create_foundation_audit`.

**Interfaces:**

- Consumes: policy de update de fleet e `audit_events`.
- Produces: auditoria sanitizada para `PATCH` e bloqueio explícito de mutações em eventos.

- [ ] **Step 1: Escrever teste RED de updates da frota**

Create `supabase/tests/database/006_fleet_updates.test.sql` with:

```sql
begin;

create extension if not exists pgtap with schema extensions;
\ir ../_helpers.psql

select plan(9);
select pg_temp.seed_foundation();

select set_config(
  'request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
set local role authenticated;

select lives_ok(
  $$update public.fleets
    set name = 'Fleet A Updated',
        slug = 'fleet-a-updated',
        description = 'Updated description',
        logo_path = 'fleets/fleet-a/logo.png',
        status = 'published'
    where id = '41000000-0000-0000-0000-000000000001'$$,
  'owner updates permitted fleet fields'
);

select ok(
  (
    select name = 'Fleet A Updated'
      and slug = 'fleet-a-updated'
      and description = 'Updated description'
      and logo_path = 'fleets/fleet-a/logo.png'
      and status = 'published'
    from public.fleets
    where id = '41000000-0000-0000-0000-000000000001'
  ),
  'all permitted fields are persisted'
);

select cmp_ok(
  (select updated_at from public.fleets where id = '41000000-0000-0000-0000-000000000001'),
  '>',
  (select created_at from public.fleets where id = '41000000-0000-0000-0000-000000000001'),
  'updated_at advances'
);

select is(
  (select count(*)::integer from public.audit_events where action = 'fleet_updated'),
  1,
  'one fleet_updated event is created'
);

select is(
  (select metadata from public.audit_events where action = 'fleet_updated'),
  '{"changed_fields":["name","slug","description","logo_path","status"]}'::jsonb,
  'audit metadata contains field names but no values'
);

select throws_ok(
  $$update public.fleets set status = 'suspended'
    where id = '41000000-0000-0000-0000-000000000001'$$,
  '42501', null, 'owner cannot set suspended through Data API'
);

reset role;
select set_config(
  'request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000003","role":"authenticated"}',
  true
);
set local role authenticated;

update public.fleets
set name = 'Blocked member update'
where id = '41000000-0000-0000-0000-000000000001';

select is(
  (select count(*)::integer
   from public.fleets
   where id = '41000000-0000-0000-0000-000000000001'
     and name = 'Blocked member update'),
  0,
  'non-owner updates no fleet rows'
);

reset role;
select set_config(
  'request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
set local role authenticated;

select throws_ok(
  $$update public.fleets
    set created_by = '40000000-0000-0000-0000-000000000002'
    where id = '41000000-0000-0000-0000-000000000001'$$,
  '42501', null, 'owner has no grant to change created_by'
);

update public.fleets
set name = 'Blocked tenant update'
where id = '41000000-0000-0000-0000-000000000002';

reset role;
select is(
  (select name from public.fleets where id = '41000000-0000-0000-0000-000000000002'),
  'Fleet B',
  'owner cannot update another tenant by known UUID'
);

select * from finish();
rollback;
```

- [ ] **Step 2: Escrever teste de regressão da auditoria**

Create `supabase/tests/database/007_audit_events.test.sql` with:

```sql
begin;

create extension if not exists pgtap with schema extensions;
\ir ../_helpers.psql

select plan(8);
select pg_temp.seed_foundation();

insert into public.audit_events (
  id, fleet_id, actor_user_id, action, entity_type, entity_id, metadata
) values
  (
    '43000000-0000-0000-0000-000000000001',
    '41000000-0000-0000-0000-000000000001',
    '40000000-0000-0000-0000-000000000001',
    'fleet_updated',
    'fleet',
    '41000000-0000-0000-0000-000000000001',
    '{"changed_fields":["name"]}'::jsonb
  ),
  (
    '43000000-0000-0000-0000-000000000002',
    '41000000-0000-0000-0000-000000000002',
    '40000000-0000-0000-0000-000000000005',
    'fleet_updated',
    'fleet',
    '41000000-0000-0000-0000-000000000002',
    '{"changed_fields":["status"]}'::jsonb
  );

select set_config(
  'request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
set local role authenticated;

select is((select count(*)::integer from public.audit_events), 1, 'owner reads own fleet events');
select is(
  (select count(*)::integer from public.audit_events where fleet_id = '41000000-0000-0000-0000-000000000002'),
  0,
  'owner reads no events from another tenant'
);
select is(
  (select metadata from public.audit_events),
  '{"changed_fields":["name"]}'::jsonb,
  'sanitized metadata contains no changed values'
);

reset role;
select set_config(
  'request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000003","role":"authenticated"}',
  true
);
set local role authenticated;
select is((select count(*)::integer from public.audit_events), 0, 'non-owner reads no audit events');

reset role;
select set_config('request.jwt.claims', '', true);
set local role anon;
select throws_ok(
  $$select count(*) from public.audit_events$$,
  '42501', null, 'anonymous cannot read audit events'
);

reset role;
select set_config(
  'request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
set local role authenticated;

select throws_ok(
  $$insert into public.audit_events (
      fleet_id, actor_user_id, action, entity_type, entity_id
    ) values (
      '41000000-0000-0000-0000-000000000001',
      '40000000-0000-0000-0000-000000000001',
      'forged',
      'fleet',
      '41000000-0000-0000-0000-000000000001'
    )$$,
  '42501', null, 'authenticated cannot insert audit events'
);

select throws_ok(
  $$update public.audit_events set action = 'forged'
    where id = '43000000-0000-0000-0000-000000000001'$$,
  '42501', null, 'authenticated cannot update audit events'
);

select throws_ok(
  $$delete from public.audit_events
    where id = '43000000-0000-0000-0000-000000000001'$$,
  '42501', null, 'authenticated cannot delete audit events'
);

select * from finish();
rollback;
```

- [ ] **Step 3: Confirmar RED pela ausência do trigger de auditoria**

Run:

```bash
supabase test db supabase/tests/database/006_fleet_updates.test.sql
supabase test db supabase/tests/database/007_audit_events.test.sql
```

Expected: `006` falha porque ainda não existe `fleet_updated`; `007` confirma que os grants e a RLS já tornam os eventos imutáveis e isolados.

- [ ] **Step 4: Criar a migration de auditoria**

Run:

```bash
supabase migration new create_foundation_audit
```

- [ ] **Step 5: Implementar o trigger sanitizado**

Write in the generated migration:

```sql
create function private.audit_fleet_update()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_changed_fields text[] := array_remove(array[
    case when old.name is distinct from new.name then 'name' end,
    case when old.slug is distinct from new.slug then 'slug' end,
    case when old.description is distinct from new.description then 'description' end,
    case when old.logo_path is distinct from new.logo_path then 'logo_path' end,
    case when old.status is distinct from new.status then 'status' end
  ], null);
begin
  if cardinality(v_changed_fields) > 0 then
    insert into public.audit_events (
      fleet_id,
      actor_user_id,
      action,
      entity_type,
      entity_id,
      metadata
    ) values (
      new.id,
      auth.uid(),
      'fleet_updated',
      'fleet',
      new.id,
      jsonb_build_object('changed_fields', to_jsonb(v_changed_fields))
    );
  end if;

  return new;
end;
$$;

revoke execute on function private.audit_fleet_update() from public, anon, authenticated;

create trigger fleets_audit_update
after update on public.fleets
for each row execute function private.audit_fleet_update();
```

- [ ] **Step 6: Confirmar GREEN da suíte completa**

Run:

```bash
supabase db reset
supabase test db
```

Expected: testes 001 a 007 passam e eventos não contêm os valores anteriores ou novos dos campos.

---

### Task 8: Seed fictício, validação, remoto e documentação

**Files:**

- Modify: `supabase/seed.sql`.
- Modify: `README.md`.
- Modify: `deliverables.md`.
- Modify: nenhum outro arquivo de domínio.

**Interfaces:**

- Consumes: fundação completa e testes verdes.
- Produces: ambiente local demonstrável, migrations aplicadas no remoto após checkpoint e entrega documentada.

- [ ] **Step 1: Adicionar somente dados fictícios ao seed**

Adicionar usuários determinísticos de desenvolvimento, duas frotas e associações suficientes para demonstrar owner, driver e múltiplos papéis. Usar exclusivamente endereços `@example.test`, nomes fictícios e UUIDs fixos do namespace reservado aos seeds.

O seed deve reutilizar as tabelas e constraints implementadas; como é executado pelo papel de bootstrap local, pode inserir os fixtures diretamente sem duplicar regras de autorização nem inserir qualquer dado real.

- [ ] **Step 2: Validar do zero**

Run:

```bash
supabase db reset
supabase test db
supabase db lint
supabase migration list --local
git diff --check
```

Expected: reset, testes e lint passam; sete migrations do Ciclo 1 aparecem em ordem local; diff sem erros de whitespace.

- [ ] **Step 3: Conferir o Git antes da quality gate**

Run:

```bash
git status --short
```

Expected: somente arquivos do Ciclo 0, Ciclo 1 e documentação autorizada; nenhuma alteração concorrente perdida.

- [ ] **Step 4: Executar `software-quality-gate` em modo não modificador**

Expected: a skill não instala dependências, não altera manifests ou lockfiles, não cria testes, não grava configuração e não deixa arquivos gerados no repositório.

- [ ] **Step 5: Conferir o Git após a quality gate**

Run:

```bash
git status --short
git diff --check
```

Expected: o mesmo conjunto de mudanças esperado antes da quality gate.

- [ ] **Step 6: Preparar o deployment remoto sem executá-lo**

Run:

```bash
supabase db push --help
supabase db push --dry-run
```

Expected: dry run lista somente migrations versionadas dos ciclos concluídos. Parar aqui e solicitar autorização explícita para alterar o remoto.

- [ ] **Step 7: Aplicar migrations após o checkpoint explícito**

Run only after approval:

```bash
supabase db push
```

Expected: migrations aplicadas uma vez, sem edição manual pelo Dashboard ou MCP.

- [ ] **Step 8: Validar o remoto pelo Supabase MCP**

Run:

- `list_tables` para `public` e `private`, com detalhes;
- `list_migrations`;
- `get_advisors` para `security`;
- `get_advisors` para `performance`;

Expected: cinco tabelas, sete migrations, três RPCs e nenhuma Edge Function; resolver advisors críticos ou altos antes de concluir.

- [ ] **Step 9: Atualizar documentação com fatos verificados**

Atualizar `README.md` para informar que a fundação multi-tenant está implementada. Em `deliverables.md`, registrar:

- status `Concluído` e data;
- cinco tabelas e três RPCs entregues;
- migrations efetivamente aplicadas;
- matriz real de grants e RLS;
- resultado de reset, pgTAP, lint, quality gate e advisors;
- confirmação do deployment remoto;
- desvios reais, ou `Nenhum desvio registrado`.

- [ ] **Step 10: Revisar a entrega documental e técnica**

Run:

```bash
git diff -- README.md deliverables.md supabase docs/superpowers/plans
git diff --check
git status --short
```

Expected: documentação não afirma entregas não verificadas; nenhum arquivo do Ciclo 2 foi criado.

---

## Critérios de aceite

- As cinco tabelas existem localmente e no remoto com constraints e índices definidos.
- Novo `auth.users` cria exatamente um `profiles` mínimo sem copiar `user_metadata`.
- Usuário autenticado lê e atualiza apenas o próprio perfil.
- Usuário autenticado lê somente frotas e associações autorizadas.
- Owner atualiza somente campos permitidos da própria frota.
- `create_fleet` cria frota, associação, primeiro owner e auditoria atomicamente.
- RPCs de papéis e status aceitam apenas associações existentes.
- Nenhuma RPC permite remover, suspender ou rebaixar o último owner ativo.
- Acesso anônimo retorna nenhum dado e não executa RPCs.
- Conhecer UUID de outro tenant não concede acesso.
- `audit_events` é imutável para usuários comuns e legível somente por owners autorizados.
- Erros RPC usam os códigos aprovados e não expõem SQL, stack trace ou dados de outro tenant.
- `supabase db reset`, `supabase test db`, lint, quality gate e advisors passam.
- Migrations locais e remotas correspondem.
- `deliverables.md` contém somente resultados realmente observados.

## Fora de escopo confirmado

- Adicionar pessoas a uma frota por convite ou solicitação.
- Projeção pública de frotas.
- Alunos, responsáveis, escolas e cidades.
- Vans, rotas, agendas e capacidade.
- Viagens, presença e confirmações.
- Edge Functions, Cron, Realtime, Storage, notificações e mapa.

Esses itens começam nos ciclos posteriores e não devem ser antecipados para facilitar testes ou demonstrações do Ciclo 1.
