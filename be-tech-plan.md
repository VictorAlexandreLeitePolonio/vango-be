# VanGo — plano técnico do backend

## 1. Estado e finalidade

Este documento registra a arquitetura aprovada para o MVP do VanGo. Os Ciclos 0–5 e o escopo do Ciclo 6 independente de provedor estão implementados e validados localmente no Supabase. O registro de publicação e as pendências externas estão em [deliverables.md](./deliverables.md).

O aplicativo será mobile, desenvolvido em Flutter para iOS e Android, conforme decisão aprovada em 2026-09-07. Este repositório concentrará todo o backend no Supabase. Não haverá API Node.js, JWT próprio, `bcrypt` ou servidor Socket.io no MVP.

## 2. Escopo do produto

O VanGo coordena transporte escolar e universitário entre quatro papéis:

- dono da frota (`owner`);
- motorista (`driver`);
- responsável (`guardian`);
- aluno adulto (`student`).

Uma conta pode acumular papéis. O papel sempre pertence ao vínculo do usuário com uma frota. A frota representa o tenant e isola dados, permissões e operações.

Alunos menores não possuem conta. Um ou mais responsáveis gerenciam cada menor. Alunos maiores de idade possuem conta própria e usam o papel `student`.

O MVP inclui:

- marketplace público de frotas;
- solicitações e convites de vínculo;
- gestão de vans, motoristas, alunos e responsáveis;
- rotas recorrentes de ida e volta;
- viagens diárias e confirmações por sentido;
- localização da van durante viagens ativas;
- roteirização, ETA e notificações;
- registro de atrasos, desvios, ocorrências e eventos operacionais;
- auditoria e isolamento multi-tenant.

O MVP exclui:

- pagamentos, mensalidades, contratos e comissões;
- aprovação prévia de uma frota pela plataforma;
- diretório público de responsáveis ou alunos;
- avaliação pública de frotas;
- QR Code ou detecção automática de embarque;
- desenho de polígonos de atendimento;
- login por telefone ou SMS.

## 3. Arquitetura

### 3.1 Abordagem híbrida no Supabase

O backend usa cada recurso do Supabase onde ele reduz complexidade sem dispersar regras de negócio:

- **Supabase Auth:** cadastro por e-mail e senha, confirmação de e-mail, sessão e recuperação de senha;
- **PostgreSQL:** modelo relacional, constraints, transações, histórico e auditoria;
- **RLS:** autorização por linha e isolamento entre frotas;
- **Database Functions/RPC:** comandos transacionais e regras críticas;
- **Realtime Broadcast:** posição atual da van em canal privado por viagem;
- **Edge Functions:** integrações externas, geocodificação, roteirização e push;
- **Storage:** avatares, logos e arquivos futuros;
- **Cron:** geração de viagens, fechamento de confirmações e expiração dos pontos brutos de GPS.

O Flutter acessa diretamente consultas e alterações simples protegidas por RLS. Comandos que mudam várias entidades ou exigem validação concorrente passam por RPC. Edge Functions não repetem CRUD comum; elas protegem segredos e coordenam serviços externos.

### 3.2 Alternativas rejeitadas

- **Node.js mais Supabase:** exige outro servidor e duplica autenticação, autorização e tempo real sem benefício suficiente para o MVP.
- **Tudo por Edge Functions:** aumenta código intermediário e latência e reduz a velocidade inicial.
- **Flutter direto em todas as tabelas:** espalha regras transacionais pelo cliente e aumenta o risco de inconsistência.
- **Socket.io próprio:** o Realtime privado do Supabase cobre o fluxo inicial de localização.

### 3.3 Estrutura futura do repositório

```text
supabase/
├── config.toml
├── migrations/
├── seed.sql
├── tests/
│   └── database/
└── functions/
    └── _shared/
```

O repositório já contém a estrutura local de banco e testes dos Ciclos 0–2; Edge Functions serão acrescentadas nos ciclos correspondentes. Migrações são a única forma válida de alterar o schema do banco compartilhado.

## 4. Identidade, tenant e papéis

### 4.1 Identidade

`auth.users` mantém e-mail, senha, confirmação e sessão. `profiles` contém somente dados de domínio:

| Campo | Regra |
| --- | --- |
| `id` | UUID e FK para `auth.users.id` |
| `full_name` | nome do usuário |
| `phone` | telefone opcional |
| `avatar_path` | caminho opcional no Storage |
| `created_at` | criação |
| `updated_at` | última atualização |

Um trigger mínimo cria o perfil após o cadastro. O usuário pode completar o perfil antes de confirmar o e-mail. Criar uma frota, convidar alguém ou solicitar vínculo exige e-mail confirmado.

`profiles` não duplica e-mail, senha ou papéis. Metadados editáveis do JWT nunca concedem autorização.

### 4.2 Frota como tenant

`fleets` representa o tenant:

| Campo | Regra |
| --- | --- |
| `id` | UUID |
| `name` | nome comercial |
| `slug` | identificador público único |
| `description` | descrição pública opcional |
| `logo_path` | logo opcional |
| `status` | `draft`, `published`, `suspended` ou `archived` |
| `created_by` | usuário criador |
| `created_at` | criação |
| `updated_at` | última atualização |

O dono pode publicar a frota imediatamente. `suspended` fica reservado para moderação futura; o MVP não exige aprovação de um administrador da plataforma.

Toda entidade operacional inclui `fleet_id`. O aplicativo informa o tenant em cada operação. O backend não mantém um “tenant atual” global.

### 4.3 Associação e múltiplos papéis

`fleet_memberships` registra uma associação única entre usuário e frota:

| Campo | Regra |
| --- | --- |
| `id` | UUID |
| `fleet_id` | tenant |
| `user_id` | usuário autenticado |
| `status` | `active`, `suspended` ou `left` |
| `joined_at` | início |
| `suspended_at` | suspensão opcional |
| `left_at` | saída opcional |

`fleet_membership_roles` permite vários papéis na mesma associação:

| Campo | Regra |
| --- | --- |
| `membership_id` | associação |
| `role` | `owner`, `driver`, `guardian` ou `student` |

A chave composta impede papéis duplicados. Um usuário pode acumular papéis na mesma frota e pertencer a várias frotas. A seleção de papel no Flutter muda a experiência visual, não as permissões no banco.

