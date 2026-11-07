-- Limpeza única (07/11/2026, pedida pelo Emil): encerra os alertas "Saldo do BTG variou ... sem
-- movimentação lançada" criados pela atualização de 07/10. Ela veio quase um mês depois da
-- anterior e a faixa era semanal (0,5%), então quase todo cliente acendeu só por rendimento.
-- Cada alerta fica marcado como resolvido (não apagado) e o histórico do cliente ganha uma nota.
-- Também grava 07/10 como a data da última atualização onshore, de onde a faixa nova começa a contar.
-- Não faz parte do adami_completo.sql (é correção de dado, não estrutura).
with alvo as (
  select l.id from public.leads l
   where exists (select 1 from jsonb_array_elements(coalesce(l.alertas, '[]'::jsonb)) a
                  where a->>'tipo' = 'divergencia' and a->>'data' = '2026-10-07'
                    and not coalesce((a->>'resolvido')::boolean, false))
)
update public.leads l set
  alertas = (select jsonb_agg(case when a->>'tipo' = 'divergencia' and a->>'data' = '2026-10-07'
                                     and not coalesce((a->>'resolvido')::boolean, false)
                                   then a || jsonb_build_object('resolvido', true,
                                          'resolvidoEm', (extract(epoch from now()) * 1000)::bigint,
                                          'resolvidoPor', 'Hub Adami (limpeza de 07/11/2026)')
                                   else a end order by o)
               from jsonb_array_elements(l.alertas) with ordinality t(a, o)),
  historico = coalesce(l.historico, '[]'::jsonb) || jsonb_build_array(jsonb_build_object(
    'id', 'h-limpeza-0711-' || l.id, 'de', l.etapa, 'para', l.etapa,
    'data', (extract(epoch from now()) * 1000)::bigint,
    'resumo', 'Alerta de saldo do BTG de 07/10 encerrado: a atualização veio quase um mês depois da anterior e a faixa era semanal (0,5%). A diferença era rendimento do período, não aporte nem resgate.',
    'autor', 'Hub Adami', 'reconciliacao', true)),
  atualizado_em = now()
from alvo where alvo.id = l.id;

insert into public.configuracoes (chave, valor)
values ('btg_ultima_onshore', ((extract(epoch from timestamptz '2026-10-07 12:00:00-03') * 1000)::bigint)::text)
on conflict (chave) do nothing;

insert into public.auditoria (usuario, acao, alvo, detalhe)
values ('hub@adamicaptal.com.br', 'encerrou alertas de saldo', 'atualização BTG de 07/10', 'limpeza pedida pelo Emil em 07/11/2026');
