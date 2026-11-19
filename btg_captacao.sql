-- Captação do BTG no CRM (19/11/2026, CRM 2026.11.19.9). Pedido do Emil: "coloca tudo aí no CRM".
-- O relatório rm-reports-nnm (captação líquida, pedido todo dia útil às 15h30 pela btg-sync) traz os últimos 30 dias,
-- um lançamento por linha: conta, data, mercado, tipo e valor (positivo entrou, negativo saiu).
-- crm_captacao() devolve as linhas do arquivo mais recente ligadas à ficha do CRM pela conta (mesma regra de
-- btg_caixa_crm). Quem vê só parte do CRM recebe só as linhas das próprias fichas; contas sem ficha no CRM só
-- aparecem para quem vê todos os clientes (entram no total da casa). O Dashboard soma o mês corrente.
-- Rodar inteiro no SQL Editor (Run without RLS).
create or replace function public.crm_captacao()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_vis text[]; v_arq bigint; v_em timestamptz;
begin
  if not public.acesso_liberado() then raise exception 'Acesso não liberado.'; end if;
  if not public.tem_permissao('ferramenta.crm') then return jsonb_build_object('linhas', '[]'::jsonb); end if;
  v_vis := public.crm_fichas_visiveis();
  select a.id, a.recebido_em into v_arq, v_em from public.btg_arquivos a
   where a.servico = 'rm-reports-nnm' and a.status = 'processado' order by a.id desc limit 1;
  if v_arq is null then return jsonb_build_object('linhas', '[]'::jsonb); end if;
  return jsonb_build_object('atualizado_em', v_em, 'linhas', coalesce((
    with ld as (
      select l.id, ltrim(regexp_replace(l.conta, '\D', '', 'g'), '0') k from public.leads l
       where not coalesce(l.excluido, false) and coalesce(l.conta, '') <> '' and coalesce(l.funil, 'assessor') = 'assessor'),
    li as (select ltrim(coalesce(x.dados->>'nr_conta', ''), '0') k, x.dados d from public.btg_linhas x where x.arquivo_id = v_arq)
    select jsonb_agg(jsonb_build_object(
             'lead_id', ld.id, 'conta', case when ld.id is null then li.k end,
             'data', li.d->>'data_captacao', 'valor', coalesce(public.btg_numero(li.d->>'captacao'), 0),
             'mercado', li.d->>'mercado', 'tipo', li.d->>'tipo_lancamento',
             'ativo', left(coalesce(li.d->>'ativo', ''), 80), 'descricao', left(coalesce(li.d->>'descricao', ''), 120),
             'abertura', b.dados->>'dt_abertura'))
      from li
      left join ld on ld.k = li.k
      left join public.btg_base b on ltrim(b.nr_conta, '0') = li.k
     where li.k <> '' and (v_vis is null or ld.id = any(v_vis))), '[]'::jsonb));
end $$;
revoke all on function public.crm_captacao() from public, anon;
grant execute on function public.crm_captacao() to authenticated;

