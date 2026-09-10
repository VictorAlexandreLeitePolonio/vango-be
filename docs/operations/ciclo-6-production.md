# Operação do Ciclo 6 — rastreamento e roteirização

Este runbook cobre a entrega parcial das Tasks 1–6: ingestão autenticada de
GPS, canais Realtime privados, sincronização histórica, revisão de percurso,
retenção de 30 dias e alertas de proximidade alimentados por ETA válido. O
provedor de mapas, geocodificação, otimização e ETA externo permanece em
stand-by; sem essa fonte, a viagem manual exibe ETA nulo e não cria alerta de
proximidade.

## Destinos e limites

O teste transacional e o teste de concorrência usam somente o banco local
descartável `vango_cycle_6`, em `127.0.0.1:54322`. Antes de cada execução,
confirme o nome do banco e o usuário. O harness recusa hosts remotos, serviços
que substituem o host e qualquer banco diferente do DB6.

As tabelas de localização não têm DML direto para clientes. O motorista envia
amostras por `public.ingest_trip_locations`; a função verifica e-mail
confirmado, atribuição vigente, viagem ativa para o modo ao vivo, limites de
captura e deduplicação. O histórico amostra por janela fixa de 30 segundos e preserva também a última posição recente em eventos operacionais online. Eventos offline não recebem a posição atual. Receipts conservam a idempotência por sequência. A posição atual é publicada somente no tópico privado da época
vigente.

## Validação local

Execute a suite integrada com includes expandidos automaticamente:

```bash
python3 supabase/tests/run_database_tests.py
```

C6: 154 assertions (31 GPS, 24 acesso, 25 offline, 33 revisoes, 41 retencao/ETA). O teste transacional roda em `postgres`; a concorrencia exige um clone local descartavel `vango_cycle_6` do schema final, sem pg_cron (extensao exclusiva do banco configurado no scheduler).

As duas sessões PostgreSQL reais verificam revogação de atribuição enquanto
uma ingestão aguarda o lock de planejamento e edição de endereço enquanto uma
resposta de percurso aguarda aplicação. Execute com credencial fornecida pelo
ambiente, sem imprimir a DSN:

```bash
VANGO_TEST_DATABASE_URL='postgresql://supabase_admin:REDACTED@127.0.0.1:54322/vango_cycle_6' \
PGPASSWORD="$LOCAL_DB_PASSWORD" \
  python3 supabase/tests/concurrency/tracking.py
```

O harness usa WebSocket nativo e JWTs ficticios assinados somente com a configuracao local, sem imprimir tokens. Opera no Supabase local em `postgres`, valida IDs livres e limpa as fixtures ao final:

```bash
deno run --allow-run --allow-read --allow-env --allow-net supabase/tests/concurrency/tracking.ts
```

Mantenha um tópico antigo aberto durante desembarque, ausência, remoção e
substituição. Depois da rotação da época, a sessão antiga não recebe a nova
posição; a sessão autorizada consulta o novo tópico e o usuário revogado não
entra nele. Não registre JWTs, chaves, receipts completos, endereços ou
coordenadas de alunos nos logs.

## Retenção, alertas e jobs

`private.expire_trip_locations(p_now)` recebe o relógio explicitamente. Remove
GPS bruto, receipts e projeções correntes fora dos 30 dias pelo horário
capturado, ou uma projeção corrente que já não pertence a uma viagem ativa.
Eventos operacionais, auditoria, snapshots e resumos verificáveis ficam
preservados. Antes de apagar a trilha, a migration materializa em
`private.trip_location_summaries` a contagem e as primeiras/últimas capturas
que foram comprovadas pelos pontos persistidos; ela não inventa distância ou
duração a partir de uma amostragem. A captura recebida tarde não reinicia a
retenção.

`private.evaluate_trip_proximity(trip_id, p_now)` só considera passageiro
confirmado em `waiting` ou `boarded`, vínculo ativo, ETA calculado, válido,
futuro e da revisão de rota calculada aplicada. A chave é
`trip_id:student_id:approaching`; o corpo contém apenas IDs, horário e revisão.
`private.notification_actionable` revalida viagem, participação, ETA,
revisão, cálculo e autorização antes do envio da fila do Ciclo 5.

A migration cria no banco configurado para `pg_cron` um único job diário
chamado `vango-location-retention`, inicialmente inativo. O responsável deve
conferir `cron.database_name`, a unicidade e as permissões antes de ativá-lo;
no DB6 isolado de testes ele deve permanecer inativo e sem execução do
scheduler. Antes de ativar, execute uma chamada controlada e confira apenas
contagens:

```sql
select private.expire_trip_locations(clock_timestamp());
select private.evaluate_trip_proximity(:trip_id, clock_timestamp());
```

Não habilite avaliação de proximidade a partir de GPS offline ou ordenação
manual; o provedor em espera não é substituído por valor calculado no cliente.

## Publicação parcial e recuperação

Antes da publicação, confira migrations em ordem, RLS, grants, policies do
Realtime e o destino. A aplicação no projeto remoto e a criação do job ficam
sob coordenação do responsável; não use reset, seed ou `--include-all` no
destino. Faça dry-run, preserve o ponto de recuperação e aplique correções por
uma nova migration.

Se o Realtime falhar, mantenha a consulta RPC e o modo manual com ETA nulo;
revogue a sessão por nova época antes de investigar. Se a retenção ou o
materializador falhar, pause o job, preserve eventos e snapshots e corrija a
função por migration. A entrega das Tasks 1–6 não confirma dispositivos móveis,
produção ou integração externa.

## Publicação verificada em 2026-09-08

As migrations SQL deste ciclo foram aplicadas por `npx supabase db push` após validação local integrada. O remoto confirma 41 migrations no total, sem tabelas públicas desprotegidas por RLS nem SECURITY DEFINER sem search_path. Os três jobs permanecem inativos. Configurações externas, deploy do worker, ativação operacional e dispositivos não fazem parte dessa confirmação SQL. Detalhes em [deliverables.md](../../deliverables.md).
