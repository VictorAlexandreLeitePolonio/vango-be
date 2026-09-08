# Ciclo 6 — Mapa, rastreamento e roteirização

**Data:** 7 de setembro de 2026
**Status:** aprovada em 2026-09-07; integração de mapas em espera por decisão do usuário
**Implementation plan:** [Ciclo 6](../plans/2026-09-07-ciclo-6-mapa-rastreamento-roteirizacao.md)
**Base:** Ciclos 3–5 validados; Flutter iOS/Android.

## Objetivo e fronteira em espera

Entregar localização autorizada, sincronização offline, projeções de mapa por papel, retenção, revisão de percurso e integração dos alertas de proximidade. Geocodificação, otimização e ETA dependem de um provedor que ainda não foi escolhido.

O orçamento, escala e provedor de mapas/rotas estão em stand-by. Não pesquisar planos comerciais para fixar escolha, contratar serviços ou criar um adaptador fictício marcado como integração concluída. O implementation plan separará as tarefas independentes da seleção e as tarefas bloqueadas pela escolha.

O modo manual é contingência. GPS e operação manual podem ser entregues separadamente, mas não encerram o Ciclo 6 completo nem comprovam roteirização automática em produção.

## Arquitetura e modelo propostos

| Recurso | Responsabilidade |
| --- | --- |
| `trip_location_points` | amostras com frota/viagem, posição, precisão, sequência, captura e recebimento; retenção de 30 dias |
| posição atual por viagem | última amostra válida; nunca regredir ao receber lote antigo |
| época de broadcast em `trips` | versão de autorização usada no tópico privado |
| histórico de atribuições do Ciclo 4 | validar autor e período de uma captura offline |
| revisões de percurso | hash/revisão das entradas, estado manual/calculado/desatualizado e versão usada por viagem |
| resultados de cálculo | apenas dados permitidos pelo provedor selecionado; escrita condicionada à revisão atual |

Reutilizar `trip_stops`, `trip_events`, `trip_assignments` e infraestrutura de entrega do Ciclo 5. Endereço completo não integra broadcasts, logs ou chaves de deduplicação.

## Ingestão de GPS

Motorista envia posição ao backend por comando autenticado; o backend verifica a atribuição atual e `trip.active` antes de publicar. Não conceder ao aplicativo permissão para escrever broadcasts arbitrários diretamente. Isso permite rejeitar um motorista substituído sem depender do cache de autorização de uma conexão aberta.

Validar coordenadas, precisão, tipo, tamanho do lote, sequência, timestamps e limite de frequência. GPS é informação declarada pelo dispositivo; o backend não pode garantir sua veracidade física. Rejeitar captura impossível ou fora do intervalo permitido e registrar erro sem expor dados pessoais.

Proposta técnica inicial para revisão: envio a cada 5 segundos em movimento, 15 segundos parado; persistência regular a cada 30 segundos e nos eventos operacionais; sinal desatualizado após 30 segundos sem posição válida. São parâmetros técnicos ajustáveis, não garantias de cobertura de rede nem cadência imposta por `setInterval` no servidor. Calibrar em teste real antes de produção.

Uma posição recebida fora de ordem não substitui a atual. Amostras com baixa qualidade podem ser descartadas do cálculo de ETA sem inventar posição. A interface recebe horário da última amostra e estado de atualização.

## Canais privados e revogação

Dono acompanha a frota; motorista acessa a viagem atribuída. Responsável/adulto acompanha viagem com seu aluno confirmado enquanto ele não estiver desembarcado ou ausente. Outro dependente elegível conserva o acesso do mesmo responsável. Histórico autorizado permanece após o fim do acesso ao vivo.

A documentação do Supabase descreve autorização calculada na entrada do canal; portanto não basta alterar uma policy esperando que uma conexão já aberta perca acesso imediatamente. Proposta de implementação: tópico `trip:{trip_id}:v{epoch}`, com a época atual validada pela policy. Publicações usam somente a época vigente.

