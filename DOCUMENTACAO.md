# Adami Captal — documentação técnica do portal

Documento de contexto para o projeto **Adami Captal**. Existe um portal irmão, da
**Alom Capital**, com codebase quase idêntico e projeto separado. Nada deste documento
se aplica à outra empresa sem verificação explícita.

Última atualização: 17 de setembro de 2026 · versão do portal: **2.51**

> O nome da firma se escreve **Adami Captal**, sem "i" no final. Aparece assim em toda
> a interface e em todo o código. "Adami Wealth" é grafia antiga e só sobrevive em
> textos herdados.

---

## 1. Contexto

A Adami Captal é uma gestora de patrimônio. O portal é a **plataforma administrativa
interna da firma**, o lugar onde a operação vai reunindo todas as suas ferramentas.
Não é um sistema de relatório com acessórios em volta: é um admin da empresa, e o
consolidado de carteiras é hoje o módulo mais desenvolvido dentro dele, não o propósito
único.

Isso tem consequência prática: quando surgir uma demanda nova da operação, um controle,
um cálculo, um cadastro, o caminho natural é virar **mais um módulo no portal**, e não
um sistema à parte. Trate pedidos futuros com essa premissa.

O módulo Carteiras, o mais maduro, é onde os assessores lançam mês a mês a posição das
carteiras dos clientes e geram o relatório consolidado de performance em PDF, enviado ao
cliente por e-mail.

**Emil Stade** é o fundador e é quem conduz o desenvolvimento. Ele não é técnico: não
roda comandos, não edita código. Ele descreve o problema em linguagem comum, revisa o
resultado visual e aponta o que está errado. Todo trabalho de código e publicação é
feito pelo assistente. Instruções para ele devem ser sempre clique a clique.

---

## 2. Arquitetura

**Frontend:** HTML puro, sem build, sem framework. Os arquivos ficam na raiz do
repositório e precisam permanecer lado a lado porque se referenciam por caminho
relativo:

| Arquivo | Módulo |
|---|---|
| `index.html` | **Hub de entrada** + módulo Carteiras + tela de Equipe |
| `crm.html` | CRM: jornada do cliente, negócios, carteira, Net New Money |
| `rv.html` | Mesa RV: operações de renda variável e alocações |
| `diagnostico.html` | Ferramenta Wealth Planning |
| `patrimonial.html` | Gerador de Planos Patrimoniais |
| `imobiliario.html` | Relatório Imobiliário |
| `simulador.html` | Simulador de receita RV |
| `adami_completo.sql` | Banco inteiro, portal + CRM, num arquivo só |
| `vendor/` | React, ReactDOM, jsPDF e supabase-js, servidos localmente |

**O hub é a porta da plataforma.** Depois do login, o usuário vê os cards dos módulos
agrupados em Ferramentas e Simuladores, e escolhe onde entrar. O hub existe justamente
porque a plataforma é feita para crescer em módulos.

**Como nasce um módulo novo:** um arquivo HTML próprio na raiz, no mesmo padrão visual,
mais um card no hub apontando para ele por caminho relativo. Módulos que precisarem de
dados usam o mesmo Supabase e as mesmas tabelas de identidade, para não criar uma
segunda noção de usuário dentro da mesma casa.

**Hospedagem:** HostGator (Plano M), no endereço **`adamicaptal.com.br/hub`**, desde
novembro/2026. Antes era a Vercel, que foi desligada: o wi-fi do escritório bloqueava o
endereço `.vercel.app`. O código não mudou na troca: os módulos se chamam por caminho
relativo e funcionam dentro da pasta `/hub`. A publicação é automática a cada commit na
branch `main` do GitHub `AdamiRafa/adami-wealth` (transferido de `emilstade/adami-wealth`
em novembro/2026). Detalhes na seção 10.

**Backend:** Supabase (PostgreSQL + PostgREST + Auth + Row Level Security).
Projeto ativo: `ghxjqmjtmbqzvogwzylo.supabase.co`, na conta do Rafael (organização
"Adami Wealth", plano Free) desde novembro/2026. O projeto foi transferido, não
recriado: o código continua o mesmo. A chave *publishable* vive no código
do navegador, o que é correto: a proteção real está na RLS. A chave *service_role* nunca
deve aparecer em arquivo servido pelo navegador.

**Por que HTML puro:** o projeto nasceu em React + Vite e passou os primeiros dias
quebrando no build da Vercel. Em 13/08 foi reescrito como HTML estático e nunca mais
houve falha de deploy. **Esta decisão é definitiva.** Não proponha reintroduzir
framework ou etapa de build.

O `crm.html` é a exceção aparente: ele é React, porque veio pronto de um sócio. Mas
continua sendo um arquivo HTML sem build, com as bibliotecas servidas de `vendor/` em
vez de CDN. Nenhuma etapa de compilação foi introduzida.

**Bloco `EMPRESA`:** no topo do `<script>` existe um objeto com nome da empresa,
domínio de e-mail, texto de apresentação e as chaves do Supabase. É o único trecho que
difere entre este portal e o da Alom. Logos ficam em `LOGO_AZUL` (fundo claro) e
`LOGO_BRANCO` (fundo escuro), como data URI. Portar uma melhoria de um portal para o
outro significa copiar tudo menos esse bloco e os dois logos.

---

## 3. Modelo de dados

### Portal

| Tabela | Conteúdo |
|---|---|
| `perfis` | `user_id`, `nome`, `codigo`, `admin`, `mesa_rv`, `super` |
| `clientes` | `id`, `nome`, `assessor_id` (→ auth.users), `criado_em` |
| `lancamentos` | `cliente_id`, `mes`, `ano`, `contas` (jsonb), `indicadores` (jsonb) |
| `cartas` | `mes`, `ano`, `conteudo`. O comentário é **da casa**, não do cliente |
| `auditoria` | `quando`, `usuario`, `acao`, `alvo`, `detalhe` |
| `backups` | dump completo em jsonb, **exclusivo do admin** |
| `rv_operacoes` | operações da Mesa RV, com status e desfecho |
| `rv_alocacoes` | alocação de cada cliente numa operação |
| `convites` | e-mail liberado para primeiro acesso, com os papéis já definidos |

### CRM

| Tabela | Conteúdo |
|---|---|
| `profiles` | `id`, `nome`, `role`, `status`, `produtos` |
| `leads` | jornada do cliente, contas BTG, movimentações, histórico |
| `configuracoes` | pares chave/valor, hoje a cotação do dólar |

`perfis` e `profiles` são a mesma pessoa vista de dois ângulos: `perfis.user_id` e
`profiles.id` apontam para o mesmo `auth.users`. Não existe colisão de nome entre os
dois esquemas, o que foi verificado objeto a objeto antes de juntar os dois no mesmo
projeto Supabase.

**`contas`** é um array. Cada conta: `nome`, `inst`, `saldo`, `apl`, `res`, `rendRs`,
`rendPct`, `moeda` (`"BRL"` ou `"USD"`; ausente significa BRL, por compatibilidade).

**`indicadores`** é um objeto com `cdi`, `ipca`, `ibov`, `sp500`, `poup`, `dolar`,
`ouro`, `ifix`, `ptax`, `vencimentos`, `estrategias` e `secoes`.

Gravação usa upsert com `?on_conflict=cliente_id,mes,ano` na URL. Sem isso a gravação
falha silenciosamente. Foi bug real.

---

## 4. Regras de negócio, não quebrar

**Rentabilidade % e rentabilidade R$ são campos independentes.** Aportes no meio do mês
rompem a relação matemática entre os dois, então a instituição informa o percentual e o
resultado em reais separadamente. O percentual da **carteira** é média ponderada pelo
saldo de abertura de cada conta, nunca derivado do valor em reais.

**Saldo de abertura** = saldo final − rendimento − aplicações + resgates. Quando o
resultado dá zero ou negativo, o sistema usa o saldo final como fallback e a conferência
aponta a inconsistência.

**Aplicações e resgates são movimentos, sempre positivos.** O sinal já está na fórmula
da abertura. Um resgate digitado com menos inverte a soma e erra a abertura em **duas
vezes** o valor. Os campos bloqueiam o sinal negativo de propósito.

**Onshore (R$) e offshore (US$) nunca são somados.** São dois blocos independentes, cada
um com seu total e sua ponderação. A PTAX aparece apenas como referência de conversão,
nunca para consolidar. A rentabilidade offshore é medida em dólar e portanto **não
incorpora variação cambial**, o que está escrito no rodapé do relatório e não deve ser
removido.

**Rentabilidades compostas**, nunca somadas: `comp()` multiplica `(1+p/100)`.

**Numeração de seções é dinâmica** (`nx()`), para não abrir buraco quando uma seção é
desligada.

**Indicadores de mercado são globais por mês**: ao salvar, são replicados para todos os
outros clientes com lançamento naquele mês. Apenas campos **preenchidos** sobrescrevem:
um campo em branco nunca zera o do vizinho. Vencimentos, estratégias e contas nunca são
replicados.

**Herança de contas entre meses.** Offshore e onshore são herdados do mês anterior, mas
conta que fechou o mês com saldo zero ou negativo não ressuscita. A chave de comparação
é nome + instituição, normalizada.

**Rótulos dos indicadores** refletem o benchmark realmente usado: "Inflação (IMA-B)",
"Ouro (USD)", "S&P 500 (USD)". Meses históricos ainda guardam valores antigos sob os
rótulos novos, e isso está pendente de decisão.

---

## 5. Controle de acesso

Três níveis no portal, guardados em `perfis`:

| Coluna | Na tela | O que dá |
|---|---|---|
| `super` | **master** | concede e revoga privilégio, convida, gere a equipe |
| `admin` | administrador | enxerga todos os clientes e os backups |
| `mesa_rv` | Mesa RV | escreve nas operações de renda variável |

Master manda em tudo que admin manda, e admin manda em tudo que mesa_rv manda. Hoje são
master: Emil, Bibiana e Rafael.

**A escrita direta em privilégio está fechada em três camadas**, e isso é deliberado.
Já houve a falha oposta: uma política permitia que qualquer assessor fizesse `PATCH` em
`admin = true` na própria linha e virasse administrador sozinho.

1. Permissão de coluna: pela API o autenticado só escreve em `nome`.
2. Gatilho `proteger_privilegios` em `perfis`, que recusa alteração de `admin`,
   `mesa_rv` e `super` por quem não é master. `auth.uid()` nulo, que é o caso do SQL
   Editor, continua passando: é a saída de emergência.
3. Política de RLS.

Toda mudança de permissão passa por função `security definer` (`definir_privilegio`,
`definir_papel_crm`, `definir_codigo`), que confere quem está chamando antes de gravar
e registra em `auditoria`.

**Filtrar no navegador não é segurança.** Se surgir demanda de restrição de acesso, ela
tem que ser resolvida no banco, com política, nunca escondendo elemento na tela.

### Convite e primeiro acesso

Não existe criação de conta pelo administrador, porque isso exigiria a chave
`service_role` no navegador. O fluxo é:

1. O master convida pelo hub, em Equipe → Convidar pessoa. O convite já carrega os
   papéis do portal e do CRM.
2. A pessoa entra pelo "Primeiro acesso" na tela de login e escolhe a própria senha.
3. Um gatilho em `auth.users` recusa cadastro de e-mail sem convite, cria o perfil do
   portal e o do CRM com os papéis do convite, e marca o convite como consumido.

O convite é marcado como consumido em vez de apagado, para não depender da ordem em que
os gatilhos rodam.

**Link de redefinir senha (desde a 2.85).** O modelo do e-mail aponta para
`{{ .SiteURL }}?token_hash={{ .TokenHash }}&type=recovery`, e não para o
`{{ .ConfirmationURL }}` padrão. Motivo: o link padrão gasta o código no momento em que
é aberto, e os robôs de segurança dos provedores de e-mail abrem os links para
conferir. Os registros de Auth de 05/11 mostram isso: cada link foi aberto duas vezes em
segundos, uma delas por um "Windows NT" que não era o Emil, e o clique da pessoa caía em
"link já usado". Agora o link só abre a tela de nova senha; o código vira sessão
(`POST /auth/v1/verify` com `type: recovery`) apenas no clique em "Salvar nova senha".
Se a troca falhar depois disso (ex.: senha igual à antiga), a sessão fica guardada e a
segunda tentativa não precisa do código. O formato antigo (`#access_token`) continua
aceito, e o retorno de erro do Supabase (`#error_code=otp_expired`) vira mensagem na tela
de login. O Site URL precisa continuar `https://adamicaptal.com.br/hub/`, porque o link
é montado a partir dele.

**E-mail de boas-vindas (desde a 2.84).** Logo depois do `rpc/convidar`, o portal chama a
Edge Function `enviar-convite` (código em `supabase/functions/enviar-convite/index.ts`),
que manda o e-mail pela caixa `hub@adamicaptal.com.br` da HostGator (SMTP direto, porta
465, remetente "Hub Adami"). O link do e-mail é `adamicaptal.com.br/hub/?primeiro=<e-mail>`
e só preenche a tela de Primeiro acesso: não cria conta, não carrega token e não expira.
Quem autoriza o envio é o banco: a função chama `listar_convites` com a sessão de quem
clicou, e essa função só devolve convite pendente para master. A função não usa
`service_role`. A senha da caixa fica só no Supabase, em Edge Functions → Secrets
(`SMTP_SENHA`), e a função é instalada com "Verify JWT" desligado (a conferência é a do
banco). Se o envio falhar, o convite continua valendo e a tela diz o motivo; na lista de
convites pendentes há "reenviar e-mail".

