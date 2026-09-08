# Ciclo 6 — Mapa, rastreamento e roteirização Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Entregar rastreamento privado, sincronização offline, percurso versionado e alertas, completando integração externa e publicação quando a escolha de mapas sair de espera.

**Architecture:** Backend valida cada posição e publica no tópico privado da época atual; revogação troca a época e interrompe novas posições no tópico antigo. PostgreSQL mantém snapshots/revisões e sincroniza eventos; roteirização externa entra por Edge Function após escolha explícita do fornecedor. Reutilizar entrega FCM do Ciclo 5.

**Tech Stack:** Supabase PostgreSQL/RLS, Realtime Broadcast, pgTAP, Deno/fetch, Edge Functions, Cron e FCM já implementado.

**Spec:** `docs/superpowers/specs/2026-09-07-ciclo-6-mapa-rastreamento-roteirizacao-design.md`, aprovada em 2026-09-07.

## Global Constraints

- Provedor, orçamento e escala de mapas/rotas em stand-by por solicitação do usuário.
- Tasks 1–6 são independentes de fornecedor; Tasks 7–8 têm barreiras explícitas de integração/publicação completa.
- Operação manual é contingência, não conclusão de roteirização automática.
- Somente motorista atribuído origina GPS; backend valida e publica. Clientes não enviam broadcast arbitrário.
- Responsável/adulto perde mapa após desembarque/ausência do próprio aluno; outro dependente elegível mantém acesso.
- Revogar também conexões abertas; RLS de entrada no canal isoladamente não basta.
- Nenhum endereço, identidade de aluno alheio ou geometria residencial completa no payload público/limitado.
- GPS bruto expira após 30 dias; eventos e resumos seguem política existente.
- Cadastro muda somente a próxima viagem não iniciada; ativa preserva seu snapshot.
- Offline guarda GPS/presença, mas início/substituição/encerramento exigem conexão.
- Cadência inicial: 5s em movimento, 15s parado, persistência a cada 30s e eventos; sinal desatualizado após 30s. Calibrar em dispositivo real.
- Não criar tabela/função no schema `realtime`; policies em `realtime.messages` são permitidas.
- TDD, migrations via CLI, local → produção, sem staging remoto, seed/reset remoto ou commit/push automático.

## Arquivos e interfaces comuns

| Arquivo | Responsabilidade |
| --- | --- |
| migrations `cycle_6_locations`, `cycle_6_realtime`, `cycle_6_offline`, `cycle_6_route_revisions`, `cycle_6_alerts_retention` | fatias independentes do provedor |
| `supabase/tests/database/037_locations.test.sql` a `041_tracking_retention.test.sql` | testes SQL |
| `supabase/tests/_tracking.psql` | fixtures sobre operação C4 |
| `supabase/tests/realtime/tracking.test.ts` | canais efetivamente conectados |
| `supabase/tests/realtime/fixtures.ts` | usuários de teste e clientes autenticados locais |
| `supabase/tests/concurrency/tracking.py` | ingestão/revogação e cálculo/início |
| `supabase/functions/route-calculate/contracts.ts` e `contracts.test.ts` | formato de entradas/resultados, sem fornecedor |
| `supabase/functions/route-calculate/index.ts`, `provider.ts`, `provider.test.ts` | somente após Task 7 liberar escolha |
| `supabase/functions/.env.example` | nomes reais do provedor apenas após decisão |
| `docs/operations/ciclo-6-production.md` | verificação parcial/completa e configuração privada |
| `docs/research/2026-09-07-mapas-decisao.md` | somente quando decisão sair de espera, sem arquivo vazio |

Tipos SQL públicos usam JSON validado para lotes, não payload livre. Toda RPC valida sessão e relação no banco; `p_user_id` não é parâmetro dos comandos públicos.

## Task 1: GPS atual, histórico e validação

**Files:** Create `037_locations.test.sql`, `_tracking.psql`, migration `cycle_6_locations`.

**Interfaces:** Produces:

```sql
public.ingest_trip_locations(p_trip_id uuid,p_assignment_id uuid,
  p_points jsonb,p_live boolean) returns jsonb
private.can_track_trip(p_trip_id uuid,p_user_id uuid) returns boolean
```

