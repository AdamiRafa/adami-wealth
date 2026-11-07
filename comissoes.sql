-- ============================================================
--  8.18. COMISSÕES (07/11/2026, Hub 2.97)
--     Ferramenta Comissões (comissoes.html). Quem opera é o Financeiro
--     (Sarah); o master vê e, no começo, também opera. Ninguém mais.
--     Competência = mês do negócio; pagamento no mês seguinte.
--
--     Regras de repasse: uma por origem/empresa/produto, com a divisão em %
--     (BTG, escritório, assessor, especialista) e o imposto, e "vale a partir
--     de". O cálculo de cada lançamento é feito aqui no banco e guardado
--     (mudar a regra depois não mexe no que já foi lançado).
--
--     Tabelas fechadas (RLS sem política): tudo passa pelas funções abaixo,
--     que conferem comissoes.operar / comissoes.ver (tabela Perfis e acessos).
--     Pode rodar de novo sem estragar nada.
-- ============================================================

-- ---------- permissões ----------
insert into public.permissoes_catalogo (chave, tipo, nome, descricao, ordem, so_master) values
  ('comissoes.operar', 'atribuicao', 'Operar as comissões', 'Lançar, criar regras, fechar o mês, enviar os e-mails e marcar pagamentos.', 160, false),
  ('comissoes.ver',    'atribuicao', 'Ver as comissões', 'Só leitura: lançamentos, totais e pagamentos.', 165, false)
on conflict (chave) do update set tipo = excluded.tipo, nome = excluded.nome, descricao = excluded.descricao, ordem = excluded.ordem;
-- No começo o master também opera (pedido do Emil em 07/11/2026); depois ele desmarca em Perfis e acessos.
insert into public.permissoes_perfil (perfil, permissao, liberado, atualizado_por)
select pf.chave, pm.chave, pf.chave in ('master', 'financeiro'), 'instalação'
  from public.perfis_catalogo pf cross join (values ('comissoes.operar'), ('comissoes.ver')) pm(chave)
on conflict (perfil, permissao) do nothing;

create or replace function public.com_pode_operar() returns boolean language sql stable security definer set search_path = public as $$
  select public.tem_permissao('comissoes.operar');
$$;
create or replace function public.com_pode_ver() returns boolean language sql stable security definer set search_path = public as $$
  select public.tem_permissao('comissoes.ver') or public.tem_permissao('comissoes.operar');
$$;
revoke all on function public.com_pode_operar(), public.com_pode_ver() from public, anon;
grant execute on function public.com_pode_operar(), public.com_pode_ver() to authenticated;

-- ---------- tabelas ----------
create table if not exists public.comissao_dados_pagto (
  user_id        uuid primary key references auth.users(id) on delete cascade,
  nome_completo  text not null default '',
  cpf_cnpj       text not null default '',
  banco          text not null default '',
  agencia        text not null default '',
  conta          text not null default '',
  tipo_conta     text not null default '',
  pix_tipo       text not null default '',
  pix_chave      text not null default '',
  titular        text not null default '',
  observacao     text not null default '',
  atualizado_em  timestamptz not null default now(),
  atualizado_por text
);

create table if not exists public.comissao_regras (
  id               uuid primary key default gen_random_uuid(),
  nome             text not null check (char_length(btrim(nome)) between 1 and 120),
  origem           text not null check (origem in ('btg', 'seguro', 'consorcio', 'outro')),
  empresa          text not null default '',
  produto          text not null default '',
  pct_imposto      numeric(7,4) not null default 0 check (pct_imposto between 0 and 100),
  pct_btg          numeric(7,4) not null default 0 check (pct_btg between 0 and 100),
  pct_escritorio   numeric(7,4) not null default 0 check (pct_escritorio between 0 and 100),
  pct_assessor     numeric(7,4) not null default 0 check (pct_assessor between 0 and 100),
  pct_especialista numeric(7,4) not null default 0 check (pct_especialista between 0 and 100),
  vigencia_inicio  date not null default date '2026-10-01',
  vigencia_fim     date,
  ativo            boolean not null default true,
  obs              text not null default '',
  criado_em        timestamptz not null default now(),
  atualizado_em    timestamptz not null default now(),
  atualizado_por   text,
  constraint comissao_regras_soma check (abs(pct_btg + pct_escritorio + pct_assessor + pct_especialista - 100) < 0.01)
);