- **E-mail do domínio é Microsoft 365, não HostGator (06/11/2026).** O MX do
  `adamicaptal.com.br` é `adamicaptal-com-br.mail.protection.outlook.com`, o DMARC é
  `p=quarantine` e o SPF (`include:_spf.localservices.com.br include:spf.protection.outlook.com
  include:spf-0057a601.pphosted.com -all`) não autorizava a HostGator. Mensagem com remetente
  `@adamicaptal.com.br` saindo pelo `br542.hostgator.com.br` (108.179.252.185) falhava no SPF,
  e o Microsoft 365 mandava para quarentena: por isso o boas-vindas chegava num Gmail e o
  reset, que vai para o e-mail da empresa, "não chegava". Os acessos de "Windows NT" nos
  links eram o Safe Links do Microsoft Defender abrindo para conferir. Correção: acrescentar
  `a:br542.hostgator.com.br` ao SPF, no Editor de zona DNS do cPanel (o DNS do domínio é da
  HostGator: `ns542/ns543.hostgator.com.br`), sem tirar nada do que já está lá. Se a
  HostGator trocar o servidor da conta, o SPF precisa acompanhar.
- **nodemailer não funciona ali.** No runtime Deno das Edge Functions ele não conclui o
  TLS da porta 465 ("Greeting never received"). Por isso o SMTP é escrito à mão, com
  `Deno.connectTls`. Testado contra servidor SMTP e PostgREST falsos: envio, master/não
  master, convite inexistente, sessão expirada, senha errada, injeção de cabeçalho.
- Supabase bloqueia saída nas portas 25 e 587 das Edge Functions. Usar 465.
- Depois de mudar o modelo (`emails/_base.py`), é preciso colar o `index.ts` de novo no
  Supabase: o repositório não publica a função sozinho.

**Recuperação de senha** manda o link por `POST /auth/v1/recover`, com `redirect_to`
explícito (a origem+caminho atual) em vez de depender só do "Site URL" do painel — mas
o Supabase só segue esse `redirect_to` se a URL estiver na lista de "Redirect URLs"
em Authentication → URL Configuration. O link volta com o token no **hash** da URL
(`#access_token=...&type=recovery`); `detectarRecuperacaoNaUrl()` lê isso no boot da
página, antes de checar sessão, e mostra a tela de "defina sua nova senha"
(`viewRedefinirSenha`), que troca a senha com `PUT /auth/v1/user` autenticado pelo
token do link. Esse pedaço não existia até 09/2026 — o link chegava e não tinha pra onde
ir.

O serviço de e-mail embutido do Supabase entrega só 2 por hora, **no projeto inteiro**
(não por pessoa), e sempre responde 200 mesmo quando não entrega — por isso a tela não
promete "enviado", avisa que pode não chegar e já indica o caminho alternativo (pedir a
um master pra trocar a senha pela própria tela do Supabase: Authentication → Users →
a pessoa → Reset Password, não precisa de e-mail nenhum). Só funciona de verdade,
pros dois lados (envio e `redirect_to`), depois de configurar SMTP próprio (ver
pendência na seção 14). A URL do portal já está nas Redirect URLs desde 05/11/2026
(`https://adamicaptal.com.br/hub/**`, e Site URL `https://adamicaptal.com.br/hub/`).

**Modelos de e-mail (marca "Hub Adami"):** gerados por `emails/_base.py` a partir de um
layout único (`python3 emails/_base.py`). O de redefinir senha
(`emails/redefinir-senha.html`) é colado à mão no Supabase, em Authentication → Emails →
Templates → Reset Password, e usa as variáveis `{{ .ConfirmationURL }}` e `{{ .Email }}`.
O de boas-vindas é gravado pelo script dentro da função `enviar-convite`
(`emails/boas-vindas.html` é só a cópia de referência). O repositório é a fonte; o
painel é cópia. Os e-mails do Supabase (redefinir senha) saem pelo SMTP próprio
configurado em Authentication → Emails → SMTP Settings, com a mesma caixa
`hub@adamicaptal.com.br` e remetente "Hub Adami". O logo e
os ícones vêm de `img/`, publicada junto com o portal em `adamicaptal.com.br/hub/img/`:
cliente de e-mail não mostra imagem embutida em base64, então ela precisa estar num
endereço público. Apagar ou renomear arquivo de `img/` quebra a imagem dos e-mails já
enviados e dos próximos. `emails/` não vai para o ar.

### Login único entre portal e CRM

O portal guarda a sessão em `localStorage` sob a chave `aw_sessao`. O `crm.html` lê essa
chave e adota a sessão com `setSession`, então o login é um só. Quando o token é
renovado dentro do CRM, ele devolve a sessão atualizada ao portal.

**Recusar acesso ao CRM não é logout.** Com login único, chamar `signOut()` ali
derrubaria a pessoa do portal inteiro. Quem não tem perfil ativo no CRM vê uma tela de
bloqueio com botão para voltar ao hub, e a sessão continua de pé. Isso já foi bug.

A gestão de usuários acontece **só no hub**. A tela de equipe do CRM é somente leitura,
com um botão que leva ao hub.

---

## 6. Código do assessor

Cada pessoa em `perfis` tem um `codigo`, gerado sozinho e sequencial (A001, A002…) e
editável pelo master na tela de Equipe. Ele existe para uma coisa: **ligar a planilha de
clientes ao assessor na importação do CRM**.

O nome não serve para isso. "RAFAEL", "Rafael Souza" e "R. SOUZA" são a mesma pessoa
para quem lê e três strings diferentes para o computador, e um vínculo errado de
carteira mexe em comissão.

Na importação da base BTG, se a planilha trouxer uma coluna de código (aceita em várias
grafias: `Código do assessor`, `Cód. Assessor`, `ID Assessor`, `Codigo Assessor`), o
vínculo é **aplicado** e fica no histórico do cliente. Sem a coluna, vale a regra antiga:
o assessor que vem no arquivo do BTG gera apenas um aviso, nunca uma transferência.

A diferença é intencional. O código foi digitado por quem monta a planilha olhando a
tela de Equipe, então é instrução. O nome vindo do BTG é palpite.

Códigos que não pertencem a ninguém aparecem numa seção própria da prévia e não alteram
nada.

O índice de unicidade é sobre `upper(codigo)`, porque a comparação com a planilha também
ignora maiúscula.

---

## 7. Importação da base BTG (CRM)

Toda semana chega um export do BTG com a carteira inteira. A reconciliação é **por
conta**, nunca por nome: o export traz só o primeiro nome e há 84 primeiros nomes
cobrindo 273 contas. Nome é rótulo, conta é identidade.

A conta é normalizada antes de comparar, porque abrir o `.xlsx` no Excel e salvar come
os zeros à esquerda, e "9990002" deixaria de casar com "009990002" em silêncio.

**O que a importação não faz, por decisão:** não cria cliente que ainda não existe, não
exclui quem sumiu do arquivo, e não transfere carteira pelo nome. Os casos são
sinalizados para alguém decidir. Um export incompleto não pode derrubar a carteira do
escritório em silêncio.

**O BTG manda o saldo, nunca o movimento.** Não há como distinguir aporte novo de
valorização olhando dois arquivos. Por isso a diferença nunca vira movimentação, que
viraria captação líquida inflada pela alta da bolsa. Ela sobrescreve o saldo e, quando
não se explica pelo que o assessor lançou, gera alerta no card do cliente. A faixa é de
0,5% por importação semanal.

O que se grava é o valor **inicial**, não o saldo do arquivo: as movimentações lançadas
somam por cima e seriam contadas duas vezes.

Nada é gravado antes da prévia. A prévia não é cortesia, é o único ponto em que alguém
confere centenas de linhas antes de elas mexerem na carteira.

---

## 8. Impressão

Todos os relatórios são impressos pelo navegador, sem biblioteca de PDF.

**A armadilha central:** margem de página não se falsifica com `padding`. Padding de um
elemento que atravessa várias folhas aparece **uma vez**, no topo da primeira e no pé da
última. Da segunda folha em diante o conteúdo encosta na borda do papel e a impressora
come o que não cabe. Use `@page { margin: … }` de verdade.

Quando a capa precisa sangrar até a borda, ela ganha **página nomeada** com margem zero
(`@page capa { margin: 0 }` e `page: capa` no elemento). Margem negativa não resolve: o
navegador recorta o que passa da área útil.

**`break-inside: avoid` só vale para o que cabe numa folha.** Pedir isso a um bloco mais
alto que a página não impede a quebra, só faz o navegador quebrar onde ele quiser, em
geral no meio de um cartão. Trave a peça pequena (cartão, tabela, gráfico), deixe a
seção fluir. Antes de travar um bloco, meça a altura dele contra a área útil.

`!important` na folha de impressão sobrescreve mudança feita no CSS de tela. A capa já
ficou branca na tela e azul no PDF por isso.

---

## 9. Como o Emil trabalha

- Descreve o problema visualmente ("ficou cagado", "não tá indo"). Espera diagnóstico de
  causa raiz, não perguntas de esclarecimento técnico.
- Escreve curto, misturando português e inglês.
- Prefere receber um arquivo para baixar ou um passo para clicar.
- Cada conjunto de mudanças ganha um número de versão, visível no rodapé. O selo existe
  para ele perceber quando está vendo cache ou arquivo local.
- Scripts SQL são rodados por ele no SQL Editor do Supabase, colando o arquivo inteiro.
  O aviso "Potential issues detected" é falso positivo: a orientação é **Run without RLS**.

---

## 10. Publicação

O commit é feito pelo assistente, direto na `main`. A cada commit na `main`, o GitHub
Actions (`.github/workflows/publicar-hostgator.yml`) roda `.github/publicar-hostgator.sh`,
que copia o portal por FTPS para a pasta `/hub` do `adamicaptal.com.br` na HostGator
(Plano M). Leva um ou dois minutos. Se falhar, o erro aparece na aba **Actions** do
repositório.

- **O que vai ao ar** é uma lista positiva: `*.html`, `vendor/`, `img/` e `.htaccess`. SQL,
  documentação e qualquer arquivo novo de outro tipo ficam de fora. Módulo novo em HTML
  entra sozinho; pasta nova (imagens, por exemplo) precisa ser incluída no script.
- **A publicação apaga do servidor** o que saiu do repositório. Por isso há uma trava: se
  a pasta remota tiver conteúdo e não tiver o arquivo `.portal-adami-captal`, nada é
  enviado nem apagado. Protege o site da empresa caso a conta FTP aponte para o lugar
  errado. A conta FTP deve enxergar só a pasta do portal.
- **Acesso:** segredos `FTP_SERVIDOR`, `FTP_USUARIO` e `FTP_SENHA` em GitHub → Settings →
  Secrets and variables → Actions. Cadastrados pelo Emil direto no GitHub, nunca por
  conversa. Sem eles o workflow só avisa e não publica. `FTP_SERVIDOR` deve ser o nome do
  servidor da HostGator que o certificado cobre; o script exige criptografia e confere o
  certificado, e não deve ser afrouxado.
- **Cache:** o `.htaccess` manda `Cache-Control: no-store` (o navegador nunca guarda
  versão velha, senão o selo de versão deixa de ser confiável) e força https.
- **Supabase:** em Authentication → URL Configuration, o Site URL e as Redirect URLs
  precisam do endereço novo (`https://adamicaptal.com.br/hub/**`), senão o link de
  recuperação de senha volta para o lugar errado.
- **Estado (05/11/2026):** conta FTP `portal@adamicaptal.com.br` criada no cPanel
  (servidor `br542.hostgator.com.br`, diretório `adamicaptal.com.br/hub`), segredos
  cadastrados no GitHub, primeiro envio real concluído com sucesso (todos os HTML e
  `vendor/`, por FTPS com certificado conferido). Site URL e Redirect URLs do Supabase
  ajustados. Emil confirmou o portal abrindo e o login funcionando em
  `adamicaptal.com.br/hub`. O `vercel.json` foi apagado do repositório e o projeto na
  Vercel está sendo desligado pelo Emil.
- Existe outra conta FTP no mesmo domínio, `intranet@adamicaptal.com.br`, apontando para
  uma pasta `intranet`. Não é do portal e não foi mexida.

**Para o assistente conseguir commitar**, duas condições:

1. O Claude GitHub App precisa estar instalado em `AdamiRafa/adami-wealth`
   (`github.com/apps/claude`).
2. A sessão precisa ter nascido com esse repositório selecionado, em `claude.ai/code`.

A autorização é por sessão e vale a partir do nascimento dela. Uma sessão que começou sem
o repositório não ganha acesso depois, nem com token: as credenciais ficam fora do
ambiente e um proxy autentica por fora, então **chave de API colada na conversa não
funciona** e não deve ser pedida nem enviada.

