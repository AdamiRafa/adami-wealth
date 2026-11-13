-- ============================================================
-- seguranca_326.sql · Hub 3.26 (13/11/2026) · varredura de segurança e desempenho
--
-- Já aplicado pelo Claude (migração seguranca_desempenho_326). Fica aqui para o histórico
-- e para o adami_completo.sql. Pode rodar mais de uma vez.
--
-- 1. meu_cliente, lead_meu e lead_origem_minha passam a exigir a verificação do dia
--    (acesso_liberado). Elas rodam como dono do banco (security definer) e por isso não
--    passam pela política exige_verificacao das tabelas: quem tinha só a senha, sem o
--    código do dia, conseguia chamar btg_rent_cliente e btg_sugerir_contas (que usam
--    meu_cliente) e receber dados dos próprios clientes.
-- 2. Políticas de acesso: chamadas sem argumento de linha (auth.uid(), is_admin()...) vão
--    dentro de (select ...), calculadas uma vez por consulta e não uma vez por linha.
-- 3. Índices nas chaves estrangeiras usadas em filtros.
-- ============================================================

create or replace function public.meu_cliente(cid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select public.acesso_liberado() and exists(
    select 1 from public.clientes c
    where c.id = cid and (c.assessor_id = auth.uid() or public.eh_admin()));
$$;
create or replace function public.lead_meu(p_id text)
returns boolean language sql stable security definer set search_path = public as $$
  select public.acesso_liberado() and exists (
    select 1 from public.leads where id = p_id and responsavel_id = auth.uid());
$$;
create or replace function public.lead_origem_minha(p_id text)
returns boolean language sql stable security definer set search_path = public as $$
  select public.acesso_liberado() and exists (
    select 1 from public.leads where origem_lead_id = p_id and responsavel_id = auth.uid());
$$;
revoke all on function public.meu_cliente(uuid) from public, anon;
revoke all on function public.lead_meu(text) from public, anon;
revoke all on function public.lead_origem_minha(text) from public, anon;
grant execute on function public.meu_cliente(uuid) to authenticated;
grant execute on function public.lead_meu(text) to authenticated;
grant execute on function public.lead_origem_minha(text) to authenticated;

do $$
declare p record; q text; c text; re text :=
  '(?<!SELECT )\m(auth\.uid|auth\.jwt|is_admin|is_ativo|eh_admin|eh_super|pode_editar_rv|pode_publicar_aviso|acesso_liberado)\(\)';
begin
  for p in select schemaname, tablename, policyname, cmd, qual, with_check from pg_policies
           where schemaname in ('public','storage')
             and (coalesce(qual,'') || coalesce(with_check,'')) ~ re
  loop
    q := case when p.qual is null then null else regexp_replace(p.qual, re, '(SELECT \1())', 'g') end;
    c := case when p.with_check is null then null else regexp_replace(p.with_check, re, '(SELECT \1())', 'g') end;
    if q is not null and c is not null then
      execute format('alter policy %I on %I.%I using (%s) with check (%s)', p.policyname, p.schemaname, p.tablename, q, c);
    elsif q is not null then
      execute format('alter policy %I on %I.%I using (%s)', p.policyname, p.schemaname, p.tablename, q);
    elsif c is not null then
      execute format('alter policy %I on %I.%I with check (%s)', p.policyname, p.schemaname, p.tablename, c);
    end if;
  end loop;
end $$;

create index if not exists anexos_enviado_por_idx on public.anexos (enviado_por);
create index if not exists avisos_leitura_user_idx on public.avisos_leitura (user_id);
create index if not exists lancamentos_feito_por_idx on public.lancamentos (feito_por);
create index if not exists tarefas_criado_por_idx on public.tarefas (criado_por);
create index if not exists problemas_user_idx on public.problemas (user_id);
create index if not exists relatorios_envios_por_idx on public.relatorios_envios (enviado_por);
create index if not exists rv_alocacoes_cliente_idx on public.rv_alocacoes (cliente_id);
create index if not exists comissao_lanc_origem_idx on public.comissao_lancamentos (origem_id);
create index if not exists comissao_lanc_regra_idx on public.comissao_lancamentos (regra_id);
create index if not exists comissao_pag_user_idx on public.comissao_pagamentos (user_id);
create index if not exists comissao_fixos_user_idx on public.comissao_fixos (user_id);