Criar uma frota cria atomicamente uma associação ativa e o primeiro papel `owner`. Nenhuma operação remove, suspende ou rebaixa o último dono ativo.

### 4.4 Auditoria

`audit_events` registra mudanças sensíveis:

| Campo | Regra |
| --- | --- |
| `id` | identificador ordenável ou UUID |
| `fleet_id` | tenant |
| `actor_user_id` | autor; nulo para automação |
| `action` | ação estável |
| `entity_type` | tipo da entidade |
| `entity_id` | entidade afetada |
| `metadata` | contexto sanitizado |
| `created_at` | horário do evento |

Usuários comuns não alteram nem apagam auditorias. `metadata` registra contexto e campos alterados sem copiar endereços, tokens ou outros dados pessoais desnecessários.

## 5. Capacidades por papel

### 5.1 Dono

O dono acessa somente as frotas nas quais possui papel `owner`. Ele pode:

- editar e publicar a frota;
- cadastrar, remover logicamente e consultar vans;
- associar motoristas;
- configurar rotas, escolas, horários, capacidade e prazos;
- aceitar ou negar solicitações;
- atribuir aluno a uma van e rota, mesmo fora das preferências informadas;
- gerenciar lista de espera;
- acompanhar todas as viagens ativas do tenant;
- substituir motorista ou van em uma viagem;
- consultar histórico e ocorrências;
- enviar notificações para frota, rota, viagem, van ou usuário.

### 5.2 Motorista

O motorista acessa somente vans, rotas e viagens atribuídas. Ele pode:

- consultar alunos previstos, confirmados e não confirmados;
- consultar rota, próxima parada e ETA;
- iniciar, concluir ou cancelar uma viagem permitida;
- escolher a próxima parada entre as autorizadas;
- marcar embarque, desembarque ou ausência;
- transmitir localização durante a viagem ativa;
- registrar trânsito, atraso, acidente, falha mecânica, desvio e outras ocorrências;
- registrar justificativa para um desvio temporário;
- enviar uma mensagem categorizada, com observação opcional, aos participantes da própria viagem.

O motorista não altera endereços, escolas, alunos, capacidade ou configuração permanente da rota.

### 5.3 Responsável

Um responsável pode gerenciar vários alunos menores. Vários responsáveis podem estar ligados ao mesmo aluno:

- todos acompanham e confirmam viagens autorizadas;
- o responsável principal edita o aluno, o endereço e a programação;
- somente o principal convida ou remove outros responsáveis;
- alterações sensíveis ficam auditadas.

O responsável pesquisa frotas, solicita vínculo, informa preferências, recebe convites, confirma ida e volta separadamente e acompanha somente as viagens do próprio dependente.

### 5.4 Aluno adulto

O aluno adulto possui `profile`, associação com papel `student` e um registro de aluno ligado à própria conta. Ele pesquisa frotas, solicita vínculo, informa preferências, administra a própria programação, confirma cada sentido e acompanha somente as próprias viagens.

## 6. Modelo de domínio planejado

Esta seção combina o contrato entregue no Ciclo 2 com entidades planejadas para ciclos posteriores. Cada ciclo detalha constraints e índices antes da implementação.

### 6.1 Localização e catálogo público

`fleet_service_cities` liga uma frota às cidades usadas na descoberta do marketplace. Cidade é um filtro comercial, não uma fronteira operacional. Uma rota pode atravessar várias cidades.

`schools` forma um catálogo global, vazio no Ciclo 2 e preparado para carga manual futura:

- `id` interno;
- `provider` e `external_id` para idempotência;
- nome e tipo da instituição;
- endereço estruturado;
- cidade, latitude e longitude;
- metadados de origem e data da última sincronização.

Usuários autenticados não escrevem diretamente no catálogo. A carga inicial pretendida para Itapetininga, Sorocaba, São Miguel Arcanjo, Tatuí, Capão Bonito e Pilar do Sul será feita diretamente no Supabase em trabalho futuro. Nenhum importador ou provedor externo foi fixado.

O marketplace expõe uma projeção sanitizada das frotas publicadas e filtra por cidade e instituição no Ciclo 2. Turno, disponibilidade, distância e operação ficam para ciclos posteriores. Nenhuma consulta pública expõe usuários, alunos, endereços residenciais, rotas exatas ou localização ao vivo.

### 6.2 Alunos e responsáveis

`students` representa tanto menores quanto alunos adultos:

- identidade e data de nascimento;
- endereço residencial atual e coordenadas;
- `profile_id` opcional e único para aluno adulto;
- datas de criação e atualização.

Menor possui `profile_id` nulo. O responsável principal controla os dados. O endereço completo só chega a uma frota após o usuário enviar uma solicitação.

`student_guardians` relaciona menores e responsáveis:

- `student_id`;
- `guardian_user_id`;
- `is_primary`;
- permissões de acompanhamento e confirmação;
- estado e datas do vínculo.

Cada menor tem exatamente um responsável principal ativo e pode ter vários secundários.

### 6.3 Solicitações, convites e vínculos

`fleet_join_requests` registra a solicitação feita por um responsável ou aluno adulto:

- frota, solicitante e aluno;
- escola, turno, sentidos e dias desejados;
- endereço privado usado na análise;
- status `pending`, `approved`, `rejected`, `waitlisted` ou `cancelled`;
- decisão, autor e datas.

`join_request_van_preferences` guarda até três vans em ordem de preferência. As preferências são informativas. O dono pode escolher outra van compatível, e a atribuição final prevalece.

`fleet_invitations` permite ao dono convidar um contato conhecido. Não existe busca pública de usuários.

`fleet_enrollments` representa o vínculo aprovado entre frota e aluno. Um aluno pode manter vínculos ativos com várias frotas. O banco impede programações conflitantes no mesmo dia, turno e sentido.

Sem vaga programada, a solicitação entra na lista de espera. A vaga considera a capacidade contratada da rota, não faltas ocasionais.

**Decisão aprovada em 2026-09-07 para o Ciclo 3:** a aprovação deve reservar todas as vagas solicitadas, cobrindo os dias e sentidos do pedido. Validar capacidade e conflitos, registrar as atribuições, criar o vínculo e aprovar a solicitação devem ocorrer na mesma transação. Se não for possível atender ao pedido inteiro, a operação não pode aprovar parcialmente nem deixar reservas parciais.