create table if not exists public.comissao_meses (
  competencia       date primary key check (extract(day from competencia) = 1),
  status            text not null default 'aberto' check (status in ('aberto', 'fechado')),
  fechado_em        timestamptz,
  fechado_por       text,
  reaberto_em       timestamptz,
  motivo_reabertura text
);

create table if not exists public.comissao_lancamentos (
  id               uuid primary key default gen_random_uuid(),
  competencia      date not null references public.comissao_meses(competencia),
  tipo             text not null check (tipo in ('receita', 'estorno', 'ajuste', 'saldo_anterior')),
  origem           text not null default 'outro' check (origem in ('btg', 'seguro', 'consorcio', 'outro', 'ajuste', 'saldo')),
  regra_id         uuid references public.comissao_regras(id),
  regra_nome       text not null default '',
  cliente          text not null default '',
  conta            text not null default '',
  empresa          text not null default '',
  produto          text not null default '',
  descricao        text not null default '',
  receita          numeric(16,2) not null default 0,
  imposto          numeric(16,2) not null default 0,
  valor_btg        numeric(16,2) not null default 0,
  valor_escritorio numeric(16,2) not null default 0,
  rateio           jsonb not null default '[]'::jsonb,   -- [{user_id, papel, valor}]
  gerado_por_fechamento date,                             -- saldo negativo levado do mês anterior
  criado_em        timestamptz not null default now(),
  criado_por       text,
  atualizado_em    timestamptz not null default now()
);
create index if not exists comissao_lanc_comp_idx on public.comissao_lancamentos (competencia);

create table if not exists public.comissao_pagamentos (
  competencia  date not null references public.comissao_meses(competencia),
  user_id      uuid not null references auth.users(id) on delete cascade,
  valor        numeric(16,2) not null,
  pago_em      date,
  pago_por     text,
  enviado_em   timestamptz,
  envio_erro   text,
  primary key (competencia, user_id)
);

alter table public.comissao_dados_pagto enable row level security;
alter table public.comissao_regras      enable row level security;
alter table public.comissao_meses       enable row level security;
alter table public.comissao_lancamentos enable row level security;
alter table public.comissao_pagamentos  enable row level security;
revoke all on public.comissao_dados_pagto, public.comissao_regras, public.comissao_meses,
  public.comissao_lancamentos, public.comissao_pagamentos from anon, authenticated;

-- Regra padrão do BTG (pedido do Emil): 50% BTG, 50% escritório e, desses, metade ao assessor.
insert into public.comissao_regras (nome, origem, pct_btg, pct_escritorio, pct_assessor, vigencia_inicio, obs, atualizado_por)
select 'BTG padrão', 'btg', 50, 25, 25, date '2026-10-01',
       'Padrão da casa: da receita, 50% fica com o BTG e 50% com o escritório; dos 50% do escritório, metade vai ao assessor.', 'instalação'
 where not exists (select 1 from public.comissao_regras where origem = 'btg');

-- ---------- funções internas ----------
create or replace function public.com_quem() returns text language sql stable set search_path = public as $$
  select coalesce(auth.jwt() ->> 'email', '?');
$$;
create or replace function public.com_mes(p date) returns date language sql immutable set search_path = public as $$
  select date_trunc('month', p)::date;
$$;
create or replace function public.com_garantir_mes(p date) returns void language sql security definer set search_path = public as $$
  insert into public.comissao_meses (competencia) values (public.com_mes(p)) on conflict do nothing;
$$;
create or replace function public.com_exigir_aberto(p date) returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.com_garantir_mes(p);
  if (select status from public.comissao_meses where competencia = public.com_mes(p)) <> 'aberto' then
    raise exception 'O mês de % está fechado. Reabra para mudar.', to_char(public.com_mes(p), 'MM/YYYY');
  end if;
end $$;
revoke all on function public.com_quem(), public.com_mes(date), public.com_garantir_mes(date), public.com_exigir_aberto(date)
  from public, anon, authenticated;

