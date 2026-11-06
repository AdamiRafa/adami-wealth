# API de Relatórios Gerenciais do BTG (resumo da especificação)

Copiada pelo Emil do portal em 06/11/2026 (OpenAPI 3.0.2, versão 3.1.2.0). Não vai ao ar.

- Servidor: `https://api.btgpactual.com/api-rm-reports`
- Cabeçalhos em toda chamada: `x-id-partner-request` (UUID novo) e `access_token` (seção 23.1).
- Toda chamada é **assíncrona**: responde 202 e o arquivo chega pelo webhook de mesmo nome
  (ver `webhooks.md`). Sem o webhook cadastrado: erro síncrono "Webhook not registered".
- Os relatórios diários são **gerados em janelas fixas**; a chamada devolve sempre o último
  arquivo gerado. Depois de cadastrar um webhook, o primeiro arquivo só existe a partir da
  janela seguinte (antes disso o webhook traz "Relatório não disponível...").
- Os mensais (POST) são gerados uma vez por pedido; o mês anterior só a partir do dia 7.
- Formato do arquivo: CSV (o de FEE Fixo usa `;`).
- Limite: 60 pedidos por minuto.

## Os que o Hub vai usar

| Endpoint | Webhook | Janelas (Brasília) | Dados | Uso no Hub |
|---|---|---|---|---|
| `GET /api/v1/rm-reports/account-link` | rm-reports-account-link | 1x/dia, 7h | D-1 | **Assessor responsável por conta** (`cge_officer`, `login`) |
| `GET /api/v1/rm-reports/account-base` | rm-reports-account-base | 1x/dia, 8h | D-1 | Base de clientes com assessor e PL por classe (substitui a planilha do CRM) |
| `GET /api/v1/rm-reports/position` | rm-reports-position | 7h, 15h, 20h | D-1 e D0 | Posição por ativo (Carteiras) |
| `POST /api/v1/rm-reports/position-by-date` `{refDay,refMonth,refYear}` | rm-reports-position-by-date | sob demanda | um dia | Fechamento de posição do mês (último dia útil) e recargas |
| `GET /api/v1/rm-reports/movement` | rm-reports-movement | 7h, 15h, 20h | últimos 20 dias | Aplicações e resgates |
| `POST /api/v1/rm-reports/monthly-movement` `{refMonth,refYear}` | rm-reports-monthly-movement | sob demanda | um mês (até 12 para trás) | Fechamento do mês (Carteiras, Fluxo) |
| `GET /api/v1/rm-reports/nnm` | rm-reports-nnm | 1x/dia, 15h | últimos 31 dias | Captação líquida (KPIs) |
| `POST /api/v1/rm-reports/monthly-nnm` `{refMonth,refYear}` | rm-reports-monthly-nnm | sob demanda | um mês | Fechamento de NNM |
| `GET /api/v1/rm-reports/registration-data` | rm-reports-registration-data | 7h, 15h, 20h | atual | Cadastro: aniversário, suitability, e-mail, status da conta |
| `POST /api/v1/rm-reports/monthly-account-base` `{refMonth,refYear}` | rm-reports-monthly-account-base | sob demanda | um mês (até 6 para trás) | Base histórica do mês |
| `GET /api/v1/rm-reports/monthly-tir` | rm-reports-monthly-tir | 8h, 15h, 20h | atual | TIR mensal (complementa a API de Rentabilidade Mensal) |
| `GET /api/v1/rm-reports/operations` | rm-reports-operations | 8x/dia (8h a 20h) | D-5 a D0 | Operações solicitadas pelos clientes |

Outros endpoints da mesma API: onboarding-data, funds-information, funds, representative,
openfinance, consent-openfinance, exchange-operation, pension-payment, banking, credit-card,
fee-fixo, registration-data-club-funds, principality, closed-fund-reserve, pre-operations,
pension-portability, monthly-pension-portability, account-link-funds-club, asset-allocation,
trade-idea, account-limit, judicial-block, pending-document, subscription, gerencial-banking,
product-and-market, banking-pme, potential-clients, expected-income, orders, orders-by-date,
pension-campaign, pension-campaign-by-date.

## Consequência para o horário de atualização

A regra decidida em 05/11 era "8h e 18h". As janelas do BTG são 7h/8h, 15h e 20h, então o
pedido precisa vir **depois** delas: proposta 8h30 (vínculo, base, posição, movimentação e
cadastro do dia) e 20h30 (posição e movimentação do fim do dia), mais 15h30 para NNM.
