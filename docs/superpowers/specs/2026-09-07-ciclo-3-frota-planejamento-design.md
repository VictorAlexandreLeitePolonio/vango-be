# Ciclo 3 — Frota e planejamento

**Data:** 7 de setembro de 2026
**Status:** aprovada em 2026-09-07; não implementada
**Implementation plan:** [Ciclo 3](../plans/2026-09-07-ciclo-3-frota-planejamento.md)
**Base:** Ciclos 0–2 locais; decisões registradas em `be-tech-plan.md`.

## Objetivo e corte

Fazer uma aprovação significar reserva integral de transporte, com vans, motoristas, rotas, agendas, fila e mudanças de programação. O ciclo evolui contratos do Ciclo 2; não acrescenta regras apenas a um novo caminho deixando o anterior aprovar sem capacidade.

Inclui:

- vans e unicidade global de placa entre cadastros ativos;
- convites de motorista e proteção das atribuições;
- rotas direcionais, escolas ordenadas e agendas com fuso;
- reservas recorrentes por aluno, dia e sentido;
- aprovação integral, fila conjunta e pedidos de alteração;
- preferências informativas de até três vans;
- endereço atual, escola vigente por vínculo e revisões de percurso;
- RLS, auditoria, contratos Flutter e publicação após validação local.

Exclui viagens diárias, presença, Cron operacional, GPS, push, provedor de mapas, importador de escolas e código Flutter. O catálogo real continua sendo uma carga manual separada, já prevista no repositório.

## Abordagem e trade-offs

Aprovar cria vínculo e reservas na mesma transação. Rejeita-se aprovar vínculo e alocar depois: é mais simples, mas permite transporte aprovado sem vaga, contrário à decisão do usuário.

Convite aceito de responsável/aluno cria pedido pendente, sem reservar capacidade nem criar vínculo. A análise do dono adiciona uma etapa, mas não bloqueia vagas por 14 dias aguardando o convidado.

Capacidade considera todos os alunos programados numa execução, sem reutilização de assentos por trecho. Uma van de 15 lugares aceita até 15 alunos naquela execução. Faltas e recusas diárias não liberam reservas recorrentes.

Não criar motor genérico de regras nem servidor paralelo. Reutilizar RPCs, helpers de autorização, fontes de papéis e auditoria existentes.

## Modelo proposto

| Entidade | Responsabilidade e invariantes |
| --- | --- |
| `vans` | frota, placa normalizada, modelo, identificação pública, capacidade positiva, estado e histórico; uma placa por cadastro ativo global |
| `routes` | frota, nome, sentido, par opcional, turno, van/motorista padrão, origem/destino e revisão do percurso |
| `route_schools` | instituições e ordem do dono; FKs reais, sem array de IDs |
| `route_schedules` | dias ISO, início e fim da janela reservada, fuso IANA, vigência e prazo de confirmação |
| `route_student_schedules` | vínculo, rota, dia, sentido e vigência; reservas anteriores permanecem históricas |
| `join_request_van_preferences` | pedido, van da frota e posição de 1 a 3, sem repetição |
| `fleet_join_requests` | ampliar para pedido inicial ou alteração, referência opcional ao vínculo e estado `waitlisted`; manter snapshot original |
| `fleet_enrollments` | vínculo e escola/turno vigentes; não usar o snapshot da solicitação como cadastro operacional mutável |
| `fleet_invitations` | ampliar os papéis para `driver`, reutilizando token, expiração e validação de e-mail |

Todas as relações operacionais carregam `fleet_id` e impedem combinar referências de tenants diferentes. Origem, destino e residências não integram projeções públicas. Coordenadas podem estar pendentes de resolução; isso não autoriza inventá-las.

Escola é por vínculo: o mesmo aluno pode ter relações distintas com instituições em frotas diferentes. Endereço residencial é global em `students`; sua alteração sinaliza revisão em todos os vínculos ativos afetados. Esta distinção é uma proposta técnica para revisão, pois o schema atual só guarda escola no pedido.

## Aprovação e fila

