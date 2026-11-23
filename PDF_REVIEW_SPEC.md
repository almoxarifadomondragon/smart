# ESPECIFICAÇÃO TÉCNICA PARA CODEX
## MONDRAGON — ALMOXARIFADO SMART
### Correção e melhoria da interface de conferência de pedidos PDF

**Repositório:** https://github.com/almoxarifadomondragon/smart

**Módulo:** Pedidos PDF — Importação em Massa

**Tipo de solicitação:** Correção de interface, usabilidade e responsividade

**Prioridade:** Alta

**Escopo:** Frontend e ajustes estritamente necessários para o funcionamento seguro da interface.

---

# 1. OBJETIVO

Realizar uma revisão completa da interface de conferência dos pedidos PDF importados no Almoxarifado SMART Mondragon.

A funcionalidade de importação já está implementada e, nos testes com 13 PDFs reais, apresentou:

| Indicador | Resultado |
|---|---:|
| PDFs processados | 13 |
| Pedidos identificados | 13 |
| Linhas identificadas | 521 |
| Peças solicitadas | 1.888 |
| Projetos | 2 |
| Estações | 8 |
| Separações previstas | 8 |
| Pendências | 0 |

Os resultados indicam que a extração e o agrupamento estão produzindo dados coerentes com os documentos utilizados.

**Não modificar o motor de leitura dos PDFs.**

O objetivo desta solicitação é exclusivamente melhorar a apresentação, a organização e a experiência de conferência dos dados extraídos, evitando alterações acidentais e permitindo ao operador trabalhar com centenas de linhas de forma rápida e segura.

# 2. ANÁLISE OBRIGATÓRIA ANTES DAS ALTERAÇÕES

Inspecionar o repositório e identificar:

- Componentes responsáveis pela tela Pedidos PDF.
- Componentes da tabela de conferência.
- Estilos CSS aplicados.
- Regras atuais de responsividade.
- Estados utilizados para seleção e edição dos itens.
- Funcionalidade de pesquisa, ordenação e filtros.
- Controle de paginação.
- Regras de quantidade a importar.
- Funcionamento do botão Excluir da prévia.
- Abertura do PDF original.
- Funcionamento do botão Confirmar e gerar separações.
- Fluxo de confirmação e integração com o backend.

Não reescrever desnecessariamente componentes existentes.

Priorizar correções isoladas e reutilização da arquitetura atual.

# 3. PROBLEMAS IDENTIFICADOS

As capturas de tela mostram diversos problemas.

## 3.1. Sobreposição de informações

O botão **Excluir da prévia** aparece sobre:

- Número do pedido.
- Número sequencial.
- Referência L.

Também existe sobreposição entre o código BPZ e o campo de descrição.

Esses problemas comprometem a leitura e podem provocar erros na conferência.

## 3.2. Excesso de rolagem

A tabela apresenta rolagens horizontal e vertical simultâneas.

Isso obriga o usuário a movimentar a tabela continuamente para visualizar informações da mesma peça.

## 3.3. Campos desproporcionais

Existem campos de edição com larguras inadequadas.

Alguns possuem espaço insuficiente para os valores, enquanto outros ocupam espaço excessivo.

## 3.4. Coluna Origem desorganizada

O botão de visualização do PDF está sobreposto às informações de:

- Arquivo original.
- Número do desenho.
- Revisão.
- Prazo de entrega.

## 3.5. Excesso de campos editáveis

Projeto, estação e descrição aparecem como campos de entrada em todas as linhas.

Isso aumenta a poluição visual e o risco de modificações acidentais.

## 3.6. Confirmação pouco estruturada

O botão Confirmar e gerar separações aparece diretamente na tabela, sem uma etapa visual específica para revisão do agrupamento final.

O usuário deve conseguir conferir exatamente quais separações serão criadas antes de confirmar.

# 4. NOVA ORGANIZAÇÃO DA INTERFACE

Dividir o processo visual em três etapas.

## ETAPA 1 — ARQUIVOS IMPORTADOS

Manter o upload existente.

Após o processamento, apresentar um resumo compacto.

Exemplo:

**Arquivos importados (13)**

**Pedidos identificados: 13**