Cada ponto: `{sequence:integer,captured_at:ISO8601,latitude:number,longitude:number,accuracy:number,speed:number|null,heading:number|null}`. Máximo 200 pontos/lote, sequência positiva por atribuição, heading 0–360 exclusivo e velocidade não negativa. `p_live=true` exige atribuição atual/viagem ativa; lote histórico nunca vira transmissão atual por decisão do cliente.

- [ ] **Step 1 — Baseline e RED de autorização.**

```bash
git status --short
supabase db reset --local
supabase test db
```

```sql
select has_function('public','ingest_trip_locations',
 array['uuid','uuid','jsonb','boolean'],'GPS entra por comando validado');
select throws_ok($$select public.ingest_trip_locations(
 '76000000-0000-0000-0000-000000000001',
 '76000000-0000-0000-0000-000000000002','[]'::jsonb,true)$$,
 'PGRST',null,'não aceita viagem inexistente');
```

Run: `supabase test db supabase/tests/database/037_locations.test.sql`.

- [ ] **Step 2 — Criar modelo de posição.**

`trip_location_points(id,fleet_id,trip_id,assignment_id,sequence,captured_at,received_at,latitude,longitude,accuracy,speed,heading,payload_hash)` com unique `(assignment_id,sequence)`. `trip_current_locations(trip_id PK,fleet_id,assignment_id,sequence,captured_at,received_at,latitude,longitude,accuracy,speed,heading)`. RLS em ambas, DML direto negado; leitura bruta limitada à operação autorizada, não ao responsável depois do desembarque.

Ingestão valida intervalo de atribuição e latitude/longitude; relógio do dispositivo não é confiável. Tolerância futura inicial 2 minutos; captura anterior a 30 dias é descartada/rejeitada sem ampliar retenção. Limite de ingestão atual de uma atualização por segundo por viagem, com erro `rate_limited`; eventos podem provocar persistência adicional.

```sql
insert into public.trip_current_locations
 (trip_id,fleet_id,assignment_id,sequence,captured_at,received_at,
 latitude,longitude,accuracy)
values (p_trip_id,v_fleet_id,p_assignment_id,v_sequence,v_captured_at,
 clock_timestamp(),v_latitude,v_longitude,v_accuracy)
on conflict (trip_id) do update set
 sequence=excluded.sequence,captured_at=excluded.captured_at,
 received_at=excluded.received_at,latitude=excluded.latitude,
 longitude=excluded.longitude,accuracy=excluded.accuracy,
 assignment_id=excluded.assignment_id
where excluded.captured_at>public.trip_current_locations.captured_at;
```

Completar atualização de speed/heading e critério de desempate por atribuição/sequence, sem substituir posição por captura velha. Persistência regular usa intervalo de 30s, enquanto posição atual pode atualizar mais rápido. Duplicata com mesmo hash retorna aceita sem repetir efeito; hash diferente é `idempotency_conflict`.

- [ ] **Step 3 — GREEN e domínio de captura.**

```bash
supabase db reset --local
supabase test db supabase/tests/database/037_locations.test.sql
```

Testar motorista alheio, viagem não ativa, coordenada impossível, lote grande, precisão inválida, ponto futuro/antigo, duplicata e ordem invertida. Nenhum valor capturado fora do período autorizado pode ganhar acesso ao broadcast.

## Task 2: Canal privado com época e projeções

**Files:** Create `038_tracking_authorization.test.sql`, migration `cycle_6_realtime`.

**Interfaces:** Produces:

```sql
public.get_trip_tracking(p_trip_id uuid) returns jsonb
private.can_join_trip_topic(p_topic text,p_user_id uuid) returns boolean
private.rotate_trip_topic(p_trip_id uuid) returns bigint
private.publish_current_location(p_trip_id uuid) returns void
```

`get_trip_tracking` retorna `{trip_id,topic,epoch,last_position,stale,own_stops,schools,eta}` para responsável; owner/driver recebe também paradas operacionais autorizadas. ETA ausente é NULL, nunca zero. O usuário não recebe a polyline operacional completa em projeção limitada.

- [ ] **Step 1 — RED de autorização após desembarque.**

