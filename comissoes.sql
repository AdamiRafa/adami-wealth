-- ============================================================
--  8.18. COMISSÕES 2.0 (07/11/2026, Hub 2.98)
--     Ferramenta Comissões (comissoes.html) e "Minha comissão"
--     (minha-comissao.html). Quem opera é o Financeiro (Sarah); o master
--     vê e, no começo, também opera. O assessor só vê o próprio fechamento,
--     e só depois que a Sarah libera o mês.
--     Competência = mês do negócio; pagamento no mês seguinte.
--
--     Como o cálculo funciona (motor único, com_calcular):
--       1. Cada linha da planilha (cliente, conta, profissional, categoria,
--          produto, comissão) passa pela TROCA DE CAMPOS (ex.: nome comprido
--          do BTG -> pessoa do cadastro; ex-assessor -> ESCRITORIO).
--       2. O profissional é reconhecido pelo código da Equipe, nome, e-mail,
--          nome completo ou "nomes nas planilhas" (dados de pagamento).
--       3. A primeira REGRA (pela prioridade) cujas condições batem divide a
--          comissão entre os recebedores: o próprio profissional da linha,
--          uma pessoa fixa ou o escritório, em % ou "o restante".
--       4. Imposto é por EMPRESA PAGADORA (a PJ que paga a pessoa): sai da
--          comissão bruta da pessoa e dá a líquida.
--     Valores das linhas guardados com 6 casas; arredonda só nos totais.
--     A planilha original (linhas cruas) fica guardada: dá para recalcular
--     depois de criar uma regra ou uma troca, e para excluir a planilha.
--
--     Tabelas fechadas (RLS sem política): tudo passa pelas funções abaixo,
--     que conferem comissoes.operar / comissoes.ver (Perfis e acessos).
--     Pode rodar de novo sem estragar nada.
-- ============================================================

-- ---------- troca da versão 1 (07/11/2026): só roda se ainda for a estrutura antiga ----------
-- A versão 1 ficou no ar sem nenhum lançamento; as tabelas dela são trocadas pelas novas.
do $$
begin
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'comissao_regras' and column_name = 'pct_btg') then
    drop function if exists public.comissoes_painel(date);
    drop function if exists public.comissao_regra_salvar(jsonb);
    drop function if exists public.comissao_regra_excluir(uuid);
    drop function if exists public.comissao_lancamento_salvar(jsonb);
    drop function if exists public.comissao_lancamento_excluir(uuid);
    drop function if exists public.comissao_lancamentos_lote(date, jsonb);
    drop function if exists public.comissao_fechar(date);
    drop function if exists public.comissao_reabrir(date, text);
    drop function if exists public.comissao_marcar_pago(date, uuid, date);
    drop function if exists public.comissao_envio_lista(date);
    drop function if exists public.comissao_envio_registrar(date, uuid, text);
    drop function if exists public.com_totais(date);
    drop table if exists public.comissao_pagamentos;
    drop table if exists public.comissao_lancamentos;
    drop table if exists public.comissao_regras;
  end if;
end $$;

-- ---------- permissões ----------
insert into public.permissoes_catalogo (chave, tipo, nome, descricao, ordem, so_master) values
  ('comissoes.operar', 'atribuicao', 'Operar as comissões', 'Subir planilhas, criar regras, fechar o mês, enviar os e-mails e marcar pagamentos.', 160, false),
  ('comissoes.ver',    'atribuicao', 'Ver as comissões', 'Só leitura: planilhas, regras, totais e pagamentos de todos.', 165, false)
on conflict (chave) do update set tipo = excluded.tipo, nome = excluded.nome, descricao = excluded.descricao, ordem = excluded.ordem;
-- No começo o master também opera (pedido do Emil em 07/11/2026); depois ele desmarca em Perfis e acessos.
insert into public.permissoes_perfil (perfil, permissao, liberado, atualizado_por)
select pf.chave, pm.chave, pf.chave in ('master', 'financeiro'), 'instalação'
  from public.perfis_catalogo pf cross join (values ('comissoes.operar'), ('comissoes.ver')) pm(chave)
on conflict (perfil, permissao) do nothing;
update public.permissoes_catalogo set descricao = 'Planilhas do mês, regras de repasse, fechamento e folha de pagamento da equipe.'
 where chave = 'ferramenta.comissoes';

create or replace function public.com_pode_operar() returns boolean language sql stable security definer set search_path = public as $$
  select public.tem_permissao('comissoes.operar');
$$;
create or replace function public.com_pode_ver() returns boolean language sql stable security definer set search_path = public as $$
  select public.tem_permissao('comissoes.ver') or public.tem_permissao('comissoes.operar');
$$;
revoke all on function public.com_pode_operar(), public.com_pode_ver() from public, anon;
grant execute on function public.com_pode_operar(), public.com_pode_ver() to authenticated;

-- ---------- tabelas ----------
-- Empresas pagadoras (as PJs da Adami) e o imposto de cada uma.
create table if not exists public.comissao_empresas (
  id            uuid primary key default gen_random_uuid(),
  nome          text not null unique check (char_length(btrim(nome)) between 2 and 160),
  cnpj          text not null default '',
  pct_imposto   numeric(7,4) not null default 0 check (pct_imposto between 0 and 100),
  ativo         boolean not null default true,
  ordem         int not null default 0,
  atualizado_em timestamptz not null default now(),
  atualizado_por text
);
insert into public.comissao_empresas (nome, cnpj, ordem, atualizado_por) values
  ('Adami Captal Assessores de Investimentos S/S', '36.000.256/0001-46', 1, 'instalação'),
  ('Adami Captal Wealth Planning Ltda',            '55.503.633/0001-04', 2, 'instalação'),
  ('Adami Partners Consultoria Comercial Ltda',    '32.191.808/0001-90', 3, 'instalação')
on conflict (nome) do nothing;

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
alter table public.comissao_dados_pagto add column if not exists empresa_id uuid references public.comissao_empresas(id) on delete set null;
alter table public.comissao_dados_pagto add column if not exists nomes_planilha text[] not null default '{}';

-- Acordos contratuais de cada pessoa (só Financeiro e master veem).
create table if not exists public.comissao_acordos (
  user_id            uuid primary key references auth.users(id) on delete cascade,
  funcao             text not null default '',
  luvas_ano          numeric(16,2),
  anos_luvas         numeric(6,2),
  bonificacao        numeric(16,2),
  custo_fixo_pct     numeric(7,4),
  salario            numeric(16,2),
  remuneracao_minima numeric(16,2),   -- mínimo garantido por mês (o escritório completa)
  tamanho_carteira   numeric(18,2),
  roa_liquido        numeric(7,4),
  data_contratacao   date,
  segmento           text not null default '',
  senioridade        text not null default '',
  conv_ano1 numeric(7,4), conv_ano2 numeric(7,4), conv_ano3 numeric(7,4), conv_ano4 numeric(7,4),
  com_ano1  numeric(7,4), com_ano2  numeric(7,4), com_ano3  numeric(7,4), com_ano4  numeric(7,4),
  obs                text not null default '',
  atualizado_em      timestamptz not null default now(),
  atualizado_por     text
);

-- Origens das planilhas (as 6 que sobem todo mês) e o mapeamento de colunas guardado.
create table if not exists public.comissao_origens (
  id            uuid primary key default gen_random_uuid(),
  nome          text not null unique check (char_length(btrim(nome)) between 2 and 80),
  moeda         text not null default 'BRL' check (moeda in ('BRL', 'USD')),
  ativo         boolean not null default true,
  ordem         int not null default 0,
  config        jsonb not null default '{}'::jsonb,   -- {aba, colunas:{cliente:'C',...}, linha_ini}
  atualizado_em timestamptz not null default now(),
  atualizado_por text
);
insert into public.comissao_origens (nome, moeda, ordem, atualizado_por) values
  ('BTG Investimentos', 'BRL', 1, 'instalação'), ('BTG Offshore', 'USD', 2, 'instalação'),
  ('Consórcios', 'BRL', 3, 'instalação'), ('Corban', 'BRL', 4, 'instalação'),
  ('Pershing', 'USD', 5, 'instalação'), ('Previdência', 'BRL', 6, 'instalação')
on conflict (nome) do nothing;

-- Listas de clientes (nome ou número da conta), usadas nas regras e nas trocas.
create table if not exists public.comissao_listas (
  id            uuid primary key default gen_random_uuid(),
  nome          text not null unique check (char_length(btrim(nome)) between 1 and 80),
  itens         text[] not null default '{}',
  atualizado_em timestamptz not null default now(),
  atualizado_por text
);

-- Regras de repasse. Condições vazias valem para qualquer valor. A de menor
-- prioridade (número menor) é testada primeiro; a primeira que bate é usada.
-- divisao: [{recebedor: 'profissional' | 'escritorio' | <user_id>, pct: número ou null (= o restante), negativos: bool}]
create table if not exists public.comissao_regras (
  id                uuid primary key default gen_random_uuid(),
  nome              text not null check (char_length(btrim(nome)) between 1 and 120),
  prioridade        int not null default 1000,
  ativo             boolean not null default true,
  cond_cliente      text not null default '',
  cond_lista_id     uuid references public.comissao_listas(id) on delete restrict,
  cond_profissional uuid references auth.users(id) on delete set null,
  cond_origem_id    uuid references public.comissao_origens(id) on delete set null,
  cond_categoria    text not null default '',
  cond_produto      text not null default '',
  divisao           jsonb not null default '[]'::jsonb,
  tag               text not null default '',
  obs               text not null default '',
  vigencia_inicio   date not null default date '2026-10-01',
  vigencia_fim      date,
  criado_em         timestamptz not null default now(),
  atualizado_em     timestamptz not null default now(),
  atualizado_por    text
);

-- Troca de campos: "quando a planilha diz X, entenda Y".
create table if not exists public.comissao_trocas (
  id                uuid primary key default gen_random_uuid(),
  grupo             text not null default '',
  prioridade        int not null default 1000,
  ativo             boolean not null default true,
  cond_cliente      text not null default '',
  cond_profissional text not null default '',
  cond_origem_id    uuid references public.comissao_origens(id) on delete set null,
  cond_categoria    text not null default '',
  cond_produto      text not null default '',
  campo             text not null check (campo in ('profissional', 'cliente', 'categoria', 'produto')),
  valor             text not null default '',
  criado_em         timestamptz not null default now(),
  atualizado_por    text
);

