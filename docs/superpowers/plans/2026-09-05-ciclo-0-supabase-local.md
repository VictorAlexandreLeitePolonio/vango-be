# Ciclo 0 — Supabase local Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Preparar um ambiente Supabase local reproduzível, versionado e testável, sem criar ainda as entities ou rotas de domínio do VanGo.

**Architecture:** O Ciclo 0 usa a Supabase CLI e Docker para gerar a estrutura oficial do projeto. A única migration própria cria o schema privado que receberá helpers internos nos ciclos seguintes; o projeto remoto permanece inalterado.

**Tech Stack:** Supabase CLI, Docker, PostgreSQL, pgTAP e migrations SQL imperativas.

**Spec:** `be-tech-plan.md`, seções 3.1, 3.3, 11, 12 e 13; `CONTRIBUTING.md`, seções 2, 3, 4, 5, 12 e 13.

## Global Constraints

- Não adicionar servidor Node.js, autenticação paralela, JWT próprio ou Socket.io.
- Não criar entities de domínio, RPCs, Edge Functions, Cron jobs, buckets ou policies de negócio neste ciclo.
- Trabalhar localmente antes de qualquer alteração no projeto remoto.
- Criar migrations com `supabase migration new`; não inventar timestamps de arquivos.
- Não usar o MCP `apply_migration` para iterar no banco local.
- Não instalar dependências dentro do repositório nem criar `package.json`.
- Não expor a stack local à internet; ela usa credenciais de desenvolvimento e não possui hardening de produção.
- Não adicionar secrets, chaves remotas ou credenciais ao Git.
- Não fazer commit ou push sem autorização explícita.
- Atualizar `deliverables.md` somente com evidências realmente executadas.
- Rodar a skill `software-quality-gate` antes de declarar o ciclo concluído, verificando `git status` antes e depois.

---

## Escopo do ciclo

### Incluído

- Instalação da Supabase CLI fora do repositório.
- Inicialização da estrutura oficial `supabase/`.
- Execução da stack local com Docker.
- Migration para criar e restringir o schema `private`.
- Teste pgTAP mínimo do ambiente.
- `seed.sql` sem dados de domínio.
- Atualização do status do README e do registro de entregas.

### Excluído

- `profiles`, `fleets`, associações, papéis e auditoria.
- Data API de domínio e RPCs.
- Realtime, Storage, Edge Functions e Cron.
- Marketplace, vans, rotas, viagens, notificações e mapa.
- Link, push ou migrations no projeto remoto.

## Estrutura esperada ao final

```text
vango-be/
├── supabase/
│   ├── config.toml
│   ├── migrations/
│   │   └── <timestamp-gerado-pela-cli>_create_private_schema.sql
│   ├── seed.sql
│   └── tests/
│       └── database/
│           └── 000_environment.test.sql
├── deliverables.md
└── README.md
```

O diretório `supabase/.temp/`, quando criado pela CLI, deve permanecer ignorado pelo Git.

---

### Task 1: Instalar e validar as ferramentas fora do repositório

**Files:**

- Create: nenhum arquivo no repositório.
- Modify: nenhum arquivo no repositório.
- Test: comandos de diagnóstico da CLI e do Docker.

**Interfaces:**

- Consumes: Homebrew no macOS e Docker já instalado.
- Produces: comandos `supabase` e `docker` funcionais para as tarefas seguintes.

- [x] **Step 1: Confirmar que o repositório continua limpo**

Run:

```bash
git status --short --branch
```

Expected: branch atual exibida e nenhuma mudança além dos documentos deste planejamento.

- [x] **Step 2: Instalar a CLI fora do projeto**

Run:

```bash
brew install supabase/tap/supabase
```

Expected: instalação concluída sem criar `package.json`, lockfile ou dependência dentro de `vango-be`.

- [x] **Step 3: Descobrir os comandos da versão instalada**

Run:

```bash
supabase --version
supabase --help
supabase init --help
supabase start --help
supabase test db --help
```

Expected: todos os comandos retornam ajuda sem erro. Registrar a versão efetiva no `deliverables.md` somente ao concluir o ciclo.

- [x] **Step 4: Confirmar que o Docker está disponível**

Run:

```bash
docker version
docker info
```

Expected: cliente e daemon respondem com sucesso.

---

### Task 2: Inicializar e subir a stack local

**Files:**

