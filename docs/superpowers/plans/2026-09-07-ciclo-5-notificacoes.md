# Ciclo 5 — Notificações Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Entregar caixa de avisos e push FCM para Flutter iOS/Android com autorização, leitura, repetição controlada e publicação após homologação local.

**Architecture:** PostgreSQL guarda aviso, destinatário e entrega duráveis; eventos são registrados junto à operação de negócio. Uma Edge Function com fetch/Web Crypto envia pela API FCM HTTP v1. O worker nunca reverte uma operação do transporte por falha de push.

**Tech Stack:** PostgreSQL/RLS/pgTAP, Supabase Edge Functions, Deno, Web Crypto/fetch, FCM HTTP v1, Supabase Cron.

**Spec:** `docs/superpowers/specs/2026-09-07-ciclo-5-notificacoes-design.md`, aprovada em 2026-09-07.

## Global Constraints

- Provedor FCM aprovado; Flutter iOS e Android, iOS com APNs configurado no Firebase.
- Caixa de avisos e leitura por usuário permanecem disponíveis sem push.
- Push de tela bloqueada sem endereço, nome de menor ou conteúdo sensível.
- Comunicação unidirecional; dono envia aos públicos permitidos e motorista usa categorias da própria viagem.
- Deduplicar internamente; não prometer exactly-once de entrega externa após timeout ambíguo.
- Alertas obsoletos não são enviados; fatos históricos conservam horário do ocorrido.
- Segredos somente server-side, nenhum token/credencial em logs, fixtures, manifests ou documentação.
- Sem código Flutter, chat, SMS, campanhas ou implementação de mapa/ETA.
- Local é homologação; integrar com dispositivos iOS/Android controlados antes de declarar validação ponta a ponta.
- Testes comuns com fake FCM, sem chamadas pagas. Não instalar framework de backend ou migrar projeto para Node.
- Criar migrations via CLI, preservar existentes, TDD estrito, quality gate somente leitura, sem commit/push automático.

## Arquivos e contratos

| Arquivo | Responsabilidade |
| --- | --- |
| migrations `cycle_5_inbox`, `cycle_5_devices`, `cycle_5_events`, `cycle_5_delivery_queue`, `cycle_5_worker_job` | esquema e comandos |
| `supabase/tests/database/032_notifications.test.sql` a `036_notification_delivery.test.sql` | contratos banco |
| `supabase/tests/_notifications.psql` | fixture sobre `_operations.psql` |
| `supabase/functions/notification-dispatch/index.ts` | autenticação interna, claim e envio |
| `supabase/functions/notification-dispatch/fcm.ts` e `fcm.test.ts` | HTTP v1 e tradução de resultado |
| `supabase/functions/notification-dispatch/oauth.ts` e `oauth.test.ts` | assertion da service account e access token Google |
| `supabase/functions/notification-dispatch/retry.ts` e `retry.test.ts` | backoff e validade |
| `supabase/functions/notification-dispatch/index.test.ts` | fluxo fake worker/banco/provedor |
| `supabase/functions/.env.example` | somente nomes e valores vazios |
| `supabase/config.toml` | configuração explícita da função |
| `docs/operations/ciclo-5-production.md` | credenciais, APNs, implantação e evidências |

Não criar `_shared` até outro endpoint realmente reutilizar código. Deno oferece `fetch`, `crypto.subtle` e `Deno.test`; nenhuma dependência npm é necessária para esta integração. Arquivos npm existentes pertencem ao usuário e não são removidos.

Estados de entrega: `pending|processing|sent|failed|expired|suppressed`. `sent` é aceite pelo FCM, não leitura. Leitura fica em `notification_recipients.read_at`.

## Task 1: Caixa de avisos e autorização por destinatário

**Files:** Create `032_notifications.test.sql`, `_notifications.psql`, migration `cycle_5_inbox`.

**Interfaces:** Produces:

```sql
public.list_notifications(p_limit integer,p_offset integer) returns jsonb
public.read_notification(p_notification_id uuid) returns timestamptz
private.create_notification(p_fleet_id uuid,p_event_key text,p_category text,
  p_entity_type text,p_entity_id uuid,p_body jsonb,p_occurred_at timestamptz,
  p_expires_at timestamptz,p_recipient_ids uuid[]) returns uuid
```

Helper privado é chamado somente após resolver destinatários no servidor. `p_event_key` única por frota, estável, não contém PII. `p_body` contém texto privado sanitizado, contexto de aluno próprio e ação reconhecida; payload FCM não copia esse corpo.

