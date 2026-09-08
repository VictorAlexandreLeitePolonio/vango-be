# Operação do Ciclo 3 — frota e planejamento

## Destino e estado da entrega

Projeto verificado: VanGo (`njjeopcxhnkeszukaoma`), região `sa-east-1`, PostgreSQL 17.6.1.166. A homologação é o Supabase local; não existe staging remoto. O responsável pela publicação é Victor Polonio, na branch `dev-polonio`.

O preflight remoto somente leitura encontrou 16 migrations dos Ciclos 0–2, zero vínculos ativos, zero frotas e zero escolas. Nenhuma alocação legada precisa ser inventada. A carga manual de instituições reais permanece necessária antes de abrir o marketplace. A compatibilidade com uma versão Flutter publicada ainda não foi verificada.

As sete migrations deste ciclo começam em `20260907235802` e terminam em `20260907235814`. O registro definitivo de publicação e smoke fica em `deliverables.md`; este documento não presume que `db push` já ocorreu.

## Contratos operacionais

- Aprovar reserva atomicamente todas as combinações de dias e sentidos. O custo dessa garantia é manter a vaga ocupada mesmo com ausência; não existe reutilização por trecho. Falha de capacidade preserva pedido e reservas anteriores.
- A fila reúne pedidos e alterações em `pending`/`waitlisted`, por chegada. O dono decide aceitar ou recusar; a data escolhida para um pedido novo não permite ultrapassar outro integralmente atendível. Preferências de van são informativas.
- Alterações recorrentes preservam reservas até a vigência aprovada. Os prazos das execuções antigas e novas determinam essa data.
- Endereço e escola conservam o vínculo; o Ciclo 4 atualiza apenas viagens não iniciadas. O dono resolve a logística. Ao editar uma rota, escolas referenciadas por reservas ativas ou futuras permanecem no conjunto; adicionar escolas e reordenar as paradas continua permitido.
- Vans e motoristas exigem disponibilidade e ausência de conflito entre janelas reais. Suspensão, saída e retirada do papel são bloqueadas por atribuições futuras ou ativas.
- Rotas inativas não reservam van ou motorista para novas agendas. Reativar uma rota ou alterar seus recursos passa pela mesma validação de conflitos futuros.
- O lock de planejamento é global e transacional. É uma escolha deliberada para o volume inicial; medir contenção antes de particionar locks, preservando conflitos entre frotas.

## Evidência local

A restauração do baseline local seguida das sete migrations, executadas como `postgres`, passou. A suíte dos Ciclos 0–3 passou com 24 arquivos e 329 assertions pgTAP (178 do baseline e 151 do Ciclo 3). Os cenários adicionais de criação de agenda após suspensão/inativação e prioridade entre vigências diferentes tiveram RED reproduzido e GREEN após correção.

Os três regressions finais do Ciclo 3 também passaram no DB3 isolado: a edição de `route_schools` preserva escolas usadas por reservas ativas/futuras e permite adição/reordenação; `next_change_date` encontra a primeira interseção finita de ida e volta mesmo quando a volta começa depois; e a validação de recursos permite reutilizar van/motorista de rota inativa. A rodada C3 017–023 terminou sem falhas (`/tmp/vango-c3-suite-017_vans.log` até `/tmp/vango-c3-suite-023_planning_privacy.log`), e as sete corridas reais de concorrência passaram com limpeza (`/tmp/vango-c3-races-final.log`).

O teste de upgrade usou um vínculo fictício aprovado pelo contrato anterior. As sete migrations preservaram a matrícula, a escola/turno e a referência ao pedido; não criaram reservas nem rotas fictícias. Foram nove assertions do contrato anterior e seis de preservação após o upgrade.

O teste de concorrência executa sete disputas com sessões PostgreSQL reais: última vaga; placa global em ambas as ordens; suspensão × atribuição em ambas as ordens; motorista entre frotas em ambas as ordens. A barreira observa o lock antes de liberar a primeira transação e exige o erro de domínio específico. A limpeza usa apenas os IDs das fixtures e falha explicitamente se não concluir.

```bash
# Banco isolado local com o baseline e todas as migrations C3 aplicadas.
env -u PGHOSTADDR -u PGSERVICE -u PGSERVICEFILE \
PGHOST=127.0.0.1 PGPORT=54322 PGDATABASE=vango_cycle_3 PGUSER=postgres \
  python3 supabase/tests/concurrency/planning.py

# Após fechar os demais ciclos e reconstruir o Supabase local integrado.
python3 supabase/tests/run_database_tests.py
supabase db lint --local --schema public,private --fail-on error
```

Fornecer `PGPASSWORD` pelo ambiente e disponibilizar `psql` no PATH. O harness recusa host remoto, substituição de host via serviço e banco diferente de `vango_cycle_3`. Não executar fixtures em produção.

## Publicação e recuperação

1. Revalidar o projeto vinculado e o histórico; conferir novamente vínculos ativos e mudanças remotas desde o preflight.
2. Concluir reset integrado, suíte completa, concorrência e `software-quality-gate`. Registrar resultados reais em `deliverables.md`.
3. Conferir o ponto de recuperação disponível no projeto e preservar o schema anterior. Se surgirem vínculos legados sem reservas, preparar um plano de dados antes de publicar; não preencher alocações por suposição.
4. Executar `npx supabase db push --dry-run` e comparar a lista com a release validada; então executar `npx supabase db push`, conforme autorização do usuário. Nunca usar reset remoto, seed ou `--include-all` para contornar divergência.
5. Conferir versões aplicadas, RLS, grants e assinaturas das RPCs com consultas somente leitura. Validar Auth, SMTP e callbacks Flutter com a configuração real antes de abrir o fluxo ao público.

Se houver falha, interromper a publicação, preservar dados e aplicar correção por nova migration. Não reescrever migrations já aplicadas. Restauração de backup exige avaliar o impacto sobre dados criados após o ponto de recuperação. A publicação das migrations não equivale à validação de dispositivos ou à ativação dos jobs dos ciclos seguintes.

## Publicação verificada em 2026-09-08

As migrations SQL deste ciclo foram aplicadas por `npx supabase db push` após validação local integrada. O remoto confirma 41 migrations no total, sem tabelas públicas desprotegidas por RLS nem SECURITY DEFINER sem search_path. Os três jobs permanecem inativos. Configurações externas, deploy do worker, ativação operacional e dispositivos não fazem parte dessa confirmação SQL. Detalhes em [deliverables.md](../../deliverables.md).