**Isso vale até trocar de dono do repositório, também** — foi o que aconteceu em
novembro/2026: o repositório saiu de `emilstade/adami-wealth` e foi transferido pra
`AdamiRafa/adami-wealth`. A sessão que estava em andamento na hora da troca perdeu a
permissão de escrita no meio da conversa (ela nasceu amarrada ao endereço antigo) e não
teve como recuperar — nem reconectando o repositório na sessão (o ambiente organiza a
pasta pelo nome do repositório, e os dois se chamam `adami-wealth`, então não dá pra ter
os dois ligados ao mesmo tempo), nem trocando a URL remota à mão (bloqueado de propósito
pela proteção do próprio Claude Code, como contorno de permissão). A sessão antiga
continuou lendo o repositório (ele é público, e por um tempo o GitHub redireciona
sozinho do endereço antigo pro novo), mas não conseguiu mais publicar nada. Se isso
acontecer de novo — trocar o dono do repositório com uma sessão em andamento — a saída é
sempre abrir uma conversa nova em `claude.ai/code` já apontando pro endereço novo.

Sem o app instalado ou sem a sessão poder publicar, o caminho é o assistente entregar os
arquivos e o Emil subir em **Add file → Upload files** na raiz do repositório, com os
mesmos nomes.

**Nunca usar `raw.githubusercontent.com` para conferir se um commit subiu.** O CDN serve
conteúdo velho e já causou duas reversões silenciosas de trabalho publicado. Conferir
sempre pela API, decodificando o campo `content`.

---

## 11. Armadilhas já encontradas

- **Padding no lugar de margem de página.** Ver seção 8.
- **`create or replace function` não muda o tipo de retorno.** Quando uma função ganha
  coluna, é preciso `drop` antes. O `adami_completo.sql` já derruba todas as versões dos
  nomes afetados, inclusive assinaturas antigas que sobrariam como overload e deixariam
  a chamada RPC ambígua.
- **PostgREST devolve corpo vazio em 201.** Chamar `res.json()` direto estoura com
  "Unexpected end of JSON input", e a gravação parece ter falhado quando na verdade
  funcionou. Ler com `res.text()` e só então tentar `JSON.parse`.
- **Variável usada sem declaração** passa na checagem de sintaxe e só quebra em execução.
  Rodar análise de escopo (acorn + eslint-scope) antes de publicar, e **não publicar
  quando ela acusa**.
- **Bug de DOM não aparece em checagem estática.** Renomear uma classe sem atualizar quem
  a lê deixa o formulário lendo o vazio, e nenhum analisador percebe. Testar com jsdom,
  e para impressão gerar o PDF de verdade e medir.
- **Handlers inline em HTML gerado por string** são avaliados no escopo global. Índices
  de laço precisam ser interpolados (`'+i+'`), não referenciados por nome.
- **CORS pode bloquear a API de PTAX do Banco Central.** O campo é sempre editável à mão
  e mostra mensagem de falha em vez de travar.
- **Cache do navegador** engana com frequência. Sempre pedir Cmd+Shift+R e conferir o
  selo de versão antes de investigar qualquer coisa.
- **O wi-fi do escritório bloqueava `.vercel.app`** por DNS
  (`DNS_PROBE_FINISHED_NXDOMAIN`). Foi o motivo da mudança para a HostGator. Se alguém
  ainda tiver o link antigo salvo, ele não abre mais: o endereço é
  `adamicaptal.com.br/hub`.

---

## 12. Histórico de versões

**12/08** tentativa em React + Vite; sucessão de falhas de build.
**13/08** reescrita em HTML estático; Supabase; relatório com capa, carta, cinco seções
e disclaimer; login com sessão persistente.
**14/08** logo, numeração real de páginas, backup diário; hub de sistemas; adição do
Diagnóstico Patrimonial e do Relatório Imobiliário.
**16/08** renomeações e adoção da numeração 1.9.
**18/08** 1.9.x correções de gravação, offshore com PTAX, indicadores compartilhados,
benchmarks · **2.0 acesso por assessor com RLS** · 2.1 a 2.3 seções habilitáveis e sumário.
**19/08** 2.4 a 2.7 conferência de consistência, capa clara, auditoria geral ·
**2.8 nome padronizado dos arquivos baixados**.
**Setembro** correção da escalada de privilégio em `perfis`; nível master e tela de
Equipe; Mesa RV com exportação nativa em `.xlsx`; renomeação para Adami Captal;
Gerador de Planos Patrimoniais com aba imobiliária e liquidez; Ferramenta Wealth Planning
reescrita com motor de linha do tempo, objetivos recorrentes, grade de sensibilidade e
planejamento sucessório; integração do CRM com login único; consolidação de cinco
scripts SQL num só · **2.51 código do assessor e correção da impressão do Wealth Planning**.
**Outubro** Política de Alocação; cores por etapa e contraste do Painel no CRM; modal de
detalhe do CRM em duas colunas; edição/exclusão na timeline do CRM · **2.80 "Importar de
PDF" na lista de ativos das Carteiras — lê o Relatório de Performance (BTG/Necton) e o
Extrato de cliente (Sinosserra) direto do PDF, sem precisar digitar nem montar planilha** ·
**2.81 tira as janelas de 3 e 6 meses da lista de ativos (planilha, PDF e relatório
impresso) — nenhuma fonte de dado usada na importação informa essas duas janelas por
ativo, só mês/ano/12 meses/desde o início** · **2.82 conserta "Esqueci minha senha": o
link do e-mail de recuperação não tinha nenhuma tela esperando por ele, então clicar não
levava a lugar nenhum — existe a tela de "defina sua nova senha" agora** ·
**2.83 Fluxo e Captação (`fluxo.html`), fatia 1: importa a Movimentação geral do BTG,
calcula NNM/aplicações/resgates/renda passiva/caixa, tela de auditoria — ver seção 15** ·
**2.84 (05/11/2026) tela de login vira "Hub Adami"; convite manda e-mail de boas-vindas
sozinho (função `enviar-convite`, botão "reenviar e-mail"); link do e-mail abre o
Primeiro acesso já preenchido; Enter no Primeiro acesso cria a conta em vez de tentar
login; senha nova igual à antiga mostra mensagem em português** ·
**2.85 (05/11/2026) link de redefinir senha à prova de robô de e-mail: o código só é
gasto no clique em "Salvar nova senha" (`token_hash` + `POST /auth/v1/verify`); link
vencido explica na tela; mensagens do "Esqueci minha senha" em português; aviso de
sucesso em verde** ·
**2.86 (05/11/2026) "Esqueci minha senha" vira tela própria (digita o e-mail, envia,
"Confira seu e-mail"); o reset passa a sair pela função `enviar-senha` (caixa hub@, com o
erro real do servidor de e-mail na tela), com volta automática ao envio antigo enquanto a
função não estiver instalada. CRM `2026.11.05.6`: aba Agenda (seção 19), faixa "Agenda de
hoje" no Dashboard, e-mail da manhã (função `agenda-manha`) e cabeçalho do CRM cabendo no
celular** ·
**2.87 (05/11/2026) visual 2026 em tudo (seção 20): tela inicial nova do Hub com menu
lateral, números do dia, "Hoje" e Avisos da casa; login e Carteiras no estilo de vidro;
camada comum `estilo/adami-2026.css` nos 11 módulos; modo noite no Hub e no CRM. CRM
`2026.11.05.7`: abas viram menu lateral recolhível** ·
**2.89 (06/11/2026) tela de Equipe e Segurança redesenhada, legível no modo noite (antes os
campos ficavam escuros numa janela branca). CRM `2026.11.06.2`: simulando um assessor, os
contadores de Consórcio, Seguro e Agenda no menu passam a ser dele, não do escritório** ·
**2.91 (06/11/2026) segurança (seção 22): verificação em duas etapas por e-mail para todos
(código de 6 dígitos depois da senha), acesso que vence à meia-noite de Brasília, tela Segurança
com o registro de acessos, correções da varredura (Política de Alocação gravável sem login,
códigos de assessor expostos, Carta do mês com HTML perigoso, código BTG trocável pelo próprio
assessor, auditoria forjável) e cabeçalhos de segurança no servidor. CRM `2026.11.06.4`: login
só pelo Hub** ·
**2.90 (06/11/2026) menu lateral encostado na borda e mais largo (Hub e CRM); tema Dia, Noite
ou Sistema (segue o modo escuro do computador); Carteiras sempre clara, com o botão "← Hub
Adami" fixo no topo ao rolar. CRM `2026.11.06.3`: todas as fichas e a lista de clientes com
Pipe (nada de "captação nova"), Relacionamento navegável (cada número abre a lista) e
auditoria de contraste em todas as telas e tabelas, nos dois modos** ·
**2.88 (06/11/2026) tela inicial do Hub limpa: ferramentas só no menu; no meio, o dia, o
calendário e os avisos. CRM `2026.11.06.1`: arquivos na ficha do cliente (seção 21).
Wealth Planning e Planos Patrimoniais com "Salvar no CRM"**.

---

## 13. Conferência de consistência

O botão **Conferir dados**, na aba Relatório, varre todo o histórico do cliente e aponta,
agrupado por mês: saldo de abertura negativo ou zerado, percentual fora de escala,
divergência entre resultado em reais e percentual informado, campo faltando de um lado
só, abertura que não fecha com o fechamento do mês anterior, conta nova sem aplicação,
conta que sumiu sem resgate, e resultado fora do padrão histórico da própria conta.

