# Ciclo 2 — Marketplace e vínculos

**Data:** 6 de setembro de 2026
**Status:** aprovado para planejamento
**Base:** Ciclo 1 concluído localmente em `9d42709`

## Objetivo

Entregar o catálogo vazio de instituições, a cobertura comercial das frotas, o cadastro de alunos e responsáveis, o marketplace público e os fluxos de solicitação, convite e vínculo. O ciclo preserva o isolamento por frota e os dados pessoais dos alunos.

## Corte aprovado

O Ciclo 2 inclui:

- tabela global `schools`, sem carga inicial;
- cobertura por cidade em `fleet_service_cities`;
- cobertura por instituição em `fleet_service_schools`;
- alunos menores e adultos;
- responsáveis principal e secundários;
- convites para responsáveis secundários;
- busca pública por instituições e frotas publicadas;
- solicitações iniciadas pelo marketplace;
- convites iniciados pelo dono da frota;
- vínculos aprovados em `fleet_enrollments`;
- RLS, RPCs, auditoria sanitizada e testes pgTAP.

O Ciclo 2 exclui:

- inserção de escolas ou faculdades reais;
- importador, integração com INEP, e-MEC, Google, Mapbox ou OpenStreetMap;
- painel administrativo do catálogo;
- preferências de van;
- capacidade, disponibilidade real e lista de espera;
- vans, motoristas, rotas e agendas;
- envio de e-mail, push ou outra notificação;
- alteração no aplicativo Flutter.

O catálogo será preenchido diretamente no Supabase no futuro. A primeira carga pretendida abrangerá instituições ativas e campi presenciais de Itapetininga, Sorocaba, São Miguel Arcanjo, Tatuí, Capão Bonito e Pilar do Sul. Essa intenção não cria dados nem restringe o schema a essas cidades.

## Arquitetura

O Flutter continuará usando a Data API para leituras e alterações simples protegidas por RLS. Database Functions executarão criação de alunos, convites, transições de estado, criação de associações e vínculos, propagação de papéis e auditoria.

O ciclo não cria Edge Functions. O backend retorna o token bruto de cada convite uma única vez; o Flutter formará o deep link e preservará `/invite/:token` durante cadastro, login e callback do Supabase Auth. O banco guarda somente o hash do token.

## Modelo de dados

### `schools`

Catálogo global curado. Usuários autenticados e anônimos não escrevem diretamente na tabela.

Campos mínimos:

- `id uuid`;
- `provider text`: `inep` ou `emec`;
- `external_id text`;
- `institution_type text`: `school` ou `higher_education`;
- `name text`;
- `postal_code text`;
- `street text`;
- `street_number text`;
- `address_complement text` opcional;
- `neighborhood text`;
- `city_name text`;
- `city_ibge_code text` com sete dígitos;
- `state_code text` com duas letras maiúsculas;
- `latitude numeric` e `longitude numeric` opcionais;
- `status text`: `active` ou `inactive`;
- `source_updated_at date`;
- `created_at` e `updated_at`.

`(provider, external_id)` é único. `inep` aceita apenas `school`; `emec` aceita apenas `higher_education`. Para ensino superior, `external_id` identifica o campus ou local de oferta, não apenas a sede da instituição.

### `fleet_service_cities`

Registra cobertura comercial sem criar uma tabela global de cidades.

Campos mínimos:

- `fleet_id`;
- `city_ibge_code`;
- `city_name`;
- `state_code`;
- `created_by`;
- `created_at`.

A chave é `(fleet_id, city_ibge_code)`. Membros ativos consultam; somente owners inserem e removem registros da própria frota.

### `fleet_service_schools`

Liga a frota às instituições que ela declara atender comercialmente. Essa relação não substitui `route_schools`, prevista para o Ciclo 3.

Campos mínimos:

- `fleet_id`;
- `school_id`;
- `created_by`;
- `created_at`.

A chave é `(fleet_id, school_id)`. A relação aceita somente instituição ativa e somente owners a alteram.

