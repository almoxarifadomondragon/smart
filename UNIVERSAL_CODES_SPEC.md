# ESPECIFICAÇÃO TÉCNICA CORRETIVA — CODEX
## MONDRAGON — ALMOXARIFADO SMART
### Compatibilidade universal BMA e BPZ — QR Code, digitação manual e importação PDF

**Repositório:** https://github.com/almoxarifadomondragon/smart

**Prioridade:** Alta — Correção funcional

**Módulos envolvidos:** Separação Digital, Leitura QR Code, Importação PDF, Banco de Dados, Auditoria, Caixas Físicas e Romaneios.

**Tipo:** Correção de regra de negócio e ampliação de compatibilidade.

---

# 1. OBJETIVO

Corrigir a arquitetura atual do Almoxarifado SMART para permitir que materiais identificados pelos prefixos **BMA** e **BPZ** sejam registrados por qualquer uma das modalidades operacionais suportadas:

1. Leitura de QR Code.
2. Leitura por scanner USB/Bluetooth.
3. Digitação manual.
4. Importação em massa de pedidos PDF.

A importação PDF não pode ser obrigatória para nenhum dos dois prefixos.

O sistema deve tratar BMA e BPZ como identificadores de materiais válidos, independentemente da modalidade utilizada.

**REGRA CENTRAL: O prefixo do material não determina obrigatoriamente sua origem operacional.**

BMA e BPZ poderão ter origem manual, QR Code ou PDF.

A rastreabilidade deverá ser preservada conforme a modalidade utilizada.

# 2. DIAGNÓSTICO DO CÓDIGO ATUAL

A inspeção do repositório identificou os seguintes pontos.

## 2.1. Validação de código

Arquivo:

`public/domain.js`

A função `parseCode()` já aceita:

`BMA` seguido de sete dígitos.

`BPZ` seguido de sete dígitos.

Entretanto, o tratamento de QR Code deve ser revisado para garantir que todos os formatos já suportados aceitem ambos os prefixos.

## 2.2. Bloqueio no banco

Migração existente:

`supabase/migrations/20261123120000_pdf_order_import.sql`

Função:

`smart_private.guard_pdf_document()`

A função contém uma regra equivalente a:

```sql
ELSIF item->>'code' LIKE 'BPZ%' THEN
  RAISE EXCEPTION 'BPZ exige vínculo de importação PDF.';
END IF;
```

Essa condição impede registrar BPZ manualmente quando o item não possui vínculo com uma importação PDF.

**Essa obrigatoriedade deverá ser eliminada, preservando as demais proteções do trigger.**

## 2.3. Extrator PDF

Arquivo:

`public/pdf-orders.js`

Atualmente, o extrator contém validações e expressões regulares específicas para códigos BPZ.

Será necessário ampliar o reconhecimento para códigos BMA.

A ampliação deve preservar integralmente a capacidade atual de leitura dos pedidos BPZ.

## 2.4. Proteções documentais

O sistema possui estruturas de rastreabilidade, incluindo:

- `pdf_import_batches`
- `pdf_import_files`
- `pdf_order_lines`
- `pdf_order_allocations`

Essas estruturas deverão permanecer funcionando.

As alocações associadas aos PDFs continuam protegidas contra alterações indevidas de código, destino e quantidade.

# 3. MATRIZ FUNCIONAL OBRIGATÓRIA

Todas as combinações abaixo deverão funcionar.

| Código | QR Code | Digitação manual | Importação PDF |
|---|---|---|---|
| BMA | Permitido | Permitido | Permitido |
| BPZ | Permitido | Permitido | Permitido |

Nenhuma modalidade poderá ser bloqueada exclusivamente pelo prefixo BMA ou BPZ.

As validações operacionais existentes continuam obrigatórias.

Exemplos:

`BMA0001979`

`BPZ0043578`

Ambos devem ser aceitos.

Não permitir formatos inválidos ou códigos incompletos.

# 4. CORREÇÃO DO TRIGGER POSTGRESQL