**Trade-off:** a aprovação passa a significar transporte garantido na programação, evitando vínculos aprovados sem vaga. Em contrapartida, o dono precisa ter rotas e capacidade definidas antes de aprovar, e a transação exige controle de concorrência para impedir que duas aprovações consumam a mesma vaga. Rejeita-se a alternativa de aprovar o vínculo primeiro e alocar depois, embora ela preservasse o contrato atual com menos alterações.

**Convites — decisão aprovada em 2026-09-07:** aceitar um convite da frota passa a criar uma solicitação `pending`, sem criar vínculo nem reservar capacidade. O dono aprova posteriormente com a alocação completa, usando a mesma regra de reserva das solicitações do marketplace. O convite aceito registra a resposta do destinatário; ele não significa transporte aprovado.

**Trade-off dos convites:** a revisão pelo dono adiciona uma etapa ao fluxo atual, mas evita bloquear vagas enquanto aguarda a resposta ao convite e impede aprovação sem capacidade. A aceitação do convite não garante prioridade nem disponibilidade.

**Lista de espera — decisão aprovada em 2026-09-07:** o atendimento deve respeitar a ordem de chegada, com decisão manual de aceite ou recusa pelo dono. Surgir uma vaga não aprova automaticamente uma solicitação; o aceite continua exigindo a reserva integral na mesma transação.

**Antiguidade — decisão aprovada em 2026-09-07:** a prioridade conta desde a criação da solicitação, e não desde sua entrada na lista de espera. No marketplace, corresponde ao envio do pedido; em convites, à aceitação que cria a solicitação pendente. O horário de criação deve ser atribuído pelo backend. A demora na análise pelo dono não altera a antiguidade, e emitir um convite não antecipa a posição do destinatário na fila.

**Compatibilidade da fila — decisão aprovada em 2026-09-07:** entre os pedidos que podem ser atendidos integralmente nas vagas disponíveis, prevalece o mais antigo. Um pedido sem atendimento completo permanece aguardando e conserva sua posição, sem bloquear o próximo compatível. Por exemplo, se o primeiro pede ida e volta e só há vaga de ida, o dono pode avaliar o próximo que pediu apenas ida. Não são permitidas reservas parciais para o pedido que permanece na fila.

**Trade-off da fila:** a ordem de chegada entre pedidos integralmente compatíveis impede priorização arbitrária e evita vagas ociosas por bloqueio de um pedido incompatível. A decisão manual permite ao dono aceitar ou recusar o pedido; a compatibilidade precisa ser validada pelo backend, considerando escola, turno, dias, sentidos, capacidade e conflitos de programação, sem depender apenas da ordenação apresentada pelo aplicativo.

Essas regras foram implementadas no Ciclo 3: aprovação reserva integralmente e aceitar convite cria pedido pendente. A publicação é bloqueada se houver vínculos ativos legados sem programação; não se inventam reservas nem se apagam vínculos para permitir o rollout.

### 6.4 Vans e atribuições

`vans` pertence a uma frota e contém:

- placa única entre cadastros ativos de todas as frotas;
- modelo, identificação pública e capacidade;
- status operacional;
- dados públicos resumidos para o marketplace;
- datas de criação e atualização.

O MVP deve suportar cerca de 30 alunos por van. A capacidade permanece configurável.

**Unicidade da van — decisão aprovada em 2026-09-07:** uma placa identifica no máximo um cadastro ativo de van em todo o sistema, independentemente da frota. A transferência para outra frota exige inativar o cadastro anterior antes de ativar o novo, preservando o cadastro anterior e seu histórico. Erros de placa já utilizada não revelam a identidade nem os dados da outra frota.

**Inativação da van — decisão aprovada em 2026-09-07:** o backend bloqueia a inativação enquanto houver viagem ativa atualmente atribuída à van ou atribuição futura ao veículo. O dono precisa concluir a viagem ativa ou realizar uma substituição emergencial válida, além de substituir o veículo nas rotas e viagens futuras, antes de inativá-lo. As substituições respeitam capacidade e conflitos de agenda; a inativação não apaga histórico nem desfaz reservas de alunos.

**Trade-off da unicidade e inativação:** a regra impede reservar o mesmo veículo por cadastros ativos em frotas diferentes e evita deixar alunos com vaga garantida sem veículo. Em contrapartida, a transferência exige resolver as pendências operacionais e inativar o cadastro anterior antes de ativar o novo.

**Entrada de motoristas — decisão aprovada em 2026-09-07:** o dono convida o motorista por e-mail. O destinatário aceita usando uma conta com o mesmo e-mail confirmado; a aceitação cria ou associa o vínculo com a frota e concede o papel `driver`, preservando outros papéis e sem contornar uma suspensão existente. Esse fluxo não exige cadastro de aluno, não cria solicitação de transporte e não disputa vagas. Após a aceitação, o dono pode atribuir o motorista às rotas, respeitando associação ativa e conflitos de agenda.

O dono que também dirige precisa possuir explicitamente o papel `driver`. O papel `owner` sozinho não torna o usuário elegível para atribuição como motorista.

**Suspensão de motorista — decisão aprovada em 2026-09-07:** o backend rejeita a suspensão enquanto o motorista tiver viagem ativa ou atribuições futuras, incluindo rotas recorrentes e viagens já geradas. O dono deve concluir a viagem ativa ou realizar uma substituição válida e resolver as atribuições futuras antes de suspender. Uma tentativa bloqueada não altera a associação nem interrompe o acesso operacional ou o envio de GPS.

**Remoção de papel e saída — decisão aprovada em 2026-09-07:** a mesma trava vale para remover o papel `driver` ou encerrar a associação do motorista com a frota (`left`). Nenhum desses comandos pode deixar atribuições ativas ou futuras sem motorista elegível. Enquanto a trava se aplicar, a tentativa é rejeitada integralmente e preserva os papéis, a associação e o acesso operacional.

**Trade-off da suspensão:** preserva a continuidade da operação e impede deixar viagens sem motorista por uma mudança administrativa. Em contrapartida, exige resolver as atribuições antes de suspender. O Ciclo 3 deve evoluir `set_fleet_membership_status` e `set_fleet_member_roles`, e o Ciclo 4 deve acrescentar a verificação de viagens ativas e futuras na mesma transação, sem permitir corrida com novas atribuições.

