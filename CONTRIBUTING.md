# VanGo — diretrizes de desenvolvimento

Este documento define as regras inegociáveis de engenharia para todo o projeto VanGo (Backend Supabase e Frontend Flutter). Toda IA (agente de código) ou desenvolvedor humano **DEVE ler e seguir estritamente estas diretrizes antes de planejar e antes de implementar qualquer código no repositório**. Não adicione um servidor Node.js ou uma camada paralela de autenticação sem uma nova decisão arquitetural aprovada.

## 1. Princípios

- **TDD Obrigatório:** toda mudança ou adição de comportamento inicia obrigatoriamente por um teste automatizado que falha antes de existir o código produtivo.
- **Idioma estritamente em Inglês:** todo código-fonte, nomes de variáveis, classes, funções, comentários, documentação técnica inline, mensagens de commit e descrições de testes devem estar em **Inglês**.
- **Qualidade estática e cobertura:** nenhum código é aceito sem validação de lint (zero warnings e zero errors) e sem geração de relatório de cobertura de testes (coverage).
- Faça a menor alteração segura para o comportamento em desenvolvimento.
- Preserve o contrato aprovado e o isolamento multi-tenant.
- Use nomes claros e mantenha cada arquivo, classe, migração e função com uma única responsabilidade.
- Evite abstrações antecipadas, duplicação e lógica de autorização no cliente.
- Trate falhas de forma explícita. Não use `catch` vazio nem esconda erros.
- Não misture refactors sem relação com a entrega atual.
- Registre toda decisão que altere domínio, segurança ou contrato.

## 2. TDD estrito (Test-Driven Development)

Toda alteração de comportamento em qualquer camada do sistema — **Banco de dados/RLS, Edge Functions ou Frontend Flutter** — começa obrigatoriamente por um teste automatizado. O ciclo inegociável é:

1. **Red:** escreva um teste unitário, de widget ou de integração focado e execute-o. Confirme que ele falha especificamente pela ausência exata do comportamento esperado (não por erro de sintaxe ou compilação acidental).
2. **Green:** implemente somente o código estritamente necessário para fazer o teste passar.
3. **Refactor:** melhore legibilidade, arquitetura, nomes e tipagem mantendo todos os testes verdes.
4. Repita o ciclo para o próximo comportamento ou fatia vertical.

Regras inegociáveis do TDD:
- **Proibido codificar antes do teste:** Não escreva a implementação antes de ter o teste vermelho executado e confirmado.
- **Sem suítes monolíticas vermelhas:** Não crie uma bateria gigante de testes vermelhos para implementar tudo depois. Trabalhe em pequenos passos incrementais (*baby steps*).
- **Evidência no relato:** Guarde evidência do ciclo `RED` e `GREEN` nos relatórios de execução da IA ou nos PRs.
- **Bugs:** Toda correção de defeito inicia com a escrita de um teste que reproduz o bug antes de corrigi-lo.
- **RLS e Políticas:** Mudanças em RLS começam com um teste negativo de acesso e um teste positivo do papel autorizado.
- **Flutter:** Regras de negócio (Controllers, Blocs, Cubits, Repositories, UseCases) e comportamentos de Widgets devem nascer a partir de testes automatizados (`flutter test`).

## 3. Estratégia de testes, Lint e Cobertura

### 3.1 Banco e RLS (PostgreSQL)

Os testes de banco (via pgTAP) devem cobrir:

- constraints e integridade referencial;
- transações e concorrência relevante;
- transições de estado válidas e inválidas;
- acesso permitido para cada papel;
- acesso negado entre tenants;
- chamadas anônimas;
- uso de UUID conhecido de outro tenant;
- imutabilidade de histórico e auditoria;
- funções RPC e seus códigos de erro.

Cada tabela com `fleet_id` precisa de teste que use ao menos dois tenants. Um teste que cobre somente o caminho autorizado não valida isolamento.

### 3.2 Edge Functions (Deno / TypeScript)

Edge Functions devem ter testes unitários para transformação, validação e tratamento de falhas. Integrações externas usam fakes ou servidores controlados nos testes; a suíte comum não consome APIs pagas.

Teste timeouts, resposta inválida, limite do provedor, repetição idempotente e indisponibilidade. Segredos nunca aparecem em fixtures, snapshots ou logs.

### 3.3 Realtime e jobs