## RF-01 — Alterar a regra de proteção

Modificar o comportamento de:

`smart_private.guard_pdf_document()`

O trigger deverá distinguir itens com alocação documental de itens sem alocação.

### Caso A — Item vinculado a PDF

Quando o item estiver associado a um registro válido em `pdf_order_allocations`:

Preservar:

- Código original.
- Projeto aprovado.
- Estação aprovada.
- Quantidade máxima reservada.
- Pedido de origem.
- Linha original.
- Identificador da alocação.
- Histórico de correções.
- Auditoria.

Não permitir alteração que ultrapasse as quantidades reservadas.

Não permitir substituição do BMA ou BPZ por outro código sem fluxo administrativo autorizado.

Não permitir remover o vínculo documental por uma edição comum.

### Caso B — Item registrado manualmente ou por QR Code

Quando o item não possuir vínculo com PDF:

Permitir BMA e BPZ normalmente, respeitando:

- Validação de código.
- Validação de projeto.
- Validação de estação.
- Controle de quantidade.
- Regras de usuário.
- Regras de separação em andamento.
- Regras de edição e confirmação.

Não exigir importação PDF.

### Caso C — Documento originado por PDF com inclusão posterior de itens

Se uma separação originada por PDF permitir adicionar itens pelo fluxo operacional existente, preservar a origem de cada item individualmente.

Um novo item manual não poderá herdar falsamente o vínculo documental de outro item.

A inclusão não pode ser usada para burlar as regras de quantidade reservada ou identidade documental.

Itens adicionados manualmente devem possuir origem própria e auditoria correspondente.

## RF-02 — Proteção contra remoção ou substituição de vínculos

O trigger também deverá validar que itens originalmente vinculados a PDF não sejam transformados em itens manuais por remoção de identificadores.

Comparar os vínculos persistidos com os itens anteriores e novos do documento.

Uma atualização não poderá:

- Apagar a origem PDF para escapar da validação.
- Substituir o UUID de um item documental para escapar do vínculo.
- Reutilizar UUID documental em outro item.
- Alterar silenciosamente o destino de um item importado.
- Modificar quantidade acima da alocação original.

Se uma operação de exclusão ou cancelamento estiver autorizada pelo sistema, respeitar seu fluxo específico e sua auditoria.

## RF-03 — Nova migração incremental

**Não editar diretamente a migração já aplicada à produção.**

Criar uma nova migração SQL com timestamp atual.

Exemplo de nome:

`*_allow_manual_bma_bpz.sql`

A migração deverá:

1. Inspecionar a definição existente do trigger.
2. Preservar sua assinatura.
3. Substituir a função com `CREATE OR REPLACE FUNCTION`.
4. Eliminar somente a obrigatoriedade de PDF por prefixo.
5. Preservar os demais bloqueios documentais.
6. Manter o trigger associado à tabela atual.
7. Manter privilégios, propriedade e `search_path` seguros.
8. Não modificar registros históricos.
9. Não excluir alocações.
10. Não alterar quantidades existentes.

Evitar substituições textuais frágeis na definição SQL.

Implementar explicitamente a função revisada e adicionar testes de regressão.

# 5. VALIDAÇÃO UNIVERSAL DE BMA E BPZ

## RF-04 — Padronização de códigos

A validação deverá aceitar:

```regex
^(BMA|BPZ)[0-9]{7}$
```

Aplicar normalização de espaços e letras maiúsculas na entrada do usuário.

Exemplos válidos:

- BMA0001979
- BMA0000856
- BPZ0043578
- BPZ0043634

Exemplos inválidos:

- BMA123
- BPZ123
- ABC0043578
- BPZ0043578X

O frontend e o backend deverão utilizar regras compatíveis.

Não aceitar um código no frontend para rejeitá-lo injustificadamente no banco.

# 6. LEITURA POR QR CODE

## RF-05 — Aceitar ambos os prefixos

Revisar `parseQR()` e os componentes de leitura.