**Trade-off da entrada de motoristas:** o convite exige aceite e confirmação do e-mail antes da atribuição, mas evita associações silenciosas e separa a entrada da equipe dos pedidos de transporte. Reutilizar os mecanismos existentes de convite e múltiplos papéis não significa reutilizar o fluxo que exige aluno e reserva de vaga; o plano do Ciclo 3 deve definir esse contrato específico.

**Capacidade — decisão aprovada em 2026-09-07:** todos os alunos programados para uma execução da rota em determinado dia contam contra a capacidade de passageiros da van. Não há reutilização de vaga por trecho após desembarque. Uma van com capacidade de 15 alunos comporta no máximo 15 alunos programados naquela execução, ainda que alguns desembarquem antes de outros embarcarem. Confirmações negativas e faltas ocasionais não liberam a vaga contratada para outra aprovação.

**Trade-off da capacidade:** contar os alunos programados por execução simplifica a reserva e mantém a garantia de vaga independentemente da ordem das paradas. Em contrapartida, o MVP não aproveita lugares que ficariam livres em trechos intermediários; esse aproveitamento exigiria controle de lotação por trecho e restrições adicionais às mudanças de percurso.

Uma rota possui van e motorista padrão. Cada viagem copia essa configuração para preservar o histórico. O dono pode substituir van ou motorista antes da saída ou, em emergência, durante a viagem ativa. A substituição exige motivo e gera auditoria sem alterar a rota recorrente.

**Substituição emergencial — decisão aprovada em 2026-09-07:** o dono pode substituir van ou motorista durante uma viagem ativa, inclusive com passageiros embarcados. A operação exige motivo obrigatório, validação de capacidade e conflitos de agenda e registro da configuração anterior e nova, autor e horário. A viagem mantém sua identidade, passageiros, estados de embarque e histórico; a troca não exige concluir nem recriar a viagem.

**Trade-off da substituição emergencial:** permite tratar quebra de veículo ou indisponibilidade do motorista sem registrar uma conclusão fictícia. Em contrapartida, o backend precisa preservar a sequência de atribuições e atualizar a autorização operacional para o motorista substituto. A reserva da viagem não pode se sobrepor a outros compromissos do novo veículo ou motorista.

### 6.5 Rotas recorrentes

`routes` representa um único sentido:

- `fleet_id`;
- nome e status;
- direção `going` ou `return`;
- `paired_route_id` opcional;
- partida e término planejados;
- van e motorista padrão;
- parâmetros de confirmação e proximidade;
- versão da rota-base otimizada.

A rota de ida segue partida da van, residências confirmadas e escolas. A rota de volta segue escolas, residências confirmadas e ponto final da van. Rotas opostas podem formar um par, mas mantêm agenda, alunos e ordem independentes.

`route_schools` substitui arrays de IDs e mantém integridade relacional:

- rota e escola;
- ordem definida pelo dono;
- janela de chegada ou saída;
- estado do vínculo.

O MVP preserva a ordem das escolas. O otimizador ordena as residências sem mudar essa sequência.

`route_schedules` define dias da semana, horário previsto de saída, fuso horário, janela operacional e prazo de confirmação. O prazo padrão é 30 minutos antes da saída, mas o dono pode alterá-lo por rota.

**Conflitos de van e motorista — decisão aprovada em 2026-09-07:** cada rota deve informar início e fim previstos. O backend bloqueia atribuições de van ou motorista com janelas operacionais sobrepostas nos dias aplicáveis. A verificação do motorista abrange todas as frotas em que trabalha; um conflito retorna erro de domínio sem revelar a identidade da outra frota, suas rotas ou horários. Alterações de agenda e substituições também devem respeitar essa regra.

**Margem entre rotas — decisão aprovada em 2026-09-07:** o dono inclui o deslocamento necessário e a margem operacional no horário final da janela reservada. Não há intervalo fixo global adicional. Van e motorista ficam indisponíveis durante toda essa janela; uma rota consecutiva pode começar a partir do seu término. O plano deve distinguir o fim da janela de reserva do horário real de conclusão da viagem.

**Trade-off dos conflitos:** cadastrar o fim da janela exige estimar a operação, o deslocamento e sua margem, mas permite impedir compromissos simultâneos antes da roteirização externa. O backend valida a ausência de sobreposição; estimar uma margem suficiente fica sob responsabilidade do dono. A ausência de intervalo global acomoda necessidades diferentes, mas não corrige uma estimativa insuficiente.

`route_student_schedules` define os dias em que cada aluno usa aquela rota. Ida e volta são independentes. Um aluno pode faltar na ida e usar normalmente a volta.

**Alteração de programação — decisão aprovada em 2026-09-07:** quando um aluno aprovado solicita mudança de dias ou sentidos, a programação vigente e suas vagas permanecem garantidas enquanto o pedido aguarda decisão. O dono aprova a troca completa em uma única transação, validando capacidade e conflitos e substituindo as reservas anteriores pelas novas. Se a mudança não puder ser atendida integralmente, nenhuma reserva vigente é removida ou alterada.

**Prioridade da alteração — decisão aprovada em 2026-09-07:** pedidos de alteração disputam novas vagas na mesma fila das solicitações de novos alunos, pela data de criação do pedido de alteração. A antiguidade do vínculo não concede prioridade. A programação vigente permanece protegida enquanto o pedido aguarda atendimento integral.

**Vigência da alteração — decisão aprovada em 2026-09-07:** uma alteração aprovada passa a valer no próximo dia de serviço, desde que todas as viagens afetadas ainda permitam confirmação. Se algum prazo já encerrou, a troca inteira é adiada para o primeiro dia de serviço que satisfaça essa condição. A programação anterior permanece válida até a nova vigência, sem troca parcial. Viagens futuras já geradas e ainda não iniciadas devem ser atualizadas a partir dessa vigência. Alterações na programação recorrente não modificam viagens do dia atual, viagens ativas nem snapshots de viagens concluídas.

**Trade-off da vigência:** preservar o dia atual evita mudanças na lista do motorista e invalidação de confirmações durante a operação, mas impede trocas imediatas pela programação recorrente. Os Ciclos 3 e 4 devem compartilhar a mesma data de vigência para as reservas e os passageiros das viagens futuras, sem liberar antecipadamente vagas ainda usadas pela programação anterior.

**Reconfirmação — decisão aprovada em 2026-09-07:** quando a alteração de programação modificar uma viagem futura de um aluno já confirmado, a confirmação anterior não vale para a nova programação. O backend deve exigir nova confirmação para a viagem afetada e avisar o responsável ou aluno adulto. Confirmações de viagens não afetadas permanecem válidas.

