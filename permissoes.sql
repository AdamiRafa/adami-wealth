-- ============================================================
--  8.13. PERFIS E ACESSOS (06/11/2026, Hub 2.94)
--     A tela Equipe > Perfis e acessos: para cada perfil, quais
--     ferramentas abre e quais atribuições tem. O master marca as
--     caixinhas; o banco obedece (não é só esconder botão).
--     Pode rodar de novo sem estragar nada: as escolhas já feitas
--     na tela ficam como estão.
--
--     Perfis de uma pessoa = a soma do que ela tem na Equipe:
--       portal: master, administrador, mesa_rv, financeiro (novo)
--       CRM:    admin_crm, assessor, especialista (só com status ativo)
--     O acesso dela é a soma do que os perfis dela liberam.
--
--     Começa igual ao que já valia antes desta versão, com uma
--     exceção nova: Comissões (ferramenta em construção), que nasce
--     só para master e financeiro.
-- ============================================================

-- ---------- 1. Perfil Financeiro ----------
alter table public.perfis   add column if not exists financeiro boolean not null default false;
alter table public.convites add column if not exists financeiro boolean not null default false;

-- ---------- 2. Catálogos e matriz ----------
create table if not exists public.perfis_catalogo (
  chave     text primary key,
  nome      text not null,
  descricao text not null default '',
  ordem     int  not null
);
insert into public.perfis_catalogo (chave, nome, descricao, ordem) values
  ('master',        'Master',        'Chave "Master" na Equipe',          1),
  ('administrador', 'Administrador', 'Chave "Admin" na Equipe',           2),
  ('mesa_rv',       'Mesa RV',       'Chave "Mesa RV" na Equipe',         3),
  ('financeiro',    'Financeiro',    'Chave "Financeiro" na Equipe',      4),
  ('admin_crm',     'Admin do CRM',  'Papel no CRM: Admin do CRM',        5),
  ('assessor',      'Assessor',      'Papel no CRM: Assessor',            6),
  ('especialista',  'Especialista',  'Papel no CRM: Especialista',        7)
on conflict (chave) do update set nome = excluded.nome, descricao = excluded.descricao, ordem = excluded.ordem;

create table if not exists public.permissoes_catalogo (
  chave     text primary key,
  tipo      text not null check (tipo in ('ferramenta','atribuicao')),
  nome      text not null,
  descricao text not null default '',
  ordem     int  not null,
  so_master boolean not null default false   -- só o master pode ter, e não sai dele
);
insert into public.permissoes_catalogo (chave, tipo, nome, descricao, ordem, so_master) values
  ('ferramenta.crm',         'ferramenta', 'CRM', 'Clientes, funil, agenda e KPIs. Sem ele, a pessoa também não grava "Salvar no CRM".', 10, false),
  ('ferramenta.processo',    'ferramenta', 'Processo Comercial', '', 11, false),
  ('ferramenta.carteiras',   'ferramenta', 'Carteiras', 'Relatórios mensais das carteiras.', 20, false),
  ('ferramenta.planos',      'ferramenta', 'Gerador de Planos Patrimoniais', '', 21, false),
  ('ferramenta.imobiliario', 'ferramenta', 'Relatório Imobiliário', '', 22, false),
  ('ferramenta.rv',          'ferramenta', 'Mesa RV', 'Abrir e ver a Mesa RV. Lançar operação é a atribuição "Operar a Mesa RV".', 23, false),
  ('ferramenta.diagnostico', 'ferramenta', 'Ferramenta Wealth Planning', '', 24, false),
  ('ferramenta.boletas',     'ferramenta', 'Controle de Boletas', '', 25, false),
  ('ferramenta.alocacao',    'ferramenta', 'Política de Alocação', 'Ver a política. Salvar é a atribuição "Editar a Política de Alocação".', 26, false),
  ('ferramenta.fluxo',       'ferramenta', 'Fluxo e Captação', 'Movimentações do BTG, captação e resgates da casa.', 27, false),
  ('ferramenta.comissoes',   'ferramenta', 'Comissões', 'Em construção.', 28, false),
  ('ferramenta.simrv',       'ferramenta', 'Simulador de Receita RV', '', 30, false),
  ('ferramenta.agio',        'ferramenta', 'Ágio e Troca de Ativos', '', 31, false),
  ('ferramenta.liberdade',   'ferramenta', 'Liberdade Financeira', '', 32, false),
  ('equipe.gerenciar',  'atribuicao', 'Gerenciar equipe, convites e permissões', 'Só o master. Fica sempre marcado, para ninguém se trancar fora.', 100, true),
  ('carteiras.todas',   'atribuicao', 'Ver todas as carteiras e preencher os relatórios', 'Sem ela, a pessoa vê só as carteiras dela. Inclui auditoria e backups.', 110, false),
  ('crm.todos',         'atribuicao', 'Ver todos os clientes do CRM e os KPIs da casa', 'Sem ela, a pessoa vê só os clientes dela. Inclui convites e configurações do CRM.', 120, false),
  ('rv.operar',         'atribuicao', 'Operar a Mesa RV', 'Lançar, editar e encerrar operações.', 130, false),
  ('alocacao.editar',   'atribuicao', 'Editar a Política de Alocação', 'Salvar o material do mês.', 140, false),
  ('avisos.publicar',   'atribuicao', 'Publicar avisos da casa', '', 150, false)