```sql
select is(private.can_track_trip(
 (select id from operation_ids where kind='going'),
 '60000000-0000-0000-0000-000000000001'),false,
 'desembarcado não acompanha van');
```

Fixture usa responsável/menor confirmado e depois desembarcado; conferir IDs definidos na fixture ao implementá-la. Run: `supabase test db supabase/tests/database/038_tracking_authorization.test.sql`.

- [ ] **Step 2 — Implementar época e publicação exclusiva do servidor.**

Adicionar `trips.broadcast_epoch bigint not null default 1`. Helper de tópico faz parse seguro de `trip:{uuid}:v{integer}`; string malformada retorna false antes de qualquer cast. Policy exige sessão, época atual, viagem ativa e `can_track_trip`.

```sql
create policy trip_broadcast_read on realtime.messages
for select to authenticated using (
 extension='broadcast'
 and private.can_join_trip_topic(realtime.topic(),(select auth.uid()))
);
```

Não criar policy INSERT para clientes. Publicar pelo helper servidor usando `realtime.send(payload,'location',topic,true)`, assinatura conferida na versão instalada. Payload somente posição/horário/precisão/seq e contexto mínimo, sem paradas/alunos.

Acrescentar rotação na transação de desembarque/ausência, substituição, encerramento, remoção de responsável e mudanças de relação que revoguem acesso. Ampliar corpos dos comandos existentes em novas migrations, não apenas atualizar policy. Cada ingestão/publição e rotação bloqueia a mesma viagem; conteúdo posterior ao commit de revogação só vai à nova época.

```sql
update public.trips set broadcast_epoch=broadcast_epoch+1
where id=p_trip_id returning broadcast_epoch;
```

Uma conexão antiga pode receber mensagem já enviada anteriormente, mas não novas posições publicadas após a revogação. Para reconectar elegíveis, cliente consulta RPC novamente; revogado recebe `not_found`. Outro dependente elegível mantém acesso pela relação restante.

- [ ] **Step 3 — GREEN de projeções e grants.**

```bash
supabase db reset --local
supabase test db supabase/tests/database/038_tracking_authorization.test.sql
```

Testar época anterior/futura, nome malformado, usuário de outra frota, suspensão, dependentes múltiplos, consulta de GPS bruto e ausência de endereço de terceiros no JSON. Checagem SQL não substitui Task 6 de WebSocket real.

## Task 3: Sincronização offline de presença e GPS

**Files:** Create `039_offline_sync.test.sql`, migration `cycle_6_offline`.

**Interfaces:** Produces:

```sql
public.sync_trip_events(p_trip_id uuid,p_assignment_id uuid,p_events jsonb) returns jsonb
```

Lote de até 100 `{command_id:uuid,sequence:integer,student_id:uuid,kind:boarded|dropped_off|absent,captured_at:ISO8601}`. Resposta por item `{command_id,status:accepted|duplicate|conflict|rejected,code:string|null,event_id:integer|null}`. Processar cada item em subtransação e não mascarar conflitos.

- [ ] **Step 1 — RED de idempotência e ordem causal.**

```sql
select has_function('public','sync_trip_events',array['uuid','uuid','jsonb'],
 'presença offline tem contrato explícito');
```

Preparar lote embarque/desembarque com duas sequências; executar duas vezes e esperar dois fatos totais, não quatro. Run: `supabase test db supabase/tests/database/039_offline_sync.test.sql`.

- [ ] **Step 2 — Implementar histórico sem reabrir operação.** Adicionar índice único de sequência de cliente por atribuição nos registros offline. Validar usuário autenticado ainda elegível e atribuição original em `captured_at`; não aceitar por afirmar passado anterior à suspensão. Horários cliente são declarados, recebimento é servidor.

```sql
select * from jsonb_to_recordset(p_events)
as e(command_id uuid,sequence bigint,student_id uuid,kind text,captured_at timestamptz)
order by sequence;
```

Reutilizar validação de presença e `append_trip_event` do Ciclo 4. Validar sequência causal e comando original; não sobrescrever correção mais recente nem permitir passageiro novo após início. GPS histórico válido pode completar trilha/resumo após término sem publicar posição atual; presença incompatível com viagem concluída gera conflito para resolução, não reabre estado.

