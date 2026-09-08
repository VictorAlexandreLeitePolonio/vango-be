# VanGo Backend

Backend do VanGo, um aplicativo mobile em Flutter para gestão de transporte escolar e universitário. O MVP usa o Supabase como backend completo, sem servidor Node.js próprio.

## Status do repositório

O backend dos Ciclos 0–5 e a parte do Ciclo 6 independente de provedor estão implementados e validados no Supabase local. O catálogo permanece vazio. Configuração FCM/dispositivos e integração do provedor de mapas/ETA ainda estão pendentes; veja o registro de publicação e validações em [deliverables.md](./deliverables.md).

O Ciclo 2 entrega schema, RLS, buscas públicas e RPCs para alunos, responsáveis, solicitações, convites e vínculos. Não há importador, integração externa, carga de escolas reais, envio de e-mail ou código Flutter.

## Objetivo do MVP

O VanGo conecta donos de frotas, motoristas, responsáveis e alunos adultos. O sistema permite descobrir frotas, solicitar vínculo, organizar vans e rotas, confirmar viagens, acompanhar a van durante uma viagem ativa e receber notificações operacionais.

Pagamentos, mensalidades, contratos, comissões e avaliações não fazem parte do MVP.

## Perfis e papéis

Uma conta pode acumular papéis. Os papéis são contextuais à frota, que representa o tenant:

- `owner`: administra somente as frotas às quais pertence como dono;
- `driver`: opera somente as vans e viagens atribuídas;
- `guardian`: gerencia alunos menores vinculados à conta;
- `student`: representa apenas aluno adulto autenticado.

Alunos menores não possuem login. Eles são dependentes gerenciados por um ou mais responsáveis. Um responsável principal edita os dados do aluno e administra outros responsáveis; responsáveis secundários acompanham e confirmam viagens.

O mesmo usuário pode ser dono na Frota A, motorista na Frota B e responsável por um aluno. O backend sempre valida o papel dentro do `fleet_id` informado.

## Arquitetura aprovada

O backend combina recursos nativos do Supabase:

- **Supabase Auth:** cadastro por e-mail e senha, confirmação de e-mail e recuperação de senha;
- **PostgreSQL:** dados relacionais, integridade, transações e histórico;
- **Row Level Security:** isolamento entre frotas e proteção dos dados pessoais;
- **Database Functions/RPC:** operações transacionais e regras críticas;
- **Realtime Broadcast:** localização da van em canais privados por viagem;
- **Edge Functions:** roteirização, geocodificação, push e integrações externas;
- **Storage:** avatares, logos e arquivos futuros;
- **Cron:** geração de viagens, fechamento de confirmações e expiração do GPS bruto.

O Flutter pode consultar e alterar dados simples protegidos por RLS. Regras como aprovar um vínculo, reservar vaga, trocar motorista ou iniciar uma viagem passam por RPC. Integrações e segredos ficam nas Edge Functions.

## Fluxos principais

### Marketplace e vínculos

Frotas publicadas aparecem por cidade e instituição coberta. A busca pública usa `search_schools` e `search_marketplace`; somente campos institucionais e comerciais sanitizados são retornados.

O responsável principal cria menores e o aluno adulto cria o próprio registro. Solicitações guardam um snapshot privado do endereço, exigem escola ativa/coberta e cidade atendida, e aguardam aprovação do owner. A aprovação cria o vínculo na mesma transação.

Owners também podem convidar responsáveis ou alunos adultos. O Flutter preserva o token no callback de cadastro/login; o backend guarda somente o hash SHA-256 e aceita o convite apenas para o mesmo e-mail confirmado. Responsáveis secundários recebem acesso derivado aos vínculos ativos do dependente.

A aprovação exige alocação integral das vagas na mesma transação; aceitar convite cria pedido pendente. Pedidos novos e alterações disputam vagas por antiguidade entre os integralmente compatíveis, com aceite/recusa pelo dono.

O catálogo `schools` não contém dados reais neste ciclo. A carga regional futura será inserida diretamente no Supabase, sem importador ou API definida.

### Frota e rotas

O dono cadastra vans, define a capacidade, configura rotas e escolhe motorista e van padrão. Ele pode substituir ambos em uma viagem específica sem mudar o planejamento futuro.