- Create: `supabase/config.toml` pela Supabase CLI.
- Create or modify: `.gitignore`, somente se a CLI fizer essa alteração.
- Test: estado dos serviços locais.

**Interfaces:**

- Consumes: Supabase CLI e Docker funcionais.
- Produces: stack Supabase local reproduzível a partir de `supabase/config.toml`.

- [x] **Step 1: Gerar a estrutura oficial**

Run:

```bash
supabase init
```

Expected: diretório `supabase/` criado pela CLI. Não editar identificadores, portas ou versões geradas sem necessidade comprovada.

- [x] **Step 2: Revisar os arquivos gerados**

Run:

```bash
git status --short
git diff -- .gitignore supabase/config.toml
```

Expected: somente configuração local e regras de ignore geradas pela CLI; nenhum secret remoto.

- [x] **Step 3: Iniciar o ambiente local**

Run:

```bash
supabase start
```

Expected: banco, Auth, Data API, Studio e demais serviços padrão ficam saudáveis.

- [x] **Step 4: Verificar o estado da stack sem registrar credenciais**

Run:

```bash
supabase status
```

Expected: serviços locais ativos. Não copiar chaves ou senhas exibidas para documentação versionada.

---

### Task 3: Criar o primeiro teste RED do ambiente

**Files:**

- Create: `supabase/tests/database/000_environment.test.sql`.
- Test: `supabase/tests/database/000_environment.test.sql`.

**Interfaces:**

- Consumes: banco local inicializado sem schema `private`.
- Produces: teste que exige um schema interno sem acesso de `anon` ou `authenticated`.

- [x] **Step 1: Criar o teste pgTAP**

Create `supabase/tests/database/000_environment.test.sql` with:

```sql
begin;

create extension if not exists pgtap with schema extensions;

select plan(3);

select has_schema(
  'private',
  'private schema exists'
);

select ok(
  not has_schema_privilege('anon', 'private', 'usage'),
  'anon cannot use private schema'
);

select ok(
  not has_schema_privilege('authenticated', 'private', 'usage'),
  'authenticated cannot use private schema'
);

select * from finish();

rollback;
```

- [x] **Step 2: Executar o teste e confirmar RED**

Run:

```bash
supabase test db supabase/tests/database/000_environment.test.sql
```

Expected: FAIL porque o schema `private` ainda não existe. Guardar no relato a razão exata do RED.

---

### Task 4: Criar a migration mínima do schema privado

**Files:**

- Create: caminho retornado por `supabase migration new create_private_schema` em `supabase/migrations/`.
- Test: `supabase/tests/database/000_environment.test.sql`.

**Interfaces:**

- Consumes: teste RED da Task 3.
- Produces: schema `private` indisponível para `anon` e `authenticated`.

- [x] **Step 1: Solicitar à CLI o nome correto da migration**

Run:

```bash
supabase migration new create_private_schema
```

Expected: a CLI informa o arquivo recém-criado. Usar exatamente esse caminho nos passos seguintes.

- [x] **Step 2: Implementar a menor migration que satisfaz o teste**

Write in the generated migration:

```sql
create schema if not exists private;

revoke all on schema private from public;
revoke all on schema private from anon;
revoke all on schema private from authenticated;
```

- [x] **Step 3: Recriar o banco local do zero**

Run:

```bash
supabase db reset
```

Expected: todas as migrations locais são aplicadas sem erro em um banco limpo.

- [x] **Step 4: Executar o teste e confirmar GREEN**

Run:

```bash
supabase test db supabase/tests/database/000_environment.test.sql
```

Expected: 3 testes passam.

- [x] **Step 5: Conferir o histórico local**

Run:

```bash
supabase migration list --local
```

Expected: `create_private_schema` aparece no histórico local e não aparece no remoto.

---

### Task 5: Manter um seed local explícito e seguro

**Files:**

- Create or modify: `supabase/seed.sql`.
- Test: reset completo do banco.

**Interfaces:**

- Consumes: configuração local gerada pela CLI.
- Produces: seed válido sem dados pessoais ou registros de domínio prematuros.

- [x] **Step 1: Definir o conteúdo do seed do Ciclo 0**

Set `supabase/seed.sql` to:

```sql
-- Cycle 0 has no domain seed data.
```

- [x] **Step 2: Confirmar que o reset processa migration e seed**

Run:

```bash
supabase db reset
supabase test db
```