**Linhas reconhecidas: 521**

O detalhamento dos arquivos deverá ficar em um painel expansível.

Ao clicar em Arquivos importados, mostrar:

- Nome do PDF.
- Número do pedido.
- Quantidade de linhas.
- Quantidade de páginas.
- Situação de processamento.
- Ação para visualizar o arquivo.

Após processamento bem-sucedido, deixar a lista de arquivos recolhida por padrão.

Isso permitirá aproveitar melhor o espaço vertical.

## ETAPA 2 — CONFERÊNCIA DOS ITENS

Esta será a principal área de trabalho.

A tabela deverá ser redesenhada de forma compacta, legível e organizada.

## ETAPA 3 — RESUMO E CONFIRMAÇÃO

Após finalizar a conferência, o operador deverá acessar uma tela ou painel de resumo antes de gerar as separações.

Não executar a criação de separações ao clicar simplesmente em Avançar.

A confirmação definitiva deverá acontecer somente na etapa final.

# 5. NOVA TABELA DE CONFERÊNCIA

Substituir o layout atual por uma tabela com sete colunas principais:

| Coluna | Conteúdo |
|---|---|
| Selecionar | Checkbox |
| Pedido / Linha | Pedido, sequencial e L |
| Código / Descrição | Código BPZ e descrição da peça |
| Destino | Projeto e estação |
| Solicitada / Saldo | Quantidades de referência |
| Importar | Quantidade editável |
| Ações | Editar, visualizar PDF e excluir |

## 5.1. Coluna Selecionar

Exibir checkbox centralizado.

Permitir seleção e desmarcação individual.

Manter estado de seleção ao navegar entre páginas.

O checkbox não poderá ser afetado pela alteração dos filtros, exceto quando o usuário executar explicitamente uma seleção em massa.

## 5.2. Coluna Pedido / Linha

Exibir:

**VH21338**

Seq. 1 · L:1

A primeira linha deverá ter destaque visual.

A segunda deverá utilizar fonte menor e cor secundária.

Não utilizar campos de entrada nessa coluna.

Não posicionar botões sobre o conteúdo.

## 5.3. Coluna Código / Descrição

Exibir:

**BPZ0043578**

TAMPO DO ALIMENTADOR

O código BPZ deve ficar em negrito.

A descrição deverá aparecer abaixo, com quebra automática de linha.

Evitar truncamentos que escondam permanentemente informações relevantes.

Se necessário, utilizar tooltip para descrições muito longas.

## 5.4. Coluna Destino

Exibir:

**Projeto 26005**

Estação 31050

Não utilizar campos de entrada diretamente na tabela para esses dados.

Disponibilizar edição no painel de detalhes do item.

## 5.5. Coluna Solicitada / Saldo

Exibir as quantidades de forma compacta.

Exemplo:

Solicitada: 32

Anterior: 0

Saldo: 32

Os valores não devem ser editáveis diretamente.

## 5.6. Coluna Importar

Manter um campo numérico editável.

Exemplo:

`32`

Dimensionar a largura para números usuais de quantidades industriais.

Impedir valores inválidos ou superiores ao saldo disponível conforme as regras já existentes.

Não perder o valor digitado ao mudar de página ou aplicar filtros.

## 5.7. Coluna Ações

Adicionar botões ou ícones compactos para:

**Editar:** abrir detalhes e permitir correções.

**Ver PDF:** abrir o documento original na página correspondente.

**Excluir:** remover o item da prévia atual.

O botão Excluir deve solicitar confirmação quando aplicável e não poderá ficar sobreposto a qualquer informação.

A exclusão da prévia não deverá excluir definitivamente registros originais do pedido.

# 6. PAINEL DE DETALHES E EDIÇÃO

Ao clicar em Editar, abrir um painel lateral ou modal.

Apresentar:

**Identificação**
- Pedido.
- Número sequencial.
- Referência L.
- Código BPZ.
- Descrição.

**Destino**
- Projeto.
- Estação.

**Quantidades**
- Solicitada.
- Anteriormente importada.
- Saldo.
- Quantidade a importar.

**Documentação**
- Desenho técnico.
- Revisão.
- Prazo de entrega.
- Arquivo PDF.
- Página de origem.

