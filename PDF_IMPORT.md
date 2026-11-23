# Importação em massa de pedidos PDF

## Arquitetura e integração

O SMART é uma aplicação estática de módulos JavaScript em `public/`, hospedada no GitHub Pages, com Supabase Auth, RPCs PostgreSQL e Edge Functions. A tabela existente `public.picking_documents` contém os itens e volumes em JSONB. As regras atuais de proprietário, revisão otimista, destinos, destinatários, caixas, romaneios e comprovantes continuam sendo usadas pelos documentos importados.

O menu **Pedidos PDF** apresenta seleção múltipla, arrastar arquivos, progresso por página, revisão paginada de 50 linhas, seleção em lote, filtros combinados, ordenação, correções justificadas, consulta do original e histórico. A revisão mantém seleção e edições ao filtrar ou paginar. Lotes em revisão podem ser retomados pelo histórico.

A extração utiliza PDF.js 5.6.205, com arquivos e licença versionados em `public/vendor/pdfjs/`. O navegador reconstrói linhas por coordenadas para conferir o documento. A Edge Function `import-pdf-order` autentica novamente o usuário e extrai o PDF de forma independente antes de armazenar o original em bucket privado. Os valores solicitados vêm dessa extração canônica do servidor.

A leitura reconhece cabeçalhos, linhas de tabela, BPZ, descrição, sequencial, referência L:, quantidade decimal, destino explícito, desenho, revisão, prazo e página. As páginas de etiquetas servem para cruzar pedido, linha, código, destino e quantidade. Os desenhos são campos de rastreabilidade. O destino utilizado vem de `L: ... - projeto - estação`.

## Persistência e segurança

Aplicar em ordem as migrações incrementais `supabase/migrations/20261123120000_pdf_order_import.sql` e `supabase/migrations/20261123121000_pdf_box_lookup.sql` em uma instalação existente. A migração verifica o hash dos documentos existentes antes e depois das alterações e reverte se detectar mudanças. A coluna nova `picking_documents.import_state` é nula para documentos anteriores.

| Estrutura privada | Responsabilidade |
| --- | --- |
| `pdf_import_batches` | Autor, estado, seleção confirmada e resultado durável para repetição idempotente. |
| `pdf_import_files` | SHA-256, caminho privado, páginas, cabeçalhos e extração canônica completa. |
| `pdf_order_lines` | Identidade da linha e quantidade solicitada. |
| `pdf_order_allocations` | Quantidade reservada por linha, lote, arquivo, documento e UUID do item, correções e cancelamento. |

As quatro tabelas possuem RLS e acesso direto revogado para navegador e anônimo. `stage_pdf_order` é exclusivo de `service_role`, usado dentro da Edge Function. As demais RPCs verificam associação ativa e perfil. Administradores e operadores importam. Leitores consultam histórico e documentos permitidos. O histórico administrativo mostra auditoria e justificativas. A operação de criação não envia e-mails.

O bucket `picking-order-pdfs` é privado, com limite de 20 MB e MIME PDF. A Edge confere a assinatura `%PDF-`, integridade pelo parser, tamanho real do corpo, páginas, extensão e usuário ativo. Nenhum código de ação ou script incorporado do PDF é executado pelo fluxo de extração. A consulta do original gera URL assinada válida por 60 segundos.

Os limites centralizados em `PDF_LIMITS`, em `public/pdf-orders.js`, são 25 arquivos por lote, 20 MB por arquivo, 200 páginas e 5.000 linhas por arquivo. Mudanças no limite em bytes devem acompanhar o limite do bucket e a validação SQL. Documentos sem camada de texto, protegidos ou fora da estrutura reconhecida apresentam erro por arquivo. Os outros arquivos continuam. OCR permanece fora desta versão.

## Duplicidade, saldo e correções

