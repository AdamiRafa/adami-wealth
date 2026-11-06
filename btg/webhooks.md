# Webhooks do BTG (portal de parceiros), resumo

Copiado pelo Emil em 06/11/2026 do portal `developer-partner.btgpactual.com` (Webhooks >
Documentação; requisição "webhook" na aba Rede do Chrome). São 78 webhooks; aqui estão os que
importam para o Hub e o formato comum. Não vai ao ar.

## Como funcionam

1. Cadastrar o webhook no portal (Webhooks > Manutenção > Cadastrar Webhook), com o endereço
   que vai receber (o nosso: uma Edge Function do Supabase).
2. Chamar o endpoint da API correspondente. A resposta é 202 (assíncrona).
3. O BTG faz `POST` no nosso endereço com um JSON assim:

```json
{"errors":[{"code":null,"message":null}],
 "response":{"fileSize":123,"startDate":"2021-05-01","endDate":"2022-06-20",
             "url":"https://invest-reports...s3.amazonaws.com/.../XXXX",
             "signedURLExpirationDate":"2022-10-13T21:28:13.543Z",
             "lastModified":"2023-09-30T15:30:00Z"}}
```

4. O dado em si está no arquivo do `url` (link assinado do S3, com prazo de validade): baixar
   logo que o aviso chega. Pela documentação da API 8, o arquivo é CSV com os campos do
   "fileExample".

Exceções no formato: `account-advisor` manda `{"url","fileSize","filters":{...}}` sem
`response`; `account-movement` (tempo real) manda o evento direto, sem arquivo.

## Os que importam para o Hub

| Webhook (service) | Endpoint a chamar | Para quê no Hub | Campos principais do arquivo |
|---|---|---|---|
| **rm-reports-account-base** (Base de Contas, id 860) | get-rm-reports-account-base (API de Relatórios Gerenciais) | Substitui a planilha de base que o CRM importa hoje | nr_conta, nome_completo, nm_assessor, email_assessor, **cge_officer**, cge_partner, tipo_cliente, dt_abertura, dt_vinculo, perfil_investidor, faixa_cliente, pl_total, pl_conta_corrente, pl_fundos, pl_renda_fixa, pl_renda_variavel, pl_previdencia, pl_derivativos, vl_aportes, vl_retiradas, dt_ultimo_aporte, status_ranking |
| **rm-reports-account-link** (Vínculo de Conta, id 859) | get-rm-reports-account-link | **Quem é o assessor de cada conta** (o vínculo de verdade, ao contrário do account-advisor, que só diz quem enxerga) | nr_conta, ts_criado, nm_officer, **login**, **cge_officer**, cge_partner, nm_partner, tipo_parceiro |
| **rm-reports-position** (Posição, id 628) e **rm-reports-position-by-date** (1364) | get-rm-reports-position / post-rm-reports-position-by-date | Posição por ativo de cada conta (Carteiras) | nr_conta, dt_interface, mercado, sub_mercado, produto, ativo, emissor, indexador, cnpj_fundo, quantidade, vl_bruto, vl_liquido, vl_ir, vl_iof, dt_vencimento, vl_bruto_curva_cliente, vl_bruto_curva_mercado, tipo_previdencia |
| **rm-reports-movement** (137) e **rm-reports-monthly-movement** (265) | get-rm-reports-movement / get-rm-reports-monthly-movement | Aplicações e resgates (Carteiras e Fluxo e Captação) | nr_conta, dt_movimentacao, mercado, sub_mercado, historico_movimentacao, tipo_lancamento, tipo_operacao, ativo, vl_bruto, vl_liquido, vl_ir, vl_iof, vl_captacao, flag_nnm, dt_liquidacao |
| **monthly-customer-profitability** (TIR mensal por cliente, 1784) | post-monthly-customer-profitability (API de Rentabilidade Mensal) | Rentabilidade da carteira no relatório (mês, ano, 12m, CDI, Ibovespa, IPCA, IMA-B, dólar) | cod_carteira, reference_month, auc_end, inflow_and_outflow, profit_mtd/ytd/12m, profitability_mtd/ytd/12m, cdi_*, ibovespa_*, ipca_*, imab_*, dolar_* |
| **monthly-product-profitability** (1785) e **monthly-strategy-profitability** (1786) | idem | Rentabilidade por produto e por estratégia | cod_carteira, product_name, market_id / asset_allocation_strategy, profitability_* |
| **rm-reports-nnm** (1255) e **rm-reports-monthly-nnm** (1363) | get-rm-reports-nnm / post-rm-reports-monthly-nnm | Captação líquida (KPIs, Fluxo) | nr_conta, dt_captacao, ativo, mercado, cge_officer, tipo_lancamento, captacao, is_officer_nnm, is_partner_nnm |
| **partner-report-stvm** (430) | post-report-stvm-by-partner-and-period (API Net New Money) | STVM e portabilidade | cod_carteira, tipo_lancamento, captacao, officer_officer_cge, data_captacao, mercado |
| **rm-reports-registration-data** (136) | get-rm-reports-registration-data | Cadastro (aniversário, suitability, e-mail) | nr_conta, nome_completo, dt_nascimento, celular, email_comunicacao, suitability, dt_vencimento_suitability, tipo_cliente, status, dt_abertura, dt_encerramento |
| **account-movement** (397) | (só assinar) | Aviso em tempo real de crédito/débito na conta | type, data.value, data.type (CREDIT/DEBIT), data.description, accountNumber |
| **office-informations-by-partner** (496) | get-office-informations (API 8) | Lista de usuários do escritório no BTG | loginName, advisorName, advisorCgeCode, active, email |

Outros que podem servir depois: rm-reports-orders (ordens de RV, Mesa RV),
ipo-report-reservation / ipo-reservation-history (ofertas, Fluxo), rm-reports-pension-portability
(portabilidade), rm-reports-expected-income (proventos futuros), rm-reports-asset-allocation
(alocação por classe), rm-reports-trade-idea (ágio e deságio), rm-reports-fee-fixo, rm-reports-pending-document.

## Ligação com o assessor no Hub

O BTG identifica o assessor por `cge_officer` (código interno) e `login` (ex.: a0123456789).
O Hub liga carteira a assessor por `perfis.codigo`. Decidir com o Emil qual dos dois guardar
em `perfis.codigo`, ou guardar os dois.
