# ESPECIFICAÇÃO TÉCNICA E FUNCIONAL PARA CODEX
## MONDRAGON — ALMOXARIFADO SMART
### Destinatários de Elétrica e envio condicional de romaneios

**Repositório:** https://github.com/almoxarifadomondragon/smart  
**Módulos envolvidos:** Configurações, Destinatários Fixos, Romaneios e Envio de E-mails  
**Tipo:** Evolução funcional pontual  
**Prioridade:** Alta  
**Objetivo:** Incluir destinatários da área Elétrica e permitir o envio condicional de cópias dos romaneios para esses responsáveis.

---

# 1. CONTEXTO

O sistema Almoxarifado SMART Mondragon possui um cadastro de destinatários fixos para envio automático de e-mails e romaneios.

Atualmente, a tela de Configurações apresenta duas áreas:

- PCP
- Almoxarifado

Cada área permite cadastrar múltiplos endereços de e-mail, respeitando o limite atualmente estabelecido de 1 a 30 destinatários por área.

O sistema também possui uma tela de revisão de romaneios, apresentada antes da confirmação definitiva.

A nova necessidade é possibilitar que os responsáveis pela área Elétrica recebam uma cópia do romaneio **somente quando o material estiver identificado como Material Elétrico pelo usuário**.

Não é desejável que todos os romaneios sejam automaticamente encaminhados à Elétrica.

Portanto, o envio deverá ser opcional, explícito e controlado.

# 2. OBJETIVO DA IMPLEMENTAÇÃO

Implementar duas melhorias integradas:

**Melhoria A — Cadastro de destinatários**

Adicionar a área **Elétrica** na seção Destinatários Fixos, permitindo cadastrar um ou mais endereços de e-mail.

**Melhoria B — Revisão do romaneio**

Adicionar um checkbox chamado **Material Elétrico**, que permitirá incluir os destinatários cadastrados na Elétrica na distribuição do romaneio.

A regra central será:

**Checkbox desmarcado:** manter exatamente os destinatários atualmente previstos no sistema.

**Checkbox marcado:** manter os destinatários atuais e acrescentar os destinatários cadastrados na área Elétrica.

O envio para Elétrica não deverá substituir PCP, Almoxarifado, gestor do projeto nem qualquer outro destinatário já previsto pelas regras existentes.

# 3. ANÁLISE OBRIGATÓRIA ANTES DE IMPLEMENTAR

Antes de alterar o código, analisar integralmente os componentes envolvidos.

Identificar:

1. Estrutura atual da tela Configurações.
2. Componente Destinatários Fixos.
3. Modelo de persistência dos e-mails de PCP e Almoxarifado.
4. Limite atual de destinatários.
5. Validação dos endereços.
6. Processo de salvamento das configurações.
7. Funcionamento do botão Testar conexão com Gmail.
8. Estrutura de autenticação e permissões.
9. Componente da tela Revisão do Romaneio.
10. Rotina de confirmação definitiva.
11. Rotina de geração do PDF.
12. Serviço de envio de e-mails.
13. Regras atuais de destinatários.
14. Regras de inclusão de novos destinatários no romaneio.
15. Histórico de envio.
16. Mecanismo de reenvio de comprovantes e romaneios.
17. Logs de auditoria.
18. Estrutura de banco de dados e migrações.

**Obrigatório reutilizar os componentes e serviços existentes.**

Não criar um serviço paralelo de envio de e-mails.

Não substituir o fluxo atual de romaneios.

Não alterar o mecanismo de autenticação nem as permissões existentes.

Não excluir configurações ou registros já cadastrados.

# 4. NOVA ÁREA NO CADASTRO DE DESTINATÁRIOS FIXOS

## RF-01 — Incluir Elétrica

Na tela Configurações → Destinatários Fixos, adicionar uma terceira área:

**ELÉTRICA**

A estrutura visual deverá ser semelhante à utilizada em PCP e Almoxarifado.

Organização sugerida:

**Destinatários fixos**

PCP

- PCP — E-mail 1
- Botão Adicionar e-mail

Almoxarifado

- Almoxarifado — E-mail 1
- Almoxarifado — E-mail 2
- Botão Adicionar e-mail

**Elétrica**

- Elétrica — E-mail 1
- Botão Adicionar e-mail

Ao final:

- Salvar destinatários
- Testar conexão com Gmail

Não alterar a disposição das áreas existentes, salvo pequenos ajustes necessários para manter consistência visual.

## RF-02 — Quantidade de destinatários

A área Elétrica deverá utilizar o mesmo limite existente nas demais áreas.

