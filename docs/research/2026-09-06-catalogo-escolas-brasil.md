# Catálogo de escolas e instituições de ensino superior no Brasil

**Data da pesquisa:** 6 de setembro de 2026
**Escopo:** INEP/e-MEC, Google Places, Mapbox Search e OpenStreetMap (Nominatim/Overpass), usando somente documentação e dados oficiais dos respectivos mantenedores.

## Conclusão

Para o MVP do VanGo, a opção mais segura é uma arquitetura híbrida mínima:

1. **Identidade e dados cadastrais oficiais:** INEP para educação básica e Cadastro e-MEC/Censo da Educação Superior para ensino superior.
2. **Busca:** um índice local, enxuto e atualizado a cada nova publicação oficial. A tabela de domínio `schools` continua sendo preenchida somente quando o usuário seleciona uma instituição; o índice não significa cadastrar todas as escolas no domínio.
3. **Coordenadas:** dados OpenStreetMap consultados por uma instância própria do Nominatim ou por um provedor comercial com termos compatíveis com o VanGo, somente após a seleção. A busca deve tentar primeiro o código INEP quando existir (`ref:INEP`) e, como alternativa, nome mais endereço oficial. O resultado selecionado pode ser persistido com atribuição ao OpenStreetMap.
4. **Fallback:** se não houver correspondência geográfica confiável, a instituição permanece sem coordenada validada e não participa do filtro por distância até revisão administrativa. Não se deve aceitar automaticamente um ponto apenas por semelhança de nome.

Essa separação preserva um identificador oficial e persistente, evita dependência de uma API comercial para dados centrais e mantém a importação de `schools` sob demanda. O custo é um processo periódico simples para reconstruir o índice de busca a partir dos arquivos oficiais.

Se “sob demanda” significar literalmente não manter nem um índice derivado dos arquivos oficiais, a alternativa viável é consultar OSM por uma instância própria ou por um provedor comercial adequado. Ela é menor, mas perde a garantia de cobertura e autoridade do INEP/e-MEC; portanto, não é a recomendação principal. A instância pública `nominatim.openstreetmap.org` não pode ser o caminho de produção do VanGo, pois sua política inclui aplicações de rastreamento de veículos entre os usos que devem operar serviço próprio.

## Comparação resumida