**Trade-off da reconfirmação:** exige uma nova ação do usuário, mas impede transportar o aluno com base em uma confirmação de outra programação. A atualização da participação e a invalidação da confirmação devem ocorrer juntas; o envio do aviso deve ser integrado ao ciclo de notificações. Adiar a troca inteira quando algum prazo já encerrou preserva a oportunidade de confirmar e evita mudanças parciais, ao custo de postergar o atendimento da alteração.

**Trade-off da alteração:** o aluno não perde o transporte já garantido ao solicitar uma mudança, mas ser cliente não permite ultrapassar pedidos anteriores pelas novas vagas. O backend precisa distinguir a programação vigente do pedido de alteração e validar a substituição atomicamente, sem contar duas vezes as vagas do próprio aluno que serão mantidas.

### 6.6 Dias de serviço e viagens

**Calendário — decisão aprovada em 2026-09-07:** o dono marca se haverá ou não transporte por rota e data, com opção de aplicar a marcação a todas as rotas da frota. A agenda semanal define o padrão; a marcação registra exceções, sem calcular feriados nem presumir calendários escolares. Desativar o transporte cancela viagens ainda não iniciadas e avisa os participantes, sem disparar cálculo de percurso. A marcação não encerra vínculos nem libera vagas recorrentes. Viagens ativas não são canceladas pela marcação; continuam sujeitas à regra de encerramento operacional.

`service_days` agrupa, por data, as viagens de ida e volta relacionadas. Ele permite consultar a operação diária sem misturar os estados de cada sentido.

`trips` representa uma única execução direcional:

- `service_day_id`, `fleet_id` e `route_id`;
- van e motorista copiados ou substituídos;
- horários planejados e reais;
- estado `scheduled`, `confirmation_closed`, `active`, `completed` ou `cancelled`;
- rota otimizada usada naquela execução;
- resumo operacional.

Uma `trip` referencia somente uma rota. Ela não contém `route_going_id` e `route_return_id`, pois ida e volta têm estados, horários, passageiros, ocorrências e localizações independentes.

Um job diário cria as viagens do dia seguinte. Criar os registros não chama o provedor de rotas.

`trip_passengers` copia os alunos previstos. Confirmação e embarque usam estados separados:

- confirmação: `pending`, `confirmed`, `declined` ou `expired`;
- operação: `waiting`, `boarded`, `dropped_off` ou `absent`.

Ao vencer o prazo, `pending` passa para `expired` e fica fora da otimização. O sistema não apaga nem troca a atribuição; ele conserva a decisão no histórico. Não são permitidas inclusões de novos passageiros após o início da viagem.

**Confirmações — decisão aprovada em 2026-09-07:** até o prazo, o aluno adulto ou qualquer responsável ativo pode confirmar ou recusar; vale a última resposta, com autor registrado. A ausência de resposta exclui o aluno daquela execução, sem liberar sua vaga recorrente. Após o prazo e antes da saída, somente o dono pode autorizar mudança de participação, com motivo e atualização do percurso. Depois da saída, não entram novos passageiros.

**Conclusão e cancelamento — decisão aprovada em 2026-09-07:** nenhuma viagem pode ser concluída ou cancelada enquanto houver passageiro marcado como embarcado. O motorista registra o desembarque antes de encerrar e, em caso de interrupção, também a ocorrência. Uma substituição emergencial mantém a viagem ativa e preserva o histórico.

**Encerramento do transporte — decisão aprovada em 2026-09-07:** o dono, o responsável principal ou o aluno adulto pode encerrar o vínculo, com motivo obrigatório. Responsáveis secundários não podem encerrá-lo. O encerramento libera reservas futuras e retira participações em viagens ainda não iniciadas, preservando o histórico. Se o aluno participa de uma viagem ativa, o comando é bloqueado até essa viagem terminar. O Ciclo 3 deve evoluir o contrato atual, restrito ao dono, e o Ciclo 4 deve integrar as verificações e os efeitos nas viagens.

`trip_stops` guarda o snapshot das paradas usadas na viagem:

- origem, residência, escola ou destino final;
- ordem planejada e real;
- coordenadas e endereço necessários à operação;
- ETA e horário real;
- aluno ou escola relacionados, quando aplicável.

Snapshots impedem que a edição posterior de um endereço altere uma viagem concluída.

**Mudança de endereço ou escola — decisão aprovada em 2026-09-07:** o aluno permanece no mesmo transporte, mantendo vínculo e vagas. A mudança atualiza o percurso e avisa o dono, responsável por resolver a logística, sem depender de aprovação prévia nem colocar o aluno novamente na fila. A regra de alteração de dias e sentidos permanece separada: ela ainda exige aprovação e reserva integral.

**Vigência da mudança cadastral — decisão aprovada em 2026-09-07:** a mudança entra em vigor na próxima viagem ainda não iniciada. Durante uma viagem ativa, o endereço operacional do aluno e o percurso permanecem inalterados; a edição cadastral não substitui paradas nem gera ajuste de percurso nessa execução. O backend aplica o novo endereço às viagens seguintes ainda não iniciadas, inclusive às já geradas, sem aguardar aprovação do dono. Viagens ativas e concluídas preservam seus snapshots. Essa regra de vigência não é a regra de troca de dias ou sentidos.

**Trade-off cadastral:** preserva o transporte contratado e evita mudança de destino durante uma execução em andamento. O endereço anterior permanece válido apenas para a execução já iniciada; o novo vale nas seguintes ainda não iniciadas. Em contrapartida, o novo percurso pode exigir reorganização pelo dono, inclusive quando sair da cobertura ou aumentar a duração. Falhas de geocodificação ou recálculo seguem a operação manual definida na seção 6.9.

### 6.7 Ocorrências e mudanças operacionais

`trip_incidents` registra:

- categoria: trânsito, atraso, acidente, falha mecânica, desvio ou outra;
- descrição opcional;
- autor, data e localização;
- impacto estimado e estado de resolução.

Substituições de motorista ou van e desvios temporários registram configuração anterior, nova configuração, autor, horário e motivo. Resumos dessas mudanças permanecem junto ao histórico da viagem.

