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