Teste a autorização do canal privado, o bloqueio fora de uma viagem ativa e a rejeição de um motorista não atribuído. Jobs agendados precisam ser idempotentes e testados como funções invocáveis sem esperar o relógio real.

### 3.4 Flutter e Dart (Frontend Mobile)

No diretório `vango_app`, os testes devem abranger:

- **Testes Unitários (`test/unit/...`):** Regras de validação, modelos de domínio, mapeamento JSON/DTO, serviços de API, repositórios e gerenciamento de estado (Bloc/Cubit/Notifier).
- **Testes de Widget (`test/widget/...`):** Renderização de componentes compartilhados, estados visuais de formulários, validações dinâmicas de campos, respostas a cliques e transições de tela.
- **Testes de Integração (`integration_test/...`):** Fluxos críticos ponta a ponta (como fluxo de autenticação e alternância de telas).

### 3.5 Análise Estática e Lint (Obrigatório após implementação)

Ao término de qualquer implementação ou alteração, a suíte de lint deve ser executada e passar com **tolerância ZERO** para erros e avisos:

- **Flutter / Dart:**
  - Executar: `flutter analyze`
  - Requisito: **0 issues found** (sem erros, avisos ou lints pendentes).
  - Formatação: Executar `dart format --output=none --set-exit-if-changed .` para garantir conformidade total com o guia oficial de estilo Dart.
- **Supabase / Edge Functions:**
  - Executar: `deno lint` e `deno check` nas funções alteradas.
- **Banco de Dados:**
  - Executar: `supabase db lint` antes de submeter migrações.

### 3.6 Cobertura de Código (Test Coverage)

Todo novo comportamento deve possuir cobertura de testes automatizados com relatório gerado:

- **Flutter / Dart:**
  - Executar: `flutter test --coverage`
  - Saída: arquivo padronizado `coverage/lcov.info`.
  - **Meta mínima:** mínimo de **80% de cobertura** nas camadas de lógica de negócio (`domain/`, `core/utils/`, `blocs/`, `cubits/`, `services/`, `repositories/`).
  - Para validação rápida local de limites de cobertura: recomenda-se o uso de ferramentas como `lcov` (`genhtml coverage/lcov.info -o coverage/html`) ou utilitários Dart como `coverde check 80`.
- **Edge Functions:**
  - Executar: `deno test --coverage=cov_profile`.

### 3.7 Validação final

Antes de declarar qualquer etapa concluída:

- execute toda a suíte de testes relevante (`flutter test`, `deno test`, testes pgTAP);
- execute a análise estática (`flutter analyze`, `deno lint`);
- verifique a cobertura de testes e garanta que novas lógicas estejam cobertas;
- execute a checagem de formatação (`dart format`);
- confira migrações do zero se houver mudanças de schema;
- procure por logs temporários, segredos e comentários desnecessários;
- garanta que todo código e comentários novos estejam em **Inglês**;
- confira `git diff --check`;
- confira `git status` antes e depois da finalização.

## 4. Migrações PostgreSQL

- Versione toda mudança de schema em `supabase/migrations`.
- Não crie tabelas, triggers, funções, extensões ou policies manualmente no projeto remoto.
- Migrações aplicadas são imutáveis; corrija o schema com uma nova migração.
- Use UUIDs ou identificadores ordenáveis conforme a necessidade documentada.
- Declare `NOT NULL`, `UNIQUE`, `CHECK`, `FOREIGN KEY` e ações de remoção de forma explícita.
- Indexe chaves estrangeiras, `fleet_id` e colunas usadas em policies e filtros frequentes.
- Use `timestamptz` para instantes e armazene horários recorrentes com fuso explícito.
- Prefira exclusão lógica quando a entidade participa de histórico operacional.
- Evite arrays de chaves estrangeiras. Use tabelas de relacionamento, como `route_schools`.
- Preserve snapshots de viagens concluídas; não derive histórico de dados cadastrais mutáveis.

`seed.sql` deve conter apenas dados fictícios e seguros para desenvolvimento local.

## 5. Multi-tenancy e RLS

A frota é o tenant. Toda entidade operacional deve carregar `fleet_id`, mesmo quando ele puder ser inferido por outra relação, se isso fortalecer policies, índices e auditoria sem criar inconsistência.

Regras obrigatórias:

- habilite RLS em toda tabela exposta;
- use `auth.uid()` para identificar o usuário;
- valide associação ativa e papel dentro do mesmo `fleet_id`;
- não confie em papel, usuário ou tenant enviados pelo Flutter;
- bloqueie acesso cruzado mesmo quando o solicitante conhece o UUID;
- exponha somente projeções sanitizadas no marketplace;
- mantenha dados de menores, residências e rotas fora de consultas públicas;
- escreva policies para cada operação necessária; ausência de policy deve negar acesso;
- teste `SELECT`, `INSERT`, `UPDATE` e `DELETE` separadamente quando aplicáveis.

Evite policies recursivas entre associações e papéis. Helpers privados podem consultar permissões. Funções `security definer` exigem:

- `search_path` explícito e seguro;
- schema não exposto;
- permissões revogadas por padrão;
- `GRANT` somente aos papéis necessários;
- validação interna de `auth.uid()` e `fleet_id`;
- testes negativos dedicados.

Nunca coloque `service_role` ou outra chave secreta no Flutter.

## 6. Auth e perfis

O Supabase Auth gerencia e-mail, senha, confirmação, sessão e recuperação. Não crie `password_hash`, JWT próprio ou refresh token alternativo.

`profiles` estende `auth.users` com dados de domínio. Um trigger pode criar o registro mínimo, mas não deve usar metadados editáveis para conceder acesso.

O usuário pode completar o perfil sem confirmar o e-mail. Operações que afetam terceiros, como criar frota, convidar ou solicitar vínculo, exigem confirmação.

## 7. Database Functions e contratos

Use RPC para operações que:

- alteram várias tabelas;
- validam capacidade ou conflito;
- mudam papéis;
- executam transições de estado;
- produzem auditoria junto à ação;
- exigem lock ou idempotência.

Uma função deve validar autenticação, tenant, papel, estado atual e invariantes. Retorne tipos estáveis. Erros de domínio precisam de códigos previsíveis, como:

- `email_unverified`;
- `forbidden`;
- `membership_conflict`;
- `capacity_exceeded`;
- `schedule_conflict`;
- `invalid_transition`;
- `last_owner`.

O Flutter deve mapear o código, não o texto da mensagem. Não exponha stack trace, SQL interno ou dados de outro tenant.

## 8. Edge Functions e integrações

Use Edge Functions para APIs externas, push, geocodificação e roteirização. Não mova CRUD simples para Edge Functions.

- Valide o JWT do Supabase e a autorização de domínio.
- Leia segredos somente do ambiente seguro.
- Defina timeout e política de repetição.
- Use idempotency key em operações repetíveis.
- Normalize respostas externas antes de devolvê-las ao Flutter.
- Registre métricas e contexto sem tokens, endereços completos ou coordenadas desnecessárias.
- Centralize clientes compartilhados em `supabase/functions/_shared` somente quando houver reutilização real.

Nenhum provedor externo pode ser fixado antes da pesquisa e decisão registradas no plano técnico.

## 9. Realtime e localização

- Use somente canais privados por viagem.
- Autorize leitura e escrita por associação, papel e participação.
- Aceite transmissão apenas do motorista atribuído e durante `trip.active`.
- Envie no broadcast somente posição e contexto operacional mínimo.
- Nunca transmita endereços ou paradas residenciais de alunos.
- Aplique a filtragem no backend; esconder marcadores na interface não protege dados.
- Persista amostras em frequência menor que o fluxo ao vivo.
- Remova pontos brutos após 30 dias.
- Preserve resumos e eventos operacionais conforme o plano técnico.

## 10. Auditoria e observabilidade

Audite ações sensíveis na mesma transação da mudança. Inclua tenant, autor, ação, entidade e contexto mínimo. Não copie payloads inteiros para `metadata`.

Registre falhas operacionais com correlação suficiente para diagnóstico. Logs não podem conter:

- senhas ou tokens;
- chaves de API;
- endereço residencial completo;
- coordenadas de alunos sem necessidade operacional;
- payloads completos de provedores;
- dados pessoais de outro tenant.

## 11. Privacidade

Dados de menores e localização exigem minimização por padrão. Cada consulta deve responder apenas com os campos necessários ao papel e à ação.

O responsável ou aluno adulto recebe posição da van, ETA, escolas e o próprio ponto. Somente dono e motorista atribuído recebem a rota operacional completa. A API não deve retornar dados proibidos para que o Flutter os esconda depois.