Permitir cadastrar até 30 e-mails.

Apesar de a necessidade inicial envolver apenas um responsável, manter suporte para múltiplos destinatários.

A área poderá permanecer sem destinatários cadastrados enquanto o recurso não estiver em uso.

Não exigir o cadastro de Elétrica para continuar utilizando PCP e Almoxarifado.

## RF-03 — Adicionar e remover e-mails

Permitir:

- Adicionar novo campo.
- Editar endereço existente.
- Remover endereço.
- Salvar alterações.

Manter a mesma experiência utilizada nas demais áreas.

A remoção de um endereço não poderá excluir os destinatários de outras áreas.

Ao remover um campo, evitar alterações indevidas nos registros restantes.

## RF-04 — Validação

Aplicar as mesmas regras de validação existentes.

Validar:

- Formato do e-mail.
- Campos vazios.
- Limite de destinatários.
- Endereços repetidos.
- Persistência após salvar.

Recomenda-se normalizar espaços em branco e comparar endereços sem diferenciação entre maiúsculas e minúsculas.

Não permitir que dois cadastros idênticos na área Elétrica provoquem envios duplicados.

## RF-05 — Salvamento

O botão **Salvar destinatários** deverá salvar PCP, Almoxarifado e Elétrica, preservando os dados existentes.

Após salvar, apresentar mensagem de sucesso somente quando houver confirmação real da gravação.

Se ocorrer erro, manter os dados digitados e informar o problema.

Ao atualizar a página, os destinatários deverão ser carregados corretamente.

A inclusão da área Elétrica não poderá apagar ou sobrescrever configurações anteriores.

# 5. PERSISTÊNCIA DOS DESTINATÁRIOS

## RF-06 — Estrutura de dados

Analisar a estrutura atual utilizada para PCP e Almoxarifado.

Se o banco utiliza uma configuração centralizada, acrescentar Elétrica mantendo compatibilidade.

Se utiliza tabela de destinatários por área, adicionar a nova categoria.

Não criar uma tabela exclusiva para Elétrica se a estrutura atual já suporta diferentes áreas.

Identificador lógico sugerido:

`eletrica`

Manter os identificadores atuais de PCP e Almoxarifado.

## RF-07 — Compatibilidade

Configurações antigas que não possuírem Elétrica deverão continuar funcionando.

Na ausência do novo campo, considerar a lista de Elétrica vazia.

Não exigir atualização manual dos registros existentes.

As mudanças de banco deverão ser aditivas e reversíveis quando tecnicamente viável.

Não modificar políticas de segurança existentes sem necessidade.

# 6. NOVO CHECKBOX NA REVISÃO DO ROMANEIO

## RF-08 — Campo Material Elétrico

Na tela de **Revisão do Romaneio**, adicionar um checkbox:

**☐ Material Elétrico**

Texto auxiliar:

"Quando marcado, uma cópia do romaneio também será enviada aos destinatários cadastrados na área Elétrica."

Posicionar o campo na parte inferior da revisão, próximo aos botões:

- Voltar e editar
- Confirmar romaneio

O checkbox deverá ficar visualmente destacado, mas sem comprometer o layout atual.

## RF-09 — Estado inicial

Para um novo romaneio, o checkbox deverá iniciar sempre desmarcado.

Não marcar automaticamente com base no projeto, estação, descrição dos itens ou histórico anterior.

A classificação deverá ser definida explicitamente pelo usuário.

Isso evita encaminhamentos indevidos.

## RF-10 — Persistência durante a revisão

Se o usuário marcar Material Elétrico e clicar em Voltar e editar, preservar a seleção enquanto estiver trabalhando no mesmo romaneio.

Ao retornar à revisão, apresentar a opção anteriormente escolhida.

Não perder o estado por simples navegação entre as etapas.

Após confirmação, armazenar definitivamente a informação vinculada ao romaneio.

# 7. REGRAS DE DESTINATÁRIOS

## RF-11 — Checkbox desmarcado

Quando Material Elétrico estiver desmarcado:

- Não acrescentar destinatários da Elétrica.
- Manter integralmente os destinatários atuais.
- Preservar a lógica existente de PCP.
- Preservar a lógica existente de Almoxarifado.
- Preservar gestores e destinatários adicionais.
- Executar o envio normalmente.

Não deve haver qualquer mudança perceptível no fluxo atualmente utilizado.

## RF-12 — Checkbox marcado

Quando Material Elétrico estiver marcado:

1. Recuperar a lista de destinatários de Elétrica.
2. Validar os endereços.
3. Recuperar os destinatários normais do romaneio.
4. Acrescentar os destinatários da Elétrica.
5. Eliminar endereços repetidos.
6. Gerar o romaneio normalmente.
7. Executar o envio pelo serviço existente.
8. Registrar a classificação e os destinatários utilizados.

Os destinatários de Elétrica devem receber uma cópia adicional do mesmo romaneio.

**Não gerar um segundo romaneio e não criar uma segunda confirmação.**

## RF-13 — Campo CC

Preferencialmente, utilizar o campo **CC** para os destinatários da Elétrica.

Entretanto, verificar antes se o serviço atual utiliza destinatários To, CC ou BCC e como essa informação é tratada.

Se o envio atual não oferecer suporte adequado a CC, adaptar a função existente de forma compatível, sem criar outro mecanismo independente.

Os destinatários normais não poderão ser removidos nem substituídos.

Caso um endereço esteja em To e também na lista de Elétrica, não duplicar seu envio. Preservar preferencialmente o destinatário principal.

# 8. ELÉTRICA SEM E-MAIL CADASTRADO

## RF-14 — Validação antes da confirmação

Quando o checkbox estiver marcado, verificar se existe pelo menos um endereço válido cadastrado em Elétrica.

Se não houver, apresentar:

**"Nenhum destinatário da Elétrica está cadastrado. Cadastre um e-mail em Configurações ou desmarque Material Elétrico para continuar."**

Não permitir confirmar o romaneio com Material Elétrico marcado e sem destinatário válido.

Se o checkbox estiver desmarcado, não exigir nenhum cadastro em Elétrica.

Essa validação deverá ocorrer também no backend para impedir inconsistências.

# 9. PRÉVIA DOS DESTINATÁRIOS

## RF-15 — Conferência visual

Na tela de Revisão do Romaneio, apresentar uma pequena seção:

**Destinatários do e-mail**

Exibir os destinatários que efetivamente receberão o documento, respeitando o cadastro e as regras atuais.

Quando o checkbox estiver marcado, indicar também:

**Elétrica — cópia adicional**

A prévia deverá deixar claro quais endereços receberão o romaneio.

Não exibir e-mails que não participarão do envio.

A prévia é informativa e não substitui a validação do servidor.

No momento da confirmação, o backend deverá calcular novamente os destinatários autorizados, evitando depender exclusivamente dos valores enviados pelo navegador.

# 10. GRAVAÇÃO DA CLASSIFICAÇÃO

## RF-16 — Campo material_eletrico

Adicionar uma informação vinculada ao romaneio:

`material_eletrico`

Tipo lógico: booleano.

Valores:

- `false`: não classificado como Material Elétrico.
- `true`: classificado como Material Elétrico.

Para romaneios antigos, considerar `false` por padrão.

A migração deverá preservar todos os registros existentes.

## RF-17 — Histórico

Registrar:

- Identificador do romaneio.
- Valor de Material Elétrico.
- Usuário responsável.
- Data/hora da confirmação.
- Destinatários normais utilizados.
- Destinatários adicionais de Elétrica.
- Resultado do envio.

A classificação deve permanecer disponível para consulta posterior.

## RF-18 — Snapshot de destinatários

Salvar os endereços efetivamente utilizados no envio, ou aproveitar o mecanismo de histórico existente se já armazenar essas informações.

Exemplo:

Romaneio confirmado em 23/11/2026.

Destinatário da Elétrica no momento da confirmação:

`eletrica@empresa.com`

Posteriormente, o cadastro é alterado.

O histórico do envio original deverá continuar mostrando o endereço que efetivamente recebeu o documento naquele momento.

Não sobrescrever o histórico antigo com a configuração atual.

# 11. REENVIO DE ROMANEIOS

## RF-19 — Preservar a classificação original

Ao consultar um romaneio confirmado, apresentar a classificação registrada.

Exemplo:

**Material Elétrico: Sim**

O usuário não poderá alterar silenciosamente essa informação em um documento já confirmado.

## RF-20 — Reenvio

Se o sistema oferecer reenvio do romaneio, utilizar como padrão a classificação e os destinatários registrados na confirmação original, respeitando as regras atuais do módulo.

Não acrescentar automaticamente novos destinatários cadastrados posteriormente.

Se a função atual de reenvio permitir incluir outros endereços, preservar essa funcionalidade e registrar claramente os destinatários adicionais utilizados.

Não modificar datas e horários originais de confirmação ou entrega.

Registrar separadamente a data/hora de cada reenvio.

