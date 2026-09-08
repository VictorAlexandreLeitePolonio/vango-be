# Operação do Ciclo 5 — notificações

Este runbook cobre a preparação e a publicação controlada da caixa de notificações, da fila de entregas e do dispatcher FCM. As migrations criam um job `pg_cron` chamado `notification-dispatch` a cada minuto, mas deixam o job desativado. A função também materializa eventos e lembretes antes de enfileirar a chamada HTTP para a Edge Function.

A preparação verificada em 2026-09-07 aponta para o projeto Supabase VanGo `njjeopcxhnkeszukaoma` em `sa-east-1`, PostgreSQL 17.6.1.166. A publicação SQL foi concluída conforme o registro ao final. Credenciais, Edge Function, ativação do job e dispositivos permanecem pendentes.

## Dependências e nomes

A migration exige as extensões `pg_net` e `pg_cron`. O `pg_cron` deve estar instalado no banco configurado por `cron.database_name` (no projeto hospedado, `postgres`). A ausência da extensão interrompe a aplicação da migration e deve ser resolvida antes de prosseguir.

A Edge Function `notification-dispatch` recebe `verify_jwt=false` porque a autenticação interna usa `x-worker-secret`. Os nomes que precisam receber valores por canal seguro são:

- Vault/Postgres: `notification_worker_url` e `notification_worker_secret`.
- Edge: `NOTIFICATION_WORKER_SECRET`, `FCM_PROJECT_ID`, `FCM_CLIENT_EMAIL` e `FCM_PRIVATE_KEY`.
- Runtime Supabase injetado: `SUPABASE_URL` e `SUPABASE_SERVICE_ROLE_KEY`.

Os valores reais ficam no Vault, nos secrets da Edge ou no runtime protegido. Não registrar bearer, chave privada, token FCM ou corpo de uma notificação.

## Pré-publicação

1. Confirme o projeto, a região, o banco alvo e o estado das extensões:

   ```sql
   select current_database();
   select name, installed_version
   from pg_available_extensions
   where name in ('pg_cron', 'pg_net');
   show cron.database_name;
   ```

2. Faça a revisão da migration e aplique o conjunto C0–C5 no banco de homologação. Confirme que `cron.job` contém exatamente um job chamado `notification-dispatch` e que `active` é `false`.

3. Cadastre `notification_worker_url` e `notification_worker_secret` no Vault e os quatro secrets FCM na Edge. O endpoint deve usar HTTPS em produção e aceitar apenas a chamada interna com o segredo configurado.

4. Defina o corte de ativação depois de revisar os eventos existentes. Use o maior `trip_events.id` aprovado pelo operador; não avance o corte a cada lote:

   ```sql
   begin;
   select id, activation_event_id, enabled
   from private.notification_worker_state
   where id = true
   for update;
   update private.notification_worker_state
   set activation_event_id = :activation_event_id,
       enabled = true,
       activated_at = clock_timestamp()
   where id = true;
   select cron.alter_job(jobid, active := true)
   from cron.job
   where jobname = 'notification-dispatch';
   commit;
   ```

   A migration cria a linha singleton desativada; se a consulta não retornar uma linha, interrompa a ativação e corrija a aplicação das migrations. A ativação só deve ocorrer depois de confirmar que os secrets estão presentes.

5. Faça uma execução controlada e confira somente estados e contagens:

   ```sql
   select private.dispatch_notification_worker();
   select state, count(*)
   from public.notification_deliveries
   group by state
   order by state;
   ```

## Operação e desativação

A cada tick, `private.dispatch_notification_worker()` materializa eventos novos, cria lembretes de confirmação ainda pendentes e enfileira uma chamada HTTP para a Edge. A Edge autentica o segredo, reivindica até dez entregas, revalida cada concessão, envia até quatro itens em paralelo e conclui cada item por CAS. A caixa permanece disponível mesmo quando um token é desativado ou uma entrega falha.

Para pausar o envio, desative primeiro o job e depois a materialização:

```sql
begin;
select cron.alter_job(jobid, active := false)
from cron.job
where jobname = 'notification-dispatch';
update private.notification_worker_state
set enabled = false
where id = true;
commit;
```

Não apague notificações ou entregas como parte de uma pausa. Para retomar, corrija a causa, confirme os secrets, verifique o cursor e habilite o estado e o job na ordem descrita acima. Migrations aplicadas são imutáveis; correções posteriores devem ser novas migrations.

## Diagnóstico seguro

- `worker_not_configured`: confira a existência dos dois nomes no Vault e mantenha o job desativado até corrigir.
- `worker_dependency_missing`: confirme `pg_net`, `pg_cron`, o schema `net` e `cron.database_name` no banco correto.
- Crescimento de `pending` ou `processing`: consulte estado, idade e contagem da fila sem selecionar `body`, token ou segredo:

  ```sql
  select state, count(*), min(next_attempt_at), max(next_attempt_at)
  from public.notification_deliveries
  group by state
  order by state;
  ```

- Um lease expirado é recuperável pelo próximo claim. Uma resposta externa ambígua pode repetir o push; o sistema não promete exactly-once fora do banco.

## Validação local e pós-publicação

No banco isolado de testes, confirme o nome do banco antes de executar comandos e use a DSN somente no ambiente local:

```bash
VANGO_PSQL="${VANGO_PSQL:-psql}" \
VANGO_TEST_DATABASE_URL='postgresql://supabase_admin:postgres@127.0.0.1:54322/vango_cycle_5' \
  python3 supabase/tests/database/036_notification_delivery_concurrency.py

deno test supabase/functions/notification-dispatch
deno lint supabase/functions/notification-dispatch
```

Antes de declarar a publicação, faça um envio controlado para um dispositivo Android e um iOS de teste, valide abertura autenticada da caixa, teste token inválido e confirme a recuperação de uma concessão expirada. A configuração APNs/Firebase, permissões móveis e dispositivos de teste são dependências externas e não foram publicadas ou verificadas por este ciclo.

## Publicação verificada em 2026-09-08

As migrations SQL deste ciclo foram aplicadas por `npx supabase db push` após validação local integrada. O remoto confirma 41 migrations no total, sem tabelas públicas desprotegidas por RLS nem SECURITY DEFINER sem search_path. Os três jobs permanecem inativos. Configurações externas, deploy do worker, ativação operacional e dispositivos não fazem parte dessa confirmação SQL. Detalhes em [deliverables.md](../../deliverables.md).