Não sincronizar início/substituição/conclusão offline. Antes de encerrar, cliente deve enviar presença pendente; o servidor mantém suas próprias travas independentemente dessa recomendação.

- [ ] **Step 3 — GREEN de retomada.**

```bash
supabase db reset --local
supabase test db supabase/tests/database/039_offline_sync.test.sql
```

Testar lote fora de ordem, sequência repetida com payload diferente, motorista substituído com captura anterior, usuário suspenso, timestamp falsamente futuro, correção posterior e perda de ACK. Não disparar proximidade para capturas históricas.

## Task 4: Revisões do percurso e contingência manual

**Files:** Create `040_route_revisions.test.sql`, migration `cycle_6_route_revisions`, `contracts.ts`, `contracts.test.ts` em `route-calculate`.

**Interfaces:** Produces:

```sql
public.request_trip_route_calculation(p_trip_id uuid) returns bigint
public.get_route_calculation_input(p_trip_id uuid,p_revision bigint) returns jsonb
public.apply_trip_route_result(p_trip_id uuid,p_revision bigint,p_result jsonb) returns text
```

As duas últimas são internas com EXECUTE somente `service_role`. Pedido exige owner/driver autorizado, respeita estado e eventos de desvio; não concede ao cliente poder de aplicar geometria arbitrária. Revisão nova não dispara provedor enquanto integração estiver em espera.

```ts
export type RoutePoint={id:string;kind:'origin'|'home'|'school'|'destination';
 latitude:number;longitude:number;schoolOrder:number|null};
export type RouteInput={tripId:string;revision:number;points:RoutePoint[];
 departureAt:string;schoolOrder:string[]};
export type RouteResult={revision:number;orderedPointIds:string[];
 distanceMeters:number;durationSeconds:number;calculatedAt:string;
 legs:{fromId:string;toId:string;durationSeconds:number;distanceMeters:number}[]};
export function validateRouteResult(input:RouteInput,result:unknown):RouteResult;
```

- [ ] **Step 1 — RED de revisão obsoleta e escola reordenada.**

```sql
select throws_ok($$select public.apply_trip_route_result(
 '76000000-0000-0000-0000-000000000001',1,'{}'::jsonb)$$,
 'PGRST',null,'resultado inválido não substitui percurso');
```

Teste TS usa entrada origem/escola1/escola2/destino e resultado trocando escolas; esperar erro. Run: `supabase test db supabase/tests/database/040_route_revisions.test.sql` e `deno test supabase/functions/route-calculate/contracts.test.ts`.

- [ ] **Step 2 — Implementar versão e CAS.** Criar `trip_route_calculations(id,trip_id,fleet_id,revision,status,input_hash,result,created_at,applied_at,error_code)` com unique `(trip_id,revision)`; status `pending|manual|calculated|failed|superseded`. RLS bloqueia conteúdo completo ao participante comum.

`input_hash` inclui passageiros/pontos/escolas/ordem/agenda/origem/destino e configuração; nada de recalcular só porque contagem mudou. Aplicação bloqueia viagem e compara revisão atual. Resposta atrasada marca `superseded` e não altera paradas. Geometria externa só será persistida se termos do fornecedor permitirem.

```ts
const ids=result.orderedPointIds;
if(ids.length!==input.points.length||new Set(ids).size!==ids.length)
 throw new Error('invalid_route_points');
if(ids.some(id=>!input.points.some(point=>point.id===id)))
 throw new Error('unknown_route_point');
```

Completar verificação de origem/destino, ordem relativa das escolas, trechos encadeados, números finitos/não negativos e revisão igual. Em modo manual, ordem do dono e pontos válidos bastam para início, com ETA NULL; endereço não localizado exige correção de ponto antes de iniciar. Cadastro não afeta viagem ativa.

- [ ] **Step 3 — GREEN de modo manual e revisão.**

```bash
supabase db reset --local
supabase test db supabase/tests/database/040_route_revisions.test.sql
deno test supabase/functions/route-calculate/contracts.test.ts
```

Testar mesma lista com endereço novo, escola nova após prazo, corrida edição×resposta e início×edição, resultado inválido, falha externa representada sem endereço antigo e ausência de geometria para responsáveis.