## 12. Git e revisão

Use branches curtas e Conventional Commits:

- `feat(scope): ...`
- `fix(scope): ...`
- `test(scope): ...`
- `refactor(scope): ...`
- `docs(scope): ...`

Não faça commit ou push sem autorização explícita. Preserve alterações locais que não pertencem à tarefa. Antes e depois de editar, confira `git status` e limite o diff aos arquivos autorizados.

Uma revisão deve priorizar:

1. **Crítico:** vazamento entre tenants, exposição de menores, segredo no cliente ou corrupção de dados;
2. **Alto:** quebra de contrato, bypass de autorização, corrida de capacidade ou transição inválida;
3. **Médio:** falha de tratamento, consulta ineficiente relevante ou histórico inconsistente;
4. **Baixo:** problema localizado de manutenção ou clareza;
5. **Sugestão:** melhoria sem impacto funcional imediato.

Evite comentários cosméticos sem efeito prático.

## 13. Definição de pronto (Definition of Done)

Uma etapa de implementação só é considerada concluída e pronta para PR/merge quando:

- **TDD executado com evidência:** todos os novos comportamentos começaram por um teste vermelho válido (`RED`) antes da implementação produtiva (`GREEN`);
- **Testes passam integralmente:** testes unitários, de widgets e de integração passam com 100% de sucesso (`flutter test`, `deno test`, testes pgTAP);
- **Lint estrito verificado:** `flutter analyze` reporta 0 issues (zero avisos e zero erros) e `deno lint` passa sem inconformidades;
- **Formatação conferida:** `dart format` validado sem alterações pendentes;
- **Cobertura de testes gerada:** `flutter test --coverage` (ou `deno test --coverage`) executado com a meta mínima de 80% atendida nas regras de negócio;
- **Idioma 100% em Inglês:** todo o código, nomes de arquivos, identificadores, comentários e mensagens de commit estão estritamente em Inglês;
- **Migrações idempotentes e limpas:** migrações funcionam a partir de um banco zerado;
- **RLS completa:** RLS possui cenários validados de autorização e negação entre tenants;
- **Erros tipados e tratados:** falhas mapeadas em contratos e códigos previsíveis;
- **Limpeza de código:** nenhum segredo, log temporário, código comentado ou TODO sem referência permanece;
- **Git limpo:** `git diff --check` passa e `git status` final contém apenas os arquivos previstos pela tarefa.

Não chame uma implementação de concluída sem essas evidências.

## 14. Padrão de Idioma (English-Only Policy)

Todo o repositório deve manter um padrão internacional de código. É **estritamente obrigatório** o uso de **Inglês** nos seguintes escopos:

1. **Código-fonte:**
   - Nomes de arquivos e pastas (`user_repository.dart`, `login_screen.dart`);
   - Nomes de classes, métodos, funções, variáveis e constantes (`class VehicleTracker`, `fetchActiveRoutes()`, `final String userEmail`);
   - Schemas de banco de dados, tabelas, colunas e triggers PostgreSQL (`fleet_id`, `created_at`, `is_active`);
   - Nomes de rotas e parâmetros.

2. **Comentários e Documentação de Código:**
   - Todos os comentários de linha (`//`), de bloco (`/* */`) e de documentação (`///`) devem ser redigidos exclusivamente em **Inglês**;
   - Anotações de migrações e comentários SQL (`--`) em Inglês.

3. **Mensagens de Commit e PRs:**
   - Mensagens de commit no padrão Conventional Commits em Inglês (exemplo: `feat(auth): add email and password validation rules`, `test(widget): add widget test for custom text field`);
   - Títulos de Pull Requests e descrições técnicas de código em Inglês.

4. **Testes Automatizados:**
   - Descrições de grupos (`group('AuthRepository', () { ... })`) e testes (`test('should return user when credentials are valid', ...)` ou `testWidgets('renders login button disabled when form is empty', ...)`).

> **Observação sobre textos da interface (UI Copy):**
> Textos exibidos na tela para os usuários finais brasileiros no app (labels, placeholders, mensagens ao usuário) podem estar em Português (pt-BR) diretamente ou via arquivos de internacionalização (l10n/i18n). No entanto, as chaves identificadoras e a lógica de internacionalização no código devem permanecer sempre em Inglês (exemplo: `AppStrings.loginWelcomeMessage`).