- [ ] **Step 1 — Revalidar baseline e escrever RED de isolamento.**

```bash
git status --short
supabase db reset --local
supabase test db
```

```sql
select has_table('public','notification_recipients','leitura pertence ao destinatário');
select has_function('public','read_notification',array['uuid'],'leitura idempotente');
```

Run: `supabase test db supabase/tests/database/032_notifications.test.sql`.

- [ ] **Step 2 — Criar schema/RPC com projection whitelist.**

Criar `notifications(id,fleet_id,event_key,category,entity_type,entity_id,body,occurred_at,created_at,expires_at)` e `notification_recipients(notification_id,fleet_id,user_id,read_at,created_at)`. Unicidades `(fleet_id,event_key)` e `(notification_id,user_id)`. Grants de DML direto negados; funções públicas filtram por usuário e autorização atual de contexto.

```sql
update public.notification_recipients
set read_at=coalesce(read_at,clock_timestamp())
where notification_id=p_notification_id and user_id=auth.uid()
returning read_at;
```

Consulta retorna `{items:[{id,category,body,occurred_at,read_at,entity_type,entity_id}],limit,offset}`; limite 1–50, offset não negativo. Um destinatário removido de relação não lê detalhe privado só por ter uma linha antiga; histórico autorizado continua visível quando o contrato permitir.

- [ ] **Step 3 — GREEN de leitura e replay.**

```bash
supabase db reset --local
supabase test db supabase/tests/database/032_notifications.test.sql
```

Testar dois usuários/tenants, UUID alheio, secundário removido, token ausente, leitura repetida sem mudar timestamp e evento duplicado sem duplicar caixa.

## Task 2: Instalações e tokens próprios

**Files:** Create `033_devices.test.sql`, migration `cycle_5_devices`.

**Interfaces:** Produces:

```sql
public.register_device(p_installation_id uuid,p_platform text,p_token text) returns uuid
public.revoke_device(p_installation_id uuid) returns void
```

- [ ] **Step 1 — RED de acesso ao token.**

```sql
select has_table('public','device_tokens','dispositivos são privados');
select throws_ok($$select public.register_device(
 '75000000-0000-0000-0000-000000000001','web','fake-token')$$,
 'PGRST',null,'plataforma fora do MVP rejeitada');
```

Run: `supabase test db supabase/tests/database/033_devices.test.sql`.

- [ ] **Step 2 — Implementar ownership e rotação.**

Schema `device_tokens(id,user_id,installation_id,platform,token,active,created_at,updated_at,revoked_at)`, plataforma `ios|android`, unicidade de instalação ativa por conta e token ativo global. Validar token não vazio com tamanho máximo 4096; nenhum endpoint retorna token a terceiros.

```sql
create unique index device_tokens_active_token_key
on public.device_tokens(token) where active;
```

Registro atualiza somente instalação do próprio usuário. Se o token estiver ativo em outra conta, rejeitar `device_conflict`, sem revelar a conta. Logout revoga antes da troca de conta; novo registro pode reivindicar token apenas após revogação anterior. Não permitir transferência por simples conhecimento de UUID/token. Refresh no mesmo usuário desativa token antigo e registra o novo atomicamente.

- [ ] **Step 3 — GREEN e troca de conta.** Testar rotação, logout repetido, token reutilizado por outro usuário, owner tentando listar tokens da frota e dispositivo sem permissão push. Nenhuma falha em token remove avisos.

```bash
supabase db reset --local
supabase test db supabase/tests/database/033_devices.test.sql
```

## Task 3: Eventos automáticos e mensagens manuais

**Files:** Create `034_notification_events.test.sql`, `035_manual_messages.test.sql`, migration `cycle_5_events`.

**Interfaces:** Produces:

```sql
private.materialize_notifications(p_limit integer,p_now timestamptz)
  returns integer
public.send_manual_notification(p_fleet_id uuid,p_scope text,p_target_id uuid,
  p_category text,p_message text,p_command_id uuid) returns uuid
private.notification_actionable(p_notification_id uuid,p_user_id uuid,
  p_now timestamptz) returns boolean
```

Escopos `fleet|route|trip|van|user`; `fleet` usa target igual fleet. Motorista só `trip` atribuído, categorias `delay|arrival|incident|reminder`; owner aceita `notice` também. Texto 1–2000 caracteres, máximo 10 comandos manuais por minuto por autor/frota, computado no banco. Essa proteção não é plano comercial.