on conflict (chave) do update set tipo = excluded.tipo, nome = excluded.nome, descricao = excluded.descricao,
  ordem = excluded.ordem, so_master = excluded.so_master;

create table if not exists public.permissoes_perfil (
  perfil        text not null references public.perfis_catalogo(chave) on delete cascade,
  permissao     text not null references public.permissoes_catalogo(chave) on delete cascade,
  liberado      boolean not null,
  atualizado_em timestamptz not null default now(),
  atualizado_por text,
  primary key (perfil, permissao)
);
alter table public.perfis_catalogo     enable row level security;
alter table public.permissoes_catalogo enable row level security;
alter table public.permissoes_perfil   enable row level security;
-- Sem política de propósito: ninguém lê nem grava direto pela API. Tudo passa pelas
-- funções abaixo (minhas_permissoes, permissoes_matriz, permissoes_definir).
revoke all on public.perfis_catalogo, public.permissoes_catalogo, public.permissoes_perfil from anon, authenticated;

-- Valores iniciais = o que valia antes. "on conflict do nothing": rodar de novo não
-- desfaz o que o master marcou na tela.
insert into public.permissoes_perfil (perfil, permissao, liberado, atualizado_por)
select pf.chave, pm.chave,
  case
    when pm.chave = 'equipe.gerenciar' then pf.chave = 'master'
    when pm.chave = 'ferramenta.fluxo' then pf.chave = 'master'
    when pm.chave = 'ferramenta.comissoes' then pf.chave in ('master','financeiro')
    when pm.chave = 'carteiras.todas' then pf.chave in ('master','administrador')
    when pm.chave = 'crm.todos' then pf.chave in ('master','admin_crm')
    when pm.chave = 'rv.operar' then pf.chave in ('master','administrador','mesa_rv')
    when pm.chave = 'avisos.publicar' then pf.chave in ('master','administrador','admin_crm')
    when pm.chave = 'alocacao.editar' then pf.chave <> 'financeiro'
    when pm.tipo = 'ferramenta' then pf.chave <> 'financeiro'
    else false
  end, 'instalação'
from public.perfis_catalogo pf cross join public.permissoes_catalogo pm
on conflict (perfil, permissao) do nothing;

-- ---------- 3. Quem é o quê ----------
create or replace function public.perfis_de(p_user uuid)
returns text[] language sql stable security definer set search_path = public as $$
  select coalesce(array_remove(array[
           case when p.super      then 'master' end,
           case when p.admin      then 'administrador' end,
           case when p.mesa_rv    then 'mesa_rv' end,
           case when p.financeiro then 'financeiro' end,
           case when pr.status = 'ativo' and pr.role = 'admin'        then 'admin_crm' end,
           case when pr.status = 'ativo' and pr.role = 'vendedor'     then 'assessor' end,
           case when pr.status = 'ativo' and pr.role = 'especialista' then 'especialista' end
         ], null), '{}')
  from (select p_user as id) x
  left join public.perfis p    on p.user_id = x.id
  left join public.profiles pr on pr.id = x.id;
$$;
revoke all on function public.perfis_de(uuid) from public, anon, authenticated;

-- A pergunta que todas as regras fazem: "quem está logado pode isto?"
-- Exige a sessão liberada (código do dia), como o resto do banco.
create or replace function public.tem_permissao(p text)
returns boolean language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and public.acesso_liberado() and exists (
    select 1 from public.permissoes_perfil pp
     where pp.permissao = p and pp.liberado
       and pp.perfil = any (public.perfis_de(auth.uid()))
  );
