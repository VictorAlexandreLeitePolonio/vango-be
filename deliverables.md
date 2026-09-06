# VanGo Backend — entregas por ciclo

Este arquivo registra somente funcionalidades, arquivos, migrations e validações realmente concluídos. Planos e intenções permanecem nos documentos de implementação e não contam como entrega.

## Regras de atualização

- Atualizar um ciclo apenas depois da implementação e das validações previstas.
- Registrar comandos executados e resultados reais; não marcar validações não executadas como aprovadas.
- Informar desvios entre o plano e o resultado final.
- Não incluir secrets, tokens, URLs privadas ou dados pessoais.
- Não alterar o histórico de ciclos concluídos para representar planos posteriores.

## Resumo

| Ciclo | Escopo | Status | Concluído em |
| --- | --- | --- | --- |
| 0 | Preparação local | Concluído | 2026-09-05 |
| 1 | Fundação multi-tenant | Concluído | 2026-09-05 |
| 2 | Marketplace e vínculos | Não iniciado | — |
| 3 | Frota e planejamento | Não iniciado | — |
| 4 | Operação diária | Não iniciado | — |
| 5 | Notificações | Não iniciado | — |
| 6 | Mapa, rastreamento e roteirização | Não iniciado | — |

## Ciclo 0 — Preparação local

**Status:** Concluído

**Concluído em:** 2026-09-05

**CLI:** Supabase CLI 2.116.0, instalada fora do repositório via Homebrew.

**Escopo entregue:** Ambiente Supabase local reproduzível com Docker, schema `private` inacessível a `anon` e `authenticated` e teste pgTAP de infraestrutura. Nenhuma entity ou rota de domínio foi criada.

**Artefatos:**

- `supabase/config.toml` e `supabase/.gitignore`, gerados por `supabase init`;
- `supabase/migrations/20260905224114_create_private_schema.sql`;
- `supabase/seed.sql`, sem dados de domínio;
- `supabase/tests/database/000_environment.test.sql`.

**Migrations:** Uma migration local aplicada: `20260905224114_create_private_schema`. O projeto remoto permaneceu sem migrations.

**Rotas e contratos:** Nenhum contrato ou rota de domínio criado.

**Validações:**

- `supabase --version`, `supabase --help`, `supabase init --help`, `supabase start --help` e `supabase test db --help`: executados com sucesso;
- Docker Desktop iniciado; `docker version` e `docker info`: executados com sucesso;
- `supabase init`, `supabase start`, `supabase status` e `supabase db reset`: executados com sucesso;
- teste RED antes da migration: falhou porque o schema `private` não existia;
- teste GREEN após a migration: 3 testes pgTAP aprovados;
- `supabase test db`: 1 arquivo, 3 testes, resultado `PASS`;
- `supabase db lint --local --schema public,private --fail-on error`: nenhum erro de schema;
- `supabase db advisors --local --type all --fail-on error`: nenhuma issue;
- consulta local em `public` e `private`: 0 tabelas de domínio;
- MCP Supabase: 0 tabelas, 0 migrations e 0 Edge Functions no projeto remoto;
- `git diff --check`: sem saída.
- `software-quality-gate`: PASS; o `git status` permaneceu igual antes e depois da gate.

**Desvios e pendências:** O primeiro download da stack recebeu respostas transitórias `429`/timeout do registry; a CLI repetiu as imagens e concluiu o bootstrap. Nenhum desvio de escopo registrado.

## Ciclo 1 — Fundação multi-tenant

**Status:** Concluído

**Concluído em:** 2026-09-05

**Escopo entregue:** Fundação multi-tenant local com cinco entities relacionais, perfil automático após cadastro no Auth, isolamento por `fleet_id`, múltiplos papéis, três RPCs transacionais, auditoria sanitizada e seed fictício.

**Artefatos:**

- `supabase/config.toml`, com `api.auto_expose_new_tables = false`;
- sete migrations do Ciclo 1, geradas por `supabase migration new`;
- `supabase/seed.sql`, com cinco usuários, duas frotas e associações fictícias `@example.test`;
- `supabase/tests/database/000_environment.test.sql`;
- `supabase/tests/database/001_profiles.test.sql` a `007_audit_events.test.sql`;
- `supabase/tests/_helpers.psql`, mantido fora da descoberta automática de testes da CLI.

**Entities:** `profiles`, `fleets`, `fleet_memberships`, `fleet_membership_roles` e `audit_events`, com foreign keys, constraints de status/slug/papel, índices de associação e RLS habilitado.

**Rotas e contratos:** Data API permite `SELECT` isolado e `PATCH` somente nas colunas aprovadas de perfil e frota. As RPCs públicas são `create_fleet`, `set_fleet_member_roles` e `set_fleet_membership_status`; inserts/deletes diretos de domínio permanecem negados.

**Segurança:** `anon` não possui acesso às tabelas nem às RPCs. `authenticated` recebe somente grants explícitos; os helpers `security definer` ficam em `private`, com `search_path` vazio e acesso mínimo para avaliação do RLS. Owners leem auditoria da própria frota; eventos não podem ser alterados por usuários comuns.

**Migrations locais:** `20260905224114_create_private_schema` (Ciclo 0) e `20260905225944_create_foundation_tables`, `20260905225945_create_profile_triggers`, `20260905225946_create_authorization_helpers`, `20260905225947_create_foundation_rls`, `20260905225948_create_fleet_rpc`, `20260905225949_create_membership_rpcs` e `20260905225950_create_foundation_audit` (Ciclo 1). Nenhuma migration foi aplicada ao remoto.

**Validações executadas:**

- `supabase db reset`: PASS;
- `supabase test db`: 8 arquivos, 59 testes pgTAP, PASS;
- `supabase db lint --local --schema public,private --fail-on error`: nenhum erro;
- `supabase db advisors --local --type all --fail-on error`: nenhuma issue;
- `supabase migration list --local`: oito migrations locais em ordem;
- inspeção SQL: cinco tabelas, grants/RLS e nove funções conferidos;
- `git diff --check`: sem erros de whitespace;
- `software-quality-gate`: PASS; o `git status` permaneceu no mesmo conjunto esperado antes e depois da gate.

**Desvios:** A CLI descobre recursivamente arquivos `.sql` em `supabase/tests`; por isso o helper usa a extensão `.psql` e é incluído via `\ir ../_helpers.psql`. O teste de acesso anônimo valida erro de permissão `42501`, coerente com o grant nulo, em vez de consultar uma tabela exposta que retornaria zero linhas. Nenhum arquivo de mapa, Edge Function, Cron, Realtime, Storage ou domínio posterior foi criado.

## Ciclo 2 — Marketplace e vínculos

**Status:** Não iniciado

**Registro:** Nenhuma entrega de implementação registrada.

## Ciclo 3 — Frota e planejamento

**Status:** Não iniciado

**Registro:** Nenhuma entrega de implementação registrada.

## Ciclo 4 — Operação diária

**Status:** Não iniciado

**Registro:** Nenhuma entrega de implementação registrada.

## Ciclo 5 — Notificações

**Status:** Não iniciado

**Registro:** Nenhuma entrega de implementação registrada.

## Ciclo 6 — Mapa, rastreamento e roteirização

**Status:** Não iniciado

**Registro:** Nenhuma entrega de implementação registrada.