- [ ] **Step 1 — RED de público e idempotência.**

```sql
select has_function('private','materialize_notifications',
 array['integer','timestamp with time zone'],'eventos têm processamento retomável');
select throws_ok($$select public.send_manual_notification(
 '41000000-0000-0000-0000-000000000001','fleet',
 '41000000-0000-0000-0000-000000000001','notice','Teste',
 '75000000-0000-0000-0000-000000000002')$$,
 'PGRST',null,'motorista não envia para frota');
```

Executar os dois arquivos novos individualmente; JWT da segunda assertion é driver da fixture.

- [ ] **Step 2 — Implementar resolução e validade.**

Consumir `trip_events` com corte inicial persistido em `private.notification_worker_state(id boolean primary key,activation_event_id bigint,enabled boolean,activated_at timestamptz)` e tabela `private.notification_processed_events(event_id bigint primary key,processed_at timestamptz)`. O corte inicial é fixado pelo operador na ativação; não avançá-lo como cursor de leitura a cada lote, pois IDs podem ser alocados em uma ordem e commitados em outra.

Selecionar eventos acima do corte inicial que ainda não constem na tabela de processados, por ID, com `FOR UPDATE SKIP LOCKED`. Materializar avisos/destinatários e registrar processamento na mesma transação, inclusive eventos sem destinatários elegíveis. Crash reverte ambos; um evento de ID menor que comitou tarde continua sendo encontrado na próxima execução. A função retorna quantidade processada, não um high-water mark inseguro.

Criar eventos sem viagem (pedido aprovado/recusado, alteração de escola/endereço) chamando `create_notification` na própria transação dos comandos de domínio; nada de varrer audit logs contendo dados insuficientes. Corpo de endereço não contém endereço no push. Destinatários vêm de matrículas/responsáveis atuais e atribuição da próxima viagem, não da ativa preservada.

```sql
insert into public.notification_recipients(notification_id,fleet_id,user_id)
select v_notification_id,v_fleet_id,recipient_id
from unnest(v_recipient_ids) recipient_id
on conflict (notification_id,user_id) do nothing;
```

`notification_actionable`: conferência de autorização atual e validade. Confirmação disponível/próxima expira no prazo; viagem iniciada expira no encerramento; fatos/manuais têm janela de envio de 24h. Evento factual offline usa `occurred_at` original e jamais se apresenta como proximidade atual. Aviso expirado para push continua no histórico autorizado.

Lembrete de prazo: criar uma única chave por viagem/aluno quando faltar até 10 minutos e estado ainda for `pending`; fechar no deadline. Default técnico 10 minutos, sem repetir por tick do Cron.

- [ ] **Step 3 — GREEN e casos negativos.**

```bash
supabase db reset --local
supabase test db supabase/tests/database/034_notification_events.test.sql
supabase test db supabase/tests/database/035_manual_messages.test.sql
```

Testar destinatários duplicados, responsável removido, vínculo encerrado, motorista substituído, escopo cruzado, limite por minuto, retomada após crash, commits de eventos fora da ordem de IDs e evento fora da janela de validade.

## Task 4: Entregas concorrentes e retomada

**Files:** Create `036_notification_delivery.test.sql`, migration `cycle_5_delivery_queue`.

**Interfaces:** RPCs públicas internas, EXECUTE somente `service_role`:

```sql
public.claim_notification_deliveries(p_limit integer,p_lease_id uuid) returns jsonb
public.finish_notification_delivery(p_delivery_id uuid,p_lease_id uuid,
 p_outcome text,p_provider_id text,p_error_code text,p_retry_after_seconds integer)
 returns text
public.notification_delivery_ready(p_delivery_id uuid,p_lease_id uuid) returns boolean
```

`p_outcome=sent|retry|invalid_token|permanent_failure`. Claim usa relógio do banco e retorna array `{id,token,notification_id,expires_at,attempt,lease_id}`; nunca retorna corpo privado, porque push é genérico. Helpers de teste podem receber relógio controlado em `private`, sem expô-lo a clientes.

- [ ] **Step 1 — RED de claim sem duplicação.**

```sql
select has_table('public','notification_deliveries','entrega é durável');
select ok(not has_function_privilege('authenticated',
 'public.claim_notification_deliveries(integer,uuid)','EXECUTE'),
 'cliente não reivindica tokens');
```

- [ ] **Step 2 — Implementar concessão e conclusão CAS.**