$$;
revoke all on function public.tem_permissao(text) from public, anon;
grant execute on function public.tem_permissao(text) to authenticated;

-- O que a tela precisa saber da pessoa logada (menu do Hub e guarda dos módulos).
create or replace function public.minhas_permissoes()
returns jsonb language sql stable security definer set search_path = public as $$
  select case when auth.uid() is null or not public.acesso_liberado()
    then jsonb_build_object('perfis', '[]'::jsonb, 'permissoes', '[]'::jsonb)
    else jsonb_build_object(
      'perfis', to_jsonb(public.perfis_de(auth.uid())),
      'permissoes', coalesce((select jsonb_agg(distinct pp.permissao order by pp.permissao)
                                from public.permissoes_perfil pp
                               where pp.liberado and pp.perfil = any (public.perfis_de(auth.uid()))), '[]'::jsonb))
  end;
$$;
revoke all on function public.minhas_permissoes() from public, anon;
grant execute on function public.minhas_permissoes() to authenticated;

-- A tabela inteira, para a tela do master.
create or replace function public.permissoes_matriz()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.eh_super() then raise exception 'Apenas o master vê as permissões da equipe.'; end if;
  return jsonb_build_object(
    'perfis', (select jsonb_agg(jsonb_build_object('chave', chave, 'nome', nome, 'descricao', descricao) order by ordem)
                 from public.perfis_catalogo),
    'permissoes', (select jsonb_agg(jsonb_build_object('chave', chave, 'tipo', tipo, 'nome', nome, 'descricao', descricao,
                                                       'so_master', so_master) order by ordem)
                     from public.permissoes_catalogo),
    'matriz', (select coalesce(jsonb_agg(jsonb_build_object('perfil', perfil, 'permissao', permissao, 'liberado', liberado)), '[]'::jsonb)
                 from public.permissoes_perfil));
end $$;
revoke all on function public.permissoes_matriz() from public, anon;
grant execute on function public.permissoes_matriz() to authenticated;

create or replace function public.permissoes_definir(p_perfil text, p_permissao text, p_liberado boolean)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_so_master boolean; v_nome_perm text; v_nome_perfil text;
  v_quem text := coalesce(auth.jwt() ->> 'email', '?');
begin
  if not public.eh_super() then raise exception 'Apenas o master pode mudar as permissões.'; end if;
  select so_master, nome into v_so_master, v_nome_perm from public.permissoes_catalogo where chave = p_permissao;
  select nome into v_nome_perfil from public.perfis_catalogo where chave = p_perfil;
  if v_nome_perm is null or v_nome_perfil is null then raise exception 'Perfil ou permissão desconhecido.'; end if;
  if v_so_master then raise exception '"%" é só do master e não muda.', v_nome_perm; end if;
  if p_liberado is null then raise exception 'Marque ou desmarque.'; end if;

  insert into public.permissoes_perfil (perfil, permissao, liberado, atualizado_em, atualizado_por)
  values (p_perfil, p_permissao, p_liberado, now(), v_quem)
  on conflict (perfil, permissao) do update
    set liberado = excluded.liberado, atualizado_em = now(), atualizado_por = excluded.atualizado_por;

  insert into public.auditoria (usuario, acao, alvo, detalhe)
  values (v_quem, case when p_liberado then 'liberou permissão' else 'tirou permissão' end,
          v_nome_perfil, v_nome_perm);
end $$;
revoke all on function public.permissoes_definir(text, text, boolean) from public, anon;
grant execute on function public.permissoes_definir(text, text, boolean) to authenticated;

-- ---------- 4. As regras que já existiam passam a ler a matriz ----------
-- Mesmos nomes, então todas as políticas e funções que já usam estas quatro passam
-- a obedecer à tela sem precisar ser reescritas. eh_super() (master) não muda.
create or replace function public.eh_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select public.tem_permissao('carteiras.todas');
$$;
create or replace function public.pode_editar_rv()
returns boolean language sql stable security definer set search_path = public as $$
  select public.tem_permissao('rv.operar');
$$;
create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select public.tem_permissao('crm.todos');
$$;
create or replace function public.pode_publicar_aviso()
returns boolean language sql stable security definer set search_path = public as $$
  select public.tem_permissao('avisos.publicar');
