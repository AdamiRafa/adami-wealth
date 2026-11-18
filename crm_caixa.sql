-- Dinheiro parado em conta no painel do CRM (CRM 2026.11.19.1, 19/11/2026).
-- Saldo em conta corrente (pl_conta_corrente) e valores em trânsito de cada cliente, da base de contas que o BTG
-- manda todo dia útil (btg_base). Devolve só os clientes que a pessoa pode ver no CRM (pode_ver_lead).
-- Rodar inteiro no SQL Editor (Run without RLS).
create or replace function public.btg_caixa_crm()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.acesso_liberado() then raise exception 'Acesso não liberado.'; end if;
  return jsonb_build_object(
    'atualizado_em', (select max(atualizado_em) from public.btg_base),
    'leads', coalesce((
      select jsonb_object_agg(l.id, jsonb_build_object(
               'cc', coalesce(public.btg_numero(b.dados->>'pl_conta_corrente'), 0),
               'transito', coalesce(public.btg_numero(b.dados->>'pl_valores_transito'), 0)))
        from public.leads l
        join public.btg_base b on ltrim(b.nr_conta, '0') = ltrim(regexp_replace(coalesce(l.conta, ''), '\D', '', 'g'), '0')
       where not coalesce(l.excluido, false) and coalesce(l.conta, '') <> '' and public.pode_ver_lead(l.id)), '{}'::jsonb));
end $$;
revoke all on function public.btg_caixa_crm() from public, anon;
grant execute on function public.btg_caixa_crm() to authenticated;
