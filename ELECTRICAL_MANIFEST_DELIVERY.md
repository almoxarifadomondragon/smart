# Elétrica e romaneios — relatório de implementação

Data: 23/11/2026. Empresa: MONDRAGON.

Aplicação oficial: https://almoxarifadomondragon.github.io/smart/

Repositório: https://github.com/almoxarifadomondragon/smart

Supabase: `qrcpprvxjgcnlxyushsg`.

## Resultado funcional

A seção Destinatários Fixos agora apresenta PCP, Almoxarifado e Elétrica. Elétrica é opcional e aceita até 30 endereços válidos, normalizados e sem duplicação na área. Adicionar, editar e remover utiliza os mesmos componentes existentes. PCP e Almoxarifado continuam obrigatórios, com seus limites atuais e sem alteração automática de endereços.

Na revisão, Material Elétrico começa desmarcado em cada novo romaneio. A escolha permanece ao voltar e editar o mesmo documento. Quando marcada, a conferência exige destinatário válido da Elétrica e apresenta os endereços adicionais em cópia. Quando desmarcada, somente a distribuição normal participa do envio.

A confirmação grava `material_eletrico`, destinatários normais em `recipient_snapshot.to`, cópias adicionais em `recipient_snapshot.cc`, lista original da área em `recipient_snapshot.electrical` e a união efetiva em `email_recipients`. Endereços que já estão em Para não são repetidos em CC. O histórico mostra a classificação e a cópia congelada; documentos antigos têm classificação false.

A conferência do servidor inclui classificação, associações de áreas, projeto, exceção e roteamento no fingerprint. Cadastro alterado após a prévia exige nova aprovação. Uma resposta antiga ou uma versão de API que não comprove a classificação não pode aprovar um romaneio elétrico.

A mesma função `send-manifest` envia o mesmo conteúdo com Para e CC. Usa exclusivamente o snapshot do documento devolvido pela reserva atômica. Não consulta o cadastro atual para adicionar destinatários em uma tentativa posterior. Nenhum segundo romaneio, serviço ou confirmação foi criado. O conteúdo do e-mail e a geração do PDF permaneceram intactos.

Comprovantes de entrega, fechamento de caixas e respectivas listas de destinatários não foram ampliados. Os testes de banco verificaram essa separação em um romaneio elétrico vinculado a caixa física.

## Arquivos

- `public/administration.js`: terceira área, validação, checkbox, estado da revisão, prévia e aprovação.
- `public/api.js`: parâmetros explícitos para os overloads compatíveis das RPCs existentes.
- `public/app.js`: consulta da classificação e cópia; confirmação em demonstração.
- `public/style.css`: checkbox acessível e organização responsiva do painel.
- `supabase/functions/send-manifest/index.ts`: roteamento Para/CC a partir do snapshot, validação de integridade e limite efetivo de 121.
- `supabase/migrations/20261123195154_electrical_manifest_recipients.sql`: migração aditiva, gerada pela CLI oficial e aplicada via SQL Editor.
- `test/administration.test.mjs`, `test/confirmation-review.test.mjs`, `test/gmail.test.mjs`: validações e regressões de interface/envio.
- `test/electrical-database.test.mjs`: integração com PostgreSQL descartável.
- `ELECTRICAL_MANIFEST_SPEC.md`: especificação fornecida.
- `ELECTRICAL_MANIFEST_DELIVERY.md`: este relatório.

Não houve alteração no extrator PDF, nas etiquetas, na leitura QR, na geração do PDF, na geração de separações ou na função de envio de comprovantes de caixa.

## Banco, compatibilidade e segurança

A categoria `Elétrica` foi acrescentada à constraint da tabela já existente `notification_recipients`. Não foi criada tabela exclusiva. A coluna `picking_documents.material_eletrico` é booleana, obrigatória e tem default false.

Foram adicionados overloads sem defaults conflitantes para `set_recipients(jsonb, boolean)`, `preview_recipients(uuid, jsonb, text, boolean)` e `finalize_picking(uuid, jsonb, text, text, boolean)`. As assinaturas antigas continuam disponíveis. Um cliente antigo que salva apenas PCP e Almoxarifado não apaga a configuração de Elétrica.

O cadastro continua exigindo administrador ativo. Revisão e confirmação exigem operador ou administrador ativo, proprietário do documento. O Leitor não altera classificação ou cadastro. `anon` não executa as novas RPCs; permissões de escrita direta não foram concedidas. RLS e autenticação permanecem habilitadas.

O limite combinado de 121 corresponde a 30 PCP + 30 Almoxarifado + 1 gestor + 30 adicionais + 30 Elétrica. A reserva existente foi adaptada apenas nesse limite. Travas de envio, status incerto, falhas parciais e reconciliação foram preservados.

A migração possui verificações transacionais de hash para abortar caso documentos ou destinatários existentes sejam alterados. Não modifica timestamps, snapshots ou resultados antigos. Não há rollback destrutivo automático; uma eventual reversão deve preservar os snapshots e documentos elétricos já confirmados.

