# Migração controlada Mondragon — 19/10/2026

**Em homologação. Não liberado para operação real.** Este relatório registra evidências, sem tratar testes simulados como integração real.

## Origem e integridade

Origem somente leitura: engdenysmartinez/mondragon, main, commit `4cd12d23773a40da8d5a381e597c02defa565ee3`.
Todos os 24 arquivos recuperados foram comparados com os hashes Git da árvore remota. Backup ZIP, checksum SHA256, árvore e inventário estão na pasta local migration-20261019. Nenhum dado histórico, usuário, senha ou sessão foi importado. Nenhuma alteração foi feita no ambiente original.

Dependências: JavaScript nativo, Node >=22 para servidor/testes; biblioteca QR local de Kazuhiko Arase com licença preservada; Google Fonts (com fallback Arial); Nodemailer 10.0.14 na Edge Function; GitHub Actions checkout/configure-pages/upload-pages-artifact/deploy-pages. Sem nova dependência paga.

## A. GitHub

- Destino: https://github.com/almoxarifadomondragon/smart, branch main.
- Aplicação esperada: https://almoxarifadomondragon.github.io/smart/.
- Publicação e commit remoto: em execução; não comprovados nesta versão do relatório.
- Copiados todos os arquivos originais, inclusive testes, SQL histórico, logo, biblioteca QR e workflow.
- Alterados: public/api.js (destino e consulta de membro); public/app.js (bloqueio de usuário sem vínculo, nome do banco, abertura de caixa de rascunho e limpeza local no logout); função send-manifest (origem CORS padrão); README.md (ambiente oficial).
- Adicionados: README-PILOTO.md (documentação original preservada), supabase/config.toml, supabase/inspect-destination.sql, test/migration.test.mjs e este relatório.
- Layout, estilos, QR, CSV, etiquetas e regras operacionais preservados. Links usam caminhos relativos e mantêm /smart/.

## B. Supabase

- Destino: qrcpprvxjgcnlxyushsg. Sessão oficial confirmada no painel.
- Inspeção inicial: nenhuma tabela ou função no esquema public.
- schema.sql instalado com sucesso. app_members, picking_documents e notification_recipients verificadas, cada uma com RLS=true e uma política SELECT.
- Quatro RPCs incluídas no esquema: create_picking, save_picking, finalize_picking, set_recipients. Validação funcional SQL ainda pendente de usuários.
- Autenticação: novos usuários precisam ser criados no Auth e vinculados pelo UUID. Denys autorizado pelo solicitante como administrador de implantação; almoxarifado.br previsto como administrador. Gmail remetente não recebe acesso automaticamente.
- Edge Function e segredos: implantação em execução; SMTP real ainda não validado.
- verify_jwt=true no arquivo de configuração. Auth e propriedade continuam obrigatórios dentro do handler.

## C. Gmail

Remetente oficial: almoxarifadomondragon@gmail.com. Segredos GMAIL_USER, GMAIL_APP_PASSWORD e APP_ORIGIN devem existir no destino. A senha é cadastrada pelo titular diretamente no painel. APP_ORIGIN deve ser https://almoxarifadomondragon.github.io.

O código já tenta enviar após confirmar, preservando o documento mesmo se o envio falhar. O botão permite nova tentativa. Testes locais usam mocks; não comprovam SMTP, Enviados, recebimento ou status real. Esses quatro pontos permanecem pendentes.

### Concorrência e rastreabilidade — proposta antes do uso operacional

O código original não possui trava distribuída. Duas chamadas podem enviar o mesmo documento, e falha após aceitação SMTP pode deixar status pending. Message-ID estável não garante idempotência.

Proposta: outbox transacional criada por finalize_picking com UNIQUE(document_id); claim atômico com token e estado sending; registro separado de cada tentativa com destinatários, horários e resultado sanitizado; conclusão condicionada ao token do claim. Falhas comprovadamente anteriores ao envio admitem retry com atraso. Timeout, aceitação parcial ou perda da confirmação ficam em estado uncertain, sem retry automático, até reconciliação com Gmail Enviados. Uma fila não deve prometer exactly-once via SMTP. Operadores não podem alterar estados da outbox; RPCs internas exclusivas de service_role. Não implementado nesta migração para evitar alterar o contrato operacional sem validação integrada.

## D. Testes

Baseline original: 16 executados, 16 aprovados, 0 reprovados.
Cópia migrada: 19 executados, 19 aprovados, 0 reprovados, comando `node --test --test-isolation=none`.
Incluem parser QR, decimais, zeros, pedidos, validações, CSV, etiquetas, autorização e SMTP simulados; novos testes verificam destino /smart/, vínculo app_members e abertura de caixa em rascunho.
SQL: 2 scripts originais preservados, ainda não executados no destino. Homologação autenticada (20 verificações do pedido), SMTP real e leitores físicos ainda não executados. Não contabilizados como aprovados.

## E. Comparação funcional

| Funcionalidade | Original | Migrado | Resultado |
|---|---|---|---|
| Login | Sim | Código preservado e vínculo explícito | Login real pendente |
| Nova separação | Sim | RPC e UI preservadas | SQL/E2E pendente |
| QR Code | Sim | Formatos preservados | Testes JS aprovados; leitor físico pendente |
| Edição | Sim | Preservada | Domínio testado; E2E pendente |
| Caixas | Sim | Preservadas; corrigida abertura de rascunho | Teste de regressão aprovado |
| Remanejamento | Sim | Preservado | Domínio testado; SQL pendente |
| Romaneio | Sim | Preservado | Homologação pendente |
| Histórico | Sim | Preservado | Homologação pendente |
| CSV | Sim | Preservado | Testes aprovados |
| Etiquetas | Sim | A4 paisagem e URL /smart/ preservadas | Testes aprovados; impressão pendente |
| Gmail | Previsto | Envio automático e manual preservados | Mocks aprovados; entrega pendente |
| Permissões | Sim | RLS e RPCs preservados | RLS instalado; testes com perfis pendentes |

## F. Pendências e limites reais

1. Concluir publicação, conferir workflow e site remoto; registrar commit.
2. Titular criar contas e senhas no Auth; autorizar vínculos app_members. Informar operador de teste e destinatários de homologação. Depois validar admin, operador e usuário sem vínculo.
3. Titular cadastrar senha de aplicativo Gmail; executar diagnóstico e envio real, conferir Enviados, destinatário e status no banco.
4. Executar scripts SQL com rollback e cenário autenticado de três caixas/projeto25024/estação31133, inclusive reentrada e persistência. Sequências PostgreSQL reservam números mesmo com rollback; não há garantia de numeração sem lacunas.
5. Validação física USB/Bluetooth/câmera e impressão A4 requer equipamento disponível.
6. Controle de envio concorrente proposto acima. Atualizações de rascunho possuem lock SQL, mas não versão otimista: duas abas do mesmo usuário podem sobrescrever alterações. Não existe recuperação garantida de campos ainda não salvos após fechar/recarregar a página. Sem trilha completa de versões de edição.

Limites gratuitos e quotas de SMTP devem ser acompanhados pelos administradores. Não foi ativado serviço pago. Não há SLA operacional nem homologação concluída.
