# Operação do Ciclo 4 — operação diária

Este runbook cobre a preparação local, a inspeção e a publicação controlada das viagens diárias. O ciclo inclui calendário, geração idempotente, confirmações, presença, substituições, ocorrências, reconciliação e o orquestrador diário. O job fica inativo até a revisão do operador; eventos produzidos pelo banco não significam que uma notificação foi entregue.

## Destino e estado da entrega

O destino verificado pelo responsável é o projeto VanGo (`njjeopcxhnkeszukaoma`), em `sa-east-1`, com PostgreSQL 17.6.1.166. A homologação usada para este ciclo é o banco Supabase local. O `db push` foi concluído conforme o registro ao final. Ativação do Cron e validação em dispositivos permanecem pendentes.

As migrations do Ciclo 4 são `20260907235815` até `20260907235829`, em ordem. Migrations aplicadas são imutáveis; qualquer correção posterior deve ser uma migration nova. Não usar reset, seed ou fixtures no destino remoto.

## Pré-publicação local

Recrie o ambiente integrado somente sob coordenação do responsável e execute a suíte pelo executor que expande os includes `.psql`:

```bash
python3 supabase/tests/run_database_tests.py
supabase db lint --local --schema public,private --fail-on error
```

O teste de concorrência usa somente o banco descartável `vango_cycle_4` e exige conexão local explícita:

```bash
PGHOST=127.0.0.1 PGPORT=54322 PGDATABASE=vango_cycle_4 PGUSER=postgres \
  PGPASSWORD="$LOCAL_DB_PASSWORD" \
  python3 supabase/tests/concurrency/operations.py
```

O harness abre sessões PostgreSQL reais e cobre início × alteração de endereço, início × encerramento, início duplo e substituição × suspensão. Ele aguarda o lock de planejamento, exige o erro de domínio esperado e limpa apenas os IDs da fixture. Não execute essa fixture em um banco remoto.

O teste `031_operation_jobs.test.sql` valida o orquestrador por chamada direta, a geração idempotente e a unicidade agenda/data. As quatro assertions que consultam `cron.job` precisam ser executadas no banco integrado configurado para o `pg_cron`; o banco local isolado DB4 não hospeda essa relação e serve apenas para as assertions de negócio do helper.

## Contratos operacionais

- O job chama `private.run_daily_operations(clock_timestamp())`. Cada execução calcula o amanhã local de cada fuso e chama a geração uma vez por data distinta; a geração percorre todas as frotas e é idempotente.
- `cron.job` deve conter exatamente um job chamado `vango-daily-operations`, com comando `select private.run_daily_operations(clock_timestamp());` e `active = false` antes da ativação.
- O `pg_cron` deve estar instalado no banco indicado por `cron.database_name` (no destino verificado, `postgres`). Se a extensão ou a tabela não estiverem disponíveis, interrompa a publicação.
- Confirmações vencem no limite do prazo. Depois do prazo e antes do início, somente o dono usa override com motivo persistido no evento; antes do prazo o override é rejeitado.
- Início, substituição, encerramento, presença e ocorrências mantêm o lock de planejamento antes dos locks de viagem e revalidam a autorização depois da espera.
- Uma viagem ativa conserva passageiros, presença e snapshots. Mudanças de endereço/escola afetam somente a próxima execução não iniciada; mudanças de agenda removem ou adicionam as datas afetadas sem resetar respostas inalteradas.
- Declined, expired e passageiros removidos saem da lista executável. A presença só opera sobre participantes confirmados e os eventos são append-only e idempotentes por viagem, comando, autor e payload.

## Inspeção antes de ativar

Depois de aplicar o conjunto validado no banco integrado, confira o destino, a extensão e o job em uma transação de leitura:

```sql
select current_database(), current_user;
show cron.database_name;
select extname, extversion
from pg_extension
where extname in ('pg_cron', 'pg_net');

select jobid, jobname, schedule, command, active
from cron.job
where jobname = 'vango-daily-operations';
```

A consulta deve retornar uma única linha para o job, `active = false`, frequência `* * * * *` e o comando registrado acima. O operador deve revisar grants das funções privadas, RLS, unicidades, eventos e os estados de viagens antes de qualquer ativação.

## Publicação e recuperação

1. Revalide o projeto vinculado, a região, o banco configurado e o histórico remoto de migrations. Compare o dry-run com os oito arquivos do Ciclo 4.
2. Execute a suíte local, a concorrência, o lint e a quality gate; preserve os relatórios de RED/GREEN em `/tmp/vango-cycle4-report.md`.
3. Faça a aplicação remota somente com a autorização do operador e sem reset. Se uma migration falhar, pare, preserve os dados e corrija por nova migration.
4. Mantenha `vango-daily-operations` inativo até confirmar os contratos e a configuração. A ativação é explícita:

   ```sql
   begin;
   select cron.alter_job(jobid, active := true)
   from cron.job
   where jobname = 'vango-daily-operations';
   commit;
   ```

5. Faça uma execução controlada e confira contagens, estados e a ausência de duplicatas. Não gere dados em massa nem altere reservas reais para provar o fluxo.

Para pausar o ciclo, desative o job primeiro e depois investigue a causa. Não remova histórico de viagens, atribuições, presença, ocorrências ou eventos para recuperar uma execução. O próximo deploy deve conter apenas migrations novas e uma validação equivalente antes de reativar o job.

## Publicação verificada em 2026-09-08

As migrations SQL deste ciclo foram aplicadas por `npx supabase db push` após validação local integrada. O remoto confirma 41 migrations no total, sem tabelas públicas desprotegidas por RLS nem SECURITY DEFINER sem search_path. Os três jobs permanecem inativos. Configurações externas, deploy do worker, ativação operacional e dispositivos não fazem parte dessa confirmação SQL. Detalhes em [deliverables.md](../../deliverables.md).