1. Autenticar, validar e-mail confirmado e dono ativo da frota.
2. Carregar o pedido, a programação vigente quando houver, os recursos envolvidos e a fila sob controle de concorrência.
3. Considerar juntos `pending` e `waitlisted`, pedidos iniciais e alterações. Ordenar por `created_at` atribuído pelo servidor, com `id` como desempate estável.
4. Identificar o pedido mais antigo integralmente atendível em escola, turno, dias, sentidos, capacidade e conflitos. Não basta verificar apenas a van escolhida pelo dono se outra alocação compatível atenderia um pedido anterior.
5. Pedido incompatível conserva antiguidade e não bloqueia o próximo compatível. O dono pode aceitar ou recusar; recusar tira o pedido da fila. Não existe promoção automática.
6. Validar o conjunto completo das alocações. Para alterações, descontar corretamente as reservas substituídas na data de vigência, sem liberar as anteriores antes dela.
7. Aprovar e gravar reservas, vínculo, fontes de papéis e auditoria atomicamente. Uma falha não deixa aprovação nem reserva parcial.

Os dias e sentidos pedidos são obrigação; preferências de van são informativas. Uma rota diferente da preferência é permitida quando cumpre o pedido. A lista de espera não revela dados de outros alunos ao solicitante.

Quando a análise constatar falta de atendimento integral, persistir `waitlisted` por uma transição explícita, sem lançar depois um erro que reverta o estado. Falha de aprovação por concorrência retorna conflito sem mutação parcial. O solicitante pode cancelar seu pedido ainda aberto; reenviar cria nova antiguidade, coerente com a imutabilidade do pedido.

## Motoristas, vans e agendas

Convite de motorista não exige aluno nem cria pedido de transporte. O aceite com o mesmo e-mail confirmado acrescenta a fonte manual `driver`, preserva outros papéis e não contorna suspensão existente. Dono que dirige também precisa de `driver`.

Van e motorista não podem ter janelas sobrepostas. O motorista é verificado entre frotas; o erro não identifica outra frota nem seus horários. O dono inclui deslocamento e margem no final da janela; não existe intervalo fixo adicional. Intervalos são tratados como início inclusivo e fim exclusivo, permitindo começar no término da reserva anterior.

A validação considera recorrência, vigência, fuso e cruzamento de meia-noite; não se limita às viagens já materializadas. Alunos também não podem ter programações conflitantes entre frotas no mesmo dia, turno e sentido, conforme contrato base. Não inferir autorização a partir do tenant enviado pelo cliente.

Antes de inativar uma van, substituir todas as atribuições futuras. A placa pode então ser ativada em outra frota, conservando o registro antigo. Suspensão, saída (`left`) e remoção de `driver` são bloqueadas enquanto houver atribuições. Os Ciclos 4 e 6 ampliam os mesmos comandos para viagens e autorização ao vivo.

Diminuir capacidade ou mudar van/agenda precisa revalidar reservas existentes; rejeitar a alteração se ela quebrar a garantia de vaga. Desativar uma rota com reservas exige realocar ou encerrar os transportes pelos comandos de domínio, sem apagar reservas silenciosamente.

## Alterações e vigência

Mudança solicitada de dias/sentidos preserva a programação anterior enquanto aguarda. Disputa novas vagas pela data do pedido de alteração, na mesma fila dos novos alunos. O dono aprova a troca inteira; a implementação precisa guardar reservas com vigência, em vez de sobrescrever a programação antiga.

A vigência começa no próximo dia de serviço em que todas as viagens afetadas ainda permitam confirmação. Nenhuma troca parcial. O Ciclo 3 calcula a vigência pela agenda e exceções disponíveis; o Ciclo 4 incorpora as viagens geradas e seus estados, preservando o dia atual.

Mudança de endereço ou escola mantém transporte e vagas, sem fila ou aprovação prévia, e sinaliza a logística ao dono. A aplicação à execução ocorre no Ciclo 4: próxima viagem não iniciada; nunca alterar percurso ativo ou histórico concluído. O novo endereço não é condicionado à cobertura comercial anterior.

Uma mudança de escola não muda implicitamente dias, sentido ou turno contratado. O dono resolve a logística da nova escola na mesma operação contratada; eventual troca de programação usa o fluxo próprio. Ajustar o percurso pode exigir revalidar duração e recursos, sem cancelar automaticamente a matrícula.

## Contratos a entregar

As assinaturas completas e tipos de payload pertencem ao implementation plan. A superfície funcional é:

- cadastro/edição/inativação de van e consulta operacional sanitizada;
- cadastro/edição de rota, escolas e agenda, com validação de referências;
- criação de convite `driver` e aceite específico sem aluno;
- consulta de disponibilidade e fila conjunta;
- submissão de alteração de programação;
- aprovação com alocações completas, espera, recusa e cancelamento;
- atualização da escola vigente pelo adulto ou responsável principal;
- consultas de programação para dono, motorista atribuído e próprio aluno/responsáveis.