Cada `route` representa um único sentido: ida ou volta. Rotas opostas podem formar um par. Uma rota contém escolas ordenadas por uma tabela relacional; o dono define a ordem das escolas. O sistema otimiza as paradas residenciais respeitando essa ordem e os horários.

As escolas vêm de um catálogo global vazio neste ciclo. Usuários não escrevem diretamente no catálogo; a carga futura será manual no Supabase. A fonte externa, se necessária, será decidida antes de qualquer importação.

### Agenda, viagens e confirmações

Uma rota possui agenda semanal. Cada aluno pode usar dias e sentidos diferentes; por exemplo, pode não ir com a van e voltar com ela.

O sistema cria as viagens do dia seguinte a partir da agenda. `service_days` agrupa as viagens de ida e volta da mesma operação. Cada `trip` executa uma única `route` e mantém status, horários, van, motorista, passageiros e histórico próprios.

Os passageiros previstos começam com confirmação pendente. O prazo é configurável por rota e usa 30 minutos antes da saída como padrão:

- `confirmed`: participa da otimização;
- `declined`: fica fora da rota e permanece no histórico;
- `expired`: não respondeu no prazo e fica fora da rota.

A capacidade considera a programação normal, não as ausências diárias. Uma van com 30 lugares e 30 alunos programados aparece sem vaga; novos pedidos entram na lista de espera.

### Operação do motorista

O motorista acessa somente a van, as viagens e os alunos atribuídos. Ele não altera endereços, escolas, alunos ou a configuração permanente da rota.

Durante uma viagem, o motorista pode:

- iniciar, concluir ou cancelar a operação permitida;
- escolher a próxima escola ou parada autorizada;
- marcar o passageiro como aguardando, embarcado, desembarcado ou ausente;
- registrar atraso, trânsito, acidente, falha mecânica, desvio ou outra ocorrência;
- informar um desvio temporário com justificativa;
- enviar uma mensagem categorizada aos participantes da própria viagem.

Mudanças de estado registram horário e, quando aplicável, localização. QR Code e detecção automática de embarque ficam fora do MVP.

### Rastreamento e privacidade

O rastreamento começa quando o motorista inicia a `trip` e termina quando a conclui ou cancela. O dono acompanha todas as viagens ativas da própria frota.

Responsáveis e alunos adultos acompanham somente viagens nas quais o aluno está confirmado, até seu desembarque ou registro de ausência. Outro dependente elegível mantém o acesso do responsável. Eles recebem posição atual, escola, ETA e próprio ponto; qualquer representação de trajeto deve preservar a privacidade. O backend nunca envia endereços, identidades, pontos ou a geometria completa que possa revelar a casa de outro aluno.

Os pontos brutos de GPS permanecem por 30 dias. Resumos de viagem, distância, duração, horários, atrasos, ocorrências, embarques, desembarques e eventos de auditoria permanecem sem prazo de expiração definido.

### Roteirização

A rota-base será recalculada quando alunos, endereços, escolas ou atribuições mudarem. Criar a viagem diária não chama o provedor de rotas. No encerramento das confirmações, o sistema compara a revisão completa das entradas, não apenas os passageiros. Mudanças cadastrais valem na próxima viagem não iniciada, preservando o percurso da ativa. Incidentes podem disparar um novo cálculo excepcional autorizado.

O MVP considera até 30 alunos por van, mais partida e escolas. A escolha do provedor deverá verificar limites de paradas, cobertura, ETA e custo. Se uma chamada não aceitar todos os pontos, o serviço dividirá o cálculo sem alterar o modelo de domínio.

### Notificações

O sistema enviará notificações para:

- confirmação disponível e prazo próximo;
- viagem iniciada;
- van a cerca de 10 minutos do aluno;
- chegada ao ponto;
- embarque e desembarque;
- chegada à escola;
- atraso, desvio, cancelamento e ocorrência;
- mensagem manual do dono.

O aviso de proximidade usa ETA, não uma distância fixa. O limite padrão é 10 minutos, configurável por rota, com deduplicação para evitar notificações repetidas.

O dono pode enviar mensagens para toda a frota, rota, viagem, van ou usuário. O motorista usa categorias predefinidas e uma observação opcional apenas na própria viagem.

## Multi-tenancy e segurança

A frota é o tenant. Toda entidade operacional inclui `fleet_id`, e toda tabela exposta possui RLS. Conhecer um UUID nunca concede acesso.

Regras centrais:

- o aplicativo usa somente a chave pública do Supabase;
- chaves secretas permanecem em serviços internos;
- papéis enviados pelo cliente nunca são considerados confiáveis;
- operações críticas validam associação, papel e estado no banco;
- nenhum usuário remove ou rebaixa o último dono ativo;
- canais Realtime são privados e autorizados por viagem;
- auditorias são imutáveis para usuários comuns;
- projeções públicas omitem dados operacionais e pessoais.

## Etapas planejadas

1. **Fundação multi-tenant:** Supabase local, Auth, perfis, frotas, associações, múltiplos papéis, RLS e auditoria — concluída localmente no Ciclo 1.
2. **Marketplace e vínculos:** catálogo vazio, cobertura comercial, alunos, responsáveis, solicitações, convites, vínculos, privacidade e auditoria — concluído localmente no Ciclo 2. Preferências, capacidade e lista de espera ficaram fora do corte.
3. **Frota e planejamento:** vans, capacidade, motoristas, rotas, escolas ordenadas, agendas, reservas, fila e alterações de programação.
4. **Operação diária:** calendário, dias de serviço, viagens, confirmações, substituições, presença e ocorrências.
5. **Notificações:** caixa de avisos com leitura, push, eventos operacionais, mensagens unidirecionais, deduplicação e validade de alertas.
6. **Mapa, rastreamento e roteirização:** GPS, Realtime privado, sincronização offline, visibilidade segura, retenção, otimização, ETA e geocodificação; integração dos alertas de proximidade com o Ciclo 5.

Cada etapa possui especificação, plano, migrations e testes. Os Ciclos 3–6 foram desenvolvidos com regressões RED/GREEN e validação integrada.

Os planos dos ciclos restantes incluem preparação e publicação em produção, usando o ambiente local como homologação, sem staging remoto. A integração prevista é Flutter iOS e Android, com push via Firebase Cloud Messaging. A escolha e o orçamento do provedor de mapas e rotas estão em espera; a publicação do escopo completo do Ciclo 6 depende dessa definição. Os ciclos anteriores continuam registrados como entregas locais, sem presumir implantação remota.

## Documentação

As specs foram aprovadas em 2026-09-07. Os planos registram contratos e tarefas; [deliverables.md](./deliverables.md) distingue a implementação validada das integrações externas pendentes.

| Ciclo | Spec | Implementation plan |
| --- | --- | --- |
| 3 | [Frota e planejamento](./docs/superpowers/specs/2026-09-07-ciclo-3-frota-planejamento-design.md) | [Plano do Ciclo 3](./docs/superpowers/plans/2026-09-07-ciclo-3-frota-planejamento.md) |
| 4 | [Operação diária](./docs/superpowers/specs/2026-09-07-ciclo-4-operacao-diaria-design.md) | [Plano do Ciclo 4](./docs/superpowers/plans/2026-09-07-ciclo-4-operacao-diaria.md) |
| 5 | [Notificações](./docs/superpowers/specs/2026-09-07-ciclo-5-notificacoes-design.md) | [Plano do Ciclo 5](./docs/superpowers/plans/2026-09-07-ciclo-5-notificacoes.md) |
| 6 | [Mapa, rastreamento e roteirização](./docs/superpowers/specs/2026-09-07-ciclo-6-mapa-rastreamento-roteirizacao-design.md) | [Plano do Ciclo 6](./docs/superpowers/plans/2026-09-07-ciclo-6-mapa-rastreamento-roteirizacao.md) |

- [Plano técnico e modelo de domínio](./be-tech-plan.md)
- [Diretrizes de desenvolvimento](./CONTRIBUTING.md)
- [Entregas por ciclo](./deliverables.md)
- [Plano de implementação do Ciclo 1](./docs/superpowers/plans/2026-09-05-ciclo-1-fundacao-multitenant.md)
- [Spec do Ciclo 2](./docs/superpowers/specs/2026-09-06-ciclo-2-marketplace-vinculos-design.md)
- [Plano de implementação do Ciclo 2](./docs/superpowers/plans/2026-09-06-ciclo-2-marketplace-vinculos.md)

## Validação do backend

Execute `python3 supabase/tests/run_database_tests.py` no Supabase local. O executor expande includes `\ir` em arquivos temporários, executa a suíte pgTAP e remove esses arquivos ao final. Não usa banco remoto.