## RF-21 — Comprovantes de entrega

Não aplicar automaticamente a nova regra de cópia aos e-mails de comprovante de entrega, fechamento de caixa ou outras notificações.

A nova funcionalidade deverá atuar **somente no envio do romaneio**, salvo se a arquitetura atual tratar o mesmo evento como parte inseparável da confirmação.

Nesse caso, analisar o fluxo antes de alterar e evitar qualquer ampliação indevida dos destinatários.

# 12. TRATAMENTO DE ERROS DE ENVIO

## RF-22 — Falha na comunicação com Gmail

O sistema já possui integração de e-mail.

Manter o tratamento existente, acrescentando os registros necessários para identificar eventuais falhas.

Se o Gmail estiver indisponível:

- Não informar falsamente que o e-mail foi enviado.
- Não criar um segundo romaneio.
- Não duplicar a confirmação.
- Registrar o erro.
- Permitir recuperação ou reenvio conforme o fluxo já existente.

Preservar a separação entre status de confirmação do romaneio e status de envio, caso essa separação já exista no sistema.

## RF-23 — Prevenção de envios duplicados

Proteger o botão Confirmar romaneio contra cliques repetidos.

Se a mesma operação for reenviada por falha de rede, não gerar múltiplos registros ou múltiplos envios indevidos.

Reutilizar as proteções de idempotência existentes.

# 13. PERMISSÕES E SEGURANÇA

## RF-24 — Cadastro de destinatários

Manter as permissões atuais da tela Configurações.

Somente usuários autorizados poderão adicionar, modificar ou remover destinatários da Elétrica.

Não conceder novas permissões administrativas ao perfil Operador ou Leitor.

## RF-25 — Classificação do romaneio

O checkbox poderá ser alterado somente por usuários que já possuem permissão para revisar e confirmar romaneios.

O perfil Leitor poderá consultar a classificação do documento, mas não alterá-la.

Aplicar validações no backend e no banco.

# 14. INTERFACE E RESPONSIVIDADE

## RF-26 — Cadastro

A nova área Elétrica deverá apresentar a mesma identidade visual, espaçamento, tipografia e comportamento das áreas PCP e Almoxarifado.

Evitar duplicação de código.

Reutilizar componentes existentes quando possível.

## RF-27 — Revisão

O checkbox deve permanecer legível e acessível em:

- Computador.
- Tablet.
- Celular.

Não provocar rolagem horizontal ou sobreposição de componentes.

A prévia de destinatários poderá ser apresentada em uma área expansível para economizar espaço.

## RF-28 — Acessibilidade

Garantir:

- Checkbox clicável pelo texto.
- Navegação por teclado.
- Indicação visual de foco.
- Texto auxiliar legível.
- Mensagens de erro claras.
- Estado de carregamento durante confirmação.

# 15. TESTES OBRIGATÓRIOS

## 15.1. Cadastro de Elétrica

| Teste | Resultado esperado |
|---|---|
| Adicionar e-mail | Campo criado |
| Cadastrar endereço válido | Salvamento permitido |
| Cadastrar endereço inválido | Erro de validação |
| Remover endereço | Somente o endereço selecionado removido |
| Cadastrar e-mails repetidos | Duplicidade tratada |
| Atualizar página | Endereços preservados |
| Salvar Elétrica | PCP e Almoxarifado preservados |
| Elétrica vazia | Demais funcionalidades continuam operando |

## 15.2. Revisão de romaneio

| Teste | Resultado esperado |
|---|---|
| Novo romaneio | Checkbox desmarcado |
| Marcar Material Elétrico | Destinatários de Elétrica incluídos na prévia |
| Desmarcar | Elétrica removida da prévia |
| Voltar e editar | Estado preservado |
| Retornar à revisão | Estado correto |
| Marcar sem e-mail cadastrado | Confirmação bloqueada |
| Desmarcado sem cadastro | Confirmação permitida |
| Confirmar marcado | Registro salvo com `material_eletrico = true` |
| Confirmar desmarcado | Registro salvo com `material_eletrico = false` |

## 15.3. Envio de e-mails

Testar:

1. Romaneio comum.
2. Romaneio marcado como Material Elétrico.
3. Envio para um destinatário da Elétrica.
4. Envio para vários destinatários da Elétrica.
5. E-mail repetido entre PCP e Elétrica.
6. E-mail repetido entre Almoxarifado e Elétrica.
7. Destinatário adicional cadastrado no romaneio.
8. Falha na conexão Gmail.
9. Reenvio do romaneio.
10. Alteração posterior do cadastro de Elétrica.
11. Consulta do histórico original.
12. Clique duplo na confirmação.

