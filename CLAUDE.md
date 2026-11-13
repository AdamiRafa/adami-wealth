# Portal Adami Captal

Plataforma administrativa interna da Adami Captal, gestora de patrimônio.
Leia `DOCUMENTACAO.md` na raiz antes de mexer em qualquer coisa: ele tem o modelo de
dados, as regras de negócio e as armadilhas já encontradas. Este arquivo é só o essencial
para começar.

O nome da firma se escreve **Adami Captal**, sem "i" no final.

---

## Com quem você está falando

Emil Stade, fundador. Não é técnico: não roda comandos, não edita código, não abre
terminal. Ele descreve o problema em linguagem comum ("ficou cagado", "tá comendo as
etapas"), revisa o resultado visual e aponta o que está errado.

- Diagnostique a causa raiz em vez de pedir esclarecimento técnico.
- Instruções para ele são sempre clique a clique.
- Responda em português do Brasil, direto, sem travessão longo e sem soar como IA.
- Quando errar, diga que errou e o que causou. Ele prefere isso a rodeio.

---

## Arquitetura, e o que não discutir

HTML puro, sem build, sem framework, sem etapa de compilação. **Esta decisão é
definitiva.** O projeto nasceu em React + Vite e passou dias quebrando no build da
Vercel; em 13/08/2026 foi reescrito em HTML estático e nunca mais falhou deploy. Não
proponha reintroduzir framework, bundler ou build.

Arquivos na raiz, que se referenciam por caminho relativo e precisam continuar lado a
lado:

| Arquivo | Módulo |
|---|---|
| `index.html` | Hub de entrada + Carteiras + tela de Equipe |
| `crm.html` | CRM (React servido de `vendor/`, sem build) |
| `rv.html` | Mesa RV |
| `diagnostico.html` | Ferramenta Wealth Planning |
| `patrimonial.html` | Gerador de Planos Patrimoniais |
| `imobiliario.html` | Relatório Imobiliário |
| `simulador.html` | Simulador de receita RV |
| `alocacao.html` | Política de Alocação (material do comitê, gera PDF) |
| `fluxo.html` | Fluxo e Captação — mapa das movimentações do BTG, acesso só master |
| `boletas.html` | Controle de Boletas |
| `agio.html` | Ágio e Troca de Ativos |
| `liberdade.html` | Liberdade Financeira |
| `processo.html` | Processo Comercial |
| `adami_completo.sql` | Banco inteiro, portal + CRM |

Backend: Supabase (`ghxjqmjtmbqzvogwzylo.supabase.co`), Postgres com RLS.
E-mail: caixa `hub@adamicaptal.com.br` (HostGator), remetente "Hub Adami". O de boas-vindas
sai pela Edge Function `supabase/functions/enviar-convite` (colada à mão no Supabase); o de
redefinir senha pela `enviar-senha`, o e-mail da manhã da Agenda pela `agenda-manha` e o código
de acesso de 6 dígitos pela `codigo-acesso`. Os
modelos são gerados por `emails/_base.py`, que grava cada um dentro da sua função.
Agenda do CRM: tabela `tarefas` (`agenda.sql`); detalhes na seção 19 da documentação.
Relatório ao cliente (3.20, seção 28): função `relatorio-enviar`; destinatários só de `clientes.emails_relatorio`
e só com o mês feito. A carteira liga à ficha do CRM por `clientes.lead_id`.
Visual 2026 (seção 20): vidro, menu lateral e modo noite; camada comum dos módulos em
`estilo/adami-2026.css`. Tudo que é visual fica em `@media screen`: a impressão não pode mudar.
Arquivos do cliente: Storage `anexos` + tabela `anexos` (`anexos.sql`); as ferramentas gravam
na ficha por `comum/anexos.js` (seção 21).
Barra comum (3.10, seção 26): `comum/barra.js` no `<head>` de todo módulo (botão ?, busca Ctrl+K,
Reportar um problema). Módulo novo carrega `comum/sessao.js` e `comum/barra.js` e ganha uma entrada em
`AJUDA` no barra.js. O manual do Hub fica em `ajuda/Manual-do-Hub.pdf` (fonte em `manual-fonte/`); se o
manual mudar, atualize as páginas em `AJUDA[...].pag`. O Hub é instalável no celular (`app.webmanifest`).
A chave *publishable* fica no código do navegador, o que é correto: a proteção está na
RLS. A *service_role* **nunca** entra em arquivo servido ao navegador.

Módulo novo = arquivo HTML próprio na raiz, no mesmo padrão visual, mais um card no hub.
Antes de propor sistema separado para uma demanda nova, considere o hub.

---

## Antes de publicar

Emil não tem como testar código. Se subir quebrado, ele descobre com um cliente na
frente. A disciplina abaixo não é opcional.

1. **Sintaxe**: `node --check` em cada bloco `<script>` extraído.
2. **Escopo**: análise com acorn + eslint-scope. Variável usada sem declaração passa na
   checagem de sintaxe e só quebra em execução. **Se o analisador acusar, não publique.**
   Já aconteceu de publicar ignorando o próprio aviso.
3. **DOM**: testar com jsdom. Renomear uma classe sem atualizar quem a lê deixa o
   formulário lendo o vazio, e nenhum analisador estático percebe.
4. **Impressão**: gerar o PDF de verdade com Playwright (Chromium em
   `/opt/pw-browsers/chromium`) e **medir as margens página por página**. Olhar o HTML
   na tela não revela problema de paginação.
5. **SQL**: validar com `pglast` antes de entregar.

O verificador de sintaxe e escopo está em `testes/escopo.js` (instruções em `testes/README.md`).
Desde a 3.20 a publicação roda `testes/verificar.sh` antes de enviar (sintaxe, escopo, SQL e os 15 módulos
abertos num navegador com o Supabase simulado): se falhar, nada vai ao ar. Rode-o também antes de commitar.
Nome de navegador novo que o escopo não conhece vai em `testes/escopo-conhecidos.json`.

Cada conjunto de mudanças ganha um número de versão novo, visível no rodapé de cada
módulo (`var VERSAO="versão 2.51"` e equivalentes). O selo existe para o Emil perceber
quando está vendo cache em vez do arquivo novo.

---

## Publicação

O portal fica em **`adamicaptal.com.br/hub`**, na HostGator. A cada commit na `main`, o
GitHub Actions publica sozinho em menos de um minuto (ver `DOCUMENTACAO.md` seção 10).
Se a publicação falhar, o erro aparece na aba Actions do repositório. A Vercel foi
desligada em novembro/2026. Commite direto na `main`; não abra PR, a menos que ele peça.

Nunca confira um commit por `raw.githubusercontent.com`. O CDN serve conteúdo velho e já
causou **duas reversões silenciosas** de trabalho publicado. Confira pela API do GitHub,
decodificando o campo `content`.

SQL é rodado pelo Emil no SQL Editor do Supabase, colando o arquivo inteiro. O aviso
"Potential issues detected" é falso positivo: a orientação é **Run without RLS**.

Nunca peça nem aceite chave de API ou token por conversa. Não funciona no ambiente de
execução e fica registrado no histórico.

---

## Regras de negócio que não se quebram

- **Rentabilidade % e rentabilidade R$ são independentes.** Aporte no meio do mês rompe
  a relação entre os dois. O percentual da carteira é média ponderada pelo saldo de
  abertura, nunca derivado do valor em reais.
- **Abertura** = saldo final − rendimento − aplicações + resgates.
- **Aplicações e resgates são sempre positivos.** O sinal já está na fórmula. Um resgate
  negativo erra a abertura em duas vezes o valor.
- **Onshore (R$) e offshore (US$) nunca se somam.** A PTAX é referência de conversão, não
  de consolidação. A rentabilidade offshore não incorpora variação cambial, e isso está
  no rodapé do relatório.
- **Rentabilidades são compostas**, nunca somadas.
- **Indicadores são globais por mês** e replicam entre clientes, mas campo em branco
  nunca zera o do vizinho. Vencimentos, estratégias e contas nunca replicam.
- **Privilégio não se escreve pela API.** Toda mudança passa por função `security
  definer` que confere quem chama. Já houve escalada de privilégio por política mal
  escrita; ver `DOCUMENTACAO.md` seção 5.
- **Filtrar no navegador não é segurança.** Restrição de acesso se resolve no banco, com
  política.
- **Verificação em duas etapas por e-mail ou app autenticador (2.91 e 3.01) e acesso que vence à meia-noite (seção 22).**
  Com o app ligado, o aparelho pode ser lembrado por 7 dias (3.10, seção 26): só o código é dispensado, a senha não.
  Toda tabela com RLS tem a política restritiva `exige_verificacao`; tabela nova também precisa
  ter. Função nova que devolve ou grava dado checa `acesso_liberado()` (as funções de permissão
  já checam) e nunca fica executável para `anon`: o Supabase dá EXECUTE ao `anon` por padrão,
  e `revoke ... from public` não tira. Todo módulo carrega `comum/sessao.js` no `<head>`.
- **HTML vindo do banco** entra na tela só por `esc()` ou `limparHtmlCarta`. `esc()` não escapa aspas simples:
  dado do banco (id em texto, nome) nunca vai dentro de string de `onclick`; passe um índice (seção 30). Endereço externo
  novo precisa entrar na Content-Security-Policy do `.htaccess`.
- **A importação do BTG não cria, não exclui e não transfere carteira pelo nome.** Só o
  código do assessor autoriza transferência. Ver `DOCUMENTACAO.md` seções 6 e 7.
  A integração pela API (decidida em 05/11/2026, aguardando o BTG) grava direto e cria
  conta nova, mas só pelo código do assessor do BTG; nunca apaga e nunca transfere por
  nome. Ver `DOCUMENTACAO.md` seção 14.

---

## Armadilhas que já custaram caro

- **Margem de página não se falsifica com padding.** Padding de um elemento que atravessa
  várias folhas aparece uma vez só. Use `@page { margin: … }`. Para sangrar a capa, use
  página nomeada com margem zero.
- **`break-inside: avoid` só vale para o que cabe numa folha.** Num bloco mais alto que a
  página, ele não impede a quebra, só faz o navegador quebrar onde quiser.
- **`create or replace function` não muda tipo de retorno.** Derrube a função antes.
- **PostgREST devolve corpo vazio em 201.** `res.json()` estoura com "Unexpected end of
  JSON input" e a gravação parece ter falhado quando funcionou.
- **Handlers inline em HTML gerado por string** rodam no escopo global. Índice de laço
  precisa ser interpolado.
- **`@media (max-width:…)` sem `screen` vale também na impressão.** A folha A4 tem menos
  de 900 px: uma regra de celular mudou o PDF dos KPIs de 5 para 6 páginas. Use
  `@media screen and (max-width:…)` para regra que é só de tela.
- **Cache do navegador engana.** Peça Cmd+Shift+R e confira o selo de versão antes de
  investigar qualquer coisa.

---

## Pendências

Ver `DOCUMENTACAO.md` seção 14. As mais quentes: acesso à API de parceiros do BTG (regras já
decididas) e a autorização do Microsoft 365 para o Outlook na Agenda. Agenda, Avisos, Arquivos e
o reset de senha estão instalados e funcionando desde 06/11/2026. A verificação em duas etapas
(2.91) depende de o Emil instalar a função `codigo-acesso` e rodar `seguranca.sql`.
