# VanGo — plano técnico do backend

## 1. Estado e finalidade

Este documento registra a arquitetura aprovada para o MVP do VanGo. Os Ciclos 0, 1 e 2 estão implementados localmente no Supabase; vans, rotas, operação, mapa e notificações continuam planejados para ciclos posteriores.

O aplicativo será mobile, desenvolvido em Flutter. Este repositório concentrará todo o backend no Supabase. Não haverá API Node.js, JWT próprio, `bcrypt` ou servidor Socket.io no MVP.

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

O repositório não terá essa estrutura até o início da implementação. Migrações serão a única forma válida de alterar o banco compartilhado.

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

### 6.4 Vans e atribuições

`vans` pertence a uma frota e contém:

- placa única conforme a regra definida no ciclo;
- modelo, identificação pública e capacidade;
- status operacional;
- dados públicos resumidos para o marketplace;
- datas de criação e atualização.

O MVP deve suportar cerca de 30 alunos por van. A capacidade permanece configurável.

Uma rota possui van e motorista padrão. Cada viagem copia essa configuração para preservar o histórico. O dono pode substituir van ou motorista antes da saída. A substituição exige motivo e gera auditoria sem alterar a rota recorrente.

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

`route_student_schedules` define os dias em que cada aluno usa aquela rota. Ida e volta são independentes. Um aluno pode faltar na ida e usar normalmente a volta.

### 6.6 Dias de serviço e viagens

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

Ao vencer o prazo, `pending` passa para `expired` e fica fora da otimização. O sistema não apaga nem troca a atribuição; ele conserva a decisão no histórico. Após o início, somente uma exceção autorizada pode mudar a participação, sempre com auditoria.

`trip_stops` guarda o snapshot das paradas usadas na viagem:

- origem, residência, escola ou destino final;
- ordem planejada e real;
- coordenadas e endereço necessários à operação;
- ETA e horário real;
- aluno ou escola relacionados, quando aplicável.

Snapshots impedem que a edição posterior de um endereço altere uma viagem concluída.

### 6.7 Ocorrências e mudanças operacionais

`trip_incidents` registra:

- categoria: trânsito, atraso, acidente, falha mecânica, desvio ou outra;
- descrição opcional;
- autor, data e localização;
- impacto estimado e estado de resolução.

Substituições de motorista ou van e desvios temporários registram configuração anterior, nova configuração, autor, horário e motivo. Resumos dessas mudanças permanecem junto ao histórico da viagem.

### 6.8 Localização em tempo real

`trip_location_points` armazena amostras do GPS:

- `fleet_id` e `trip_id`;
- latitude, longitude, velocidade, direção e precisão;
- horário capturado no dispositivo e recebido pelo backend.

O fluxo ao vivo usa um canal privado `trip:{trip_id}`. Somente o motorista atribuído transmite. O dono da frota recebe todas as viagens ativas. Responsáveis e alunos adultos recebem apenas viagens em que o aluno esteja confirmado.

O rastreamento começa quando a viagem entra em `active` e termina em `completed` ou `cancelled`. Mensagens fora desse período são rejeitadas.

O payload ao vivo contém a posição da van e dados operacionais mínimos. Endereços de alunos nunca entram no broadcast.

Consultas de mapa aplicam projeções por papel:

- dono e motorista recebem a rota operacional completa;
- responsável recebe posição atual, escolas, ETA, ponto do próprio dependente e trecho aproximado relevante;
- aluno adulto recebe posição atual, escolas, ETA, próprio ponto e trecho aproximado relevante.

Ocultar um marcador apenas no Flutter não protege os dados. O backend nunca envia pontos, identidades ou a geometria completa capaz de revelar casas de outros alunos.

Pontos brutos de GPS expiram após 30 dias. O sistema conserva resumos, distância, duração, horários, atrasos, ocorrências, embarques, desembarques e auditoria.

### 6.9 Roteirização e ETA

Uma Edge Function encapsula o provedor de geocodificação e rotas. O domínio não depende diretamente do formato de um fornecedor.

Estratégia de cálculo:

1. calcular a rota-base quando aluno, endereço, escola, van ou configuração mudar;
2. criar as viagens do dia seguinte sem chamar o provedor;
3. receber confirmações até o prazo;
4. recalcular no fechamento somente se a lista de passageiros mudou;
5. congelar a versão operacional da viagem;
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

Uma Edge Function envia push pelo provedor escolhido. A chave administrativa e as credenciais do provedor nunca chegam ao Flutter.

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
4. O dono aprova ou rejeita a solicitação; não há lista de espera neste ciclo.
5. Ao aprovar, o backend cria o vínculo, associa os papéis derivados e audita a transação.

Frotas são públicas; usuários não. O dono vê somente pessoas que solicitaram acesso ou contatos que ele convidou.

### 7.3 Geração e confirmação da viagem

1. Cron cria `service_days`, `trips` e passageiros previstos para o dia seguinte.
2. Cada passageiro começa como `pending`.
3. Responsável ou aluno adulto confirma ou recusa ida e volta separadamente.
4. O sistema envia lembretes antes do prazo configurado.
5. No prazo, pendências passam para `expired`.
6. Confirmados entram na rota final; recusados e expirados permanecem no histórico.
7. O sistema recalcula a rota somente quando a lista mudou.

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
3. **Frota e planejamento:** vans, capacidade, motoristas, rotas, pares de sentido, escolas, agendas e alunos programados.
4. **Operação diária:** `service_days`, `trips`, passageiros, confirmações, substituições e estados operacionais.
5. **Rastreamento e ocorrências:** Realtime privado, GPS, projeções seguras, incidentes e retenção.
6. **Roteirização e notificações:** geocodificação, otimização, ETA, push, deduplicação e provedores externos.

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
- provedor final de push, considerando suporte a Flutter e operação server-side;
- frequência adaptativa do GPS e intervalo de persistência das amostras;
- termos de retenção permanente conforme política de privacidade e requisitos legais.

Os critérios já estão definidos. A pesquisa deverá priorizar fontes oficiais, cobertura no Brasil, segurança, limites, custo e licença. Nenhuma implementação deve fixar um provedor antes dessa decisão.