Permitir corrigir apenas os campos já autorizados pelas regras atuais.

Para alterações de projeto ou estação, exigir justificativa, caso isso já faça parte da validação do sistema.

Botões:

**Salvar alterações**

**Cancelar**

Não salvar alterações automaticamente ao fechar o painel.

Ao cancelar, restaurar os valores anteriores.

Ao salvar, atualizar imediatamente a linha na tabela e recalcular os indicadores.

Preservar todas as validações já existentes.

# 7. RESPONSIVIDADE E DIMENSIONAMENTO

## 7.1. Computadores

A tabela deve utilizar adequadamente a largura disponível da área principal, considerando o menu lateral existente.

Na resolução desktop usual, não deverá existir rolagem horizontal para consultar as informações essenciais.

Utilizar:

- Layout responsivo.
- Dimensionamento proporcional.
- Quebra automática de textos.
- Altura de linha compatível.
- Espaçamentos consistentes.
- Cabeçalho alinhado com as colunas.

Evitar posicionamentos absolutos inadequados.

Não utilizar larguras fixas excessivas que ultrapassem o container.

## 7.2. Tablets

Para telas intermediárias, utilizar um layout adaptado.

Se não houver espaço suficiente para a tabela completa, apresentar cartões compactos por item ou outra organização responsiva que mantenha acessíveis as ações principais.

Cada cartão deverá conter:

- Checkbox.
- Pedido e linha.
- BPZ.
- Descrição.
- Projeto e estação.
- Quantidade a importar.
- Botão Editar.

Informações complementares poderão ficar dentro de uma área expansível.

## 7.3. Celulares

Preservar o acesso e a legibilidade, evitando componentes sobrepostos.

Não tentar reproduzir todas as colunas de desktop em uma tela estreita.

Utilizar cards ou layout vertical.

# 8. ROLAGEM E PAGINAÇÃO

Manter paginação.

Configuração recomendada:

- 25 itens por página.
- Opção para 50 itens.
- Opção para 100 itens, caso a performance permita.

Exibir:

**Página 2 de 21 — Exibindo 26 a 50 de 521 itens**

Se houver filtros aplicados, exibir os totais filtrados.

Manter seleção e edições entre páginas.

Preferencialmente utilizar a rolagem vertical principal da página.

Evitar múltiplas áreas com barras de rolagem internas.

Se utilizar cabeçalho fixo, garantir que não se sobreponha às linhas.

A barra de paginação deve ficar sempre visível no final da tabela ou em posição consistente, sem cobrir conteúdo.

# 9. PESQUISA E FILTROS

Reorganizar a barra de ferramentas.

Apresentar:

**Campo de pesquisa**

Placeholder:

"Buscar pedido, BPZ ou descrição..."

Filtros:

- Projeto.
- Estação.
- Pedido.
- Situação.

Ações:

- Limpar filtros.
- Selecionar resultados válidos.
- Desmarcar resultados.
- Visualizar selecionados.

A pesquisa deverá funcionar em conjunto com os filtros.

A seleção em massa deverá respeitar os resultados filtrados.

Exemplo:

Se o usuário filtrar Estação 31050 e clicar em Selecionar resultados válidos, selecionar somente os itens válidos desse resultado.

Não alterar os demais itens fora do filtro.

Ao remover os filtros, preservar as seleções anteriores.

A interface deve deixar explícito o alcance da seleção em massa, especialmente quando os resultados ocuparem várias páginas.

# 10. INDICADORES OPERACIONAIS

Reorganizar os indicadores em cartões compactos.

Primeira linha:

- PDFs processados.
- Pedidos.
- Linhas.
- Peças solicitadas.
- Projetos.
- Separações previstas.

Segunda linha:

- Pendências.
- Itens já importados.
- Itens selecionados.
- Peças selecionadas.

Os indicadores deverão ter hierarquia visual clara.

Usar números em destaque e descrições menores.

Não permitir que os cartões provoquem rolagem horizontal.

Todos os valores deverão continuar sendo recalculados a partir dos dados reais do sistema.

# 11. VISUALIZAÇÃO POR PROJETO E ESTAÇÃO

