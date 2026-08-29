# VanGo Backend (BE)

Guia rápido do repositório VanGo Backend, baseado na documentação vigente no diretório.

## Sobre o projeto

Este repositório concentra a especificação técnica e diretrizes de engenharia para a API backend do **VanGo**.

- O backend é responsável por autenticação/autorização, regras de negócio e trilha em tempo real.
- O **Supabase** é usado como banco PostgreSQL + storage estático.
- O frontend (Flutter) não depende diretamente do Supabase para lógica de negócio; ele consome um **endpoint único** do Node.js.

## Arquitetura definida

- **Node.js + TypeScript** como API principal.
- **Framework sugerido**: Express ou Fastify.
- **Autenticação**: JWT com `bcrypt` para hash de senha e middleware de validação.
- **Tempo real**: Socket.io para rastreamento de localização.
- **Mapas/Roteirização**: integração com Mapbox via serviço server-side.
- **Banco**: PostgreSQL no Supabase, controlado por migrações SQL no repositório.

## Diretrizes de engenharia (resumo)

As regras abaixo são obrigatórias e já estão documentadas em `CONTRIBUTING.md`:

- Código limpo, simples e sem duplicação (Clean Code, KISS, DRY, SOLID).
- Camadas de arquitetura separadas por responsabilidade (sem acoplamento de UI com rede/banco).
- Commit semântico (`feat`, `fix`, `test`, `refactor`, `docs`).
- Erros de API com respostas padronizadas, por exemplo: `401`, `400`, `500` com payload `{ "error": "..." }`.
- Testes com foco em TDD (Red-Green-Refactor).
- Fluxo Git com branch `main` protegido e abertura de PR para integração.

## Modelagem inicial do banco (PostgreSQL)

Esquemas definidos no plano técnico:

- `public.profiles`
  - `id`, `email` (único), `password_hash`, `name`, `phone`, `role`, `created_at`, `updated_at`
- `public.veiculos`
  - `id`, `plate` (único), `model`, `capacity`, `owner_id`
- `public.turmas`
  - `id`, `name`, `invite_code` (único), `driver_id`, `vehicle_id`, `created_at`
- `public.estudantes_turma`
  - `id`, `name`, `turma_id`, `responsavel_id`, `address_text`, `address_lat`, `address_lng`, `status_presenca_padrao`, `created_at`
- `public.rotas`
  - `id`, `turma_id`, `status`, `started_at`, `ended_at`, `optimized_path`, `created_at`
- `public.presencas_rota`
  - `id`, `rota_id`, `estudante_id`, `status`, `updated_at`
- `public.historico_geolocalizacao`
  - `id`, `rota_id`, `lat`, `lng`, `speed`, `created_at`

Observação: as decisões incluem `FOREIGN KEY` com ações explícitas (`ON DELETE CASCADE`/`SET NULL`) e segurança de dados com RLS para novas tabelas.

## Contrato de autenticação (proposto)

- `POST /auth/register`
  - Cria perfil no PostgreSQL após hash da senha (`bcrypt`).
- `POST /auth/login`
  - Valida credenciais e retorna JWT.
- Middleware `checkAuth`
  - Valida token JWT e injeta `req.user`.

## Tempo real (Sockets)

- Handshake protegido por JWT.
- Salas de rota (`route:{rotaId}`): clientes da rota entram em sala para receber atualizações.
- Motorista envia `send-location`; servidor valida permissão e retransmite `location-update` para a sala.
- Histórico geográfico pode ser persistido em lote (batch) no PostgreSQL.

## Requisitos de implementação (próximos passos)

1. Inicializar o projeto Node.js com TypeScript, cliente de banco (Prisma ou `pg`) e Socket.io.
2. Criar migrações SQL do schema acima no Supabase.
3. Implementar autenticação e validações de segurança.
4. Implementar APIs de rotas, usuários, turmas, presenças e histórico.
5. Implementar serviço de otimização de rota (Mapbox).
6. Implementar notificações push (Firebase Admin SDK).

## Documentação local

- Arquitetura e próximos passos: [`be-tech-plan.md`](./be-tech-plan.md)
- Regras de código, testes e fluxo Git: [`CONTRIBUTING.md`](./CONTRIBUTING.md)

## Status atual do repositório

Neste momento, este repositório funciona como base de especificação do backend. Ainda não há implementação de código de aplicação no checkout atual.
