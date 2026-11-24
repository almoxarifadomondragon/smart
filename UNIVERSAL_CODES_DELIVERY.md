# MONDRAGON — Compatibilidade BMA/BPZ

Data: 24/11/2026. Destinos autorizados: `almoxarifadomondragon/smart` e Supabase `qrcpprvxjgcnlxyushsg`.

## Estado da entrega

Implementação testada e publicada em 24/11/2026 nos destinos oficiais. Acesso de escrita confirmado pelo proprietário do repositório e pelo editor SQL da organização Mondragon. A migração incremental foi aplicada, o extrator canônico e as duas funções de e-mail foram republicados. Os arquivos públicos retornaram HTTP 200 e conteúdo idêntico aos arquivos locais testados (normalizando CRLF).

GitHub Pages: https://almoxarifadomondragon.github.io/smart/

Commit da interface: `91294d5bda9a6d3e2f44b58bf5766c6a05dbd7ac`. Publicação Pages concluída com sucesso: https://github.com/almoxarifadomondragon/smart/actions/runs/45462664440

## Diagnóstico e solução

O validador básico já aceitava os dois prefixos, mas o parser de códigos simples e o extrator PDF tinham restrições BPZ/BMA inconsistentes. O trigger de proteção exigia PDF para BPZ sem alocação. A correção separa identidade do código e origem operacional por item.

- BMA e BPZ normalizados com três letras e sete dígitos; entradas simples, JSON, texto rotulado e QR composto preservadas.
- Botão “Digitar código” reutiliza o modal e registra origem Manual. Scanner/câmera usam origem QR. Não é possível distinguir teclado físico de texto digitado no campo de leitura; a ação manual explícita estabelece essa distinção.
- Zero é permitido somente como entrada temporária no modal; salvar exige quantidade positiva.
- PDF cliente e canônico compartilham o mesmo extrator ampliado para BMA/BPZ.
- Alocações reais continuam determinando a origem PDF no backend. UUID, código, destino, pedido, linha, alocação e limite de quantidade são protegidos. Metadados omitidos são restaurados; metadados adulterados são recusados.
- Inclusões manuais/QR não alteram reservas PDF. Possíveis duplicidades exigem conferência, justificativa e impressão digital calculada novamente pelo servidor, com auditoria. A prévia exige operador ativo e rascunho próprio. Leitor permanece somente consulta.
- Itens históricos sem origem conhecida são exibidos como Legado. A migração não reescreve itens históricos.
- Cabeçalhos documentais genéricos passam a “Código BMA/BPZ”; CSV acrescenta Origem ao final.

## Arquivos

Os caminhos abaixo são relativos à raiz local `C:\Users\sn1078588\Documents\ChatGPT\MONDRAGON 2\smart`.

| Arquivo | Alteração |
|---|---|
| `public/domain.js` | QR universal e CSV |
| `public/pdf-orders.js` | Parser BMA/BPZ com grupos não capturantes |
| `public/api.js` | RPC de prévia de duplicidade |
| `public/app.js` | Modal, entrada manual, origem e revisão de duplicidade |
| `public/item-origin.js` | Prévia de duplicidade exclusiva da demonstração |
| `public/style.css` | Indicadores de origem e revisão |
| `public/warehouse.js` | Cabeçalhos genéricos |
| `supabase/migrations/20261124180921_allow_manual_bma_bpz.sql` | Nova migração transacional incremental |
| `supabase/functions/import-pdf-order/index.ts` | Documentação da dependência compartilhada; republicar com parser atualizado |
| `supabase/functions/send-manifest/index.ts` | Cabeçalho BMA/BPZ |
| `supabase/functions/send-box-delivery/index.ts` | Cabeçalho BMA/BPZ |
| `test/universal-codes.test.mjs` | Entradas e regressão individual dos PDFs |
| `test/universal-database.test.mjs` | Integração SQL, adulteração, duplicidade e permissões |
| `test/electrical-database.test.mjs` | Fixtures compatíveis com revisão de repetição legítima |
| `test/warehouse.test.mjs` | CSV com origem |
| `test/fixtures/pdf-bpz-reference.json` | Hashes de referência das 521 linhas e 13 PDFs |
| `test/fixtures/synthetic-bma-order.pdf` | Documento sintético claramente identificado |

Nenhuma migração anterior foi modificada. A nova migração substitui explicitamente `guard_pdf_document`, `save_picking_impl`, `stage_pdf_order` e `confirm_pdf_import`, preserva o trigger e adiciona a RPC `preview_item_duplicates` e seu helper privado. Mantém `search_path` seguro e acesso restrito. Confere hashes dos documentos e alocações antes/depois dentro da transação, abortando em caso de mudança histórica.

## Evidências executadas

Comando `node --test --test-isolation=none`: **103 testes, 103 aprovados, zero falhas e zero ignorados**. Log local: `tmp/universal-all-final.txt`.

Os 13 PDFs reais foram comparados com referência capturada no commit-base `47c00ca187642afc5d3ae31cdce2bbe8dd6cab0b`, antes da mudança do parser: hash do arquivo e hash JSON completo de cada uma das **521 linhas**, não somente totais. A referência contém hashes, sem publicar os PDFs reais. O teste real depende desses arquivos locais em Downloads; em outro ambiente sem os PDFs, essa prova é explicitamente ignorada pelo runner e não deve ser anunciada como executada.

Os totais de referência continuam: 13 pedidos, 521 linhas, 1.888 peças, dois projetos, oito estações/separações previstas e zero pendências.