Os seguintes formatos devem continuar funcionando:

- QR Code BMA completo.
- QR Code BPZ completo.
- Código BMA simples.
- Código BPZ simples.
- Leitura por scanner.
- Digitação manual.

Preservar os formatos compostos já utilizados no SMART.

Quando o QR Code apresentar projeto, estação, quantidade, pedido e linha, utilizar esses dados conforme as regras existentes.

Quando o código contiver apenas BMA ou BPZ, permitir que o operador complete os campos necessários.

## RF-06 — QR Code das etiquetas de peças usinadas

Os PDFs Mondragon incluem etiquetas com informações como:

- `RefFab`
- `Ord`
- `Art`
- `Dest`
- `QTY`

Investigar como esses dados estão efetivamente codificados no QR Code.

Se o leitor já suportar esse formato, preservá-lo.

Se não suportar, adicionar um adaptador compatível para interpretar o conteúdo real, sem comprometer os demais formatos de QR Code.

Não presumir que o texto visível da etiqueta seja necessariamente o conteúdo exato do QR Code.

# 7. DIGITAÇÃO MANUAL

## RF-07 — Incluir BMA e BPZ

Permitir criar itens manualmente utilizando qualquer um dos dois prefixos.

A tela deverá continuar solicitando os campos obrigatórios já definidos para separações manuais.

Campos operacionais:

- Código BMA/BPZ.
- Projeto.
- Estação.
- Quantidade.
- Pedido de compras, quando aplicável.
- Item do pedido, quando aplicável.
- Demais informações previstas no fluxo atual.

Não exigir que o usuário importe um PDF para liberar um BPZ.

## RF-08 — Quantidade zero

Preservar a funcionalidade existente que permite iniciar a bipagem com quantidade zero, quando prevista no fluxo operacional, e ajustar a quantidade posteriormente.

Essa regra deverá funcionar igualmente para BMA e BPZ.

Não permitir que a flexibilização modifique indevidamente as regras de confirmação ou fechamento de separações.

# 8. IMPORTAÇÃO PDF PARA BMA E BPZ

## RF-09 — Ampliação do extrator

O motor atual de importação PDF identifica códigos BPZ.

Ampliar o reconhecimento para aceitar BMA e BPZ, sem alterar desnecessariamente o restante do processamento.

Revisar:

- `public/pdf-orders.js`
- Extrator canônico da Edge Function `import-pdf-order`
- Validações SQL.
- Funções de staging.
- Prévia e conferência.
- Identificação de etiquetas.
- Regras de duplicidade.
- Confirmação de importação.
- Testes automatizados.

A alteração deverá ser feita tanto no cliente quanto no servidor.

Não é suficiente alterar somente a expressão regular do frontend.

## RF-10 — Preservar a estrutura dos pedidos

Manter extração de:

- Número do pedido.
- Linha sequencial.
- Referência L.
- Código BMA ou BPZ.
- Descrição.
- Quantidade.
- Projeto.
- Estação.
- Desenho.
- Revisão.
- Prazo.
- Página de origem.

Preservar a distinção entre linha sequencial e referência L.

## RF-11 — Compatibilidade documental

Os 13 PDFs de referência possuem códigos BPZ.

Esses documentos deverão continuar sendo processados sem alterações nos resultados.

**Importante:** não assumir que todos os pedidos contendo BMA terão exatamente o mesmo layout documental dos pedidos BPZ.

O Codex deverá verificar se o extrator atual consegue reconhecer corretamente um PDF com materiais BMA.

Caso a estrutura seja equivalente, ampliar a validação e o reconhecimento.

Caso o layout seja diferente, criar um adaptador específico, preservando o parser atual.

Não inventar campos ausentes nem presumir que todos os PDFs são compatíveis.

Registrar a necessidade de documentos reais BMA para validação completa, caso eles não estejam disponíveis.

# 9. IDENTIFICAÇÃO DA ORIGEM

## RF-12 — Origem de cada item

A rastreabilidade deverá distinguir, no mínimo:

- PDF.
- QR Code.
- Manual.

Preservar os identificadores e estruturas existentes.

Não criar um novo campo incompatível quando já existir uma forma de registrar origem.

O controle deve acontecer no nível do item, especialmente quando uma separação possuir materiais com origens diferentes.

Exemplo:

| Código | Origem | Pedido |
|---|---|---|
| BPZ0043578 | PDF | VH21338 |
| BPZ0043634 | QR Code | Informado na leitura |
| BMA0001979 | Manual | Informado pelo operador |
| BMA0000856 | PDF | Pedido extraído |

Não classificar automaticamente todos os itens de um documento como PDF simplesmente porque a separação foi inicialmente gerada por importação.

# 10. CONTROLE DE DUPLICIDADES

## RF-13 — Distinguir duplicidade documental e operacional

O controle de duplicidade deverá considerar a origem e a identidade do material.

### Importação PDF

Manter o sistema atual de:

- Identidade por pedido e linha.
- Hash do PDF.
- Controle de quantidade solicitada.
- Quantidade anteriormente importada.
- Saldo importável.
- Alocação documental.
- Operações transacionais.
- Idempotência.

Aplicar as mesmas proteções tanto a BMA quanto a BPZ importados.

### Bipagem e digitação manual

Não bloquear automaticamente um material simplesmente porque seu código BMA ou BPZ já existe em outro documento.

O mesmo código pode ser utilizado legitimamente em operações diferentes.

Entretanto, verificar possíveis duplicidades considerando:

- Código.
- Projeto.
- Estação.
- Pedido.
- Linha do pedido.
- Quantidade.
- Separação atual.
- Registros documentais existentes.

## RF-14 — Alerta de possível duplicidade

Quando houver possível duplicidade entre registro manual/QR e importação PDF, apresentar um alerta claro.

Exemplo:

"Este código já possui registro para o mesmo projeto e estação. Verifique se o material já foi separado antes de continuar."

O sistema deverá diferenciar:

**Duplicidade comprovada:** bloquear conforme regras existentes.

**Possível duplicidade:** solicitar conferência do operador.

**Registro legítimo adicional:** permitir, desde que autorizado pelas regras operacionais, com justificativa e auditoria quando necessário.

Não criar um bloqueio absoluto pelo código BPZ ou BMA.

## RF-15 — Não permitir contornar saldos documentais

Registrar manualmente um BMA ou BPZ não poderá ser um mecanismo para modificar ou ampliar artificialmente a quantidade reservada em uma linha importada.

O registro manual deverá possuir identidade operacional própria.

Caso o operador esteja registrando uma quantidade complementar de um pedido já importado, sinalizar a existência da importação e orientar a utilização do saldo documental quando essa associação for necessária.

Não vincular automaticamente quantidades manuais a uma linha PDF sem uma operação explícita, validada e auditada.

# 11. INTEGRAÇÃO COM SEPARAÇÕES

## RF-16 — Preservar o fluxo existente

BMA e BPZ deverão seguir as mesmas regras de:

- Criação de separações.
- Login e permissões.
- Proprietário da separação.
- Bloqueio de separações em andamento.
- Assumir separação.
- Edição.
- Finalização.
- Organização em caixas.
- Romaneios.
- Notas fiscais.
- Etiquetas.
- Comprovantes.
- Histórico.

A modalidade de inclusão do material não deve criar um segundo processo operacional.

## RF-17 — Separações PDF

Manter:

`import_state = pending`

e as demais regras documentais existentes.

A importação não poderá permitir editar ou confirmar uma separação pendente sem iniciar corretamente o procedimento.

O desbloqueio de BPZ manual não poderá interferir nessas restrições.

# 12. ROMANEIOS E DOCUMENTOS

## RF-18 — Compatibilidade

Romaneios deverão aceitar itens BMA e BPZ provenientes de qualquer modalidade autorizada.

Preservar:

- Código.
- Quantidade.
- Projeto.
- Estação.
- Pedido de compras.
- Linha do pedido.
- Nota fiscal.
- Origem documental.
- Almoxarife.
- Data e horário.

Corrigir somente os cabeçalhos genéricos que ainda estejam identificados exclusivamente como BMA quando a coluna puder conter BPZ.

Utilizar preferencialmente:

**Código BMA/BPZ**

Não alterar desnecessariamente os modelos de impressão.

# 13. SEGURANÇA E AUDITORIA

## RF-19 — Auditoria

Registrar inclusão manual ou por QR Code de BPZ e BMA conforme os mecanismos já utilizados.

Para alertas de duplicidade confirmados pelo usuário, registrar quando aplicável:

- Usuário.
- Data/hora.
- Código.
- Projeto.
- Estação.
- Quantidade.
- Origem.
- Referência ao registro possivelmente duplicado.
- Justificativa.

Não permitir que o frontend informe uma origem PDF falsa para escapar das validações.

A associação documental deverá ser determinada e validada pelo backend.

## RF-20 — Permissões

Manter:

**Administrador:** permissões atuais.

**Operador:** permissões atuais de separação e bipagem.

**Leitor:** somente consulta.

O novo suporte a BPZ manual não pode conceder permissões adicionais ao perfil Leitor.

# 14. TESTES OBRIGATÓRIOS

## 14.1. Testes de entrada

| Cenário | Resultado |
|---|---|
| BMA por QR Code | Permitido |
| BPZ por QR Code | Permitido |
| BMA por digitação | Permitido |
| BPZ por digitação | Permitido |
| BMA por PDF compatível | Permitido |
| BPZ por PDF | Permitido |
| Código inválido | Rejeitado |
| Operador sem autorização | Rejeitado |

## 14.2. Testes do trigger PostgreSQL

Testar:

1. Criar BMA manual sem PDF.
2. Criar BPZ manual sem PDF.
3. Salvar BMA por QR Code.
4. Salvar BPZ por QR Code.
5. Editar item manual autorizado.
6. Preservar vínculo de item PDF.
7. Tentar alterar código de item PDF.
8. Tentar alterar destino protegido.
9. Tentar ultrapassar quantidade reservada.
10. Tentar remover origem PDF.
11. Tentar trocar UUID documental.
12. Tentar reutilizar UUID vinculado.
13. Tentar editar separação PDF pendente.
14. Cancelar importação autorizada.
15. Confirmar documento sem inconsistências.

Os cenários de violação documental deverão continuar bloqueados.

## 14.3. Testes de duplicidade

Testar:

- Mesmo BPZ em pedidos distintos.
- Mesmo BMA em pedidos distintos.
- Repetição de item dentro da mesma separação.
- Reimportação do mesmo PDF.
- Importação parcial.
- Complemento de quantidade.
- Alerta de possível duplicidade manual/PDF.
- Registro manual legítimo adicional.
- Clique duplo na confirmação.

## 14.4. Regressão dos 13 PDFs

Os 13 PDFs fornecidos anteriormente devem continuar apresentando:

| Indicador | Referência |
|---|---:|
| Arquivos | 13 |
| Pedidos | 13 |
| Linhas | 521 |
| Peças | 1.888 |
| Projetos | 2 |
| Estações | 8 |
| Separações previstas | 8 |
| Pendências | 0 |

Preservar também as quantidades e os destinos individuais.

Não considerar a regressão aprovada somente pela coincidência dos totais.

Comparar os registros extraídos, linha por linha, com o resultado de referência.

## 14.5. Testes com PDF BMA

Utilizar documentos reais contendo BMA quando estiverem disponíveis.

Validar:

- Reconhecimento do prefixo.
- Pedido.
- Linha.
- Quantidade.
- Projeto.
- Estação.
- Duplicidade.
- Rastreamento.
- Geração de separação.

Se os documentos BMA não estiverem disponíveis, executar testes sintéticos e registrar explicitamente que a validação com arquivos reais permanece pendente.

## 14.6. Testes de regressão operacional

