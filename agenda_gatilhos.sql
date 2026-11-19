-- Agenda do CRM como "missão do dia" (19/11/2026, CRM 2026.11.19.4).
-- O master escolhe na tela Agenda > Gatilhos quais tarefas automáticas o Hub cria para os assessores, com os números
-- de cada uma (saldo mínimo, dias de antecedência...). Três partes:
--   agenda_gatilhos   liga/desliga + parâmetros de cada gatilho (o catálogo com nome e explicação fica no crm.html).
--                     Lê quem está no CRM; grava só o master, pela função agenda_gatilho_definir (com auditoria).
--   agenda_resolvidos o que o assessor marcou como feito nas tarefas automáticas (uma linha por tarefa, pela chave),
--                     para ela não voltar. Grava só pela função agenda_resolver.
--   agenda_btg_itens  as tarefas que saem dos dados do BTG (saldo em conta, vencimentos, cotização, FGC, contas sem
--                     ativar, aniversário, suitability, aportes e saídas), só das fichas que a pessoa pode ver.
-- Rodar inteiro no SQL Editor (Run without RLS).

create table if not exists public.agenda_gatilhos (
  chave text primary key,
  ligado boolean not null default false,
  params jsonb not null default '{}'::jsonb,
  atualizado_em timestamptz not null default now(),
  atualizado_por uuid
);
alter table public.agenda_gatilhos enable row level security;
revoke all on public.agenda_gatilhos from anon, authenticated;
grant select on public.agenda_gatilhos to authenticated;
drop policy if exists agenda_gatilhos_ler on public.agenda_gatilhos;
create policy agenda_gatilhos_ler on public.agenda_gatilhos for select to authenticated using ((select public.is_ativo()));
drop policy if exists exige_verificacao on public.agenda_gatilhos;
create policy exige_verificacao on public.agenda_gatilhos as restrictive for all to authenticated
  using ((select public.acesso_liberado())) with check ((select public.acesso_liberado()));

-- Valores iniciais: os gatilhos que vêm dos dados (BTG e processo comercial) começam ligados; rotina e capacitação
-- começam desligados, porque dependem do texto que a gestão quer. Rodar de novo não desfaz o que o master marcou.
insert into public.agenda_gatilhos (chave, ligado, params) values
  ('btg_caixa', true, '{"min":10000}'),
  ('btg_vencimento', true, '{"dias":15}'),
  ('btg_cotizacao', true, '{"dias":15}'),
  ('btg_fgc', true, '{"limite":250000}'),
  ('btg_ativar', true, '{"dias":90}'),
  ('btg_aniversario', true, '{}'),
  ('btg_suitability', true, '{"dias":30}'),
  ('btg_aporte', true, '{"min":50000,"dias":3}'),
  ('btg_saida', true, '{"min":100000,"dias":3}'),
  ('crm_lead_novo', true, '{"dias":1}'),
  ('crm_sla', true, '{}'),
  ('crm_proposta', true, '{"dias":5}'),
  ('crm_parado', true, '{"dias":15}'),
  ('crm_boas_vindas', true, '{}'),
  ('crm_indicacao', true, '{"dias":60}'),
  ('crm_revisao_anual', false, '{"dias":365}'),
  ('esp_oportunidade', true, '{}'),
  ('rot_cenario', false, '{"titulo":"Ler o cenário do dia","hora":"08:30"}'),
  ('rot_prospeccao', false, '{"titulo":"Bloco de prospecção","meta":10,"hora":"10:00"}'),
  ('rot_registro', false, '{"titulo":"Registrar as atividades do dia no CRM","hora":"17:30"}'),
  ('rot_reuniao_semanal', false, '{"titulo":"Reunião comercial da semana","dia_semana":1,"hora":"09:00"}'),
  ('rot_pipeline', false, '{"titulo":"Revisar o pipeline e a temperatura dos negócios","dia_semana":5}'),
  ('rot_comite', false, '{"titulo":"Comitê de alocação do mês","dia_mes":10}'),
  ('rot_fechamento', false, '{"titulo":"Fechar as carteiras do mês","dia_mes":2}'),
  ('rot_comissao', false, '{"titulo":"Conferir a comissão do mês","dia_mes":15}'),
  ('cap_conteudo', false, '{"titulo":"","link":"","dia_semana":1}'),
  ('cap_produto', false, '{"titulo":"","link":"","dia_semana":1}'),
  ('cap_certificacao', false, '{"dias":90,"lista":[]}'),
  ('cap_roleplay', false, '{"titulo":"Roleplay com o head comercial (R1 ou proposta)","dia_mes":20}'),
  ('cap_especialista', false, '{"titulo":"Acompanhar uma reunião de especialista","dia_mes":25}')