Não enviar e-mails de testes para os destinatários reais sem um ambiente controlado ou destinatários próprios de teste.

## 15.4. Testes de regressão

Garantir que permaneçam funcionando:

- Cadastro de PCP.
- Cadastro de Almoxarifado.
- Cadastro de gestores por projeto.
- Destinatários adicionais.
- Teste de conexão Gmail.
- Geração de romaneios.
- PDFs.
- Notas fiscais.
- Caixas físicas.
- Etiquetas.
- Comprovantes.
- Reenvio de recibos.
- Histórico.
- Permissões.
- Separações manuais.
- Separações por QR Code.
- Separações criadas por importação PDF.

# 16. CRITÉRIOS DE ACEITE

A funcionalidade estará concluída quando:

1. A área Elétrica estiver disponível em Destinatários Fixos.
2. O cadastro permitir até 30 e-mails.
3. Os destinatários forem persistidos corretamente.
4. PCP e Almoxarifado permanecerem inalterados.
5. A revisão apresentar o checkbox Material Elétrico.
6. O checkbox iniciar desmarcado em novos romaneios.
7. O envio para Elétrica ocorrer exclusivamente quando marcado.
8. Os destinatários atuais continuarem recebendo normalmente.
9. Endereços repetidos não gerarem envios duplicados.
10. A confirmação for bloqueada quando o checkbox estiver marcado e não houver destinatário válido.
11. A classificação ficar registrada no histórico.
12. Os destinatários utilizados permanecerem rastreáveis.
13. O reenvio preservar as informações originais.
14. Nenhuma outra funcionalidade apresentar regressões.

# 17. RESTRIÇÕES OBRIGATÓRIAS

**NÃO EXCLUIR DADOS EXISTENTES.**

**NÃO ALTERAR OS E-MAILS ATUAIS DE PCP E ALMOXARIFADO.**

**NÃO SUBSTITUIR OS DESTINATÁRIOS EXISTENTES PELOS DA ELÉTRICA.**

**NÃO ENVIAR PARA ELÉTRICA QUANDO O CHECKBOX ESTIVER DESMARCADO.**

**NÃO MARCAR AUTOMATICAMENTE MATERIAL ELÉTRICO.**

**NÃO CRIAR UM SEGUNDO SERVIÇO DE ENVIO.**

**NÃO MODIFICAR O CONTEÚDO OU A GERAÇÃO DO PDF DO ROMANEIO.**

**NÃO ALTERAR O FLUXO DE CAIXAS FÍSICAS OU SEPARAÇÕES.**

**NÃO ALTERAR DATAS E HORÁRIOS ORIGINAIS DE DOCUMENTOS CONFIRMADOS.**

**NÃO CONCEDER NOVAS PERMISSÕES A USUÁRIOS NÃO AUTORIZADOS.**

**NÃO ALTERAR O EXTRATOR DE PEDIDOS PDF.**

# 18. ENTREGÁVEIS DO CODEX

Ao finalizar, apresentar:

1. Resumo da implementação.
2. Arquivos modificados.
3. Componentes criados.
4. Alterações de banco realizadas.
5. Regras de envio implementadas.
6. Evidências de persistência dos destinatários.
7. Evidências dos testes com checkbox marcado e desmarcado.
8. Evidências de ausência de duplicidade de e-mails.
9. Testes de regressão executados.
10. Pendências ou limitações identificadas.

Não declarar testes aprovados sem executá-los.

---

# 19. INSTRUÇÃO FINAL AO CODEX

Implementar no Almoxarifado SMART Mondragon a nova área **Elétrica** no cadastro de Destinatários Fixos e o checkbox **Material Elétrico** na tela de Revisão do Romaneio.

Quando Material Elétrico estiver marcado, acrescentar os destinatários cadastrados em Elétrica à lista normal de envio, preferencialmente em cópia (CC).

Quando estiver desmarcado, manter exatamente o comportamento atual.

Preservar PCP, Almoxarifado, gestores, destinatários adicionais e todas as regras existentes.

Registrar a classificação, os destinatários efetivamente utilizados e os resultados de envio, mantendo rastreabilidade e comportamento seguro em reenvios.

Antes de implementar, analisar a arquitetura atual e reutilizar os serviços existentes.

Priorizar alterações pontuais, compatíveis e não destrutivas.

Executar os testes necessários e apresentar evidências.

**Preservar integralmente as funcionalidades operacionais já existentes no Almoxarifado SMART Mondragon.**