Expected: reset concluído e todos os testes verdes.

---

### Task 6: Atualizar a documentação após a implementação

**Files:**

- Modify: `README.md`.
- Modify: `deliverables.md`.
- Test: revisão do diff documental.

**Interfaces:**

- Consumes: comandos e evidências reais das Tasks 1 a 5.
- Produces: documentação coerente com o estado implementado.

- [x] **Step 1: Atualizar o status do README**

Replace only the outdated status paragraph with:

```markdown
O projeto possui um ambiente Supabase local reproduzível, uma migration inicial do schema privado e um teste de infraestrutura. As entities, policies e rotas de domínio ainda não foram implementadas.
```

- [x] **Step 2: Registrar a entrega real no Ciclo 0**

Em `deliverables.md`, alterar somente a seção `Ciclo 0 — Preparação local`:

- status para `Concluído`;
- data efetiva da conclusão;
- versão efetivamente retornada por `supabase --version`;
- lista dos arquivos criados;
- comandos executados e seus resultados;
- confirmação de que o projeto remoto continuou sem migrations;
- desvios reais, ou `Nenhum desvio registrado`.

- [x] **Step 3: Revisar a documentação**

Run:

```bash
git diff -- README.md deliverables.md
```

Expected: README descreve apenas o que foi implementado e `deliverables.md` contém evidências verificáveis, sem afirmar que o Ciclo 1 começou.

---

### Task 7: Executar a validação final do Ciclo 0

**Files:**

- Modify: nenhum arquivo além dos já listados.
- Test: stack, migrations, pgTAP, diff e quality gate.

**Interfaces:**

- Consumes: todas as entregas locais do ciclo.
- Produces: evidência suficiente para declarar o Ciclo 0 concluído.

- [x] **Step 1: Validar tudo a partir de banco limpo**

Run:

```bash
supabase db reset
supabase test db
supabase migration list --local
```

Expected: reset e testes passam; somente a migration local do Ciclo 0 aparece como nova.

- [x] **Step 2: Confirmar que nenhum recurso de domínio foi criado**

Run against the local database:

```sql
select table_schema, table_name
from information_schema.tables
where table_schema in ('public', 'private')
order by table_schema, table_name;
```

Expected: nenhuma tabela de domínio do VanGo em `public` ou `private`.

- [x] **Step 3: Verificar o remoto pelo MCP em modo somente leitura**

Run with the Supabase MCP:

- `list_tables` para os schemas `public` e `private`;
- `list_migrations`;
- `list_edge_functions`.

Expected: o Ciclo 0 não adicionou tabelas, migrations ou Edge Functions ao projeto remoto.

- [x] **Step 4: Conferir o Git antes da quality gate**

Run:

```bash
git status --short
git diff --check
```

Expected: somente arquivos do Ciclo 0 e documentação relacionada; `git diff --check` sem saída.

- [x] **Step 5: Executar `software-quality-gate` sem permitir alterações**

Expected: a quality gate não instala dependências, não altera manifests ou lockfiles, não cria testes, não grava configuração e não deixa artefatos no repositório.

- [x] **Step 6: Conferir o Git depois da quality gate**

Run:

```bash
git status --short
git diff --check
```

Expected: exatamente os mesmos arquivos esperados antes da quality gate.

- [x] **Step 7: Parar a stack local quando ela não for mais necessária**

Run:

```bash
supabase stop
```

Expected: containers locais do projeto encerrados sem alterar o schema versionado.

## Critérios de aceite

- A Supabase CLI está instalada fora do repositório e sua versão foi registrada.
- `supabase start` sobe a stack local com sucesso.
- `supabase db reset` recria o ambiente do zero.
- Existe exatamente uma migration própria do Ciclo 0: criação e restrição do schema `private`.
- `supabase test db` executa 3 asserts verdes.
- Não existem entities, rotas, RPCs, Edge Functions, Cron jobs, buckets ou dados de domínio.
- O projeto remoto permanece inalterado.
- README e `deliverables.md` refletem apenas entregas comprovadas.
- `git diff --check` passa.
- A quality gate não altera o repositório.

## Limite para o próximo ciclo

O Ciclo 1 começa somente após estes critérios. Ele será responsável por `profiles`, `fleets`, `fleet_memberships`, `fleet_membership_roles`, `audit_events`, RLS e RPCs da fundação multi-tenant.