## Task 5: Retenção, ETA e integração de alertas

**Files:** Create `041_tracking_retention.test.sql`, migration `cycle_6_alerts_retention`.

**Interfaces:** Produces:

```sql
private.expire_trip_locations(p_now timestamptz) returns integer
private.evaluate_trip_proximity(p_trip_id uuid,p_now timestamptz) returns integer
```

Consumir `private.create_notification` e `private.notification_actionable` do Ciclo 5. Só avaliar ETA calculado e ainda válido, nunca inventar ETA a partir de ordem manual ou GPS antigo. ETA por passageiro armazenado com `calculated_at`, revisão e prazo de validade, sem contaminar snapshots concluídos.

Adicionar a `trip_passengers`: `eta_at timestamptz`, `eta_calculated_at timestamptz`, `eta_valid_until timestamptz`, `eta_revision bigint`, todos nulos em modo manual. O cálculo válido ancora ETA em posição/horário atuais, não soma durações antigas à partida planejada para fingir atualização. A Task 7 popula esses campos por integração; até lá somente fixtures transacionais produzem ETA fake.

- [ ] **Step 1 — RED de retenção e alerta obsoleto.**

```sql
select has_function('private','expire_trip_locations',
 array['timestamp with time zone'],'retenção é testável por relógio');
select is(private.evaluate_trip_proximity(
 (select id from operation_ids where kind='going'),'2026-09-14 12:00+00'),0,
 'sem ETA válido não cria proximidade');
```

- [ ] **Step 2 — Implementar expiração e chaves.**

```sql
delete from public.trip_location_points
where captured_at < p_now - interval '30 days';
```

Também remover posição atual antiga/inaplicável que reteria GPS indefinidamente; não apagar `trip_events`, auditoria ou resumos. Captura tardia não reinicia relógio da retenção. Calcular resumos antes da expiração apenas com dados verificáveis.

Proximidade usa limiar da rota (default 10min) e chave `trip_id:student_id:approaching`; chegada usa evento de parada operacional `mark_trip_stop_reached` já existente. Uma chave não recebe PII. Antes de enfileirar e enviar, verificar viagem ativa, aluno confirmado e não desembarcado/ausente. Avaliar no recebimento de ETA atual, sem alertar retrospectivamente por lote offline.

Agendar expiração diária com nome único; criar job via migration e conferir duplicação. Enquanto provider estiver em espera, testes usam ETA fake inserido somente na transação de teste; produção não emite proximidade automática sem fonte válida.

- [ ] **Step 3 — GREEN da integração.**

```bash
supabase db reset --local
supabase test db supabase/tests/database/041_tracking_retention.test.sql
supabase test db supabase/tests/database/036_notification_delivery.test.sql
```

Testar 29/30/31 dias, amostra recebida tarde, resumos preservados, dedup, sinal desatualizado e desembarque ocorrido entre claim e envio. Revalidar utilidade imediatamente antes do envio; aceitar que mensagem já aceita pelo provedor antes do desembarque não é recolhível.

## Task 6: WebSocket real, duas sessões e publicação parcial independente

**Files:** Create `supabase/tests/realtime/tracking.test.ts`, `fixtures.ts`, `supabase/tests/concurrency/tracking.py`, `docs/operations/ciclo-6-production.md`.

**Interfaces:** fixture exporta `createTrackingFixture():Promise<{driver:SupabaseClient,guardian:SupabaseClient,owner:SupabaseClient,tripId:string,assignmentId:string,studentId:string,cleanup:()=>Promise<void>}>`. Usar `SupabaseClient` de `npm:@supabase/supabase-js@2.116.0`, versão verificada no registry em 2026-09-07; registrar lock Deno em `supabase/tests/realtime/deno.lock`. Clientes autenticam pela API Auth local, não por JWT inventado. Fixture entrega viagem ativa, aluno confirmado e embarcado. `cleanup()` remove somente fixtures locais. Guardar credenciais em memória, nunca imprimir.

- [ ] **Step 1 — RED com canal antigo aberto.** Usar cliente Realtime oficial com o import fixado acima; não adicionar dependência ao npm raiz por conveniência.