create table if not exists public.comissao_meses (
  competencia       date primary key check (extract(day from competencia) = 1),
  status            text not null default 'aberto' check (status in ('aberto', 'fechado')),
  fechado_em        timestamptz,
  fechado_por       text,
  reaberto_em       timestamptz,
  motivo_reabertura text
);
alter table public.comissao_meses add column if not exists liberado boolean not null default false;
alter table public.comissao_meses add column if not exists liberado_em timestamptz;

-- Planilhas que subiram (uma por origem e mês). itens = as linhas cruas, para recalcular.
create table if not exists public.comissao_planilhas (
  id          uuid primary key default gen_random_uuid(),
  competencia date not null references public.comissao_meses(competencia),
  origem_id   uuid not null references public.comissao_origens(id),
  arquivo     text not null default '',
  aba         text not null default '',
  cotacao     numeric(14,6) not null default 1 check (cotacao > 0),
  itens       jsonb not null default '[]'::jsonb,
  linhas      int not null default 0,
  linhas_erro int not null default 0,
  total       numeric(18,2) not null default 0,
  avisos      jsonb not null default '[]'::jsonb,
  criado_em   timestamptz not null default now(),
  criado_por  text,
  atualizado_em timestamptz not null default now(),
  unique (competencia, origem_id)
);

-- Ajustes fixos que se repetem todo mês entre início e fim (salário, liderança, etc.).
create table if not exists public.comissao_fixos (
  id         uuid primary key default gen_random_uuid(),
  grupo      text not null default '',
  user_id    uuid not null references auth.users(id) on delete cascade,
  descricao  text not null check (char_length(btrim(descricao)) between 2 and 160),
  valor      numeric(16,2) not null check (valor <> 0),
  categoria  text not null default 'AJUSTE',
  inicio     date not null check (extract(day from inicio) = 1),
  fim        date check (fim is null or extract(day from fim) = 1),
  ativo      boolean not null default true,
  criado_em  timestamptz not null default now(),
  atualizado_por text
);

-- Linhas do mês. valor = comissão que entrou (em reais, com sinal). rateio = partes das
-- pessoas [{user_id, papel, valor}]; valor_escritorio = parte do escritório.
create table if not exists public.comissao_lancamentos (
  id               uuid primary key default gen_random_uuid(),
  competencia      date not null references public.comissao_meses(competencia),
  tipo             text not null check (tipo in ('receita', 'ajuste', 'fixo', 'minimo', 'saldo_anterior')),
  planilha_id      uuid references public.comissao_planilhas(id) on delete cascade,
  linha            int,
  origem_id        uuid references public.comissao_origens(id),
  origem_nome      text not null default '',
  cliente          text not null default '',
  conta            text not null default '',
  profissional_txt text not null default '',
  profissional_id  uuid,
  prof_escritorio  boolean not null default false,
  categoria        text not null default '',
  produto          text not null default '',
  descricao        text not null default '',
  valor_original   numeric(20,6) not null default 0,
  cotacao          numeric(14,6) not null default 1,
  valor            numeric(20,6) not null default 0,
  regra_id         uuid references public.comissao_regras(id) on delete set null,
  regra_nome       text not null default '',
  rateio           jsonb not null default '[]'::jsonb,
  valor_escritorio numeric(20,6) not null default 0,
  fixo_id          uuid references public.comissao_fixos(id) on delete cascade,
  gerado_por_fechamento date,
  criado_em        timestamptz not null default now(),
  criado_por       text
);
create index if not exists comissao_lanc_comp_idx on public.comissao_lancamentos (competencia);
create index if not exists comissao_lanc_plan_idx on public.comissao_lancamentos (planilha_id);

create table if not exists public.comissao_pagamentos (
  competencia    date not null references public.comissao_meses(competencia),
  user_id        uuid not null references auth.users(id) on delete cascade,
  bruto          numeric(16,2) not null,
  pct_imposto    numeric(7,4) not null default 0,
  imposto        numeric(16,2) not null default 0,
  valor          numeric(16,2) not null,       -- líquido a pagar
  empresa_id     uuid references public.comissao_empresas(id) on delete set null,
  pago_em        date,
  pago_por       text,
  enviado_em     timestamptz,
  envio_erro     text,
  visualizado_em timestamptz,
  primary key (competencia, user_id)
);

alter table public.comissao_empresas    enable row level security;
alter table public.comissao_dados_pagto enable row level security;
alter table public.comissao_acordos     enable row level security;
alter table public.comissao_origens     enable row level security;
alter table public.comissao_listas      enable row level security;
alter table public.comissao_regras      enable row level security;
alter table public.comissao_trocas      enable row level security;
alter table public.comissao_meses       enable row level security;
alter table public.comissao_planilhas   enable row level security;
alter table public.comissao_fixos       enable row level security;
alter table public.comissao_lancamentos enable row level security;
alter table public.comissao_pagamentos  enable row level security;
revoke all on public.comissao_empresas, public.comissao_dados_pagto, public.comissao_acordos, public.comissao_origens,
  public.comissao_listas, public.comissao_regras, public.comissao_trocas, public.comissao_meses, public.comissao_planilhas,
  public.comissao_fixos, public.comissao_lancamentos, public.comissao_pagamentos from anon, authenticated;

-- Regra padrão da casa (pedido do Emil): 50% para o assessor da linha, o restante para o escritório.
-- Fica por último na prioridade: vale quando nenhuma outra regra pegou.
insert into public.comissao_regras (nome, prioridade, divisao, obs, atualizado_por)
select 'Repasse padrão', 9999,
       '[{"recebedor":"profissional","pct":50,"negativos":true},{"recebedor":"escritorio","pct":null,"negativos":true}]'::jsonb,
       'Padrão da casa: metade da comissão para o assessor, o restante para o escritório.', 'instalação'
 where not exists (select 1 from public.comissao_regras);

-- ---------- funções internas ----------
create or replace function public.com_quem() returns text language sql stable set search_path = public as $$
  select coalesce(auth.jwt() ->> 'email', '?');
$$;
create or replace function public.com_mes(p date) returns date language sql immutable set search_path = public as $$
  select date_trunc('month', p)::date;
$$;
-- Texto comparável: sem acento, maiúsculo, espaços simples.
create or replace function public.com_norm(t text) returns text language sql immutable set search_path = public as $$
  select btrim(regexp_replace(upper(translate(coalesce(t, ''),
    'áàâãäéèêëíìîïóòôõöúùûüçñÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇÑ', 'aaaaaeeeeiiiiooooouuuucnAAAAAEEEEIIIIOOOOOUUUUCN')), '\s+', ' ', 'g'));
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
create or replace function public.com_nome(p_user uuid) returns text language sql stable security definer set search_path = public as $$
  select coalesce(nullif(p.nome, ''), split_part(u.email, '@', 1)) from auth.users u left join public.perfis p on p.user_id = u.id where u.id = p_user;
$$;

-- Quem é o profissional escrito na planilha? Devolve user_id; "ESCRITORIO" devolve o uuid zero.
create or replace function public.com_pessoa(p_txt text) returns uuid language sql stable security definer set search_path = public as $$
  with n as (select public.com_norm(p_txt) as t)
  select case when (select t from n) = '' then null
              when (select t from n) in ('ESCRITORIO', 'ESCRITORIO ADAMI', 'ADAMI CAPTAL') then '00000000-0000-0000-0000-000000000000'::uuid
              else (select x.uid from (
                select p.user_id as uid, 1 as ordem from public.perfis p, n where p.codigo is not null and public.com_norm(p.codigo) = n.t
                union all select d.user_id, 2 from public.comissao_dados_pagto d, n where exists (select 1 from unnest(d.nomes_planilha) a where public.com_norm(a) = n.t)
                union all select p.user_id, 3 from public.perfis p, n where public.com_norm(p.nome) = n.t
                union all select d.user_id, 4 from public.comissao_dados_pagto d, n where public.com_norm(d.nome_completo) = n.t
                union all select u.id, 5 from auth.users u, n where public.com_norm(u.email) = n.t or public.com_norm(split_part(u.email, '@', 1)) = n.t
              ) x order by x.ordem limit 1) end;
$$;

-- Item cabe na condição de cliente (texto ou lista)? Compara com o nome e com a conta.
create or replace function public.com_bate_cliente(p_cond text, p_lista uuid, p_cliente text, p_conta text)
returns boolean language sql stable security definer set search_path = public as $$
  select (public.com_norm(p_cond) = '' or public.com_norm(p_cond) in (public.com_norm(p_cliente), public.com_norm(p_conta)))
     and (p_lista is null or exists (select 1 from public.comissao_listas l, unnest(l.itens) i
                                      where l.id = p_lista and public.com_norm(i) in (public.com_norm(p_cliente), public.com_norm(p_conta))
                                        and public.com_norm(i) <> ''));
$$;

-- O motor. p: {cliente, conta, profissional (texto) ou profissional_id, categoria, produto, valor}
-- Devolve a linha calculada, com "erro" quando não dá para calcular e "avisos" das trocas feitas.
create or replace function public.com_calcular(p jsonb, p_origem uuid, p_comp date, p_cotacao numeric)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_cli text := btrim(coalesce(p->>'cliente', '')); v_conta text := btrim(coalesce(p->>'conta', ''));
  v_prof text := btrim(coalesce(p->>'profissional', '')); v_cat text := btrim(coalesce(p->>'categoria', ''));
  v_prod text := btrim(coalesce(p->>'produto', ''));
  v_orig numeric; v_val numeric; v_pid uuid; v_esc boolean := false;
  t record; r record; d jsonb; v_feitos text[] := '{}'; v_avisos jsonb := '[]'::jsonb;
  v_regra public.comissao_regras; v_soma numeric := 0; v_resto jsonb; v_parte numeric; v_quem uuid;
  v_rateio jsonb := '{}'::jsonb; v_escr numeric := 0; v_saida jsonb := '[]'::jsonb; k text;