| Fonte | Cobertura de escolas e IES no Brasil | Consulta sob demanda | Endereço e coordenadas | Persistência e licença | Limites e custo | Estabilidade e riscos |
| --- | --- | --- | --- | --- | --- | --- |
| **INEP / e-MEC** | O Censo Escolar cobre escolas públicas e privadas de todas as etapas da educação básica. O Catálogo informa mais de 226 mil escolas. O e-MEC é o cadastro oficial de IES, cursos e locais de oferta. | Há pesquisa pública por nome/código e exportação, mas a pesquisa não encontrou contrato REST público, versionado e documentado para consulta transacional. As interfaces oficiais são painéis, consulta web e downloads periódicos. | O Catálogo de Escolas publica endereço e telefone. O e-MEC publica endereços de funcionamento; o Censo Superior trabalha com locais de oferta. Coordenadas não devem ser consideradas garantidas por um contrato público de API. | O registro do INEP Data no portal Dados.gov informa licença Creative Commons Attribution. Para cada arquivo baixado, deve-se conservar o aviso/licença que acompanha o pacote; o conteúdo web do gov.br tem termos próprios. | Sem cobrança por consulta/download publicada. O custo é interno: baixar, normalizar e indexar arquivos anuais grandes. Não há quota de API aplicável porque não foi identificada uma API de consulta suportada. | É a fonte mais autoritativa, porém anual e potencialmente defasada entre censos. Painéis Power BI ou endpoints internos não devem ser raspados: não são contrato público e podem mudar sem aviso. |
| **Google Places API (New)** | Suporta os tipos `preschool`, `primary_school`, `school`, `secondary_school`, `university` e outros tipos educacionais. A plataforma possui cobertura no Brasil, mas não publica garantia de completude específica para escolas. | Sim: Autocomplete, Text Search, Nearby Search e Place Details por REST. | Retorna nome, endereço formatado/componentes e `location` conforme a máscara de campos. | Inadequada como catálogo persistente: os termos proíbem copiar/salvar nomes e endereços do Google Maps Content; latitude/longitude de Places pode ser armazenada por até 30 dias. Somente o Place ID é expressamente persistível. Conteúdo de Places também não pode ser usado com mapa não Google. | Exige billing e chave. Em 06/09/2026, Text Search Pro inclui 5 mil chamadas mensais sem cobrança e custa US$ 32 por mil no primeiro nível pago; a máscara de campos determina o SKU. | Serviço maduro e incluído nos Core Services, mas cria dependência comercial e jurídica. Place IDs podem mudar e o Google recomenda atualizá-los após 12 meses. Não atende ao contrato persistente de `schools`. |
| **Mapbox Search Box API** | Pesquisa endereços e POIs, mas a documentação atual limita as geografias suportadas a Estados Unidos, Canadá e Europa. **Brasil não é suportado.** | Sim: `/suggest` + `/retrieve`, `/forward`, `/category` e `/reverse`. | Respostas GeoJSON incluem nome, endereço completo e coordenadas. | Todo dado retornado pelo Search Box é somente para uso temporário; armazenamento de posição exige contato comercial. O Geocoding API oferece modalidade permanente, mas não inclui POIs, portanto não resolve um catálogo de escolas. | Limite padrão de 10 req/s. Preço padrão atual: 2.500 sessões/mês gratuitas e, depois, US$ 11,50 por mil até 100 mil sessões. | API documentada, porém eliminada para este caso por falta de suporte geográfico e de persistência padrão. |
| **OpenStreetMap + Nominatim** | O modelo possui tags aprovadas para `amenity=school`, `amenity=college` e `amenity=university`; no Brasil também existe `ref:INEP`. A cobertura é global e comunitária, sem garantia de completude ou atualização uniforme. | Sim para pesquisa textual/estruturada por instância própria ou provedor comercial. A instância pública proíbe autocomplete e não deve atender a produção do VanGo. | Nominatim retorna nome, endereço quando disponível, latitude/longitude, `osm_type` e `osm_id`. | Dados sob ODbL com atribuição. A diretriz oficial permite armazenar resultados individuais de geocodificação com outros dados sem acionar share-alike, desde que a coleção não reconstrua parte substancial/sistemática do OSM. Um provedor comercial pode impor termos adicionais. | Software e dados podem ser auto-hospedados; custo será de infraestrutura/operação. Provedores comerciais têm preço e quota próprios. A instância pública tem limite absoluto de 1 req/s, mas sua política determina serviço próprio para aplicações de rastreamento de veículos. | Boa opção de enriquecimento, não de autoridade cadastral. Produção exige instância própria ou fornecedor com SLA/termos adequados. A instância pública pode servir apenas ao desenvolvimento ou a uma prova manual compatível com a política vigente. |
| **OpenStreetMap + Overpass** | Consulta objetos por tags, inclusive todos os estabelecimentos educacionais mapeados em uma área. | Tecnicamente sim, mas foi feito para consulta/extratos, não para autocomplete nem para servir cada digitação do usuário. | Retorna elementos, tags e geometrias OSM. | Mesma ODbL e atribuição do OSM. Extração sistemática de um catálogo amplo aumenta o risco de a base resultante ser considerada derivada e sujeita a share-alike. | Instâncias públicas são gratuitas e compartilhadas. A principal sugere, para uso regular, menos de 100 consultas e 10 MB/dia; uso comercial deve ser próprio ou pago. | A própria documentação alerta que os servidores públicos podem ficar sobrecarregados e não devem ser tratados como altamente confiáveis. Não usar no caminho crítico do app. |

## Evidências por fonte

### INEP e e-MEC