Evoluções obrigatórias:

| Contrato atual | Evolução |
| --- | --- |
| `decide_fleet_join_request(uuid, text)` | impedir aprovação sem alocações; plano deve substituir a assinatura ou fazê-la rejeitar esse caminho com erro estável |
| `accept_fleet_invitation(...)` | passa a retornar ID do pedido pendente, não ID de vínculo; documentar quebra para Flutter |
| `set_fleet_member_roles` | proteger remoção de `driver` com atribuições |
| `set_fleet_membership_status` | proteger suspensão e `left` com atribuições |
| `end_fleet_enrollment` | autorizar também principal/adulto e encerrar reservas futuras; secundário não encerra |
| `update_student` | sinalizar revisões de percurso afetadas sem reescrever pedidos históricos |
| buscas e projeções de pedidos | incluir espera e alteração sem ampliar exposição de dados pessoais |

Não deixar overload legado aprovar sem reserva. Erros novos incluem `capacity_exceeded`, `schedule_conflict`, `queue_priority`, `resource_in_use` e `allocation_required`, além dos códigos existentes. Retornos `not_found` continuam protegendo recursos invisíveis.

## Segurança e concorrência

Escritas que alteram capacidade, agendas, reservas ou estado passam por RPC. RLS limita leituras; funções privilegiadas usam `search_path = ''`, nomes qualificados, grants mínimos e checagem interna de relação/papel. Fonte manual de `guardian` não concede acesso a qualquer aluno.

Reutilizar o lock de frota onde ele já serializa decisões. A checagem global de motorista/aluno exige também locks comuns por recurso, numa ordem única entre todos os comandos. O plano deve explicitar essa ordem e provar concorrência com duas sessões, incluindo atribuição versus suspensão. Índices/constraints sustentam unicidades; não depender de um `SELECT` seguido de `INSERT` sem proteção.

Auditar decisões e mudanças com IDs, estados, motivos e nomes de campos. Não copiar endereço, coordenadas, tokens ou e-mail para auditoria.

## Testes e critérios de aceite

- RED/GREEN por comportamento, ampliando fixtures transacionais existentes.
- Aprovação garante todos os dias/sentidos; nenhuma reserva parcial em falha.
- Duas aprovações concorrentes pela última vaga; prioridade entre pedidos novos e alterações, inclusive `pending`.
- Primeiro incompatível não bloqueia o próximo; primeiro compatível não pode ser ignorado sem recusa.
- Reserva de alteração só substitui a anterior na vigência correta.
- Conflitos de motorista e aluno entre frotas sem vazamento.
- Placa global e transferência, capacidade reduzida e recursos em uso.
- Convite aceito não cria vínculo; convite de motorista não exige aluno.
- Endereço/escola sinalizam revisão, conservam vínculo e histórico.
- Bloqueios nos dois comandos de associação e em todos os caminhos de atribuição.
- Dois tenants, chamadas anônimas, usuários sem e-mail confirmado e auditoria sanitizada.

## Homologação local e produção

Local é homologação; não criar staging remoto. Executar reset local, suíte inteira, lint/advisors e quality gate conforme `CONTRIBUTING.md`. A documentação de resultados deve separar local, publicado e verificado em produção.

Antes de publicar, inspecionar schema/migrations e dados do destino. Se existirem vínculos ativos antigos sem reservas, bloquear o rollout e apresentar a lista de inconsistências ao operador; não inventar alocações, apagar vínculos nem assumir banco remoto vazio. Essa é uma barreira de compatibilidade, não migração automática de dados reais.

Aplicar migrations versionadas sem seed fictício e verificar contratos/RLS no destino. Configurar Auth com confirmação de e-mail e callbacks reais iOS/Android; as URLs locais do `config.toml` não servem como configuração de produção. Manter recuperação por backup verificado e correção por nova migration; nunca resetar produção.

Catálogo real e cobertura precisam estar preenchidos para o fluxo de solicitação operar. Carga manual continua fora das migrations/seed; validar formato e procedência antes de abrir esse fluxo a usuários. Esta spec não declara carga nem publicação executadas.

## Referências

- `be-tech-plan.md`, seções 4–11 e decisões de 2026-09-07.
- `CONTRIBUTING.md` e `deliverables.md`.
- `docs/superpowers/specs/2026-09-06-ciclo-2-marketplace-vinculos-design.md` como contrato histórico.
- Migrations `20260906201503`, `20260906201646`, `20260906210854`, `20260906211326`, `20260906211528` e `20260906211805`.
