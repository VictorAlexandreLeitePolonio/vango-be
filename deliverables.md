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
| 2 | Marketplace e vínculos | Concluído localmente | 2026-09-06 |
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

**Status:** Concluído localmente

**Concluído em:** 2026-09-06

**Escopo entregue:** catálogo global vazio, cobertura comercial por cidade e instituição, cadastro de menores e adultos, responsáveis principal/secundários, buscas públicas, solicitações do marketplace, convites com token hasheado, vínculo direto por convite, aprovação/rejeição/cancelamento/encerramento, fontes de papéis derivados, RLS e auditoria sanitizada.

**Corte preservado:** nenhuma escola ou faculdade real foi inserida; não há importador, API externa, Edge Function, envio de e-mail, código Flutter, van, motorista, rota, capacidade, disponibilidade, preferência ou lista de espera.

**Artefatos:**

- migrations `20260906201503_create_cycle_2_schema` e `20260906201646_create_cycle_2_authorization`;
- migrations `20260906201925_create_marketplace_functions`, `20260906210854_create_student_functions`, `20260906211059_create_guardian_functions`, `20260906211326_create_join_request_functions`, `20260906211528_create_enrollment_functions` e `20260906211805_create_fleet_invitation_functions`;
- `supabase/tests/database/008_cycle_2_schema.test.sql` a `016_cycle_2_audit_privacy.test.sql`;
- `supabase/tests/_helpers.psql`, com fixtures fictícias transacionais;
- `README.md`, `be-tech-plan.md` e esta documentação atualizados para o corte executado.

**Entities:** `schools`, `fleet_service_cities`, `fleet_service_schools`, `students`, `student_guardians`, `student_guardian_invitations`, `fleet_invitations`, `fleet_join_requests`, `fleet_enrollments` e `fleet_membership_role_sources`. O catálogo `schools` permanece vazio após o reset e o seed.

**RPCs:** `search_schools`, `search_marketplace`, `list_fleet_join_requests`, `get_fleet_invitation`, criação/edição de alunos, convites de responsáveis e frota, submissão/decisão/cancelamento de solicitações, aceitação/recusa/cancelamento de convites e encerramento de vínculos. Funções críticas usam `security definer`, `search_path` vazio, validação de e-mail confirmado, locks e códigos de erro `PGRST`.

**Segurança:** tabelas transacionais não aceitam escrita direta por `anon`/`authenticated`; owners administram somente a cobertura da própria frota; projeções de owner ocultam endereço após o fim da finalidade; tokens são armazenados apenas como SHA-256; papéis derivados usam fontes para preservar papéis manuais e outros dependentes; auditoria não registra PII.

**Validações executadas:**

- `supabase db reset`: PASS;
- `supabase test db`: 17 arquivos, 176 testes pgTAP, PASS;
- `supabase migration list --local`: 17 migrations locais em ordem;
- `git diff --check`: executado após as alterações;
- `supabase db lint --local --level warning --fail-on error`: PASS, sem erros de schema;
- `supabase db advisors --local --type all --level warn --fail-on error`: PASS, sem achados de nível warn/error; a execução em `level info` retornou apenas recomendações informativas de índices e RLS intencionalmente sem policy para tabelas acessadas por RPC;
- inspeção de grants/RLS/funções privilegiadas: PASS, RLS habilitada nas dez tabelas, escrita transacional direta negada e `security definer` com `search_path` vazio;
- `software-quality-gate`: PASS; revisão somente leitura, mutation analysis por raciocínio das regras críticas, sem arquivos gerados ou alteração de configuração.

**Pendências futuras:** inserir manualmente o catálogo regional de instituições ativas e campi presenciais de Itapetininga, Sorocaba, São Miguel Arcanjo, Tatuí, Capão Bonito e Pilar do Sul; decidir uma fonte externa somente se a carga manual deixar de ser suficiente.

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