begin
  begin
    v_orig := coalesce(nullif(btrim(p->>'valor'), '')::numeric, 0);
  exception when others then
    return jsonb_build_object('erro', 'valor da comissão não é número: ' || coalesce(p->>'valor', ''));
  end;
  v_val := round(v_orig * coalesce(p_cotacao, 1), 6);

  -- 1. troca de campos (a primeira que bate, para cada campo)
  for t in select * from public.comissao_trocas where ativo and (cond_origem_id is null or cond_origem_id = p_origem) order by prioridade, criado_em loop
    continue when t.campo = any(v_feitos);
    continue when public.com_norm(t.cond_cliente) <> '' and public.com_norm(t.cond_cliente) not in (public.com_norm(v_cli), public.com_norm(v_conta));
    continue when public.com_norm(t.cond_profissional) <> '' and public.com_norm(t.cond_profissional) <> public.com_norm(v_prof);
    continue when public.com_norm(t.cond_categoria) <> '' and public.com_norm(t.cond_categoria) <> public.com_norm(v_cat);
    continue when public.com_norm(t.cond_produto) <> '' and public.com_norm(t.cond_produto) <> public.com_norm(v_prod);
    if t.campo = 'profissional' then v_avisos := v_avisos || to_jsonb(v_prof || ' → ' || t.valor); v_prof := t.valor;
    elsif t.campo = 'cliente' then v_avisos := v_avisos || to_jsonb(v_cli || ' → ' || t.valor); v_cli := t.valor;
    elsif t.campo = 'categoria' then v_avisos := v_avisos || to_jsonb(v_cat || ' → ' || t.valor); v_cat := t.valor;
    else v_avisos := v_avisos || to_jsonb(v_prod || ' → ' || t.valor); v_prod := t.valor; end if;
    v_feitos := v_feitos || t.campo;
  end loop;

  -- 2. quem é o profissional
  if nullif(p->>'profissional_id', '') is not null then
    v_pid := (p->>'profissional_id')::uuid;
    if v_pid = '00000000-0000-0000-0000-000000000000'::uuid then v_pid := null; v_esc := true; v_prof := 'ESCRITORIO';
    else v_prof := coalesce(public.com_nome(v_pid), v_prof); end if;
  elsif v_prof <> '' then
    v_pid := public.com_pessoa(v_prof);
    if v_pid = '00000000-0000-0000-0000-000000000000'::uuid then v_pid := null; v_esc := true;
    elsif v_pid is null then
      return jsonb_build_object('erro', 'profissional "' || v_prof || '" não está no cadastro (crie uma troca de nome ou cadastre em Pessoas)',
        'cliente', v_cli, 'conta', v_conta, 'profissional_txt', v_prof, 'categoria', v_cat, 'produto', v_prod,
        'valor_original', v_orig, 'valor', v_val, 'avisos', v_avisos);
    end if;
  end if;

  -- 3. a regra
  select * into v_regra from public.comissao_regras g
   where g.ativo and g.vigencia_inicio <= p_comp and (g.vigencia_fim is null or g.vigencia_fim >= p_comp)
     and (g.cond_origem_id is null or g.cond_origem_id = p_origem)
     and (public.com_norm(g.cond_categoria) = '' or public.com_norm(g.cond_categoria) = public.com_norm(v_cat))
     and (public.com_norm(g.cond_produto) = '' or public.com_norm(g.cond_produto) = public.com_norm(v_prod))
     and (g.cond_profissional is null or g.cond_profissional = v_pid)
     and public.com_bate_cliente(g.cond_cliente, g.cond_lista_id, v_cli, v_conta)
   order by g.prioridade, g.criado_em limit 1;
  if v_regra.id is null then
    return jsonb_build_object('erro', 'nenhuma regra de repasse serve para esta linha',
      'cliente', v_cli, 'conta', v_conta, 'profissional_txt', v_prof, 'profissional_id', v_pid, 'prof_escritorio', v_esc,
      'categoria', v_cat, 'produto', v_prod, 'valor_original', v_orig, 'valor', v_val, 'avisos', v_avisos);
  end if;

  -- 4. a divisão
  for d in select * from jsonb_array_elements(v_regra.divisao) loop
    if d->'pct' is null or jsonb_typeof(d->'pct') = 'null' then v_resto := d; continue; end if;
    if v_val < 0 and not coalesce((d->>'negativos')::boolean, true) then continue; end if;
    v_parte := round(v_val * (d->>'pct')::numeric / 100, 6);
    v_soma := v_soma + v_parte;
    if d->>'recebedor' = 'profissional' then
      if v_esc then v_escr := v_escr + v_parte; continue; end if;
      if v_pid is null then
        return jsonb_build_object('erro', 'a regra "' || v_regra.nome || '" paga o profissional da linha, e a linha não tem profissional',
          'cliente', v_cli, 'conta', v_conta, 'profissional_txt', v_prof, 'categoria', v_cat, 'produto', v_prod,
          'valor_original', v_orig, 'valor', v_val, 'regra_id', v_regra.id, 'regra_nome', v_regra.nome, 'avisos', v_avisos);
      end if;
      v_quem := v_pid;
    elsif d->>'recebedor' = 'escritorio' then v_escr := v_escr + v_parte; continue;
    else v_quem := (d->>'recebedor')::uuid; end if;
    v_rateio := jsonb_set(v_rateio, array[v_quem::text], to_jsonb(coalesce((v_rateio->>v_quem::text)::numeric, 0) + v_parte));
  end loop;
  v_parte := v_val - v_soma;   -- o restante
  if v_resto is not null and v_parte <> 0 and (v_val >= 0 or coalesce((v_resto->>'negativos')::boolean, true)) then
    if v_resto->>'recebedor' = 'escritorio' or (v_resto->>'recebedor' = 'profissional' and v_esc) then v_escr := v_escr + v_parte;
    elsif v_resto->>'recebedor' = 'profissional' and v_pid is null then
      return jsonb_build_object('erro', 'a regra "' || v_regra.nome || '" paga o profissional da linha, e a linha não tem profissional',
        'cliente', v_cli, 'conta', v_conta, 'categoria', v_cat, 'produto', v_prod, 'valor_original', v_orig, 'valor', v_val, 'avisos', v_avisos);
    else
      v_quem := case when v_resto->>'recebedor' = 'profissional' then v_pid else (v_resto->>'recebedor')::uuid end;
      v_rateio := jsonb_set(v_rateio, array[v_quem::text], to_jsonb(coalesce((v_rateio->>v_quem::text)::numeric, 0) + v_parte));
    end if;
  elsif v_parte <> 0 then
    v_escr := v_escr + v_parte;   -- sem "restante": o que sobra fica com o escritório
  end if;
  for k in select jsonb_object_keys(v_rateio) loop
    v_saida := v_saida || jsonb_build_object('user_id', k, 'papel', case when k::uuid = v_pid then 'profissional' else 'repasse' end,
                                             'valor', (v_rateio->>k)::numeric);
  end loop;
  return jsonb_build_object('cliente', v_cli, 'conta', v_conta, 'profissional_txt', v_prof, 'profissional_id', v_pid,
    'prof_escritorio', v_esc, 'categoria', v_cat, 'produto', v_prod, 'valor_original', v_orig, 'valor', v_val,
    'regra_id', v_regra.id, 'regra_nome', v_regra.nome, 'rateio', v_saida, 'valor_escritorio', v_escr, 'avisos', v_avisos);
end $$;