São regras **determinísticas**, não modelo de linguagem. A decisão foi consciente: num
relatório que vai para cliente, um alerta que mostra a conta ("R$ 9.000 sobre abertura
de R$ 91.000 dá 9,89%, mas foi informado 0,50%") vale mais que um texto que às vezes
inventa. Além disso, chamar um modelo do navegador exigiria expor a chave da API.

---

## 14. Pendências

- **E-mail próprio (05/11/2026):** caixa `hub@adamicaptal.com.br` criada, SMTP do
  Supabase e função `enviar-convite` configurados; boas-vindas confirmado chegando.
  Falta colar de novo o modelo de redefinir senha da 2.85 (link com `token_hash`) e o
  Emil confirmar o reset de ponta a ponta. Se os e-mails caírem em spam, conferir SPF e
  DKIM do `adamicaptal.com.br` no Editor de zona DNS (o cPanel desse plano não mostra
  "Email Deliverability").
- **Integração com a API do BTG (decidido em 05/11/2026, aguardando acesso):** grava
  saldo, posição e movimentação direto, 8h e 18h nos dias úteis e no botão "Atualizar do
  BTG"; conta nova vira cliente ligado ao assessor pelo código do BTG; conta que some vira
  encerrada, nunca apagada; troca de assessor só pelo código; trava se uma atualização
  mexer em mais de 5% do patrimônio da casa. Falta o BTG liberar a API de parceiros.
- **Reset de senha resolvido (06/11/2026).** Confirmado pelo Emil: o "Esqueci minha senha"
  chega no Outlook. O que resolveu: SPF com `a:br542.hostgator.com.br` e o envio pela função
  `enviar-senha` (caixa hub@). O roteamento de e-mail da HostGator já estava remoto: as caixas
  antigas do domínio na HostGator (angela@, lucas.marsicano@ etc.) não recebem os e-mails do
  Hub, conferido na caixa da angela@. Não apagar o hub@ da HostGator: é ele que envia.
- **Instalado no Supabase (06/11/2026):** `instalar-novidades.sql` (agendamento "agenda-manha"
  ativo) e as funções `enviar-senha` e `agenda-manha` com Verify JWT desligado (conferido
  chamando as duas). O primeiro e-mail da manhã sai no dia útil seguinte, 6h50.
- **Outlook na Agenda:** só leitura, decidido; depende de o administrador do Microsoft 365
  registrar um aplicativo (Microsoft Graph, permissão de leitura de calendário).
- **Importador de extrato BTG** no Gerador de Planos Patrimoniais nunca foi calibrado
  contra um arquivo real. Sem ele não há enquadramento por produto.
- **IPCA contra IMA-B nos meses históricos.** Os rótulos mudaram, os valores antigos não.
- A suíte de testes usada nas auditorias não está versionada no repositório.
- **Segurança:** tokens do GitHub e chaves do Supabase já foram expostos em conversa mais
  de uma vez e precisam de revogação confirmada. Não pedir nem aceitar credencial por
  chat: ela não funciona no ambiente de execução e fica registrada no histórico.
- **Segurança 2.91/2.92 instalada em 06/11/2026 (seção 22)** pelo conector do Supabase,
  a pedido do Emil: função `codigo-acesso` (Verify JWT desligado), `agenda-manha` nova e
  `seguranca.sql` (migrações `seguranca_2_91_verificacao_por_email` e
  `seguranca_2_92_funcoes_de_gatilho`). Conferido no banco real: 22 tabelas + Storage com
  `exige_verificacao`, nenhuma tabela ou função para `anon`, simulação com master (sem código: 0
  leads; com código: 884; liberação de ontem: 0), ataques de visitante recusados. Falta no
  painel: ligar a proteção contra senhas vazadas (Authentication) e, opcional, senha mínima 8.
  Avisos que sobram no relatório de segurança do Supabase são esperados: tabelas `acesso_*`
  sem política (ninguém lê pela API, de propósito) e funções `security definer` executáveis
  por usuário logado (as RPCs do portal e as funções de permissão; todas conferem quem chama).

---

## 15. Fluxo e Captação (`fluxo.html`)

BI de captação construído a partir dos exports de movimentação do BTG, pra alimentar o
comitê de política de alocação. Acesso restrito a master (`eh_super()`), porque mostra
captação da casa inteira, de todos os assessores — não só a carteira de quem está
logado. Entra no hub com `restritoMaster:true`, que esconde o card de quem não é master
(a segurança de verdade é a RLS de `fluxo_snapshots`/`fluxo_lancamentos`, o esconder no
hub é só pra não mostrar um link morto).

**Entregue até agora (fatia 1):** importa a Movimentação geral (aba "Export" do BTG,
identificada pelo conjunto de colunas, nunca pelo nome do arquivo), normaliza a conta
pra 9 dígitos com zero-fill, calcula fluxo financeiro externo (com neutralização de
pares intra-escritório, editável na tela de Auditoria), transferência de custódia,
portabilidade de previdência, aplicações e resgates por classe, renda passiva
distribuída, caixa acumulado e um mapa geral de movimentações por
Mercado/Submercado/Lançamento. Salva em `public.fluxo_lancamentos`, um snapshot por
mês/ano, substituível (reimportar apaga e grava de novo, com registro em `auditoria`).

**Validado contra o PPTX real de outubro/2026** (que o Emil mandou como referência):
aplicações de renda fixa, fundos e renda variável bateram exatas; resgates totais,
renda passiva (até o centavo, incluindo quem reinvestiu e quem não) e caixa acumulado
também bateram. A transferência de custódia bateu com a leitura de "líquido" usada na
fórmula do NNM (não com o destaque de "só as duas contas novas" do slide, que é uma
subfatia editorial, não o total).

**Fluxo financeiro externo não reconcilia sozinho com o PPTX** (regra escrita dá
-R$ 9,97 milhões em outubro, o PPTX mostra -R$ 6,0 milhões), **e isso é proposital, não
uma pendência.** Testei filtrar automaticamente contraparte com nome de empresa
(LTDA/S.A./INSTITUTO) e o filtro pegava junto o M.H.Linden — R$ 8,35 milhões que o
próprio PPTX quer CONTADOS, é a história do mês (slide "Os Dois Eventos do Mês"). Não dá
pra distinguir "tesouraria de empresa" de "resgate real de cliente pessoa jurídica" só
pelo nome da contraparte. Por isso a tela não tenta adivinhar: a seção "Maiores
movimentações de conta corrente (não pareadas)" na Auditoria lista as entradas/saídas
não casadas por valor, e cada uma tem botão de excluir/recolocar — quem conhece o
cliente decide, transação por transação, igual já funcionava para os pares. Testei
excluindo as 5 transações da TFL DO BRASIL (identificada como provável tesouraria, bastante
entrada e saída na mesma conta no mês): o líquido muda exatamente R$ 506.352,76 (o líquido
delas) e volta ao valor original ao recolocar — mecanismo correto, decisão de negócio
em aberto com o Emil.
- **Detector de reciclagem de previdência só pega o que resgata e porta no mesmo mês
  importado.** O caso real que inspirou a regra (Maristela: portou em julho, resgatou
  em outubro, portou de volta em outubro) só é pego depois que os meses anteriores
  também estiverem salvos no banco — é inerente ao desenho (precisa de histórico), não
  uma falha da fatia 1.
- **"Aplicações totais" do card de resumo não soma exatamente igual ao número do PPTX**
  (26,8 mi contra 27,6 mi) — as 3 classes individuais (RF/Fundos/RV) batem exatas, a
  diferença está em algo não quebrado na tabela de métricas do Emil (possivelmente
  COE ou criptoativo, que não têm regra de "aplicação" escrita).

**Navegação mês a mês (entregue):** seletor no topo da tela lista os meses já salvos em
`fluxo_snapshots` (mais recente primeiro, com a contagem de lançamentos). Escolher um mês
busca `fluxo_lancamentos` paginado (o PostgREST do Supabase devolve no máximo 1000 linhas
por vez — a tela busca em lotes de 1000 até não vir mais nada) e reconstrói exatamente o
mesmo objeto que o upload de arquivo monta, rodando o motor de cálculo de novo em cima do
dado salvo. Testado ponta a ponta: importar o arquivo real de outubro/2026 (7.812 linhas),
salvar, zerar a tela, recarregar pelo seletor — todos os indicadores (NNM, fluxo
financeiro, custódia, previdência, aplicações/resgates, renda passiva, canal de fundos)
saem idênticos ao do import original. Os botões de desmarcar par/excluir transação da
Auditoria não persistem no banco (ficam só na sessão) — ao recarregar um mês salvo, eles
voltam ao estado padrão (nada desmarcado), igual a toda vez que um arquivo é importado de
novo.

**Coluna nova em `fluxo_lancamentos`: `movimentacao`.** O texto cru da coluna
"Movimentação" do export do BTG não estava sendo salvo — sem ele, recarregar um mês do
banco não conseguia reclassificar fluxo financeiro externo nem canal de fundos (as duas
seções que leem o texto da movimentação, não só Mercado/Sub Mercado/Lançamento). Se esse
SQL já foi colado antes sem essa coluna, colar de novo não quebra nada: é só um `alter
table add column if not exists`, idempotente.

**Comparativo de período (entregue):** segundo seletor no topo, habilitado quando tem um
mês carregado — mês anterior, mesmo mês do ano anterior, média dos últimos 3 ou 6 meses.
Aba nova "Comparativo" mostra uma tabela com cada indicador (NNM, fluxo financeiro,
custódia, portabilidade, aplicações e resgates por classe, renda passiva, caixa),
valor do mês atual, valor/média do período comparado, variação em R$ e em %. Busca os
meses de comparação direto do banco (com cache em memória pra não repetir a mesma
consulta) e nunca trava se faltar algum: numa média de 3 meses com só 2 salvos, calcula
com os 2 e avisa "só achei 2 de 3"; se nenhum mês necessário estiver salvo, avisa e some
pede pra importar/salvar esses meses — nunca mostra comparação incompleta sem dizer.
Validado com meses sintéticos (matemática de deslocar mês, inclusive virada de ano, e de
média com mês faltando) — ainda não dá pra validar contra o PPTX porque só outubro/2026
está salvo no banco; assim que o Emil salvar mais meses o comparativo começa a valer de
verdade.

**Gráficos (entregue):** SVG à mão, sem lib nova, mesmo padrão do `chartEvolucao` do
`index.html`. Dois gráficos na Visão Geral: série histórica de Net New Money (barra por
mês, verde quando positivo e vermelho quando negativo, eixo em zero — usa todos os meses
já salvos mais o mês em tela mesmo que ainda não esteja salvo) e destino das aplicações
do mês (barra por classe — renda fixa, fundos, renda variável, previdência). Paleta
categórica das 4 classes validada pela skill de dataviz (azul/laranja/água/amarelo, ordem
fixa, ΔE ≥ 8 contra daltonismo e ≥ 15 visão normal) — não reaproveita verde/vermelho de
positivo/negativo pra não confundir com o sinal dos cards. Testado com meses sintéticos
(inclusive NNM negativo, pra confirmar a cor e a barra pra baixo do zero) e com
screenshot real via Playwright, sem sobreposição de rótulo.

**Ofertas públicas e secundário (entregue, fatia 5 adiantada):** nova aba "Ofertas e
Secundário". Reconhece mais 3 tipos de arquivo pelas colunas, no mesmo input de upload
de sempre: ordens no secundário (intermediação de cotas de fundos — compra/venda entre
clientes/contrapartes), dashboard de ofertas públicas (histórico) e book de reservas.
Diferença importante desses 3 em relação à Movimentação geral: **cada arquivo cobre
vários meses de histórico, não um mês só** (o de ordens, por exemplo, tinha 36 meses
diferentes, de setembro/2023 a novembro/2026). Por isso a tela agrupa por mês a partir da
data de solicitação e mostra uma tabela com todos os meses encontrados de uma vez; salvar
dispara uma chamada no banco por mês (função nova `fluxo_substituir_distribuicao`, mesmo
padrão de `fluxo_substituir_mes`, mas gravando em `fluxo_distribuicao`).

No secundário, só conta como "comprado/vendido" a ordem com status `EXECUTADA` — as
outras (`CANCELADA`, `REJEITADA`, `AGUARDANDO_*`, `PARCIAL`) aparecem na contagem total
mas não entram na soma, porque não é volume de verdade. O campo "Ordem direta" do export
do BTG é salvo como veio, sem a tela tentar adivinhar se isso quer dizer CETIP direto ou
outra coisa — não dava pra confirmar o significado exato só pelo nome da coluna, e já
levou engano no passado tentar inferir regra de negócio de nome de coluna ambíguo (ver
"Fluxo financeiro externo" acima). Pendente: perguntar pro Emil o que "Ordem direta"
significa de verdade pra decidir se vira um indicador próprio.

Dashboard e book de ofertas são tratados como **duas tabelas separadas, nunca somadas**:
cobrem o mesmo processo de reserva de oferta pública por ângulos diferentes (dashboard é
o histórico completo, book parece ser um corte mais recente/operacional) e muito
provavelmente se sobrepõem. A tela avisa isso na tela em vez de arriscar contar a mesma
reserva duas vezes.

Datas desses 3 arquivos vêm em formatos diferentes mesmo dentro do mesmo arquivo (ISO com
"T", ISO com espaço, ou `DD/MM/AAAA`) e nenhuma vem como data de verdade do Excel, só
texto — por isso o parser (`parseDataFlexivel`) aceita os três formatos em vez de confiar
no `cellDates` do SheetJS.

Schema (`adami_completo.sql`, seção 8.5): `fluxo_distribuicao` ganhou duas colunas,
`tipo_operacao` e `ordem_direta` (só usadas pelo secundário — criei colunas novas em vez
de reaproveitar `modalidade`/`motivo_status` com significado trocado, pra não virar
armadilha depois). **Se o SQL já foi colado antes, precisa colar de novo** — são `alter
table add column if not exists`, não quebra nada do que já tem.

**Checklist de upload (entregue):** a área de importação virou 5 caixas de
arrastar-e-soltar, uma por tipo de arquivo (Movimentação geral, ordens no secundário,
dashboard de ofertas, book de reservas, NNM do escritório), pra o Emil sempre saber quais
planilhas levantar no mês. Cada caixa aceita qualquer um dos 5 tipos — a identificação
continua sendo só pelas colunas, então não tem problema soltar no quadrado errado. Fica
verde e mostra "mês/ano — N lançamentos" assim que reconhece alguma coisa (só nesta
sessão, não é algo salvo no banco).

**NNM do escritório (reconhecido, ainda não processado):** novo arquivo detectado pelas
colunas (Conta, Nome, Mercado, Descrição, Ativo, Quantidade, Captação, Data, Tipo,
Assessor, Escritório, ID). A coluna "Data" vem como número de série do Excel cru, não
como texto nem data de verdade — mesma armadilha de "Data Cotização" na Movimentação
geral, resolvida com `dataDeSerialExcel()` (conferido batendo exatamente com
`XLSX.SSF.format`). **De propósito, a tela só guarda o arquivo na sessão e mostra na
caixa — não calcula nada, não compara com o NNM que a Movimentação geral calcula, não
salva no banco.** O Emil pediu pra avisar quando for a hora de "imputar" esse dado; até
lá fica só reconhecido. Primeira conferência rápida feita à mão (não publicada na tela):
outubro/2026 soma R$ 32.461.433,91 de captação bruta nesse arquivo contra
R$ 31.939.268,86 do NNM calculado pela Movimentação geral — diferença de ~1,6%, esperado
dado que são metodologias diferentes, mas é o número a cruzar quando o Emil pedir pra
processar.

**Drill-down clicável em "pra onde foi"/"de onde veio" (entregue):** o Emil mandou um PDF
de referência ("Leitura de Movimentações", comitê de julho/2026) com o nível de insight
que ele quer — tabelas de concentração por produto/gestor, maiores aportes/saques,
narrativa explicando por que cada número importa. Pediu explicitamente pra navegar
clicando, não só ler números estáticos. Primeira fatia disso: as barras de "Aplicações e
resgates" agora são clicáveis — clicar numa classe (Renda fixa/Fundos/Renda
variável/Previdência) abre uma tabela agrupada pelo produto de dentro dela (Produto pra
renda fixa, Ativo pra fundos/RV/previdência — são os campos realmente preenchidos pra
cada Mercado, conferido linha a linha no arquivo real), com aplicado/resgatado/net/qtd de
contas por grupo. Clicar numa linha do grupo abre o segundo nível: os lançamentos
individuais (conta, nome, data, valor). Validado que a soma dos grupos bate exatamente
com o total já auditado da classe, e a soma dos lançamentos individuais bate com o grupo.