### `students`

Representa menores e alunos adultos fora de um tenant específico, pois um aluno pode usar várias frotas.

Campos mínimos:

- `id`;
- `student_type`: `minor` ou `adult`;
- `profile_id` opcional e único;
- `full_name`;
- `birth_date`;
- endereço estruturado com os mesmos campos de `schools`;
- coordenadas opcionais;
- `created_by`;
- `created_at` e `updated_at`.

Adultos possuem `profile_id`; menores não. A RPC de criação valida 18 anos na data da operação. O ciclo não automatiza a transição de um menor quando ele completa 18 anos.

### `student_guardians`

Relaciona um menor aos responsáveis.

Campos mínimos:

- `student_id`;
- `guardian_user_id`;
- `is_primary`;
- `status`: `active` ou `removed`;
- `joined_at`;
- `removed_at` opcional.

Cada menor possui exatamente um responsável principal ativo. O principal cadastra e altera o aluno, convida secundários e os remove. Secundários consultam e acompanham, mas não alteram o aluno nem administram responsáveis.

### Convites

`student_guardian_invitations` permite ao responsável principal convidar um secundário. `fleet_invitations` permite ao owner convidar um responsável ou aluno adulto.

Ambas guardam:

- e-mail normalizado;
- hash SHA-256 de token aleatório de 32 bytes;
- autor;
- status `pending`, `accepted`, `declined`, `cancelled` ou `expired`;
- expiração após 14 dias;
- datas da transição e usuário que respondeu.

Somente um convite pendente pode existir para o mesmo e-mail e contexto. O usuário precisa autenticar, confirmar o mesmo e-mail e voltar à rota do convite. Outro e-mail recebe `invitation_email_mismatch`.

Como o ciclo não possui Cron, uma RPC que toca um convite vencido muda seu estado para `expired` e retorna esse estado sem aceitar o convite.

### `fleet_join_requests`

Registra solicitações do marketplace e o formulário preenchido ao aceitar um convite da frota.

Campos mínimos:

- frota, solicitante, aluno e instituição;
- origem `marketplace` ou `invitation`;
- convite da frota opcional;
- turno `morning`, `afternoon`, `evening` ou `full_time`;
- sentidos `going` e/ou `return`;
- dias ISO da semana, de 1 a 7;
- snapshot estruturado do endereço do aluno;
- status `pending`, `approved`, `rejected` ou `cancelled`;
- decisão, autor e datas.

A solicitação é imutável. O solicitante pode apenas cancelar uma solicitação pendente. Para corrigir dados, cancela e envia outra. Existe no máximo uma solicitação pendente por aluno e frota.

Solicitações do marketplace exigem frota publicada, instituição ativa, cobertura da instituição e cobertura da cidade do endereço. Convites aceitos criam uma solicitação já aprovada para preservar o mesmo histórico.

### `fleet_enrollments`

Representa o vínculo aprovado entre frota e aluno.

Campos mínimos:

- `id`;
- `fleet_id`;
- `student_id`;
- `source_request_id` único;
- status `active` ou `ended`;
- `started_at`;
- `ended_at`, `ended_by` e `end_reason` opcionais.

Existe no máximo um vínculo ativo por aluno e frota. Registros encerrados permanecem no histórico.

## Fluxos

### Cadastro de aluno

O responsável principal cria o menor e o próprio vínculo primário na mesma transação. O aluno adulto cria somente o próprio registro. O owner não cadastra alunos.

Alterações de endereço ou identidade passam por RPC. A auditoria registra somente os nomes dos campos alterados em cada frota com vínculo ativo.

### Responsável secundário

O principal cria um convite para qualquer e-mail. O destinatário pode criar a conta, confirmar o e-mail e retornar pelo callback. Ao aceitar, torna-se responsável secundário e recebe acesso `guardian` em todos os vínculos ativos do aluno e nos vínculos futuros.

Uma suspensão existente na frota prevalece. A remoção do secundário retira somente acessos derivados daquele aluno; preserva outros papéis e dependentes.