-- Grava as linhas de uma planilha (apaga as anteriores dela). Devolve contagens.
create or replace function public.com_processar_planilha(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare pl public.comissao_planilhas; o public.comissao_origens; it jsonb; c jsonb; i int := 0; n_ok int := 0;
        erros jsonb := '[]'::jsonb; trocas jsonb := '[]'::jsonb; v_total numeric := 0;
begin
  select * into pl from public.comissao_planilhas where id = p_id;
  select * into o from public.comissao_origens where id = pl.origem_id;
  delete from public.comissao_lancamentos where planilha_id = p_id;
  for it in select * from jsonb_array_elements(pl.itens) loop
    i := i + 1;
    c := public.com_calcular(it, pl.origem_id, pl.competencia, pl.cotacao);
    if jsonb_array_length(coalesce(c->'avisos', '[]')) > 0 then
      trocas := trocas || jsonb_build_object('linha', coalesce((it->>'linha')::int, i), 'trocas', c->'avisos');
    end if;
    if c ? 'erro' then
      erros := erros || jsonb_build_object('linha', coalesce((it->>'linha')::int, i), 'erro', c->>'erro', 'valor', c->'valor');
      continue;
    end if;
    insert into public.comissao_lancamentos (competencia, tipo, planilha_id, linha, origem_id, origem_nome, cliente, conta,
      profissional_txt, profissional_id, prof_escritorio, categoria, produto, valor_original, cotacao, valor, regra_id, regra_nome,
      rateio, valor_escritorio, criado_por)
    values (pl.competencia, 'receita', p_id, coalesce((it->>'linha')::int, i), pl.origem_id, o.nome, c->>'cliente', c->>'conta',
      c->>'profissional_txt', nullif(c->>'profissional_id', '')::uuid, coalesce((c->>'prof_escritorio')::boolean, false),
      c->>'categoria', c->>'produto', (c->>'valor_original')::numeric, pl.cotacao, (c->>'valor')::numeric,
      (c->>'regra_id')::uuid, c->>'regra_nome', c->'rateio', (c->>'valor_escritorio')::numeric, public.com_quem());
    n_ok := n_ok + 1; v_total := v_total + (c->>'valor')::numeric;
  end loop;
  update public.comissao_planilhas set linhas = n_ok, linhas_erro = jsonb_array_length(erros), total = round(v_total, 2),
         avisos = jsonb_build_object('erros', erros, 'trocas', trocas), atualizado_em = now()
   where id = p_id;
  return jsonb_build_object('gravadas', n_ok, 'erros', jsonb_array_length(erros), 'total', round(v_total, 2));
end $$;

-- Ajustes fixos do mês aberto: põe os que faltam e tira os que deixaram de valer.
create or replace function public.com_aplicar_fixos(p_comp date) returns void language plpgsql security definer set search_path = public as $$
declare v_comp date := public.com_mes(p_comp);
begin
  if (select status from public.comissao_meses where competencia = v_comp) is distinct from 'aberto' then return; end if;
  delete from public.comissao_lancamentos l where l.competencia = v_comp and l.tipo = 'fixo'
     and not exists (select 1 from public.comissao_fixos f where f.id = l.fixo_id and f.ativo and f.inicio <= v_comp and (f.fim is null or f.fim >= v_comp)
                       and l.valor = -f.valor and l.descricao = f.descricao and l.categoria = f.categoria and (l.rateio->0->>'user_id')::uuid = f.user_id);
  insert into public.comissao_lancamentos (competencia, tipo, fixo_id, profissional_id, profissional_txt, categoria, descricao, valor, rateio, valor_escritorio, criado_por)
  select v_comp, 'fixo', f.id, f.user_id, coalesce(public.com_nome(f.user_id), ''), f.categoria, f.descricao, -f.valor,
         jsonb_build_array(jsonb_build_object('user_id', f.user_id, 'papel', 'ajuste fixo', 'valor', f.valor)), -f.valor, 'automático'
    from public.comissao_fixos f
   where f.ativo and f.inicio <= v_comp and (f.fim is null or f.fim >= v_comp)
     and not exists (select 1 from public.comissao_lancamentos l where l.competencia = v_comp and l.fixo_id = f.id);
end $$;

-- Totais de cada pessoa no mês: bruto (soma das partes), imposto da empresa pagadora e líquido.
create or replace function public.com_totais(p_comp date)
returns table (user_id uuid, bruto numeric, pct_imposto numeric, imposto numeric, liquido numeric, empresa_id uuid, linhas int)
language sql stable security definer set search_path = public as $$
  with b as (
    select (r->>'user_id')::uuid as uid, round(sum((r->>'valor')::numeric), 2) as bruto, count(*)::int as linhas
      from public.comissao_lancamentos l, jsonb_array_elements(l.rateio) r
     where l.competencia = public.com_mes(p_comp) and nullif(r->>'user_id', '') is not null
     group by 1)
  select b.uid, b.bruto, coalesce(e.pct_imposto, 0),
         case when b.bruto > 0 then round(b.bruto * coalesce(e.pct_imposto, 0) / 100, 2) else 0 end,
         b.bruto - case when b.bruto > 0 then round(b.bruto * coalesce(e.pct_imposto, 0) / 100, 2) else 0 end,
         d.empresa_id, b.linhas
    from b left join public.comissao_dados_pagto d on d.user_id = b.uid
           left join public.comissao_empresas e on e.id = d.empresa_id;
$$;

-- Mínimo garantido: quanto falta para cada pessoa chegar ao piso (sem contar o complemento já lançado).
create or replace function public.com_minimos(p_comp date)
returns table (user_id uuid, minimo numeric, bruto numeric, complemento numeric)
language sql stable security definer set search_path = public as $$
  with b as (
    select (r->>'user_id')::uuid as uid, sum((r->>'valor')::numeric) as v
      from public.comissao_lancamentos l, jsonb_array_elements(l.rateio) r
     where l.competencia = public.com_mes(p_comp) and l.tipo <> 'minimo' and nullif(r->>'user_id', '') is not null
     group by 1)
  select a.user_id, a.remuneracao_minima, round(coalesce(b.v, 0), 2), greatest(0, a.remuneracao_minima - round(coalesce(b.v, 0), 2))
    from public.comissao_acordos a join auth.users u on u.id = a.user_id
    left join b on b.uid = a.user_id
   where coalesce(a.remuneracao_minima, 0) > 0 and not coalesce(u.banned_until > now(), false);
$$;

revoke all on function public.com_quem(), public.com_mes(date), public.com_norm(text), public.com_garantir_mes(date),
  public.com_exigir_aberto(date), public.com_nome(uuid), public.com_pessoa(text), public.com_bate_cliente(text, uuid, text, text),
  public.com_calcular(jsonb, uuid, date, numeric), public.com_processar_planilha(uuid), public.com_aplicar_fixos(date),
  public.com_totais(date), public.com_minimos(date) from public, anon, authenticated;

-- ---------- leitura (tela do Financeiro) ----------
-- volatile: quem opera, ao abrir um mês aberto, já recebe os ajustes fixos do mês lançados.
create or replace function public.comissoes_painel(p_competencia date)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_comp date := public.com_mes(coalesce(p_competencia, now()::date)); v_ano int := extract(year from coalesce(p_competencia, now()::date));
begin
  if not public.com_pode_ver() then raise exception 'Seu perfil não tem acesso às comissões.'; end if;
  if public.com_pode_operar() then perform public.com_garantir_mes(v_comp); perform public.com_aplicar_fixos(v_comp); end if;
  return jsonb_build_object(
    'competencia', v_comp,
    'pode_operar', public.com_pode_operar(),
    'mes', (select to_jsonb(m) from public.comissao_meses m where m.competencia = v_comp),
    'meses', coalesce((select jsonb_agg(jsonb_build_object('competencia', competencia, 'status', status, 'liberado', liberado) order by competencia desc) from public.comissao_meses), '[]'),
    'empresas', coalesce((select jsonb_agg(to_jsonb(e) order by e.ordem, e.nome) from public.comissao_empresas e), '[]'),
    'origens', coalesce((select jsonb_agg(to_jsonb(o) order by o.ordem, o.nome) from public.comissao_origens o), '[]'),
    'listas', coalesce((select jsonb_agg(to_jsonb(l) order by l.nome) from public.comissao_listas l), '[]'),
    'regras', coalesce((select jsonb_agg(to_jsonb(r) order by r.prioridade, r.criado_em) from public.comissao_regras r), '[]'),
    'trocas', coalesce((select jsonb_agg(to_jsonb(t) order by t.prioridade, t.criado_em) from public.comissao_trocas t), '[]'),
    'fixos', coalesce((select jsonb_agg(to_jsonb(f) order by f.grupo, f.criado_em) from public.comissao_fixos f), '[]'),
    'planilhas', coalesce((select jsonb_agg((to_jsonb(p) - 'itens') order by p.criado_em) from public.comissao_planilhas p where p.competencia = v_comp), '[]'),
    'grade', coalesce((select jsonb_agg(jsonb_build_object('competencia', p.competencia, 'origem_id', p.origem_id, 'linhas', p.linhas, 'linhas_erro', p.linhas_erro))
                         from public.comissao_planilhas p where extract(year from p.competencia) = v_ano), '[]'),
    'lancamentos', coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'tipo', l.tipo, 'planilha_id', l.planilha_id, 'linha', l.linha,
        'origem_id', l.origem_id, 'origem_nome', l.origem_nome, 'cliente', l.cliente, 'conta', l.conta, 'profissional_txt', l.profissional_txt,
        'profissional_id', l.profissional_id, 'prof_escritorio', l.prof_escritorio, 'categoria', l.categoria, 'produto', l.produto,
        'descricao', l.descricao, 'valor_original', l.valor_original, 'cotacao', l.cotacao, 'valor', l.valor, 'regra_nome', l.regra_nome,
        'rateio', l.rateio, 'valor_escritorio', l.valor_escritorio, 'fixo_id', l.fixo_id, 'criado_por', l.criado_por) order by l.criado_em, l.linha)
      from public.comissao_lancamentos l where l.competencia = v_comp), '[]'),
    'totais', coalesce((select jsonb_agg(to_jsonb(t)) from public.com_totais(v_comp) t), '[]'),
    'minimos', coalesce((select jsonb_agg(to_jsonb(m)) from public.com_minimos(v_comp) m), '[]'),
    'pagamentos', coalesce((select jsonb_agg(to_jsonb(p)) from public.comissao_pagamentos p where p.competencia = v_comp), '[]'),
    'pessoas', coalesce((select jsonb_agg(jsonb_build_object(
        'user_id', p.user_id, 'nome', coalesce(nullif(p.nome, ''), split_part(u.email, '@', 1)), 'email', u.email,
        'codigo', p.codigo, 'papel_crm', pr.role, 'revogado', coalesce(u.banned_until > now(), false),
        'pagto', (select to_jsonb(d) from public.comissao_dados_pagto d where d.user_id = p.user_id),
        'acordo', (select to_jsonb(a) from public.comissao_acordos a where a.user_id = p.user_id))
        order by coalesce(nullif(p.nome, ''), u.email))
      from public.perfis p join auth.users u on u.id = p.user_id left join public.profiles pr on pr.id = p.user_id), '[]'));
end $$;

