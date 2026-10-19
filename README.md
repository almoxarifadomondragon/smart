# Implantação oficial — migração em homologação

Origem: commit `4cd12d23773a40da8d5a381e597c02defa565ee3`. Destino: https://almoxarifadomondragon.github.io/smart/. Consulte o relatório de migração antes do uso operacional.

# Mondragon — Almoxarifado digital

Protótipo web responsivo, em português, com a marca fornecida. JavaScript nativo; não exige instalação de pacotes. Node.js 22 ou superior.

## Testar agora

Na pasta do projeto, execute:

```powershell
node server.mjs
```

Abra http://localhost:4173 e clique em **Abrir demonstração**. O servidor atende somente neste computador. Para uso por outros dispositivos, publique a pasta `public` em uma hospedagem HTTPS.

1. Inicie uma separação. O primeiro número da demonstração é **000147**.
2. Informe projeto e estação, ou preencha-os após a primeira leitura.
3. Bipe **180$BMA0013539$25024$31133$1,00$21117$1** e pressione Enter. O sistema preenche os dados da etiqueta.
4. Confira código, projeto, estação, quantidade e caixa; confirme a peça.
5. Crie caixas e use o lápis de cada item para editar ou remanejar.
6. Revise e confirme o romaneio. Caixas vazias impedem a confirmação.
7. Consulte o histórico, baixe CSV ou use Imprimir / PDF.

No modo de demonstração, Gabriela é uma identidade fictícia, os dados ficam no armazenamento local do navegador e nenhum e-mail é enviado. A demonstração não é autenticação e não deve receber informações sensíveis. O login real usa Supabase Auth. Recarregar a página retorna ao login, mantendo os dados salvos.

## QR code e leitores

O formato real da etiqueta é composto por sete campos separados por `$`:

```text
180$BMA0013539$25024$31133$1,00$21117$1
```

| Campo | Exemplo | Tratamento |
| --- | --- | --- |
| Prefixo do QR | 180 | Preservado como metadado; significado ainda não informado |
| Código do item | BMA0013539 | Código BMA |
| Projeto | 25024 | Preenchimento automático |
| Estação | 31133 | Preenchimento automático |
| Quantidade | 1,00 | Decimal com vírgula ou ponto, até duas casas |
| Pedido de compras | 21117 | Preservado como identificador textual |
| Item do pedido | 1 | Preservado como identificador textual |

Os dados são editáveis antes de confirmar a peça. Pedido e item aparecem na lista, no romaneio, no CSV e no modelo de e-mail. O prefixo é preservado na edição e exportado no CSV. Quantidades devem ser maiores que zero e no máximo 999999. Zeros iniciais dos identificadores são preservados. Leituras incompletas são recusadas.

Códigos simples como `BMA0006765` continuam aceitos, com preenchimento manual dos demais campos. Registros antigos sem pedido continuam compatíveis. Se um dos campos de pedido for preenchido, o outro também é obrigatório.

Também são aceitos QR codes com JSON:

```json
{"bma":"BMA0006765","projeto":"Projeto X","estacao":"Estação Y","quantidade":4}
```

Ou texto rotulado:

```text
BMA: BMA0006765; Projeto: Projeto X; Estação: Estação Y; Quantidade: 4
```

Leitores USB/Bluetooth devem operar como teclado, preferencialmente com sufixo Enter. A câmera usa a API nativa BarcodeDetector e requer suporte do navegador, HTTPS (ou localhost) e permissão de câmera. Quando indisponível, o sistema orienta usar leitor ou digitação. Leitura física por câmera não foi validada neste ambiente.

## Ativar o Supabase

O projeto e a chave **publishable** fornecidos já estão configurados em `public/api.js`. Essa chave é pública por definição; autorização depende de Auth, RLS e funções do banco. Nunca coloque service_role ou a chave Resend no frontend.

1. Acesse o projeto `qrcpprvxjgcnlxyushsg` no painel Supabase.
2. O esquema atual `supabase/schema.sql` foi instalado no destino em 19/10/2026 após confirmar que estava vazio. Não execute novamente. A migração histórica do QR já está incorporada nesse esquema.
3. Em Authentication > Users, crie os usuários de teste com e-mail e senha.
4. Autorize cada usuário na tabela `app_members`, usando o UUID real de Authentication, o nome completo e o papel `operator` ou `admin`. Há um exemplo SQL comentado no fim do arquivo.
5. Entre com um administrador e cadastre os três destinatários em Configurações.

O banco gera a numeração sequencial, registra o responsável e a hora da leitura no servidor e preserva essas informações durante a edição. Apenas o proprietário edita seus rascunhos. Usuários autorizados podem consultar os romaneios da equipe. Após confirmar, o documento fica imutável pelas APIs de usuário. Os destinatários são congelados na confirmação.

## E-mail automático pelo Gmail

A função send-manifest usa Gmail SMTP com TLS obrigatório em smtp.gmail.com:465 (o Supabase bloqueia as portas 25 e 587). A autenticação do usuário, a autorização por RLS, a propriedade e a confirmação do romaneio continuam obrigatórias. O conteúdo e os destinatários vêm do banco.

Nos segredos das Edge Functions do Supabase, cadastre:

- GMAIL_USER: almoxarifadomondragon@gmail.com.
- GMAIL_APP_PASSWORD: senha de aplicativo dessa conta, criada pelo titular com verificação em duas etapas. Insira diretamente no painel; não armazene no repositório nem no frontend.
- APP_ORIGIN: https://almoxarifadomondragon.github.io (sem /smart/).

RESEND_API_KEY e MAIL_FROM não são utilizados nesta versão. O nome do remetente é Mondragon; o endereço sempre é o próprio GMAIL_USER autenticado.

Publique supabase/functions/send-manifest/index.ts pelo painel. A dependência Nodemailer está fixada na versão 10.0.14. O arquivo supabase/config.toml mantém verify_jwt=true. O navegador envia o JWT da sessão em Authorization e a chave publishable em apikey; a função também valida a sessão no Auth e aplica RLS. Validar no destino antes da homologação.

No sistema, entre como administrador e abra Configurações → Testar conexão com Gmail. Essa ação verifica conexão TLS e autenticação, sem enviar mensagem. Ao confirmar o romaneio, a aplicação tenta enviar o e-mail automaticamente. Se necessário, o botão Enviar e-mail permite nova tentativa controlada. Confira a mensagem em Enviados no Gmail e na caixa do destinatário. Aceitação SMTP não comprova entrega final.

O SMTP não oferece a chave de idempotência do Resend. Um Message-ID estável facilita rastreio, mas não garante deduplicação. Se o envio tiver resposta incerta, destinatários parcialmente recusados ou falha ao salvar o status, confira Enviados antes de tentar novamente. Envios simultâneos por várias abas não estão protegidos por trava distribuída. Não há fila de retentativas em segundo plano.

Referências: [Google: senhas de aplicativo](https://support.google.com/mail/answer/185833), [Supabase: limites de rede](https://supabase.com/docs/guides/functions/limits).

## Verificação e limites

```powershell
node --test --test-isolation=none
```

Os 16 testes originais passaram antes das alterações. Foram adicionados três testes de migração. Consulte MIGRATION-REPORT.md para distinguir testes locais e homologação real. O histórico anterior está preservado em README-PILOTO.md e não comprova a implantação oficial.

Este sistema não realiza baixa de estoque, integração ERP ou assinatura eletrônica certificada. Não possui controle de versões de edição nem fila de e-mail.