**Ocorrências — decisão aprovada em 2026-09-07:** o dono e o motorista atribuído podem registrar ocorrências. O motorista não aguarda aprovação para informar atraso ou problema. Registros preservam autor e horário; correções acrescentam informação sem apagar ou sobrescrever o relato original.

### 6.8 Localização em tempo real

`trip_location_points` armazena amostras do GPS:

- `fleet_id` e `trip_id`;
- latitude, longitude, velocidade, direção e precisão;
- horário capturado no dispositivo e recebido pelo backend.

O fluxo ao vivo usa canal privado por viagem. A spec do Ciclo 6 propõe `trip:{trip_id}:v{epoch}` para cessar publicações em tópicos antigos após revogação. Somente o motorista atribuído origina posições, validadas e publicadas pelo backend. O dono da frota recebe todas as viagens ativas; o motorista acessa somente a viagem atribuída. Responsáveis e alunos adultos recebem apenas viagens em que o aluno esteja confirmado, desde o início até seu desembarque ou registro de ausência. Depois disso, conservam acesso ao histórico autorizado, sem localização ao vivo. Um responsável com outro dependente ainda elegível na mesma viagem conserva o acesso por esse dependente.

**Acesso ao mapa — decisão aprovada em 2026-09-07:** desembarque ou ausência encerram a autorização de acompanhamento ao vivo daquele aluno. O Ciclo de rastreamento deve aplicar essa revogação no backend também a conexões já abertas; ocultar o mapa no Flutter não cumpre o contrato.

O rastreamento começa quando a viagem entra em `active` e termina em `completed` ou `cancelled`. Transmissões ao vivo fora desse período são rejeitadas. Sincronização tardia de registros capturados offline é um fluxo distinto, sujeito à validação do período e da atribuição originais.

**Perda de conexão — decisão aprovada em 2026-09-07:** o aplicativo mostra a última posição com seu horário e indicação de sinal desatualizado. Durante a falta de conexão, armazena temporariamente GPS e registros de embarque e desembarque para sincronizar depois. O backend valida autoria, sequência e duplicação, sem tratar amostras antigas como posição atual. Início, substituição e encerramento da viagem exigem conexão. O plano de backend define os contratos dessa sincronização; o armazenamento no dispositivo pertence ao Flutter.

**Trade-off offline:** permite registrar a operação durante perda de sinal, mas o acompanhamento e os avisos podem ficar atrasados até a sincronização. Comandos de ciclo de vida continuam online para preservar um estado autoritativo da viagem.

O payload ao vivo contém a posição da van e dados operacionais mínimos. Endereços de alunos nunca entram no broadcast.

Consultas de mapa aplicam projeções por papel:

- dono e motorista recebem a rota operacional completa;
- responsável recebe posição atual, escolas, ETA, ponto do próprio dependente e trecho aproximado relevante;
- aluno adulto recebe posição atual, escolas, ETA, próprio ponto e trecho aproximado relevante.

Ocultar um marcador apenas no Flutter não protege os dados. O backend nunca envia pontos, identidades ou a geometria completa capaz de revelar casas de outros alunos.

Pontos brutos de GPS expiram após 30 dias. O sistema conserva resumos, distância, duração, horários, atrasos, ocorrências, embarques, desembarques e auditoria.

### 6.9 Roteirização e ETA

Uma Edge Function encapsula o provedor de geocodificação e rotas. O domínio não depende diretamente do formato de um fornecedor.

**Falha no cálculo — decisão aprovada em 2026-09-07:** uma viagem ainda não iniciada pode operar com pontos válidos e ordem manual definida pelo dono quando o cálculo externo falhar, indicando ausência de otimização e ETA. Se o novo endereço não puder ser localizado, o dono precisa definir o ponto correto antes de iniciar a viagem afetada. A falha não autoriza reutilizar silenciosamente o endereço anterior nem alterar uma viagem ativa.

**Trade-off da operação manual:** a indisponibilidade do provedor não impede transporte com pontos válidos, mas transfere ao dono a definição da ordem e deixa o usuário sem ETA confiável até a recuperação do cálculo.

Estratégia de cálculo:

1. calcular a rota-base quando aluno, endereço, escola, van ou configuração mudar;
2. criar as viagens do dia seguinte sem chamar o provedor;
3. receber confirmações até o prazo;
4. recalcular no fechamento se a revisão aplicável mudou, incluindo passageiros, endereços, escolas e configuração;
5. atualizar mudanças cadastrais na próxima viagem não iniciada e congelar o snapshot no início;
6. recalcular excepcionalmente após desvio ou incidente autorizado.

O dono define a ordem das escolas. O serviço otimiza as residências e respeita horários e sequência. Uma rota pode atravessar cidades diferentes.

O limite esperado é de 30 alunos, mais partida, destino e escolas. A seleção do provedor deverá validar limite de paradas, trânsito, ETA, cobertura, preço e termos de armazenamento. Se o limite for menor, a implementação dividirá o cálculo em trechos mantendo uma única viagem no domínio.

### 6.10 Notificações

`device_tokens` registra tokens por usuário, dispositivo e plataforma. Tokens inválidos são desativados.

`notifications` registra conteúdo, categoria, tenant, público e entidade de origem. `notification_deliveries` registra tentativa, resultado, provedor e deduplicação.

Eventos automáticos do MVP:

- confirmação disponível;
- prazo de confirmação próximo;
- viagem iniciada;
- van a cerca de 10 minutos do ponto;
- van chegou ao ponto;
- aluno embarcou;
- aluno desembarcou;
- van chegou à escola;
- atraso, desvio, cancelamento ou ocorrência.

O aviso de proximidade usa ETA, não distância fixa. O padrão é 10 minutos e pode variar por rota. Uma chave de deduplicação impede alertas repetidos.

O dono envia mensagens para toda a frota, rota, viagem, van ou usuário. O motorista envia somente categorias predefinidas, com observação opcional, para participantes da própria viagem.