```ts
import {createTrackingFixture} from './fixtures.ts';
import type {SupabaseClient} from 'npm:@supabase/supabase-js@2.116.0';
async function rpc(client:SupabaseClient,name:string,args:Record<string,unknown>){
 const {data,error}=await client.rpc(name,args);
 if(error) throw new Error(error.code);
 return data;
}
async function subscribe(client:SupabaseClient,topic:string,seen:number[]){
 const channel=client.channel(topic,{config:{private:true}})
  .on('broadcast',{event:'location'},({payload})=>seen.push(payload.sequence));
 await new Promise<void>((resolve,reject)=>{
  const timer=setTimeout(()=>reject(new Error('subscribe_timeout')),5000);
  channel.subscribe(status=>{
   if(status==='SUBSCRIBED'){clearTimeout(timer);resolve();}
   if(status==='CHANNEL_ERROR'||status==='TIMED_OUT'){
    clearTimeout(timer);reject(new Error(status));
   }
  });
 });
 return channel;
}
async function until(predicate:()=>boolean){
 const deadline=Date.now()+5000;
 while(!predicate()){
  if(Date.now()>deadline) throw new Error('event_timeout');
  await new Promise(resolve=>setTimeout(resolve,20));
 }
}
Deno.test('desembarque cessa publicações na conexão antiga',async()=>{
 const fixture=await createTrackingFixture();
 try {
  const {driver,guardian,owner,tripId,assignmentId,studentId}=fixture;
  const previous=await rpc(guardian,'get_trip_tracking',{p_trip_id:tripId});
  const oldSeen:number[]=[],ownerSeen:number[]=[];
  await subscribe(guardian,previous.topic,oldSeen);
  const point=(sequence:number)=>({sequence,captured_at:new Date().toISOString(),
   latitude:0,longitude:0,accuracy:5,speed:0,heading:0});
  await rpc(driver,'ingest_trip_locations',{p_trip_id:tripId,
   p_assignment_id:assignmentId,p_points:[point(1)],p_live:true});
  await until(()=>oldSeen.includes(1));
  await rpc(driver,'record_passenger_event',{p_trip_id:tripId,p_student_id:studentId,
   p_kind:'dropped_off',p_command_id:crypto.randomUUID()});
  const current=await rpc(owner,'get_trip_tracking',{p_trip_id:tripId});
  if(current.topic===previous.topic) throw new Error('epoch_not_rotated');
  await subscribe(owner,current.topic,ownerSeen);
  await new Promise(resolve=>setTimeout(resolve,1100));
  await rpc(driver,'ingest_trip_locations',{p_trip_id:tripId,
   p_assignment_id:assignmentId,p_points:[point(2)],p_live:true});
  await until(()=>ownerSeen.includes(2));
  await new Promise(resolve=>setTimeout(resolve,1000));
  if(oldSeen.includes(2)) throw new Error('revoked_channel_received_location');
  const denied=await guardian.rpc('get_trip_tracking',{p_trip_id:tripId});
  if(!denied.error) throw new Error('revoked_user_can_query_tracking');
  let joined=false;
  try{await subscribe(guardian,current.topic,[]);joined=true;}
  catch(error){
   if(!(error instanceof Error)||error.message!=='CHANNEL_ERROR') throw error;
  }
  if(joined) throw new Error('revoked_user_joined_new_epoch');
 } finally { await fixture.cleanup(); }
});
```

O teste precisa falhar no baseline sem rotação. Timeout de ausência é apenas a janela de observação, com recebimento positivo pelo owner como prova de que o broadcast aconteceu. `cleanup` remove também todos os canais dos três clientes e chama sign-out antes de limpar usuários/dados locais. A fixture deve recusar URL que não seja loopback antes de qualquer criação.

- [ ] **Step 2 — Completar matriz real e concorrência.** Rodar variantes: ausência, motorista substituído, responsável removido, outro dependente mantendo acesso, época conhecida mas negada, ingestão direta maliciosa e chamada após término. `tracking.py` usa dois processos psql locais com barreira, sem dados reais, para revogação×ingestão e revisão×aplicação de resultado.

```bash
deno test --allow-net=127.0.0.1,localhost --allow-env supabase/tests/realtime
python3 supabase/tests/concurrency/tracking.py
```