Ao desembarcar, marcar ausência, substituir motorista, retirar responsável ou mudar outra relação que revogue acesso, avançar a época na mesma transação. Consultas autenticadas devolvem a nova época apenas a quem ainda tem acesso. O tópico antigo deixa de receber novas posições. Usuários revogados não conseguem ingressar na nova época, mesmo conhecendo seu nome. Revalidar também ingestão por comando, sem confiar no JWT para papéis de domínio.

Publicação e revogação usam serialização compatível por viagem. Um worker atrasado não pode publicar posição nova no tópico antigo. Mensagens já enviadas antes da revogação não podem ser recolhidas; o critério de aceite é não publicar novas posições para a audiência revogada depois da transação.

As policies podem ser criadas em `realtime.messages`; não criar tabelas/funções auxiliares nem alterar estruturas no schema `realtime`. Helpers pertencem a `private`, conforme o padrão do repo e a restrição atual do Supabase.

## Projeções de mapa

- Dono e motorista atribuído: sequência operacional completa e pontos necessários à viagem.
- Responsável/adulto: posição da van, escola, ETA e ponto do próprio aluno; somente representação aproximada que não exponha residências de terceiros.
- Anônimo/marketplace: nenhuma posição ao vivo, endereço residencial ou geometria operacional.

Proposta mínima de privacidade: retornar pontos próprios e posição da van sem polyline operacional completa. Não tentar anonimizar uma geometria residencial detalhada removendo apenas os marcadores. O mapa-base/SDK Flutter não faz parte da implementação deste repo e também depende da escolha de mapas em espera.

Histórico de GPS bruto não é um atalho para continuar acompanhando depois do desembarque: responsáveis recebem apenas o histórico de eventos do próprio aluno, não a série de posições restante da van.

## Offline e retomada

Flutter armazena temporariamente GPS e embarque/desembarque quando sem rede. Backend aceita lotes autenticados com ID de evento, viagem, versão de atribuição, sequência e horários declarado/recebido. O armazenamento local do aplicativo é dependência documentada, não código backend.

Validar autor contra o histórico de atribuições, não apenas contra motorista atual. Preservar permissão atual de autenticação e rejeitar comandos incompatíveis com suspensão/saída; dados não confiáveis não ganham privilégio por declarar captura anterior. Repetir um ID com payload diferente é conflito.

GPS histórico pode completar resumos e trilha dentro da retenção sem alterar posição atual, reabrir viagem ou reativar mapa. Eventos de presença seguem sequência causal do passageiro; processar embarque antes do desembarque. Evento incompatível com correção posterior não sobrescreve estado: retornar conflito para resolução auditada.

Início, substituição e encerramento exigem conexão. Antes de encerrar, o cliente sincroniza a presença pendente; o backend ainda bloqueia encerramento enquanto houver embarcado ou lista não resolvida. Uma troca pode receber dados atrasados do período anterior, mas nunca comandos atuais do antigo motorista.

## Percurso e vigência

Uma revisão de cálculo inclui passageiros, endereços, escola e sua ordem, origem/destino, agenda e configuração relevante. Mudanças nessas entradas invalidam o resultado mesmo com lista de passageiros igual.

Fluxo:

1. Preparar rota-base quando entradas mudarem.
2. Gerar viagens sem chamar provedor.
3. No fechamento das confirmações, calcular apenas se a revisão aplicável diferir do cálculo válido.
4. Antes do início, incorporar mudanças cadastrais à próxima viagem não iniciada; não usar endereço antigo por falha de cálculo.
5. Iniciada a viagem, preservar percurso/snapshots frente a edições cadastrais. Desvio ou incidente autorizado usa um evento operacional próprio.
6. Gravar resposta de cálculo apenas se a revisão ainda for atual; resposta atrasada nunca sobrescreve endereço novo.

Ordem das escolas é do dono; otimizar residências sem alterar essa ordem. Até cerca de 30 alunos mais partida, destino e escolas. Não presumir que dividir chamadas resolve sozinho um problema de otimização global: a seleção futura precisa demonstrar um algoritmo viável e seus limites.