on conflict (chave) do nothing;

create or replace function public.agenda_gatilho_definir(p_chave text, p_ligado boolean, p_params jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_antes public.agenda_gatilhos;
begin
  if not public.eh_super() then raise exception 'Só um master muda os gatilhos da Agenda.'; end if;
  if coalesce(p_chave, '') !~ '^[a-z_]{3,40}$' then raise exception 'Gatilho inválido.'; end if;
  if p_params is not null and jsonb_typeof(p_params) <> 'object' then raise exception 'Parâmetros inválidos.'; end if;
  if length(coalesce(p_params, '{}'::jsonb)::text) > 20000 then raise exception 'Parâmetros grandes demais.'; end if;
  select * into v_antes from public.agenda_gatilhos where chave = p_chave;
  insert into public.agenda_gatilhos (chave, ligado, params, atualizado_em, atualizado_por)
  values (p_chave, coalesce(p_ligado, false), coalesce(p_params, '{}'::jsonb), now(), auth.uid())
  on conflict (chave) do update set ligado = excluded.ligado, params = excluded.params,
    atualizado_em = now(), atualizado_por = auth.uid();
  insert into public.auditoria (quando, usuario, acao, alvo, detalhe)
  values (now(), coalesce((select email from auth.users where id = auth.uid()), auth.uid()::text), 'agenda_gatilho', p_chave,
          left(jsonb_build_object('antes', to_jsonb(v_antes) - 'atualizado_por', 'ligado', p_ligado, 'params', p_params)::text, 2000));
  return (select to_jsonb(g) from public.agenda_gatilhos g where chave = p_chave);
end $$;
revoke all on function public.agenda_gatilho_definir(text, boolean, jsonb) from public, anon;
grant execute on function public.agenda_gatilho_definir(text, boolean, jsonb) to authenticated;

create table if not exists public.agenda_resolvidos (
  chave text primary key,
  gatilho text not null,
  lead_id text,
  dono_id uuid,
  resolvido_por uuid not null,
  resolvido_em timestamptz not null default now(),
  dia date not null default (now() at time zone 'America/Sao_Paulo')::date,
  nota text
);
create index if not exists agenda_resolvidos_dono on public.agenda_resolvidos (dono_id, dia);
alter table public.agenda_resolvidos enable row level security;
revoke all on public.agenda_resolvidos from anon, authenticated;
grant select on public.agenda_resolvidos to authenticated;
drop policy if exists agenda_resolvidos_ler on public.agenda_resolvidos;
create policy agenda_resolvidos_ler on public.agenda_resolvidos for select to authenticated
  using ((select public.is_ativo()) and (resolvido_por = (select auth.uid()) or dono_id = (select auth.uid())
         or (select public.is_admin()) or (select public.eh_super())));
drop policy if exists exige_verificacao on public.agenda_resolvidos;
create policy exige_verificacao on public.agenda_resolvidos as restrictive for all to authenticated
  using ((select public.acesso_liberado())) with check ((select public.acesso_liberado()));
drop policy if exists exige_ferramenta on public.agenda_resolvidos;
create policy exige_ferramenta on public.agenda_resolvidos as restrictive for all to authenticated
  using ((select public.tem_permissao('ferramenta.crm'))) with check ((select public.tem_permissao('ferramenta.crm')));

-- Marca (p_feito = true) ou desmarca uma tarefa automática. Com cliente, só quem pode ver a ficha; o dono da tarefa
-- é o responsável pela ficha. Sem cliente (rotina, capacitação), a tarefa é da própria pessoa: a chave termina no id dela.
create or replace function public.agenda_resolver(p_chave text, p_gatilho text, p_lead_id text, p_nota text, p_feito boolean default true)
returns boolean language plpgsql security definer set search_path = public as $$
declare v_dono uuid;
begin
  if not public.acesso_liberado() or not public.is_ativo() or not public.tem_permissao('ferramenta.crm') then
    raise exception 'Acesso não liberado.';
  end if;
  if coalesce(p_chave, '') = '' or length(p_chave) > 300 or coalesce(p_gatilho, '') !~ '^[a-z_]{3,40}$' then
    raise exception 'Tarefa inválida.';
  end if;
  if coalesce(p_lead_id, '') <> '' then
    if not public.pode_ver_lead(p_lead_id) then raise exception 'Cliente fora do seu alcance.'; end if;
    select responsavel_id into v_dono from public.leads where id = p_lead_id;
  else
    if right(p_chave, 36) <> auth.uid()::text then raise exception 'Tarefa de outra pessoa.'; end if;
    v_dono := auth.uid();
  end if;
  if coalesce(p_feito, true) then
    insert into public.agenda_resolvidos (chave, gatilho, lead_id, dono_id, resolvido_por, nota)
    values (p_chave, p_gatilho, nullif(p_lead_id, ''), v_dono, auth.uid(), left(p_nota, 2000))
    on conflict (chave) do nothing;
  else
    delete from public.agenda_resolvidos
     where chave = p_chave and (resolvido_por = auth.uid() or public.is_admin() or public.eh_super());
  end if;
  return true;
end $$;
revoke all on function public.agenda_resolver(text, text, text, text, boolean) from public, anon;
grant execute on function public.agenda_resolver(text, text, text, text, boolean) to authenticated;

-- Tarefas que saem dos dados do BTG, prontas para a Agenda. Uma linha por tarefa:
-- {gatilho, chave, lead_id, dono_id, valor, data, info}. "data" é a data do fato (vencimento, aniversário...);
-- a tarefa vale para hoje. As já resolvidas não voltam. p_dono filtra um assessor (null = todas as fichas visíveis).
create or replace function public.agenda_btg_itens(p_dono uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_vis text[];
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  g jsonb;
  v_pos bigint; v_mov bigint; v_cad bigint;
begin
  if not public.acesso_liberado() then raise exception 'Acesso não liberado.'; end if;
  if not public.tem_permissao('ferramenta.crm') then return '[]'::jsonb; end if;
  v_vis := public.crm_fichas_visiveis();
  select coalesce(jsonb_object_agg(chave, params), '{}'::jsonb) into g from public.agenda_gatilhos where ligado;
  select max(id) into v_pos from public.btg_arquivos where servico = 'rm-reports-position-by-date' and status = 'processado';
  select max(id) into v_mov from public.btg_arquivos where servico = 'rm-reports-movement' and status = 'processado';
  select max(id) into v_cad from public.btg_arquivos where servico = 'rm-reports-registration-data' and status = 'processado';
  return coalesce((
    with lc as (
      select ld.id, ld.responsavel_id dono, ltrim(regexp_replace(ld.conta, '\D', '', 'g'), '0') k
        from public.leads ld
       where not coalesce(ld.excluido, false) and coalesce(ld.funil, 'assessor') = 'assessor' and coalesce(ld.conta, '') <> ''
         and (p_dono is null or ld.responsavel_id = p_dono)
         and (v_vis is null or ld.id = any(v_vis))
    ), base as (
      select lc.id lead_id, lc.dono, lc.k, b.dados, (b.atualizado_em at time zone 'America/Sao_Paulo')::date dia_base
        from public.btg_base b join lc on lc.k = ltrim(b.nr_conta, '0')
    ), pos as (
      select lc.id lead_id, lc.dono, lc.k, p.dados from public.btg_linhas p join lc on lc.k = ltrim(p.nr_conta, '0')
       where v_pos is not null and p.arquivo_id = v_pos
    ), mov as (
      select lc.id lead_id, lc.dono, lc.k, m.dados from public.btg_linhas m join lc on lc.k = ltrim(m.nr_conta, '0')
       where v_mov is not null and m.arquivo_id = v_mov and m.dados->>'flag_nnm' = 'SIM'
         and left(m.dados->>'dt_movimentacao', 10) >= to_char(v_hoje - greatest(coalesce((g->'btg_saida'->>'dias')::int, 3), coalesce((g->'btg_aporte'->>'dias')::int, 3)), 'YYYY-MM-DD')
    ), itens as (
      -- dinheiro parado: saldo em conta corrente no dia, acima do mínimo
      select 'btg_caixa' gatilho, 'caixa:' || k || ':' || dia_base chave, lead_id, dono,
             public.btg_numero(dados->>'pl_conta_corrente') valor, dia_base::text data, '{}'::jsonb info
        from base where g ? 'btg_caixa'
         and public.btg_numero(dados->>'pl_conta_corrente') >= coalesce((g->'btg_caixa'->>'min')::numeric, 10000)
      union all
      -- vencimento de renda fixa e COE nos próximos N dias, agrupado por cliente e data
      select 'btg_vencimento', 'venc:' || k || ':' || d, lead_id, dono, sum(v), d,
             jsonb_build_object('ativos', jsonb_agg(a order by v desc))
        from (select lead_id, dono, k, left(dados->>'dt_vencimento', 10) d, public.btg_numero(dados->>'vl_bruto') v,
                     coalesce(nullif(dados->>'ativo', ''), dados->>'produto') a
                from pos where g ? 'btg_vencimento' and dados->>'mercado' in ('RENDA FIXA', 'COE')
                 and left(coalesce(dados->>'dt_vencimento', ''), 10) between to_char(v_hoje, 'YYYY-MM-DD')
                     and to_char(v_hoje + coalesce((g->'btg_vencimento'->>'dias')::int, 15), 'YYYY-MM-DD')) x
       group by lead_id, dono, k, d
      union all
      -- resgate de fundo em cotização: avisar a data em que o dinheiro cai
      select 'btg_cotizacao', 'cot:' || k || ':' || d, lead_id, dono, sum(v), d,
             jsonb_build_object('ativos', jsonb_agg(a order by v desc))
        from (select lead_id, dono, k, left(dados->>'dt_vencimento', 10) d, public.btg_numero(dados->>'vl_bruto') v,
                     coalesce(nullif(dados->>'ativo', ''), dados->>'produto') a
                from pos where g ? 'btg_cotizacao' and dados->>'mercado' ilike 'VALOR EM TR%' and dados->>'sub_mercado' in ('FN', 'PN')
                 and left(coalesce(dados->>'dt_vencimento', ''), 10) between to_char(v_hoje, 'YYYY-MM-DD')
                     and to_char(v_hoje + coalesce((g->'btg_cotizacao'->>'dias')::int, 15), 'YYYY-MM-DD')) x
       group by lead_id, dono, k, d
      union all
      -- mesmo emissor acima do limite do FGC (produtos cobertos), uma vez por mês
      select 'btg_fgc', 'fgc:' || k || ':' || md5(e) || ':' || to_char(v_hoje, 'YYYY-MM'), lead_id, dono, sum(v), null,
             jsonb_build_object('emissor', e)
        from (select lead_id, dono, k, coalesce(nullif(dados->>'emissor', ''), '?') e, public.btg_numero(dados->>'vl_bruto') v
                from pos where g ? 'btg_fgc' and dados->>'mercado' = 'RENDA FIXA'
                 and dados->>'produto' in ('CDB', 'RDB', 'LC', 'LCI', 'LCA', 'LH', 'LIG')) x
       group by lead_id, dono, k, e
      having sum(v) > coalesce((g->'btg_fgc'->>'limite')::numeric, 250000)
      union all
      -- conta aberta há pouco e ainda sem dinheiro, uma vez por mês
      select 'btg_ativar', 'ativar:' || k || ':' || to_char(v_hoje, 'YYYY-MM'), lead_id, dono, null, dados->>'dt_abertura', '{}'::jsonb
        from base where g ? 'btg_ativar' and coalesce(public.btg_numero(dados->>'pl_total'), 0) = 0
         and coalesce(dados->>'dt_abertura', '') >= to_char(v_hoje - coalesce((g->'btg_ativar'->>'dias')::int, 90), 'YYYY-MM-DD')
      union all
      -- aniversário hoje (na segunda, também o do fim de semana)
      select 'btg_aniversario', 'aniv:' || k || ':' || extract(year from v_hoje), lead_id, dono, null,
             to_char(v_hoje, 'YYYY') || '-' || substr(dados->>'dt_nascimento', 4, 2) || '-' || substr(dados->>'dt_nascimento', 1, 2), '{}'::jsonb
        from base where g ? 'btg_aniversario' and coalesce(dados->>'dt_nascimento', '') ~ '^\d{2}/\d{2}/\d{4}$'
         and substr(dados->>'dt_nascimento', 4, 2) || substr(dados->>'dt_nascimento', 1, 2) in
             (to_char(v_hoje, 'MMDD'), case when extract(isodow from v_hoje) = 1 then to_char(v_hoje - 1, 'MMDD') end,
              case when extract(isodow from v_hoje) = 1 then to_char(v_hoje - 2, 'MMDD') end)
      union all
      -- suitability vencendo (cadastro do BTG)
      select 'btg_suitability', 'suit:' || lc.k || ':' || left(c.dados->>'dt_vencimento_suitability', 10), lc.id, lc.dono, null,
             left(c.dados->>'dt_vencimento_suitability', 10), '{}'::jsonb
        from public.btg_linhas c join lc on lc.k = ltrim(c.nr_conta, '0')
       where g ? 'btg_suitability' and v_cad is not null and c.arquivo_id = v_cad
         and left(coalesce(c.dados->>'dt_vencimento_suitability', ''), 10) ~ '^\d{4}-\d{2}-\d{2}$'
         and left(c.dados->>'dt_vencimento_suitability', 10) <= to_char(v_hoje + coalesce((g->'btg_suitability'->>'dias')::int, 30), 'YYYY-MM-DD')
      union all
      -- aporte recebido (entrada de dinheiro novo), por dia
      select 'btg_aporte', 'aporte:' || k || ':' || d, lead_id, dono, sum(v), d, '{}'::jsonb
        from (select lead_id, dono, k, left(dados->>'dt_movimentacao', 10) d, public.btg_numero(dados->>'vl_bruto') v
                from mov where g ? 'btg_aporte' and public.btg_numero(dados->>'vl_bruto') > 0
                 and left(dados->>'dt_movimentacao', 10) >= to_char(v_hoje - coalesce((g->'btg_aporte'->>'dias')::int, 3), 'YYYY-MM-DD')) x
       group by lead_id, dono, k, d
      having sum(v) >= coalesce((g->'btg_aporte'->>'min')::numeric, 50000)
      union all
      -- saída de dinheiro (resgate para fora do BTG), por dia
      select 'btg_saida', 'saida:' || k || ':' || d, lead_id, dono, -sum(v), d, '{}'::jsonb
        from (select lead_id, dono, k, left(dados->>'dt_movimentacao', 10) d, public.btg_numero(dados->>'vl_bruto') v
                from mov where g ? 'btg_saida' and public.btg_numero(dados->>'vl_bruto') < 0
                 and left(dados->>'dt_movimentacao', 10) >= to_char(v_hoje - coalesce((g->'btg_saida'->>'dias')::int, 3), 'YYYY-MM-DD')) x
       group by lead_id, dono, k, d
      having -sum(v) >= coalesce((g->'btg_saida'->>'min')::numeric, 100000)
    )
    select jsonb_agg(jsonb_build_object('gatilho', i.gatilho, 'chave', i.chave, 'lead_id', i.lead_id, 'dono_id', i.dono,
             'valor', round(i.valor, 2), 'data', i.data, 'info', i.info) order by i.valor desc nulls last)
      from itens i
     where not exists (select 1 from public.agenda_resolvidos r where r.chave = i.chave)
  ), '[]'::jsonb);
end $$;
revoke all on function public.agenda_btg_itens(uuid) from public, anon;
grant execute on function public.agenda_btg_itens(uuid) to authenticated;

-- ===================================================================
-- Indicações dos especialistas de produto (19/11/2026). O especialista (seguro, consórcio...) escolhe na base os
-- clientes com perfil para o produto; cada indicação vira tarefa na Agenda do assessor responsável pela ficha.
-- O especialista vê, para escolher, nome, assessor e patrimônio por classe dos clientes da base do BTG (sem telefone
-- nem e-mail). O assessor responde "falei com o cliente" ou "sem interesse"; o especialista acompanha.
-- ===================================================================
create table if not exists public.oportunidades_produto (
  id uuid primary key default gen_random_uuid(),
  lead_id text not null,
  produto text not null,
  nota text,
  especialista_id uuid not null,
  dono_id uuid,
  status text not null default 'aberta' check (status in ('aberta', 'feita', 'sem_interesse', 'cancelada')),
  criado_em timestamptz not null default now(),
  resolvido_em timestamptz,
  resolvido_por uuid,
  resposta text
);
create unique index if not exists oportunidades_produto_aberta on public.oportunidades_produto (lead_id, produto) where status = 'aberta';
create index if not exists oportunidades_produto_dono on public.oportunidades_produto (dono_id, status);
alter table public.oportunidades_produto enable row level security;
drop policy if exists oportunidades_ler on public.oportunidades_produto;
create policy oportunidades_ler on public.oportunidades_produto for select to authenticated
  using ((select public.is_ativo()) and (especialista_id = (select auth.uid()) or dono_id = (select auth.uid())
         or (select public.is_admin()) or (select public.eh_super())));
drop policy if exists exige_verificacao on public.oportunidades_produto;
create policy exige_verificacao on public.oportunidades_produto as restrictive for all to authenticated
  using ((select public.acesso_liberado())) with check ((select public.acesso_liberado()));
drop policy if exists exige_ferramenta on public.oportunidades_produto;
create policy exige_ferramenta on public.oportunidades_produto as restrictive for all to authenticated
  using ((select public.tem_permissao('ferramenta.crm'))) with check ((select public.tem_permissao('ferramenta.crm')));

-- Quem pode indicar: especialista ativo no CRM, administrador do CRM ou master.
create or replace function public.oport_pode_indicar()
returns boolean language sql stable security definer set search_path = public as $$
  select public.acesso_liberado() and public.tem_permissao('ferramenta.crm') and (
    exists (select 1 from public.profiles p where p.id = auth.uid() and p.status = 'ativo' and p.role = 'especialista')
    or public.is_admin() or public.eh_super());
$$;
revoke all on function public.oport_pode_indicar() from public, anon;
grant execute on function public.oport_pode_indicar() to authenticated;

-- A base para o especialista escolher: clientes do funil do assessor com conta no BTG, com o perfil da base diária.
create or replace function public.oport_base(p_produto text default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
begin
  if not public.oport_pode_indicar() then raise exception 'Só especialista, administrador do CRM ou master.'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'lead_id', l.id, 'cliente', l.cliente, 'assessor', pr.nome, 'segmento', l.segmento, 'tipo_pessoa', l.tipo_pessoa,
             'pl_total', public.btg_numero(b.dados->>'pl_total'),
             'pl_previdencia', public.btg_numero(b.dados->>'pl_previdencia'),
             'pl_renda_fixa', public.btg_numero(b.dados->>'pl_renda_fixa'),
             'pl_fundos', public.btg_numero(b.dados->>'pl_fundos'),
             'pl_renda_variavel', public.btg_numero(b.dados->>'pl_renda_variavel'),
             'idade', case when coalesce(b.dados->>'dt_nascimento', '') ~ '^\d{2}/\d{2}/\d{4}$'
                           then extract(year from age(v_hoje, to_date(b.dados->>'dt_nascimento', 'DD/MM/YYYY')))::int end,
             'profissao', nullif(b.dados->>'profissao', ''), 'estado_civil', nullif(b.dados->>'estado_civil', ''),
             'perfil', nullif(b.dados->>'perfil_investidor', ''), 'cidade', nullif(b.dados->>'endereco_cidade', ''),
             'indicada', exists (select 1 from public.oportunidades_produto o
                                  where o.lead_id = l.id and o.status = 'aberta' and o.produto = coalesce(p_produto, o.produto)))
           order by public.btg_numero(b.dados->>'pl_total') desc nulls last)
      from public.leads l
      join public.btg_base b on ltrim(b.nr_conta, '0') = ltrim(regexp_replace(l.conta, '\D', '', 'g'), '0')
      left join public.profiles pr on pr.id = l.responsavel_id
     where not coalesce(l.excluido, false) and coalesce(l.funil, 'assessor') = 'assessor' and coalesce(l.conta, '') <> ''
       and not coalesce(l.perdido, false)), '[]'::jsonb);