Garantir que permaneçam funcionando:

- QR Code tradicional BMA.
- Importação BPZ.
- Separações abertas.
- Iniciar separação PDF.
- Assumir separação.
- Caixas físicas.
- Romaneios.
- Notas fiscais.
- E-mails.
- Comprovantes.
- Permissões.
- Consultas e relatórios.
- Histórico e auditoria.

# 15. CRITÉRIOS DE ACEITE

A correção será considerada concluída quando:

1. BMA puder ser registrado por QR Code e digitação.
2. BPZ puder ser registrado por QR Code e digitação.
3. BMA puder ser importado a partir de PDF compatível.
4. BPZ continuar sendo importado normalmente por PDF.
5. Nenhum código válido for bloqueado exclusivamente pelo prefixo.
6. A importação PDF continuar controlando saldos documentais.
7. Os vínculos documentais não puderem ser adulterados.
8. As duplicidades forem tratadas de maneira segura.
9. As permissões permanecerem inalteradas.
10. Os 13 PDFs de referência continuarem sendo extraídos corretamente.
11. Nenhuma funcionalidade existente apresentar regressões.
12. As alterações de banco forem incrementais e não destrutivas.

# 16. RESTRIÇÕES CRÍTICAS

**NÃO EXCLUIR DADOS EXISTENTES.**

**NÃO ALTERAR MIGRAÇÕES JÁ APLICADAS.**

**NÃO REMOVER O TRIGGER COMPLETO.**

**NÃO REMOVER AS PROTEÇÕES DOCUMENTAIS DE PDF.**

**NÃO PERMITIR ADULTERAR ALOCAÇÕES IMPORTADAS.**

**NÃO ALTERAR SALDOS EXISTENTES.**

**NÃO SUBSTITUIR O MOTOR DE IMPORTAÇÃO PDF SEM NECESSIDADE.**

**NÃO ALTERAR O FLUXO DE ROMANEIOS E CAIXAS FÍSICAS.**

**NÃO ALTERAR PERMISSÕES.**

**NÃO CRIAR DUPLICIDADES AUTOMÁTICAS.**

**NÃO PUBLICAR ALTERAÇÕES NÃO TESTADAS DIRETAMENTE EM PRODUÇÃO.**

# 17. ENTREGÁVEIS DO CODEX

Apresentar:

1. Diagnóstico técnico das validações existentes.
2. Arquivos modificados.
3. Nova migração SQL.
4. Nova definição da função de proteção.
5. Alterações de QR Code e digitação.
6. Alterações do extrator BMA/BPZ.
7. Validações de duplicidade.
8. Testes automatizados.
9. Evidências da regressão dos 13 PDFs.
10. Resultado dos testes manuais BMA/BPZ.
11. Orientações de implantação.
12. Eventuais limitações e pendências.

Não declarar testes ou implantações concluídos sem executá-los.

---

# 18. INSTRUÇÃO FINAL AO CODEX

Implementar a compatibilidade universal entre BMA e BPZ no Almoxarifado SMART Mondragon.

Ambos os prefixos deverão funcionar por QR Code, scanner, digitação manual e importação PDF.

Corrigir a função `smart_private.guard_pdf_document()` para eliminar a exigência obrigatória de PDF para BPZ, mantendo integralmente as proteções de alocações documentais.

Ampliar o extrator PDF para reconhecer BMA e BPZ, preservando o processamento dos pedidos existentes.

Revisar as validações do frontend, backend e PostgreSQL para garantir comportamento consistente.

Implementar prevenção segura de duplicidades, sem bloquear registros legítimos e sem permitir contornar os controles de saldo dos PDFs.

Utilizar migração incremental e testes automatizados.

Preservar todas as funcionalidades do Almoxarifado SMART, especialmente separações, caixas físicas, romaneios, notas fiscais, comprovantes, usuários e auditoria.

**A importação PDF deve ser uma alternativa operacional para grandes volumes, nunca uma obrigatoriedade determinada pelo prefixo do material.**
