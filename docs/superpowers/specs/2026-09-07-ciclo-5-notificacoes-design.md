# Ciclo 5 — Notificações

**Data:** 7 de setembro de 2026
**Status:** aprovada em 2026-09-07; não implementada
**Implementation plan:** [Ciclo 5](../plans/2026-09-07-ciclo-5-notificacoes.md)
**Base:** eventos e contratos operacionais do Ciclo 4.
**Provedor aprovado:** Firebase Cloud Messaging, Flutter iOS e Android.

## Objetivo e corte

Entregar caixa de avisos por destinatário e push FCM, mantendo a operação do transporte independente da disponibilidade do provedor. Inclui mensagens automáticas, mensagens manuais unidirecionais, estado de leitura, tentativas, validade e desativação de tokens inválidos.

Não inclui chat, respostas, SMS, e-mail transacional, campanhas de marketing, automação de mapas ou código Flutter. E-mail de autenticação pertence à configuração do Supabase Auth para produção. Alertas de proximidade serão conectados no Ciclo 6, quando houver GPS e ETA reais.

## Arquitetura e trade-offs

Gravar o evento de domínio na mesma transação da operação. Um processamento idempotente cria os avisos/destinatários; uma Edge Function envia mensagens via FCM HTTP v1. Credenciais administrativas e OAuth permanecem server-side.

Reutilizar `trip_events` quando ele for a origem. A caixa de saída da notificação é durável no PostgreSQL; não chamar o FCM dentro da transação de embarque. Para eventos não operacionais, como decisão de pedido, a mudança e a criação do aviso pendente também são atômicas.

Não introduzir broker externo. Workers concorrentes reivindicam entregas com lock e concessão temporária, recuperando trabalho abandonado sem reservar a linha indefinidamente.

A caixa de avisos evita perder acesso ao conteúdo quando o push falha. Isso não prova leitura. `sent` significa aceite pelo provedor, não exibição no dispositivo nem leitura pelo usuário.

## Modelo proposto

| Entidade | Responsabilidade |
| --- | --- |
| `device_tokens` | usuário, instalação, plataforma `ios`/`android`, token FCM, estado e datas |
| `notifications` | frota, categoria, conteúdo privado, origem, chave de evento e validade |
| `notification_recipients` | notificação/usuário, disponibilidade e `read_at`; uma linha por destinatário |
| `notification_deliveries` | aviso/dispositivo, estado, próxima tentativa, concessão de processamento e resposta sanitizada |

Uma notificação é compartilhável entre destinatários, mas leitura pertence ao usuário. Tokens nunca são expostos ao dono, motorista ou outros usuários. Um token ativo não fica associado simultaneamente a contas diferentes; rotação/logout precisa revogar ou transferir a instalação com autorização verificável, sem duplicar destinatários.

Unicidades de evento, destinatário e entrega impedem duplicações internas. O payload FCM inclui `notification_id` estável para deduplicação no aplicativo. Timeout depois de aceite pelo FCM pode causar entrega repetida; não prometer exactly-once do provedor. O plano deve testar reprocessamento e documentar essa limitação do push.

## Destinatários e conteúdo

Resolver destinatários pelo vínculo, participação e papel do domínio, nunca por uma lista arbitrária enviada pelo cliente. Consultar novamente autorização quando materializar/enviar conteúdo sensível. Suspensão ou remoção de relação não pode manter acesso por ter sido destinatário em outro momento.

Pais/responsáveis e adultos recebem avisos dos próprios alunos. Se um responsável tem dois dependentes no mesmo evento, deduplicar por notificação/usuário sem perder a referência correta ao conteúdo autorizado. Dono recebe avisos administrativos da sua frota.

Push usa título/corpo discreto, sem endereço, nome do menor ou detalhe sensível. O aplicativo abre a caixa e obtém o conteúdo autorizado com sessão. Campos de deep link são IDs/rotas reconhecidos pelo aplicativo, não URLs executáveis arbitrárias.

## Eventos e validade

| Categoria | Origem e validade operacional |
| --- | --- |
| confirmação disponível | viagem aberta; não enviar como chamada à ação após fechar prazo |
| prazo próximo | somente quem ainda está pendente; expira no prazo |
| viagem iniciada | participantes autorizados; envio oportuno, não reapresentar após encerramento |
| embarque/desembarque | fato histórico, com horário real; deduplicado por evento |
| chegada à escola | parada/escola e alunos relacionados, sem revelar outros passageiros |
| cancelamento/ocorrência | público afetado pelo evento; preservar aviso histórico |
| aprovação/recusa/alteração | solicitante e responsáveis autorizados afetados |
| endereço/escola atualizados | dono e motorista da próxima execução afetada; preservar a viagem ativa |
| mensagem manual | público permitido e contexto registrado |
| proximidade/chegada ao ponto | Ciclo 6; validade vinculada ao ETA, presença e estado ativo |

