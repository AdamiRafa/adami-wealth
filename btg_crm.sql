-- ============================================================
--  8.15. BTG FASE 2: ATUALIZAR A BASE DO CRM PELO BTG (06/11/2026)
--     O botão "Atualizar do BTG" na tela Atualizar base do CRM usa a base
--     que o BTG manda todo dia útil (rm-reports-account-base, guardada em
--     btg_base) e o assessor de cada conta (rm-reports-account-link, em
--     btg_vinculos), no mesmo formato da planilha. A comparação e a prévia
--     são as mesmas da planilha (crm.html, reconciliarBaseBTG): nada grava
--     antes de alguém aplicar.
--     Pode rodar de novo sem estragar nada.
-- ============================================================
create or replace function public.btg_base_crm()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  -- Mesma régua da tela: quem vê todos os clientes do CRM (crm.todos, que é o is_admin).
  if not public.is_admin() then
    raise exception 'Só quem vê todos os clientes do CRM pode atualizar a base.';
  end if;
  return jsonb_build_object(
    'atualizado_em', (select max(atualizado_em) from public.btg_base),
    'vinculos_em',   (select max(atualizado_em) from public.btg_vinculos),
    'linhas', coalesce((
      select jsonb_agg(jsonb_build_object(
               'Conta', b.nr_conta,
               'Nome', b.nome,
               'Sob Gestão', coalesce(b.pl_total, 0),
               'Assessor', coalesce(nullif(v.nm_officer, ''), b.nm_assessor, ''),
               'Código Assessor', coalesce(nullif(v.cge_officer, ''), b.cge_officer, '')
             ) order by b.nr_conta)
        from public.btg_base b
        left join public.btg_vinculos v on v.nr_conta = b.nr_conta), '[]'::jsonb));
end $$;
revoke all on function public.btg_base_crm() from public, anon;
grant execute on function public.btg_base_crm() to authenticated;
