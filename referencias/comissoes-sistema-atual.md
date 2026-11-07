# Referência: sistema de comissões que a Adami usa hoje (prints do Emil, 07/11/2026)

Material de referência para o módulo Comissões (`comissoes.html`, DOCUMENTACAO seção 25).
O Emil está mandando prints de várias telas e vai dar o comando para implementar depois.
**Não implementar nada daqui sem o comando dele.** Esta pasta não vai ao site: a publicação
só leva HTML, `vendor/`, `img/`, `estilo/`, `comum/` e `.htaccess`.

Os prints têm nomes reais de clientes e assessores; por isso só a descrição fica aqui, sem as
imagens.

---

## Lote 1 (5 prints)

### Tela "Planilhas" (painel do mês)
- Topo: mês e ano ("Novembro 2026", com lápis para trocar) e a chave **"Fechamento disponível
  para profissionais"**, que libera a visão do fechamento para os assessores.
- Abas do módulo: **Comissões Assessores · Planilhas · Impostos · Regras · Ajustes Manuais ·
  Mínimo Garantido · Troca de Campos · Listas**.
- Na aba Planilhas: escolha entre "Visão anual" e "Visão mensal", campo de pesquisa e o botão
  "Subir nova planilha".
- **Grade "Envio de planilhas no ano"**: uma linha por origem e uma coluna por mês (Jan a Dez),
  com o status de cada planilha em ícone.
  - Origens que aparecem: BTG Investimentos, BTG Offshore, Consórcios, Corban, Pershing e
    Previdência. São as **6 planilhas** que o Emil citou.
  - Legenda dos status: Concluído, Documento possui avisos, Erro encontrado, Não enviado, Em
    processamento, Aguardando validação.

### "Adicionar Planilha": assistente em 3 etapas
O mês aparece ao lado do título.

1. **Escolha a Origem.**
2. **Importe a planilha.** Área de arrastar e soltar o arquivo (exemplo de nome:
   "Relatório B2B 5390761-1 - 16026817-1.xlsx"), com os botões "Etapa Anterior" e "Próximo".