Antes da execução, fixtures recusam hosts externos; não usar esses testes contra produção. Teste iOS/Android controlado valida cadência, perda de conexão e consumo de bateria como integração, sem afirmar resultado apenas por teste SQL.

- [ ] **Step 3 — Gate local e publicação parcial identificada.**

```bash
supabase db reset --local
supabase test db
deno test supabase/functions/route-calculate/contracts.test.ts
git diff --check
```

Executar lint/advisors e quality gate somente leitura. Se Tasks 1–6 estiverem completas, o runbook pode publicar GPS/privacidade/modo manual após conferir destino, migrations, recuperação e canais privados. Usar `supabase db push --linked --dry-run` e depois `supabase db push --linked`, sem seed/reset. Verificar dois usuários controlados em produção, sem harness destrutivo.

Registrar como entrega parcial: rastreamento publicado, provedor em espera. Não marcar Ciclo 6 concluído, nem exibir otimização/ETA como disponíveis.

## Task 7: Retomar escolha e implementar integração externa

**Estado:** bloqueada por decisão explícita de stand-by; não executar pesquisa comercial, criar `provider.ts` ou habilitar chamadas reais enquanto essa decisão não for retomada.

**Files:** somente após liberação, Create `docs/research/2026-09-07-mapas-decisao.md`, `route-calculate/index.ts`, `provider.ts`, `provider.test.ts`; Modify `.env.example`, spec e plano somente com escolha real. Se a retomada ocorrer em outra data, usar a data real no nome da pesquisa e atualizar a referência.

**Interfaces:** `calculateRoute(input:RouteInput,fetchImpl:typeof fetch):Promise<RouteResult>` em `provider.ts`; `geocodeAddress(address:Record<string,string>,fetchImpl:typeof fetch):Promise<{latitude:number;longitude:number;label:string}>`. Chamada server-side, autorização de dono/driver verificada por RPC antes de retornar dados operacionais.

- [ ] **Step 1 — Registrar decisão verificável.** Confirmar retomada com o usuário, pesquisar fontes oficiais e registrar: fornecedor, cobertura regional, geocoding, limite de pontos e matriz para 30 alunos+escolas/origem/destino, restrição da ordem das escolas, trânsito/ETA, quotas, custo aceito, termos de armazenamento e atribuição. Sem esses dados, a task continua bloqueada; não preencher nomes fictícios.

- [ ] **Step 2 — Escrever REDs do adaptador com respostas reais sanitizadas.**

```ts
import {calculateRoute} from './provider.ts';
Deno.test('indisponibilidade do provedor não produz rota falsa',async()=>{
 const fake:typeof fetch=async()=>new Response('unavailable',{status:503});
 let rejected=false;
 try { await calculateRoute({tripId:'test',revision:1,points:[
   {id:'origin',kind:'origin',latitude:0,longitude:0,schoolOrder:null},
   {id:'destination',kind:'destination',latitude:0.01,longitude:0.01,schoolOrder:null}],
   departureAt:'2026-09-14T11:00:00Z',schoolOrder:[]},fake); }
 catch { rejected=true; }
 if(!rejected) throw new Error('resultado externo inválido foi aceito');
});
```

Acrescentar teste com limite completo de pontos e contar chamadas no fake para provar que a falha 503 veio do fornecedor, não de validação anterior. Exigir timeout, quota, resposta inválida e revisão obsoleta. Teste de sucesso usa fixtures sanitizadas do fornecedor efetivamente escolhido, nunca resposta genérica inventada como prova de compatibilidade.

- [ ] **Step 3 — Implementar fornecedor único e geocodificação.** Usar fetch com timeout, secrets server-side e conversão para tipos Task 4. `validateRouteResult` valida antes de `apply_trip_route_result`. Cálculo iniciado com revisão X só aplica em X; caso contrário descartar/registrar superseded. Se precisar dividir chamadas, provar continuidade/ordem/capacidade de pontos; não assumir otimização global por concatenação.

Geocoding aplica resultado somente à revisão/endereço ainda atual; resposta ambígua/falha exige ponto manual do dono. Não reescrever snapshot ativo. Registrar estado de falha sem persistir payload externo completo ou infringir termos escolhidos.