-- NNM para o gerencial dos KPIs (19/11/2026, CRM 2026.11.19.11). Cada relatório diário traz os últimos 30 dias; aqui
-- juntam-se todos os que ainda estão guardados (120 dias, btg_limpeza) e, para cada data, valem as linhas do relatório
-- MAIS RECENTE que tem aquela data (o BTG pode corrigir um lançamento de um dia para o outro). Assim o histórico cresce
-- sozinho a cada dia. Mesma regra de visibilidade de crm_captacao. cobre_de = primeira data disponível.
create or replace function public.crm_nnm(p_de date, p_ate date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_vis text[]; v_em timestamptz; v_cobre date;
begin
  if not public.acesso_liberado() then raise exception 'Acesso não liberado.'; end if;
  if not public.tem_permissao('ferramenta.crm') then return jsonb_build_object('linhas', '[]'::jsonb); end if;
  v_vis := public.crm_fichas_visiveis();
  select max(a.recebido_em) into v_em from public.btg_arquivos a where a.servico = 'rm-reports-nnm' and a.status = 'processado';
  if v_em is null then return jsonb_build_object('linhas', '[]'::jsonb); end if;
  select min(left(x.dados->>'data_captacao', 10)::date) into v_cobre
    from public.btg_linhas x join public.btg_arquivos a on a.id = x.arquivo_id
   where a.servico = 'rm-reports-nnm' and a.status = 'processado' and coalesce(x.dados->>'data_captacao', '') ~ '^\d{4}-\d{2}-\d{2}';
  return jsonb_build_object('atualizado_em', v_em, 'cobre_de', v_cobre, 'linhas', coalesce((
    with li as (
      select x.arquivo_id, left(x.dados->>'data_captacao', 10)::date d, x.dados
        from public.btg_linhas x join public.btg_arquivos a on a.id = x.arquivo_id
       where a.servico = 'rm-reports-nnm' and a.status = 'processado'
         and coalesce(x.dados->>'data_captacao', '') ~ '^\d{4}-\d{2}-\d{2}'),
    ult as (select d, max(arquivo_id) a from li group by d),
    sel as (select li.d, li.dados, ltrim(coalesce(li.dados->>'nr_conta', ''), '0') k
              from li join ult on ult.d = li.d and ult.a = li.arquivo_id
             where (p_de is null or li.d >= p_de) and (p_ate is null or li.d <= p_ate)),
    ld as (
      select l.id, ltrim(regexp_replace(l.conta, '\D', '', 'g'), '0') k from public.leads l
       where not coalesce(l.excluido, false) and coalesce(l.conta, '') <> '' and coalesce(l.funil, 'assessor') = 'assessor')
    select jsonb_agg(jsonb_build_object(
             'lead_id', ld.id, 'conta', case when ld.id is null then sel.k end,
             'data', sel.d, 'valor', coalesce(public.btg_numero(sel.dados->>'captacao'), 0),
             'mercado', sel.dados->>'mercado', 'tipo', sel.dados->>'tipo_lancamento',
             'ativo', left(coalesce(sel.dados->>'ativo', ''), 80), 'descricao', left(coalesce(sel.dados->>'descricao', ''), 120),
             'abertura', b.dados->>'dt_abertura'))
      from sel
      left join ld on ld.k = sel.k
      left join public.btg_base b on ltrim(b.nr_conta, '0') = sel.k
     where sel.k <> '' and (v_vis is null or ld.id = any(v_vis))), '[]'::jsonb));
end $$;
revoke all on function public.crm_nnm(date, date) from public, anon;
grant execute on function public.crm_nnm(date, date) to authenticated;


-- crm_contas_novas (19/11/2026, Hub 3.38): contas abertas no BTG no mês, pela data de abertura
create or replace function public.crm_contas_novas()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_vis text[];
  v_ini date := date_trunc('month', now() at time zone 'America/Sao_Paulo')::date;
  v_ant date := (date_trunc('month', now() at time zone 'America/Sao_Paulo') - interval '1 month')::date;
begin
  if not public.acesso_liberado() then raise exception 'Acesso não liberado.'; end if;
  if not public.tem_permissao('ferramenta.crm') then return null; end if;
  v_vis := public.crm_fichas_visiveis();
  return (
    with b as (
      select ltrim(b.nr_conta, '0') k, left(b.dados->>'dt_abertura', 10)::date ab, coalesce(b.pl_total, 0) pl
        from public.btg_base b where coalesce(b.dados->>'dt_abertura', '') ~ '^\d{4}-\d{2}-\d{2}'),
    ld as (
      select l.id, ltrim(regexp_replace(l.conta, '\D', '', 'g'), '0') k from public.leads l
       where not coalesce(l.excluido, false) and coalesce(l.conta, '') <> '' and coalesce(l.funil, 'assessor') = 'assessor'),
    x as (select b.*, ld.id from b left join ld on ld.k = b.k where v_vis is null or ld.id = any(v_vis))
    select jsonb_build_object(
      'mes', count(*) filter (where ab >= v_ini),
      'pl_mes', coalesce(sum(pl) filter (where ab >= v_ini), 0),
      'mes_anterior', count(*) filter (where ab >= v_ant and ab < v_ini),
      'base_em', (select max(atualizado_em) from public.btg_base))
    from x);
end $$;
revoke all on function public.crm_contas_novas() from public, anon;
grant execute on function public.crm_contas_novas() to authenticated;
