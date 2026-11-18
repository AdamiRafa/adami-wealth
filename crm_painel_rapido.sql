-- Painel do CRM rápido (18/11/2026). Vencimentos e Dinheiro parado davam zero para o Emil: as duas funções conferiam
-- pode_ver_lead() linha a linha (~3 ms cada) sobre milhares de linhas da posição do BTG e estouravam o limite de 8 s
-- do Supabase. Agora a lista de fichas visíveis é calculada uma vez, por crm_fichas_visiveis(): null para quem vê
-- todas (administrador com o CRM liberado), senão os ids que pode_ver_lead() aceita.
-- Rodar inteiro no SQL Editor (Run without RLS).
create or replace function public.crm_fichas_visiveis()
returns text[] language plpgsql stable security definer set search_path = public as $$
begin
  if not public.acesso_liberado() then raise exception 'Acesso não liberado.'; end if;
  if public.tem_permissao('ferramenta.crm') and public.is_admin() then return null; end if;
  return array(select l.id from public.leads l where not coalesce(l.excluido, false) and public.pode_ver_lead(l.id));
end $$;
revoke all on function public.crm_fichas_visiveis() from public, anon, authenticated;
create or replace function public.btg_caixa_crm()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_vis text[];
begin
  if not public.acesso_liberado() then raise exception 'Acesso não liberado.'; end if;
  v_vis := public.crm_fichas_visiveis();
  return jsonb_build_object(
    'atualizado_em', (select max(atualizado_em) from public.btg_base),
    'leads', coalesce((
      select jsonb_object_agg(l.id, jsonb_build_object(
               'cc', coalesce(public.btg_numero(b.dados->>'pl_conta_corrente'), 0),
               'transito', coalesce(public.btg_numero(b.dados->>'pl_valores_transito'), 0)))
        from public.leads l
        join public.btg_base b on ltrim(b.nr_conta, '0') = ltrim(regexp_replace(coalesce(l.conta, ''), '\D', '', 'g'), '0')
       where not coalesce(l.excluido, false) and coalesce(l.conta, '') <> '' and (v_vis is null or l.id = any(v_vis))), '{}'::jsonb));
end $$;
revoke all on function public.btg_caixa_crm() from public, anon;
grant execute on function public.btg_caixa_crm() to authenticated;
create or replace function public.crm_vencimentos(p_dias int default 90)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_ini text := to_char(current_date - 7, 'YYYY-MM-DD');
  v_fim text := to_char(current_date + greatest(1, least(coalesce(p_dias, 90), 400)), 'YYYY-MM-DD');
  v_vis text[];
begin
  if not public.acesso_liberado() then raise exception 'Acesso não liberado.'; end if;
  v_vis := public.crm_fichas_visiveis();
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
    ), pos_arq as (
      select max(id) id from public.btg_arquivos where servico = 'rm-reports-position-by-date' and status = 'processado'
    ), lc as (
      select ld.id, ltrim(regexp_replace(ld.conta, '\D', '', 'g'), '0') k from public.leads ld
       where not coalesce(ld.excluido, false) and coalesce(ld.funil, 'assessor') = 'assessor' and coalesce(ld.conta, '') <> ''
    ), pos as (
      select ld.id lead_id,
             coalesce(nullif(p.dados->>'ativo', ''), nullif(p.dados->>'produto', ''), p.dados->>'sub_mercado') ativo,
             coalesce(nullif(p.dados->>'emissor', ''), 'BTG Pactual') inst,
             left(p.dados->>'dt_vencimento', 10) data,
             public.btg_numero(p.dados->>'vl_bruto') valor,
             case when p.dados->>'mercado' ilike 'VALOR EM TR%' then 'cotizacao' else 'vencimento' end tipo
        from public.btg_linhas p
        join pos_arq a on a.id = p.arquivo_id
        join lc ld on ld.k = ltrim(p.nr_conta, '0')
       where left(coalesce(p.dados->>'dt_vencimento', ''), 10) between v_ini and v_fim
         and (p.dados->>'mercado' in ('RENDA FIXA', 'COE')
              or (p.dados->>'mercado' ilike 'VALOR EM TR%' and p.dados->>'sub_mercado' in ('FN', 'PN')))
    ), unicos as (
      select lead_id, ativo, inst, data, valor, tipo from pos where data between v_ini and v_fim
      union all
      select lead_id, ativo, inst, data, valor, 'vencimento' from ativos
       where lead_id is not null and data between v_ini and v_fim
         and (not exists (select 1 from pos_arq where id is not null) or coalesce(inst, '') !~* 'btg|necton')
      union all
      select l.lead_id, l.ativo, l.inst, l.data, l.valor, 'vencimento' from lista l
       where l.lead_id is not null and l.data between v_ini and v_fim
         and (not exists (select 1 from pos_arq where id is not null) or coalesce(l.inst, '') !~* 'btg|necton')
         and not exists (select 1 from ativos x where x.lead_id = l.lead_id and x.data = l.data
                            and split_part(upper(coalesce(x.ativo, '')), ' ', 1) = split_part(upper(coalesce(l.ativo, '')), ' ', 1))
    )
    select jsonb_agg(jsonb_build_object('lead_id', lead_id, 'ativo', ativo, 'inst', inst, 'data', data, 'valor', valor, 'tipo', tipo) order by data)
      from unicos where v_vis is null or lead_id = any(v_vis)
  ), '[]'::jsonb);
end $$;
revoke all on function public.crm_vencimentos(int) from public, anon;
grant execute on function public.crm_vencimentos(int) to authenticated;