Schema `notification_deliveries(id,notification_id,device_id,state,attempt,next_attempt_at,lease_id,lease_until,provider_id,last_error_code,sent_at)`, unique `(notification_id,device_id)`. Claim limita 1–100, revalida utilidade e seleciona linhas prontas com `FOR UPDATE SKIP LOCKED`; concessão 60 segundos. Conclusão exige o `lease_id` atual; worker antigo não confirma trabalho reivindicado por outro.

```sql
select id from public.notification_deliveries
where (state='pending' and next_attempt_at<=clock_timestamp())
   or (state='processing' and lease_until<clock_timestamp())
order by next_attempt_at,id for update skip locked limit p_limit;
```

Backoff máximo de 5 tentativas, atraso base 60s, dobrando até 1h e respeitando Retry-After maior; não ultrapassar validade. Sucesso marca `sent`; token inválido desativa token; autorização revogada marca `suppressed`. Error codes sanitizados, sem corpo FCM cru.

`notification_delivery_ready` verifica concessão vigente e chama `notification_actionable` imediatamente antes do envio externo. Se false, o worker não chama FCM. Uma mensagem já aceita pelo provedor não pode ser recolhida; a revalidação reduz a janela de obsolescência sem prometer atomicidade entre PostgreSQL e FCM.

- [ ] **Step 3 — GREEN de concorrência.**

```bash
supabase db reset --local
supabase test db supabase/tests/database/036_notification_delivery.test.sql
```

Acrescentar duas sessões reais ao harness local para provar claim sem duplicata, concessão vencida e worker antigo rejeitado. Testar timeout depois de aceite externo: caixa continua única, mas push pode repetir; não transformar esse caso em garantia falsa de exactly-once.

## Task 5: Cliente FCM HTTP v1 com testes falsos

**Files:** Create `fcm.ts`, `fcm.test.ts`, `oauth.ts`, `oauth.test.ts`, `retry.ts`, `retry.test.ts` em `notification-dispatch`.

**Interfaces:**

```ts
export type FcmResult = {kind:'sent'; providerId:string}
 | {kind:'retry'; code:string; retryAfterSeconds:number|null}
 | {kind:'invalid_token'|'permanent_failure'; code:string};
export async function sendFcmMessage(input: {
 projectId:string; accessToken:string; deviceToken:string; notificationId:string;
 expiresAt:string; now:Date; fetchImpl:typeof fetch
}): Promise<FcmResult>;
export async function getGoogleAccessToken(credentials: {
 client_email:string; private_key:string
}, fetchImpl:typeof fetch, now:Date): Promise<{token:string; expiresAt:number}>;
export function retryDelay(attempt:number,retryAfter:number|null,random:number):number;
```

- [ ] **Step 1 — RED de erro e sucesso sem rede.**

```ts
import {sendFcmMessage} from './fcm.ts';
Deno.test('token inexistente é desativável', async () => {
 const fake: typeof fetch = async () => new Response(JSON.stringify({error:{
   code:404,details:[{'@type':'type.googleapis.com/google.firebase.fcm.v1.FcmError',
   errorCode:'UNREGISTERED'}]}}),{status:404});
 const result=await sendFcmMessage({projectId:'test',accessToken:'fake',
  deviceToken:'fake-device',notificationId:'notice-1',
  expiresAt:'2026-09-15T00:00:00Z',now:new Date('2026-09-14T00:00:00Z'),fetchImpl:fake});
 if(result.kind!=='invalid_token') throw new Error('token deve ser invalidado');
});
```

Run: `deno test supabase/functions/notification-dispatch/fcm.test.ts`; FAIL por módulo/função ausente, não por acesso ao provedor.

- [ ] **Step 2 — Implementar envio e autenticação Google.**

```ts
const response = await fetchImpl(
 `https://fcm.googleapis.com/v1/projects/${encodeURIComponent(projectId)}/messages:send`,
 {method:'POST',headers:{Authorization:`Bearer ${accessToken}`,
 'Content-Type':'application/json'},signal:AbortSignal.timeout(10000),
 body:JSON.stringify({message:{token:deviceToken,
 notification:{title:'VanGo',body:'Você tem uma atualização no aplicativo.'},
 data:{notification_id:notificationId}}})});