end $$;
revoke all on function public.oport_base(text) from public, anon;
grant execute on function public.oport_base(text) to authenticated;

create or replace function public.oport_criar(p_leads text[], p_produto text, p_nota text)
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not public.oport_pode_indicar() then raise exception 'Só especialista, administrador do CRM ou master.'; end if;
  if coalesce(btrim(p_produto), '') = '' or length(p_produto) > 60 then raise exception 'Informe o produto.'; end if;
  if coalesce(array_length(p_leads, 1), 0) = 0 or array_length(p_leads, 1) > 300 then raise exception 'Escolha de 1 a 300 clientes.'; end if;
  insert into public.oportunidades_produto (lead_id, produto, nota, especialista_id, dono_id)
  select l.id, btrim(p_produto), left(nullif(btrim(p_nota), ''), 1000), auth.uid(), l.responsavel_id
    from public.leads l
   where l.id = any(p_leads) and not coalesce(l.excluido, false) and coalesce(l.funil, 'assessor') = 'assessor'
  on conflict (lead_id, produto) where status = 'aberta' do nothing;
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.oport_criar(text[], text, text) from public, anon;
grant execute on function public.oport_criar(text[], text, text) to authenticated;

-- O assessor da ficha (ou o administrador) responde; quem indicou pode cancelar.
create or replace function public.oport_resolver(p_id uuid, p_status text, p_resposta text)
returns boolean language plpgsql security definer set search_path = public as $$
declare o public.oportunidades_produto; v_dono uuid;
begin
  if not public.acesso_liberado() or not public.is_ativo() or not public.tem_permissao('ferramenta.crm') then
    raise exception 'Acesso não liberado.';
  end if;
  if p_status not in ('feita', 'sem_interesse', 'cancelada', 'aberta') then raise exception 'Situação inválida.'; end if;
  select * into o from public.oportunidades_produto where id = p_id;
  if o.id is null then raise exception 'Indicação não encontrada.'; end if;
  select responsavel_id into v_dono from public.leads where id = o.lead_id;
  if p_status = 'cancelada' then
    if o.especialista_id <> auth.uid() and not public.is_admin() and not public.eh_super() then
      raise exception 'Só quem indicou cancela.';
    end if;
  elsif v_dono is distinct from auth.uid() and o.especialista_id <> auth.uid() and not public.is_admin() and not public.eh_super() then
    raise exception 'Só o assessor do cliente responde.';
  end if;
  update public.oportunidades_produto
     set status = p_status, resposta = left(nullif(btrim(p_resposta), ''), 1000),
         resolvido_em = case when p_status = 'aberta' then null else now() end,
         resolvido_por = case when p_status = 'aberta' then null else auth.uid() end,
         dono_id = coalesce(v_dono, dono_id)
   where id = p_id;
  return true;
exception when unique_violation then
  raise exception 'Já existe outra indicação aberta deste produto para o cliente.';
end $$;
revoke all on function public.oport_resolver(uuid, text, text) from public, anon;
grant execute on function public.oport_resolver(uuid, text, text) to authenticated;