- SHA-256 elimina PDFs idênticos no mesmo lote. A identidade lógica usa origem, pedido e referência L:, com BPZ e destino original verificados no conteúdo. Essa unicidade mais forte também detecta uma troca de BPZ na mesma linha de um pedido.
- A quantidade importável é a solicitada menos a soma de vínculos ativos de todos os lotes. A confirmação adquire locks e serializa a validação entre lotes. Clique duplo e repetição de requisição retornam o resultado já confirmado. Repetição com seleção diferente é rejeitada.
- As linhas são agrupadas pelo destino aprovado em todo o lote. Para cada destino, a função utiliza `create_picking`, a numeração existente e o volume inicial normal. A confirmação inteira é uma transação. Um erro desfaz todas as separações daquele envio.
- Quantidade positiva com até duas casas decimais é obrigatória na importação. A leitura QR existente conserva seu procedimento de quantidade inicial zero. A edição de BPZ em uma separação exige vínculo de importação no banco.
- `purchase_order` mantém a parte numérica compatível com os validadores atuais. `source_order` mantém o VH completo no item, e a relação de origem preserva arquivo, página, L:, sequencial, desenho, revisão e conteúdo original. CSV e visualização do documento preferem o pedido completo quando disponível.
- Projeto, estação e descrição podem ser corrigidos na revisão, com justificativa obrigatória para alterações. Divergências com etiquetas também exigem justificativa. Correções e origem são auditadas no momento da alocação.
- Conteúdo divergente de uma linha importada é bloqueado até revisão administrativa. A RPC `review_pdf_order_line` permite aprovar alterações de quantidade ou destino, preserva antes/depois e impede quantidade solicitada inferior à já reservada. Uma mudança de BPZ na mesma linha exige regularização do documento com o responsável.
- Cancelamento só libera reservas quando todas as separações do lote permanecem pendentes. As entidades e a auditoria são preservadas. Remover um item de uma separação iniciada mantém a reserva original, e aumentar sua quantidade acima do reservado é bloqueado. O saldo adicional deve passar por outra importação.

## Início e fluxo operacional

As separações PDF começam com `status=draft` e `import_state=pending`. A interface oferece **Iniciar separação** ao proprietário e **Assumir e iniciar separação** ao administrador. O início verifica separações em andamento do usuário, registra o proprietário anterior e libera a edição normal. Salvar, confirmar ou criar caixa física enquanto pendente é bloqueado no banco.

Após o início, a separação segue os mesmos serviços de edição, revisão, NF, organização dos volumes, caixa física, confirmação de destinatários, romaneio, fechamento e comprovante. A importação registra a origem documental. Recebimento físico, qualidade e entrega seguem seus procedimentos operacionais.

## Testes executados

Em 23/11/2026, a suíte ampliada executou 86 testes sem falhas e sem testes ignorados no computador com os documentos de referência disponíveis. O PostgreSQL de testes é PGlite em memória, com todos os schemas e migrações e identidades fictícias. A base operacional foi consultada apenas para verificar compatibilidade antes da implantação.

| PDF | Páginas | Linhas |
| --- | ---: | ---: |
| VH21338 | 2 | 3 |
| VH21339 | 11 | 43 |
| VH21340 | 16 | 64 |
| VH21346 | 11 | 45 |
| VH21347 | 13 | 56 |
| VH21348 | 7 | 30 |
| VH21349 | 20 | 85 |
| VH21350 | 11 | 59 |
| VH21352 | 21 | 92 |
| VH21353 | 5 | 21 |
| VH21519 | 5 | 16 |
| VH21549 | 2 | 1 |
| VH21715 | 3 | 6 |
| Total | | 521 |

| Projeto | Estação | Linhas |
| --- | --- | ---: |
| 25024 | 31250 | 6 |
| 26005 | 31050 | 117 |
| 26005 | 31100 | 102 |
| 26005 | 31150 | 15 |
| 26005 | 31200 | 99 |
| 26005 | 31300 | 15 |
| 26005 | 31400 | 61 |
| 26005 | 31450 | 106 |

O lote contém 1.888 peças. A extração encontrou 13 pedidos, dois projetos e oito grupos, com zero pendências nos documentos de referência. Todos foram gravados e agrupados no PostgreSQL descartável. A tela de teste local exibiu os mesmos totais e confirmou oito separações. Seleção, filtro de projeto e paginação foram verificados no navegador. O modal HTML de justificativa também foi aberto e fechado pela interface.

Os testes de banco incluem importação 60 + 25 de uma linha de 100, rejeição de excesso, repetição idempotente, rollback de falha, conteúdo alterado, revisão administrativa, início com outra separação aberta, salvamento versionado do BPZ, NF, caixa física, confirmação do romaneio, fechamento com snapshot e consulta da auditoria. Os testes anteriores de QR, segurança, destinatários, etiquetas, entrega e reenvio continuam passando. A nova função passou em `deno check`, e a extração foi executada no Deno. O artefato empacotado iniciou com sucesso no Deno local.

