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

---

## Lote 3 (5 prints)

### Regras (continuação)
- Mais regras de consórcio, uma por cliente. Uma delas é de **produto CARTA CONTEMPLADA** com
  outra divisão: 25% para um sócio, 23% para o especialista e o restante para o escritório. Ou
  seja, a divisão muda conforme o **produto** do consórcio, e não só conforme a administradora.
- **"Repasse padrão"** é a última regra, a de menor prioridade, e vale quando nenhuma de cima pegou:
  - linhas 1 e 2: quando o profissional é uma sócia específica, ela fica com 58% e o restante vai
    para o ESCRITORIO;
  - linhas 3 e 4: para qualquer outro profissional, **$PROFISSIONAL fica com 50%** e o restante vai
    para o ESCRITORIO.
  - Isso confirma o padrão que o Emil já tinha dito: 50% para o assessor. A exceção da sócia (58%)
    mostra que dá para ter um padrão diferente por pessoa.

### Ajustes Manuais
- Filtro por profissional, pesquisa e "+ Adicionar Ajuste". Os ajustes ficam em **grupos com
  nome** (ex.: "Pagamento Dayler", "Liderança comercial").
- Colunas de cada linha: **Profissional · Debitar de · Descrição · Valor Bruto · % do escritório ·
  Origem · % de imposto · Data Início · Data Fim · Categoria**.
- "Debitar de" = ESCRITORIO nos exemplos, ou seja, o escritório paga um valor fixo ao
  profissional. Exemplos: valores fixos de R$ 1.200 e R$ 5.000 descritos como função
  (FINANCEIRO, SEGUROS, CONSÓRCIOS, LIDERANÇA COMERCIAL, CEO, BackOffice).
- **Data Início / Data Fim** indicam que o ajuste é **recorrente**: repete todo mês dentro do
  período, sem precisar lançar de novo. Hoje o nosso "Ajuste" vale só para um mês.