$$;

-- Política de Alocação: salvar passa a exigir a atribuição.
create or replace function public.politica_alocacao_salvar(p_mes int, p_ano int, p_dados jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
  v_email text := auth.jwt() ->> 'email';
begin
  if not public.tem_permissao('alocacao.editar') then
    raise exception 'Seu perfil não pode salvar a Política de Alocação. Peça ao master.';
  end if;
  insert into public.politica_alocacao_snapshots (mes, ano, dados, salvo_por)
  values (p_mes, p_ano, p_dados, auth.uid())
  on conflict (mes, ano) do update set dados = excluded.dados, atualizado_em = now(), salvo_por = excluded.salvo_por
  returning id into v_id;
  insert into public.auditoria (usuario, acao, alvo, detalhe)
  values (v_email, 'salvou política de alocação', p_mes || '/' || p_ano, '');
  return v_id;
end $$;
revoke all on function public.politica_alocacao_salvar(int,int,jsonb) from public, anon;
grant execute on function public.politica_alocacao_salvar(int,int,jsonb) to authenticated;

-- Fluxo e Captação: era "só master"; passa a ser "quem tem a ferramenta".
drop policy if exists fluxo_snapshots_master on public.fluxo_snapshots;
create policy fluxo_snapshots_master on public.fluxo_snapshots for all to authenticated
  using ((select public.tem_permissao('ferramenta.fluxo'))) with check ((select public.tem_permissao('ferramenta.fluxo')));
drop policy if exists fluxo_lancamentos_master on public.fluxo_lancamentos;
create policy fluxo_lancamentos_master on public.fluxo_lancamentos for all to authenticated
  using ((select public.tem_permissao('ferramenta.fluxo'))) with check ((select public.tem_permissao('ferramenta.fluxo')));
drop policy if exists fluxo_distribuicao_master on public.fluxo_distribuicao;
create policy fluxo_distribuicao_master on public.fluxo_distribuicao for all to authenticated
  using ((select public.tem_permissao('ferramenta.fluxo'))) with check ((select public.tem_permissao('ferramenta.fluxo')));

-- As duas importações do Fluxo conferiam eh_super(). Troca só essa conferência, sem
-- reescrever o corpo inteiro (rodar de novo não muda mais nada).
do $$
declare f text; def text;
begin
  foreach f in array array['public.fluxo_substituir_distribuicao(int,int,text,jsonb)',
                           'public.fluxo_substituir_mes(int,int,text,jsonb)'] loop
    if to_regprocedure(f) is null then continue; end if;
    def := pg_get_functiondef(to_regprocedure(f));
    if position('public.eh_super()' in def) > 0 then
      def := replace(def, 'public.eh_super()', 'public.tem_permissao(''ferramenta.fluxo'')');
      def := replace(def, 'Só master pode importar dados de fluxo.', 'Seu perfil não tem acesso ao Fluxo e Captação.');
      execute def;
    end if;
  end loop;
end $$;

-- ---------- 5. Ferramenta desmarcada = dados da ferramenta fechados ----------
-- Políticas "restritivas": somam-se às que já existem (não abrem nada novo) e exigem
-- que a pessoa tenha a ferramenta. "(select ...)" faz o banco perguntar uma vez por
-- consulta, não uma vez por linha.
do $$
declare r record;
begin
  for r in select * from (values
      ('leads',                       '(select public.tem_permissao(''ferramenta.crm''))'),
      ('tarefas',                     '(select public.tem_permissao(''ferramenta.crm''))'),
      ('anexos',                      '(select public.tem_permissao(''ferramenta.crm''))'),
      ('lancamentos',                 '(select public.tem_permissao(''ferramenta.carteiras''))'),
      ('cartas',                      '(select public.tem_permissao(''ferramenta.carteiras''))'),
      ('clientes',                    '((select public.tem_permissao(''ferramenta.carteiras'')) or (select public.tem_permissao(''ferramenta.rv'')))'),
      ('rv_operacoes',                '(select public.tem_permissao(''ferramenta.rv''))'),
      ('rv_alocacoes',                '(select public.tem_permissao(''ferramenta.rv''))'),
      ('politica_alocacao_snapshots', '(select public.tem_permissao(''ferramenta.alocacao''))')
    ) as v(tabela, regra)
  loop
    if to_regclass('public.' || r.tabela) is null then continue; end if;
    execute format('drop policy if exists exige_ferramenta on public.%I', r.tabela);
    execute format('create policy exige_ferramenta on public.%I as restrictive for all to authenticated using (%s) with check (%s)',
                   r.tabela, r.regra, r.regra);
  end loop;
end $$;

-- Arquivos do cliente (Storage): a regra da ficha passa a exigir o CRM também.
create or replace function public.pode_ver_lead(p_id text)
returns boolean language sql security definer stable set search_path = public as $$
  select public.tem_permissao('ferramenta.crm') and exists (
    select 1 from public.leads l
    where l.id = p_id
      and ( public.is_admin()
            or (public.is_ativo() and l.responsavel_id = auth.uid())
            or (public.is_ativo() and l.origem_lead_id is not null and public.lead_meu(l.origem_lead_id))
            or (public.is_ativo() and public.lead_origem_minha(l.id)) )
  );
$$;
revoke all on function public.pode_ver_lead(text) from public, anon;
grant execute on function public.pode_ver_lead(text) to authenticated;

-- ---------- 6. Financeiro na Equipe e no convite ----------
create or replace function public.proteger_privilegios()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then
    return new;                      -- SQL Editor / service_role
  end if;
  if (new.admin      is distinct from old.admin)
  or (new.mesa_rv    is distinct from old.mesa_rv)
  or (new.super      is distinct from old.super)
  or (new.financeiro is distinct from old.financeiro)
  or (new.codigo     is distinct from old.codigo) then
    if not public.eh_super() then
      raise exception 'Apenas o master pode alterar privilégios e código de assessor.';
    end if;
  end if;
  if new.user_id is distinct from old.user_id then
    raise exception 'O vinculo do perfil com o usuario nao pode ser alterado.';
  end if;
  return new;
end $$;

create or replace function public.perfil_novo_sem_privilegio()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and not public.eh_super() then
    new.admin      := false;
    new.mesa_rv    := false;
    new.super      := false;
    new.financeiro := false;
  end if;
  return new;
end $$;

create or replace function public.criar_perfil()
returns trigger language plpgsql security definer set search_path = public as $$
declare cv public.convites%rowtype;
begin
  select * into cv from public.convites where email = lower(new.email);
  insert into public.perfis(user_id, nome, admin, mesa_rv, super, financeiro)
  values (new.id,
          coalesce(nullif(cv.nome,''),
                   nullif(new.raw_user_meta_data->>'nome',''),
                   split_part(new.email,'@',1)),
          coalesce(cv.admin,false),
          coalesce(cv.mesa_rv,false),
          coalesce(cv.master,false),
          coalesce(cv.financeiro,false))
  on conflict (user_id) do nothing;
  return new;
exception when others then
  return new;   -- nunca impedir a criação da conta por causa do perfil
end $$;
revoke all on function public.proteger_privilegios(), public.perfil_novo_sem_privilegio(), public.criar_perfil()
  from public, anon, authenticated;

create or replace function public.definir_privilegio(p_user_id uuid, p_campo text, p_valor boolean)
returns void language plpgsql security definer set search_path = public as $$
declare v_super boolean;
begin
  if not public.eh_super() then
    raise exception 'Apenas o master pode alterar privilégios.';
  end if;
  if p_campo not in ('admin','mesa_rv','financeiro') then
    raise exception 'Campo inválido: %.', p_campo;
  end if;
  select super into v_super from public.perfis where user_id = p_user_id;
  if v_super is null then raise exception 'Perfil não encontrado.'; end if;
  if v_super then raise exception 'O perfil master não pode ser alterado pela tela.'; end if;

  if p_campo = 'admin' then update public.perfis set admin = p_valor where user_id = p_user_id;
  elsif p_campo = 'mesa_rv' then update public.perfis set mesa_rv = p_valor where user_id = p_user_id;
  else update public.perfis set financeiro = p_valor where user_id = p_user_id;
  end if;

  insert into public.auditoria(usuario, acao, alvo, detalhe)
  values (coalesce(auth.jwt() ->> 'email','?'), 'privilegio',
          (select email from auth.users where id = p_user_id), p_campo || ' = ' || p_valor);
end $$;
revoke all on function public.definir_privilegio(uuid,text,boolean) from public, anon;
grant execute on function public.definir_privilegio(uuid,text,boolean) to authenticated;

-- Convite com Financeiro (parâmetro novo no fim, com padrão: a tela antiga continua funcionando).
drop function if exists public.convidar(text,text,text,boolean,boolean,boolean,text[]);
create or replace function public.convidar(
  p_email text, p_nome text, p_role text,
  p_master boolean default false, p_admin boolean default false,
  p_mesa_rv boolean default false, p_produtos text[] default '{}',
  p_financeiro boolean default false)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.eh_super() then
    raise exception 'Apenas o master pode convidar.';
  end if;
  if p_role not in ('admin','vendedor','especialista') then
    raise exception 'Papel invalido no CRM: %', p_role;
  end if;
  if position('@' in p_email) = 0 then
    raise exception 'E-mail invalido.';
  end if;
  if exists (select 1 from auth.users u where lower(u.email) = lower(p_email)) then
    raise exception 'Ja existe conta com este e-mail. Use a tela de Equipe para ajustar os acessos.';
  end if;

  insert into public.convites (email, nome, role, produtos, master, admin, mesa_rv, financeiro, convidado_por)
  values (lower(p_email), p_nome, p_role, coalesce(p_produtos,'{}'),
          p_master, p_admin, p_mesa_rv, coalesce(p_financeiro,false), auth.uid())
  on conflict (email) do update
    set nome=excluded.nome, role=excluded.role, produtos=excluded.produtos,
        master=excluded.master, admin=excluded.admin, mesa_rv=excluded.mesa_rv,
        financeiro=excluded.financeiro, convidado_por=excluded.convidado_por, criado_em=now(),
        -- 10/11/2026: convidar de novo reabre o convite. Antes ficava marcado como usado
        -- (pessoa que já teve conta e foi excluída): o e-mail era recusado e o cadastro também.
        -- Quem ainda tem conta não chega aqui (o "Ja existe conta" acima barra).
        consumido_em=null;

  insert into public.auditoria(usuario, acao, alvo, detalhe)
  values (coalesce(auth.jwt() ->> 'email','?'), 'convite', lower(p_email),
          'papel CRM '||p_role||case when p_master then ', master' else '' end
          ||case when coalesce(p_financeiro,false) then ', financeiro' else '' end);
end $$;
revoke all on function public.convidar(text,text,text,boolean,boolean,boolean,text[],boolean) from public, anon;
grant execute on function public.convidar(text,text,text,boolean,boolean,boolean,text[],boolean) to authenticated;

drop function if exists public.listar_convites();
create function public.listar_convites()
returns table (email text, nome text, role text, produtos text[],
               master boolean, admin boolean, mesa_rv boolean, criado_em timestamptz, financeiro boolean)
language sql stable security definer set search_path = public as $$
  select c.email, c.nome, c.role, c.produtos, c.master, c.admin, c.mesa_rv, c.criado_em, c.financeiro
  from public.convites c
  where public.eh_super() and c.consumido_em is null
  order by c.criado_em desc;
$$;
revoke all on function public.listar_convites() from public, anon;
grant execute on function public.listar_convites() to authenticated;

drop function if exists public.listar_equipe();
create function public.listar_equipe()
returns table (user_id uuid, email text, nome text, codigo text, admin boolean, mesa_rv boolean, super boolean,
               crm_role text, crm_status text, crm_produtos text[], criado_em timestamptz,
               revogado boolean, ultimo_acesso timestamptz, qtd_leads int, qtd_carteiras int,
               financeiro boolean, perfis text[])
language sql stable security definer set search_path = public as $$
  select p.user_id, u.email::text, p.nome, p.codigo, p.admin, p.mesa_rv, p.super,
         pr.role, pr.status, pr.produtos, u.created_at,
         coalesce(u.banned_until > now(), false), u.last_sign_in_at,
         (select count(*)::int from public.leads l where l.responsavel_id = p.user_id and not coalesce(l.excluido, false)),
         (select count(*)::int from public.clientes c where c.assessor_id = p.user_id),
         p.financeiro, public.perfis_de(p.user_id)
  from public.perfis p
  join auth.users u on u.id = p.user_id
  left join public.profiles pr on pr.id = p.user_id
  where public.eh_super()
  order by p.super desc, p.admin desc, p.mesa_rv desc, u.email;
$$;
revoke all on function public.listar_equipe() from public, anon;
grant execute on function public.listar_equipe() to authenticated;
