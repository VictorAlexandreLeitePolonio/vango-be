Projeto VanGo - Plano Técnico e Estrutura do Backend (Node.js + Supabase DB)
Este plano técnico define a arquitetura consolidada de backend do VanGo. Toda a lógica de negócios, o sistema de autenticação (cadastro/login/JWT) e o servidor de WebSockets em tempo real rodam sob o servidor Node.js (TypeScript). O Supabase é utilizado estritamente como banco de dados (PostgreSQL) e armazenamento estático de arquivos (Blob Storage).

1. Arquitetura de Comunicação Simplificada
O aplicativo mobile (Flutter) interage com um único endpoint (o servidor Node.js) para todas as operações, minimizando as dependências client-side e otimizando a latência de comunicação.

Mermaid diagram
2. Modelagem do Banco de Dados (PostgreSQL no Supabase)
Toda a persistência é mantida no banco PostgreSQL do Supabase, gerenciado pela API Node.js.

A. Perfis (public.profiles)
Armazena dados cadastrais e credenciais para autenticação gerenciada pelo Node.js.

id (uuid, PK, DEFAULT gen_random_uuid()).
email (text, UNIQUE, NOT NULL).
password_hash (text, NOT NULL): Senha encriptada via bcrypt no Node.js.
name (text, NOT NULL).
phone (text).
role (text, NOT NULL): CHECK role IN ('gerente', 'motorista', 'responsavel', 'estudante').
created_at (timestamptz, DEFAULT now()).
updated_at (timestamptz, DEFAULT now()).
B. Veículos (public.veiculos)
id (uuid, PK, DEFAULT gen_random_uuid()).
plate (text, UNIQUE, NOT NULL).
model (text, NOT NULL).
capacity (integer, NOT NULL).
owner_id (uuid, FK -> profiles.id ON DELETE CASCADE).
created_at (timestamptz, DEFAULT now()).
C. Turmas (public.turmas)
id (uuid, PK, DEFAULT gen_random_uuid()).
name (text, NOT NULL).
invite_code (text, UNIQUE, NOT NULL).
driver_id (uuid, FK -> profiles.id ON DELETE SET NULL).
vehicle_id (uuid, FK -> veiculos.id ON DELETE SET NULL).
created_at (timestamptz, DEFAULT now()).
D. Estudantes da Turma (public.estudantes_turma)
id (uuid, PK, DEFAULT gen_random_uuid()).
name (text, NOT NULL).
turma_id (uuid, FK -> turmas.id ON DELETE SET NULL).
responsavel_id (uuid, FK -> profiles.id ON DELETE CASCADE).
address_text (text, NOT NULL).
address_lat (double precision, NOT NULL).
address_lng (double precision, NOT NULL).
status_presenca_padrao (boolean, DEFAULT true).
created_at (timestamptz, DEFAULT now()).
E. Rotas (public.rotas)
id (uuid, PK, DEFAULT gen_random_uuid()).
turma_id (uuid, FK -> turmas.id ON DELETE CASCADE).
status (text, NOT NULL, DEFAULT 'agendada'): CHECK status IN ('agendada', 'em_andamento', 'concluida', 'cancelada').
started_at (timestamptz).
ended_at (timestamptz).
optimized_path (jsonb): Dados geográficos ordenados obtidos da Mapbox API.
created_at (timestamptz, DEFAULT now()).
F. Presenças por Rota (public.presencas_rota)
id (uuid, PK, DEFAULT gen_random_uuid()).
rota_id (uuid, FK -> rotas.id ON DELETE CASCADE).
estudante_id (uuid, FK -> estudantes_turma.id ON DELETE CASCADE).
status (text, NOT NULL, DEFAULT 'aguardando'): CHECK status IN ('aguardando', 'embarcado', 'desembarcado', 'ausente').
updated_at (timestamptz, DEFAULT now()).
G. Histórico de Geolocalização (public.historico_geolocalizacao)
id (bigint, PK, GENERATED ALWAYS AS IDENTITY).
rota_id (uuid, FK -> rotas.id ON DELETE CASCADE).
lat (double precision, NOT NULL).
lng (double precision, NOT NULL).
speed (double precision).
created_at (timestamptz, DEFAULT now()).
3. Fluxo de Autenticação e Emissão de Tokens (Node.js)
A camada de autenticação foi movida inteiramente para a API Node.js.

Registro (POST /auth/register):
Recebe nome, email, telefone, senha e tipo de conta (role).
Gera o hash da senha usando bcrypt (10 rounds de salt).
Insere o novo perfil diretamente no PostgreSQL do Supabase.
Login (POST /auth/login):
Consulta o usuário por email no banco.
Compara a senha enviada com a cadastrada usando bcrypt.compare().
Se correto, emite um token JWT contendo { userId: uuid, role: string } assinado pelo segredo local do servidor Node.js.
Middleware (checkAuth):
Intercepta requisições HTTP e descriptografa o JWT usando o segredo local.
Injeta os dados decodificados em req.user.
4. Comunicação em Tempo Real via Socket.io (Node.js WebSockets)
O rastreamento de localização do motorista e o recebimento das coordenadas pelos pais/alunos funcionam através do servidor WebSocket nativo integrado ao Node.js.

A. Handshake e Autenticação
Ao estabelecer a conexão WebSocket, o cliente envia o token JWT emitido pela autenticação:

typescript

import { Server } from 'socket.io';
import jwt from 'jsonwebtoken';
const io = new Server(serverServer);
io.use((socket, next) => {
  const token = socket.handshake.auth.token;
  if (!token) return next(new Error("Autenticação necessária"));
  
  try {
    const decoded = jwt.verify(token, process.env.JWT_SECRET as string);
    socket.data.user = decoded; // Armazena os dados do usuário no socket
    next();
  } catch (err) {
    next(new Error("Token inválido"));
  }
});
B. Ciclo de Vida da Rota e Salas (Rooms)
Entrada na Sala: Ao carregar a tela de mapa da rota, o cliente envia um evento join-route com a rota_id. O servidor valida se o usuário pertence àquela turma no banco e executa:
typescript

socket.join(`route:${rotaId}`);
Streaming de Localização (Motorista): O motorista transmite periodicamente a coordenada GPS gerando o evento send-location:
typescript

socket.on('send-location', (data: { lat: number, lng: number, speed: number }) => {
  // Valida se o usuário conectado é de fato o motorista da rota correspondente
  // Transmite a geolocalização da van para os demais integrantes (pais e alunos) na sala
  socket.to(`route:${rotaId}`).emit('location-update', {
    lat: data.lat,
    lng: data.lng,
    speed: data.speed
  });
});
Gravação no PostgreSQL (Batch de Histórico): A cada 1 minuto de tráfego contínuo na sala, o servidor Node.js faz um insert em lote na tabela historico_geolocalizacao para auditoria histórica.
5. Próximos Passos para o Desenvolvimento
Inicialização do Repositório Node.js: Estruturar o projeto com TypeScript, express (ou fastify), socket.io e pg-pool ou Prisma.
Criação do Banco de Dados: Criar as migrações SQL no banco PostgreSQL do Supabase seguindo os esquemas da Seção 2.
Implementação de Autenticação: Codificar os serviços de hashing, geração de tokens JWT e middlewares.
Desenvolvimento do Servidor WebSocket: Codificar as lógicas de salas do Socket.io para geolocalização.
Cálculo da Rota Mapbox: Criar o serviço que consome a API do Mapbox para retornar a rota otimizada e o ETA.
Notificações Push: Implementar o envio de Push Notifications por meio do Firebase Admin SDK.