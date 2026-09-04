# VanGo — diretrizes de desenvolvimento

Este documento define como o backend será implementado. O MVP usa Supabase Auth, PostgreSQL, RLS, Database Functions, Realtime, Storage, Cron e Edge Functions. Não adicione um servidor Node.js ou uma camada paralela de autenticação sem uma nova decisão arquitetural aprovada.

## 1. Princípios

- Faça a menor alteração segura para o comportamento em desenvolvimento.
- Preserve o contrato aprovado e o isolamento multi-tenant.
- Use nomes claros e mantenha cada migração, função e Edge Function com uma responsabilidade.
- Evite abstrações antecipadas, duplicação e lógica de autorização no cliente.
- Trate falhas de forma explícita. Não use `catch` vazio nem esconda erros.
- Não misture refactors sem relação com a entrega atual.
- Registre toda decisão que altere domínio, segurança ou contrato.

## 2. TDD estrito

Toda alteração de comportamento começa por um teste. O ciclo obrigatório é:

1. **Red:** escreva um teste pequeno e execute-o. Confirme que ele falha pela ausência exata do comportamento esperado.
2. **Green:** implemente somente o necessário para o teste passar.
3. **Refactor:** melhore nomes e estrutura com todos os testes verdes.
4. Repita o ciclo para o próximo comportamento.

Não escreva a implementação antes do teste. Não crie uma grande suíte vermelha e implemente tudo depois. Trabalhe em fatias verticais pequenas e guarde evidência de cada `RED` e `GREEN` no relato da tarefa.

Correções de bug começam com um teste que reproduz o defeito. Mudanças em RLS começam com um teste negativo de acesso e um teste positivo do papel autorizado.

## 3. Estratégia de testes

### 3.1 Banco e RLS

Os testes de banco devem cobrir:

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

### 3.2 Edge Functions

Edge Functions devem ter testes unitários para transformação, validação e tratamento de falhas. Integrações externas usam fakes ou servidores controlados nos testes; a suíte comum não consome APIs pagas.

Teste timeouts, resposta inválida, limite do provedor, repetição idempotente e indisponibilidade. Segredos nunca aparecem em fixtures, snapshots ou logs.

### 3.3 Realtime e jobs

Teste a autorização do canal privado, o bloqueio fora de uma viagem ativa e a rejeição de um motorista não atribuído. Jobs agendados precisam ser idempotentes e testados como funções invocáveis sem esperar o relógio real.

### 3.4 Validação final

Antes de declarar uma etapa pronta:

- execute toda a suíte relevante;
- execute validações estáticas disponíveis;
- confira migrações do zero;
- procure logs, comentários temporários e segredos;
- confira `git diff --check`;
- confira `git status` antes e depois da quality gate;
- execute a skill `software-quality-gate` sem permitir alterações no repositório.

A quality gate não pode instalar dependências, alterar manifests ou lockfiles, criar testes, gravar configuração ou deixar arquivos gerados no repositório. Toda ferramenta auxiliar deve rodar fora do projeto.

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

## 13. Definição de pronto

Uma etapa só está pronta quando:

- todos os comportamentos começaram por um teste vermelho válido;
- testes focados e suíte completa passam;
- migrações funcionam em banco limpo;
- RLS tem cenários positivos e negativos;
- erros estão tratados e tipados no contrato;
- nenhum segredo, log temporário, código comentado ou TODO sem referência permanece;
- documentação e `.env.example` refletem novas configurações;
- `git diff --check` passa;
- a quality gate termina sem modificar o repositório;
- `git status` final contém apenas mudanças esperadas.

Não chame uma implementação de concluída sem essas evidências.
