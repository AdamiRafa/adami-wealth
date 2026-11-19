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
