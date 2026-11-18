-- Cadastro do cliente nas Carteiras (Hub 3.32, 19/11/2026): ao digitar o número de uma conta do BTG,
-- a tela mostra de quem é a conta e o saldo de hoje, para conferir antes de vincular.
-- Só devolve conta que a pessoa pode ver: quem vê todos os clientes (is_admin) ou o assessor da conta
-- (código da Equipe igual ao código do assessor no BTG). Rodar inteiro no SQL Editor (Run without RLS).
create or replace function public.btg_conta_info(p_contas text[])
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_cod text;
begin
  if not public.acesso_liberado() then raise exception 'Acesso não liberado.'; end if;
  select upper(btrim(codigo)) into v_cod from public.perfis where user_id = auth.uid();
  return coalesce((
    select jsonb_agg(jsonb_build_object('nr_conta', b.nr_conta, 'nome', b.nome, 'pl', b.pl_total,
             'assessor', coalesce(nullif(v.nm_officer, ''), b.nm_assessor), 'atualizado_em', b.atualizado_em))
      from public.btg_base b
      left join public.btg_vinculos v on v.nr_conta = b.nr_conta
     where ltrim(b.nr_conta, '0') in (select ltrim(regexp_replace(x, '\D', '', 'g'), '0') from unnest(p_contas) x)
       and (public.is_admin()
            or (v_cod is not null and v_cod = upper(btrim(coalesce(nullif(v.cge_officer, ''), b.cge_officer, '')))))
  ), '[]'::jsonb);
end $$;
revoke all on function public.btg_conta_info(text[]) from public, anon;
grant execute on function public.btg_conta_info(text[]) to authenticated;
