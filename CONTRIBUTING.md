VanGo - Diretrizes de Desenvolvimento e Boas Práticas
Este documento consolida as regras de engenharia, padrões de projeto, fluxo de testes (TDD) e boas práticas obrigatórias para os repositórios de Front-end (UI - Flutter) e Back-end (BE - Supabase) do projeto VanGo.

1. Princípios Gerais de Código e Engenharia
Clean Code & SOLID: Todo código escrito deve ser legível, autoexplicativo e seguir os princípios SOLID.
KISS & DRY: Evite complexidade desnecessária (Keep It Simple, Stupid) e evite repetição de lógica (Don't Repeat Yourself).
Clean Architecture: Separação estrita de camadas. A UI nunca deve conhecer detalhes do banco de dados ou da rede, e a lógica de negócios deve ser isolada e testável de forma independente.
Conventional Commits: Todos os commits devem seguir a especificação:
feat(escopo): Adição de nova funcionalidade.
fix(escopo): Correção de bug.
test(escopo): Escrita ou refatoração de testes.
refactor(escopo): Alteração de código que não altera o comportamento externo.
docs(escopo): Alterações em documentação.
2. Diretrizes do Repositório UI (Flutter + BLoC + Mapbox)
A. Estrutura e Organização de Pastas (Feature-First)
Cada domínio de negócio (Feature) deve ser auto-contido. A estrutura interna de uma feature segue:

text

feature_name/
 ├── data/                  # Fontes de dados e Modelos
 │    ├── datasources/      # Remote (Supabase API) / Local (Secure Storage)
 │    └── models/           # Classes de dados que estendem as Entidades da Camada Domain
 ├── domain/                # Regras de Negócio Puras (Dart nativo, sem dependências de UI)
 │    ├── entities/         # Objetos de dados do domínio
 │    ├── repositories/     # Interfaces/Contratos de repositório
 │    └── usecases/         # Ações isoladas de negócio (ex: RequestRouteOptimization)
 └── presentation/          # Interface do Usuário e Gerência de Estado
      ├── blocs/            # Classes BLoC ou Cubit (Gerenciamento de Estado)
      ├── pages/            # Telas (Widgets Scaffold)
      └── widgets/          # Componentes visuais reutilizáveis locais da feature
B. Regras de Estado (BLoC/Cubit)
Sem lógica nas Views: Widgets Flutter devem ser burros e declarativos. Eles apenas despacham eventos ou chamam métodos do Cubit e escutam as mudanças de estado para renderizar a tela.
Imutabilidade: Todos os estados do BLoC devem ser imutáveis (usando equatable ou construtores const).
Tratamento de Falhas: Erros devem ser capturados na camada de dados, convertidos em objetos Failure na camada de domínio e propagados à UI na forma de estados de erro.
C. Integração com Mapbox SDK
Gerenciamento de Memória: Mapas consomem muita memória. Sempre chame o método de liberação (dispose) do controlador do mapa nos ciclos de vida do Flutter.
Criptografia de Tokens: O token público do Mapbox deve ser inserido via variáveis de ambiente (--dart-define) em tempo de build, nunca hardcoded no código fonte.
3. Diretrizes do Repositório Backend (Supabase + PostgreSQL)
A. Migrações e Banco de Dados (PostgreSQL)
Sem Alterações Manuais: Nenhuma tabela, trigger ou política de RLS deve ser criada manualmente pelo painel do Supabase em produção. Toda mudança deve ser feita via migrações SQL no repositório Backend (Supabase CLI).
Tipagem estrita: Sempre use chaves estrangeiras (FOREIGN KEY) com ações explícitas de remoção (ON DELETE CASCADE ou ON DELETE SET NULL) para manter a integridade dos dados.
B. Row Level Security (RLS) Obrigatório
Todas as tabelas novas devem ter o RLS ativado via ALTER TABLE ... ENABLE ROW LEVEL SECURITY.
Toda política deve conter testes unitários em banco ou validações manuais rigorosas para impedir acessos cruzados ou vazamento de dados de menores (LGPD).
C. Supabase Edge Functions (Deno / TypeScript)
Única Fonte da Verdade para APIs de Terceiros: Requisições para serviços externos pagos (como o faturamento de rotas da Mapbox) devem obrigatoriamente rodar nas Edge Functions para proteger chaves de API secretas.
Tratamento de Erros Resiliente: As funções devem sempre retornar códigos HTTP correspondentes (ex: 400 Bad Request, 401 Unauthorized, 500 Internal Server Error) com mensagens padronizadas em JSON: { "error": "descrição do erro" }.
4. Testes e TDD (Test-Driven Development)
Adotamos a abordagem TDD para garantir cobertura, qualidade e documentação viva do comportamento do código.

O Ciclo TDD (Red-Green-Refactor)
Red: Escreva um teste de unidade para o comportamento desejado que falhe inicialmente (já que a lógica ainda não existe).
Green: Escreva a quantidade mínima de código de produção necessária para fazer o teste passar.
Refactor: Limpe o código, elimine repetições e melhore a legibilidade mantendo os testes passando.
Mermaid diagram
Tipos de Teste Obrigatórios
UI - Testes Unitários de Casos de Uso (Use Cases): Testar se a lógica do negócio se comporta de maneira correta simulando (mockando) as interfaces dos repositórios.
UI - BLoC/Cubit Tests: Garantir que a emissão de estados ocorre na ordem correta em resposta a eventos ou ações específicas (use o pacote bloc_test).
BE - Testes de Triggers e Functions: Escrever scripts SQL ou testes via API para validar se as triggers automáticas (como criação de perfis) respondem devidamente.
5. Fluxo de Trabalho do Git (Git Flow simplificado)
Branch Principal (main): Reflete o código de produção ativo e estável. Protegida contra Commits Diretos.
Desenvolvimento de Funcionalidades:
Crie uma branch a partir da main: feature/nome-da-feature ou bugfix/nome-do-bug.
Pull Requests (PR):
Para fundir na main, deve ser aberto um PR.
Critérios de Aprovação: Os testes devem passar na esteira CI/CD, e deve haver pelo menos uma aprovação de Code Review.