Também: coluna **Net** (aplicado − resgatado) e linha de Total na tabela de
aplicações/resgates, com aviso de que Net mistura dinheiro novo (NNM) com realocação
interna entre produtos — não é a mesma coisa. **Separar de verdade NNM de realocação
ainda não foi construído** — exigiria casar resgate↔aplicação por conta dentro do mesmo
mês (mesma ideia da neutralização de pares do fluxo externo, só que por cliente entre
classes de ativo, não entre contas). Fica como próximo passo claro.

**Ajustes de uso real (entregue, feedback direto do Emil depois de usar a versão
anterior):**
- **Drill-down de renda fixa virou por título, não por cliente.** O primeiro nível
  (clicar "Renda fixa") continua agrupando por Produto (CDB/LCA/LCI/...). O segundo nível
  mudou: em vez de listar os lançamentos de cada cliente, agrupa por título de verdade —
  Emissor + Indexador + Taxa (campo `Taxa Emissão`, com fallback pra `Taxa Compra`) — e
  mostra Emissor/Taxa/Vencimento/Captado/Contas/Títulos. Vencimento varia dia a dia dentro
  do mesmo título (emissão contínua do BTG), por isso virou faixa (mín–máx) em vez de uma
  data só. Fundos/RV/Previdência continuam com o segundo nível por cliente, porque ali o
  primeiro nível (Ativo = fundo/ticker) já é o produto mais específico que existe — não
  tem mais nada abaixo pra agrupar.
- **"Outras fontes do mês" aparece na Visão Geral.** Antes, importar secundário/ofertas só
  mudava a aba separada "Ofertas e Secundário" — dava a impressão de que nada mudava na
  tela principal. Agora, se o mês em tela tiver dado reconhecido nessas fontes, aparece um
  card na Visão Geral (líquido do secundário, valor obtido nas ofertas); se não tiver,
  mostra aviso explicando que precisa arrastar o arquivo certo.
- **Navegação por mês**: botões ← → do lado do seletor pra andar sequencialmente pelos
  meses salvos (desabilitam sozinhos na ponta da lista), e as barras do gráfico de série
  histórica de NNM ficam clicáveis — clicar numa barra salva pula direto pra aquele mês.
- **Ajuste visual**: números de tabela e dos cards pararam de usar fonte monoespaçada
  (ficava com cara de planilha/terminal) — viraram números normais, alinhados, em negrito
  nos cards. Títulos de seção ganharam uma linha dourada embaixo. Cards com sombra leve em
  vez de borda só, pra parecer menos "gerado por IA" e mais editorial, mais perto do
  PDF de referência que o Emil mandou.

**NNM confirmado (não mudou):** Emil achou que "fluxo financeiro é o verdadeiro NNM", mas
depois esclareceu: "NNM é o quanto teve de NET no mês = entradas − saídas". Isso bate
exatamente com a fórmula que já estava em produção (fluxo financeiro + custódia +
portabilidade — cada um já é, por si, um líquido de entradas−saídas do próprio canal).
Não mudei nada na fórmula, só o texto do card (agora diz "entradas − saídas" explícito)
pra não gerar a mesma dúvida de novo.

**Indicador novo: Total aplicado no mês.** Emil pediu explicitamente: "eu preciso saber
no comitê o quanto movimentamos no mês, total, todas aplicações, essa informação é uma
das mais importantes". Virou card novo na Visão Geral (soma de RF+Fundos+RV+Previdência)
e entrou em `indicadoresDe()`, então já aparece no comparativo de período também.

**Drill-down em renda passiva, secundário e ofertas públicas (entregue, "isso pra tudo"
— pedido do Emil de repetir o padrão de clicar-e-navegar em toda seção):**
- **Renda passiva**: clicar na seção mostra de onde veio (RF juros/amortização, RV
  rendimento/juros s.capital/dividendos/restituição, COE juros/amortização), e clicar
  numa origem mostra os lançamentos (conta, nome, ativo/emissor, data, valor).
- **Secundário**: clicar num mês mostra compra vs. venda e intermediação direta vs. não
  direta (campo "Ordem direta" do export, salvo como veio — Emil confirmou que
  secundário = cetipado), mais um ranking por fundo; clicar num fundo mostra as ordens
  individuais (conta, nome, tipo, direta, data, valor).
- **Ofertas públicas (dashboard)**: clicar num mês mostra ranking por oferta (nome,
  ativo, reservado, obtido, contas) e por assessor (campo ASSESSOR do próprio dashboard —
  é a única das 3 fontes de secundário/ofertas que tem essa coluna); clicar numa oferta
  mostra quem participou (conta, nome, assessor, reservado, obtido). Book de reservas
  ainda não ganhou esse nível de clique — fica pra próxima rodada, prioridade menor
  porque é um corte complementar ao dashboard, não independente.
- Ranking por assessor no **secundário** segue pendente: o arquivo de ordens não tem
  coluna de assessor (só conta/titular), igual a limitação que o próprio PDF do Emil
  documenta pra Movimentação geral. Precisa de um de-para conta→assessor pra destravar.

**Pendente (nessa ordem, conforme o PDF de referência do Emil):** mais seções no mesmo
estilo "tabela + leitura" do PDF — composição do dinheiro novo (de onde veio, por
prefixo), saídas e reciclagem com faixas de prazo, concentração de clientes (maiores
entradas/saídas líquidas por CLIENTE, não só por transação), caixa parado com custo de
oportunidade anualizado, teste de FGC por cliente/emissor (mesma limitação documentada no
PDF: só pega compras do mês importado), drill-down no book de reservas, de-para
conta→assessor pro secundário. Pendente de dado: câmbio (arquivo ainda não enviado),
aderência à política de alocação (precisa de uma política salva pra comparar contra).
Também pendente: decidir com o Emil como e quando usar o NNM do escritório (comparação de
referência? substitui o cálculo próprio? os dois lado a lado?).

SQL em `adami_completo.sql`, seção 8.5: tabelas `fluxo_snapshots`, `fluxo_lancamentos`,
`fluxo_distribuicao` (schema pronto pra fatia 5, ainda sem tela) e a função
`fluxo_substituir_mes`. Precisa ser colado no SQL Editor do Supabase antes do módulo
funcionar de ponta a ponta (sem isso, a tela calcula e mostra tudo, só não salva).

---

## 16. Política de Alocação (`alocacao.html`)

Ferramenta do comitê mensal: formulário à esquerda, prévia do relatório pronta pra
imprimir à direita, uma `.folha` (A4) por página.

**Histórico mensal no Supabase (entregue).** Até a versão 1.4, o estado inteiro (`EST`)
só existia no `localStorage` do navegador, sob a chave `aw_alocacao` — sem backup, sem
histórico, e o botão "Novo mês" **apagava os números do mês anterior pra sempre** (só os
textos de Objetivo/Governança/Diretrizes sobreviviam). Era por isso que o Emil perguntou
"preciso salvar o que eu tenho feito aqui? se eu imprimir funciona?" — a resposta era
"só imprimindo mesmo, não tinha outro jeito". Agora tem: tabela
`politica_alocacao_snapshots` (uma linha por mês/ano, `dados jsonb` com o `EST` inteiro)
e a função `politica_alocacao_salvar` (security definer, grava com `on conflict (mes,ano)
do update`). Botão "Salvar esta política" no topo + seletor de mês/ano pra navegar entre
os meses já salvos, mesmo padrão visual do seletor de `fluxo.html`. Aberto a qualquer
usuário logado — igual já era no localStorage, não é dado sensível de cliente.

O campo "Mês" da Capa, que era texto livre, virou `<select>` com os 12 meses — precisa
de um valor numérico confiável pra indexar a tabela, e texto livre podia vir com
abreviação, erro de digitação, etc. `numeroDoMes()` converte o nome pro número (1-12).
`localStorage` continua existindo como rascunho do navegador atual (não foi removido),
mas deixou de ser a única cópia.

**Nova página final: Ativos e Emissores Sugeridos (entregue).** Pedido direto do Emil —
uma lista de ativos/emissores de crédito privado já avaliados pelo comitê, "alocando
aqui, sem complicação esperada, high grade, triple A". Mesmo padrão de formulário e
página que "Trade Ideas do Mês" (lista de título + texto, adicionar/remover item).

**Armadilha encontrada e corrigida: `.folha` corta conteúdo sem avisar.** Cada página
impressa é uma `div.folha` com `overflow:hidden` e, dentro de `@media print`,
`height:297mm` fixo — texto que passa da altura de uma folha A4 **some silenciosamente**,
sem erro, sem scroll visível (CLAUDE.md já avisava sobre isso em geral; aqui apareceu na
prática). Testado com Playwright, forçando `media:'print'` de verdade (sem isso a
medição dá falso negativo, porque na tela o `.folha` só tem `min-height`, cresce livre e
nunca corta nada — só mediu certo depois de `page.emulateMedia({media:'print'})`): 8
itens de texto realista cabem numa página, 15 itens parecidos já cortam ~2 itens do
final, sem aviso nenhum. Como não dá pra medir isso ao vivo no navegador sem forçar o
layout de impressão (e isso é caro de fazer a cada tecla digitada), a solução foi um
orçamento de caracteres calibrado contra o teste real: acima de 1.600 caracteres
(títulos + textos somados) aparece um aviso visível no formulário — "texto longo demais
pra uma página só, confira o PDF antes de mandar pro comitê". Isso não é uma correção
perfeita (é estimativa por caractere, não medida exata do layout), mas transforma um
corte silencioso em aviso visível antes de imprimir. "Trade Ideas do Mês" tem exatamente
o mesmo risco estrutural e não ganhou o mesmo aviso ainda — fica pendente.

**Pendente:** o mesmo aviso de limite de caracteres pra "Trade Ideas do Mês" (risco
idêntico, ainda sem aviso); paginação de verdade (deixar o conteúdo fluir pra uma segunda
folha em vez de cortar) seria a correção definitiva, mas é uma mudança de arquitetura
maior — não entrou nesta rodada.