- O INEP descreve o Censo Escolar como a principal pesquisa estatística da educação básica, com participação de todas as escolas públicas e privadas e cobertura de educação infantil, fundamental, médio, EJA e educação profissional: [Censo Escolar — apresentação](https://www.gov.br/inep/pt-br/areas-de-atuacao/pesquisas-estatisticas-e-indicadores/censo-escolar).
- O Catálogo de Escolas reúne endereço, telefone e oferta educacional de mais de 226 mil escolas, é atualizado anualmente, permite pesquisar por nome/código e exportar dados: [Catálogo de Escolas](https://www.gov.br/inep/pt-br/acesso-a-informacao/dados-abertos/inep-data/catalogo-de-escolas).
- Os arquivos anuais continuam sendo a interface oficial de dados abertos: [Microdados do Censo Escolar](https://www.gov.br/inep/pt-br/acesso-a-informacao/dados-abertos/microdados/censo-escolar) e [Microdados do Censo da Educação Superior](https://www.gov.br/inep/pt-br/acesso-a-informacao/dados-abertos/microdados/censo-da-educacao-superior).
- O MEC define o e-MEC como base oficial e pública das IES e informa pesquisa por nome, sigla ou código, além de endereços de funcionamento e contato: [Cadastro Nacional de Cursos e IES](https://www.gov.br/mec/pt-br/politica-regulacao-supervisao-educacao-superior/cadastro-nacional-de-cursos-e-ies).
- O INEP informa que o Censo Superior utiliza o e-MEC, onde ficam os registros de todas as instituições, cursos e locais de oferta: [Censo da Educação Superior — apresentação](https://www.gov.br/inep/pt-br/areas-de-atuacao/pesquisas-estatisticas-e-indicadores/censo-da-educacao-superior).
- Para transporte, o identificador correto de uma IES deve representar o **local de oferta/campus**, não apenas a sede. O manual oficial informa que cada local possui código, nome, endereço e tipo: [Manual do módulo IES 2024](https://download.inep.gov.br/pesquisas_estatisticas_indicadores_educacionais/censo_da_educacao_superior/orientacoes/manuais/modulo_instituicao_de_educacao_superior_ies_2024.pdf).
- O catálogo oficial Dados.gov classifica o conjunto INEP Data como Creative Commons Attribution: [INEP Data no Portal Brasileiro de Dados Abertos](https://dados.gov.br/dados/conjuntos-dados/inep-data---conjunto-de-painis-de-bi---business-intelligence---do-inep).

**Limitação encontrada:** não foi localizada documentação oficial de uma API REST de escolas/IES destinada a integrações de produção. O fato de o catálogo aparecer como “api” no Dados.gov não fornece endpoints de busca, esquema, autenticação, SLA ou política de versão. Consumir chamadas internas do painel ou raspar o e-MEC criaria uma integração sem contrato.

### Google Places

- A API oferece Autocomplete, Place Details, Nearby Search e Text Search: [Places API (New)](https://developers.google.com/maps/documentation/places/web-service/reference/rest).
- Os tipos oficiais incluem `preschool`, `primary_school`, `school`, `secondary_school` e `university`: [Place Types (New)](https://developers.google.com/maps/documentation/places/web-service/place-types).
- Text Search pode retornar `displayName`, `formattedAddress`, `addressComponents` e `location`, com cobrança definida pela máscara: [Text Search (New)](https://developers.google.com/maps/documentation/places/web-service/text-search) e [Place Data Fields](https://developers.google.com/maps/documentation/places/web-service/data-fields).
- A tabela atual de preços mostra 5 mil chamadas mensais gratuitas para Text Search Pro e US$ 32/1.000 no primeiro nível pago: [Google Maps Platform pricing](https://developers.google.com/maps/billing-and-pricing/pricing).
- Os termos proíbem indexar/copiar/salvar conteúdo, incluindo nomes e endereços; os termos específicos limitam o cache de latitude/longitude de Places a 30 dias: [Google Maps Platform Terms](https://cloud.google.com/maps-platform/terms) e [Service Specific Terms](https://cloud.google.com/maps-platform/terms/maps-service-terms).
- Place IDs são exceção à restrição de cache e podem ser persistidos, mas podem mudar; recomenda-se atualizá-los quando tiverem mais de 12 meses: [Place IDs](https://developers.google.com/maps/documentation/places/web-service/place-id).

### Mapbox

- Search Box pesquisa endereços e POIs, retorna GeoJSON com nome, endereço e coordenadas, limita o uso a 10 req/s e determina que todos os resultados são temporários. A mesma página informa suporte apenas a Estados Unidos, Canadá e Europa: [Search Box API](https://docs.mapbox.com/api/search/search-box/).
- A comparação oficial informa que Search Box inclui POIs, mas não permite armazenamento permanente; Geocoding permite armazenamento permanente, mas não inclui POIs: [Search products overview](https://docs.mapbox.com/help/getting-started/search/).
- Preços padrão atuais: 2.500 sessões gratuitas por mês e US$ 11,50/1.000 no primeiro nível pago: [Mapbox pricing — Search](https://www.mapbox.com/pricing#search).

### OpenStreetMap, Nominatim e Overpass

- Nominatim aceita busca livre ou estruturada, filtro por país e retorna resultados com endereço e coordenadas: [Nominatim Search API](https://nominatim.org/release-docs/latest/api/Search/) e [output formats](https://nominatim.org/release-docs/latest/api/Output/).
- O OSM possui tags próprias para [escolas](https://wiki.openstreetmap.org/wiki/Tag%3Aamenity%3Dschool), [universidades](https://wiki.openstreetmap.org/wiki/Tag%3Aamenity%3Duniversity) e para o [código INEP no Brasil](https://wiki.openstreetmap.org/wiki/Key%3Aref%3AINEP).
- A política da instância pública fixa 1 req/s, exige identificação, cache e atribuição e proíbe autocomplete. Em “Unacceptable Use”, determina que aplicações de rastreamento de pacotes/veículos operem serviço próprio. Portanto, `nominatim.openstreetmap.org` não é uma dependência permitida para a produção do VanGo; no máximo pode apoiar desenvolvimento ou prova manual quando o uso concreto estiver de acordo com a política vigente: [Nominatim Usage Policy](https://operations.osmfoundation.org/policies/nominatim/).
- A diretriz oficial de geocodificação considera resultados individuais extrações não substanciais, que podem ser armazenadas com dados de terceiros, desde que não reconstruam sistematicamente uma parte substancial do OSM; a atribuição continua obrigatória: [OSMF Geocoding Guideline](https://osmfoundation.org/wiki/Licence/Community_Guidelines/Geocoding_-_Guideline) e [Attribution Guidelines](https://osmfoundation.org/wiki/Licence/Attribution_Guidelines).
- A documentação do Overpass alerta que instâncias públicas são voltadas a projetos pequenos, podem ficar sobrecarregadas e recomenda infraestrutura própria/paga para uso comercial: [Overpass API — public instances](https://wiki.openstreetmap.org/wiki/Overpass_API#Public_Overpass_API_instances).

## Contrato mínimo sugerido para o Ciclo 2

No catálogo persistido, usar:

- educação básica: `provider = 'inep'` e `external_id = código INEP`;
- ensino superior: `provider = 'emec'` e `external_id = código do local de oferta`, mantendo também o código da IES nos metadados;
- `source_updated_at` correspondente ao ano/data da publicação oficial;
- `geocoder_provider = 'osm'`, `geocoder_external_id = osm_type + osm_id` e data da geocodificação quando houver correspondência;
- nome, tipo e endereço vindos da fonte oficial; latitude e longitude vindas do geocodificador, sem substituir silenciosamente os campos oficiais;
- restrição única em `(provider, external_id)`.

Em produção, a chamada deve partir do backend para uma instância própria do Nominatim ou provedor comercial com licença, persistência, quota e SLA compatíveis. Ela ocorre apenas após busca submetida/seleção e usa `countrycodes=br`, cache e identificação exigida pelo operador. O endpoint deve ser configurável por ambiente. `nominatim.openstreetmap.org` fica fora do caminho de produção e, se usado em desenvolvimento/prova manual, continua sujeito a User-Agent identificável, cache, proibição de autocomplete e limite global de 1 req/s.

## Decisões que esta pesquisa evita

- Não usar Google Places como banco permanente de escolas; guardar apenas Place ID não satisfaz o modelo do VanGo, que precisa de nome, endereço e coordenadas persistentes.
- Não usar Mapbox Search Box no Brasil enquanto a documentação não incluir o país e não houver direito de persistência contratado.
- Não consultar Overpass a cada busca do usuário.
- Não acoplar o backend a endpoints internos de Power BI/e-MEC sem documentação pública.
- Não importar todas as instituições para `schools`; somente o índice de origem é periódico, e o registro de domínio nasce na seleção.

## Validação pendente antes da implementação

Ao iniciar o código do Ciclo 2, baixar os pacotes oficiais vigentes e confirmar no dicionário que os campos necessários continuam publicados, especialmente endereço completo e código do local de oferta. Também registrar os avisos de licença incluídos nos próprios pacotes. Se o arquivo de educação superior não expuser o endereço do campus, o MVP deve usar a identidade oficial do e-MEC e tratar a coordenada/endereço operacional obtidos do OSM como dados de origem separada, sem raspar a consulta web.