### Solicitação do marketplace

O responsável principal envia a solicitação de um menor. O aluno adulto envia a própria solicitação. O backend copia o endereço atual para o snapshot e não aceita endereço arbitrário no payload.

O owner aprova ou rejeita. A aprovação bloqueia a solicitação, confirma `pending`, cria ou reativa a associação adequada, adiciona `guardian` ou `student` sem remover outros papéis, cria o vínculo, atualiza a solicitação e grava auditoria na mesma transação.

### Convite da frota

O owner cria um convite com papel `guardian` ou `student`. O destinatário abre o link. Sem sessão, o Flutter preserva o token ao navegar para cadastro ou login. Após o callback, o backend valida o e-mail confirmado.

Ao aceitar, o responsável seleciona um menor que administra; o aluno adulto usa o próprio registro. O destinatário informa escola, turno, sentidos e dias. A RPC cria uma solicitação `approved`, a associação, o papel e o vínculo na mesma transação.

### Encerramento

O owner encerra um vínculo com motivo obrigatório. A operação remove um papel derivado somente quando nenhum outro vínculo ativo daquele usuário exige o mesmo papel na frota. A associação e os demais papéis permanecem intactos.

## Consultas públicas

`search_schools` aceita texto, cidade, tipo, limite e deslocamento. Retorna somente instituições ativas e campos públicos. A pesquisa tolera acentos, mas usa uma busca simples adequada ao catálogo regional inicial.

`search_marketplace` aceita cidade, instituição, limite e deslocamento. Retorna apenas nome, slug, descrição e logo de frotas `published` que declararam a cobertura solicitada. A consulta não retorna vans, capacidade, disponibilidade, membros ou dados operacionais.

## Autorização e privacidade

- `anon` executa somente as duas consultas públicas.
- Usuários consultam os próprios alunos, dependentes, convites, solicitações e vínculos.
- O responsável principal altera o menor; secundários somente consultam.
- Owners consultam solicitações e alunos por projeções controladas.
- O endereço de uma solicitação aparece ao owner enquanto ela está pendente ou enquanto o vínculo permanece ativo.
- Depois de rejeição, cancelamento ou encerramento, o owner vê o histórico sem endereço.
- Tabelas transacionais negam escrita direta a `anon` e `authenticated`.
- Conhecer um UUID de outro tenant não revela a existência do recurso.
- Auditorias omitem e-mail, token, endereço e coordenadas.

## Contratos RPC

Consultas:

```text
search_schools(p_query text, p_city_ibge_code text, p_institution_type text, p_limit integer, p_offset integer)
search_marketplace(p_city_ibge_code text, p_school_id uuid, p_limit integer, p_offset integer)
list_fleet_join_requests(p_fleet_id uuid, p_status text, p_limit integer, p_offset integer)
get_fleet_invitation(p_token text)
```

Comandos:

```text
create_minor_student(p_full_name text, p_birth_date date, p_postal_code text, p_street text, p_street_number text, p_address_complement text, p_neighborhood text, p_city_name text, p_city_ibge_code text, p_state_code text, p_latitude numeric, p_longitude numeric) returns uuid
create_adult_student(p_full_name text, p_birth_date date, p_postal_code text, p_street text, p_street_number text, p_address_complement text, p_neighborhood text, p_city_name text, p_city_ibge_code text, p_state_code text, p_latitude numeric, p_longitude numeric) returns uuid
update_student(p_student_id uuid, p_full_name text, p_birth_date date, p_postal_code text, p_street text, p_street_number text, p_address_complement text, p_neighborhood text, p_city_name text, p_city_ibge_code text, p_state_code text, p_latitude numeric, p_longitude numeric) returns uuid
create_student_guardian_invitation(p_student_id uuid, p_email text) returns text
respond_student_guardian_invitation(p_token text, p_accept boolean) returns text
remove_student_guardian(p_student_id uuid, p_guardian_user_id uuid) returns text
submit_fleet_join_request(p_fleet_id uuid, p_student_id uuid, p_school_id uuid, p_shift text, p_directions text[], p_weekdays smallint[]) returns uuid
cancel_fleet_join_request(p_request_id uuid) returns text
decide_fleet_join_request(p_request_id uuid, p_decision text) returns text
create_fleet_invitation(p_fleet_id uuid, p_email text, p_role text) returns text
accept_fleet_invitation(p_token text, p_student_id uuid, p_school_id uuid, p_shift text, p_directions text[], p_weekdays smallint[]) returns uuid
decline_fleet_invitation(p_token text) returns text
cancel_fleet_invitation(p_invitation_id uuid) returns text
end_fleet_enrollment(p_enrollment_id uuid, p_reason text) returns text
```