Com pontos válidos, falha externa permite ordem manual definida pelo dono, sem ETA/otimização fictícios. Se o endereço não foi localizado, o dono define o ponto correto antes de iniciar a próxima execução afetada. Não alterar a execução já ativa para corrigir cadastro.

## Integração externa: condição para retomar

Antes de implementar o adaptador de mapas, registrar decisão com provedor, limites de pontos/matriz, cobertura brasileira, geocodificação, trânsito/ETA, otimização com ordem das escolas, quotas/custo e termos de armazenamento/atribuição. Nenhum desses itens fica implicitamente aprovado pela existência desta spec.

Depois da escolha, testar transformação de respostas, timeout, repetição, quota, resultados inválidos, divisão de trechos quando aplicável e revisão obsoleta. Só então habilitar chamadas reais e validar a rota com volume representativo de 30 alunos.

O contrato normalizado contém entradas de pontos/janelas/revisão e saída de ordem, trechos, distâncias, durações e fonte/validade do ETA. Não criar uma hierarquia de fornecedores para múltiplas implementações hipotéticas.

## Alertas e retenção

Integrar proximidade pelo ETA, padrão de 10 minutos configurável por rota, com chave por viagem/aluno/evento. Sem ETA válido não fabricar alerta de proximidade. Chegada ao ponto e à escola devem ter fonte operacional explícita; a cadência de GPS sozinha não prova embarque.

Revalidar estado e participação antes de enfileirar e antes de enviar; não notificar proximidade depois de ausência/desembarque. Sincronização histórica não dispara um aviso de proximidade atual. Fatos de embarque/desembarque podem aparecer com seu horário original.

Expirar GPS bruto após 30 dias; relógio/recebimento não estende indevidamente a retenção de uma captura antiga. Preservar resumos, distância/duração quando verificáveis, ocorrências e eventos conforme política existente. Testar retenção de forma invocável com relógio de teste, sem apagar auditoria nem snapshots por engano.

## Testes e aceite

- Ingestão atual versus histórica, precisão, limites, repetição e ordem.
- Duas sessões Realtime: manter conexão antiga aberta após desembarque/ausência/substituição/remoção e comprovar ausência de novas posições nela.
- Usuário com outro dependente, conexão com UUID conhecido e policy de época antiga.
- Consultas e broadcasts sem casas de terceiros nem polyline privada.
- Lotes offline duplicados, fora de ordem, atribuição antiga válida e evento conflitante.
- Mudança de endereço concorrente ao cálculo/início, resposta externa obsoleta e modo manual.
- Fake externo para erro, quota e tempo esgotado; provedor real somente após escolha.
- Retenção de 30 dias e alertas tardios descartados.
- Fluxo representativo iOS/Android com perda de conexão, substituição e revogação.

## Local → produção e estados de entrega

Homologar localmente com banco, Edge Functions e dois clientes Realtime. Comprovar autorização em conexão aberta, não somente testar SQL. Testes comuns usam fakes; live routing permanece bloqueado pela escolha do provedor.

Publicar migrations, funções e jobs após validação local e inspeção do destino, sem staging remoto e sem seed/reset remoto. Configurar acesso exclusivamente privado, credenciais e limites operacionais. Verificar ingestão, revogação, retenção e alertas num fluxo controlado no ambiente publicado.

Registrar separadamente: rastreamento validado localmente; rastreamento publicado/verificado; integração externa em espera; integração externa publicada/verificada. Somente a última conclusão, junto às demais verificações, permite marcar todo o Ciclo 6 como concluído.

## Referências verificadas em 2026-09-07

- [Realtime Authorization](https://supabase.com/docs/guides/realtime/authorization).
- [Broadcast](https://supabase.com/docs/guides/realtime/broadcast).
- [Restrição do schema Realtime](https://supabase.com/changelog/realtime-schema-locked-down-against-modification).
- `be-tech-plan.md`, seções 6.8–6.10; specs dos Ciclos 3–5.