Envio real de e-mail, impressão física, avaliação visual em tablet e importação autenticada de um lote no ambiente de produção exigem validação operacional. Os 13 pedidos de referência foram usados no ambiente descartável, para que a decisão de gerar separações reais permaneça na confirmação do operador.

## Verificação no destino oficial

Em 23/11/2026, as duas migrações incrementais foram aplicadas no projeto oficial `qrcpprvxjgcnlxyushsg`. A consulta posterior confirmou os mesmos 11 documentos existentes, hash preservado, quatro tabelas novas com RLS, bucket privado e execução de staging revogada para o navegador. A consulta de caixas reconhece BPZ e inclui a origem VH no conteúdo das caixas. A nova Edge Function foi publicada com JWT habilitado. Uma chamada sem autenticação retornou HTTP 401. Nenhum lote de pedido foi criado pela implantação, conforme a contagem de zero lotes no destino.

## Execução reproduzível

Pré-requisitos de desenvolvimento são Node 24 e pnpm 11.25.0. O lockfile fixa as dependências de desenvolvimento. O frontend publicado utiliza os módulos locais de PDF.js.

```powershell
pnpm install --frozen-lockfile
pnpm test
pnpm run build:pdf-edge
pnpm run test:pdf-ui
```

A tela isolada fica em `http://127.0.0.1:4181/`. Ela inicializa um banco descartável com identidade fictícia. Fechar o processo descarta os dados desse ambiente. Os testes com os 13 PDFs leem `SMART_PDF_FIXTURES`, com fallback para a pasta Downloads usada na execução original. Esses testes são explicitamente ignorados em máquinas sem todos os documentos. Os PDFs privados não integram o repositório.

## Implantação

1. Conferir o projeto oficial `qrcpprvxjgcnlxyushsg`, fazer o backup conforme o procedimento operacional e aplicar somente as duas migrações incrementais novas, em ordem. A instalação por SQL Editor pode não ter `supabase_migrations.schema_migrations`, como observado no destino. Registrar a aplicação no controle de implantação da organização.
2. Publicar a Edge Function `import-pdf-order`. O CLI pode usar a árvore de imports do repositório. Para o editor do painel, `pnpm run build:pdf-edge` produz `tmp/pdf-edge-bundle.js` em um único arquivo e uma página auxiliar local para copiar o código. Conservar a verificação JWT habilitada. A função também valida o usuário via Auth e o perfil ativo.
3. As variáveis de servidor são as automáticas do Supabase `SUPABASE_URL`, `SUPABASE_ANON_KEY` e `SUPABASE_SERVICE_ROLE_KEY`. Nenhuma chave privilegiada é enviada ao cliente. O frontend reutiliza a configuração pública e a sessão existentes.
4. Publicar `public/` pelo workflow Pages existente depois de verificar migração e função. Conferir o menu Pedidos PDF e o acesso por perfil. O operador confirma explicitamente qualquer criação de separações reais.
5. Em rollback de interface, restaurar o frontend anterior pelo workflow. Conservar as novas tabelas, alocações e arquivos privados para preservar rastreabilidade. Interromper novas importações pela desativação da função, se necessário, conforme o procedimento de operação.

## Arquivos

Novos arquivos principais são `public/pdf-orders.js`, `public/pdf-import-view.js`, os arquivos locais e a licença de PDF.js em `public/vendor/pdfjs/`, a Edge Function, as migrações incrementais, `test/pdf-orders.test.mjs`, `test/pdf-import-database.test.mjs`, `scripts/build-pdf-edge.mjs`, `scripts/pdf-import-harness.mjs`, este documento e os lockfiles de desenvolvimento.

Foram adaptados `public/app.js`, `public/api.js`, `public/domain.js`, `public/picking-access.js`, `public/history.js`, `public/warehouse.js`, `public/style.css`, `server.mjs`, `package.json`, `.gitignore` e `supabase/config.toml`. O ajuste do servidor local adiciona o MIME de módulos `.mjs`. A migração estende as funções de salvamento, busca e dashboard existentes e adiciona proteção documental.