O Advisor Center foi consultado e sinaliza as funções SECURITY DEFINER acessíveis a usuários autenticados, incluindo o novo overload de cadastro. Esse acesso é intencional na arquitetura existente e permanece protegido por verificações internas de membro ativo, perfil e propriedade, conforme a operação. Não foram removidas as verificações nem ampliadas as permissões diretas de tabelas para suprimir o aviso.

## Preservação em produção

| Verificação | Antes | Depois |
|---|---|---|
| Documentos existentes | 11 | 11 |
| Hash dos documentos, desconsiderando apenas a coluna nova | `cb236c05ff0e9a52de8c204db9b208e0` | `cb236c05ff0e9a52de8c204db9b208e0` |
| Destinatários existentes | 4 | 4 |
| Hash integral dos destinatários | `b952695e8e2090d7d6e1d212f3933010` | `b952695e8e2090d7d6e1d212f3933010` |
| Endereços de Elétrica | 0 | 0 |
| Classificação dos documentos anteriores | campo inexistente | todos false |
| RLS de destinatários | habilitada | habilitada |
| Execução anônima de prévia e confirmação novas | não disponível | negada |

Nenhum endereço de teste foi salvo no cadastro oficial. O administrador deve cadastrar os destinatários reais de Elétrica antes da primeira confirmação marcada. O fluxo comum funciona com a área vazia.

## Testes executados

`node --test --test-isolation=none`: **97 testes aprovados, zero falhas e zero testes ignorados**.

Inclui:

- Elétrica vazia, limite de 30, inválidos, duplicação normalizada e preservação das áreas obrigatórias.
- Checkbox inicialmente desmarcado, opção preservada ao retornar, resposta atrasada e API legada sem comprovação rejeitadas.
- Prévia normal sem Elétrica, prévia marcada com CC e endereço já presente em Para sem duplicação.
- Alteração do cadastro após conferência bloqueando a confirmação antiga; confirmação válida congelando a lista.
- Repetição da confirmação preservando timestamp e classificação original.
- Alteração posterior do cadastro sem modificar snapshot ou destinatários da reserva.
- Reserva duplicada bloqueada, falha Gmail, timeout, aceitação parcial e recuperação de status preservados.
- Limite completo de 121 destinatários atravessando cadastro, prévia, confirmação e reserva no PostgreSQL descartável; roteamento máximo também exercitado no handler simulado.
- Leitor e usuário anônimo impedidos de executar as novas operações; operador impedido de administrar destinatários.
- Comprovante de caixa sem cópia automática para Elétrica.
- Regressões operacionais anteriores, incluindo os 13 PDFs reais, 521 linhas e oito separações no ambiente descartável.

A sintaxe TypeScript da Edge Function foi compilada com esbuild. Os testes do handler usam transporte SMTP simulado e verificam os campos efetivos de envio. Não se afirma typecheck completo com Deno.

Homologação no navegador utilizou os componentes reais de configurações e revisão, com persistência local separada e endereços `example.invalid`. Foram conferidos salvamento e recarga, cadastro vazio, checkbox marcado/desmarcado, duplicação entre PCP e Elétrica e retorno à revisão. Áreas de conteúdo de 390 px e 768 px foram simuladas, sem transbordamento; não houve ensaio físico em celular ou tablet.

Não foram enviados e-mails de teste para destinatários reais. A função publicada respondeu 401 a chamada sem autorização. O teste pelo painel retornou a mensagem do próprio handler `Login necessário`, comprovando inicialização e preservação da autenticação. Esse teste não comprova entrega SMTP; envio e falhas foram exercitados com transporte simulado.

## Publicação

Migração e `send-manifest` implantadas no Supabase oficial pelo painel autenticado, preservando JWT e segredos existentes. O código integral do editor da função foi comparado com o artefato local antes da implantação.

Interface inicialmente publicada no commit `619e168bc3d1a70748885ca82bf84586e11027aa`.

GitHub Pages dessa publicação: https://github.com/almoxarifadomondragon/smart/actions/runs/45255584712 — concluído com sucesso.

Versão final da interface: commit 5b1df4e74b5093027f350ea1efbdb88d05a5d6c8. Essa versão exige comprovação explícita da classificação na resposta da prévia, protegendo sessões com versões antigas em cache.

Publicação final concluída com sucesso: https://github.com/almoxarifadomondragon/smart/actions/runs/45256834306

Os quatro arquivos públicos alterados foram obtidos do endereço publicado com HTTP 200 e comparados com os locais testados, com igualdade após normalização de finais de linha. Atualize a página ao iniciar o uso da nova versão.

Capturas de configurações, revisão marcada/desmarcada, largura estreita e verificação do banco acompanham os artefatos locais da entrega.

Referências de implementação: [Nodemailer — Message configuration](https://nodemailer.com/message), [Supabase — Database functions](https://supabase.com/docs/guides/database/functions).
