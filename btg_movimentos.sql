-- ============================================================
--  8.17. ALERTA DE SALDO DO BTG: MOVIMENTAÇÕES QUE EXPLICAM A DIFERENÇA (07/11/2026)
--     Na "Atualizar do BTG" do CRM, as aplicações e resgates que o BTG informou
--     (rm-reports-movement, guardadas em btg_linhas) desde a última atualização
--     explicam a variação de saldo antes de virar alerta.
--     Conta: soma de vl_captacao das linhas com flag_nnm (dinheiro que entrou
--     ou saiu da conta); sem vl_captacao, vl_bruto com o sinal pelo tipo.
--     A calibrar com o primeiro arquivo real do BTG.
--     Pode rodar de novo sem estragar nada.
-- ============================================================
create or replace function public.btg_data(p text)
returns date language plpgsql immutable set search_path = public as $$
declare s text := btrim(coalesce(p, ''));
begin
  if s ~ '^\d{4}-\d{2}-\d{2}' then return left(s, 10)::date; end if;
  if s ~ '^\d{2}/\d{2}/\d{4}' then return to_date(left(s, 10), 'DD/MM/YYYY'); end if;
  return null;
exception when others then return null;
end $$;

create or replace function public.btg_movimentos_crm(p_desde date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  if not public.is_admin() then raise exception 'Só quem vê todos os clientes do CRM.'; end if;
  with linhas as (
    -- o mesmo movimento vem em vários arquivos (o BTG manda os últimos 20 dias a cada pedido)
    select distinct l.nr_conta, l.dados
      from public.btg_linhas l
      join public.btg_arquivos a on a.id = l.arquivo_id
     where a.servico in ('rm-reports-movement', 'rm-reports-monthly-movement') and l.nr_conta is not null
  ), mov as (
    select nr_conta,
           public.btg_data(dados->>'dt_movimentacao') dia,
           lower(btrim(coalesce(dados->>'flag_nnm', ''))) flag,
           public.btg_numero(dados->>'vl_captacao') cap,
           public.btg_numero(dados->>'vl_bruto') bruto,
           lower(coalesce(dados->>'tipo_operacao', '') || ' ' || coalesce(dados->>'tipo_lancamento', '') || ' '
                 || coalesce(dados->>'historico_movimentacao', '')) tipo
      from linhas
  ), por_conta as (
    select nr_conta,
           sum(coalesce(cap, case when tipo ~ '(resg|retir|debit|saida|saída|transf.*sai)' then -abs(bruto) else abs(bruto) end)) valor
      from mov
     where dia > p_desde and flag in ('s', 'sim', 'true', '1', 'y', 'yes')
     group by nr_conta
  )
  select jsonb_build_object('desde', p_desde, 'contas_com_movimento', count(*),
           'contas', coalesce(jsonb_object_agg(nr_conta, round(coalesce(valor, 0), 2)), '{}'::jsonb))
    into v from por_conta;
  return v;
end $$;
revoke all on function public.btg_movimentos_crm(date) from public, anon;
grant execute on function public.btg_movimentos_crm(date) to authenticated;
