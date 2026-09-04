# VanGo Backend

Backend do VanGo, um aplicativo mobile em Flutter para gestão de transporte escolar e universitário. O MVP usa o Supabase como backend completo, sem servidor Node.js próprio.

## Status do repositório

O projeto está na fase de arquitetura. Este repositório contém a visão do produto, o plano técnico e as diretrizes de desenvolvimento. Ainda não há código executável, migrações, Edge Functions ou testes.

Nenhuma funcionalidade descrita abaixo deve ser tratada como implementada.

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

### Marketplace

Frotas publicadas aparecem em uma pesquisa por cidades atendidas, escola, turno, disponibilidade e distância aproximada. Somente frotas são públicas; não existe diretório público de responsáveis ou alunos.

O usuário informa o endereço completo de forma privada. O backend mostra vans compatíveis com dados resumidos do veículo e do motorista, partida e janela estimada de busca. O solicitante ordena até três preferências. O dono decide a van final e pode escolher outra opção compatível.

Uma frota pode atender várias cidades. Uma rota pode partir da cidade A, buscar um aluno na cidade B e chegar a uma escola na cidade C.

### Frota e rotas

O dono cadastra vans, define a capacidade, configura rotas e escolhe motorista e van padrão. Ele pode substituir ambos em uma viagem específica sem mudar o planejamento futuro.

Cada `route` representa um único sentido: ida ou volta. Rotas opostas podem formar um par. Uma rota contém escolas ordenadas por uma tabela relacional; o dono define a ordem das escolas. O sistema otimiza as paradas residenciais respeitando essa ordem e os horários.

As escolas virão de um catálogo global abastecido por uma API externa. O dono escolhe opções existentes e não cadastra escolas manualmente. A fonte externa será escolhida antes do ciclo de marketplace.

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

Responsáveis e alunos adultos acompanham somente viagens nas quais o aluno está confirmado. Eles recebem a posição atual da van, a escola, o ETA, o próprio ponto e um trajeto público aproximado. O backend nunca envia endereços, identidades, pontos ou a geometria completa que possa revelar a casa de outro aluno.

Os pontos brutos de GPS permanecem por 30 dias. Resumos de viagem, distância, duração, horários, atrasos, ocorrências, embarques, desembarques e eventos de auditoria permanecem sem prazo de expiração definido.

### Roteirização

A rota-base será recalculada quando alunos, endereços, escolas ou atribuições mudarem. Criar a viagem diária não chama o provedor de rotas. No encerramento das confirmações, o sistema recalcula somente se a lista de passageiros mudou. Incidentes podem disparar um novo cálculo excepcional.

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

1. **Fundação multi-tenant:** Supabase local, Auth, perfis, frotas, associações, múltiplos papéis, RLS e auditoria.
2. **Marketplace e vínculos:** catálogo de escolas, cidades atendidas, alunos, responsáveis, solicitações, preferências e lista de espera.
3. **Frota e planejamento:** vans, capacidade, motoristas, rotas, escolas ordenadas, agendas e atribuições.
4. **Operação diária:** dias de serviço, viagens, confirmações, substituições e presença.
5. **Rastreamento e ocorrências:** Realtime privado, GPS, visibilidade segura, desvios, atrasos e retenção.
6. **Roteirização e notificações:** otimização, ETA, geocodificação, push e integrações externas.

Cada etapa terá especificação e plano próprios. A implementação começará pela fundação e seguirá TDD estrito.

## Documentação

- [Plano técnico e modelo de domínio](./be-tech-plan.md)
- [Diretrizes de desenvolvimento](./CONTRIBUTING.md)