Adicionar duas opções de visualização:

**Todos os itens**

**Agrupados por projeto/estação**

Na visualização agrupada, apresentar:

Projeto 26005

- Estação 31050: 117 linhas.
- Estação 31100: 102 linhas.
- Estação 31150: 15 linhas.
- Estação 31200: 99 linhas.
- Estação 31300: 15 linhas.
- Estação 31400: 61 linhas.
- Estação 31450: 106 linhas.

Projeto 25024

- Estação 31250: 6 linhas.

Os valores acima são referências dos testes com os 13 PDFs.

Na aplicação, os totais devem ser dinâmicos e considerar os itens efetivamente selecionados.

Ao clicar em um agrupamento, exibir as linhas correspondentes.

Permitir selecionar e desmarcar os itens daquele grupo, respeitando os filtros aplicados.

Não alterar a lógica real de agrupamento no backend.

Esta será apenas uma nova apresentação dos resultados.

# 12. RESUMO ANTES DA CONFIRMAÇÃO

Substituir o fluxo atual de confirmação direta por uma etapa específica.

Ao terminar a conferência, o usuário deverá clicar em:

**REVISAR SEPARAÇÕES**

O sistema abrirá um resumo contendo:

- Total de PDFs.
- Total de pedidos.
- Total de linhas selecionadas.
- Total de peças selecionadas.
- Total de projetos.
- Total de separações previstas.
- Quantidade de itens excluídos da prévia.
- Quantidade de itens alterados.
- Pendências existentes.

## 12.1. Tabela-resumo

Exemplo:

| Projeto | Estação | Linhas selecionadas | Peças |
|---|---|---:|---:|
| 26005 | 31050 | Dinâmico | Dinâmico |
| 26005 | 31100 | Dinâmico | Dinâmico |
| 26005 | 31150 | Dinâmico | Dinâmico |
| 26005 | 31200 | Dinâmico | Dinâmico |
| 26005 | 31300 | Dinâmico | Dinâmico |
| 26005 | 31400 | Dinâmico | Dinâmico |
| 26005 | 31450 | Dinâmico | Dinâmico |
| 25024 | 31250 | Dinâmico | Dinâmico |

Não exibir grupos sem itens selecionados.

Permitir expandir cada grupo e conferir os itens que serão incluídos.

## 12.2. Validações finais

Antes de habilitar a confirmação, verificar:

- Existem itens selecionados?
- Existem quantidades inválidas?
- Existem quantidades superiores ao saldo?
- Existem pendências impeditivas?
- Existem itens duplicados?
- Projeto e estação estão preenchidos?
- Os agrupamentos são válidos?

Reutilizar as validações já implementadas.

Não criar novas regras de negócio conflitantes.

## 12.3. Botões

**Voltar à conferência**

Retorna à tabela sem perder alterações.

**CONFIRMAR E GERAR SEPARAÇÕES**

Executa o mesmo fluxo de geração já existente.

Ao clicar, apresentar confirmação final:

"Você está prestes a gerar X separações, contendo Y linhas e Z peças. Deseja continuar?"

Após confirmação, executar a criação.

Bloquear cliques repetidos enquanto a operação estiver em andamento.

Exibir resultado real retornado pelo backend.

Não apresentar sucesso antes da confirmação da gravação.

# 13. COMPORTAMENTO APÓS A CONFIRMAÇÃO

Manter integralmente o comportamento já implementado.

Exibir:

- Identificador do lote.
- Número das separações.
- Projeto.
- Estação.
- Quantidade de linhas.
- Situação.
- Acesso às separações geradas.

Não alterar os processos de caixas físicas, romaneios, notas fiscais, etiquetas, comprovantes e histórico.

# 14. ACESSIBILIDADE E EXPERIÊNCIA

Aplicar boas práticas de usabilidade:

- Contraste adequado.
- Tamanho de fonte legível.
- Botões com dimensões apropriadas.
- Estados de foco visíveis.
- Navegação por teclado.
- Identificação de campos obrigatórios.
- Mensagens de validação próximas aos campos.
- Textos auxiliares claros.
- Ícones com títulos ou descrições.
- Confirmação para ações destrutivas.

