-- Atualização automática da base do CRM pelo BTG (18/11/2026, CRM 2026.11.18.1).
-- A função btg-base-auto (Edge Functions) aplica sozinha, todo dia útil, a base de contas que o BTG
-- manda às 8h30: o mesmo que o botão "Atualizar do BTG" + "Aplicar" do CRM, com as mesmas regras
-- (regras.js é gerado do crm.html). Ver DOCUMENTACAO.md seção 23.11.
-- Rodar inteiro no SQL Editor (o aviso "Potential issues detected" é falso positivo: Run without RLS).

-- 1. Movimentações informadas pelo BTG desde uma data, por conta. A conta sai daqui; quem chama pela
--    tela continua sendo btg_movimentos_crm (confere se é admin). Esta só a chave de serviço executa.
create or replace function public.btg_movimentos_calc(p_desde date)
returns jsonb language sql stable security definer set search_path = public as $$
  with linhas as (
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
    from por_conta;
$$;
revoke all on function public.btg_movimentos_calc(date) from public, anon, authenticated;
grant execute on function public.btg_movimentos_calc(date) to service_role;

create or replace function public.btg_movimentos_crm(p_desde date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Só quem vê todos os clientes do CRM.'; end if;
  return public.btg_movimentos_calc(p_desde);
end $$;
revoke all on function public.btg_movimentos_crm(date) from public, anon;
grant execute on function public.btg_movimentos_crm(date) to authenticated;

-- 2. Agendamento: 9h15 e 11h15 de Brasília (12h15 e 14h15 UTC), dias úteis. A segunda rodada só
--    age se a base do dia chegou atrasada: cada base é aplicada uma vez só.
do $$ begin perform cron.unschedule('btg-base-auto'); exception when others then null; end $$;
select cron.schedule('btg-base-auto', '15 12,14 * * 1-5', $c$
  select net.http_post(
    url := 'https://ghxjqmjtmbqzvogwzylo.supabase.co/functions/v1/btg-base-auto',
    headers := jsonb_build_object('Content-Type', 'application/json',
      'x-btg-sync', (select decrypted_secret from vault.decrypted_secrets where name = 'btg_sync_token')),
    body := '{}'::jsonb, timeout_milliseconds := 120000);
$c$);