```

Acrescentar TTL Android e `apns-expiration` conforme `expiresAt`, sem enviar aviso já expirado. Parsear resultado: sucesso exige `name` string; 429/5xx/timeout são retry, `UNREGISTERED` invalida token; `INVALID_ARGUMENT` só invalida token se detalhe específico comprovar token inválido, não por payload bug. JSON inválido não vira sucesso.

OAuth usa service account assertion RS256 por Web Crypto, scope `https://www.googleapis.com/auth/firebase.messaging`, audience `https://oauth2.googleapis.com/token`, `iat` atual e `exp=iat+3600`. Trocar assertion por access token via formulário URL-encoded. Isso autentica integração Google; não cria JWT próprio para usuários VanGo. Cache em memória até 60s antes de expirar, nunca persistir chave/token em banco/log.

- [ ] **Step 3 — GREEN para resposta e criptografia.**

```bash
deno test supabase/functions/notification-dispatch/fcm.test.ts
deno test supabase/functions/notification-dispatch/oauth.test.ts
deno test supabase/functions/notification-dispatch/retry.test.ts
deno check supabase/functions/notification-dispatch/fcm.ts
```

OAuth test gera chave RSA efêmera via `crypto.subtle.generateKey`, exporta fixture somente em memória e verifica assinatura/claims/assertion no fake token endpoint. Testar timeout, erro JSON, 429/Retry-After, renovação de cache e segredo ausente. `retryDelay` usa random injetado para jitter determinístico em testes.

## Task 6: Worker autenticado, agendamento e contrato mobile

**Files:** Create `index.ts`, `index.test.ts`, `.env.example`, migration `cycle_5_worker_job`; Modify `supabase/config.toml`.

**Interfaces:** HTTP `POST /functions/v1/notification-dispatch`, somente chamada interna com segredo próprio no header `x-worker-secret`; body `{}`, resposta `{claimed,sent,retried,failed}`. Nenhum cliente pode escolher recipients/tokens pelo body. Produzir também `private.dispatch_notification_worker() returns bigint`, que retorna o ID da requisição pg_net e só é executável pelo agendador/operador autorizado.

- [ ] **Step 1 — RED de requisição sem credencial.** Exportar `handle(request:Request,deps:{workerSecret:string; dispatch:()=>Promise<Record<string,number>>}):Promise<Response>` do módulo sem executar `Deno.serve` em import de teste.

```ts
import {handle} from './index.ts';
Deno.test('worker não é endpoint público de envio',async()=>{
 let called=false;
 const response=await handle(new Request('http://localhost',{method:'POST'}),{
  workerSecret:'test-secret',dispatch:async()=>{called=true;return {claimed:0};}});
 if(response.status!==401||called) throw new Error('envio não autorizado');
});
```

- [ ] **Step 2 — Implementar orchestration sem broker.** Comparar segredo em tempo constante, rejeitar método/body inesperados, obter credencial OAuth e reivindicar lote. Usar `fetch` em `/rest/v1/rpc/claim_notification_deliveries` e `/finish_notification_delivery` com chave Supabase server-side e headers `apikey`/Bearer, sem expor schema privado. O grant service-role-only das RPCs é obrigatório.

`index.ts` chama `Deno.serve` e lê ambiente somente no ponto de entrada, usando `import.meta.main`; importar em teste não inicia servidor nem lê secrets. Antes de cada chamada FCM, consultar `notification_delivery_ready` pela RPC interna e abortar se perdeu concessão/utilidade. Configurar `[functions.notification-dispatch] verify_jwt = false`, pois a credencial é interna e não JWT de usuário; a verificação de `x-worker-secret` é mandatória e testada antes de qualquer efeito.

Obter OAuth antes de reivindicar entregas. Worker reivindica 10 por chamada, processa até quatro em paralelo e interrompe novos envios após 45s; timeout HTTP de 10s e concessão de 60s. Item não processado é recuperável pela expiração da concessão. Não reivindicar 100 para enviar sequencialmente além da validade do lock.

`.env.example` contém nomes vazios: `FCM_PROJECT_ID`, `FCM_CLIENT_EMAIL`, `FCM_PRIVATE_KEY`, `NOTIFICATION_WORKER_SECRET`. Ler `SUPABASE_URL` e credencial server-side do runtime; nomes finais precisam bater com os segredos configurados. Valores reais em arquivo ignorado/fora do repo.

Agendar chamada interna a cada minuto por Cron/pg_net, segredo e URL em Vault; migration registra a função SQL de despacho e job desativado, com habilitação somente após valores seguros existentes. `dispatch_notification_worker` lê `notification_worker_url` e `notification_worker_secret` em `vault.decrypted_secrets`, rejeita valor ausente e chama:

```sql
select net.http_post(url:=v_url,
 headers:=jsonb_build_object('Content-Type','application/json','x-worker-secret',v_secret),
 body:='{}'::jsonb,timeout_milliseconds:=10000);
```

Conferir suporte/assinatura de pg_net no ambiente e nunca expor Vault ao cliente. Não colocar segredo literal no SQL de job. Concluir cada entrega com resultado sanitizado.

- [ ] **Step 3 — GREEN do fluxo inteiro fake.**

```bash
deno test supabase/functions/notification-dispatch
deno check supabase/functions/notification-dispatch/index.ts
supabase functions serve notification-dispatch --help
```

Testar erro no claim, FCM indisponível, conclusão CAS rejeitada, token desativado e resposta sem segredo. Documentar para Flutter: registrar refresh, solicitar permissão, configurar APNs, logout antes de troca de conta, abrir aviso via consulta autenticada e deduplicar `notification_id`.

## Task 7: Homologar localmente, publicar e verificar iOS/Android

**Files:** Create `docs/operations/ciclo-5-production.md`; Modify `README.md`, `be-tech-plan.md`, `deliverables.md` após resultados reais.

**Interfaces:** Consumes worker/DB; Produces push publicado verificado nas duas plataformas.

- [ ] **Step 1 — Gate local sem rede externa na suíte.**

```bash
supabase db reset --local
supabase test db
deno test supabase/functions/notification-dispatch
deno check supabase/functions/notification-dispatch/index.ts
supabase db lint --local --schema public,private --fail-on error
supabase db advisors --local --type all --level warn --fail-on error
git diff --check
git status --short
```

Executar quality gate somente leitura. Smoke local com FCM real usa credencial/dispositivo de teste explicitamente selecionados, fora da suíte comum; não disparar para usuários reais.

- [ ] **Step 2 — Preparar publicação.** Conferir projeto Firebase, FCM API habilitada, service account com permissão mínima, APNs, bundle/package IDs reais, dispositivos iOS/Android e callbacks Auth. Guardar segredos por canal seguro; documentação registra nomes, nunca valores. Registrar cursor de ativação, plano de desligar worker e recuperação do banco.

- [ ] **Step 3 — Aplicar e implantar.**

```bash
: "${SUPABASE_PROJECT_REF:?Projeto de produção verificado}"
supabase link --project-ref "$SUPABASE_PROJECT_REF"
supabase db push --linked --dry-run
supabase db push --linked
supabase functions deploy notification-dispatch --project-ref "$SUPABASE_PROJECT_REF"
```

Conferir `supabase secrets set --help` e carregar segredos de arquivo seguro, sem ecoar conteúdo. Só habilitar o job após teste de autenticação e credenciais. Nenhum staging remoto, reset ou seed em produção.

- [ ] **Step 4 — Validar entrega publicada e recuperação.** Enviar aviso controlado para iOS e Android, verificar recebimento, abertura autenticada e leitura. Testar permissão negada com caixa disponível, token inválido e retomada de worker. Falta de dispositivo/credencial mantém o smoke pendente, mesmo se fake passou.

Se falhar, desativar worker e preservar fila/avisos; corrigir função/migration sem reverter operação de transporte. Documentar local, publicado e smoke em `deliverables.md`, sem declarar garantia exactly-once.

## Cobertura

| Requisito | Task |
| --- | --- |
| caixa/leitura/privacidade | 1 |
| tokens/rotação/logout | 2 |
| eventos/manuais/validade | 3 |
| deduplicação/claim/concessão | 4 |
| FCM/OAuth/erros | 5 |
| worker/Cron/Flutter | 6 |
| local → produção/iOS/Android | 7 |

Referências oficiais: [FCM Flutter](https://firebase.google.com/docs/cloud-messaging/flutter/get-started), [FCM HTTP v1](https://firebase.google.com/docs/cloud-messaging/send/v1-api), [testes Edge Functions](https://supabase.com/docs/guides/functions/unit-test), [deploy](https://supabase.com/docs/guides/functions/deploy). Revalidar detalhes de TTL, códigos e configuração na execução.

## Registro de execução

Backend validado na release integrada em 2026-09-08: 850 assertions pgTAP, 45 testes Deno, 14 disputas PostgreSQL e WebSocket real. Evidência consolidada, publicação e pendências externas em [deliverables.md](../../../deliverables.md) e no runbook do ciclo. Os checklists acima descrevem a sequência de trabalho, não comprovam ativação de serviços externos.

FCM/Vault, deploy do worker e validação iOS/Android em dispositivos permanecem pendentes de configuração externa.