Evitar ações acionadas apenas ao passar o mouse.

O sistema deverá permanecer utilizável por toque em tablets.

# 15. PRESERVAÇÃO DE FUNCIONALIDADES

**NÃO MODIFICAR:**

- Motor de extração PDF.
- Reconhecimento de pedidos.
- Identificação de BPZ.
- Identificação de projeto e estação.
- Extração de quantidades.
- Controle de saldo importável.
- Prevenção de duplicidades.
- Regras de importação parcial.
- Estrutura de dados dos pedidos.
- Regras de geração de separações.
- Fluxo de leitura QR Code.
- Controle de separações abertas.
- Funcionalidade Assumir Separação.
- Caixas físicas.
- Romaneios.
- Notas fiscais.
- Etiquetas.
- E-mails.
- Comprovantes.
- Auditoria.
- Permissões.

Se alguma alteração fora do frontend for indispensável, justificar tecnicamente e limitar ao mínimo necessário.

# 16. TESTES OBRIGATÓRIOS

Testar a nova interface utilizando os 13 PDFs já fornecidos.

## 16.1. Layout

Verificar:

1. Ausência de sobreposição entre texto e botões.
2. Ausência de truncamentos indevidos.
3. Alinhamento das colunas.
4. Altura adequada das linhas.
5. Visualização correta das descrições.
6. Correta apresentação do pedido e da linha.
7. Responsividade em computador, tablet e celular.
8. Ausência de rolagem horizontal desnecessária.

## 16.2. Funcionalidade

Validar:

1. Pesquisa por pedido.
2. Pesquisa por BPZ.
3. Pesquisa por descrição.
4. Filtros combinados.
5. Limpeza dos filtros.
6. Seleção individual.
7. Seleção em massa.
8. Desmarcação em massa.
9. Paginação.
10. Preservação das seleções entre páginas.
11. Edição de quantidade.
12. Cancelamento de edição.
13. Correção de projeto e estação.
14. Exclusão da prévia.
15. Visualização do PDF.
16. Resumo por projeto e estação.
17. Retorno à conferência.
18. Confirmação final.
19. Prevenção de clique duplo.
20. Exibição do resultado real.

## 16.3. Regressão

Garantir que a implementação não altere:

- Total de linhas identificadas.
- Quantidades extraídas.
- Projetos e estações.
- Agrupamento das separações.
- Controle de duplicidades.
- Regras de autorização.
- Funcionamento do restante do SMART.

# 17. CRITÉRIOS DE ACEITE

A correção será considerada concluída quando:

1. Todos os textos e botões estiverem perfeitamente legíveis.
2. Não houver sobreposição de componentes.
3. A tabela apresentar as informações essenciais sem necessidade de rolagem horizontal em desktop.
4. A edição de campos críticos ocorrer em painel próprio.
5. A quantidade a importar continuar editável diretamente.
6. Pesquisa, filtros e seleção funcionarem entre páginas.
7. A visualização por projeto e estação estiver disponível.
8. O resumo final apresentar exatamente os itens selecionados.
9. A confirmação exigir uma ação explícita do operador.
10. Os resultados da extração dos PDFs permanecerem inalterados.
11. O restante do SMART continuar funcionando normalmente.

# 18. ENTREGÁVEIS DO CODEX

Ao finalizar, apresentar:

- Arquivos modificados.
- Componentes criados.
- Descrição das melhorias aplicadas.
- Capturas de tela do novo layout.
- Resultado dos testes de responsividade.
- Resultado dos testes funcionais.
- Evidência de preservação dos dados da importação.
- Evidência de preservação do processo de separação.
- Eventuais limitações pendentes.

Não declarar testes executados se não houver evidências.

---

# 19. LIMPEZA DO LOTE DE TESTE CANCELADO

## 19.1. Identificação e alcance

Incluir na entrega a limpeza do teste identificado na última captura de tela fornecida pelo usuário:

| Campo | Valor |
|---|---|
| Lote | `0e837525-6131-405c-ad33-f9baa5d120c2` |
| Operador exibido | Amarildo |
| Data e hora exibidas | 23/11/2026, 13:22:25 — America/Sao_Paulo |
| Estado exibido | `cancelled` |
| Evidência | Captura de tela 2026-11-23 133031.png |

