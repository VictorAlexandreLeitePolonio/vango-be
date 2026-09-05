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
| 1 | Fundação multi-tenant | Não iniciado | — |
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

**Status:** Não iniciado

**Registro:** Nenhuma entrega de implementação registrada.

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