**Provedor de push — decisão aprovada em 2026-09-07:** Firebase Cloud Messaging (FCM) atende Flutter iOS e Android. Uma Edge Function envia mensagens pela API HTTP v1 com credenciais server-side. O iOS exige configuração APNs no Firebase. Credenciais administrativas nunca chegam ao Flutter. Referências: [FCM para Flutter](https://firebase.google.com/docs/cloud-messaging/flutter/get-started) e [HTTP v1](https://firebase.google.com/docs/cloud-messaging/send/v1-api).

**Caixa de avisos — decisão aprovada em 2026-09-07:** notificações ficam disponíveis no aplicativo, com estado de leitura por destinatário, além do push. Falha ou desativação do push não remove o aviso. O conteúdo exibido na tela bloqueada é discreto e não contém endereço nem informação sensível do aluno.

**Entrega — decisão aprovada em 2026-09-07:** falhas temporárias recebem novas tentativas com deduplicação. Alertas que perderam utilidade não são enviados atrasados; por exemplo, proximidade não gera push depois do desembarque. Falha na entrega não desfaz a operação de domínio já registrada, como confirmação ou embarque. O plano deve definir validade por categoria e garantir que o registro do evento sobreviva à indisponibilidade do provedor.

**Mensagens manuais — decisão aprovada em 2026-09-07:** a comunicação é unidirecional. O dono envia aos públicos autorizados; o motorista usa categorias predefinidas com observação para sua viagem. O MVP não inclui chat nem respostas às mensagens.

**Trade-off das notificações:** a caixa de avisos preserva o acesso ao conteúdo quando o push falha, mas não garante que o usuário o leia. Novas tentativas e validade por categoria evitam perder avisos úteis ou enviar alertas operacionais obsoletos; a operação do transporte não depende da disponibilidade do serviço de push.

## 7. Fluxos de negócio

### 7.1 Cadastro e criação de frota

1. Usuário cria conta com e-mail e senha.
2. Trigger cria `profiles`.
3. Usuário completa o perfil.
4. Usuário confirma o e-mail.
5. RPC cria a frota, a associação e o papel `owner` na mesma transação.
6. O dono pode manter a frota em rascunho ou publicá-la imediatamente.

### 7.2 Descoberta e solicitação

1. Responsável ou aluno adulto filtra frotas por cidade e escola coberta.
2. O usuário informa o endereço completo em área privada.
3. O backend grava um snapshot do endereço na solicitação.
4. O dono aceita ou recusa; solicitações integralmente atendíveis respeitam a ordem de chegada.
5. Aprovar cria o vínculo, associa os papéis derivados, reserva todas as vagas e audita a mesma transação, conforme a seção 6.3.

Frotas são públicas; usuários não. O dono vê somente pessoas que solicitaram acesso ou contatos que ele convidou.

### 7.3 Geração e confirmação da viagem

1. Cron cria `service_days`, `trips` e passageiros previstos para o dia seguinte.
2. Cada passageiro começa como `pending`.
3. Responsável ou aluno adulto confirma ou recusa ida e volta separadamente.
4. O sistema envia lembretes antes do prazo configurado.
5. No prazo, pendências passam para `expired`.
6. Confirmados entram na rota final; recusados e expirados permanecem no histórico.
7. O sistema recalcula quando a revisão de passageiros, pontos, escolas ou configuração diferir da versão válida.

### 7.4 Execução da viagem

1. Motorista atribuído inicia a viagem.
2. O backend valida motorista, van, estado e tenant.
3. O canal Realtime passa a aceitar localização.
4. O motorista segue as paradas autorizadas e atualiza o estado dos passageiros.
5. O sistema recalcula ETA, envia notificações e registra amostras.
6. O motorista registra incidentes ou desvios quando necessário.
7. Ao concluir ou cancelar, o backend fecha o rastreamento e produz o resumo permanente.

## 8. Autorização e RLS

### 8.1 Princípios

- RLS fica ativa em toda tabela exposta.
- `auth.uid()` identifica o usuário.
- Helpers privados verificam associação ativa e papel por `fleet_id`.
- Funções `security definer` usam `search_path` explícito, privilégios mínimos e revisão dedicada.
- A chave pública do Supabase pode ficar no aplicativo; a chave secreta administrativa permanece fora dele.
- O cliente nunca decide o próprio papel, tenant, capacidade ou autorização.
- Índices acompanham todas as colunas usadas em policies e relações de tenant.

Helpers privados evitam recursão entre policies de associação e papéis. Chamadas anônimas retornam nenhum dado privado. Conhecer o UUID de uma entidade não altera o resultado.

### 8.2 Matriz resumida

| Recurso | Público | Membro | Motorista atribuído | Dono |
| --- | --- | --- | --- | --- |
| perfil público da frota | leitura sanitizada | leitura | leitura | gestão |
| perfil completo de usuário | nenhum | próprio | próprio | somente projeções necessárias |
| membros da frota | nenhum | próprio vínculo | equipe necessária | gestão do tenant |
| alunos e endereços | nenhum | próprios vínculos | viagem atribuída | tenant autorizado |
| rota completa | nenhum | projeção limitada | atribuída | tenant |
| viagem ao vivo | nenhum | própria participação | atribuída | tenant |
| localização de outras casas | nenhum | nenhum | operacional | operacional |
| auditoria | nenhum | ações próprias quando previsto | ações próprias quando previsto | tenant |

### 8.3 RPCs críticas previstas

No Ciclo 2, as RPCs públicas incluem:

- `search_schools`, `search_marketplace`, `list_fleet_join_requests` e `get_fleet_invitation`;
- `create_minor_student`, `create_adult_student` e `update_student`;
- convites de responsáveis e de frotas;
- submissão, cancelamento e decisão de solicitações;
- aceitação/recusa/cancelamento de convites e encerramento de vínculos.

As operações posteriores continuam previstas:

- criar frota e primeiro dono;
- alterar papéis sem remover o último dono;
- solicitar e revisar vínculo;
- atribuir aluno com validação de capacidade e conflito;
- confirmar ou recusar viagem;
- substituir motorista ou van;
- iniciar, concluir ou cancelar viagem;
- registrar estado do passageiro e ocorrência;
- produzir resumo e encerrar rastreamento.

Erros terão códigos estáveis, entre eles `email_unverified`, `forbidden`, `membership_conflict`, `capacity_exceeded`, `schedule_conflict`, `invalid_transition` e `last_owner`. O Flutter não dependerá do texto humano da mensagem.

## 9. Consistência e concorrência

Operações de capacidade, atribuição e mudança de estado devem ocorrer em transações. O banco deve impedir:

- duas associações idênticas entre usuário e frota;
- dois responsáveis principais ativos para o mesmo menor;
- mais de três preferências por solicitação;
- atribuição acima da capacidade programada;
- horários conflitantes para o mesmo aluno, motorista ou van;
- início simultâneo indevido da mesma viagem;
- localização enviada por motorista não atribuído;
- transições inválidas de confirmação, embarque e viagem;
- edição de snapshots históricos;
- remoção do último dono.

O desenho detalhado escolherá constraints, índices únicos parciais, locks ou níveis de isolamento conforme cada invariante.

## 10. Retenção e privacidade

- GPS bruto: 30 dias.
- Resumo da viagem: permanente enquanto o produto mantiver o histórico.
- Atrasos, ocorrências e desvios: permanentes.
- Embarques, desembarques e ausências: permanentes.
- Auditoria: permanente e imutável para usuários comuns.
- Tokens de dispositivo: até revogação ou invalidação.

Jobs de retenção apagam somente dados cobertos pela política. Eles registram execução e falha sem guardar conteúdo sensível.

O backend retorna a menor projeção necessária para cada papel. Dados de menores, residências e deslocamentos exigem testes negativos específicos de RLS.

## 11. Estratégia de entrega

O projeto será dividido em seis ciclos:

1. **Fundação multi-tenant:** ambiente Supabase local, Auth, `profiles`, `fleets`, associações, papéis, RLS e auditoria.
2. **Marketplace e vínculos:** catálogo vazio, cidades e instituições cobertas, alunos, responsáveis, solicitações, convites, vínculos, RLS e auditoria. Preferências, capacidade e lista de espera ficaram fora do corte.
3. **Frota e planejamento:** vans, capacidade, motoristas, rotas, pares de sentido, escolas, agendas, reservas, fila e alterações de programação.
4. **Operação diária:** calendário, `service_days`, `trips`, passageiros, confirmações, presença, substituições, ocorrências e estados operacionais.
5. **Notificações:** caixa de avisos, leitura, push, mensagens unidirecionais, eventos operacionais, deduplicação e validade de alertas.
6. **Mapa, rastreamento e roteirização:** GPS, Realtime privado, sincronização offline, projeções seguras, retenção, geocodificação, otimização e ETA; integração dos alertas de proximidade com o Ciclo 5.

**Sequência aprovada em 2026-09-07:** notificações operacionais precedem o mapa. Ocorrências pertencem ao Ciclo 4; o Ciclo 6 acrescenta rastreamento e os eventos dependentes de localização e ETA. O contrato de presença do Ciclo 4 deve permitir a evolução para sincronização offline no Ciclo 6. Cada ciclo restante terá spec e implementation plan próprios; esta organização não registra implementação concluída.

**Destino da entrega — decisão aprovada em 2026-09-07:** os planos incluem preparação e publicação em produção. O ambiente local é a homologação: validar primeiro localmente e então publicar em produção, sem projeto remoto de staging. Devem prever configuração de Auth e callbacks para Flutter iOS/Android, segredos de integrações, aplicação ordenada de migrations sem seed fictício, implantação de Edge Functions e jobs, validação de RLS e contratos no ambiente publicado e procedimentos de recuperação e verificação pós-publicação. Esta etapa da conversa produz documentação; nenhuma publicação foi executada.

**Trade-off local → produção:** dispensa um ambiente remoto intermediário, mas testes locais não comprovam credenciais, limites ou conectividade do ambiente publicado. Cada ciclo exige inspeção prévia do destino e verificação controlada pós-publicação. Homologação local não autoriza reset de produção nem uso de dados reais nos testes.

**Dependência externa em espera — decisão de 2026-09-07:** orçamento, escala inicial e seleção de provedores de mapas e rotas ficam em stand-by por solicitação do usuário. Não assumir plano comercial, contratar serviço nem fixar fornecedor enquanto essa decisão estiver suspensa. A spec e o plano do Ciclo 6 devem separar o trabalho independente de fornecedor da integração bloqueada por essa escolha. A conclusão e publicação do escopo completo de mapas e roteirização exigem a seleção, as credenciais e a validação do provedor; operação manual é contingência e não substitui essa entrega. Push já está definido como FCM.

Cada ciclo terá uma especificação aprovada, plano de implementação, migrações, RLS e testes próprios. Nenhum ciclo posterior deve ampliar silenciosamente o escopo do anterior.

## 12. Ciclos implementados localmente

O primeiro ciclo entrega somente:

- configuração local do Supabase;
- migrações ordenadas;
- criação automática do perfil;
- criação transacional de frota e primeiro dono;
- associações com múltiplos papéis;
- helpers privados de autorização;
- policies RLS;
- auditoria básica;
- dados fictícios locais;
- documentação coerente.

O Ciclo 2 acrescenta `schools`, coberturas comerciais, `students`, `student_guardians`, convites, solicitações, vínculos e fontes de papéis, com RLS, RPCs e auditoria sanitizada. O catálogo permanece sem dados reais e não há importador.

Testes mínimos da fundação:

- criação automática de perfil;
- criação atômica de frota e dono;
- múltiplos papéis e múltiplas frotas;
- bloqueio de leitura e escrita entre tenants;
- diferença de permissões entre dono e demais papéis;
- bloqueio da remoção do último dono;
- exigência de e-mail confirmado;
- imutabilidade da auditoria;
- rejeição de chamadas anônimas;
- isolamento quando o usuário conhece UUIDs de outro tenant.

## 13. TDD obrigatório

Toda implementação segue uma sequência estrita e repetida:

1. escrever um teste para um único comportamento;
2. executar o teste e confirmar `RED` pela razão esperada;
3. escrever a menor migração, função ou policy que resolva o comportamento;
4. executar o teste e confirmar `GREEN`;
5. refatorar mantendo todos os testes verdes;
6. iniciar o próximo comportamento.

O time não escreverá toda a implementação antes dos testes nem criará uma grande suíte vermelha de uma vez. Cada fatia deve produzir evidência de `RED` e `GREEN`.

## 14. Decisões pendentes

Estas decisões exigem pesquisa antes do ciclo correspondente:

- API externa para catálogo de escolas e faculdades;
- provedor de geocodificação, matriz, otimização e ETA;
- credenciais e configuração FCM/APNs para o provedor de push já aprovado;
- frequência adaptativa do GPS e intervalo de persistência das amostras;
- termos de retenção permanente conforme política de privacidade e requisitos legais.

Os critérios já estão definidos. A pesquisa deverá priorizar fontes oficiais, cobertura no Brasil, segurança, limites, custo e licença. Nenhuma implementação deve fixar um provedor antes dessa decisão.
