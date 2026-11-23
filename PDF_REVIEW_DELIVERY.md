# Conferência de pedidos PDF — entrega de 23/11/2026

Repositório oficial: https://github.com/almoxarifadomondragon/smart

Aplicação: https://almoxarifadomondragon.github.io/smart/

## Resultado

Conferência em sete colunas, com descrição quebrada em linhas, destino somente para leitura, quantidade editável e ações separadas. Edição de descrição, projeto, estação, quantidade e justificativa ocorre em diálogo com Salvar/Cancelar. O PDF original continua disponível na página correspondente. Os arquivos processados ficam recolhidos por padrão.

Pesquisa por pedido, BPZ ou descrição combinada com filtros de projeto, estação, pedido, situação e selecionados. Seleção em massa abrange os resultados filtrados de todas as páginas e informa esse alcance. Paginação com 25, 50 ou 100 itens. Visualização agrupada com ações restritas ao grupo e aos filtros.

A etapa Revisar separações mostra totais dinâmicos, alterações, exclusões, pendências e os grupos expansíveis. Voltar preserva a conferência. A confirmação exige ação explícita, bloqueia repetição durante diálogo/requisição e utiliza a mesma RPC transacional existente.

CSS restrito ao módulo PDF. Em áreas estreitas a tabela se transforma em cartões. Extrator PDF, Edge Function, criação de separações, QR, caixas, romaneios, notas fiscais, etiquetas e envios não foram alterados.

## Arquivos

- `public/pdf-import-view.js`: interface, edição, resumo, filtros, paginação e consulta administrativa dos testes arquivados.
- `public/pdf-review.js`: funções de apresentação para filtros, pendências e resumo.
- `public/style.css`: estilos do módulo e cartões responsivos.
- `supabase/migrations/20261123184311_archive_pdf_test_batch.sql`: migração gerada com a CLI oficial, transacional e repetível, aplicada pelo SQL Editor do projeto oficial.
- `test/pdf-review.test.mjs`: filtros combinados, preservação, seleção, resumo e validações.
- `test/pdf-import-database.test.mjs`: regressão do fluxo e arquivamento, repetição, estado incompatível e acesso ao histórico.
- `scripts/pdf-import-harness.mjs`: homologação local com PostgreSQL descartável e controle de largura da área de trabalho.
- `.gitignore`: ignora metadados temporários da CLI.
- `PDF_REVIEW_SPEC.md`: especificação integral fornecida, incluindo seção de limpeza do teste.
- `PDF_REVIEW_DELIVERY.md`: este relatório.

## Testes e evidências

`node --test --test-isolation=none`: 90 testes aprovados, zero falhas, zero testes ignorados. Inclui os 13 PDFs reais, 521 linhas, 1.888 peças e oito grupos; não foram enviados PDFs para o GitHub.

Homologação no navegador, em banco descartável:

- 25 itens por página; página seguinte mostra 26–50 de 521.
- Filtrar estação 31050 encontra 117 linhas. Desmarcar os resultados deixa 404 selecionadas; limpar os filtros preserva essa seleção. Selecionar novamente restaura 521.
- Cancelar edição descarta a descrição digitada. Salvar correção sem justificativa mostra erro. Justificativa válida permite salvar e atualiza o resumo.
- Grupos exibem os oito destinos esperados, com totais derivados dos itens.
- Resumo e retorno preservam a seleção. A confirmação explícita gerou oito separações somente no banco descartável.
- Áreas de trabalho de 768 px e 390 px usam cartões sem transbordamento horizontal do módulo. São simulações da largura do conteúdo, não ensaios em dispositivos físicos. A capacidade de redimensionamento do navegador não alterou o viewport observado; não se afirma teste físico de celular.
- Capturas locais de desktop, tablet, celular, edição e resumo acompanham a entrega no diretório de artefatos da conversa.

## Lote de teste arquivado em produção

Projeto Supabase: `qrcpprvxjgcnlxyushsg`.

Lote: `0e837525-6131-405c-ad33-f9baa5d120c2`.

Operador original: Amarildo. Data original: 23/11/2026 13:22:25, America/Sao_Paulo. Estado: `cancelled`.

Inspeção encontrou 13 PDFs, zero alocações e nenhuma separação vinculada. Aplicado arquivamento reversível, sem excluir arquivos, linhas, documentos ou auditoria. O SQL recusa estado diferente de cancelado e qualquer vínculo de alocação/resultado. A repetição não duplica auditoria nem libera reservas.

| Verificação | Antes | Depois |
|---|---:|---:|
| Documentos operacionais | 11 | 11 |
| Hash dos documentos | `cb236c05ff0e9a52de8c204db9b208e0` | `cb236c05ff0e9a52de8c204db9b208e0` |
| PDFs armazenados no cadastro | 13 | 13 |
| Linhas de pedido persistidas | 0 | 0 |
| Alocações | 0 | 0 |
| Lote arquivado | não | sim |

Consulta padrão após arquivamento retorna zero lotes. Consulta administrativa com `archived: true` retorna o lote preservado. Uma entrada `pdf.archive_test` registra a execução por migração, com operador e data originais nos detalhes. `actor_id` é a identidade autenticada da execução quando disponível; não atribui o arquivamento ao operador original.

RLS da tabela permanece habilitada. `anon` continua sem permissão de executar o histórico. Nenhuma política ou concessão de acesso foi ampliada. Todos os arquivos permanecem no bucket privado, portanto não há exclusões pendentes no Storage.

O ambiente oficial não possui a tabela `supabase_migrations.schema_migrations` visível na inspeção. A implantação foi realizada pelo SQL Editor; o arquivo versionado documenta a mudança e pode ser reaplicado sem duplicar o arquivamento. Não foi criado histórico de migrações fictício.

O Advisor Center foi consultado. Ele sinaliza que a RPC de histórico é uma função SECURITY DEFINER executável por usuários autenticados. Esse acesso é intencional na arquitetura existente: a função exige membro ativo, limita a inclusão de arquivados ao administrador e não concede acesso direto às tabelas privadas. A permissão anônima foi verificada como falsa. Não foi ampliado o acesso nem removida a verificação de autorização para eliminar esse aviso.

## Publicação

Interface publicada no commit `680e8c0a1fd831bdc9797600bf5cba15c5387232`.

GitHub Pages concluído com sucesso: https://github.com/almoxarifadomondragon/smart/actions/runs/45242968315

Os três arquivos públicos alterados foram obtidos do endereço publicado com HTTP 200 e comparados com a versão local testada, com igualdade após normalização de finais de linha. A publicação ocorreu pela sessão GitHub do titular no painel, pois o conector não listava a conta MONDRAGON e a CLI Git não tinha credenciais não interativas disponíveis.

## Limites

Não foram geradas separações, caixas, romaneios ou e-mails de teste em produção. Não houve ensaio físico de toque ou impressão. A validação funcional completa foi realizada no banco descartável; a validação de produção conferiu arquivamento, histórico, autorização e artefatos publicados. Recomenda-se a conferência operacional normal pelo usuário autenticado na próxima importação real.