Três QR vetoriais reais foram renderizados e decodificados da página 2 de VH21338. O payload observado é o formato de sete campos já suportado, por exemplo `180$BPZ0043634$26005$31450$1,00$21338$3`. Não foi inferido o payload a partir do texto visível da etiqueta.

Além do PDF sintético, os dois documentos BMA reais fornecidos em 24/11 foram renderizados e conferidos. Ambos usam pedidos **EZ**, exigindo ampliar reconhecimento e validação no parser, staging e confirmação SQL. A referência técnica EZ com espaços também é preservada integralmente, sem alterar os resultados BPZ/VH.

| Documento | Código | Quantidade | Projeto | Estação | Sequência / L | Resultado |
|---|---|---:|---|---|---|---|
| EZ21075 — AWALTECH | BMA0013502 | 1 | 26002 | 31132 | 1 / 1 | Sem erros ou avisos |
| EZ21077 — TRIVAX | BMA0008056 | 3 | 24005 | 31135 | 1 / 1 | Sem erros ou avisos |

A referência técnica TRIVAX foi conferida como `GEDORE_ADAP. QUAD. SEXT=1_4''X100MM`. Revisão não informada permanece vazia. Os testes locais também executaram staging, confirmação idempotente, início, salvamento protegido, saldo e finalização desses dois pedidos no PostgreSQL em PGlite. Não foram criadas importações de teste em produção. O teste não prova compatibilidade com todo layout BMA possível.

Teste visual na aplicação completa em demonstração local isolada: BPZ manual em minúsculas normalizado, BMA manual, QR BPZ com zero recusado ao salvar e posteriormente corrigido para 2, origem QR preservada, alerta de repetição e confirmação justificada. Resultado final: quatro registros e cinco unidades; nenhum erro de console capturado. Evidências `tmp/universal-duplicate-review.jpg` e `tmp/universal-ui-validated.jpg`. Nenhum registro foi criado no Supabase durante esse teste. O modo demo não substitui a auditoria transacional do backend.

Build `node scripts/build-pdf-edge.mjs` executado com sucesso. Bundle canônico preparado em `tmp/pdf-edge-bundle.js`.

Os testes SQL locais executaram funções e transações em PGlite, incluindo idempotência, restrições de pendência, cancelamento autorizado, finalização, adulteração de origem/UUID/destino/quantidade, permissões e auditoria. Isso não equivale a homologação no servidor de produção.

## Implantação e preservação verificadas

- Migração `20261124180921_allow_manual_bma_bpz.sql` aplicada via SQL Editor do projeto oficial. Não houve alteração de migrações antigas. A própria transação confere hashes de documentos e alocações antes/depois, abortando em caso de diferença.
- O trigger permanece habilitado. RPC de prévia inacessível a anon; staging inacessível a authenticated e permitido somente ao serviço existente. RLS permanece habilitada nas tabelas operacionais e PDF verificadas; políticas inalteradas.
- Dados atuais conferidos: **15 documentos, 65 registros, 553 unidades**, zero alocações, 18 arquivos PDF e cinco configurações de destinatários. Os arquivos e destinatários mantiveram seus hashes.
- Uma diferença de hash entre a primeira consulta e a consulta posterior foi investigada antes de liberar o deploy. A auditoria registrou NF às 15:37:14 e confirmação do romaneio 15 às 15:38:30 (São Paulo), durante o trabalho. A última transação de alteração documental foi **2110**, anterior à transação **2112** que criou a RPC/migração. Consulta comprovou **zero documentos com alteração na transação da migração ou posterior**. A diferença decorreu da operação concorrente anterior à migração, sem reescrita documental pela correção. A revisão automática inicialmente bloqueou o deploy; após apresentar essa prova, o deploy foi autorizado e concluído.
- Hash de políticas antes/depois: `b9f699a57388d8c1b27f4c59770c931e`; arquivos PDF: `3246291d7bff9c2a21fc23b969ab30eb`; configurações de destinatários: `61a232fb977367cc45ac5d8ccb214fbc`.
- Republicadas `import-pdf-order`, `send-manifest` e `send-box-delivery`; as páginas Overview confirmaram implantação recente. JWT e segredos não foram modificados. Requisições sem Authorization às três funções retornaram **401** no gateway. Nenhum e-mail foi enviado nesses testes.
- O extrator canônico foi publicado como bundle produzido por `scripts/build-pdf-edge.mjs`, incluindo o parser compartilhado atualizado, não apenas o arquivo index isolado.
- Os sete arquivos públicos alterados foram comparados com o site online e coincidiram. A interface publicada foi aberta em demonstração: botão manual, campo BMA/BPZ e origem Manual confirmados. Evidências locais: `tmp/universal-live-bma.jpg`, `tmp/universal-supabase-verified.jpg` e `tmp/universal-production-check.json`.

## Limitações e continuidade

- Não houve teste físico de câmera ou scanner USB/Bluetooth, nem envio real de e-mail nesta correção.
- Os dois layouts BMA reais enviados foram validados; novos modelos documentais exigem conferência própria.
- Testes com PDFs reais dependem dos arquivos privados locais em Downloads. Sem eles, a suíte sinaliza os testes de extração real como ignorados; as fixtures públicas contêm somente hashes e PDF sintético.
- Não executar rollback destrutivo; eventual correção deve ser incremental, preservando alocações e auditoria. A migração já foi aplicada e não deve ser executada novamente.

A especificação integral recebida está preservada em `UNIVERSAL_CODES_SPEC.md`. Todos os caminhos listados são relativos à raiz indicada neste documento.