**"Alterações no Mês" automática (entregue).** Antes era um campo de texto livre, só o
que o Emil escrevesse à mão — normalmente ficava "Sem alterações no mês" por preguiça de
redigitar. Agora tem um botão, "Comparar com mês anterior e preencher", que busca no
Supabase a última política salva antes do mês em edição (acha o mês anterior mesmo com
buraco no histórico — se agosto não foi salvo, compara com julho) e escreve sozinho o que
mudou: ativo adicionado/removido/com % alterado em cada uma das três carteiras (Brasil,
Internacional, Previdência), trade idea adicionada/removida/com texto atualizado, ativo
sugerido adicionado/removido. A comparação casa por nome do ativo ou título da ideia, não
por posição na lista, pra não se confundir quando um item é inserido no meio. O texto cai
pronto no mesmo campo que já existia e continua 100% editável — dá pra completar, cortar
ou reescrever à mão antes de salvar ou imprimir, exatamente como pedido ("deixa um espaço
pra eu poder editar"). Se já tiver texto digitado ali (diferente do placeholder padrão),
pede confirmação antes de sobrescrever, pra não apagar uma observação manual sem querer.
Ganhou o mesmo aviso de limite de caracteres da página de Ativos Sugeridos (pode ficar
grande numa comparação com muita coisa nova), reaproveitando a mesma função de aviso
(`avisoCorteDePagina`) ao invés de duplicar a lógica. Testado com jsdom simulando dois
meses com carteira, trade ideas e ativos sugeridos diferentes, e com Playwright pro visual
do botão/aviso/texto gerado.

**Bug corrigido: sessão expirava e o "Salvar" travava com "JWT expired" (entregue).**
O token de acesso do Supabase dura cerca de 1 hora. Nem `fluxo.html` nem `alocacao.html`
tinham lógica pra renovar esse token sozinho — `index.html` já tinha (`renovar()`), os
outros dois não. Depois de 1h de uso contínuo, qualquer tentativa de salvar (snapshot do
fluxo, política de alocação) voltava erro `PGRST303 JWT expired` e travava o botão em
"Salvando...", sem perder o que já estava digitado (continuava no `EST`/rascunho local),
mas sem conseguir gravar no banco. Corrigido portando o mesmo padrão do `index.html` pros
dois arquivos: ao levar 401, tenta renovar o token com o `refresh_token` guardado e refaz
a chamada original uma vez, de forma transparente (sem o usuário perceber nada). Só
mostra alerta e manda pra tela de login se o `refresh_token` também já tiver expirado
(sessão realmente morta, caso raro — isso dura semanas, não horas). Testado com jsdom
simulando os dois cenários (token velho renova e reenvia sozinho; refresh também inválido
avisa e redireciona) antes de publicar.

---

**Baixar PDF direto (versão 1.8, 06/11/2026).** No Chrome do Mac do Emil, a janela de
impressão parava em "Salvando…" e o PDF de outubro nunca saía (a prévia aparecia certa, o
travamento era na gravação do arquivo pelo navegador). Novo botão **Baixar PDF** no topo:
cada folha da prévia vira uma imagem A4 (html2canvas, escala 2) e o jsPDF monta o arquivo,
baixado direto. Nome do arquivo, pedido do Emil (versão 1.9): sempre o mês da política,
`Política de Alocação Outubro-26.pdf` (hífen no lugar da barra, que não pode em nome de
arquivo); o "Imprimir" sugere o mesmo nome no "Salvar como PDF". O botão "Imprimir" continua
ao lado. Conferido página a página contra a impressão: 12 páginas A4, mesmo conteúdo, mesmas
tabelas e gráficos. O texto do PDF baixado é imagem (não dá para selecionar).

## 17. Mesa RV (`rv.html`)

**Tipo "Posição" (entregue).** Até a versão 2.78 só existia "Compra / Venda" (aba
`ordem`) para operações diretas, com alvo e stop — pensado pra uma chamada tática, não
pra só registrar que o cliente comprou ou vendeu um ativo. Pedido do Emil: um tipo mais
simples, pra quem só quer comprar/vender mesmo, sem a análise de alvo/stop. Novo tipo
"Posição" (aba entre "Compra/Venda" e "Swing Trade"): Operação (compra/venda), Preço e
Observação — o card mostra Operação, Quantidade e Preço lado a lado, e abaixo o Valor
Total (quantidade × preço) em destaque. Entra no histórico e nas estatísticas da Mesa RV
como qualquer outro tipo.

**Campo "Quantidade" ao lado de "Ativo" (entregue).** Antes não existia campo de
quantidade em nenhum tipo de operação — só preço e percentuais. Agora tem um campo
"Quantidade" na mesma linha do "Ativo" (topo do formulário, compartilhado por todos os
tipos, como pedido — "isso pra tds"). Formata em milhar enquanto digita, igual o campo de
valor alocado no Histórico. Nos tipos que já existiam (Compra/Venda, Swing Trade, Stock or
Coupon, estruturadas), a quantidade aparece como complemento na linha abaixo do ticker
(ex.: "Bradesco PN · qtd. 2.000") quando preenchida — não aparecia antes, não teve nenhum
redesenho de card pra caber. Em "Posição" ela é uma das três colunas principais, por ser
o dado central desse tipo. Fica salva em `rv_operacoes.params.quantidade` pra todo tipo de
operação, registrada e some do resumo quando o campo fica em branco (não força zero em
operação que não usa quantidade, como as estruturadas por notional).

Validado com `node --check` por bloco, acorn + eslint-scope (sem variável usada sem
declarar), Playwright (card de Posição e card de Swing Trade com a quantidade visível) e
jsdom direto no fluxo de `registrar()` (quantidade e valor total corretos no payload
salvo, pro tipo novo e pra um já existente).

---

## 18. Painel da carteira (CRM, aba Dashboard)

Desde 05/11/2026 a aba **Dashboard** do CRM abre o painel da carteira, no lugar do cockpit
puro. O levantamento que define o que entra e o que fica de fora está no documento
"Painel da Carteira: levantamento" (Claude Docs), com as decisões do Emil marcadas.

**Níveis.** Casa (só admin) → assessor → cliente → conta e ativo. O admin troca de visão
pelo seletor no topo do painel ou pelas setas, que percorrem casa e assessores; é o mesmo
`vendorFilter` do cabeçalho, então escolher um assessor liga a faixa "Simulando a visão
de". O assessor abre direto na própria carteira. O nível conta e ativo depende da API do
BTG; até lá, o cliente abre a ficha do CRM.

**Abas.** Resumo (cartões que se abrem em lista: NNM, captação bruta, saídas, em
captação, contas abertas vs. ativadas, vencimentos, dinheiro parado, PJ2, contato
atrasado, régua) · Carteira (rosca + lista que se abre, por assessor ou por segmento) ·
Assessores (na casa: tabela por assessor, clique abre o painel dele) ou Rotina do dia (no
assessor: o cockpit de antes, com as ações de concluir e marcar feito).

**Nenhuma conta própria.** O painel (`pnStats`) só junta o que `computeCockpitStats` e
`computeAssessoriaStats` já calculam. Conferido com a base de demonstração: patrimônio
onshore e offshore iguais aos indicadores, NNM da casa igual à soma dos assessores, NNM e
vencimentos de cada assessor iguais ao cockpit dele.

**Onshore e offshore não somam no painel.** O herói mostra os dois lado a lado e a rosca
pesa só o onshore. O NNM segue o card "NNM no mês" do cockpit, que converte o offshore
pela cotação: os dois mostram o mesmo número.

**Dinheiro parado** aparece desligado, dizendo que chega com a API do BTG. Decisão de
05/11/2026: quando chegar, avisa **qualquer valor** parado em conta, sem piso de valor nem
de prazo.

**Selo de versão do CRM:** `CRM_VERSAO`, no rodapé do painel. O CRM não tinha selo até
aqui.

**Segunda rodada (05/11/2026, `2026.11.05.2`), pedidos do Emil:**

- **Movimentações saíram da ficha do cliente.** O bloco virou "Carteira e pipe": mostra o
  sob gestão (onshore/offshore) e o pipe, sem "+ Registrar", sem extrato e sem os totais de
  aportes, retiradas e NNM. Decisão consciente do Emil: até a API do BTG chegar, nenhum
  aporte ou resgate novo entra no CRM, então NNM, captação bruta e saídas do painel ficam
  parados. Os lançamentos antigos continuam gravados e contando. O fluxo de captação da
  base (+ Pipe, alterar, confirmar, encerrar) ficou, porque é pipe; "confirmar captação"
  ainda grava o aporte correspondente.
- **Pipe em todos os cards** do quadro: prospect mostra o patrimônio potencial, cliente da
  base a captação nova em negociação, negócio de especialista o valor do negócio; sem nada
  em jogo, traço esmaecido.
- **Receita gerada no mês** substitui "Receita PJ2" no Dashboard: aberto, divide PJ1
  (receita da carteira no BTG, desligado até a API) e PJ2.
- **KPIs navegáveis** (`Navegavel` + `KpiTopo`): o período virou pílula no topo azul, os
  outros recortes ficam em "Mais filtros", e cada seção vira um cartão com o número de
  abertura. Clicou, abre embaixo. O painel do admin deixou o tema escuro e a coluna de
  filtros. Nenhum gráfico ou cálculo foi reescrito: o `Navegavel` só reorganiza as seções
  que já existiam. Na impressão todas as seções saem abertas (PDF conferido: 5 páginas,
  margens iguais às de antes).
- **Mesmo estilo** em Offshore (topo azul, cartões), Captados e Desqualificados (total no
  topo, grupos por mês ou por assessor que se abrem, com Histórico e Reabrir dentro) e no
  topo e nos cards do quadro de Relacionamento (só visual; colunas e arrastar iguais).
**Terceira rodada (05/11/2026, `2026.11.05.3`):**

- **Pipe em toda a carteira.** Nova regra `captaNova(lead)`: pode ter captação nova quem já
  é carteira, venha da base OU tenha sido captado. Ela substitui `clienteDaBase` em tudo que
  é pipe e captação (iniciar, confirmar, encerrar, abater, temperatura, cards, Pipe por
  temperatura). `clienteDaBase` continua sendo a regra de origem (importação). O captado
  passa a ter "+ Pipe" na ficha; `valorCaptacaoNaMoeda` lê `valorEmCaptacao` para base e
  captado; `temperaturaDe` volta a valer para captado com pipe aberto.
- **Card padronizado:** todo card tem a linha de valor (selo "Sob gestão", "Patrimônio" para
  prospect ou "Negócio" no funil de especialista; traço quando não há valor) e a linha de pipe.
- **Dashboard:** "Em captação" abre a lista de quem está em captação (mesmo cálculo do Pipe
  por temperatura).
- **KPIs, panorama fixo (`KpiPanorama` + `Arvore`):** abaixo dos cartões, sempre à vista:
  Carteira por segmento (rosca + segmento → assessor → cliente), Pipe por temperatura
  (temperatura → assessor → cliente, "Quente" já aberto) e, no admin, Ranking de assessores
  (assessor → cliente, com onshore, offshore, pipe e quente). O cliente abre a ficha. Cada
  lista tem "Baixar Excel" (uma linha por cliente; a biblioteca `vendor/xlsx` só carrega no
  clique). O panorama não vai para o PDF, que continua com as seções completas (5 páginas,
  margens iguais).

**Quarta rodada (05/11/2026, `2026.11.05.4`):**

- **Pipe com um lugar só na ficha:** o bloco "Pipe" fica no topo para todo cliente. Prospect
  tem temperatura, pipe total e em negociação; quem já é carteira (`captaNova`) tem
  temperatura e "Captação nova" com R$/US$, que grava ao sair do campo (via
  `iniciarCaptacao`, com histórico). Apagar o valor encerra a negociação
  (`encerrarCaptacao`). Com captação aberta aparecem "confirmar" e "encerrar", que abrem os
  passos na seção Carteira, mais abaixo. A seção de baixo voltou a se chamar "Carteira" e
  perdeu o "+ Pipe"; o rodapé também. `setPipe` aceita captado.
- **Observações editáveis na ficha** ("Editar" / "+ Escrever", Salvar/Cancelar), via
  `setObservacoes` no App.
- **KPIs com seletor de assessor** no topo azul (setas e lista), usando `filtros.assessor`,
  que já recortava tudo (`kpiRecorte`).
- **Todo gráfico e tabela dos KPIs e do Offshore é interativo** (`DrillProvider`,
  `DrillPainel`, receitas `DR.*`): o mouse mostra o valor (rosca muda o centro; barras,
  linhas e meses têm dica), o clique abre um painel lateral com assessor → cliente (ou
  situação → responsável → negócio), Excel e o cliente abrindo a ficha. O painel usa o mesmo
  recorte da tela (`kpiRecorte`). Ligados: roscas (segmento, produto, onshore/offshore,
  offshore por segmento), barras verticais (carteira e offshore por assessor), todas as
  barras horizontais (segmento, etapa, origem, assessor, pipe por temperatura e por
  assessor, lista de pipe, offshore, especialistas, funil, ranking, quem indicou), os
  números de abertura (total, pipe, produção, em negociação, offshore) e o gráfico mensal
  (mês → negócios). A evolução da carteira só mostra a dica (sem clique). As roscas do
  Dashboard e do panorama também respondem ao mouse e ao clique.

**Correção (05/11/2026, `2026.11.05.5`): simulação de assessor no funil de Negócios.**
Ao simular a Angela, o admin via "nenhuma venda fechada", e ela tinha fechado 8. Causa: no
funil de Negócios o responsável do negócio é o especialista; o assessor é a ORIGEM
(`origemLeadId`). O login do próprio assessor já mostrava os negócios que ele indicou, mas a
simulação (`vendorFilter` em `scopedLeads`) só olhava o responsável. Agora a simulação usa a
mesma regra do login. Também: simular um assessor leva os KPIs junto (o `kpiFiltros.assessor`
acompanha o `vendorFilter`); antes os KPIs continuavam mostrando a casa inteira durante a
simulação. Testado com 8 negócios indicados por uma assessora: login dela 8, simulação
antes 0, simulação agora 8.

- Atenção à diferença de números entre telas: o Dashboard mostra o patrimônio onshore e o
  offshore separados; o "Total da carteira" dos KPIs e do Relacionamento continua como era,
  somando o offshore pela cotação.

**Pendência encontrada no teste:** no celular (390 px) o cabeçalho do CRM (abas, seletor
de equipe, botão Equipe, nome) passa da borda e a página rola para o lado (753 px). Já era
assim antes do painel; o painel em si cabe na tela.
Resolvido na `2026.11.05.6`: no celular o cabeçalho vira uma coluna, as ferramentas quebram
linha e as abas rolam dentro da própria faixa. Medido a 390 px em todas as abas, como
admin, assessor e especialista: nenhuma passa de 390.

---

## 19. Agenda do CRM (aba própria, `2026.11.05.6`)

Pedido do Emil em 05/11/2026; protótipo aprovado no mesmo dia. Decisões:

1. Aba **Agenda** ao lado do Dashboard (nos dois funis, para todo mundo) e uma faixa
   "Agenda de hoje" no topo do Dashboard com atalho. `crm.html#agenda` abre direto nela.
2. **Head comercial (admin do CRM) e master** atribuem tarefa a qualquer pessoa e veem a
   agenda de todos ("Agenda de", com "Toda a equipe"). O assessor vê e cria só a própria.
3. **Tarefas automáticas na mesma lista**, lidas da ficha e nunca gravadas como tarefa:
   próximo contato (`proximoContato`), vencimento (alerta aberto do tipo vencimento) e
   régua de relacionamento (`reguaStatus`). Assim a ficha e a agenda não discordam.
4. **Outlook só leitura**, ainda não ligado (pendência na seção 14).
5. **Recorrência**: não repete, todo dia útil, toda semana (dias escolhidos) ou todo mês
   (dia 31 cai no último dia do mês curto). A repetição começa no dia de "data".
6. **E-mail da manhã** nos dias úteis, por volta das 7h, só para quem tem algo no dia.

**Banco (`agenda.sql`, também no fim do `adami_completo.sql`, seção 8.7).** Tabela
`tarefas` (título, tipo, cliente opcional, dono, criado_por, data, hora, repetição,
dias_semana, `concluidas` = dias já feitos, email_manha, nota). Políticas: lê quem é dono,
quem criou, admin do CRM e master; cria para si, ou para qualquer um se admin/master;
altera dono/criador/admin/master, mas só admin/master passa a tarefa para outra pessoa;
apaga quem criou, admin ou master. O gatilho `tarefas_carimbo` preenche `criado_por` com a
sessão (o navegador não escolhe) e impede quem RECEBEU uma tarefa atribuída de mudar texto,
dia ou repetição: ele só marca como feita. Testado num Postgres local com quatro perfis
(14 casos: criar para outro, ver só as suas, concluir atribuída, editar atribuída, passar
para outro, apagar atribuída, ler as tabelas internas, head vendo tudo).
`agenda_emails` (um por pessoa por dia) e `pedidos_senha` não têm política: só as funções,
com a chave de serviço, usam.

**Tela (`Agenda`, `AgendaForm`, `AgendaFaixa`, funções `ag*` no `crm.html`).** Hoje
(Atrasadas, Hoje, Próximos 7 dias, legenda), Semana (7 colunas, rola para o lado no
celular) e Mês (grade; no celular só a contagem; clique no dia lista os itens). A cor da
borda diz a origem (`AG_ORIGENS`). Concluir tarefa ligada a cliente registra a atividade na
ficha (`AG_TIPO_ATIVIDADE`, data do dia da tarefa ou hoje). Próximo contato e régua se
resolvem registrando o contato ali mesmo (texto obrigatório; o próximo contato é limpo,
o próximo se marca na ficha); vencimento é marcado como resolvido. Recorrente atrasada
aparece uma vez só (a última ocorrência não feita, até 31 dias) e deixa de ser atrasada
quando a ocorrência seguinte chega. Sem a tabela no banco, a aba avisa e mostra só o que
vem das fichas. Testado com Playwright no modo demonstração (`semearTarefasDemo`).

**E-mail da manhã (`supabase/functions/agenda-manha`).** Chamado pelo `pg_cron`
("agenda-manha", `50 9 * * 1-5` em UTC = 6h50 de Brasília) via `pg_net`. Só envia em dia
útil entre 6h e 11h de Brasília, reserva o envio em `agenda_emails` antes de mandar (não
duplica) e pula quem não tem nada. Entram as tarefas com "Incluir no e-mail da manhã" e os
três tipos da ficha; atrasadas, hoje e a prévia de amanhã (na sexta, a de segunda), até 15
por seção. As regras de régua e recorrência estão copiadas do `crm.html`: mudou lá, muda
lá. Modelo gerado por `emails/_base.py` (`emails/agenda-manha.html`, ícone
`img/icone-agenda.png`). Testado com Supabase e SMTP falsos.

**Reset de senha pela função `enviar-senha`.** Gera o código com
`/auth/v1/admin/generate_link` (que não manda e-mail) e envia pela caixa hub@, com o
modelo `emails/senha-funcao.html`. Mesma resposta exista ou não a conta; 1 pedido por
minuto e 5 por hora por e-mail, 40 por hora no total; cada pedido fica em `pedidos_senha`
com o resultado ("enviado", "sem link: User not found", "falha no envio: ..."). Se a função
não existir (404) ou estiver com Verify JWT ligado (401), o portal volta ao envio antigo
do Supabase. As duas funções novas usam a `SUPABASE_SERVICE_ROLE_KEY` que o próprio
Supabase coloca no ambiente da função; ela nunca vai ao navegador.

---

## 20. Visual 2026 (Hub, CRM e módulos)

Pedido do Emil em 05/11/2026 a partir de vídeos de painéis em vidro fosco; protótipo aprovado
no mesmo dia ("pode implementar tudo"). Princípios: vidro fosco sobre um fundo com luz suave
no azul-marinho e dourado da casa, menu lateral com seções e contadores que recolhe para os
ícones, saudação com o que pede atenção, cartões de número com selo de variação, cartões que
sobem ao passar o mouse, modo noite. Fontes e cores da marca não mudaram.

**Regra que não pode quebrar: só tela.** Todo o visual novo vive dentro de `@media screen`
(ou em classes que a impressão esconde). Uma regra de celular escrita como
`@media (max-width:900px)`, sem `screen`, também vale na impressão (a folha A4 tem menos de
900 px) e mudou o padding do conteúdo: o PDF dos KPIs passou de 5 para 6 páginas. Corrigido
para `@media screen and (max-width:900px)` e conferido: 5 páginas, mesmas margens da versão
anterior, página por página.

**CRM (`crm.html`).** `MenuLateral` substitui as abas do topo (Dashboard, Agenda com contador
do dia, Relacionamento, Offshore, KPIs, Captados, Desqualificados, Produtos no funil de
Negócios, Gestão: Atualizar base e Equipe), com o seletor Jornada/Negócios, modo noite, a
pessoa e o botão Sair. O topo vira um painel de vidro com o título e a data, e a busca e o
seletor de equipe ficam ali. Recolher o menu fica salvo (`aw_menu_curto`). No celular, o menu
vira uma faixa que rola para o lado (medido a 390 px em todas as telas, admin, assessora e
especialista). O cabeçalho estático (masthead) e o botão flutuante "Início" saem da tela: o
menu tem "Hub Adami". Modo noite: `html[data-cor="noite"]`, com as variáveis de cor
trocadas; `--navy` continua sendo o azul dos fundos, e onde ele é cor de texto há regra
própria. O painel dos KPIs do admin trava cores claras para a impressão; à noite, na tela, é
liberado.

**Hub (`index.html`).** `viewHub` reescrita: menu lateral com os sistemas por grupo (busca
que filtra menu e cartões), saudação com "N coisas pedem sua atenção" (atrasadas da Agenda +
avisos não lidos), quatro números (Agenda de hoje, Relatórios do mês = clientes com
lançamento do mês anterior, Mesa RV abertas, Avisos novos), os sistemas em cartões, "Hoje"
(a mesma regra da Agenda do CRM, só a própria pessoa: tarefas, próximo contato, vencimento e
régua) e Avisos da casa. Os números chegam depois da tela (`carregarInicio`, no máximo a cada
60 s). "Abrir a Agenda" vai para `crm.html#agenda`. A gaveta antiga (hambúrguer) saiu. Login
e o módulo Carteiras ganharam o vidro (só tela; a régua lateral flutua só acima de 900 px).

**Avisos da casa (`avisos.sql`, também na seção 8.8 do `adami_completo.sql`).** Tabelas
`avisos` e `avisos_leitura`, função `avisos_resumo()` (avisos visíveis, autor, quantos leram,
total de pessoas com perfil, se eu li) e `pode_publicar_aviso()` (administrador/master do
portal ou admin do CRM). Publica quem pode; lê todo mundo; aviso com data futura é agendado
e só quem publica vê antes. Cada um marca só a própria leitura. Testado num Postgres local:
assessora não publica, não vê o agendado, não marca leitura por outra pessoa nem de aviso
agendado, não apaga; head e master publicam.

**Módulos.** `estilo/adami-2026.css` (publicado junto: o script de publicação agora copia
`estilo/`) entra no `<head>` dos 11 módulos: fundo com luz, blocos de vidro nas classes de
cartão que cada um já usa (`.cartao`, `.bloco`, `.card`, `.pane`, `.secao`...) e o botão
"Hub Adami" em vidro. As regras usam `html body :is(...)` para vencer o estilo base sem
`!important`, então variações mais específicas do módulo (cartão colorido) continuam
valendo. Páginas de relatório (`.pagina`) ficam de fora. Os módulos não têm modo noite.
Planos Patrimoniais já rolava 26 px para o lado em 1366 px antes desta mudança (conferido
na versão anterior); não foi mexido.

**Revisão de 06/11/2026 (2.88): tela inicial limpa.** O Emil achou a tela inicial poluída: os
sistemas apareciam no menu e de novo em cartões no meio. Agora as ferramentas ficam só no
menu lateral (com a busca), e o meio tem a saudação com o resumo do dia em pílulas, o dia
(atrasadas, itens com horário, "Próximos dias"), um calendário do mês com pontinhos nos dias
que têm algo (clique no dia mostra a lista dele) e os Avisos da casa. Os quatro números e os
cartões de sistema saíram. Tudo calculado por `hbAgendaFaixa` com as mesmas regras da Agenda
do CRM.

---

## 21. Arquivos do cliente e "Salvar no CRM" (06/11/2026)

**Arquivos na ficha** (`ArquivosCliente` no `crm.html`, coluna da direita da ficha, acima de
"Atividades e histórico"). Foto, PDF, Word, Excel, PowerPoint, texto; até 25 MB cada; arrastar
ou "+ Anexar"; miniatura para foto; abrir gera link temporário de 5 minutos; excluir só quem
enviou ou o head comercial. Banco (`anexos.sql`, seção 8.9 do `adami_completo.sql`): tabela
`anexos` (cliente, nome, caminho, tamanho, tipo, origem, observação, quem e quando), bucket
privado `anexos` no Storage com limite de 25 MB e lista de tipos, pasta por cliente.
`pode_ver_lead()` repete a regra de leitura de `leads` e vale para a tabela e para os
arquivos: quem vê o cliente vê os arquivos. O registro só aceita caminho dentro da pasta do
próprio cliente. Testado num Postgres local (7 casos) e na tela em modo demonstração (envio,
miniatura, recusa de 26 MB e de .exe, exclusão).

**Salvar no CRM** (`comum/anexos.js`, publicado junto: a publicação copia `comum/`). Janela
própria: escolhe o cliente (lista da própria carteira, já marcando o cliente com o mesmo nome
do documento), o que salvar e uma observação ("Enviado ao cliente em dd/mm/aaaa"). Grava o
arquivo no Storage e a linha em `anexos` com a origem. Fala direto com a API do Supabase com a
sessão do portal e renova o token se ele venceu.
- **Planos Patrimoniais:** "Salvar no CRM do cliente" gera os dois .docx (Plano Patrimonial e
  Análise de Enquadramento, origens `plano_patrimonial` e `enquadramento`). A trava de erro de
  consistência vale aqui também.
- **Wealth Planning:** "Salvar no CRM" gera um PDF do relatório da tela (html2canvas
  `vendor/html2canvas-1.4.1.min.js` + jsPDF, carregados só no clique). Cada bloco vira imagem;
  bloco que abre página na impressão abre página no PDF; bloco maior que a folha é cortado.
  Na cópia usada para a imagem, cada gráfico SVG vira `<img>` com o tamanho da tela (SVG com
  `width:100%` saía em branco). O "Imprimir / Exportar PDF" continua igual.
- **Correção no Wealth Planning:** a rosca de uma fatia só (100%, ex.: só investimentos) não
  aparecia nem na tela: arco de 360 graus começa e termina no mesmo ponto. Agora fecha a
  0,003 rad da volta inteira.

### 21.1. Ajustes da versão 2.90 (CRM `2026.11.06.3`)

- **Menu na borda.** Em telas a partir de 901 px o menu lateral fica encostado na esquerda
  (280 px no CRM, 290 px no Hub), da altura da tela, e o conteúdo usa até 1560 px.
- **Tema Sistema.** O seletor no menu tem Dia, Noite e Sistema; `localStorage.aw_cor` guarda
  `dia`, `noite` ou `sistema`. Em Sistema, o Hub e o CRM seguem `prefers-color-scheme` e trocam
  sozinhos quando o computador muda. Menu recolhido: um botão que alterna os três.
- **Carteiras sempre clara.** Os relatórios e o PDF das carteiras foram feitos para fundo claro;
  o modo noite não se aplica ali. O botão "← Hub Adami" fica no topo da coluna e no topo fixo
  do celular, sempre visível ao rolar.
- **Pipe em todas as fichas.** Cliente da base mostra "Pipe total" (R$ ou US$) e "Pipe em
  negociação"; "Captação nova" saiu da ficha e da etiqueta de temperatura. A lista de clientes
  ganhou a coluna Pipe, com ordenação e soma no rodapé.
- **Relacionamento navegável.** Cada cartão de número, cada etapa da legenda e o "Ver lista" do
  destaque abrem o painel com os clientes daquele recorte.
- **Contraste.** Auditoria automática (texto contra o fundo real, mínimo 3,2:1, ou 2,6:1 para
  texto grande) em todas as abas do CRM nos três perfis (admin, assessor, SDR) e no Hub,
  Equipe, Segurança e Carteiras, dia e noite: zero pendências. `--ink-faint` passou de
  `#95A1B0` para `#6B7889`. PDF dos KPIs conferido de novo: 5 páginas, mesmas margens.

---

## 22. Segurança (06/11/2026, versão 2.91)

Pedido do Emil antes da integração com o BTG: verificação em duas etapas por e-mail, acesso
que vence todo dia e uma varredura de vulnerabilidades no código e no banco.

### 22.1. Varredura: o que foi achado e corrigido

Testes feitos de fora, sem login, só com a chave publicável (que está no código da página):

| Gravidade | Achado | Correção |
|---|---|---|
| Crítica | `politica_alocacao_salvar` executava para qualquer visitante: dava para gravar por cima da Política de Alocação de qualquer mês sem login (conferido com mês inválido, nada foi gravado). | A função exige login confirmado; visitante sem login não executa mais nenhuma função. |
| Alta | O Supabase dá EXECUTE de toda função nova ao papel `anon` (visitante), além do `authenticated`. `revoke ... from public` não tira isso. `codigos_assessores` devolvia os 11 assessores com o código BTG para qualquer um. | `revoke` de tudo do `anon` (tabelas, sequências, funções) e `alter default privileges` para as próximas. `codigos_assessores` exige usuário ativo. |
| Alta | Carta do mês é HTML gravado pelo editor e mostrado no relatório de todos: um texto com `<img onerror>` rodaria na tela de quem abrisse e poderia roubar a sessão (que fica no `localStorage`). | `limparHtmlCarta` (index.html) deixa só a formatação do editor, ao gravar e ao mostrar. Testado com 12 ataques conhecidos. |
| Alta | `perfis`: a permissão de coluna (só `nome`) tinha sido desfeita por um `grant update` posterior; o assessor conseguia trocar o próprio `codigo` pela API, e é o código que autoriza levar carteira na importação do BTG. | Só `nome` de novo, e o gatilho `proteger_privilegios` também barra `codigo` para quem não é master. |
| Média | Auditoria forjável: qualquer usuário gravava registro em nome de outro; administrador apagava. | Gatilho `auditoria_carimbo` grava o e-mail do token; sem UPDATE; só master apaga (o botão some para os demais). |
| Média | A verificação por aplicativo (TOTP) só existia na tela: o banco nunca exigia. E o CRM tinha login próprio. | Substituída pela verificação por e-mail, exigida pelo banco. CRM sem sessão manda para o Hub. |
| Média | Servidor sem cabeçalhos de segurança (clickjacking, política de conteúdo). | `.htaccess`: HSTS, nosniff, X-Frame-Options, Referrer-Policy, Permissions-Policy e Content-Security-Policy. |
| Baixa | `agenda-manha` (sem login, de propósito) respondia com os nomes da equipe; `configuracoes` sem `enable row level security` no arquivo; nomes vindos da planilha do BTG dentro de `onclick` com aspas frágeis (fluxo.html). | Resposta só com contagens (detalhe nos Logs); RLS ligada; `jsArg`/`jsStr` (JSON.stringify + esc). |

Sem achado: nenhuma tabela entrega linha para visitante; histórico do git sem segredo; `.sql`,
`.md` e `error_log` não são servidos; bucket `anexos` privado; `enviar-senha` já tinha limite
e resposta igual para conta existente ou não.

### 22.2. Verificação em duas etapas por e-mail

1. Senha no Hub (`/auth/v1/token`). A sessão fica marcada `login_dia` = hoje, `dia` = vazio.
2. `rpc/estado_acesso`: se a sessão já está liberada, entra. Se a função não existe (banco
   sem o `seguranca.sql`), entra como antes.
3. Função `codigo-acesso` (Edge Function, Verify JWT desligado): confere o token em
   `/auth/v1/user`, chama `acesso_novo_codigo` com a chave de serviço (só ela executa) e manda
   o e-mail pela caixa hub@. O código nunca volta ao navegador. Limites no banco: 1 código a
   cada 30 s, 8 por hora; código vale 10 minutos; 5 erros invalidam o código; 10 erros em
   30 minutos bloqueiam a conta por 30 minutos. Só o hash (SHA-256 com a sessão) é guardado.
4. A pessoa digita; `rpc/verificar_codigo` confere e grava `acesso_sessoes` (sessão do token,
   `session_id` do JWT, válida só no dia de Brasília). O Hub grava `dia` = hoje em `aw_sessao`.

**Quem protege é o banco**, não a tela: `acesso_liberado()` entra como política
**restritiva** `exige_verificacao` em todas as tabelas com RLS (soma-se às políticas que já
existiam, não troca nenhuma) e em `storage.objects`; e as funções de permissão (`eh_super`,
`eh_admin`, `is_admin`, `is_ativo`, `pode_editar_rv`) passaram a exigir a sessão liberada, o que
cobre as funções `security definer` que não passam pela RLS. Um token roubado de outra sessão,
outro aparelho ou de ontem não lê nada. Testado no Postgres local com o banco inteiro.

**Saída de emergência** (e-mail fora do ar, ninguém entra): no SQL Editor,
`update public.acesso_config set exigir_codigo = false;` e depois `= true`.

### 22.3. Acesso que vence todo dia

- O agendamento `acesso-virada` (pg_cron, 3h01 UTC = 0h01 de Brasília) apaga as sessões de
  login (`auth.sessions`, o que invalida os tokens de renovação), as liberações do dia anterior
  e os códigos velhos. O registro de acessos fica 400 dias.
- Mesmo sem o agendamento, a liberação só vale no dia em que foi feita.
- Na tela: `comum/sessao.js`, no `<head>` de todo módulo, manda para o Hub quem não tem o
  código de hoje, a cada minuto e ao voltar para a aba. O Hub mostra "Por segurança, o acesso
  ao Hub vale até a meia-noite". Quem recarrega a página antes de digitar o código volta para a
  tela do código.
- `guardarSessao` dos módulos (alocacao, fluxo, rv) e do Hub preserva `dia` e `login_dia`
  quando o token é renovado: sem isso, a primeira renovação mandaria a pessoa para o login.

### 22.4. Tela Segurança (menu do Hub)

Mostra a verificação ativa, os últimos 40 acessos da pessoa (`meus_acessos`: entrou, código
enviado, código errado, bloqueado, com aparelho e IP), o botão **Sair de todos os aparelhos**
(`/auth/v1/logout?scope=global`, registrado) e, para master, os acessos da equipe
(`acessos_equipe`, últimos 300).

### 22.5. Política de conteúdo (Content-Security-Policy)

Script só do próprio Hub (`'unsafe-inline'` continua porque o portal usa `onclick` em HTML
gerado por texto), conexões só com o Supabase (https e wss) e com o Banco Central (PTAX),
nenhuma moldura de outro site. Conferido com Playwright, servindo os cabeçalhos do
`.htaccess`: os 13 módulos abrem sem bloqueio, e Baixar PDF (Política), PPTX (Imobiliário),
modelo xlsx e docx (Patrimonial) geram o arquivo. **Módulo novo que chame outro endereço
precisa entrar no `connect-src` do `.htaccess`.**

### 22.6. Regras daqui para frente

- **Tabela nova com RLS:** criar também a política restritiva `exige_verificacao` (o bloco 8 do
  `seguranca.sql` pode ser rodado de novo e cobre todas).
- **Função nova que devolve ou grava dado:** checar `acesso_liberado()` (ou usar uma das
  funções de permissão, que já checam). Nunca deixar executável para `anon`.
- **HTML vindo do banco** só entra na tela por `esc()` ou, se for texto formatado, por
  `limparHtmlCarta`.
- Senha nova: mínimo de 8 caracteres na tela.

---

## 23. Integração com a API do BTG (em levantamento, 06/11/2026)

Regras de negócio já decididas: seção 14 e `CLAUDE.md`. Portal do BTG:
`developer-partner.btgpactual.com` (login da Bibiana; CGE 5390761). Documentação recebida do
Emil por prints; o que foi confirmado fica aqui.

### 23.1. Autorizador (confirmado por print)

- `POST https://api.btgpactual.com/iaas-auth/api/v1/authorization/oauth2/accesstoken`
- Cabeçalhos: `Authorization: Basic base64(client_id:client_secret)`,
  `x-id-partner-request: <UUID novo a cada chamada>`,
  `Content-Type: application/x-www-form-urlencoded`.
- Corpo: `grant_type=client_credentials`.
- Resposta 200 **sem corpo**: o token vem no **cabeçalho** `access_token` (e o id da
  requisição em `x-id-pactual`).
- Token vale **15 minutos**: guardar e reaproveitar. Limite: 60 pedidos por minuto.
- client_id e client_secret nunca passam pela conversa: entram como segredo das Edge Functions
  (pedido pelo conector do Supabase, o Emil digita no painel).

### 23.2. Relacionamento de Conta e Parceiro (API 8, arquivo em `btg/openapi/`)

Especificação completa copiada do portal (versão antiga da documentação, aba Rede do Chrome,
requisição com o número da API). Servidor `https://api.btgpactual.com/iaas-account-advisor`.
Todas as chamadas levam os cabeçalhos `x-id-partner-request` (UUID novo) e `access_token`.

- `GET /api/v1/advisor/accounts` (**síncrona**): devolve `{"accounts": ["123456789", ...]}`,
  todas as contas do escritório. É a base para saber conta nova e conta que sumiu.
- `GET /api/v1/advisor/link/account` (**assíncrona**): responde 202 e manda o resultado por
  **webhook** "Relacionamento de Conta por Assessor (account-advisor)". Diz quais contas cada
  assessor **enxerga**, não quem é o assessor responsável (o BTG avisa: "não contém a
  informação de hierarquia"). Os dados ficam estáticos por 1 hora depois do pedido.
- `GET /api/v1/advisor/office-informations` (**assíncrona**, webhook "Informações do
  Escritório"): cadastro dos usuários do escritório em CSV: `loginName` (ex.: a1122334455),
  `advisorName`, `profileName`, `advisorCgeCode`, `active`, `email` etc.
- Sem o webhook cadastrado no portal (Webhooks > Manutenção > Cadastrar Webhook), as chamadas
  assíncronas devolvem erro "Webhook not registered".

**Consequência para o desenho:** o portal precisa de um endereço público que receba os
webhooks do BTG (uma Edge Function, ex.: `btg-webhook`). Falta a documentação dos webhooks
(formato, se vem arquivo CSV ou link, e como o BTG se identifica) e decidir qual campo do BTG
casa com o código do assessor do Hub (`perfis.codigo`): `loginName` ou `advisorCgeCode`.

### 23.3. Webhooks (resumo em `btg/webhooks.md`)

Os dados grandes do BTG chegam por webhook: o BTG faz POST no nosso endereço com um **link
assinado do S3** para um arquivo (CSV), que precisa ser baixado logo. Achado mais importante: a
**API de Relatórios Gerenciais por Parceiro** (`rm-reports-*`) entrega pronto o que o Hub usa:
base de contas com assessor e PL por classe (`rm-reports-account-base`), o **vínculo real
conta-assessor** (`rm-reports-account-link`: `cge_officer` e `login`), posição, movimentação,
NNM e, pela API de Rentabilidade Mensal, a TIR mensal por cliente, produto e estratégia, já com
CDI, Ibovespa, IPCA e IMA-B. Falta: a especificação dessa API (endpoints e parâmetros) e a tela
de cadastro de webhook (o que o BTG manda para o nosso endereço se identificar).

### 23.4. API de Relatórios Gerenciais (resumo em `btg/relatorios-gerenciais.md`)

Servidor `https://api.btgpactual.com/api-rm-reports`. Toda chamada é assíncrona (arquivo CSV por
webhook) e os relatórios diários saem em janelas fixas (7h/8h, 15h, 20h); a chamada devolve o
último arquivo gerado. O primeiro arquivo de cada webhook só existe na janela seguinte ao
cadastro. Por isso a atualização automática fica em **8h30 e 20h30** (e 15h30 para NNM), não
8h e 18h como combinado antes: pedir antes da janela traz o arquivo da véspera.

### 23.5. Protego e a regra de convivência (06/11/2026)

No portal havia 5 webhooks ativos para `app.protego.com.br` (operations-by-account,
positions-by-account, operations-by-partner, rm-reports-position, positions-by-account-v2),
autenticação por API Key. O Emil não reconhece a Protego (talvez ligada à Quantum, usada antes).
Decisão do Emil: **manter a Protego ativa por precaução**, sem interferir no Hub. Regras:

- O Hub **nunca cadastra webhook nesses 5 serviços**: o portal tem um endereço por serviço, e
  cadastrar o nosso tiraria a Protego do ar. Posição diária vem de `rm-reports-position-by-date`
  (D-1, sob demanda) e da base de contas (PL por classe); movimentação vem de
  `rm-reports-movement` e `rm-reports-monthly-movement`.
- Credencial: se o portal permitir, o Hub usa uma credencial própria (não a que a Protego usa),
  para cada um poder ser desligado sem afetar o outro.
- Pedido aberto ao BTG (Resolve Aí) para identificar a Protego e liberar o domínio
  `ghxjqmjtmbqzvogwzylo.supabase.co` (exigência do formulário de webhook).

### 23.6. Credencial própria do Hub e primeiro teste (06/11/2026)

- No login da Bibiana, a tela Autorização dizia "As chaves ainda não foram geradas": a Protego
  não usa chave gerada por esse usuário. O Emil gerou as chaves ali e cadastrou à mão em
  Edge Functions > Secrets como `BTG_CLIENT_ID` e `BTG_CLIENT_SECRET` (o cadastro de segredo
  pelo conector do Supabase estava pausado). As chaves nunca passaram pela conversa.
- Teste com a função `btg-teste`: autorizador 200 com `access_token` no cabeçalho, e
  `GET /iaas-account-advisor/api/v1/advisor/accounts` 200 com **883 contas** (o CRM tinha 884
  leads no mesmo dia). Sem IP liberado nem outro cadastro: a chamada síncrona funciona direto
  das Edge Functions. Depois do teste a função foi trocada por uma que responde 410 e exige
  JWT.
- Falta para os relatórios: o BTG liberar o domínio `ghxjqmjtmbqzvogwzylo.supabase.co`
  (Resolve Aí) e o cadastro dos webhooks.