-- Linhas cruas de uma planilha (para baixar de novo e conferir).
create or replace function public.comissao_planilha_itens(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.com_pode_ver() then raise exception 'Seu perfil não tem acesso às comissões.'; end if;
  return (select jsonb_build_object('arquivo', arquivo, 'aba', aba, 'itens', itens) from public.comissao_planilhas where id = p_id);
end $$;

-- ---------- planilhas ----------
-- Confere sem gravar: devolve o cálculo de cada linha (a tabela de conferência).
create or replace function public.comissao_simular(p_competencia date, p_origem_id uuid, p_cotacao numeric, p_itens jsonb)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare it jsonb; saida jsonb := '[]'::jsonb; i int := 0;
begin
  if not public.com_pode_operar() then raise exception 'Seu perfil não pode subir planilhas.'; end if;
  if jsonb_array_length(coalesce(p_itens, '[]')) > 20000 then raise exception 'Planilha grande demais (máximo 20 mil linhas).'; end if;
  for it in select * from jsonb_array_elements(coalesce(p_itens, '[]')) loop
    i := i + 1;
    saida := saida || (public.com_calcular(it, p_origem_id, public.com_mes(p_competencia), coalesce(p_cotacao, 1))
                       || jsonb_build_object('linha', coalesce((it->>'linha')::int, i)));
  end loop;
  return saida;
end $$;

-- Grava a planilha do mês para a origem (substitui a anterior da mesma origem) e guarda o mapeamento.
-- p: {competencia, origem_id, arquivo, aba, cotacao, config, itens:[{linha, cliente, conta, profissional, categoria, produto, valor}]}
create or replace function public.comissao_planilha_salvar(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_comp date := public.com_mes((p->>'competencia')::date); v_orig uuid := (p->>'origem_id')::uuid; v_id uuid; r jsonb;
begin
  if not public.com_pode_operar() then raise exception 'Seu perfil não pode subir planilhas.'; end if;
  perform public.com_exigir_aberto(v_comp);
  if not exists (select 1 from public.comissao_origens where id = v_orig) then raise exception 'Escolha a origem da planilha.'; end if;
  if jsonb_typeof(p->'itens') <> 'array' or jsonb_array_length(p->'itens') = 0 then raise exception 'A planilha não tem linhas.'; end if;
  if jsonb_array_length(p->'itens') > 20000 then raise exception 'Planilha grande demais (máximo 20 mil linhas).'; end if;
  insert into public.comissao_planilhas as c (competencia, origem_id, arquivo, aba, cotacao, itens, criado_por)
  values (v_comp, v_orig, left(coalesce(p->>'arquivo', ''), 200), left(coalesce(p->>'aba', ''), 100),
          coalesce(nullif(p->>'cotacao', '')::numeric, 1), p->'itens', public.com_quem())
  on conflict (competencia, origem_id) do update set arquivo = excluded.arquivo, aba = excluded.aba, cotacao = excluded.cotacao,
     itens = excluded.itens, criado_em = now(), criado_por = excluded.criado_por
  returning id into v_id;
  if p ? 'config' and jsonb_typeof(p->'config') = 'object' then
    update public.comissao_origens set config = p->'config', atualizado_em = now(), atualizado_por = public.com_quem() where id = v_orig;
  end if;
  r := public.com_processar_planilha(v_id);
  insert into public.auditoria (usuario, acao, alvo, detalhe)
  values (public.com_quem(), 'subiu planilha de comissões', (select nome from public.comissao_origens where id = v_orig) || ' ' || to_char(v_comp, 'MM/YYYY'),
          (r->>'gravadas') || ' linhas, ' || (r->>'erros') || ' com problema');
  return r || jsonb_build_object('id', v_id);
end $$;

-- Recalcula (depois de criar regra ou troca). p_id nulo = todas as planilhas do mês.
create or replace function public.comissao_recalcular(p_competencia date, p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_comp date := public.com_mes(p_competencia); x record; n int := 0; e int := 0; r jsonb;
begin
  if not public.com_pode_operar() then raise exception 'Seu perfil não pode recalcular.'; end if;
  perform public.com_exigir_aberto(v_comp);
  for x in select id from public.comissao_planilhas where competencia = v_comp and (p_id is null or id = p_id) loop
    r := public.com_processar_planilha(x.id); n := n + (r->>'gravadas')::int; e := e + (r->>'erros')::int;
  end loop;
  insert into public.auditoria (usuario, acao, alvo, detalhe) values (public.com_quem(), 'recalculou comissões', to_char(v_comp, 'MM/YYYY'), n || ' linhas');
  return jsonb_build_object('gravadas', n, 'erros', e);
end $$;

create or replace function public.comissao_planilha_excluir(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare pl public.comissao_planilhas;
begin
  if not public.com_pode_operar() then raise exception 'Seu perfil não pode excluir planilhas.'; end if;
  select * into pl from public.comissao_planilhas where id = p_id;
  if pl.id is null then raise exception 'Planilha não encontrada.'; end if;
  perform public.com_exigir_aberto(pl.competencia);
  delete from public.comissao_planilhas where id = p_id;   -- as linhas saem junto
  insert into public.auditoria (usuario, acao, alvo, detalhe)
  values (public.com_quem(), 'excluiu planilha de comissões', (select nome from public.comissao_origens where id = pl.origem_id) || ' ' || to_char(pl.competencia, 'MM/YYYY'),
          pl.arquivo || ', ' || pl.linhas || ' linhas');
end $$;

-- ---------- lançamento avulso (estorno, receita fora de planilha, ajuste do mês) ----------
-- p: {competencia, tipo: 'receita' | 'ajuste', cliente, conta, profissional_id, categoria, produto, valor (com sinal), descricao, origem_id}
create or replace function public.comissao_lancamento_salvar(p jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_comp date := public.com_mes((p->>'competencia')::date); v_id uuid; c jsonb; v_val numeric; v_user uuid;
begin
  if not public.com_pode_operar() then raise exception 'Seu perfil não pode lançar comissões.'; end if;
  perform public.com_exigir_aberto(v_comp);
  v_val := coalesce(nullif(p->>'valor', '')::numeric, 0);
  if v_val = 0 then raise exception 'Informe o valor (negativo para estorno ou desconto).'; end if;
  if p->>'tipo' = 'ajuste' then
    v_user := nullif(p->>'profissional_id', '')::uuid;
    if v_user is null then raise exception 'Escolha a pessoa do ajuste.'; end if;
    if char_length(btrim(coalesce(p->>'descricao', ''))) < 3 then raise exception 'Escreva o motivo do ajuste.'; end if;
    insert into public.comissao_lancamentos (competencia, tipo, profissional_id, profissional_txt, categoria, descricao, valor, rateio, valor_escritorio, criado_por)
    values (v_comp, 'ajuste', v_user, coalesce(public.com_nome(v_user), ''), coalesce(nullif(btrim(p->>'categoria'), ''), 'AJUSTE'),
            btrim(p->>'descricao'), -v_val, jsonb_build_array(jsonb_build_object('user_id', v_user, 'papel', 'ajuste', 'valor', v_val)), -v_val, public.com_quem())
    returning id into v_id;
  elsif p->>'tipo' = 'receita' then
    c := public.com_calcular(p, nullif(p->>'origem_id', '')::uuid, v_comp, 1);
    if c ? 'erro' then raise exception '%', c->>'erro'; end if;
    insert into public.comissao_lancamentos (competencia, tipo, origem_id, origem_nome, cliente, conta, profissional_txt, profissional_id, prof_escritorio,
      categoria, produto, descricao, valor_original, valor, regra_id, regra_nome, rateio, valor_escritorio, criado_por)
    values (v_comp, 'receita', nullif(p->>'origem_id', '')::uuid, coalesce((select nome from public.comissao_origens where id = nullif(p->>'origem_id', '')::uuid), 'Lançamento avulso'),
      c->>'cliente', c->>'conta', c->>'profissional_txt', nullif(c->>'profissional_id', '')::uuid, coalesce((c->>'prof_escritorio')::boolean, false),
      c->>'categoria', c->>'produto', btrim(coalesce(p->>'descricao', '')), (c->>'valor_original')::numeric, (c->>'valor')::numeric,
      (c->>'regra_id')::uuid, c->>'regra_nome', c->'rateio', (c->>'valor_escritorio')::numeric, public.com_quem())
    returning id into v_id;
  else
    raise exception 'Tipo de lançamento inválido.';
  end if;
  insert into public.auditoria (usuario, acao, alvo, detalhe)
  values (public.com_quem(), 'lançou comissão avulsa', to_char(v_comp, 'MM/YYYY'), (p->>'tipo') || ' ' || v_val);
  return v_id;
end $$;

create or replace function public.comissao_lancamento_excluir(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare l public.comissao_lancamentos;
begin
  if not public.com_pode_operar() then raise exception 'Seu perfil não pode excluir lançamentos.'; end if;
  select * into l from public.comissao_lancamentos where id = p_id;
  if l.id is null then raise exception 'Lançamento não encontrado.'; end if;
  if l.tipo not in ('receita', 'ajuste') or l.planilha_id is not null then
    raise exception 'Esta linha veio de planilha, ajuste fixo ou fechamento: mude na origem dela.';
  end if;
  perform public.com_exigir_aberto(l.competencia);
  delete from public.comissao_lancamentos where id = p_id;
  insert into public.auditoria (usuario, acao, alvo, detalhe)
  values (public.com_quem(), 'excluiu lançamento de comissão', to_char(l.competencia, 'MM/YYYY'), l.tipo || ' ' || round(l.valor, 2) || ' ' || l.cliente || l.descricao);
end $$;

-- ---------- cadastros ----------
create or replace function public.comissao_regra_salvar(p jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid := nullif(p->>'id', '')::uuid; d jsonb; v_soma numeric := 0; v_restos int := 0; v_div jsonb := '[]'::jsonb; v_rec text;
begin
  if not public.com_pode_operar() then raise exception 'Seu perfil não pode mexer nas regras.'; end if;
  if char_length(btrim(coalesce(p->>'nome', ''))) < 1 then raise exception 'Dê um nome para a regra.'; end if;
  if jsonb_typeof(p->'divisao') <> 'array' or jsonb_array_length(p->'divisao') = 0 then raise exception 'Diga quem recebe.'; end if;
  for d in select * from jsonb_array_elements(p->'divisao') loop
    v_rec := d->>'recebedor';
    if v_rec is null or (v_rec not in ('profissional', 'escritorio') and not exists (select 1 from auth.users where id::text = v_rec)) then
      raise exception 'Recebedor inválido na divisão.';
    end if;
    if d->'pct' is null or jsonb_typeof(d->'pct') = 'null' then v_restos := v_restos + 1;
    else
      if (d->>'pct')::numeric <= 0 or (d->>'pct')::numeric > 100 then raise exception 'Cada percentual precisa ficar entre 0 e 100.'; end if;
      v_soma := v_soma + (d->>'pct')::numeric;
    end if;
    v_div := v_div || jsonb_build_object('recebedor', v_rec, 'pct', d->'pct', 'negativos', coalesce((d->>'negativos')::boolean, true));
  end loop;
  if v_restos > 1 then raise exception 'Só um recebedor pode ficar com "o restante".'; end if;
  if v_soma > 100.0001 then raise exception 'Os percentuais passam de 100%% (somam %).', v_soma; end if;
  if v_id is null then
    insert into public.comissao_regras (nome, prioridade, ativo, cond_cliente, cond_lista_id, cond_profissional, cond_origem_id,
      cond_categoria, cond_produto, divisao, tag, obs, vigencia_inicio, vigencia_fim, atualizado_por)
    values (btrim(p->>'nome'), coalesce(nullif(p->>'prioridade', '')::int, (select coalesce(max(prioridade) filter (where prioridade < 9999), 0) + 10 from public.comissao_regras)),
      coalesce((p->>'ativo')::boolean, true), btrim(coalesce(p->>'cond_cliente', '')), nullif(p->>'cond_lista_id', '')::uuid,
      nullif(p->>'cond_profissional', '')::uuid, nullif(p->>'cond_origem_id', '')::uuid, btrim(coalesce(p->>'cond_categoria', '')),
      btrim(coalesce(p->>'cond_produto', '')), v_div, btrim(coalesce(p->>'tag', '')), coalesce(p->>'obs', ''),
      coalesce(nullif(p->>'vigencia_inicio', '')::date, date '2026-10-01'), nullif(p->>'vigencia_fim', '')::date, public.com_quem())
    returning id into v_id;
    insert into public.auditoria (usuario, acao, alvo, detalhe) values (public.com_quem(), 'criou regra de repasse', p->>'nome', '');
  else
    update public.comissao_regras set nome = btrim(p->>'nome'), ativo = coalesce((p->>'ativo')::boolean, ativo),
      cond_cliente = btrim(coalesce(p->>'cond_cliente', '')), cond_lista_id = nullif(p->>'cond_lista_id', '')::uuid,
      cond_profissional = nullif(p->>'cond_profissional', '')::uuid, cond_origem_id = nullif(p->>'cond_origem_id', '')::uuid,
      cond_categoria = btrim(coalesce(p->>'cond_categoria', '')), cond_produto = btrim(coalesce(p->>'cond_produto', '')),
      divisao = v_div, tag = btrim(coalesce(p->>'tag', '')), obs = coalesce(p->>'obs', obs),
      vigencia_inicio = coalesce(nullif(p->>'vigencia_inicio', '')::date, vigencia_inicio), vigencia_fim = nullif(p->>'vigencia_fim', '')::date,
      atualizado_em = now(), atualizado_por = public.com_quem()
     where id = v_id;
    if not found then raise exception 'Regra não encontrada.'; end if;
    insert into public.auditoria (usuario, acao, alvo, detalhe) values (public.com_quem(), 'alterou regra de repasse', p->>'nome', '');
  end if;
  return v_id;
end $$;

-- Ordem das regras: recebe a lista de ids na ordem nova (a primeira é a 1ª testada).
create or replace function public.comissao_regras_ordenar(p_ids uuid[])
returns void language plpgsql security definer set search_path = public as $$
declare i int;
begin
  if not public.com_pode_operar() then raise exception 'Seu perfil não pode mexer nas regras.'; end if;
  for i in 1 .. coalesce(array_length(p_ids, 1), 0) loop
    update public.comissao_regras set prioridade = i * 10 where id = p_ids[i];
  end loop;
  insert into public.auditoria (usuario, acao, alvo, detalhe) values (public.com_quem(), 'reordenou regras de repasse', '', '');
end $$;

create or replace function public.comissao_regra_excluir(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_nome text;
begin
  if not public.com_pode_operar() then raise exception 'Seu perfil não pode mexer nas regras.'; end if;
  select nome into v_nome from public.comissao_regras where id = p_id;
  if v_nome is null then raise exception 'Regra não encontrada.'; end if;
  delete from public.comissao_regras where id = p_id;   -- as linhas já calculadas guardam o nome da regra
  insert into public.auditoria (usuario, acao, alvo, detalhe) values (public.com_quem(), 'excluiu regra de repasse', v_nome, '');
end $$;

-- Testa uma linha: qual regra pega e como divide (sem gravar).
create or replace function public.comissao_testar(p jsonb, p_competencia date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.com_pode_ver() then raise exception 'Seu perfil não tem acesso às comissões.'; end if;
  return public.com_calcular(p, nullif(p->>'origem_id', '')::uuid, public.com_mes(coalesce(p_competencia, now()::date)), 1);
end $$;

create or replace function public.comissao_troca_salvar(p jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid := nullif(p->>'id', '')::uuid;
begin
  if not public.com_pode_operar() then raise exception 'Seu perfil não pode mexer nas trocas.'; end if;
  if coalesce(p->>'campo', '') not in ('profissional', 'cliente', 'categoria', 'produto') then raise exception 'Escolha o campo que será trocado.'; end if;
  if btrim(coalesce(p->>'valor', '')) = '' then raise exception 'Diga pelo que trocar.'; end if;
  if btrim(coalesce(p->>'cond_cliente', '') || coalesce(p->>'cond_profissional', '') || coalesce(p->>'cond_categoria', '') || coalesce(p->>'cond_produto', '')) = '' then
    raise exception 'Preencha pelo menos uma condição (o que a planilha diz).';
  end if;
  if v_id is null then
    insert into public.comissao_trocas (grupo, prioridade, cond_cliente, cond_profissional, cond_origem_id, cond_categoria, cond_produto, campo, valor, atualizado_por)
    values (btrim(coalesce(p->>'grupo', '')), coalesce(nullif(p->>'prioridade', '')::int, 1000), btrim(coalesce(p->>'cond_cliente', '')),
      btrim(coalesce(p->>'cond_profissional', '')), nullif(p->>'cond_origem_id', '')::uuid, btrim(coalesce(p->>'cond_categoria', '')),
      btrim(coalesce(p->>'cond_produto', '')), p->>'campo', btrim(p->>'valor'), public.com_quem())
    returning id into v_id;
  else
    update public.comissao_trocas set grupo = btrim(coalesce(p->>'grupo', '')), prioridade = coalesce(nullif(p->>'prioridade', '')::int, prioridade),
      ativo = coalesce((p->>'ativo')::boolean, ativo), cond_cliente = btrim(coalesce(p->>'cond_cliente', '')),
      cond_profissional = btrim(coalesce(p->>'cond_profissional', '')), cond_origem_id = nullif(p->>'cond_origem_id', '')::uuid,
      cond_categoria = btrim(coalesce(p->>'cond_categoria', '')), cond_produto = btrim(coalesce(p->>'cond_produto', '')),
      campo = p->>'campo', valor = btrim(p->>'valor'), atualizado_por = public.com_quem()
     where id = v_id;
    if not found then raise exception 'Troca não encontrada.'; end if;
  end if;
  insert into public.auditoria (usuario, acao, alvo, detalhe) values (public.com_quem(), 'salvou troca de campo', p->>'campo', coalesce(p->>'cond_profissional', '') || ' → ' || (p->>'valor'));
  return v_id;
end $$;

create or replace function public.comissao_troca_excluir(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.com_pode_operar() then raise exception 'Seu perfil não pode mexer nas trocas.'; end if;
  delete from public.comissao_trocas where id = p_id;
  if not found then raise exception 'Troca não encontrada.'; end if;
  insert into public.auditoria (usuario, acao, alvo, detalhe) values (public.com_quem(), 'excluiu troca de campo', '', '');
end $$;

create or replace function public.comissao_lista_salvar(p jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid := nullif(p->>'id', '')::uuid; v_itens text[];
begin
  if not public.com_pode_operar() then raise exception 'Seu perfil não pode mexer nas listas.'; end if;
  select coalesce(array_agg(distinct btrim(x)) filter (where btrim(x) <> ''), '{}') into v_itens from jsonb_array_elements_text(coalesce(p->'itens', '[]')) x;
  if v_id is null then
    insert into public.comissao_listas (nome, itens, atualizado_por) values (btrim(p->>'nome'), v_itens, public.com_quem()) returning id into v_id;
  else
    update public.comissao_listas set nome = btrim(p->>'nome'), itens = v_itens, atualizado_em = now(), atualizado_por = public.com_quem() where id = v_id;
    if not found then raise exception 'Lista não encontrada.'; end if;
  end if;
  insert into public.auditoria (usuario, acao, alvo, detalhe) values (public.com_quem(), 'salvou lista de clientes', p->>'nome', cardinality(v_itens) || ' itens');
  return v_id;
exception when unique_violation then raise exception 'Já existe uma lista com esse nome.';
end $$;

create or replace function public.comissao_lista_excluir(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.com_pode_operar() then raise exception 'Seu perfil não pode mexer nas listas.'; end if;
  if exists (select 1 from public.comissao_regras where cond_lista_id = p_id) then raise exception 'Esta lista é usada numa regra. Tire da regra antes.'; end if;
  delete from public.comissao_listas where id = p_id;
end $$;

create or replace function public.comissao_fixo_salvar(p jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid := nullif(p->>'id', '')::uuid; v_ini date; v_fim date;
begin
  if not public.com_pode_operar() then raise exception 'Seu perfil não pode mexer nos ajustes.'; end if;
  if nullif(p->>'user_id', '') is null then raise exception 'Escolha a pessoa.'; end if;
  if coalesce(nullif(p->>'valor', '')::numeric, 0) = 0 then raise exception 'Informe o valor (negativo para descontar).'; end if;
  v_ini := public.com_mes(coalesce(nullif(p->>'inicio', '')::date, now()::date));
  v_fim := public.com_mes(nullif(p->>'fim', '')::date);
  if v_fim is not null and v_fim < v_ini then raise exception 'O fim vem antes do início.'; end if;
  if v_id is null then
    insert into public.comissao_fixos (grupo, user_id, descricao, valor, categoria, inicio, fim, ativo, atualizado_por)
    values (btrim(coalesce(p->>'grupo', '')), (p->>'user_id')::uuid, btrim(p->>'descricao'), (p->>'valor')::numeric,
            coalesce(nullif(btrim(p->>'categoria'), ''), 'AJUSTE'), v_ini, v_fim, coalesce((p->>'ativo')::boolean, true), public.com_quem())
    returning id into v_id;
  else
    update public.comissao_fixos set grupo = btrim(coalesce(p->>'grupo', '')), user_id = (p->>'user_id')::uuid, descricao = btrim(p->>'descricao'),
      valor = (p->>'valor')::numeric, categoria = coalesce(nullif(btrim(p->>'categoria'), ''), 'AJUSTE'), inicio = v_ini, fim = v_fim,
      ativo = coalesce((p->>'ativo')::boolean, ativo), atualizado_por = public.com_quem()
     where id = v_id;
    if not found then raise exception 'Ajuste não encontrado.'; end if;
  end if;
  perform public.com_aplicar_fixos(m.competencia) from public.comissao_meses m where m.status = 'aberto';
  insert into public.auditoria (usuario, acao, alvo, detalhe)
  values (public.com_quem(), 'salvou ajuste fixo', public.com_nome((p->>'user_id')::uuid), (p->>'descricao') || ' ' || (p->>'valor'));
  return v_id;
exception when check_violation then raise exception 'Escreva a descrição do ajuste.';
end $$;

create or replace function public.comissao_fixo_excluir(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.com_pode_operar() then raise exception 'Seu perfil não pode mexer nos ajustes.'; end if;
  -- Nos meses fechados o lançamento fica (com o vínculo solto); nos abertos sai junto.
  update public.comissao_lancamentos l set fixo_id = null
   where l.fixo_id = p_id and (select status from public.comissao_meses m where m.competencia = l.competencia) = 'fechado';
  delete from public.comissao_fixos where id = p_id;
  if not found then raise exception 'Ajuste não encontrado.'; end if;
  insert into public.auditoria (usuario, acao, alvo, detalhe) values (public.com_quem(), 'excluiu ajuste fixo', '', '');
end $$;

create or replace function public.comissao_empresa_salvar(p jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid := nullif(p->>'id', '')::uuid;
begin
  if not public.com_pode_operar() then raise exception 'Seu perfil não pode mexer nas empresas.'; end if;
  if coalesce(nullif(p->>'pct_imposto', '')::numeric, 0) not between 0 and 100 then raise exception 'Imposto entre 0 e 100%%.'; end if;
  if v_id is null then
    insert into public.comissao_empresas (nome, cnpj, pct_imposto, ativo, ordem, atualizado_por)
    values (btrim(p->>'nome'), btrim(coalesce(p->>'cnpj', '')), coalesce(nullif(p->>'pct_imposto', '')::numeric, 0), coalesce((p->>'ativo')::boolean, true),
            (select coalesce(max(ordem), 0) + 1 from public.comissao_empresas), public.com_quem())
    returning id into v_id;
  else
    update public.comissao_empresas set nome = btrim(p->>'nome'), cnpj = btrim(coalesce(p->>'cnpj', '')),
      pct_imposto = coalesce(nullif(p->>'pct_imposto', '')::numeric, 0), ativo = coalesce((p->>'ativo')::boolean, ativo),
      atualizado_em = now(), atualizado_por = public.com_quem()
     where id = v_id;
    if not found then raise exception 'Empresa não encontrada.'; end if;
  end if;
  insert into public.auditoria (usuario, acao, alvo, detalhe) values (public.com_quem(), 'salvou empresa pagadora', p->>'nome', 'imposto ' || coalesce(p->>'pct_imposto', '0') || '%');
  return v_id;
exception when unique_violation then raise exception 'Já existe uma empresa com esse nome.';
         when check_violation then raise exception 'Confira o nome da empresa.';
end $$;

create or replace function public.comissao_origem_salvar(p jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid := nullif(p->>'id', '')::uuid;
begin
  if not public.com_pode_operar() then raise exception 'Seu perfil não pode mexer nas origens.'; end if;
  if coalesce(p->>'moeda', 'BRL') not in ('BRL', 'USD') then raise exception 'Moeda inválida.'; end if;
  if v_id is null then
    insert into public.comissao_origens (nome, moeda, ordem, atualizado_por)
    values (btrim(p->>'nome'), coalesce(p->>'moeda', 'BRL'), (select coalesce(max(ordem), 0) + 1 from public.comissao_origens), public.com_quem())
    returning id into v_id;
  else
    update public.comissao_origens set nome = btrim(p->>'nome'), moeda = coalesce(p->>'moeda', moeda), ativo = coalesce((p->>'ativo')::boolean, ativo),
      atualizado_em = now(), atualizado_por = public.com_quem() where id = v_id;
    if not found then raise exception 'Origem não encontrada.'; end if;
  end if;
  return v_id;
exception when unique_violation then raise exception 'Já existe uma origem com esse nome.';
         when check_violation then raise exception 'Confira o nome da origem.';
end $$;

-- ---------- fechamento ----------
create or replace function public.comissao_fechar(p_competencia date)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_comp date := public.com_mes(p_competencia); v_prox date := (public.com_mes(p_competencia) + interval '1 month')::date;
        t record; m record; n_pag int := 0; n_neg int := 0; n_min int := 0;
begin
  if not public.com_pode_operar() then raise exception 'Seu perfil não pode fechar o mês.'; end if;
  perform public.com_exigir_aberto(v_comp);
  perform public.com_aplicar_fixos(v_comp);
  if not exists (select 1 from public.comissao_lancamentos where competencia = v_comp) then raise exception 'Não há lançamentos neste mês.'; end if;
  perform public.com_garantir_mes(v_prox);
  if (select status from public.comissao_meses where competencia = v_prox) <> 'aberto' then
    raise exception 'O mês seguinte já está fechado; reabra-o antes.';
  end if;
  -- mínimo garantido: o escritório completa até o piso
  delete from public.comissao_lancamentos where competencia = v_comp and tipo = 'minimo';
  for m in select * from public.com_minimos(v_comp) where complemento > 0 loop
    insert into public.comissao_lancamentos (competencia, tipo, profissional_id, profissional_txt, categoria, descricao, valor, rateio, valor_escritorio, gerado_por_fechamento, criado_por)
    values (v_comp, 'minimo', m.user_id, coalesce(public.com_nome(m.user_id), ''), 'MÍNIMO GARANTIDO', 'Complemento até o mínimo de R$ ' || translate(to_char(m.minimo, 'FM999,999,990.00'), ',.', '.,'),
            -m.complemento, jsonb_build_array(jsonb_build_object('user_id', m.user_id, 'papel', 'mínimo garantido', 'valor', m.complemento)), -m.complemento, v_comp, public.com_quem());
    n_min := n_min + 1;
  end loop;
  delete from public.comissao_pagamentos where competencia = v_comp;
  for t in select * from public.com_totais(v_comp) loop
    if t.bruto > 0 then
      insert into public.comissao_pagamentos (competencia, user_id, bruto, pct_imposto, imposto, valor, empresa_id)
      values (v_comp, t.user_id, t.bruto, t.pct_imposto, t.imposto, t.liquido, t.empresa_id);
      n_pag := n_pag + 1;
    elsif t.bruto < 0 then
      -- Fechou negativo: o saldo passa para o mês seguinte.
      insert into public.comissao_lancamentos (competencia, tipo, profissional_id, profissional_txt, categoria, descricao, rateio, gerado_por_fechamento, criado_por)
      values (v_prox, 'saldo_anterior', t.user_id, coalesce(public.com_nome(t.user_id), ''), 'SALDO ANTERIOR', 'Saldo negativo de ' || to_char(v_comp, 'MM/YYYY'),
              jsonb_build_array(jsonb_build_object('user_id', t.user_id, 'papel', 'saldo anterior', 'valor', t.bruto)), v_comp, public.com_quem());
      n_neg := n_neg + 1;
    end if;
  end loop;
  update public.comissao_meses set status = 'fechado', fechado_em = now(), fechado_por = public.com_quem() where competencia = v_comp;
  insert into public.auditoria (usuario, acao, alvo, detalhe)
  values (public.com_quem(), 'fechou comissões', to_char(v_comp, 'MM/YYYY'), n_pag || ' a pagar, ' || n_neg || ' saldo(s) negativo(s) levado(s), ' || n_min || ' mínimo(s)');
  return jsonb_build_object('a_pagar', n_pag, 'negativos', n_neg, 'minimos', n_min);
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
  delete from public.comissao_lancamentos where competencia = v_comp and tipo = 'minimo';
  delete from public.comissao_pagamentos where competencia = v_comp;
  update public.comissao_meses set status = 'aberto', liberado = false, liberado_em = null, reaberto_em = now(), motivo_reabertura = btrim(p_motivo)
   where competencia = v_comp;
  insert into public.auditoria (usuario, acao, alvo, detalhe) values (public.com_quem(), 'reabriu comissões', to_char(v_comp, 'MM/YYYY'), btrim(p_motivo));
end $$;

-- Libera (ou recolhe) o fechamento para cada profissional ver o seu em "Minha comissão".
create or replace function public.comissao_liberar(p_competencia date, p_liberado boolean)
returns void language plpgsql security definer set search_path = public as $$
declare v_comp date := public.com_mes(p_competencia);
begin
  if not public.com_pode_operar() then raise exception 'Seu perfil não pode liberar o fechamento.'; end if;
  if p_liberado and (select status from public.comissao_meses where competencia = v_comp) is distinct from 'fechado' then
    raise exception 'Feche o mês antes de liberar para os profissionais.';
  end if;
  update public.comissao_meses set liberado = coalesce(p_liberado, false), liberado_em = case when p_liberado then now() end where competencia = v_comp;
  insert into public.auditoria (usuario, acao, alvo, detalhe)
  values (public.com_quem(), case when p_liberado then 'liberou fechamento para os profissionais' else 'recolheu fechamento dos profissionais' end, to_char(v_comp, 'MM/YYYY'), '');
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

-- ---------- dados de pagamento e acordos ----------
-- Quem opera comissões lê e grava; o master também, pela ficha da pessoa na Equipe.
create or replace function public.comissao_dados_pagto_ler(p_user uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not (public.com_pode_ver() or public.eh_super()) then raise exception 'Sem acesso aos dados de pagamento.'; end if;
  return (select to_jsonb(d) from public.comissao_dados_pagto d where d.user_id = p_user);
end $$;
create or replace function public.comissao_dados_pagto_salvar(p_user uuid, p jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare v_nomes text[];
begin
  if not (public.com_pode_operar() or public.eh_super()) then raise exception 'Sem permissão para mudar dados de pagamento.'; end if;
  if not exists (select 1 from auth.users where id = p_user) then raise exception 'Pessoa não encontrada.'; end if;
  select coalesce(array_agg(distinct left(btrim(x), 160)) filter (where btrim(x) <> ''), '{}') into v_nomes
    from jsonb_array_elements_text(case when jsonb_typeof(p->'nomes_planilha') = 'array' then p->'nomes_planilha' else '[]'::jsonb end) x;
  insert into public.comissao_dados_pagto as d (user_id, nome_completo, cpf_cnpj, banco, agencia, conta, tipo_conta, pix_tipo, pix_chave, titular, observacao,
    empresa_id, nomes_planilha, atualizado_em, atualizado_por)
  values (p_user, left(btrim(coalesce(p->>'nome_completo', '')), 160), left(btrim(coalesce(p->>'cpf_cnpj', '')), 30),
          left(btrim(coalesce(p->>'banco', '')), 80), left(btrim(coalesce(p->>'agencia', '')), 20), left(btrim(coalesce(p->>'conta', '')), 30),
          left(btrim(coalesce(p->>'tipo_conta', '')), 30), left(btrim(coalesce(p->>'pix_tipo', '')), 30), left(btrim(coalesce(p->>'pix_chave', '')), 120),
          left(btrim(coalesce(p->>'titular', '')), 160), left(btrim(coalesce(p->>'observacao', '')), 500),
          nullif(p->>'empresa_id', '')::uuid, v_nomes, now(), public.com_quem())
  on conflict (user_id) do update set nome_completo = excluded.nome_completo, cpf_cnpj = excluded.cpf_cnpj, banco = excluded.banco,
    agencia = excluded.agencia, conta = excluded.conta, tipo_conta = excluded.tipo_conta, pix_tipo = excluded.pix_tipo,
    pix_chave = excluded.pix_chave, titular = excluded.titular, observacao = excluded.observacao,
    empresa_id = case when p ? 'empresa_id' then excluded.empresa_id else d.empresa_id end,
    nomes_planilha = case when p ? 'nomes_planilha' then excluded.nomes_planilha else d.nomes_planilha end,
    atualizado_em = now(), atualizado_por = excluded.atualizado_por;
  insert into public.auditoria (usuario, acao, alvo, detalhe) values (public.com_quem(), 'alterou dados de pagamento', (select email from auth.users where id = p_user), '');
end $$;

create or replace function public.comissao_acordo_salvar(p_user uuid, p jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.com_pode_operar() then raise exception 'Seu perfil não pode mudar acordos contratuais.'; end if;
  if not exists (select 1 from auth.users where id = p_user) then raise exception 'Pessoa não encontrada.'; end if;
  insert into public.comissao_acordos as a (user_id, funcao, luvas_ano, anos_luvas, bonificacao, custo_fixo_pct, salario, remuneracao_minima,
    tamanho_carteira, roa_liquido, data_contratacao, segmento, senioridade, conv_ano1, conv_ano2, conv_ano3, conv_ano4,
    com_ano1, com_ano2, com_ano3, com_ano4, obs, atualizado_em, atualizado_por)
  values (p_user, left(btrim(coalesce(p->>'funcao', '')), 80), nullif(p->>'luvas_ano', '')::numeric, nullif(p->>'anos_luvas', '')::numeric,
    nullif(p->>'bonificacao', '')::numeric, nullif(p->>'custo_fixo_pct', '')::numeric, nullif(p->>'salario', '')::numeric,
    nullif(p->>'remuneracao_minima', '')::numeric, nullif(p->>'tamanho_carteira', '')::numeric, nullif(p->>'roa_liquido', '')::numeric,
    nullif(p->>'data_contratacao', '')::date, left(btrim(coalesce(p->>'segmento', '')), 80), left(btrim(coalesce(p->>'senioridade', '')), 80),
    nullif(p->>'conv_ano1', '')::numeric, nullif(p->>'conv_ano2', '')::numeric, nullif(p->>'conv_ano3', '')::numeric, nullif(p->>'conv_ano4', '')::numeric,
    nullif(p->>'com_ano1', '')::numeric, nullif(p->>'com_ano2', '')::numeric, nullif(p->>'com_ano3', '')::numeric, nullif(p->>'com_ano4', '')::numeric,
    left(coalesce(p->>'obs', ''), 1000), now(), public.com_quem())
  on conflict (user_id) do update set funcao = excluded.funcao, luvas_ano = excluded.luvas_ano, anos_luvas = excluded.anos_luvas,
    bonificacao = excluded.bonificacao, custo_fixo_pct = excluded.custo_fixo_pct, salario = excluded.salario,
    remuneracao_minima = excluded.remuneracao_minima, tamanho_carteira = excluded.tamanho_carteira, roa_liquido = excluded.roa_liquido,
    data_contratacao = excluded.data_contratacao, segmento = excluded.segmento, senioridade = excluded.senioridade,
    conv_ano1 = excluded.conv_ano1, conv_ano2 = excluded.conv_ano2, conv_ano3 = excluded.conv_ano3, conv_ano4 = excluded.conv_ano4,
    com_ano1 = excluded.com_ano1, com_ano2 = excluded.com_ano2, com_ano3 = excluded.com_ano3, com_ano4 = excluded.com_ano4,
    obs = excluded.obs, atualizado_em = now(), atualizado_por = excluded.atualizado_por;
  insert into public.auditoria (usuario, acao, alvo, detalhe) values (public.com_quem(), 'alterou acordo contratual', (select email from auth.users where id = p_user), '');
exception when invalid_text_representation or invalid_datetime_format then
  raise exception 'Confira os números e a data do acordo.';
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
    select t.user_id, coalesce(nullif(p.nome, ''), split_part(u.email, '@', 1))::text, u.email::text, t.liquido
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

-- ---------- "Minha comissão": cada pessoa vê só o seu, nos meses liberados ----------
create or replace function public.comissao_minha(p_competencia date)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_eu uuid := auth.uid(); v_comp date;
begin
  if v_eu is null or not public.acesso_liberado() then raise exception 'Entre no Hub de novo.'; end if;
  v_comp := coalesce(public.com_mes(p_competencia),
                     (select max(competencia) from public.comissao_meses where liberado));
  if v_comp is not null and not exists (select 1 from public.comissao_meses where competencia = v_comp and liberado) then
    raise exception 'Este mês ainda não foi liberado.';
  end if;
  if v_comp is not null then
    update public.comissao_pagamentos set visualizado_em = coalesce(visualizado_em, now()) where competencia = v_comp and user_id = v_eu;
  end if;
  return jsonb_build_object(
    'competencia', v_comp,
    'nome', public.com_nome(v_eu),
    'meses', coalesce((select jsonb_agg(m.competencia order by m.competencia desc) from public.comissao_meses m where m.liberado), '[]'),
    'pagamento', (select jsonb_build_object('bruto', p.bruto, 'pct_imposto', p.pct_imposto, 'imposto', p.imposto, 'valor', p.valor, 'pago_em', p.pago_em,
                    'empresa', (select nome from public.comissao_empresas e where e.id = p.empresa_id))
                    from public.comissao_pagamentos p where p.competencia = v_comp and p.user_id = v_eu),
    'linhas', coalesce((select jsonb_agg(jsonb_build_object('tipo', l.tipo, 'origem', l.origem_nome, 'cliente', l.cliente, 'conta', l.conta,
        'categoria', l.categoria, 'produto', l.produto, 'descricao', l.descricao, 'gerada', l.valor, 'parte', (r->>'valor')::numeric, 'papel', r->>'papel')
        order by l.categoria, l.cliente)
      from public.comissao_lancamentos l, jsonb_array_elements(l.rateio) r
     where l.competencia = v_comp and (r->>'user_id')::uuid = v_eu), '[]'));
end $$;

revoke all on function public.comissoes_painel(date), public.comissao_planilha_itens(uuid),
  public.comissao_simular(date, uuid, numeric, jsonb), public.comissao_planilha_salvar(jsonb), public.comissao_recalcular(date, uuid),
  public.comissao_planilha_excluir(uuid), public.comissao_lancamento_salvar(jsonb), public.comissao_lancamento_excluir(uuid),
  public.comissao_regra_salvar(jsonb), public.comissao_regras_ordenar(uuid[]), public.comissao_regra_excluir(uuid), public.comissao_testar(jsonb, date),
  public.comissao_troca_salvar(jsonb), public.comissao_troca_excluir(uuid), public.comissao_lista_salvar(jsonb), public.comissao_lista_excluir(uuid),
  public.comissao_fixo_salvar(jsonb), public.comissao_fixo_excluir(uuid), public.comissao_empresa_salvar(jsonb), public.comissao_origem_salvar(jsonb),
  public.comissao_fechar(date), public.comissao_reabrir(date, text), public.comissao_liberar(date, boolean), public.comissao_marcar_pago(date, uuid, date),
  public.comissao_dados_pagto_ler(uuid), public.comissao_dados_pagto_salvar(uuid, jsonb), public.comissao_acordo_salvar(uuid, jsonb),
  public.comissao_envio_lista(date), public.comissao_envio_registrar(date, uuid, text), public.comissao_minha(date) from public, anon;
grant execute on function public.comissoes_painel(date), public.comissao_planilha_itens(uuid),
  public.comissao_simular(date, uuid, numeric, jsonb), public.comissao_planilha_salvar(jsonb), public.comissao_recalcular(date, uuid),
  public.comissao_planilha_excluir(uuid), public.comissao_lancamento_salvar(jsonb), public.comissao_lancamento_excluir(uuid),
  public.comissao_regra_salvar(jsonb), public.comissao_regras_ordenar(uuid[]), public.comissao_regra_excluir(uuid), public.comissao_testar(jsonb, date),
  public.comissao_troca_salvar(jsonb), public.comissao_troca_excluir(uuid), public.comissao_lista_salvar(jsonb), public.comissao_lista_excluir(uuid),
  public.comissao_fixo_salvar(jsonb), public.comissao_fixo_excluir(uuid), public.comissao_empresa_salvar(jsonb), public.comissao_origem_salvar(jsonb),
  public.comissao_fechar(date), public.comissao_reabrir(date, text), public.comissao_liberar(date, boolean), public.comissao_marcar_pago(date, uuid, date),
  public.comissao_dados_pagto_ler(uuid), public.comissao_dados_pagto_salvar(uuid, jsonb), public.comissao_acordo_salvar(uuid, jsonb),
  public.comissao_envio_lista(date), public.comissao_envio_registrar(date, uuid, text), public.comissao_minha(date) to authenticated;

-- Mesma camada das outras tabelas (seção 22): mesmo fechadas, ganham a política restritiva.
do $$
declare t text;
begin
  foreach t in array array['comissao_empresas','comissao_dados_pagto','comissao_acordos','comissao_origens','comissao_listas','comissao_regras',
                           'comissao_trocas','comissao_meses','comissao_planilhas','comissao_fixos','comissao_lancamentos','comissao_pagamentos'] loop
    execute format('drop policy if exists exige_verificacao on public.%I', t);
    execute format('create policy exige_verificacao on public.%I as restrictive for all to authenticated '
                   'using ((select public.acesso_liberado())) with check ((select public.acesso_liberado()))', t);
  end loop;
end $$;

select public.com_garantir_mes(date '2026-10-01');