Proposta técnica inicial de envio: avisos factuais/manuais admitem tentativas por até 24 horas; eventos com prazo operacional expiram no primeiro limite de domínio, mesmo antes dessas 24 horas. Validade do push não apaga o histórico da caixa. O aviso informa o horário do fato para não apresentar um embarque sincronizado como se estivesse ocorrendo agora.

Alertas de proximidade e chegada não podem ser enviados depois de desembarque/ausência. Revalidar utilidade antes de cada envio, não só na criação. Avisos produzidos antes da implantação do Ciclo 5 não geram um disparo retroativo indiscriminado; o cursor de ativação deve ser explícito.

## Mensagens manuais

Dono pode enviar para frota, rota, viagem, van ou usuário autorizado da frota. Resolver o público no servidor e registrar o escopo e autor. Motorista usa categorias predefinidas e observação, somente em sua viagem; não envia para toda a frota por conhecer o ID.

Não criar canal de respostas nem inferir resposta a partir de leitura. Validar tamanho, categoria, contexto e limite de envio para evitar repetição acidental ou abuso. Limites técnicos e códigos serão fixados no implementation plan, sem inventar planos comerciais.

## Envio FCM e falhas

Edge Function autentica a chamada interna e solicita lote limitado ao banco. Renovar credencial OAuth somente quando necessário; nunca gravar chave privada ou bearer em logs. Usar API HTTP v1, não API legada de server key.

Erros temporários recebem backoff com jitter e respeito a `Retry-After`; erros permanentes de token desativam o token. Uma resposta inválida não conta como sucesso. Concessão expirada permite reprocessar uma tentativa interrompida; limite de validade encerra tentativas inúteis.

Uma falha de FCM não altera o estado da viagem. Expor falhas finais e tamanho/idade da fila ao operador, sem incluir conteúdo privado em métricas. Não eliminar a caixa de entrada ao desativar um dispositivo.

## Contratos a entregar

- registrar/rotacionar/revogar token da própria instalação;
- listar avisos próprios com paginação e marcar leitura idempotente;
- enviar mensagem manual por escopo autorizado;
- materializar evento em destinatários (interno);
- reivindicar/concluir/reagendar entrega (interno);
- Edge Function de envio FCM HTTP v1;
- job de envio e recuperação de entregas abandonadas.

Erros incluem `invalid_input`, `forbidden`, `not_found`, `invalid_audience`, `rate_limited` e conflitos de idempotência. Funções internas não são executáveis por `anon`/`authenticated`.

## Flutter iOS/Android: contrato de integração

FCM requer configuração do aplicativo Firebase para cada plataforma. iOS precisa das capacidades de push e credenciais APNs no Firebase; o fluxo deve tratar permissão negada e token ainda indisponível. Android precisa tratar permissão e disponibilidade do serviço conforme a plataforma.

Flutter registra refresh de token, revoga a instalação no logout e consulta conteúdo protegido ao abrir o aviso. Esses passos são dependências de integração, não arquivos implementados no backend. Nunca usar token FCM como autenticação Supabase.

## Testes e critérios de aceite

- RED/GREEN para RLS, destinatários, token próprio e leitura idempotente.
- Dois tenants; motorista tentando enviar fora da viagem; responsável sem relação com o aluno.
- Reprocessar evento não duplica caixa, destinatários ou entregas.
- Workers concorrentes, concessão expirada, timeout ambíguo e retomada.
- Fake FCM para sucesso, erro permanente, 429/5xx, resposta inválida e timeout; testes comuns sem serviços pagos.
- Prazo fechado, ausência e desembarque suprimem avisos obsoletos.
- Token inválido deixa caixa disponível; falha no push não reverte embarque.
- Logs e payload de tela bloqueada sem PII ou secrets.
- Verificação controlada de recebimento em iOS e Android antes de declarar integração publicada validada.

## Local → produção

Usar local como homologação. Testar Edge Functions com fakes e, com credenciais de teste disponíveis, um envio controlado para dispositivos de teste iOS/Android. Não cadastrar usuários reais como fixtures.

Pré-publicação: inspecionar o projeto Supabase/Firebase alvo, configurar segredos de FCM e APNs por canais seguros, verificar migrations e preparar recuperação. Aplicar migrations, implantar função e habilitar job após conferir os contratos. Registrar cursor de ativação e impedir disparos históricos em massa.

Após publicação, verificar entrega e abertura autenticada em ambas as plataformas, além de tentativa falha controlada e recuperação. Falta de credencial ou dispositivo necessário é uma pendência verificável; não declarar push end-to-end concluído apenas com teste fake.

Reset remoto, seed fictício em produção e staging remoto estão fora do fluxo aprovado.

## Referências verificadas em 2026-09-07

- [FCM para Flutter](https://firebase.google.com/docs/cloud-messaging/flutter/get-started).
- [Envio HTTP v1](https://firebase.google.com/docs/cloud-messaging/send/v1-api).
- `be-tech-plan.md`, seção 6.10; spec do Ciclo 4.