Os nomes completos dos argumentos de endereço serão fixados no plano de implementação. Funções `security definer` usam `search_path = ''`, nomes qualificados, grants mínimos e locks antes de transições.

## Erros

| Código | Situação |
| --- | --- |
| `unauthenticated` | sessão ausente |
| `email_unverified` | operação exige e-mail confirmado |
| `forbidden` | papel ou relação insuficiente |
| `not_found` | recurso ausente ou invisível |
| `invalid_input` | campo, endereço, turno, sentido ou dia inválido |
| `invalid_transition` | estado atual não aceita a ação |
| `student_conflict` | tipo, idade ou perfil incompatível |
| `guardian_conflict` | vínculo de responsável inválido |
| `request_conflict` | solicitação duplicada ou incompatível |
| `invitation_conflict` | convite duplicado ou incompatível |
| `invitation_expired` | convite fora de validade |
| `invitation_email_mismatch` | sessão usa outro e-mail |
| `enrollment_conflict` | vínculo ativo duplicado ou incompatível |

Erros usam SQLSTATE `PGRST` e status HTTP coerente. Funções que persistem a transição para `expired` retornam `expired`, porque lançar erro desfaria a atualização na mesma transação.

## Auditoria

O Ciclo 2 amplia os valores permitidos em `audit_events`. Eventos mínimos:

- cobertura de cidade ou instituição adicionada/removida;
- solicitação criada, cancelada, aprovada ou rejeitada;
- convite da frota criado, aceito, recusado ou cancelado;
- vínculo encerrado;
- campos do aluno alterados;
- responsável secundário adicionado ou removido quando houver frota afetada.

Metadados guardam IDs, estado anterior/novo, origem e nomes dos campos. Nunca guardam e-mail, token, endereço ou coordenadas.

## Testes

Cada comportamento seguirá RED, GREEN e refactor. A suíte pgTAP cobrirá:

- constraints, índices e ausência de dados reais em `schools`;
- busca pública e bloqueio de escrita no catálogo;
- isolamento da cobertura entre frotas;
- criação de menor e adulto, idade e propriedade;
- um único responsável principal;
- convite secundário, e-mail, token, expiração e repetição;
- propagação e remoção segura do papel `guardian`;
- snapshot imutável da solicitação;
- filtros de frota publicada, cidade e instituição;
- aprovação, rejeição, cancelamento e repetição concorrente;
- convite direto, callback autenticado e vínculo automático;
- apenas um vínculo ativo;
- encerramento sem remover papéis não derivados;
- endereço oculto após o fim da finalidade;
- UUID conhecido de outro tenant;
- auditoria sanitizada;
- chamadas anônimas e e-mails não confirmados.

A validação final executará `supabase db reset`, toda a suíte, lint, advisors, inspeção de grants/RLS, `git diff --check` e `software-quality-gate`. A gate não poderá alterar o repositório.

## Referências

- `be-tech-plan.md`, seções 4 a 9 e 11 a 14;
- `CONTRIBUTING.md`, seções 2 a 8 e 10 a 13;
- `deliverables.md`, baseline dos Ciclos 0 e 1;
- `docs/research/2026-09-06-catalogo-escolas-brasil.md`, pesquisa de fontes futuras.