-- Total de cada pessoa num mês (soma do rateio).
create or replace function public.com_totais(p_comp date)
returns table (user_id uuid, total numeric, linhas int)
language sql stable security definer set search_path = public as $$
  select (r->>'user_id')::uuid, round(sum((r->>'valor')::numeric), 2), count(*)::int
    from public.comissao_lancamentos l, jsonb_array_elements(l.rateio) r
   where l.competencia = public.com_mes(p_comp) and nullif(r->>'user_id', '') is not null
   group by 1;
$$;
revoke all on function public.com_totais(date) from public, anon, authenticated;

-- ---------- leitura (tela) ----------
create or replace function public.comissoes_painel(p_competencia date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_comp date := public.com_mes(coalesce(p_competencia, now()::date));
begin
  if not public.com_pode_ver() then raise exception 'Seu perfil não tem acesso às comissões.'; end if;
  return jsonb_build_object(
    'competencia', v_comp,
    'pode_operar', public.com_pode_operar(),
    'mes', (select to_jsonb(m) from public.comissao_meses m where m.competencia = v_comp),
    'meses', coalesce((select jsonb_agg(jsonb_build_object('competencia', competencia, 'status', status) order by competencia desc) from public.comissao_meses), '[]'),
    'regras', coalesce((select jsonb_agg(to_jsonb(r) order by r.origem, r.empresa, r.produto, r.nome) from public.comissao_regras r), '[]'),
    'lancamentos', coalesce((select jsonb_agg(to_jsonb(l) order by l.criado_em) from public.comissao_lancamentos l where l.competencia = v_comp), '[]'),
    'totais', coalesce((select jsonb_agg(to_jsonb(t)) from public.com_totais(v_comp) t), '[]'),
    'pagamentos', coalesce((select jsonb_agg(to_jsonb(p)) from public.comissao_pagamentos p where p.competencia = v_comp), '[]'),
    'pessoas', coalesce((select jsonb_agg(jsonb_build_object(
        'user_id', p.user_id, 'nome', coalesce(nullif(p.nome, ''), split_part(u.email, '@', 1)), 'email', u.email,
        'codigo', p.codigo, 'papel_crm', pr.role, 'revogado', coalesce(u.banned_until > now(), false),
        'pagto', (select to_jsonb(d) from public.comissao_dados_pagto d where d.user_id = p.user_id))
        order by coalesce(nullif(p.nome, ''), u.email))
      from public.perfis p join auth.users u on u.id = p.user_id left join public.profiles pr on pr.id = p.user_id), '[]'));
end $$;
revoke all on function public.comissoes_painel(date) from public, anon;
grant execute on function public.comissoes_painel(date) to authenticated;

-- ---------- regras ----------
create or replace function public.comissao_regra_salvar(p jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid := nullif(p->>'id', '')::uuid;
begin
  if not public.com_pode_operar() then raise exception 'Seu perfil não pode mexer nas regras.'; end if;
  if v_id is null then
    insert into public.comissao_regras (nome, origem, empresa, produto, pct_imposto, pct_btg, pct_escritorio, pct_assessor,
      pct_especialista, vigencia_inicio, vigencia_fim, ativo, obs, atualizado_por)
    values (btrim(p->>'nome'), p->>'origem', btrim(coalesce(p->>'empresa', '')), btrim(coalesce(p->>'produto', '')),
      coalesce((p->>'pct_imposto')::numeric, 0), coalesce((p->>'pct_btg')::numeric, 0), coalesce((p->>'pct_escritorio')::numeric, 0),
      coalesce((p->>'pct_assessor')::numeric, 0), coalesce((p->>'pct_especialista')::numeric, 0),
      coalesce(nullif(p->>'vigencia_inicio', '')::date, date '2026-10-01'), nullif(p->>'vigencia_fim', '')::date,
      coalesce((p->>'ativo')::boolean, true), coalesce(p->>'obs', ''), public.com_quem())
    returning id into v_id;
    insert into public.auditoria (usuario, acao, alvo, detalhe) values (public.com_quem(), 'criou regra de repasse', p->>'nome', '');
  else
    update public.comissao_regras set nome = btrim(p->>'nome'), origem = p->>'origem',
      empresa = btrim(coalesce(p->>'empresa', '')), produto = btrim(coalesce(p->>'produto', '')),
      pct_imposto = coalesce((p->>'pct_imposto')::numeric, 0), pct_btg = coalesce((p->>'pct_btg')::numeric, 0),
      pct_escritorio = coalesce((p->>'pct_escritorio')::numeric, 0), pct_assessor = coalesce((p->>'pct_assessor')::numeric, 0),
      pct_especialista = coalesce((p->>'pct_especialista')::numeric, 0),
      vigencia_inicio = coalesce(nullif(p->>'vigencia_inicio', '')::date, vigencia_inicio), vigencia_fim = nullif(p->>'vigencia_fim', '')::date,
      ativo = coalesce((p->>'ativo')::boolean, ativo), obs = coalesce(p->>'obs', obs),
      atualizado_em = now(), atualizado_por = public.com_quem()
     where id = v_id;
    if not found then raise exception 'Regra não encontrada.'; end if;
    insert into public.auditoria (usuario, acao, alvo, detalhe) values (public.com_quem(), 'alterou regra de repasse', p->>'nome', '');
  end if;
  return v_id;
exception when check_violation then
  raise exception 'A divisão precisa somar 100%% (BTG + escritório + assessor + especialista), e cada percentual entre 0 e 100.';
end $$;

create or replace function public.comissao_regra_excluir(p_id uuid)
returns text language plpgsql security definer set search_path = public as $$
declare v_nome text;
begin
  if not public.com_pode_operar() then raise exception 'Seu perfil não pode mexer nas regras.'; end if;
  select nome into v_nome from public.comissao_regras where id = p_id;
  if v_nome is null then raise exception 'Regra não encontrada.'; end if;
  if exists (select 1 from public.comissao_lancamentos where regra_id = p_id) then
    update public.comissao_regras set ativo = false, atualizado_em = now(), atualizado_por = public.com_quem() where id = p_id;
    insert into public.auditoria (usuario, acao, alvo, detalhe) values (public.com_quem(), 'desativou regra de repasse', v_nome, 'já usada em lançamentos');
    return 'desativada';
  end if;
  delete from public.comissao_regras where id = p_id;
  insert into public.auditoria (usuario, acao, alvo, detalhe) values (public.com_quem(), 'excluiu regra de repasse', v_nome, '');
  return 'excluida';
end $$;

-- ---------- lançamentos ----------
-- p: {id?, competencia, tipo: receita|estorno|ajuste, origem, regra_id, cliente, conta, empresa, produto, descricao,
--     receita (valor recebido pelo escritório/BTG, sempre positivo), assessor_id, especialista_id,
--     valor_assessor (BTG: o repasse que o relatório já traz), pessoa_id + valor (ajuste, com sinal)}
create or replace function public.comissao_lancamento_salvar(p jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_id uuid := nullif(p->>'id', '')::uuid;
  v_comp date := public.com_mes(coalesce(nullif(p->>'competencia', '')::date, now()::date));
  v_tipo text := coalesce(p->>'tipo', 'receita');
  v_origem text := coalesce(nullif(p->>'origem', ''), 'outro');
  v_regra public.comissao_regras;
  v_sinal int := case when coalesce(p->>'tipo', 'receita') = 'estorno' then -1 else 1 end;
  v_receita numeric; v_imp numeric := 0; v_liq numeric; v_btg numeric := 0; v_esc numeric := 0;
  v_ass uuid := nullif(p->>'assessor_id', '')::uuid; v_esp uuid := nullif(p->>'especialista_id', '')::uuid;
  v_rateio jsonb := '[]'::jsonb; v_va numeric; v_ve numeric;
begin
  if not public.com_pode_operar() then raise exception 'Seu perfil não pode lançar comissões.'; end if;
  perform public.com_exigir_aberto(v_comp);
  if v_id is not null then
    if (select competencia from public.comissao_lancamentos where id = v_id) is distinct from v_comp then
      perform public.com_exigir_aberto((select competencia from public.comissao_lancamentos where id = v_id));
    end if;
  end if;

  if v_tipo = 'ajuste' then
    if nullif(p->>'pessoa_id', '') is null then raise exception 'Escolha a pessoa do ajuste.'; end if;
    if coalesce((p->>'valor')::numeric, 0) = 0 then raise exception 'Informe o valor do ajuste (negativo para descontar).'; end if;
    if char_length(btrim(coalesce(p->>'descricao', ''))) < 3 then raise exception 'Escreva o motivo do ajuste.'; end if;
    v_rateio := jsonb_build_array(jsonb_build_object('user_id', p->>'pessoa_id', 'papel', 'ajuste', 'valor', round((p->>'valor')::numeric, 2)));
    v_origem := 'ajuste'; v_receita := 0;
  elsif v_tipo in ('receita', 'estorno') then
    v_receita := round(abs(coalesce((p->>'receita')::numeric, 0)), 2);
    if v_receita = 0 and nullif(p->>'valor_assessor', '') is null then raise exception 'Informe o valor da receita.'; end if;
    if nullif(p->>'regra_id', '') is not null then
      select * into v_regra from public.comissao_regras where id = (p->>'regra_id')::uuid;
      if v_regra.id is null then raise exception 'Regra não encontrada.'; end if;
      v_origem := v_regra.origem;
    end if;
    if v_origem = 'btg' and nullif(p->>'valor_assessor', '') is not null then
      -- O relatório do BTG já traz a divisão: usa os valores dele.
      v_va := round(abs((p->>'valor_assessor')::numeric), 2);
      v_esc := round(abs(coalesce((p->>'valor_escritorio')::numeric, 0)), 2);
      v_btg := round(abs(coalesce((p->>'valor_btg')::numeric, 0)), 2);
      if v_ass is null then raise exception 'Escolha o assessor.'; end if;
      v_rateio := jsonb_build_array(jsonb_build_object('user_id', v_ass, 'papel', 'assessor', 'valor', v_sinal * v_va));
    else
      if v_regra.id is null then raise exception 'Escolha a regra de repasse.'; end if;
      if v_regra.pct_assessor > 0 and v_ass is null then raise exception 'Esta regra paga assessor: escolha o assessor.'; end if;
      if v_regra.pct_especialista > 0 and v_esp is null then raise exception 'Esta regra paga especialista: escolha o especialista.'; end if;
      v_imp := round(v_receita * v_regra.pct_imposto / 100, 2);
      v_liq := v_receita - v_imp;
      v_btg := round(v_liq * v_regra.pct_btg / 100, 2);
      v_va := round(v_liq * v_regra.pct_assessor / 100, 2);
      v_ve := round(v_liq * v_regra.pct_especialista / 100, 2);
      v_esc := v_liq - v_btg - v_va - v_ve;   -- o centavo do arredondamento fica com o escritório
      if v_va <> 0 then v_rateio := v_rateio || jsonb_build_array(jsonb_build_object('user_id', v_ass, 'papel', 'assessor', 'valor', v_sinal * v_va)); end if;
      if v_ve <> 0 then v_rateio := v_rateio || jsonb_build_array(jsonb_build_object('user_id', v_esp, 'papel', 'especialista', 'valor', v_sinal * v_ve)); end if;
    end if;
  else
    raise exception 'Tipo de lançamento inválido.';
  end if;

  if v_id is null then
    insert into public.comissao_lancamentos (competencia, tipo, origem, regra_id, regra_nome, cliente, conta, empresa, produto, descricao,
      receita, imposto, valor_btg, valor_escritorio, rateio, criado_por)
    values (v_comp, v_tipo, v_origem, v_regra.id, coalesce(v_regra.nome, ''), btrim(coalesce(p->>'cliente', '')), btrim(coalesce(p->>'conta', '')),
      btrim(coalesce(p->>'empresa', coalesce(v_regra.empresa, ''))), btrim(coalesce(p->>'produto', coalesce(v_regra.produto, ''))),
      btrim(coalesce(p->>'descricao', '')), v_sinal * v_receita, v_sinal * v_imp, v_sinal * v_btg, v_sinal * v_esc, v_rateio, public.com_quem())
    returning id into v_id;
  else
    update public.comissao_lancamentos set competencia = v_comp, tipo = v_tipo, origem = v_origem, regra_id = v_regra.id,
      regra_nome = coalesce(v_regra.nome, ''), cliente = btrim(coalesce(p->>'cliente', '')), conta = btrim(coalesce(p->>'conta', '')),
      empresa = btrim(coalesce(p->>'empresa', '')), produto = btrim(coalesce(p->>'produto', '')), descricao = btrim(coalesce(p->>'descricao', '')),
      receita = v_sinal * v_receita, imposto = v_sinal * v_imp, valor_btg = v_sinal * v_btg, valor_escritorio = v_sinal * v_esc,
      rateio = v_rateio, atualizado_em = now()
     where id = v_id and gerado_por_fechamento is null;
    if not found then raise exception 'Lançamento não encontrado (ou é o saldo levado do mês anterior, que não se edita).'; end if;
  end if;
  insert into public.auditoria (usuario, acao, alvo, detalhe)
  values (public.com_quem(), 'lançou comissão', to_char(v_comp, 'MM/YYYY'),
          v_tipo || ' ' || v_origem || ' ' || coalesce(nullif(p->>'cliente', ''), coalesce(p->>'descricao', '')) || ' ' || to_char(v_receita, 'FM999G999G990D00'));
  return v_id;
end $$;

create or replace function public.comissao_lancamento_excluir(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_comp date;
begin
  if not public.com_pode_operar() then raise exception 'Seu perfil não pode mexer nas comissões.'; end if;
  select competencia into v_comp from public.comissao_lancamentos where id = p_id and gerado_por_fechamento is null;
  if v_comp is null then raise exception 'Lançamento não encontrado (o saldo levado do mês anterior sai reabrindo aquele mês).'; end if;
  perform public.com_exigir_aberto(v_comp);
  delete from public.comissao_lancamentos where id = p_id;
  insert into public.auditoria (usuario, acao, alvo, detalhe) values (public.com_quem(), 'excluiu lançamento de comissão', to_char(v_comp, 'MM/YYYY'), p_id::text);
end $$;

-- Vários de uma vez (colar planilha do BTG). Cada item é o mesmo jsonb de comissao_lancamento_salvar;
-- "codigo" (código do assessor na Equipe) vale no lugar de assessor_id.
create or replace function public.comissao_lancamentos_lote(p_competencia date, p_itens jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare it jsonb; n int := 0; erros jsonb := '[]'::jsonb; i int := 0; v_ass uuid;
begin
  if not public.com_pode_operar() then raise exception 'Seu perfil não pode lançar comissões.'; end if;
  for it in select * from jsonb_array_elements(coalesce(p_itens, '[]'::jsonb)) loop
    i := i + 1;
    begin
      v_ass := nullif(it->>'assessor_id', '')::uuid;
      if v_ass is null and nullif(it->>'codigo', '') is not null then
        select user_id into v_ass from public.perfis where upper(btrim(codigo)) = upper(btrim(it->>'codigo')) limit 1;
        if v_ass is null then raise exception 'código de assessor % não está na Equipe', it->>'codigo'; end if;
      end if;
      perform public.comissao_lancamento_salvar(it || jsonb_build_object('competencia', p_competencia, 'assessor_id', v_ass));
      n := n + 1;
    exception when others then
      erros := erros || jsonb_build_array(jsonb_build_object('linha', i, 'erro', sqlerrm));
    end;
  end loop;
  return jsonb_build_object('gravados', n, 'erros', erros);
end $$;

-- ---------- fechamento ----------
create or replace function public.comissao_fechar(p_competencia date)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_comp date := public.com_mes(p_competencia); v_prox date := (public.com_mes(p_competencia) + interval '1 month')::date;
        t record; n_pag int := 0; n_neg int := 0;
begin
  if not public.com_pode_operar() then raise exception 'Seu perfil não pode fechar o mês.'; end if;
  perform public.com_exigir_aberto(v_comp);
  if not exists (select 1 from public.comissao_lancamentos where competencia = v_comp) then raise exception 'Não há lançamentos neste mês.'; end if;
  perform public.com_garantir_mes(v_prox);
  if (select status from public.comissao_meses where competencia = v_prox) <> 'aberto' then
    raise exception 'O mês seguinte já está fechado; reabra-o antes.';
  end if;
  delete from public.comissao_pagamentos where competencia = v_comp;
  for t in select * from public.com_totais(v_comp) loop
    if t.total > 0 then
      insert into public.comissao_pagamentos (competencia, user_id, valor) values (v_comp, t.user_id, t.total);
      n_pag := n_pag + 1;
    elsif t.total < 0 then
      -- Fechou negativo: o saldo passa para o mês seguinte.
      insert into public.comissao_lancamentos (competencia, tipo, origem, descricao, rateio, gerado_por_fechamento, criado_por)
      values (v_prox, 'saldo_anterior', 'saldo', 'Saldo negativo de ' || to_char(v_comp, 'MM/YYYY'),
              jsonb_build_array(jsonb_build_object('user_id', t.user_id, 'papel', 'saldo anterior', 'valor', t.total)), v_comp, public.com_quem());
      n_neg := n_neg + 1;
    end if;
  end loop;
  update public.comissao_meses set status = 'fechado', fechado_em = now(), fechado_por = public.com_quem() where competencia = v_comp;
  insert into public.auditoria (usuario, acao, alvo, detalhe)
  values (public.com_quem(), 'fechou comissões', to_char(v_comp, 'MM/YYYY'), n_pag || ' a pagar, ' || n_neg || ' saldo(s) negativo(s) levado(s)');
  return jsonb_build_object('a_pagar', n_pag, 'negativos', n_neg);
end $$;

create or replace function public.comissao_reabrir(p_competencia date, p_motivo text)
returns void language plpgsql security definer set search_path = public as $$
declare v_comp date := public.com_mes(p_competencia); v_prox date := (public.com_mes(p_competencia) + interval '1 month')::date;
begin
  if not public.com_pode_operar() then raise exception 'Seu perfil não pode reabrir o mês.'; end if;
  if char_length(btrim(coalesce(p_motivo, ''))) < 3 then raise exception 'Escreva o motivo da reabertura.'; end if;
  if (select status from public.comissao_meses where competencia = v_comp) is distinct from 'fechado' then raise exception 'O mês não está fechado.'; end if;
  if (select status from public.comissao_meses where competencia = v_prox) = 'fechado' then raise exception 'O mês seguinte já foi fechado; reabra-o primeiro.'; end if;
  if exists (select 1 from public.comissao_pagamentos where competencia = v_comp and pago_em is not null) then
    raise exception 'Já há pagamento marcado como feito neste mês. Desmarque antes de reabrir.';
  end if;
  delete from public.comissao_lancamentos where competencia = v_prox and gerado_por_fechamento = v_comp;
  delete from public.comissao_pagamentos where competencia = v_comp;
  update public.comissao_meses set status = 'aberto', reaberto_em = now(), motivo_reabertura = btrim(p_motivo) where competencia = v_comp;
  insert into public.auditoria (usuario, acao, alvo, detalhe) values (public.com_quem(), 'reabriu comissões', to_char(v_comp, 'MM/YYYY'), btrim(p_motivo));
end $$;

create or replace function public.comissao_marcar_pago(p_competencia date, p_user uuid, p_data date)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.com_pode_operar() then raise exception 'Seu perfil não pode marcar pagamentos.'; end if;
  update public.comissao_pagamentos set pago_em = p_data, pago_por = case when p_data is null then null else public.com_quem() end
   where competencia = public.com_mes(p_competencia) and user_id = p_user;
  if not found then raise exception 'Pagamento não encontrado (o mês precisa estar fechado).'; end if;
  insert into public.auditoria (usuario, acao, alvo, detalhe)
  values (public.com_quem(), case when p_data is null then 'desmarcou pagamento de comissão' else 'marcou comissão paga' end,
          to_char(public.com_mes(p_competencia), 'MM/YYYY'), (select email from auth.users where id = p_user));
end $$;

-- ---------- dados de pagamento ----------
-- Quem opera comissões lê e grava; o master também, pela ficha da pessoa na Equipe.
create or replace function public.comissao_dados_pagto_ler(p_user uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not (public.com_pode_ver() or public.eh_super()) then raise exception 'Sem acesso aos dados de pagamento.'; end if;
  return (select to_jsonb(d) from public.comissao_dados_pagto d where d.user_id = p_user);
end $$;
create or replace function public.comissao_dados_pagto_salvar(p_user uuid, p jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not (public.com_pode_operar() or public.eh_super()) then raise exception 'Sem permissão para mudar dados de pagamento.'; end if;
  if not exists (select 1 from auth.users where id = p_user) then raise exception 'Pessoa não encontrada.'; end if;
  insert into public.comissao_dados_pagto as d (user_id, nome_completo, cpf_cnpj, banco, agencia, conta, tipo_conta, pix_tipo, pix_chave, titular, observacao, atualizado_em, atualizado_por)
  values (p_user, left(btrim(coalesce(p->>'nome_completo', '')), 160), left(btrim(coalesce(p->>'cpf_cnpj', '')), 30),
          left(btrim(coalesce(p->>'banco', '')), 80), left(btrim(coalesce(p->>'agencia', '')), 20), left(btrim(coalesce(p->>'conta', '')), 30),
          left(btrim(coalesce(p->>'tipo_conta', '')), 30), left(btrim(coalesce(p->>'pix_tipo', '')), 30), left(btrim(coalesce(p->>'pix_chave', '')), 120),
          left(btrim(coalesce(p->>'titular', '')), 160), left(btrim(coalesce(p->>'observacao', '')), 500), now(), public.com_quem())
  on conflict (user_id) do update set nome_completo = excluded.nome_completo, cpf_cnpj = excluded.cpf_cnpj, banco = excluded.banco,
    agencia = excluded.agencia, conta = excluded.conta, tipo_conta = excluded.tipo_conta, pix_tipo = excluded.pix_tipo,
    pix_chave = excluded.pix_chave, titular = excluded.titular, observacao = excluded.observacao, atualizado_em = now(), atualizado_por = excluded.atualizado_por;
  insert into public.auditoria (usuario, acao, alvo, detalhe) values (public.com_quem(), 'alterou dados de pagamento', (select email from auth.users where id = p_user), '');
end $$;

-- ---------- envio (usado pela função comissoes-enviar, com a sessão de quem clicou) ----------
create or replace function public.comissao_envio_lista(p_competencia date)
returns table (user_id uuid, nome text, email text, total numeric)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.com_pode_operar() then raise exception 'Seu perfil não pode enviar as comissões.'; end if;
  if (select status from public.comissao_meses where competencia = public.com_mes(p_competencia)) is distinct from 'fechado' then
    raise exception 'Feche o mês antes de enviar.';
  end if;
  return query
    select t.user_id, coalesce(nullif(p.nome, ''), split_part(u.email, '@', 1))::text, u.email::text, t.total
      from public.com_totais(p_competencia) t join auth.users u on u.id = t.user_id left join public.perfis p on p.user_id = t.user_id;
end $$;
create or replace function public.comissao_envio_registrar(p_competencia date, p_user uuid, p_erro text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.com_pode_operar() then raise exception 'Sem permissão.'; end if;
  update public.comissao_pagamentos set enviado_em = case when p_erro is null then now() else enviado_em end, envio_erro = p_erro
   where competencia = public.com_mes(p_competencia) and user_id = p_user;
  if p_erro is null then
    insert into public.auditoria (usuario, acao, alvo, detalhe)
    values (public.com_quem(), 'enviou comissão por e-mail', to_char(public.com_mes(p_competencia), 'MM/YYYY'), (select email from auth.users where id = p_user));
  end if;
end $$;

revoke all on function public.comissao_regra_salvar(jsonb), public.comissao_regra_excluir(uuid),
  public.comissao_lancamento_salvar(jsonb), public.comissao_lancamento_excluir(uuid), public.comissao_lancamentos_lote(date, jsonb),
  public.comissao_fechar(date), public.comissao_reabrir(date, text), public.comissao_marcar_pago(date, uuid, date),
  public.comissao_dados_pagto_ler(uuid), public.comissao_dados_pagto_salvar(uuid, jsonb),
  public.comissao_envio_lista(date), public.comissao_envio_registrar(date, uuid, text) from public, anon;
grant execute on function public.comissao_regra_salvar(jsonb), public.comissao_regra_excluir(uuid),
  public.comissao_lancamento_salvar(jsonb), public.comissao_lancamento_excluir(uuid), public.comissao_lancamentos_lote(date, jsonb),
  public.comissao_fechar(date), public.comissao_reabrir(date, text), public.comissao_marcar_pago(date, uuid, date),
  public.comissao_dados_pagto_ler(uuid), public.comissao_dados_pagto_salvar(uuid, jsonb),
  public.comissao_envio_lista(date), public.comissao_envio_registrar(date, uuid, text) to authenticated;

select public.com_garantir_mes(date '2026-10-01');