3. **Confirmação de colunas.**
   - Campos do topo: "Nome da Origem" (ex.: BTG Investimentos, com a nota "Nome para
     recorrência"), "Cotação da Moeda" (R$ 1, que serve para a planilha em dólar) e "Tipo da
     Planilha" (ex.: Comissão).
   - Bloco **"Informações Principais" (obrigatório)**: um campo por informação, com a letra da
     coluna do Excel de onde ela vem.
     - Cliente → C
     - Profissional → E
     - Categoria → F
     - Produto → G
     - Comissão → M
   - Abaixo vem a prévia da planilha.
     - Mostra as primeiras linhas (2, 3, 4), "…" e as **últimas linhas**, para conferir onde os
       dados acabam.
     - A **linha onde os dados começam** é editável (caixinha "2") e a **linha onde terminam**
       também (caixinha "657" / "2.902"). Isso corta o cabeçalho e a linha de "Total".
   - **Seletor "Aba"**: o arquivo do BTG tem várias abas, como **Resumo, Detalhe, Fundos e
     Operações RF**. Na aba Resumo as colunas não batem (a prévia sai vazia ou com "Total"). Na
     aba **Detalhe** sai o certo: cliente, assessor ("Profissional"), categoria (ex.: FUNDOS),
     produto (ex.: RENDA FIXA) e comissão com muitas casas decimais (ex.: 12,2907…).
   - "Configurações Avançadas" (opcional) e o selo "Demonstração com dados reais".
   - Os botões "Cancelar" e "Salvar" e o aviso "Planilha lida com sucesso".

### O que isso indica para o nosso módulo
Anotação de leitura; o desenho só será decidido no comando do Emil.

- **Origem** como cadastro, com nome, moeda e tipo. A configuração de colunas é guardada por
  origem e reaproveitada todo mês ("Nome para recorrência").
- **Escolha da aba** do Excel. Hoje a nossa importação lê só a primeira aba, e no relatório do
  BTG a primeira aba é o Resumo, que não serve.
- **Mapeamento por letra de coluna** e **linhas de início e fim**, além do reconhecimento
  automático pelo nome do cabeçalho que já existe.
- A planilha do BTG traz **Profissional pelo nome**, não pelo código.
- A comissão vem com muitas casas decimais: arredondar só no total.
- Grade anual de **status de envio por origem e mês**.
- As outras abas do sistema (Impostos, Mínimo Garantido, Troca de Campos, Listas) ainda não
  foram mostradas. Esperar os próximos prints.

---

## Lote 2 (5 prints)

### Detalhe de uma planilha enviada (painel lateral ao clicar no ícone do mês)
- Título com origem e mês ("BTG Investimentos · Nov/2026") e o status ("Aguardando validação").
- Botão **"Importar novamente"**. **Pedido do Emil: ao lado dele, um botão para EXCLUIR a planilha
  que subimos** (desfazer a importação daquele mês e daquela origem).
- Três cartões: **Valor total de comissões** (ex.: R$ 238 mil), **Quantidade de linhas** (ex.: 2.897)
  e **Cotação da moeda** (R$ 1,00).
- Arquivo importado com o nome original e um botão **Download** do arquivo, além do tipo da planilha
  e da data/hora da última atualização.
- **Avisos** em blocos que abrem ao clicar:
  - "Informação: N códigos da planilha serão trocados por Troca de Campos do mês (não é erro)".
    Lista de trocas do tipo `NOME COMPLETO NA PLANILHA → NOME CURTO DO CADASTRO (linha X)`, e
    também `ASSESSORIA DIGITAL → ESCRITORIO`. A planilha traz o nome do assessor escrito de jeitos
    diferentes (com e sem cedilha, completo e curto), e a "Troca de Campos" normaliza.
  - "Atenção! N profissional não está cadastrado na base. Cadastre o seguinte profissional: …".

### Aba "Comissões Assessores" (Fechamentos)
- No topo do módulo: Visão Geral · **Fechamentos** · Pagamentos. Mostra também "Acesso: Gestor".
- Escolha entre **Visão por categoria** e **Visão por cliente**.
- Botões **"Baixar todas comissões"** e **"Baixar Excel"**.
- Filtros: **Profissionais** (lista com todos, incluindo "ESCRITORIO" como se fosse um
  profissional), Categoria, Origem, Cliente, Tag e Pesquisar.
- **Bloco Resumo** do profissional escolhido:
  - Comissão Gerada (sem ajustes), Rateio, Ajustes e Impostos;
  - à direita, **Comissão Bruta Apurada** e **Comissão Líquida** em destaque.
- Tabela por categoria com **Comissão Gerada · Comissão Bruta · Comissão Líquida**, cada linha
  abrindo o detalhe. Categorias vistas: AJUSTE, FUNDOS, OPERACOES ESTRUTURADAS, RENDA VARIAVEL,
  RENDA FIXA, RENDA FIXA - PRIMARIO TERCEIROS, DERIVATIVO.
  - Gerada é o que a planilha traz para a casa. Bruta é a parte do profissional depois do rateio.
    Líquida é a Bruta depois dos impostos.

### Aba "Regras" (Emil: "achei um pouco confuso, talvez possamos melhorar, mas tem funcionado hoje")
- Aviso fixo: **as regras valem por prioridade**. A de cima ganha; a ordem importa.
- Filtros Profissionais e Clientes, pesquisa, "Adicionar Regra", e a escolha entre PRIORIDADE e
  LISTA DE REGRAS.
- Cada regra é um cartão numerado (1º, 2º, 3º…) com setas para subir/descer, lápis para renomear,
  duplicar/arquivar/excluir. Dentro, uma tabela de linhas com:
  **Cliente · Profissional · Origem · Categoria · Produto** (as condições; vazio = qualquer) e
  **Recebedor · Porcentagem · Utilizar em valores negativos · Tag** (quem recebe quanto).
- Recebedor pode ser uma pessoa, **"ESCRITORIO"** ou o coringa **"$PROFISSIONAL"** (o próprio
  assessor da linha da planilha). Porcentagem pode ser número ou **"$restante"** (o que sobra).
- Cliente pode ser um nome ou uma **lista** entre colchetes (ex.: "[CLIENTES RAFAEL]", vinda da aba
  Listas).
- Exemplos de regras, sem os nomes:
  1. **Erro operacional:** categoria ERRO OPERACIONAL e categoria FEE DE PLATAFORMA vão 100% para
     $PROFISSIONAL. Ou seja, o próprio assessor arca, inclusive quando o valor é negativo.
  2. **Repasse de uma carteira:** clientes da lista de um assessor. 30% vão para uma pessoa, 28%
     para outra e o restante fica com o ESCRITORIO, com tag.
  3. Em diante, **uma regra por cliente de consórcio**, todas iguais: categoria CONSÓRCIO, produto
     EMBRACON, 30% para a especialista de consórcio, 30% para o assessor e o restante para o
     escritório. São muitas regras repetidas, e é isso que deixa a tela confusa.

### Ideias para melhorar as Regras (anotação para a conversa com o Emil, nada decidido)
- Manter o conceito que funciona: **condições** (cliente/lista, assessor, origem, categoria,
  produto) → **divisão** (recebedor + % ou "restante"), com **prioridade**.
- Tirar a repetição: uma regra "Consórcio Embracon 30/30/restante" que vale para **uma lista de
  clientes**, em vez de uma regra por cliente.
- Mostrar cada regra como frase ("Quando categoria = Consórcio e produto = Embracon → 30% X,
  30% assessor, resto escritório") e um **testador**: escolher uma linha da planilha e ver qual
  regra pegou e por quê.
- Hoje o nosso módulo tem regras simples (imposto/BTG/escritório/assessor/especialista em %).
  Para chegar nisso precisa de condições, recebedor coringa ($PROFISSIONAL), "$restante",
  listas de clientes e prioridade.

### Outras peças que esses prints mostram (ainda sem detalhe)
- **Troca de Campos:** tabela "texto da planilha → cadastro", por mês.
- **Listas:** grupos de clientes usados nas regras.
- **Impostos, Ajustes Manuais e Mínimo Garantido:** abas próprias, ainda não mostradas.
- Chave **"Fechamento disponível para profissionais"**: cada assessor passa a ver o próprio
  fechamento.