- [ ] **Step 4 — GREEN e verificação representativa.**

```bash
deno test supabase/functions/route-calculate
deno check supabase/functions/route-calculate/index.ts
supabase test db supabase/tests/database/040_route_revisions.test.sql
```

Com autorização/credenciais já disponíveis, executar cálculo controlado de 30 alunos e múltiplas escolas, validar ponto-a-ponto, ordem das escolas, duração, ETA e quantidade de chamadas. Registrar custos/quotas observados sem prometer escala não medida.

## Task 8: Publicar integração e fechar o ciclo completo

**Pré-condições:** Tasks 1–7 concluídas, escolha aprovada, credenciais reais, testes locais e integração mobile disponíveis. Stand-by não satisfaz esta condição.

**Files:** Modify `docs/operations/ciclo-6-production.md`, `README.md`, `be-tech-plan.md`, `deliverables.md`.

**Interfaces:** Consumes Tasks 1–7, `route-calculate` e FCM publicados; Produces evidência de integração completa em produção e estado final do Ciclo 6.

- [ ] **Step 1 — Gate completo local.**

```bash
supabase db reset --local
supabase test db
deno test supabase/functions/route-calculate
deno test supabase/functions/notification-dispatch
deno test --allow-net=127.0.0.1,localhost --allow-env supabase/tests/realtime
supabase db lint --local --schema public,private --fail-on error
supabase db advisors --local --type all --level warn --fail-on error
git diff --check
git status --short
```

Quality gate somente leitura. Revalidar termos/quotas do provedor escolhido e histórico das migrations; nenhum segredo nos diffs.

- [ ] **Step 2 — Publicar com recuperação preparada.**

```bash
: "${SUPABASE_PROJECT_REF:?Projeto de produção verificado}"
supabase link --project-ref "$SUPABASE_PROJECT_REF"
supabase db push --linked --dry-run
supabase db push --linked
supabase functions deploy route-calculate --project-ref "$SUPABASE_PROJECT_REF"
```

Carregar segredos por arquivo/canal seguro, habilitar apenas a integração verificada e conferir configuração privada do Realtime. Recuperação: desabilitar chamadas externas falhas, conservar operação manual/pontos válidos e aplicar correção versionada; não apagar trilha/eventos nem restaurar endereço antigo silenciosamente.

- [ ] **Step 3 — Verificar produção e registrar conclusão.** Fluxo controlado com iOS e Android: novo endereço antes da saída, cálculo, confirmação, início, GPS, perda/reconexão, embarque, proximidade válida, desembarque, perda de mapa e conclusão. Verificar retenção/job e alertas sem duplicação interna; revisar custo observado.

Registrar três evidências separadas: validação local; publicação e smoke de rastreamento; publicação e smoke de integração externa. Só então marcar Ciclo 6 completo. Falta de provedor, credencial ou validação mobile permanece pendência explícita.

## Cobertura

| Requisito | Task |
| --- | --- |
| ingestão/cadência/posição atual | 1 |
| autorização/revogação/projeções | 2, 6 |
| offline e histórico de atribuição | 3 |
| vigência/cálculo/CAS/manual | 4, 7 |
| retenção/ETA/alertas | 5 |
| WebSocket e concorrência real | 6 |
| provedor em espera/seleção | 7 |
| publicação parcial e completa | 6, 8 |

Referências: [Realtime Authorization](https://supabase.com/docs/guides/realtime/authorization), [Broadcast](https://supabase.com/docs/guides/realtime/broadcast), [restrição do schema Realtime](https://supabase.com/changelog/realtime-schema-locked-down-against-modification). Consultadas em 2026-09-07; conferir assinaturas na execução.

## Registro de execução

Backend validado na release integrada em 2026-09-08: 850 assertions pgTAP, 45 testes Deno, 14 disputas PostgreSQL e WebSocket real. Evidência consolidada, publicação e pendências externas em [deliverables.md](../../../deliverables.md) e no runbook do ciclo. Os checklists acima descrevem a sequência de trabalho, não comprovam ativação de serviços externos.

Tasks 7–8 permanecem em espera pela escolha/orçamento do provedor; ETA externo e geocodificação não foram implementados.