Delimitar a operação pelo UUID. Nome, data e estado servem para conferência. Esta é uma exceção pontual ao escopo de interface, sem limpeza geral de lotes cancelados ou mudança no cancelamento normal.

## 19.2. Verificações obrigatórias

No projeto oficial MONDRAGON, conferir o estado atual do lote e inventariar seus arquivos, alocações, separações e demais vínculos. Não presumir ausência de dependências apenas pela captura de tela.

Verificar se o cancelamento já liberou reservas. Não liberar quantidades novamente, alterar saldos dos pedidos ou permitir importações duplicadas.

Conferir vínculos com separações iniciadas ou confirmadas, caixas físicas, romaneios, notas fiscais, entregas e comprovantes. Preservar dependências operacionais e reportar impedimentos à remoção física.

## 19.3. Resultado esperado e execução segura

Retirar exclusivamente esse teste da listagem operacional padrão de Pedidos PDF. Priorizar arquivamento ou ocultação identificada como teste, preservando consulta administrativa e auditoria. Informar claramente se houve arquivamento, ocultação ou exclusão física.

Preservar UUID, responsável, cancelamento e motivo da limpeza na trilha de auditoria. Não apagar auditoria para fazer o teste desaparecer.

Não excluir pedidos ou linhas originais compartilhados com outros lotes. Não alterar alocações ativas de outras importações, documentos reais ou numeração de separações. Preservar caixas, romaneios, notas fiscais, etiquetas, e-mails e comprovantes.

Se a solução exigir remoção física, documentar os registros comprovadamente exclusivos do teste. Executar a alteração no banco de forma transacional, idempotente e restrita ao UUID. Diante de estado incompatível ou vínculo operacional, interromper sem alterações parciais. Preservar evidência de auditoria.

Remover arquivos do Storage somente se forem exclusivos do lote e dispensáveis para a auditoria preservada. Validar cada caminho pelos vínculos do banco. Não executar exclusão por prefixo amplo ou limpeza do bucket. Tratar banco e Storage como operações distintas, registrando falhas e permitindo retomada segura.

Respeitar permissões administrativas e RLS. Não expor credenciais privilegiadas no frontend nem desabilitar segurança.

## 19.4. Critérios de aceite e entregáveis adicionais

- O teste indicado deixa de aparecer na listagem operacional padrão, com o mecanismo utilizado explicitado.
- A auditoria permanece consultável e identifica o lote e a operação.
- Outros lotes, arquivos e documentos permanecem inalterados.
- Saldos e reservas permanecem corretos, sem liberação em duplicidade.
- Repetir a operação não causa novas exclusões ou liberações.
- Dependências reais impedem sua exclusão e são informadas no relatório.
- Apresentar contagens antes e depois, registros afetados, conferência de vínculos e eventuais pendências no Storage, sem expor dados sensíveis.

Adicionar essas evidências aos entregáveis da seção 18. Não declarar a limpeza concluída sem comprovação da operação efetivamente executada.

---
# INSTRUÇÃO FINAL AO CODEX

Implementar a melhoria completa da interface de conferência de pedidos PDF do Almoxarifado SMART Mondragon, conforme a especificação apresentada.

O principal objetivo é corrigir os problemas de sobreposição, dimensionamento e organização da tabela atual, proporcionando uma experiência operacional simples, rápida e segura para conferência de centenas de itens.

Implementar tabela compacta, edição por painel de detalhes, pesquisa e filtros organizados, responsividade adequada, visualização agrupada por projeto e estação e etapa obrigatória de resumo antes da confirmação definitiva.

**Preservar integralmente o extrator PDF e todas as regras de negócio já implementadas.**

Não reescrever o processo de importação.

Não alterar a lógica de criação de separações.

Não comprometer caixas físicas, romaneios, notas fiscais, etiquetas, permissões, histórico ou qualquer funcionalidade existente.

Executar os testes necessários e apresentar evidências da correção.

Priorizar alterações localizadas, código limpo, responsividade e confiabilidade operacional.
