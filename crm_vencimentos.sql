-- Vencimentos das carteiras no painel do CRM (CRM 2026.11.19.2, 19/11/2026).
-- O cartão "Vencimentos" contava só os alertas lançados no cliente. Passa a trazer também o que vence dentro das
-- carteiras consolidadas: a lista de vencimentos de cada cliente (ind.vencimentos, que as Carteiras montam dos ativos
-- de renda fixa e COE) e os ativos com data de vencimento, do último mês lançado. O cliente das Carteiras é ligado à
-- ficha do CRM por clientes.lead_id ou, sem ele, pela conta do BTG vinculada no Cadastro (contas_btg = leads.conta).
-- Quando o mesmo título está nos ativos e na lista, fica o dos ativos (valor de hoje).
-- Janela: de 7 dias atrás até p_dias à frente (padrão 90). Só fichas que a pessoa pode ver (pode_ver_lead).
-- Rodar inteiro no SQL Editor (Run without RLS).
create or replace function public.crm_vencimentos(p_dias int default 90)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_ini text := to_char(current_date - 7, 'YYYY-MM-DD');
  v_fim text := to_char(current_date + greatest(1, least(coalesce(p_dias, 90), 400)), 'YYYY-MM-DD');
begin
  if not public.acesso_liberado() then raise exception 'Acesso não liberado.'; end if;
  return coalesce((
    with ult as (
      select distinct on (l.cliente_id) l.cliente_id, l.indicadores
        from public.lancamentos l order by l.cliente_id, l.ano desc, l.mes desc
    ), lig as (
      select c.id cliente_id, coalesce(c.lead_id, (
               select ld.id from public.leads ld
                where not coalesce(ld.excluido, false) and coalesce(ld.funil, 'assessor') = 'assessor' and coalesce(ld.conta, '') <> ''
                  and ltrim(regexp_replace(ld.conta, '\D', '', 'g'), '0') in
                      (select ltrim(regexp_replace(k, '\D', '', 'g'), '0') from unnest(coalesce(c.contas_btg, '{}')) k)
                limit 1)) lead_id
        from public.clientes c
    ), ativos as (
      select g.lead_id, a->>'nome' ativo, a->>'inst' inst, a->>'vencimento' data, public.btg_numero(a->>'posicao') valor
        from ult u join lig g on g.cliente_id = u.cliente_id
       cross join lateral jsonb_array_elements(coalesce(u.indicadores->'ativos', '[]')) a
       where a->>'vencimento' ~ '^\d{4}-\d{2}-\d{2}$'
    ), lista as (
      select g.lead_id, v->>'ativo' ativo, v->>'inst' inst, v->>'data' data, public.btg_numero(v->>'valor') valor
        from ult u join lig g on g.cliente_id = u.cliente_id
       cross join lateral jsonb_array_elements(coalesce(u.indicadores->'vencimentos', '[]')) v
       where v->>'data' ~ '^\d{4}-\d{2}-\d{2}$'
    ), unicos as (
      -- os ativos valem (valor de hoje); da lista de vencimentos só entra o título que não está nos ativos
      -- (mesmo cliente, mesma data, mesmo tipo: "LFSN", "CDB"...). Dois CDBs no mesmo dia continuam dois.
      select * from ativos where lead_id is not null and data between v_ini and v_fim
      union all
      select l.* from lista l
       where l.lead_id is not null and l.data between v_ini and v_fim
         and not exists (select 1 from ativos x where x.lead_id = l.lead_id and x.data = l.data
                            and split_part(upper(coalesce(x.ativo, '')), ' ', 1) = split_part(upper(coalesce(l.ativo, '')), ' ', 1))
    )
    select jsonb_agg(jsonb_build_object('lead_id', lead_id, 'ativo', ativo, 'inst', inst, 'data', data, 'valor', valor) order by data)
      from unicos where public.pode_ver_lead(lead_id)
  ), '[]'::jsonb);
end $$;
revoke all on function public.crm_vencimentos(int) from public, anon;
grant execute on function public.crm_vencimentos(int) to authenticated;