### Mínimo Garantido
- Filtro por profissional e "Adicionar Mínimo Garantido". Neste mês não havia nenhum ("Nenhum
  mínimo garantido cadastrado para este fechamento").
- Conceito (a confirmar com o Emil): se a comissão do mês ficar abaixo de um piso, o escritório
  completa até o mínimo.

### Troca de Campos (detalhe)
- Mesma lógica das regras: **grupos com prioridade** (1º, 2º…), cada um com linhas de condição
  **Cliente · Profissional · Origem · Categoria · Produto** e a ação **Substituir campo** (ex.:
  PROFISSIONAL) **por** um valor.
- Exemplos:
  - "Ajuste profissional": nome comprido da planilha → nome do cadastro (vários assessores), e
    ex-assessores → ESCRITORIO;
  - "Assessoria digital" → ESCRITORIO;
  - "Ajuste prev externa": o CNPJ/razão social da própria Adami como profissional → ESCRITORIO;
  - "Profissional Alexandre" → ESCRITORIO.
- Uso prático: **ensinar uma vez** que "nome X na planilha = pessoa Y" e, para quem saiu da casa,
  mandar a comissão para o escritório.

### Cadastro de profissionais (outro módulo do mesmo sistema)
- Filtros: Filial/Segmento, Equipe, Senioridade, Ratoio, Plano de carreira.
- "Editar profissionais em lote", "Enviar convites em lote" e "Adicionar Profissional".
- A opção "Profissionais Inativos" mostra **Motivo da saída · Data da saída · Multa · Saída
  carteira**.
- Cada profissional aparece com **nome curto e nome completo** (ex.: "Karan Paiva" / "KARAN
  MENIERY PAIVA"). O nome completo é o que a planilha traz.
- Para o nosso Hub: guardar na Equipe um **"nome como aparece no BTG"** (ou vários apelidos)
  resolve boa parte da Troca de Campos. Para quem sai, marcar "comissão vai para o escritório"
  a partir da data de saída.

---

## Lote 4 (5 prints)

### Pagamentos: "Folha de Pagamentos" do mês
- Filtros Profissionais e Status, mais pesquisa.
- Tabela com seleção por linha (caixinha) e as colunas **Status · Profissional · Código ·
  CPF/CNPJ · Total**, mais **uma coluna por empresa pagadora**:
  - "Adami Captal Assessores de Investimentos S/S";
  - "Adami Captal Wealth Planning Ltda".
  - Cada pessoa recebe por uma das duas PJs, ou dividido entre as duas. O ESCRITORIO também
    aparece como linha, com o que sobra para a casa.
  - Linha de **Total** por coluna. No exemplo, a folha do mês era de ~R$ 129 mil, dividida entre
    as duas PJs (~R$ 99,7 mil + ~R$ 29,5 mil).
- **Status do profissional**: "Não visualizado" / "Visualizado", ou seja, se o assessor já abriu o
  próprio demonstrativo.
- Menu do botão **"Exportar remessa"**: Atualizar profissionais, Editar dados em lote, Importar
  Histórico, Baixar Excel.
- **Exportar Remessa** (painel lateral):
  - Data de referência (mês) e Data de pagamento.
  - Formato: AAWZ, OMIE, Kamino ou **Remessa Bancária (CNAB 240)**.
  - Grupo de pagamento (obrigatório no CNAB) e **PJ pagadora (conta de origem)**.
  - Forma de lançamento: **PIX, DOC/TED ou Crédito em conta**.
  - Total da remessa e o botão Exportar.
  - Ou seja: gera o **arquivo do banco** para pagar todo mundo de uma vez.

### Cadastro do profissional: aba "Acordos contratuais"
- Abas da ficha: Dados pessoais · Dados bancários · Participações Societárias · **Acordos
  contratuais** · Clientes atrelados · Churn.
- Campos dos acordos contratuais:
  - Função; Luvas por ano (R$) e anos de luvas; Bonificação;
  - Custo fixo (% da receita); Salário; **Remuneração mínima**; Tamanho da carteira;
  - ROA líquido (%); data da contratação; Segmento; Senioridade;
  - **Expectativa de conversão** e **Comissões** para o ano 1, ano 2, ano 3 e ano 4 em diante, em
    %. É uma escada de repasse por tempo de casa.
- A "Remuneração mínima" é o que alimenta o Mínimo Garantido. Salário e luvas podem virar ajustes
  recorrentes.

### Menu geral do sistema
- Grupos do menu:
  - Gestão operacional: CRM, Compliance, Financial Planning;
  - Gestão de escritórios: **Comissões**;
  - Gestão de pessoas: **Profissionais**;
  - Ferramentas: Drive, Intelligence;
  - Jornada de Configuração; Configurações.
- As Configurações têm Gerais, Financeiro, Partnership, Estratégia e Performance, CRM, BI e
  Consolidador/Asset Allocation, Financial Planning.
- **Configurações gerais** concentram os parâmetros do escritório: permissões, CNPJs e
  profissionais.

### O que isso indica para o nosso módulo
Anotação de leitura, nada decidido.

- O pagamento precisa saber **qual PJ paga cada pessoa**. Isso entra no cadastro de dados de
  pagamento na Equipe. O nosso já tem PIX e banco, mas ainda não tem a PJ pagadora.
- **Remessa CNAB 240 / lote PIX** para o banco é um passo à frente do "marcar como pago" que temos.
  Precisa saber qual banco a Adami usa para pagar.
- **"Visualizado"**: hoje mandamos o Excel por e-mail. Se depois o assessor puder ver o próprio
  demonstrativo no Hub, dá para marcar quando ele abriu.
- **Acordos contratuais** na ficha da Equipe: remuneração mínima, salário, escada de comissão por
  ano. São dados sensíveis e precisam ficar só com Financeiro/master, como os dados bancários.

---

## Lote 5 (2 prints): Configurações gerais
- Itens: Profissionais · Equipes · **CNPJs e Filiais** · Dados pessoais · Dados e parâmetros do
  escritório · Permissões de acesso · **Acesso espelhado** (um profissional vê dados de outro em
  BI, Financeiro e Comissionamento) · Identidade visual.
- **CNPJs cadastrados**, todos ativos:
  - Adami Captal Wealth Planning Ltda, 55.503.633/0001-04;
  - Adami Captal Assessores de Investimentos S/S, 36.000.256/0001-46;
  - Adami Partners Consultoria Comercial Ltda, 32.191.808/0001-90.
- Para o nosso módulo: um **cadastro de empresas pagadoras** (as 3 PJs), usado como "PJ
  pagadora" de cada pessoa e como a coluna da folha de pagamentos.
