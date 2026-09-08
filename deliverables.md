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
| 3 | Frota e planejamento | Backend validado; ver pendências abaixo | 2026-09-08 |
| 4 | Operação diária | Backend validado; ver pendências abaixo | 2026-09-08 |
| 5 | Notificações | Backend validado; ver pendências abaixo | 2026-09-08 |
| 6 | Mapa, rastreamento e roteirização | Backend validado; ver pendências abaixo | 2026-09-08 |

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

**Status:** Implementado e validado localmente.

**Escopo entregue:** vans com placa global, convites e papéis de motorista, rotas com escolas ordenadas, agendas finitas, reservas de todas as combinações, fila por chegada e troca temporal de programação. Aprovação reserva todas as vagas atomicamente; ausência não libera capacidade por trecho. O dono pode aceitar ou recusar, mas não ultrapassar pedido anterior integralmente atendível escolhendo outra data.

**Artefatos:** sete migrations de 20260907235802 a 20260907235814, testes 017–023, fixtures e harness de concorrência. [Runbook](docs/operations/ciclo-3-production.md).

**Validação:** 151 assertions C3 e sete disputas reais: última vaga, placa global, suspensão × atribuição e motorista entre frotas, estas três em ambas as ordens. Upgrade de vínculo fictício aprovado pelo contrato anterior preservou matrícula/escola/turno e referência ao pedido sem inventar alocações. A suíte integrada revalida os Ciclos 0–2 com convite pendente e aprovação condicionada à reserva.

**Limite deliberado:** lock global de planejamento e busca sobre calendário finito. Medir contenção antes de particionar locks.

## Ciclo 4 — Operação diária

**Status:** Implementado e validado localmente.

**Escopo entregue:** calendário definido pelo dono, geração idempotente, confirmação e fechamento por prazo, exceção do dono com motivo, presença, substituição de recursos, ocorrências com complementos e reconciliação síncrona. Endereço/escola preservam o transporte e atualizam somente viagens não iniciadas, inclusive após fechamento das confirmações; a participação já confirmada permanece. Suspensão de motorista é bloqueada enquanto houver atribuições ativas ou futuras.

**Artefatos:** oito migrations de 20260907235815 a 20260907235829, testes 024–031, harness de operação e job Cron real criado inativo. [Runbook](docs/operations/ciclo-4-production.md).

**Validação:** 193 assertions operacionais, 12 do orquestrador/Cron e 18 de liberação de recursos por fuso; quatro corridas reais — início × endereço, início × encerramento, início duplo e substituição × suspensão. Cleanup considera notificações emitidas pelos ciclos posteriores.

## Ciclo 5 — Notificações

**Status:** Implementado e validado localmente; integração real com dispositivos pendente.

**Escopo entregue:** inbox persistente e leitura individual, tokens por dispositivo, destinatários revalidados, mensagens unidirecionais, eventos e lembretes, fila com lease e retries limitados, worker FCM com OAuth e payload genérico sem PII. Rotação de token durante entrega não revoga o token novo. O dispatcher Cron nasce inativo e o worker permanece desabilitado no banco.

**Artefatos:** cinco migrations de 20260907235831 a 20260907235838, testes 032–037_notification_worker_job, concorrência de claims, Edge Function notification-dispatch, exemplo de variáveis sem valores e endpoint protegido por segredo próprio. [Runbook](docs/operations/ciclo-5-production.md).

**Validação:** 129 assertions de domínio, 15 do job/worker e disputa real de claim; 28 testes Deno de OAuth, FCM e despacho, com typecheck, lint e formato.

**Pendências externas verificadas:** o projeto remoto não contém os secrets FCM_PROJECT_ID, FCM_CLIENT_EMAIL, FCM_PRIVATE_KEY e NOTIFICATION_WORKER_SECRET. Configurar FCM/Vault, publicar a Edge Function e validar Flutter iOS/APNs e Android em dispositivos antes de ativar o dispatcher. Nenhum push real foi enviado.

## Ciclo 6 — Mapa, rastreamento e roteirização

**Status:** Escopo independente do provedor implementado; integração de mapas/ETA permanece em espera.

**Escopo entregue:** GPS autenticado e histórico por atribuição, amostragem de 30 segundos, posição atual separada, canais privados com época de revogação, projeções sem pontos de outros alunos, sincronização offline idempotente, CAS de percurso, contingência manual, retenção de 30 dias, resumos verificáveis e infraestrutura de ETA/proximidade. Ordem manual não fabrica ETA.

**Artefatos:** cinco migrations de 20260907235840 a 20260907235848, testes 037_locations–041, contratos TypeScript, concorrência SQL e harness WebSocket nativo. [Runbook](docs/operations/ciclo-6-production.md).

**Validação:** resultados finais registrados abaixo. Sockets reais verificam entrega privada, negação de outra frota, ausência de GPS em canal público, bloqueio de publicação pelo cliente, revogação de dono/responsável/adulto/motorista e manutenção de acesso quando outro dependente continua elegível. Canais abertos antes da revogação não recebem as posições seguintes.

**Contrato offline:** o cliente com fila offline usa sync_trip_events tanto conectado quanto na retomada, preservando comando, sequência e captura originais. Trocar comando já enviado por record_passenger_event para o envelope diferente de sync_trip_events gera conflito explícito. Reenvio de fato aceito não modifica a presença nem reabre viagem; o operador precisa continuar autorizado.

**Pendências aprovadas:** escolha, orçamento e integração do provedor de mapas, geocodificação e ETA real; tarefas 7–8 do plano permanecem em espera. Não há geometrias externas, ETA inventado ou alertas automáticos de proximidade sem fonte válida.

## Validação integrada e publicação da release

Local: reset das 41 migrations; 850 assertions pgTAP em 44 arquivos; 45 testes Deno; typecheck, lint e formato; 14 disputas reais entre sessões PostgreSQL; WebSocket real com entrega privada e revogação de canais abertos. Todos passaram, incluindo cleanup.

Publicação SQL em 2026-09-08: `npx supabase db push --dry-run` confirmou 25 migrations pendentes e `npx supabase db push` aplicou todas com sucesso no projeto VanGo (`njjeopcxhnkeszukaoma`). Histórico remoto confirmado: 41 migrations, última `20260907235848`; zero tabelas públicas sem RLS e zero funções SECURITY DEFINER sem search_path. Frotas e escolas continuam vazias, sem seed remoto. Foi preservado um dump de schema anterior; isso não equivale a backup de dados/PITR. Os três jobs foram conferidos inativos no remoto. FCM/Vault, deploy da Edge Function, dispositivos e integração do provedor de mapas continuam pendentes.

Quality gate: **WARNING**, sem regressão funcional ou vulnerabilidade identificada pendente. Avisos: complexidade das transações SQL, lock global e avisos do analisador SQL (helper de erro/variáveis não lidas). Análise de mutações somente por raciocínio: 12 regras, maior risco hipotético CRITICAL. Nenhum teste de mutação ou Sonar executado.

Advisors remotos: avisos genéricos de RPC SECURITY DEFINER executável e informações de RLS sem policy em tabelas acessíveis apenas via RPC, coerentes com a arquitetura. As RPCs de marketplace/preview são públicas por contrato; demais RPCs revalidam autenticação e papéis. A função de event trigger rls_auto_enable pertence à plataforma e não foi criada pela release.

Cobertura Deno real: **89,3% linhas, 85,8% branches, 97,6% funções**, obtida com `deno test --coverage` e `deno coverage`, sem novas dependências. Artefatos gerados fora do repositório.
