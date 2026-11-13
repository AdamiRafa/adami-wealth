-- ============================================================
--  ADAMI — banco completo, portal + CRM, num arquivo só
--
--  Substitui adami_banco, adami_acessos (supremo), crm_schema,
--  crm_acessos e adami_convites. Eles se sobrepunham: eh_admin era
--  definida duas vezes, criar_perfil e handle_new_user três, e a
--  tabela perfis nascia sem a coluna super para ganhá-la depois.
--  Aqui cada objeto aparece uma vez, na forma final.
--
--  Rodar inteiro no SQL Editor. Pode rodar de novo sem quebrar.
--  Se voce ja rodou uma versao anterior destes scripts, rode assim
--  mesmo: as funcoes que mudaram de formato sao derrubadas e
--  recriadas automaticamente no item 5.
--  Se aparecer "Potential issues detected", use Run without RLS.
--
--  ORDEM INTERNA (não reordene):
--    1. tabelas do portal        5. convites e primeiro acesso
--    2. tabelas do CRM           6. RLS do portal
--    3. funções de permissão     7. RLS do CRM
--    4. gatilhos de usuário      8. quem é quem
-- ============================================================


-- ============================================================
--  1. TABELAS DO PORTAL
-- ============================================================
create table if not exists public.perfis (
  user_id uuid primary key references auth.users(id) on delete cascade,
  nome    text,
  admin   boolean not null default false,
  mesa_rv boolean not null default false,
  super   boolean not null default false     -- "master" na interface
);
-- para bancos criados antes de o master existir
alter table public.perfis add column if not exists super boolean not null default false;

/* CÓDIGO DO ASSESSOR
   É por ele que a planilha de clientes diz de quem é cada conta. O nome não
   serve para isso: "RAFAEL", "Rafael Souza" e "R. SOUZA" são a mesma pessoa
   para quem lê e três strings diferentes para o computador — e um vínculo
   errado de carteira mexe em comissão.

   Nasce automático e sequencial (A001, A002…) para que ninguém fique sem,
   mas é editável pelo master na tela de Equipe: o valor útil é o que a
   planilha já usa, e esse quem conhece é quem monta a planilha. */
create sequence if not exists public.perfis_codigo_seq;
alter table public.perfis add column if not exists codigo text;

update public.perfis
   set codigo = 'A' || lpad(nextval('public.perfis_codigo_seq')::text, 3, '0')
 where codigo is null;

alter table public.perfis alter column codigo
  set default 'A' || lpad(nextval('public.perfis_codigo_seq')::text, 3, '0');

/* Único sem diferenciar maiúscula de minúscula, porque a comparação com a
   planilha também não diferencia: deixar 'a001' e 'A001' conviverem seria
   guardar a ambiguidade que este campo existe para eliminar. */
create unique index if not exists perfis_codigo_idx on public.perfis (upper(codigo));

-- ------------------------------------------------------------
--  1. Clientes
-- ------------------------------------------------------------
create table if not exists public.clientes (
  id          uuid primary key default gen_random_uuid(),
  nome        text not null,
  assessor_id uuid default auth.uid() references auth.users(id) on delete set null,
  criado_em   timestamptz not null default now()
);
create index if not exists clientes_assessor_idx on public.clientes(assessor_id);

-- ------------------------------------------------------------
--  2. Lançamentos mensais
--     A unicidade por (cliente, mês, ano) é OBRIGATÓRIA: o portal
--     grava com ?on_conflict=cliente_id,mes,ano. Sem ela a gravação
--     falha em silêncio.
-- ------------------------------------------------------------
create table if not exists public.lancamentos (
  id            uuid primary key default gen_random_uuid(),
  cliente_id    uuid not null references public.clientes(id) on delete cascade,
  mes           smallint not null check (mes between 1 and 12),
  ano           smallint not null check (ano between 2000 and 2100),
  contas        jsonb not null default '[]'::jsonb,
  indicadores   jsonb not null default '{}'::jsonb,
  atualizado_em timestamptz not null default now(),
  constraint lancamentos_unico unique (cliente_id, mes, ano)
);
create index if not exists lancamentos_periodo_idx on public.lancamentos(ano, mes);

-- ------------------------------------------------------------
--  3. Comentários do mês (compartilhados por toda a casa)
--     Unicidade por (mês, ano): o portal usa ?on_conflict=mes,ano
-- ------------------------------------------------------------
create table if not exists public.cartas (
  id            bigint generated always as identity primary key,
  mes           smallint not null check (mes between 1 and 12),
  ano           smallint not null check (ano between 2000 and 2100),
  conteudo      text,
  atualizado_em timestamptz not null default now(),
  constraint cartas_unico unique (mes, ano)
);

-- ------------------------------------------------------------
--  4. Auditoria
-- ------------------------------------------------------------
create table if not exists public.auditoria (
  id      bigint generated always as identity primary key,
  quando  timestamptz not null default now(),
  usuario text,
  acao    text,
  alvo    text,
  detalhe text
);
create index if not exists auditoria_quando_idx on public.auditoria(quando desc);

-- ------------------------------------------------------------
--  5. Backups (dump completo — exclusivo do admin)
-- ------------------------------------------------------------
create table if not exists public.backups (
  id       bigint generated always as identity primary key,
  quando   timestamptz not null default now(),
  usuario  text,
  conteudo jsonb not null
);
create index if not exists backups_quando_idx on public.backups(quando desc);

-- ------------------------------------------------------------
--  6. Mesa RV
-- ------------------------------------------------------------
create table if not exists public.rv_operacoes (
  id            uuid primary key default gen_random_uuid(),
  tipo          text not null,
  ativo         text not null,
  empresa       text,
  params        jsonb not null default '{}'::jsonb,
  resumo        text,
  status        text not null default 'aberta' check (status in ('aberta','encerrada')),
  desfecho      text check (desfecho in ('alvo','stop','manual')),
  resultado_pct numeric,
  criado_por    uuid references auth.users(id) on delete set null,
  criado_em     timestamptz not null default now(),
  encerrado_em  timestamptz,
  atualizado_em timestamptz not null default now()
);
create index if not exists rv_operacoes_status_idx on public.rv_operacoes(status);
create index if not exists rv_operacoes_criado_idx on public.rv_operacoes(criado_em desc);

create table if not exists public.rv_alocacoes (
  id           uuid primary key default gen_random_uuid(),
  operacao_id  uuid not null references public.rv_operacoes(id) on delete cascade,
  cliente_id   uuid references public.clientes(id) on delete set null,
  cliente_nome text not null,
  valor        numeric not null check (valor > 0),
  lancado_por  uuid references auth.users(id) on delete set null,
  em           timestamptz not null default now()
);
create index if not exists rv_alocacoes_op_idx on public.rv_alocacoes(operacao_id);

create or replace function public.rv_touch()
returns trigger language plpgsql as $$
begin new.atualizado_em = now(); return new; end $$;
drop trigger if exists rv_operacoes_touch on public.rv_operacoes;
create trigger rv_operacoes_touch before update on public.rv_operacoes
  for each row execute function public.rv_touch();

-- ============================================================
--  2. TABELAS DO CRM
-- ============================================================

create table if not exists public.profiles (
  id                   uuid primary key references auth.users(id) on delete cascade,
  nome                 text not null,
  role                 text not null default 'vendedor'
                         check (role in ('admin','vendedor','especialista')),
  status               text not null default 'pendente'
                         check (status in ('pendente','ativo','removido')),
  -- Produtos só fazem sentido para especialista; é o que decide quem
  -- aparece como destino no encaminhamento da R4.
  produtos             text[] not null default '{}',
  -- Dupla habitual do assessor por produto: {"Consórcio":"<uuid>"}.
  -- jsonb porque é um mapa lido junto com o perfil, nunca consultado.
  especialistas_padrao jsonb  not null default '{}'::jsonb,
  criado_em            timestamptz not null default now()
);

create table if not exists public.leads (
  id               text primary key,
  cliente          text not null default '',
  oportunidade     text default '',
  telefone         text default '',
  email            text default '',
  observacoes      text default '',
  responsavel_id   uuid references public.profiles(id) on delete set null,

  -- Etapa não tem check: os estágios válidos dependem do funil e mudam
  -- com o processo comercial. A regra de trajeto vive em allowedMoves,
  -- no app, onde ela pode evoluir sem migração.
  etapa            text not null default 'Cliente Novo',
  etapa_desde      timestamptz not null default now(),
  funil            text not null default 'assessor'
                     check (funil in ('assessor','especialista')),
  esteira          text not null default 'novo'
                     check (esteira in ('novo','base')),
  segmento         text not null default 'Advisory'
                     check (segmento in ('Advisory','Exclusive','Private')),
  produto          text check (produto in ('Consórcio','Seguro')),
  origem_lead_id   text references public.leads(id) on delete set null,

  -- Dinheiro em numeric, não em texto. Em texto o parseValor devolvia 0
  -- para entrada inválida, então patrimônio digitado errado entrava como
  -- zero e sumia dos indicadores sem avisar; e a ordenação por valor era
  -- alfabética ('900000' > '1500000'). Aqui o banco recusa lixo e permite
  -- somar do lado do servidor quando a carteira crescer.
  valor_potencial  numeric(15,2),
  valor_fechado    numeric(15,2),
  -- Pipe total (valor_potencial) é o tamanho do negócio; este é a fatia que
  -- está sendo negociada agora, um número mais volátil que muda a cada
  -- conversa. Só existe para prospect (esteira 'novo'); cliente da base tem
  -- o equivalente em valor_em_captacao, com o próprio fluxo de captação.
  valor_em_negociacao numeric(15,2),
  -- Patrimônio sob gestão no exterior, em DÓLAR. O mesmo cliente pode ter as
  -- duas custódias; são dois saldos de um relacionamento só, não dois
  -- clientes. Não é convertido na gravação de propósito: converter na entrada
  -- apagaria o valor original e o número envelheceria sem que ninguém soubesse
  -- por qual cotação passou. A conversão acontece na leitura, pela cotação em
  -- configuracoes.usd_brl.
  valor_offshore   numeric(14,2),

  ultimo_contato   date,
  proximo_contato  date,
  produto_servico  text default '',

  perdido          boolean not null default false,
  motivo_perda     text default '',
  perdido_em       timestamptz,
  ganho            boolean not null default false,
  ganho_em         timestamptz,
  excluido         boolean not null default false,
  excluido_em      timestamptz,

  -- Ficha do cliente
  tipo_pessoa      text not null default 'PF' check (tipo_pessoa in ('PF','PJ')),
  contato_nome     text,
  contato_cargo    text,
  nascimento       date,
  grupo_familiar   text,
  -- Temperatura é leitura de engajamento, não de etapa: um cliente pode estar
  -- na R2 e frio. Fica nula enquanto ninguém classificou — um default daria a
  -- toda a base carregada uma leitura que ninguém fez.
  temperatura      text check (temperatura is null or temperatura in ('quente','morno','frio')),
  estado_civil     text,
  profissao        text,
  banco_atual      text,
  origem           text,
  -- Número da conta no BTG. Só existe em cliente que veio da carga da base;
  -- quem é cadastrado pelo app não tem conta, e por isso o índice único é
  -- parcial (ver importacao-base-btg.sql). É a chave de reconciliação: sem
  -- ela, uma reimportação não sabe distinguir atualização de duplicata.
  conta            text,
  -- A conta offshore do mesmo cliente (migração 17). Não é chave: o export
  -- offshore do BTG liga pela conta onshore, que está ao lado dela no arquivo.
  conta_offshore   text,
  -- Cliente da base: saldo sob gestão antes das movimentações (migração 18).
  -- Separado de valor_potencial, que é o patrimônio do formulário — eram o
  -- mesmo campo, e corrigir o patrimônio mexia na carteira.
  saldo_inicial    numeric(14,2),
  -- Cliente da base: captação nova em negociação (migração 19). Entra em
  -- "Em captação" com o potencial dos prospects; o aporte abate daqui.
  valor_em_captacao numeric(14,2),
  -- Custódia e moeda do valor acima (migração 21): onshore = BRL, offshore = USD.
  captacao_custodia text check (captacao_custodia is null or captacao_custodia in ('onshore','offshore')),
  -- Saldo offshore sob gestão, em USD (migração 20). valor_offshore é só o
  -- patrimônio offshore declarado; o que vale para a carteira é o captado.
  saldo_inicial_offshore numeric(14,2),
  -- Patrimônio e renda declarados no briefing de seguro são texto livre
  -- ("2 imóveis + previdência"), nunca somados. Ficam como texto de
  -- propósito, ao contrário das colunas de valor acima.
  patrimonio       text,
  renda            text,

  historico        jsonb not null default '[]'::jsonb,
  atividades       jsonb not null default '[]'::jsonb,
  alertas          jsonb not null default '[]'::jsonb,
  movimentacoes    jsonb not null default '[]'::jsonb,
  briefing         jsonb not null default '{}'::jsonb,
  pautas           jsonb not null default '{}'::jsonb,

  criado_em        timestamptz not null default now(),
  atualizado_em    timestamptz not null default now(),

  -- Ganho e perdido são desfechos opostos; o app já os trata como
  -- exclusivos e o banco passa a garantir isso.
  constraint leads_desfecho_exclusivo check (not (ganho and perdido))
);

-- Banco já existente não ganha coluna nova só por causa do "if not exists"
-- do create table acima — ele só age em instalação nova. Esta linha é o que
-- de fato adiciona a coluna em quem já tem a tabela.
alter table public.leads add column if not exists valor_em_negociacao numeric(15,2);

create index if not exists leads_responsavel_idx on public.leads (responsavel_id);
create index if not exists leads_etapa_idx       on public.leads (etapa);
create index if not exists leads_funil_idx       on public.leads (funil);
-- As políticas de encaminhamento buscam por origem_lead_id a cada linha
-- lida; sem índice isso vira varredura da tabela inteira.
create index if not exists leads_origem_idx      on public.leads (origem_lead_id)
  where origem_lead_id is not null;
create index if not exists leads_ativos_idx      on public.leads (excluido) where excluido = false;
create index if not exists leads_grupo_idx       on public.leads (grupo_familiar)
  where grupo_familiar is not null;
-- Parcial: a pergunta é "quem tem carteira lá fora", nunca "quem não tem".
create index if not exists leads_offshore_idx    on public.leads (valor_offshore)
  where valor_offshore is not null;
-- Parcial: a pergunta é sempre "quem está quente", nunca "quem está sem
-- classificação" na base inteira.
create index if not exists leads_temperatura_idx on public.leads (temperatura)
  where temperatura is not null;
-- Único e parcial: duas linhas não podem representar a mesma conta do BTG, mas
-- os clientes cadastrados na mão ficam todos com conta nula e não colidem.
create unique index if not exists leads_conta_uk  on public.leads (conta)
  where conta is not null;
create unique index if not exists leads_conta_offshore_uk on public.leads (conta_offshore)
  where conta_offshore is not null;


-- Convite: uma pessoa, um convite, com os papéis dos DOIS sistemas.
-- Sem as colunas do portal, o master cadastraria a mesma pessoa duas
-- vezes, em telas diferentes.
create table if not exists public.convites (
  email         text primary key check (email = lower(email)),
  nome          text not null,
  role          text not null default 'vendedor'
                  check (role in ('admin','vendedor','especialista')),
  produtos      text[] not null default '{}',
  master        boolean not null default false,
  admin         boolean not null default false,
  mesa_rv       boolean not null default false,
  criado_por    uuid references public.profiles(id) on delete set null,
  convidado_por uuid references auth.users(id) on delete set null,
  consumido_em  timestamptz,
  criado_em     timestamptz not null default now()
);
-- para bancos que já tinham convites na forma antiga
alter table public.convites
  add column if not exists master        boolean not null default false,
  add column if not exists admin         boolean not null default false,
  add column if not exists mesa_rv       boolean not null default false,
  add column if not exists convidado_por uuid references auth.users(id) on delete set null,
  add column if not exists consumido_em  timestamptz;

create table if not exists public.configuracoes (
  chave          text primary key,
  valor          text not null,
  atualizado_em  timestamptz not null default now(),
  atualizado_por uuid references public.profiles(id) on delete set null
);

create or replace function public.configuracoes_carimba()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.atualizado_por := auth.uid();
  new.atualizado_em  := now();
  return new;
end $$;

drop trigger if exists configuracoes_carimba_trg on public.configuracoes;
create trigger configuracoes_carimba_trg
  before insert or update on public.configuracoes
  for each row execute function public.configuracoes_carimba();


-- ============================================================
--  3. FUNÇÕES DE PERMISSÃO
--     security definer para a política poder consultar a tabela
--     sem cair em recursão de RLS.
-- ============================================================

create or replace function public.eh_super()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select p.super from public.perfis p where p.user_id = auth.uid()), false);
$$;

-- super manda em tudo que o admin manda
create or replace function public.eh_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select p.admin or p.super from public.perfis p where p.user_id = auth.uid()), false);
$$;

-- e também na Mesa RV
create or replace function public.pode_editar_rv()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select p.mesa_rv or p.admin or p.super
                   from public.perfis p where p.user_id = auth.uid()), false);
$$;

revoke all on function public.eh_super(), public.eh_admin(), public.pode_editar_rv() from public;
grant execute on function public.eh_super(), public.eh_admin(), public.pode_editar_rv() to authenticated;

create or replace function public.meu_cliente(cid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists(
    select 1 from public.clientes c
    where c.id = cid and (c.assessor_id = auth.uid() or public.eh_admin()));
$$;
revoke all on function public.meu_cliente(uuid) from public;
grant execute on function public.meu_cliente(uuid) to authenticated;

create or replace function public.is_ativo()
returns boolean language sql security definer stable set search_path = public as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and status = 'ativo'
  );
$$;

create or replace function public.is_admin()
returns boolean language sql security definer stable set search_path = public as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and role = 'admin' and status = 'ativo'
  );
$$;

-- Este negócio é meu?
create or replace function public.lead_meu(p_id text)
returns boolean language sql security definer stable set search_path = public as $$
  select exists (
    select 1 from public.leads
    where id = p_id and responsavel_id = auth.uid()
  );
$$;

-- Alguma indicação minha nasceu deste negócio?
create or replace function public.lead_origem_minha(p_id text)
returns boolean language sql security definer stable set search_path = public as $$
  select exists (
    select 1 from public.leads
    where origem_lead_id = p_id and responsavel_id = auth.uid()
  );
$$;

-- ============================================================
--  4. GATILHOS DE CRIAÇÃO DE USUÁRIO
--     Três gatilhos rodam no mesmo INSERT em auth.users:
--     um recusa quem não foi convidado, e os outros dois criam o
--     perfil do portal e o do CRM. Nenhum depende da ordem dos
--     outros — o convite é MARCADO como consumido, não apagado.
-- ============================================================

create or replace function public.exige_convite()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.convites c
                  where c.email = lower(new.email) and c.consumido_em is null) then
    raise exception 'Cadastro permitido apenas para e-mails convidados pela Adami.';
  end if;
  return new;
end $$;

drop trigger if exists exige_convite_trg on auth.users;
create trigger exige_convite_trg before insert on auth.users
  for each row execute function public.exige_convite();

create or replace function public.criar_perfil()
returns trigger language plpgsql security definer set search_path = public as $$
declare cv public.convites%rowtype;
begin
  select * into cv from public.convites where email = lower(new.email);
  insert into public.perfis(user_id, nome, admin, mesa_rv, super)
  values (new.id,
          coalesce(nullif(cv.nome,''),
                   nullif(new.raw_user_meta_data->>'nome',''),
                   split_part(new.email,'@',1)),
          coalesce(cv.admin,false),
          coalesce(cv.mesa_rv,false),
          coalesce(cv.master,false))
  on conflict (user_id) do nothing;
  return new;
exception when others then
  return new;   -- nunca impedir a criação da conta por causa do perfil
end $$;

drop trigger if exists ao_criar_usuario on auth.users;
create trigger ao_criar_usuario after insert on auth.users
  for each row execute function public.criar_perfil();

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  primeiro boolean;
  convite  public.convites%rowtype;
begin
  select count(*) = 0 into primeiro from public.profiles;
  select * into convite from public.convites
   where email = lower(new.email) and consumido_em is null;

  if convite.email is not null then
    insert into public.profiles (id, nome, role, status, produtos)
    values (new.id, convite.nome, convite.role, 'ativo', convite.produtos)
    on conflict (id) do nothing;
    update public.convites set consumido_em = now() where email = convite.email;
  else
    insert into public.profiles (id, nome, role, status)
    values (new.id,
            coalesce(nullif(new.raw_user_meta_data->>'nome',''), split_part(new.email,'@',1)),
            case when primeiro then 'admin' else 'vendedor' end,
            case when primeiro then 'ativo' else 'pendente' end)
    on conflict (id) do nothing;
  end if;
  return new;
exception when others then
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

create or replace function public.protege_responsavel()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.responsavel_id is distinct from old.responsavel_id
     and not public.is_admin() then
    raise exception 'Somente um administrador pode transferir a responsabilidade de um negócio.';
  end if;
  return new;
end;
$$;

drop trigger if exists leads_protege_responsavel on public.leads;
create trigger leads_protege_responsavel
  before update on public.leads
  for each row execute function public.protege_responsavel();


-- ============================================================
--  5. PROTEÇÃO DE PRIVILÉGIOS E FUNÇÕES DA TELA DE EQUIPE
-- ============================================================

create or replace function public.proteger_privilegios()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then
    return new;                      -- SQL Editor / service_role
  end if;

  if (new.admin   is distinct from old.admin)
  or (new.mesa_rv is distinct from old.mesa_rv)
  or (new.super   is distinct from old.super) then
    if not public.eh_super() then
      raise exception
        'Apenas o administrador supremo pode alterar privilegios (admin, mesa_rv, super).';
    end if;
  end if;

  if new.user_id is distinct from old.user_id then
    raise exception 'O vinculo do perfil com o usuario nao pode ser alterado.';
  end if;

  return new;
end $$;

drop trigger if exists perfis_proteger on public.perfis;
create trigger perfis_proteger before update on public.perfis
  for each row execute function public.proteger_privilegios();

-- Perfil novo nunca nasce com privilégio, aconteça o que acontecer
create or replace function public.perfil_novo_sem_privilegio()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and not public.eh_super() then
    new.admin   := false;
    new.mesa_rv := false;
    new.super   := false;
  end if;
  return new;
end $$;

drop trigger if exists perfis_nascimento on public.perfis;
create trigger perfis_nascimento before insert on public.perfis
  for each row execute function public.perfil_novo_sem_privilegio();

-- ------------------------------------------------------------
--  3. Segunda barreira: permissão no nível da coluna
--     Pela API, o autenticado só consegue escrever em "nome".
--     Um PATCH em admin/mesa_rv/super é recusado pelo Postgres
--     antes mesmo de chegar na política.
--     O portal apenas LÊ perfis, então isso não quebra nada.
-- ------------------------------------------------------------
revoke update on public.perfis from authenticated;
grant  update (nome) on public.perfis to authenticated;

/* As funcoes abaixo mudaram de formato desde a primeira versao (a
   listar_equipe, por exemplo, ganhou as colunas do CRM). O comando
   create or replace nao consegue alterar o tipo de retorno de uma
   funcao que ja existe: sem derrubar antes, o Postgres recusa com
   "cannot change return type of existing function".

   Derrubamos TODAS as versoes de cada nome, inclusive assinaturas
   antigas com outros parametros -- se sobrasse uma, a chamada pela
   API ficaria ambigua. Nenhuma delas e usada por politica ou gatilho,
   entao derrubar nao arrasta mais nada junto. Sem cascade de proposito:
   se um dia alguma passar a ter dependente, queremos o erro na cara. */
do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure::text as assinatura
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('convidar','revogar_convite','listar_convites',
                        'listar_equipe','definir_papel_crm','definir_privilegio',
                        'definir_codigo','codigos_assessores')
  loop
    execute 'drop function if exists ' || r.assinatura;
  end loop;
end $$;

create or replace function public.convidar(
  p_email text, p_nome text, p_role text,
  p_master boolean default false, p_admin boolean default false,
  p_mesa_rv boolean default false, p_produtos text[] default '{}')
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

  insert into public.convites (email, nome, role, produtos, master, admin, mesa_rv, convidado_por)
  values (lower(p_email), p_nome, p_role, coalesce(p_produtos,'{}'),
          p_master, p_admin, p_mesa_rv, auth.uid())
  on conflict (email) do update
    set nome=excluded.nome, role=excluded.role, produtos=excluded.produtos,
        master=excluded.master, admin=excluded.admin, mesa_rv=excluded.mesa_rv,
        convidado_por=excluded.convidado_por, criado_em=now();

  insert into public.auditoria(usuario, acao, alvo, detalhe)
  values (coalesce(auth.jwt() ->> 'email','?'), 'convite', lower(p_email),
          'papel CRM '||p_role||coalesce(', master',''));
end $$;

create or replace function public.revogar_convite(p_email text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.eh_super() then
    raise exception 'Apenas o master pode revogar convite.';
  end if;
  delete from public.convites where email = lower(p_email);
end $$;

create or replace function public.listar_convites()
returns table (email text, nome text, role text, produtos text[],
               master boolean, admin boolean, mesa_rv boolean, criado_em timestamptz)
language sql stable security definer set search_path = public as $$
  select c.email, c.nome, c.role, c.produtos, c.master, c.admin, c.mesa_rv, c.criado_em
  from public.convites c
  where public.eh_super() and c.consumido_em is null
  order by c.criado_em desc;
$$;

create or replace function public.listar_equipe()
returns table (
  user_id uuid, email text, nome text, codigo text,
  admin boolean, mesa_rv boolean, super boolean,
  crm_role text, crm_status text, crm_produtos text[], criado_em timestamptz)
language sql stable security definer set search_path = public as $$
  select p.user_id, u.email::text, p.nome, p.codigo, p.admin, p.mesa_rv, p.super,
         pr.role, pr.status, pr.produtos, u.created_at
  from public.perfis p
  join auth.users u on u.id = p.user_id
  left join public.profiles pr on pr.id = p.user_id
  where public.eh_admin()
  order by p.super desc, p.admin desc, p.mesa_rv desc, u.email;
$$;

/* Quem pode alterar o código: só o master, e por aqui — a escrita direta em
   perfis está limitada à coluna "nome" (item 3 acima), de propósito. */
create or replace function public.definir_codigo(p_user_id uuid, p_codigo text)
returns void language plpgsql security definer set search_path = public as $$
declare v_novo text;
begin
  if not public.eh_super() then
    raise exception 'Apenas o master pode alterar o codigo do assessor.';
  end if;

  v_novo := upper(btrim(coalesce(p_codigo, '')));
  if v_novo = '' then
    raise exception 'O codigo nao pode ficar em branco: e ele que liga a planilha ao assessor.';
  end if;
  if v_novo !~ '^[A-Z0-9._-]{2,16}$' then
    raise exception 'Codigo invalido: use de 2 a 16 letras, numeros, ponto, hifen ou sublinhado.';
  end if;
  if exists (select 1 from public.perfis
              where upper(codigo) = v_novo and user_id <> p_user_id) then
    raise exception 'Ja existe outro assessor com o codigo %.', v_novo;
  end if;

  update public.perfis set codigo = v_novo where user_id = p_user_id;
  if not found then
    raise exception 'Perfil nao encontrado.';
  end if;

  insert into public.auditoria(usuario, acao, alvo, detalhe)
  values (coalesce(auth.jwt() ->> 'email','?'), 'codigo',
          (select email from auth.users where id = p_user_id), v_novo);
end $$;

/* O CRM precisa traduzir código em pessoa na hora de ler a planilha, e ele
   não enxerga perfis (tabela do portal). Só o par id/código sai daqui: nem
   e-mail, nem privilégio — é o mínimo para fazer o vínculo. */
create or replace function public.codigos_assessores()
returns table (user_id uuid, codigo text)
language sql stable security definer set search_path = public as $$
  select p.user_id, p.codigo from public.perfis p where p.codigo is not null;
$$;

/* Papel no CRM, alterado pela tela de Equipe. A escrita direta em
   profiles continua restrita: passa por aqui, que confere quem pede. */
create or replace function public.definir_papel_crm(
  p_user_id uuid, p_role text, p_status text default null, p_produtos text[] default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.eh_super() then
    raise exception 'Apenas o master pode alterar papeis no CRM.';
  end if;
  if p_role not in ('admin','vendedor','especialista') then
    raise exception 'Papel invalido: %', p_role;
  end if;
  if p_status is not null and p_status not in ('pendente','ativo','removido') then
    raise exception 'Status invalido: %', p_status;
  end if;

  insert into public.profiles (id, nome, role, status, produtos)
  select p_user_id,
         coalesce((select nome from public.perfis where user_id = p_user_id), 'Sem nome'),
         p_role, coalesce(p_status,'ativo'), coalesce(p_produtos,'{}')
  on conflict (id) do update
    set role = excluded.role,
        status = coalesce(p_status, public.profiles.status),
        produtos = coalesce(p_produtos, public.profiles.produtos);

  insert into public.auditoria(usuario, acao, alvo, detalhe)
  values (coalesce(auth.jwt() ->> 'email','?'), 'papel-crm',
          (select email from auth.users where id = p_user_id),
          p_role||coalesce(' / '||p_status,''));
end $$;

revoke all on function public.convidar(text,text,text,boolean,boolean,boolean,text[]),
                      public.revogar_convite(text), public.listar_convites(),
                      public.definir_papel_crm(uuid,text,text,text[]) from public;
grant execute on function public.convidar(text,text,text,boolean,boolean,boolean,text[]),
                          public.revogar_convite(text), public.listar_convites(),
                          public.definir_papel_crm(uuid,text,text,text[]) to authenticated;

create or replace function public.definir_privilegio(
  p_user_id uuid, p_campo text, p_valor boolean)
returns void
language plpgsql security definer set search_path = public as $$
declare v_super boolean;
begin
  if not public.eh_super() then
    raise exception 'Apenas o administrador supremo pode alterar privilegios.';
  end if;
  if p_campo not in ('admin','mesa_rv') then
    raise exception 'Campo invalido: %. Use admin ou mesa_rv.', p_campo;
  end if;

  select super into v_super from public.perfis where user_id = p_user_id;
  if v_super is null then
    raise exception 'Perfil nao encontrado.';
  end if;
  if v_super then
    raise exception 'O perfil supremo nao pode ser alterado pela tela.';
  end if;

  if p_campo = 'admin' then
    update public.perfis set admin = p_valor where user_id = p_user_id;
  else
    update public.perfis set mesa_rv = p_valor where user_id = p_user_id;
  end if;

  insert into public.auditoria(usuario, acao, alvo, detalhe)
  values (coalesce(auth.jwt() ->> 'email','?'), 'privilegio',
          (select email from auth.users where id = p_user_id),
          p_campo || ' = ' || p_valor);
end $$;


revoke all on function public.definir_codigo(uuid,text), public.codigos_assessores() from public;
grant execute on function public.definir_codigo(uuid,text) to authenticated;
grant execute on function public.codigos_assessores() to authenticated;

revoke all on function public.listar_equipe(), public.definir_privilegio(uuid,text,boolean),
                      public.definir_papel_crm(uuid,text,text,text[]),
                      public.convidar(text,text,text,boolean,boolean,boolean,text[]),
                      public.revogar_convite(text), public.listar_convites() from public;
grant execute on function public.listar_equipe(), public.definir_privilegio(uuid,text,boolean),
                          public.definir_papel_crm(uuid,text,text,text[]),
                          public.convidar(text,text,text,boolean,boolean,boolean,text[]),
                          public.revogar_convite(text), public.listar_convites() to authenticated;

-- ============================================================
--  6. SEGURANÇA EM NÍVEL DE LINHA — PORTAL
-- ============================================================

alter table public.perfis       enable row level security;
alter table public.clientes     enable row level security;
alter table public.lancamentos  enable row level security;
alter table public.cartas       enable row level security;
alter table public.auditoria    enable row level security;
alter table public.backups      enable row level security;
alter table public.rv_operacoes enable row level security;
alter table public.rv_alocacoes enable row level security;

-- ------------------------------------------------------------
--  4. Políticas de perfis, reescritas
-- ------------------------------------------------------------
drop policy if exists perfis_ler     on public.perfis;
drop policy if exists perfis_alterar on public.perfis;
drop policy if exists perfis_apagar  on public.perfis;

create policy perfis_ler on public.perfis for select to authenticated
  using (user_id = auth.uid() or public.eh_admin());

create policy perfis_alterar on public.perfis for update to authenticated
  using (user_id = auth.uid() or public.eh_admin())
  with check (user_id = auth.uid() or public.eh_admin());

-- apagar perfil: só o supremo
create policy perfis_apagar on public.perfis for delete to authenticated
  using (public.eh_super());

-- ------------------------------------------------------------
-- clientes: cada assessor vê os seus; admin vê todos; a mesa RV lê todos
drop policy if exists clientes_ler on public.clientes;
drop policy if exists clientes_inserir on public.clientes;
drop policy if exists clientes_alterar on public.clientes;
drop policy if exists clientes_apagar on public.clientes;
create policy clientes_ler on public.clientes for select to authenticated
  using (assessor_id = auth.uid() or public.eh_admin() or public.pode_editar_rv());
create policy clientes_inserir on public.clientes for insert to authenticated
  with check (assessor_id = auth.uid() or public.eh_admin());
create policy clientes_alterar on public.clientes for update to authenticated
  using (assessor_id = auth.uid() or public.eh_admin())
  with check (assessor_id = auth.uid() or public.eh_admin());
create policy clientes_apagar on public.clientes for delete to authenticated
  using (assessor_id = auth.uid() or public.eh_admin());

-- lancamentos: leitura segue o dono do cliente, escrita é só do admin.
-- O preenchimento do relatório (Carteiras) virou tarefa do admin; sem isso
-- aqui, esconder a aba "Preencher" na tela não impede nada — o assessor
-- ainda gravaria chamando a API direto.
drop policy if exists lanc_ler on public.lancamentos;
drop policy if exists lanc_inserir on public.lancamentos;
drop policy if exists lanc_alterar on public.lancamentos;
drop policy if exists lanc_apagar on public.lancamentos;
create policy lanc_ler on public.lancamentos for select to authenticated
  using (public.meu_cliente(cliente_id));
create policy lanc_inserir on public.lancamentos for insert to authenticated
  with check (public.eh_admin());
create policy lanc_alterar on public.lancamentos for update to authenticated
  using (public.eh_admin()) with check (public.eh_admin());
create policy lanc_apagar on public.lancamentos for delete to authenticated
  using (public.eh_admin());

-- cartas: comentário é da casa, liberado a todos os autenticados
drop policy if exists cartas_tudo on public.cartas;
create policy cartas_tudo on public.cartas for all to authenticated
  using (true) with check (true);

-- auditoria: cada um vê o próprio rastro; admin vê tudo; só admin limpa
drop policy if exists aud_ler on public.auditoria;
drop policy if exists aud_inserir on public.auditoria;
drop policy if exists aud_apagar on public.auditoria;
create policy aud_ler on public.auditoria for select to authenticated
  using (public.eh_admin() or usuario = (auth.jwt() ->> 'email'));
create policy aud_inserir on public.auditoria for insert to authenticated
  with check (true);
create policy aud_apagar on public.auditoria for delete to authenticated
  using (public.eh_admin());

drop policy if exists backups_admin on public.backups;
create policy backups_admin on public.backups for all to authenticated
  using (public.eh_admin()) with check (public.eh_admin());

-- Mesa RV: todos leem, só a mesa escreve
drop policy if exists rv_op_ler on public.rv_operacoes;
drop policy if exists rv_op_escrever on public.rv_operacoes;
create policy rv_op_ler on public.rv_operacoes for select to authenticated using (true);
create policy rv_op_escrever on public.rv_operacoes for all to authenticated
  using (public.pode_editar_rv()) with check (public.pode_editar_rv());

drop policy if exists rv_al_ler on public.rv_alocacoes;
drop policy if exists rv_al_escrever on public.rv_alocacoes;
create policy rv_al_ler on public.rv_alocacoes for select to authenticated using (true);
create policy rv_al_escrever on public.rv_alocacoes for all to authenticated
  using (public.pode_editar_rv()) with check (public.pode_editar_rv());

-- ------------------------------------------------------------
--  8. Permissões de tabela para a API
-- ------------------------------------------------------------
grant usage on schema public to anon, authenticated;
grant select, insert, update, delete on
  public.perfis, public.clientes, public.lancamentos, public.cartas,
  public.auditoria, public.backups, public.rv_operacoes, public.rv_alocacoes
  to authenticated;


-- ============================================================
--  7. SEGURANÇA EM NÍVEL DE LINHA — CRM
-- ============================================================

alter table public.profiles enable row level security;
alter table public.leads    enable row level security;
alter table public.convites enable row level security;

-- Perfis ---------------------------------------------------------
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles
  for select to authenticated
  -- Quem está ativo vê a equipe (precisa disso para exibir responsáveis).
  -- Quem está pendente enxerga só o próprio registro, para saber que aguarda.
  using ( id = auth.uid() or public.is_ativo() );

-- O USING só garante que a linha é a própria. Sem prender as colunas
-- sensíveis no WITH CHECK, uma conta pendente rodaria
--   update profiles set status='ativo' where id = auth.uid()
-- e entraria sem passar por nenhum admin — a aprovação viraria
-- decorativa. Mesmo raciocínio para produtos: um especialista se
-- atribuiria produtos e passaria a receber indicação que não é dele.
-- Nome e preferências seguem editáveis pelo próprio dono.
drop policy if exists profiles_update_self on public.profiles;
create policy profiles_update_self on public.profiles
  for update to authenticated
  using ( id = auth.uid() )
  with check (
    id = auth.uid()
    and role     = (select role     from public.profiles where id = auth.uid())
    and status   = (select status   from public.profiles where id = auth.uid())
    and produtos = (select produtos from public.profiles where id = auth.uid())
  );

drop policy if exists profiles_update_admin on public.profiles;
create policy profiles_update_admin on public.profiles
  for update to authenticated
  using ( public.is_admin() ) with check ( public.is_admin() );

-- Negócios -------------------------------------------------------
-- A indicação da R4 tem dois lados: o assessor cria o card e o
-- especialista o executa. O vínculo é sempre origem_lead_id, nunca uma
-- permissão ampla — cada lado alcança só o negócio ligado ao seu.
drop policy if exists leads_select on public.leads;
create policy leads_select on public.leads
  for select to authenticated
  using (
    public.is_admin()
    or (public.is_ativo() and responsavel_id = auth.uid())
    -- assessor lê a indicação gerada a partir de um cliente da carteira dele:
    -- sem isto semIndicacao ficaria pendente para sempre e jornadaConcluida
    -- nunca dispararia
    or (public.is_ativo() and origem_lead_id is not null and public.lead_meu(origem_lead_id))
    -- especialista lê o cliente de origem da indicação que recebeu
    or (public.is_ativo() and public.lead_origem_minha(id))
  );

drop policy if exists leads_insert on public.leads;
create policy leads_insert on public.leads
  for insert to authenticated
  with check (
    public.is_admin()
    or (public.is_ativo() and responsavel_id = auth.uid())
    -- o assessor cria a indicação em nome do especialista, mas só a partir
    -- de um cliente que já é dele: origem_lead_id é a credencial do ato
    or (
      public.is_ativo()
      and funil = 'especialista'
      and origem_lead_id is not null
      and public.lead_meu(origem_lead_id)
    )
  );

-- Escrita é mais estreita que leitura: o assessor lê a indicação para
-- saber em que pé ela está, mas quem a trabalha é o especialista. Na
-- volta, o especialista escreve no cliente de origem apenas porque a
-- conclusão automática da jornada precisa gravar a etapa lá.
drop policy if exists leads_update on public.leads;
create policy leads_update on public.leads
  for update to authenticated
  using (
    public.is_admin()
    or (public.is_ativo() and responsavel_id = auth.uid())
    or (public.is_ativo() and public.lead_origem_minha(id))
  )
  with check (
    public.is_admin()
    or (public.is_ativo() and responsavel_id = auth.uid())
    or (public.is_ativo() and public.lead_origem_minha(id))
  );

-- Exclusão é lógica (coluna excluido). Nenhuma política de DELETE,
-- então nada some do banco de verdade pelo aplicativo.

-- Convites -------------------------------------------------------
drop policy if exists convites_admin on public.convites;
create policy convites_admin on public.convites
  for all to authenticated
  using ( public.is_admin() ) with check ( public.is_admin() );


-- Convites: só o master convida e enxerga a fila.
alter table public.convites enable row level security;
drop policy if exists convites_admin on public.convites;
drop policy if exists convites_master_ler on public.convites;
drop policy if exists convites_master_escrever on public.convites;
create policy convites_master_ler on public.convites for select
  to authenticated using (public.eh_super());
create policy convites_master_escrever on public.convites for all
  to authenticated using (public.eh_super()) with check (public.eh_super());

-- Todo mundo lê: sem a cotação nenhuma tela consolida a carteira.
drop policy if exists configuracoes_leitura on public.configuracoes;
create policy configuracoes_leitura on public.configuracoes
  for select to authenticated
  using ( true );

-- Só o admin escreve: a cotação move o total da carteira do escritório
-- inteiro, não é decisão de quem cuida de uma carteira só.
drop policy if exists configuracoes_admin on public.configuracoes;
create policy configuracoes_admin on public.configuracoes
  for all to authenticated
  using ( public.is_admin() ) with check ( public.is_admin() );

-- Quem gravou é carimbado pelo banco, não pelo app: o cliente poderia mandar
-- qualquer uuid nesse campo.

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'leads'
  ) then
    alter publication supabase_realtime add table public.leads;
  end if;
end $$;


grant usage on schema public to anon, authenticated;
grant select, insert, update, delete on
  public.profiles, public.leads, public.convites, public.configuracoes
  to authenticated;

-- ============================================================
--  8. QUEM É QUEM
--     Perfis para quem já existia antes destas tabelas, e os papéis
--     de partida. Troque os nomes antes do @ se estiverem diferentes.
-- ============================================================

insert into public.profiles (id, nome, role, status)
select u.id,
       coalesce(nullif(u.raw_user_meta_data->>'nome',''), split_part(u.email,'@',1)),
       'vendedor',
       'pendente'
from auth.users u
where not exists (select 1 from public.profiles p where p.id = u.id);

-- Perfil do portal para quem já existia antes da tabela perfis
insert into public.perfis (user_id, nome)
select u.id, coalesce(nullif(u.raw_user_meta_data->>'nome',''), split_part(u.email,'@',1))
from auth.users u
where not exists (select 1 from public.perfis p where p.user_id = u.id);

-- Master do portal
update public.perfis p set super = true, admin = true
from auth.users u
where u.id = p.user_id
  and lower(split_part(u.email,'@',1)) in ('emil.stade','bibiana','rafael');

-- Admin do CRM para os mesmos
update public.profiles pr set role = 'admin', status = 'ativo'
from auth.users u
where u.id = pr.id
  and lower(split_part(u.email,'@',1)) in ('emil.stade','bibiana','rafael');

-- Mesa RV
update public.perfis p set mesa_rv = true
from auth.users u
where u.id = p.user_id and lower(split_part(u.email,'@',1)) = 'thiago.miranda';
update public.profiles pr set status = 'ativo'
from auth.users u
where u.id = pr.id and lower(split_part(u.email,'@',1)) = 'thiago.miranda';

-- ============================================================
--  8.5. BI DE FLUXO/ALOCAÇÃO — snapshots mensais das movimentações do BTG
--     Acesso restrito a master (eh_super()): dado de captação da casa
--     inteira, não só da carteira de um assessor. Usado por fluxo.html.
-- ============================================================

-- Snapshots: um por mês/ano, controla o que foi importado
create table if not exists public.fluxo_snapshots (
  id            uuid primary key default gen_random_uuid(),
  mes           smallint not null check (mes between 1 and 12),
  ano           smallint not null check (ano between 2020 and 2100),
  fontes        jsonb not null default '{}'::jsonb,
  -- fontes = {"movimentacao_geral": {"importado_em": "...", "linhas": 7812},
  --           "movimentacao_fundos": null, "ordens": {...}, "oferta_dashboard": {...}, "oferta_book": {...}}
  -- null/ausente = fonte não veio nesse mês -- a tela mostra "não informado", nunca zero.
  importado_por uuid references auth.users(id) on delete set null,
  importado_em  timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  unique (mes, ano)
);

-- Lançamentos normalizados -- Movimentação geral/Fundos/RF/RV (seções 1 a 10 do dicionário)
create table if not exists public.fluxo_lancamentos (
  id               uuid primary key default gen_random_uuid(),
  snapshot_id      uuid not null references public.fluxo_snapshots(id) on delete cascade,
  mes              smallint not null,
  ano              smallint not null,
  fonte            text not null check (fonte in ('movimentacao_geral','movimentacao_fundos','movimentacao_rf','movimentacao_rv')),
  conta            text not null,       -- normalizada: 9 dígitos, zero-fill
  nome_titular     text,
  mercado          text,
  sub_mercado      text,
  produto          text,
  lancamento       text,
  emissor          text,
  ativo            text,
  tipo_previdencia text,
  indexador        text,
  taxa_emissao     text,
  taxa_compra      text,
  data_lancamento  date,                -- "Data Compra" do export -- é a data de referência pro mês, não o vencimento
  vencimento       date,
  quantidade       numeric,
  valor_bruto      numeric,
  ir               numeric,
  iof              numeric,
  valor_liquido    numeric,
  data_cotizacao   date,
  data_liquidacao  date,
  cnpj_fundo       text,                -- só vem na planilha de Fundos (enriquecimento)
  administrador    text,
  gestor           text,
  movimentacao     text,                -- texto cru da coluna "Movimentação" -- sem ele não reclassifica fluxo externo/canal de fundos ao recarregar o mês
  id_origem        text not null,       -- "ID" da linha no export BTG -- chave de deduplicação
  criado_em        timestamptz not null default now()
);
alter table public.fluxo_lancamentos add column if not exists movimentacao text;
create index if not exists fluxo_lanc_snapshot_idx on public.fluxo_lancamentos(snapshot_id);
create index if not exists fluxo_lanc_mes_ano_idx on public.fluxo_lancamentos(ano, mes);
create index if not exists fluxo_lanc_conta_idx on public.fluxo_lancamentos(conta);
create index if not exists fluxo_lanc_mercado_idx on public.fluxo_lancamentos(mercado, sub_mercado, lancamento);
create unique index if not exists fluxo_lanc_origem_uniq on public.fluxo_lancamentos(fonte, id_origem) where id_origem is not null and id_origem <> '';

-- Distribuição: ordens de fundos no secundário + ofertas públicas (seções 11 e 12 -- fatia 5, schema já pronto)
create table if not exists public.fluxo_distribuicao (
  id               uuid primary key default gen_random_uuid(),
  snapshot_id      uuid not null references public.fluxo_snapshots(id) on delete cascade,
  mes              smallint not null,
  ano              smallint not null,
  fonte            text not null check (fonte in ('ordens_secundario','oferta_dashboard','oferta_book')),
  conta            text not null,
  nome_titular     text,
  assessor         text,
  nome_oferta      text,
  ativo            text,
  status           text,
  motivo_status    text,
  data_solicitacao date,
  data_liquidacao  date,
  valor_desejado   numeric,
  valor_obtido     numeric,
  preco_unitario   numeric,
  spread           numeric,
  quantidade       numeric,
  modalidade       text,
  tipo_operacao    text,                -- só ordens_secundario: COMPRA/VENDA
  ordem_direta     boolean,             -- só ordens_secundario: campo "Ordem direta" do export
  id_origem        text,
  criado_em        timestamptz not null default now()
);
alter table public.fluxo_distribuicao add column if not exists tipo_operacao text;
alter table public.fluxo_distribuicao add column if not exists ordem_direta boolean;
create index if not exists fluxo_dist_snapshot_idx on public.fluxo_distribuicao(snapshot_id);
create index if not exists fluxo_dist_mes_ano_idx on public.fluxo_distribuicao(ano, mes);
create index if not exists fluxo_dist_fonte_idx on public.fluxo_distribuicao(fonte);

-- Mesmo substituir-por-mês da Movimentação geral, só que pra ordens/ofertas
-- (fluxo_distribuicao) -- um arquivo desses cobre vários meses de histórico,
-- então a tela chama essa função uma vez por mês encontrado no arquivo.
create or replace function public.fluxo_substituir_distribuicao(
  p_mes int, p_ano int, p_fonte text, p_registros jsonb
)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_snapshot_id uuid;
  v_qtd_antes int;
  v_qtd_depois int;
  v_email text := auth.jwt() ->> 'email';
begin
  if not public.eh_super() then
    raise exception 'Só master pode importar dados de fluxo.';
  end if;

  insert into public.fluxo_snapshots (mes, ano, importado_por)
  values (p_mes, p_ano, auth.uid())
  on conflict (mes, ano) do update set atualizado_em = now()
  returning id into v_snapshot_id;

  select count(*) into v_qtd_antes from public.fluxo_distribuicao
    where snapshot_id = v_snapshot_id and fonte = p_fonte;

  delete from public.fluxo_distribuicao where snapshot_id = v_snapshot_id and fonte = p_fonte;

  insert into public.fluxo_distribuicao (
    snapshot_id, mes, ano, fonte, conta, nome_titular, assessor, nome_oferta, ativo, status,
    motivo_status, data_solicitacao, data_liquidacao, valor_desejado, valor_obtido, preco_unitario,
    spread, quantidade, modalidade, tipo_operacao, ordem_direta, id_origem
  )
  select
    v_snapshot_id, p_mes, p_ano, p_fonte,
    x->>'conta', x->>'nome_titular', x->>'assessor', x->>'nome_oferta', x->>'ativo', x->>'status',
    x->>'motivo_status', nullif(x->>'data_solicitacao','')::date, nullif(x->>'data_liquidacao','')::date,
    nullif(x->>'valor_desejado','')::numeric, nullif(x->>'valor_obtido','')::numeric, nullif(x->>'preco_unitario','')::numeric,
    nullif(x->>'spread','')::numeric, nullif(x->>'quantidade','')::numeric, x->>'modalidade', x->>'tipo_operacao',
    nullif(x->>'ordem_direta','')::boolean, x->>'id_origem'
  from jsonb_array_elements(p_registros) as x;

  get diagnostics v_qtd_depois = row_count;

  update public.fluxo_snapshots set
    fontes = jsonb_set(fontes, array[p_fonte], jsonb_build_object(
      'importado_em', now(), 'linhas', v_qtd_depois
    )),
    atualizado_em = now()
  where id = v_snapshot_id;

  insert into public.auditoria (usuario, acao, alvo, detalhe)
  values (v_email, 'importou fluxo', p_fonte||' '||p_mes||'/'||p_ano,
    'linhas antes: '||v_qtd_antes||' -> depois: '||v_qtd_depois);

  return v_snapshot_id;
end;
$$;
revoke all on function public.fluxo_substituir_distribuicao(int,int,text,jsonb) from public;
grant execute on function public.fluxo_substituir_distribuicao(int,int,text,jsonb) to authenticated;

-- Parâmetros editáveis -- reaproveita a tabela configuracoes (curva de Selic, régua de câmbio,
-- limites de alerta, de-paras). Nada novo aqui: configuracoes(chave text pk, valor text) já existe.
-- Chaves usadas por este módulo: fluxo_curva_selic, fluxo_ipca_projetado, fluxo_regua_cambio,
-- fluxo_limite_alerta_mov, fluxo_limite_caixa, fluxo_fgc_vermelho, fluxo_fgc_amarelo,
-- fluxo_depara_conglomerado, fluxo_depara_assessor.

-- Substituir um mês inteiro, de forma atômica, com auditoria
create or replace function public.fluxo_substituir_mes(
  p_mes int, p_ano int, p_fonte text, p_lancamentos jsonb
)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_snapshot_id uuid;
  v_qtd_antes int;
  v_qtd_depois int;
  v_email text := auth.jwt() ->> 'email';
begin
  if not public.eh_super() then
    raise exception 'Só master pode importar dados de fluxo.';
  end if;

  insert into public.fluxo_snapshots (mes, ano, importado_por)
  values (p_mes, p_ano, auth.uid())
  on conflict (mes, ano) do update set atualizado_em = now()
  returning id into v_snapshot_id;

  select count(*) into v_qtd_antes from public.fluxo_lancamentos
    where snapshot_id = v_snapshot_id and fonte = p_fonte;

  delete from public.fluxo_lancamentos where snapshot_id = v_snapshot_id and fonte = p_fonte;

  insert into public.fluxo_lancamentos (
    snapshot_id, mes, ano, fonte, conta, nome_titular, mercado, sub_mercado, produto,
    lancamento, emissor, ativo, tipo_previdencia, indexador, taxa_emissao, taxa_compra,
    data_lancamento, vencimento, quantidade, valor_bruto, ir, iof, valor_liquido,
    data_cotizacao, data_liquidacao, cnpj_fundo, administrador, gestor, movimentacao, id_origem
  )
  select
    v_snapshot_id, p_mes, p_ano, p_fonte,
    x->>'conta', x->>'nome_titular', x->>'mercado', x->>'sub_mercado', x->>'produto',
    x->>'lancamento', x->>'emissor', x->>'ativo', x->>'tipo_previdencia', x->>'indexador',
    x->>'taxa_emissao', x->>'taxa_compra',
    nullif(x->>'data_lancamento','')::date, nullif(x->>'vencimento','')::date,
    nullif(x->>'quantidade','')::numeric, nullif(x->>'valor_bruto','')::numeric,
    nullif(x->>'ir','')::numeric, nullif(x->>'iof','')::numeric, nullif(x->>'valor_liquido','')::numeric,
    nullif(x->>'data_cotizacao','')::date, nullif(x->>'data_liquidacao','')::date,
    x->>'cnpj_fundo', x->>'administrador', x->>'gestor', x->>'movimentacao', x->>'id_origem'
  from jsonb_array_elements(p_lancamentos) as x;

  get diagnostics v_qtd_depois = row_count;

  update public.fluxo_snapshots set
    fontes = jsonb_set(fontes, array[p_fonte], jsonb_build_object(
      'importado_em', now(), 'linhas', v_qtd_depois
    )),
    atualizado_em = now()
  where id = v_snapshot_id;

  insert into public.auditoria (usuario, acao, alvo, detalhe)
  values (v_email, 'importou fluxo', p_fonte||' '||p_mes||'/'||p_ano,
    'linhas antes: '||v_qtd_antes||' -> depois: '||v_qtd_depois);

  return v_snapshot_id;
end;
$$;
revoke all on function public.fluxo_substituir_mes(int,int,text,jsonb) from public;
grant execute on function public.fluxo_substituir_mes(int,int,text,jsonb) to authenticated;

-- RLS -- só master lê e escreve
alter table public.fluxo_snapshots enable row level security;
alter table public.fluxo_lancamentos enable row level security;
alter table public.fluxo_distribuicao enable row level security;

drop policy if exists fluxo_snapshots_master on public.fluxo_snapshots;
create policy fluxo_snapshots_master on public.fluxo_snapshots for all to authenticated
  using (public.eh_super()) with check (public.eh_super());

drop policy if exists fluxo_lancamentos_master on public.fluxo_lancamentos;
create policy fluxo_lancamentos_master on public.fluxo_lancamentos for all to authenticated
  using (public.eh_super()) with check (public.eh_super());

drop policy if exists fluxo_distribuicao_master on public.fluxo_distribuicao;
create policy fluxo_distribuicao_master on public.fluxo_distribuicao for all to authenticated
  using (public.eh_super()) with check (public.eh_super());

-- ============================================================
--  8.6. POLÍTICA DE ALOCAÇÃO — histórico mensal
--     Antes só ficava no localStorage do navegador: sem backup, sem
--     histórico, e "Novo mês" apagava os números do mês anterior pra
--     sempre (só os textos de política/diretrizes sobreviviam). Agora
--     cada mês vira uma linha, com RPC pra salvar e dropdown pra navegar
--     entre os meses já salvos -- usado por alocacao.html.
--     Aberto a qualquer usuário logado, igual já era no localStorage:
--     não é dado sensível de cliente, é o material do comitê mensal.
-- ============================================================
create table if not exists public.politica_alocacao_snapshots (
  id            uuid primary key default gen_random_uuid(),
  mes           smallint not null check (mes between 1 and 12),
  ano           smallint not null check (ano between 2020 and 2100),
  dados         jsonb not null,       -- o objeto EST inteiro do alocacao.html
  salvo_por     uuid references auth.users(id) on delete set null,
  criado_em     timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  unique (mes, ano)
);
create index if not exists politica_aloc_mes_ano_idx on public.politica_alocacao_snapshots(ano, mes);

create or replace function public.politica_alocacao_salvar(p_mes int, p_ano int, p_dados jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
  v_email text := auth.jwt() ->> 'email';
begin
  insert into public.politica_alocacao_snapshots (mes, ano, dados, salvo_por)
  values (p_mes, p_ano, p_dados, auth.uid())
  on conflict (mes, ano) do update set dados = excluded.dados, atualizado_em = now()
  returning id into v_id;

  insert into public.auditoria (usuario, acao, alvo, detalhe)
  values (v_email, 'salvou política de alocação', p_mes||'/'||p_ano, '');

  return v_id;
end;
$$;
revoke all on function public.politica_alocacao_salvar(int,int,jsonb) from public;
grant execute on function public.politica_alocacao_salvar(int,int,jsonb) to authenticated;

alter table public.politica_alocacao_snapshots enable row level security;
drop policy if exists politica_aloc_leitura on public.politica_alocacao_snapshots;
create policy politica_aloc_leitura on public.politica_alocacao_snapshots for select to authenticated using (true);
-- escrita só pela RPC acima (security definer) -- sem policy de insert/update/delete.

-- ============================================================
--  8.7. AGENDA DO CRM (05/11/2026)
--     Rodar inteiro no SQL Editor do Supabase. Pode rodar de novo
--     sem estragar nada: tudo aqui é "se não existir" ou "troca".
--
--     tarefas         as tarefas criadas na mão (a aba Agenda do CRM).
--                     Próximo contato, vencimento e régua NÃO moram
--                     aqui: o CRM calcula a partir da ficha do cliente,
--                     para os dois nunca discordarem.
--     agenda_emails   um registro por pessoa por dia do e-mail da
--                     manhã. É o que impede o mesmo e-mail de sair duas
--                     vezes no dia.
--     pedidos_senha   cada pedido de "Esqueci minha senha", para a
--                     função enviar-senha limitar a frequência.
--
--     As duas últimas não têm política nenhuma de propósito: só as
--     funções do Supabase (com a chave de serviço) leem e escrevem.
-- ============================================================

create table if not exists public.tarefas (
  id            uuid primary key default gen_random_uuid(),
  titulo        text not null check (char_length(btrim(titulo)) between 1 and 200),
  tipo          text not null default 'tarefa'
                  check (tipo in ('ligacao','reuniao','email','tarefa')),
  -- Cliente ligado à tarefa (opcional). Concluir uma tarefa ligada a
  -- cliente registra a atividade na ficha dele, pelo próprio CRM.
  lead_id       text references public.leads(id) on delete set null,
  -- De quem é a tarefa. Assessor só cria para si; head comercial
  -- (admin do CRM) e master podem criar para qualquer pessoa.
  dono_id       uuid not null references public.profiles(id) on delete cascade,
  -- Quem criou. Preenchido pelo gatilho abaixo, nunca pelo navegador.
  criado_por    uuid default auth.uid() references public.profiles(id) on delete set null,
  data          date not null,
  hora          time,
  -- nao | dia_util (seg a sex) | semana (dias_semana) | mes (mesmo dia
  -- do mês de "data"). A repetição começa em "data".
  repeticao     text not null default 'nao'
                  check (repeticao in ('nao','dia_util','semana','mes')),
  -- 1 = segunda ... 7 = domingo. Só vale para repeticao = 'semana'.
  dias_semana   smallint[] not null default '{}'
                  check (dias_semana <@ array[1,2,3,4,5,6,7]::smallint[]),
  -- Dias já concluídos. Tarefa que não repete tem no máximo um; a que
  -- repete guarda um por ocorrência feita.
  concluidas    date[] not null default '{}',
  email_manha   boolean not null default true,
  nota          text not null default '' check (char_length(nota) <= 2000),
  criado_em     timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);
create index if not exists tarefas_dono_idx on public.tarefas (dono_id);
create index if not exists tarefas_lead_idx on public.tarefas (lead_id) where lead_id is not null;

-- Quem criou não é informado pelo navegador: é a sessão. E a tarefa
-- atribuída pelo head comercial não pode ser reescrita por quem a
-- recebeu: ele só marca como feita (e liga ou desliga o e-mail).
create or replace function public.tarefas_carimbo()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    if auth.uid() is not null then new.criado_por := auth.uid(); end if;
    new.criado_em := now();
  else
    new.criado_por := old.criado_por;
    new.criado_em := old.criado_em;
    if auth.uid() is not null
       and old.criado_por is distinct from auth.uid()
       and not (public.is_admin() or public.eh_super())
       and (new.titulo, new.tipo, new.lead_id, new.dono_id, new.data, new.hora,
            new.repeticao, new.dias_semana, new.nota)
           is distinct from
           (old.titulo, old.tipo, old.lead_id, old.dono_id, old.data, old.hora,
            old.repeticao, old.dias_semana, old.nota)
    then
      raise exception 'Esta tarefa foi atribuída a você. Só quem atribuiu pode mudar o texto, o dia ou a repetição.';
    end if;
  end if;
  new.atualizado_em := now();
  return new;
end;
$$;
drop trigger if exists tarefas_carimbo on public.tarefas;
create trigger tarefas_carimbo before insert or update on public.tarefas
  for each row execute function public.tarefas_carimbo();

alter table public.tarefas enable row level security;

drop policy if exists tarefas_ler on public.tarefas;
create policy tarefas_ler on public.tarefas for select to authenticated
  using ( public.is_ativo() and (
    dono_id = auth.uid() or criado_por = auth.uid()
    or public.is_admin() or public.eh_super() ) );

drop policy if exists tarefas_criar on public.tarefas;
create policy tarefas_criar on public.tarefas for insert to authenticated
  with check ( public.is_ativo() and (
    dono_id = auth.uid() or public.is_admin() or public.eh_super() ) );

drop policy if exists tarefas_alterar on public.tarefas;
create policy tarefas_alterar on public.tarefas for update to authenticated
  using ( public.is_ativo() and (
    dono_id = auth.uid() or criado_por = auth.uid()
    or public.is_admin() or public.eh_super() ) )
  with check ( public.is_ativo() and (
    dono_id = auth.uid() or public.is_admin() or public.eh_super() ) );

drop policy if exists tarefas_apagar on public.tarefas;
create policy tarefas_apagar on public.tarefas for delete to authenticated
  using ( public.is_ativo() and (
    criado_por = auth.uid() or public.is_admin() or public.eh_super() ) );

grant select, insert, update, delete on public.tarefas to authenticated;

-- E-mail da manhã: um por pessoa por dia.
create table if not exists public.agenda_emails (
  user_id    uuid not null references auth.users(id) on delete cascade,
  dia        date not null,
  enviado_em timestamptz not null default now(),
  resultado  text,
  primary key (user_id, dia)
);
alter table public.agenda_emails enable row level security;
revoke all on public.agenda_emails from anon, authenticated;

-- Pedidos de "Esqueci minha senha".
create table if not exists public.pedidos_senha (
  id        bigint generated always as identity primary key,
  email     text not null,
  pedido_em timestamptz not null default now(),
  resultado text
);
create index if not exists pedidos_senha_email_idx on public.pedidos_senha (email, pedido_em desc);
alter table public.pedidos_senha enable row level security;
revoke all on public.pedidos_senha from anon, authenticated;

-- Agendamento do e-mail da manhã: dias úteis, 9h50 em UTC = 6h50 em
-- Brasília. Chama a função agenda-manha, que só envia uma vez por dia
-- para cada pessoa e só entre 6h e 11h de Brasília.
create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron with schema pg_catalog;
select cron.schedule(
  'agenda-manha',
  '50 9 * * 1-5',
  $cron$
  select net.http_post(
    url := 'https://ghxjqmjtmbqzvogwzylo.supabase.co/functions/v1/agenda-manha',
    headers := '{"Content-Type":"application/json"}'::jsonb,
    body := '{}'::jsonb,
    timeout_milliseconds := 60000
  );
  $cron$
);


-- ============================================================
--  8.8. AVISOS DA CASA (05/11/2026)
--     Recados para a equipe na tela inicial do Hub, com quantos já
--     leram. Rodar inteiro no SQL Editor do Supabase. Pode rodar de
--     novo sem estragar nada.
--
--     Quem publica: administrador ou master do portal (eh_admin) e o
--     head comercial (admin do CRM, is_admin). Todo mundo lê.
--     "publicar_em" no futuro = aviso agendado: só quem publica vê
--     até chegar a hora.
-- ============================================================

create table if not exists public.avisos (
  id          uuid primary key default gen_random_uuid(),
  titulo      text not null check (char_length(btrim(titulo)) between 1 and 120),
  texto       text not null default '' check (char_length(texto) <= 2000),
  publicar_em timestamptz not null default now(),
  fixado      boolean not null default false,
  criado_por  uuid default auth.uid() references auth.users(id) on delete set null,
  criado_em   timestamptz not null default now()
);
create index if not exists avisos_publicar_idx on public.avisos (publicar_em desc);

create table if not exists public.avisos_leitura (
  aviso_id uuid not null references public.avisos(id) on delete cascade,
  user_id  uuid not null default auth.uid() references auth.users(id) on delete cascade,
  lido_em  timestamptz not null default now(),
  primary key (aviso_id, user_id)
);

create or replace function public.pode_publicar_aviso()
returns boolean language sql stable security definer set search_path = public as $$
  select public.eh_admin() or public.is_admin();
$$;
revoke all on function public.pode_publicar_aviso() from public;
grant execute on function public.pode_publicar_aviso() to authenticated;

alter table public.avisos enable row level security;
alter table public.avisos_leitura enable row level security;

drop policy if exists avisos_ler on public.avisos;
create policy avisos_ler on public.avisos for select to authenticated
  using ( publicar_em <= now() or public.pode_publicar_aviso() );

drop policy if exists avisos_publicar on public.avisos;
create policy avisos_publicar on public.avisos for insert to authenticated
  with check ( public.pode_publicar_aviso() and criado_por = auth.uid() );

drop policy if exists avisos_alterar on public.avisos;
create policy avisos_alterar on public.avisos for update to authenticated
  using ( public.pode_publicar_aviso() ) with check ( public.pode_publicar_aviso() );

drop policy if exists avisos_apagar on public.avisos;
create policy avisos_apagar on public.avisos for delete to authenticated
  using ( public.pode_publicar_aviso() );

-- Cada um marca só a própria leitura, e só de aviso que já pode ver.
drop policy if exists avisos_leitura_ler on public.avisos_leitura;
create policy avisos_leitura_ler on public.avisos_leitura for select to authenticated
  using ( user_id = auth.uid() or public.pode_publicar_aviso() );

drop policy if exists avisos_leitura_marcar on public.avisos_leitura;
create policy avisos_leitura_marcar on public.avisos_leitura for insert to authenticated
  with check ( user_id = auth.uid()
    and exists (select 1 from public.avisos a where a.id = aviso_id and a.publicar_em <= now()) );

grant select, insert, update, delete on public.avisos to authenticated;
grant select, insert on public.avisos_leitura to authenticated;

-- A tela pede tudo de uma vez: os avisos visíveis, quem publicou, quantos
-- já leram e se a própria pessoa leu. "total" é quem tem perfil no portal.
drop function if exists public.avisos_resumo();
create function public.avisos_resumo()
returns table (id uuid, titulo text, texto text, publicar_em timestamptz, fixado boolean,
               autor text, lidos integer, total integer, lido_por_mim boolean)
language sql stable security definer set search_path = public as $$
  select a.id, a.titulo, a.texto, a.publicar_em, a.fixado,
         coalesce(p.nome, ''),
         (select count(*)::int from public.avisos_leitura l where l.aviso_id = a.id),
         (select count(*)::int from public.perfis),
         exists (select 1 from public.avisos_leitura l where l.aviso_id = a.id and l.user_id = auth.uid())
  from public.avisos a
  left join public.perfis p on p.user_id = a.criado_por
  where auth.uid() is not null
    and (a.publicar_em <= now() or public.pode_publicar_aviso())
  order by a.fixado desc, a.publicar_em desc
  limit 30;
$$;
revoke all on function public.avisos_resumo() from public;
grant execute on function public.avisos_resumo() to authenticated;

-- ============================================================
--  8.9. ARQUIVOS DO CLIENTE (06/11/2026)
--     Anexos na ficha do cliente do CRM (foto, PDF, Word, Excel) e
--     os documentos que o Wealth Planning e os Planos Patrimoniais
--     mandam direto para a ficha. Rodar inteiro no SQL Editor. Pode
--     rodar de novo sem estragar nada.
--
--     Os arquivos ficam no Storage do Supabase, no "bucket" privado
--     "anexos", numa pasta por cliente: anexos/<id do cliente>/...
--     Limite de 25 MB por arquivo, só os tipos da lista abaixo.
--     Quem enxerga o cliente no CRM enxerga os arquivos dele, e mais
--     ninguém: a regra é a mesma da ficha (pode_ver_lead).
-- ============================================================

-- A mesma regra de leitura da tabela leads (política leads_select).
create or replace function public.pode_ver_lead(p_id text)
returns boolean language sql security definer stable set search_path = public as $$
  select exists (
    select 1 from public.leads l
    where l.id = p_id
      and ( public.is_admin()
            or (public.is_ativo() and l.responsavel_id = auth.uid())
            or (public.is_ativo() and l.origem_lead_id is not null and public.lead_meu(l.origem_lead_id))
            or (public.is_ativo() and public.lead_origem_minha(l.id)) )
  );
$$;
revoke all on function public.pode_ver_lead(text) from public;
grant execute on function public.pode_ver_lead(text) to authenticated;

create table if not exists public.anexos (
  id          uuid primary key default gen_random_uuid(),
  lead_id     text not null references public.leads(id) on delete cascade,
  nome        text not null check (char_length(nome) between 1 and 200),
  caminho     text not null unique,
  tamanho     bigint not null check (tamanho > 0 and tamanho <= 26214400),
  tipo        text not null default '',
  -- De onde veio: enviado na ficha, ou gerado por uma ferramenta do Hub.
  origem      text not null default 'upload'
                check (origem in ('upload','wealth_planning','plano_patrimonial','enquadramento')),
  nota        text not null default '' check (char_length(nota) <= 500),
  enviado_por uuid default auth.uid() references auth.users(id) on delete set null,
  enviado_em  timestamptz not null default now()
);
create index if not exists anexos_lead_idx on public.anexos (lead_id, enviado_em desc);

alter table public.anexos enable row level security;

drop policy if exists anexos_ler on public.anexos;
create policy anexos_ler on public.anexos for select to authenticated
  using ( public.pode_ver_lead(lead_id) );

-- O caminho tem de estar na pasta do próprio cliente: sem isto, alguém
-- registraria aqui um arquivo guardado na pasta de outro cliente.
drop policy if exists anexos_criar on public.anexos;
create policy anexos_criar on public.anexos for insert to authenticated
  with check ( public.pode_ver_lead(lead_id)
               and enviado_por = auth.uid()
               and caminho like lead_id || '/%' );

drop policy if exists anexos_apagar on public.anexos;
create policy anexos_apagar on public.anexos for delete to authenticated
  using ( public.pode_ver_lead(lead_id) and (enviado_por = auth.uid() or public.is_admin()) );

grant select, insert, delete on public.anexos to authenticated;

-- Bucket privado com limite de tamanho e de tipo.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('anexos', 'anexos', false, 26214400, array[
  'application/pdf',
  'image/jpeg', 'image/png', 'image/webp', 'image/heic', 'image/heif',
  'application/msword',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'application/vnd.ms-excel',
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'application/vnd.ms-powerpoint',
  'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  'text/plain', 'text/csv'
])
on conflict (id) do update
  set public = false,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists anexos_arquivo_ler on storage.objects;
create policy anexos_arquivo_ler on storage.objects for select to authenticated
  using ( bucket_id = 'anexos' and public.pode_ver_lead((storage.foldername(name))[1]) );

drop policy if exists anexos_arquivo_enviar on storage.objects;
create policy anexos_arquivo_enviar on storage.objects for insert to authenticated
  with check ( bucket_id = 'anexos' and public.pode_ver_lead((storage.foldername(name))[1]) );

drop policy if exists anexos_arquivo_apagar on storage.objects;
create policy anexos_arquivo_apagar on storage.objects for delete to authenticated
  using ( bucket_id = 'anexos'
          and public.pode_ver_lead((storage.foldername(name))[1])
          and (owner_id = (auth.uid())::text or public.is_admin()) );

-- ============================================================
--  9. CONFERÊNCIA — é esta tabela que importa
--     Os três masters saem com master, administrador e admin no CRM.
--     A coluna "codigo" é a que vai para a planilha de clientes; se
--     preferir outro valor, troque na tela de Equipe do hub.
-- ============================================================
select u.email, p.nome, p.codigo,
       p.super as master, p.admin as administrador, p.mesa_rv as edita_rv,
       pr.role as papel_crm, pr.status as status_crm
from public.perfis p
join auth.users u on u.id = p.user_id
left join public.profiles pr on pr.id = p.user_id
order by p.super desc, p.admin desc, u.email;


-- ============================================================
--  8.10. SEGURANÇA (06/11/2026)
--     Verificação em duas etapas por e-mail, acesso que vence todo
--     dia e as correções da varredura de segurança. Rodar inteiro
--     no SQL Editor do Supabase ("Run without RLS" se ele perguntar).
--     Pode rodar de novo sem estragar nada.
--
--     ORDEM: instale a função "codigo-acesso" (Edge Functions) ANTES
--     de rodar este arquivo. A partir daqui o banco só entrega dado
--     para quem confirmou, no mesmo dia, o código de 6 dígitos que
--     chegou por e-mail.
--
--     Como funciona:
--       - Depois da senha, o Hub chama a função codigo-acesso, que
--         gera o código aqui (acesso_novo_codigo) e manda por e-mail.
--       - A pessoa digita o código; verificar_codigo confere e libera
--         AQUELA sessão (aquele login, naquele aparelho) até o fim do
--         dia, no horário de Brasília.
--       - Toda tabela ganha uma política "restritiva" (exige_verificacao):
--         sem a sessão liberada hoje, nenhuma tabela, arquivo ou função
--         de permissão responde, venha o pedido de onde vier.
--       - 0h01 de Brasília: o agendamento "acesso-virada" derruba todos
--         os logins. No dia seguinte, todo mundo entra de novo, com
--         senha e código.
--
--     SAÍDA DE EMERGÊNCIA (se o e-mail parar e ninguém conseguir entrar):
--       rode no SQL Editor:
--         update public.acesso_config set exigir_codigo = false;
--       e, quando o e-mail voltar:
--         update public.acesso_config set exigir_codigo = true;
-- ============================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------- 1. Tabelas (nenhuma é lida direto pelo navegador) ----------

create table if not exists public.acesso_config (
  id            boolean primary key default true check (id),
  exigir_codigo boolean not null default true
);
insert into public.acesso_config (id) values (true) on conflict (id) do nothing;

-- Códigos enviados por e-mail. Só o hash fica guardado, nunca o código.
create table if not exists public.acesso_codigos (
  id          bigint generated always as identity primary key,
  user_id     uuid not null references auth.users(id) on delete cascade,
  sessao      uuid not null,
  codigo_hash text not null,
  criado_em   timestamptz not null default now(),
  expira_em   timestamptz not null,
  tentativas  int not null default 0,
  usado_em    timestamptz,
  ip          text not null default '',
  navegador   text not null default ''
);
create index if not exists acesso_codigos_user_idx on public.acesso_codigos (user_id, criado_em desc);

-- Sessões liberadas: uma linha por login confirmado, válida só no dia.
create table if not exists public.acesso_sessoes (
  sessao        uuid primary key,
  user_id       uuid not null references auth.users(id) on delete cascade,
  dia           date not null,
  verificado_em timestamptz not null default now(),
  ip            text not null default '',
  navegador     text not null default ''
);
create index if not exists acesso_sessoes_user_idx on public.acesso_sessoes (user_id, dia);

-- Registro de acessos (quem entrou, quando, de onde). Ninguém apaga pela tela.
create table if not exists public.acesso_registro (
  id        bigint generated always as identity primary key,
  user_id   uuid references auth.users(id) on delete set null,
  evento    text not null check (evento in ('codigo_enviado','codigo_errado','entrou','bloqueado','saiu_de_todos')),
  em        timestamptz not null default now(),
  ip        text not null default '',
  navegador text not null default ''
);
create index if not exists acesso_registro_user_idx on public.acesso_registro (user_id, em desc);
create index if not exists acesso_registro_em_idx on public.acesso_registro (em desc);

alter table public.acesso_config   enable row level security;
alter table public.acesso_codigos  enable row level security;
alter table public.acesso_sessoes  enable row level security;
alter table public.acesso_registro enable row level security;
revoke all on public.acesso_config, public.acesso_codigos, public.acesso_sessoes, public.acesso_registro
  from public, anon, authenticated;

-- ---------- 2. A regra central ----------

create or replace function public.dia_brasilia()
returns date language sql stable set search_path = public as $$
  select (now() at time zone 'America/Sao_Paulo')::date;
$$;

-- O "session_id" vem dentro do token do Supabase e é o mesmo do login
-- inteiro (não muda quando o token é renovado).
create or replace function public.sessao_jwt()
returns uuid language sql stable set search_path = public as $$
  select case when coalesce(auth.jwt() ->> 'session_id', '') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
              then (auth.jwt() ->> 'session_id')::uuid end;
$$;

create or replace function public.acesso_liberado()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select not c.exigir_codigo from public.acesso_config c limit 1), false)
      or exists (select 1 from public.acesso_sessoes s
                  where s.sessao = public.sessao_jwt()
                    and s.user_id = auth.uid()
                    and s.dia = public.dia_brasilia());
$$;

create or replace function public.cabecalho_req(p_nome text)
returns text language sql stable set search_path = public as $$
  select coalesce(nullif(current_setting('request.headers', true), '')::json ->> p_nome, '');
$$;

-- ---------- 3. Gerar, conferir e consultar ----------

-- Só a função codigo-acesso (chave de serviço) gera código. Se o navegador
-- pudesse chamar isto, receberia o código sem precisar do e-mail.
create or replace function public.acesso_novo_codigo(p_user uuid, p_sessao uuid, p_ip text default '', p_navegador text default '')
returns text language plpgsql security definer set search_path = public, extensions as $$
declare
  v_codigo text;
  v_ultimo timestamptz;
begin
  if p_user is null or p_sessao is null then
    raise exception 'Sessão inválida. Entre de novo.';
  end if;
  if (select count(*) from public.acesso_registro
       where user_id = p_user and evento = 'codigo_errado' and em > now() - interval '30 minutes') >= 10 then
    raise exception 'Muitas tentativas erradas. Espere 30 minutos ou peça ajuda a um master.';
  end if;
  select max(criado_em) into v_ultimo from public.acesso_codigos where user_id = p_user;
  if v_ultimo > now() - interval '30 seconds' then
    raise exception 'Acabamos de mandar um código. Espere 30 segundos antes de pedir outro.';
  end if;
  if (select count(*) from public.acesso_codigos where user_id = p_user and criado_em > now() - interval '1 hour') >= 8 then
    raise exception 'Muitos códigos pedidos na última hora. Tente de novo mais tarde.';
  end if;

  -- 10/11/2026: pedir outro código NÃO cancela os anteriores. O e-mail do Microsoft 365 às vezes
  -- chega 1 ou 2 minutos depois; a pessoa pedia outro, o primeiro chegava e era recusado.
  -- Todos os códigos desta sessão valem até expirar (10 min); o primeiro certo libera e encerra os outros.

  v_codigo := lpad(((('x' || encode(gen_random_bytes(4), 'hex'))::bit(32)::bigint) % 1000000)::text, 6, '0');
  insert into public.acesso_codigos (user_id, sessao, codigo_hash, expira_em, ip, navegador)
  values (p_user, p_sessao, encode(digest(v_codigo || ':' || p_sessao::text, 'sha256'), 'hex'),
          now() + interval '10 minutes', left(coalesce(p_ip, ''), 100), left(coalesce(p_navegador, ''), 300));
  insert into public.acesso_registro (user_id, evento, ip, navegador)
  values (p_user, 'codigo_enviado', left(coalesce(p_ip, ''), 100), left(coalesce(p_navegador, ''), 300));
  return v_codigo;
end $$;

-- Confere o código. Erro de código não levanta exceção de propósito: com
-- exceção, o contador de tentativas voltaria atrás junto.
create or replace function public.verificar_codigo(p_codigo text)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare
  v_uid uuid := auth.uid();
  v_sessao uuid := public.sessao_jwt();
  v_ip text := left(split_part(public.cabecalho_req('x-forwarded-for'), ',', 1), 100);
  v_nav text := left(public.cabecalho_req('user-agent'), 300);
  v_cod text := regexp_replace(coalesce(p_codigo, ''), '\D', '', 'g');
  r public.acesso_codigos%rowtype;
begin
  if v_uid is null or v_sessao is null then
    return json_build_object('ok', false, 'msg', 'Sessão inválida. Entre de novo.');
  end if;
  if (select count(*) from public.acesso_registro
       where user_id = v_uid and evento = 'codigo_errado' and em > now() - interval '30 minutes') >= 10 then
    insert into public.acesso_registro (user_id, evento, ip, navegador) values (v_uid, 'bloqueado', v_ip, v_nav);
    return json_build_object('ok', false, 'bloqueado', true,
      'msg', 'Muitas tentativas erradas. Espere 30 minutos ou peça ajuda a um master.');
  end if;

  -- Qualquer código ainda válido desta sessão serve (ver acesso_novo_codigo).
  select * into r from public.acesso_codigos
   where user_id = v_uid and sessao = v_sessao and usado_em is null and expira_em > now()
     and length(v_cod) = 6 and codigo_hash = encode(digest(v_cod || ':' || v_sessao::text, 'sha256'), 'hex')
   order by criado_em desc limit 1
   for update;
  if not found then
    select * into r from public.acesso_codigos
     where user_id = v_uid and sessao = v_sessao and usado_em is null and expira_em > now()
     order by criado_em desc limit 1
     for update;
    if not found then
      return json_build_object('ok', false, 'expirado', true, 'msg', 'Esse código expirou ou já foi usado. Peça um novo.');
    end if;
  end if;

  if length(v_cod) <> 6 or r.codigo_hash <> encode(digest(v_cod || ':' || v_sessao::text, 'sha256'), 'hex') then
    update public.acesso_codigos
       set tentativas = tentativas + 1,
           usado_em = case when tentativas + 1 >= 5 then now() else null end
     where id = r.id;
    insert into public.acesso_registro (user_id, evento, ip, navegador) values (v_uid, 'codigo_errado', v_ip, v_nav);
    if r.tentativas + 1 >= 5 then
      return json_build_object('ok', false, 'expirado', true, 'msg', 'Código errado 5 vezes. Peça um novo código.');
    end if;
    return json_build_object('ok', false, 'restantes', 4 - r.tentativas,
      'msg', 'Código errado. Você ainda tem ' || (4 - r.tentativas) || ' tentativa(s) com este código.');
  end if;

  update public.acesso_codigos set usado_em = now() where user_id = v_uid and sessao = v_sessao and usado_em is null;
  insert into public.acesso_sessoes (sessao, user_id, dia, ip, navegador)
  values (v_sessao, v_uid, public.dia_brasilia(), v_ip, v_nav)
  on conflict (sessao) do update
    set dia = excluded.dia, verificado_em = now(), ip = excluded.ip, navegador = excluded.navegador
    where public.acesso_sessoes.user_id = excluded.user_id;
  insert into public.acesso_registro (user_id, evento, ip, navegador) values (v_uid, 'entrou', v_ip, v_nav);
  return json_build_object('ok', true, 'dia', public.dia_brasilia());
end $$;

-- O que a tela de login precisa saber: o código é exigido? esta sessão já está liberada?
create or replace function public.estado_acesso()
returns json language sql stable security definer set search_path = public as $$
  select json_build_object(
    'exige', coalesce((select c.exigir_codigo from public.acesso_config c limit 1), true),
    'liberado', public.acesso_liberado(),
    'dia', public.dia_brasilia());
$$;

-- "Sair de todos os aparelhos" (tela Segurança) fica registrado.
create or replace function public.registrar_saida_geral()
returns void language sql security definer set search_path = public as $$
  insert into public.acesso_registro (user_id, evento, ip, navegador)
  select auth.uid(), 'saiu_de_todos',
         left(split_part(public.cabecalho_req('x-forwarded-for'), ',', 1), 100),
         left(public.cabecalho_req('user-agent'), 300)
  where auth.uid() is not null and public.acesso_liberado();
$$;

-- Últimos acessos da própria pessoa (tela Segurança).
drop function if exists public.meus_acessos();
create function public.meus_acessos()
returns table (em timestamptz, evento text, ip text, navegador text)
language sql stable security definer set search_path = public as $$
  select r.em, r.evento, r.ip, r.navegador from public.acesso_registro r
   where r.user_id = auth.uid() and public.acesso_liberado()
   order by r.em desc limit 40;
$$;

-- Acessos da equipe inteira, só para master.
drop function if exists public.acessos_equipe();
create function public.acessos_equipe()
returns table (em timestamptz, nome text, email text, evento text, ip text, navegador text)
language sql stable security definer set search_path = public as $$
  select r.em, coalesce(p.nome, ''), coalesce(u.email::text, ''), r.evento, r.ip, r.navegador
    from public.acesso_registro r
    left join public.perfis p on p.user_id = r.user_id
    left join auth.users u on u.id = r.user_id
   where public.eh_super()
   order by r.em desc limit 300;
$$;

-- ---------- 4. Virada do dia: todo mundo entra de novo ----------

create or replace function public.acesso_virada_do_dia()
returns void language plpgsql security definer set search_path = public as $$
begin
  delete from public.acesso_codigos where criado_em < now() - interval '2 days';
  delete from public.acesso_sessoes where dia < public.dia_brasilia();
  delete from public.acesso_registro where em < now() - interval '400 days';
  begin
    -- Apagar a sessão invalida o token de renovação: o login de ontem não volta.
    delete from auth.sessions;
  exception when others then
    raise warning 'Não consegui encerrar as sessões: %', sqlerrm;
  end;
end $$;

do $$
begin
  perform cron.unschedule('acesso-virada');
exception when others then null;
end $$;
-- 3h01 em UTC = 0h01 em Brasília.
select cron.schedule('acesso-virada', '1 3 * * *', $cron$ select public.acesso_virada_do_dia(); $cron$);

-- ---------- 5. Permissões de quem chama ----------
--     As funções de permissão passam a exigir a sessão liberada. Assim,
--     mesmo uma função "security definer" (que não passa pela regra das
--     tabelas) recusa quem ainda não digitou o código.

create or replace function public.eh_super()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select p.super from public.perfis p where p.user_id = auth.uid()), false)
         and public.acesso_liberado();
$$;

create or replace function public.eh_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select p.admin or p.super from public.perfis p where p.user_id = auth.uid()), false)
         and public.acesso_liberado();
$$;

create or replace function public.pode_editar_rv()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select p.mesa_rv or p.admin or p.super
                   from public.perfis p where p.user_id = auth.uid()), false)
         and public.acesso_liberado();
$$;

create or replace function public.is_ativo()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and status = 'ativo')
         and public.acesso_liberado();
$$;

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'admin' and status = 'ativo')
         and public.acesso_liberado();
$$;

-- Correção da varredura: devolvia a lista de assessores com o código BTG
-- para qualquer pessoa, mesmo sem login.
create or replace function public.codigos_assessores()
returns table (user_id uuid, codigo text)
language sql stable security definer set search_path = public as $$
  select p.user_id, p.codigo from public.perfis p
   where p.codigo is not null and (public.is_ativo() or public.eh_admin());
$$;

-- Correção da varredura: qualquer pessoa na internet conseguia gravar por
-- cima da Política de Alocação de qualquer mês. Agora exige login confirmado.
create or replace function public.politica_alocacao_salvar(p_mes int, p_ano int, p_dados jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
  v_email text := auth.jwt() ->> 'email';
begin
  if auth.uid() is null or not public.acesso_liberado()
     or not exists (select 1 from public.perfis p where p.user_id = auth.uid()) then
    raise exception 'Entre no Hub para salvar a política.';
  end if;
  insert into public.politica_alocacao_snapshots (mes, ano, dados, salvo_por)
  values (p_mes, p_ano, p_dados, auth.uid())
  on conflict (mes, ano) do update set dados = excluded.dados, atualizado_em = now(), salvo_por = excluded.salvo_por
  returning id into v_id;

  insert into public.auditoria (usuario, acao, alvo, detalhe)
  values (v_email, 'salvou política de alocação', p_mes || '/' || p_ano, '');
  return v_id;
end $$;

-- avisos_resumo também passa a exigir a sessão liberada.
create or replace function public.avisos_resumo()
returns table (id uuid, titulo text, texto text, publicar_em timestamptz, fixado boolean,
               autor text, lidos integer, total integer, lido_por_mim boolean)
language sql stable security definer set search_path = public as $$
  select a.id, a.titulo, a.texto, a.publicar_em, a.fixado,
         coalesce(p.nome, ''),
         (select count(*)::int from public.avisos_leitura l where l.aviso_id = a.id),
         (select count(*)::int from public.perfis),
         exists (select 1 from public.avisos_leitura l where l.aviso_id = a.id and l.user_id = auth.uid())
  from public.avisos a
  left join public.perfis p on p.user_id = a.criado_por
  where auth.uid() is not null and public.acesso_liberado()
    and (a.publicar_em <= now() or public.pode_publicar_aviso())
  order by a.fixado desc, a.publicar_em desc
  limit 30;
$$;

-- ---------- 6. Correções da varredura nas tabelas ----------

-- configuracoes tinha políticas, mas a regra de linha não estava ligada no arquivo.
alter table public.configuracoes enable row level security;

-- perfis: pela API a pessoa só muda o próprio nome. Antes dava para trocar o
-- próprio código de assessor, e é o código que autoriza levar carteira na
-- importação do BTG.
revoke update on public.perfis from authenticated;
grant update (nome) on public.perfis to authenticated;

create or replace function public.proteger_privilegios()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then
    return new;                      -- SQL Editor / service_role
  end if;
  if (new.admin   is distinct from old.admin)
  or (new.mesa_rv is distinct from old.mesa_rv)
  or (new.super   is distinct from old.super)
  or (new.codigo  is distinct from old.codigo) then
    if not public.eh_super() then
      raise exception 'Apenas o master pode alterar privilégios e código de assessor.';
    end if;
  end if;
  if new.user_id is distinct from old.user_id then
    raise exception 'O vinculo do perfil com o usuario nao pode ser alterado.';
  end if;
  return new;
end $$;

-- auditoria: quem gravou é carimbado pelo banco (antes dava para registrar uma
-- ação em nome de outra pessoa), ninguém altera, e só master apaga.
create or replace function public.auditoria_carimbo()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null then
    new.usuario := coalesce(auth.jwt() ->> 'email', new.usuario);
    new.quando := now();
  end if;
  return new;
end $$;
drop trigger if exists auditoria_carimbo_trg on public.auditoria;
create trigger auditoria_carimbo_trg before insert on public.auditoria
  for each row execute function public.auditoria_carimbo();
revoke update on public.auditoria from authenticated;
drop policy if exists aud_apagar on public.auditoria;
create policy aud_apagar on public.auditoria for delete to authenticated using ( public.eh_super() );

-- ---------- 7. Ninguém sem login usa o banco ----------
--     O Supabase dá, por padrão, acesso de "anon" (visitante sem login) a
--     toda tabela e função nova. Nada no portal usa isso: o login fala com
--     o serviço de autenticação, não com o banco.

revoke all on all tables in schema public from anon;
revoke all on all sequences in schema public from anon;
revoke execute on all functions in schema public from public, anon;
grant execute on all functions in schema public to authenticated, service_role;
alter default privileges in schema public revoke all on tables from anon;
alter default privileges in schema public revoke all on sequences from anon;
alter default privileges in schema public revoke execute on functions from public, anon;

-- Funções que o navegador nunca pode chamar.
revoke execute on function public.acesso_novo_codigo(uuid, uuid, text, text) from authenticated;
revoke execute on function public.acesso_virada_do_dia() from authenticated;

-- Funções de gatilho não são chamadas por ninguém: o gatilho roda sem precisar de EXECUTE
-- (conferido). Também fixa o search_path da rv_touch (aviso do relatório de segurança do Supabase).
revoke execute on function public.tarefas_carimbo(), public.auditoria_carimbo(), public.configuracoes_carimba(),
  public.criar_perfil(), public.exige_convite(), public.handle_new_user(), public.perfil_novo_sem_privilegio(),
  public.protege_responsavel(), public.proteger_privilegios(), public.rv_touch()
  from public, anon, authenticated;
alter function public.rv_touch() set search_path = public;

-- ---------- 8. A regra que vale para tudo ----------
--     Uma política "restritiva" em cada tabela com regra de linha: soma-se
--     às que já existem (não substitui nenhuma) e exige a sessão liberada.

do $$
declare t record;
begin
  for t in
    select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind = 'r' and c.relrowsecurity
       and c.relname not like 'acesso\_%'
  loop
    execute format('drop policy if exists exige_verificacao on public.%I', t.relname);
    execute format('create policy exige_verificacao on public.%I as restrictive for all to authenticated '
                   'using ((select public.acesso_liberado())) with check ((select public.acesso_liberado()))', t.relname);
  end loop;
end $$;

-- Arquivos (Storage): a mesma regra.
drop policy if exists exige_verificacao on storage.objects;
create policy exige_verificacao on storage.objects as restrictive for all to authenticated
  using ((select public.acesso_liberado())) with check ((select public.acesso_liberado()));

-- Conferência: deve listar todas as tabelas com "exige_verificacao".
select c.relname as tabela,
       c.relrowsecurity as regra_ligada,
       exists (select 1 from pg_policy p where p.polrelid = c.oid and p.polname = 'exige_verificacao') as exige_codigo
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
 where n.nspname = 'public' and c.relkind = 'r'
 order by 1;


-- ============================================================
--  8.11. INTEGRAÇÃO COM O BTG, FASE 1: RECEBER E GUARDAR (06/11/2026)
--     O Hub pede os relatórios ao BTG (função btg-sync, agendada) e o
--     BTG entrega por webhook (função btg-webhook). Esta fase só RECEBE
--     e GUARDA numa área separada: não mexe em cliente, carteira nem
--     assessor. O CRM passa a usar esses dados na fase 2, pela mesma
--     prévia do "Atualizar base" (regras das seções 6 e 7).
--
--     Ninguém do navegador escreve aqui. Só master lê (tela de
--     conferência). Quem grava são as duas funções, com a chave de
--     serviço, pelas funções btg_* abaixo.
--
--     O agendamento começa DESLIGADO (btg_config.ligado = false): liga
--     depois que os webhooks estiverem cadastrados no portal do BTG.
-- ============================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------- 1. Tabelas ----------

create table if not exists public.btg_config (
  id        boolean primary key default true check (id),
  ligado    boolean not null default false,
  alterado_em timestamptz not null default now()
);
insert into public.btg_config (id) values (true) on conflict (id) do nothing;

-- O token do BTG vale 15 minutos: guardado para não pedir um novo a cada chamada.
create table if not exists public.btg_token (
  id        boolean primary key default true check (id),
  token     text not null,
  expira_em timestamptz not null
);

-- Cada pedido feito ao BTG (o que foi pedido e o que ele respondeu na hora).
create table if not exists public.btg_pedidos (
  id           bigint generated always as identity primary key,
  servico      text not null,
  metodo       text not null,
  caminho      text not null,
  corpo        jsonb,
  origem       text not null default 'agendado',
  pedido_em    timestamptz not null default now(),
  http_status  int,
  x_id_pactual text,
  resposta     text
);
create index if not exists btg_pedidos_em_idx on public.btg_pedidos (pedido_em desc);

-- Cada aviso que o BTG mandou ao webhook, e o arquivo baixado.
create table if not exists public.btg_arquivos (
  id            bigint generated always as identity primary key,
  servico       text not null,
  recebido_em   timestamptz not null default now(),
  aviso         jsonb not null default '{}'::jsonb,
  caminho       text,
  tamanho       bigint,
  linhas        int,
  colunas       text[],
  status        text not null check (status in ('recebido','guardado','processado','sem_dados','erro')),
  erro          text,
  processado_em timestamptz
);
create index if not exists btg_arquivos_em_idx on public.btg_arquivos (recebido_em desc);

-- Quem é o assessor de cada conta (rm-reports-account-link). Última versão recebida.
create table if not exists public.btg_vinculos (
  nr_conta     text primary key,
  cge_officer  text,
  login        text,
  nm_officer   text,
  cge_partner  text,
  ts_criado    text,
  arquivo_id   bigint references public.btg_arquivos(id) on delete set null,
  atualizado_em timestamptz not null default now()
);

-- Base de contas (rm-reports-account-base). Última versão recebida; a linha inteira fica em "dados".
create table if not exists public.btg_base (
  nr_conta      text primary key,
  nome          text,
  nm_assessor   text,
  cge_officer   text,
  email_assessor text,
  pl_total      numeric,
  dados         jsonb not null,
  arquivo_id    bigint references public.btg_arquivos(id) on delete set null,
  atualizado_em timestamptz not null default now()
);

-- Demais relatórios: linhas guardadas como vieram, por arquivo (posição, movimentação,
-- NNM, cadastro...). A fase 2 lê daqui conforme cada tela precisar.
create table if not exists public.btg_linhas (
  arquivo_id bigint not null references public.btg_arquivos(id) on delete cascade,
  n          int not null,
  nr_conta   text,
  dados      jsonb not null,
  primary key (arquivo_id, n)
);
create index if not exists btg_linhas_conta_idx on public.btg_linhas (nr_conta);

alter table public.btg_config   enable row level security;
alter table public.btg_token    enable row level security;
alter table public.btg_pedidos  enable row level security;
alter table public.btg_arquivos enable row level security;
alter table public.btg_vinculos enable row level security;
alter table public.btg_base     enable row level security;
alter table public.btg_linhas   enable row level security;

revoke all on public.btg_config, public.btg_token, public.btg_pedidos, public.btg_arquivos,
              public.btg_vinculos, public.btg_base, public.btg_linhas from public, anon, authenticated;
grant select on public.btg_config, public.btg_pedidos, public.btg_arquivos,
                public.btg_vinculos, public.btg_base, public.btg_linhas to authenticated;

-- Só master lê. O token nunca é lido por ninguém pela API.
do $$
declare t text;
begin
  foreach t in array array['btg_config','btg_pedidos','btg_arquivos','btg_vinculos','btg_base','btg_linhas'] loop
    execute format('drop policy if exists btg_master_ler on public.%I', t);
    execute format('create policy btg_master_ler on public.%I for select to authenticated using (public.eh_super())', t);
    execute format('drop policy if exists exige_verificacao on public.%I', t);
    execute format('create policy exige_verificacao on public.%I as restrictive for all to authenticated '
                   'using ((select public.acesso_liberado())) with check ((select public.acesso_liberado()))', t);
  end loop;
end $$;

-- ---------- 2. Arquivos brutos (Storage privado, só a chave de serviço) ----------

insert into storage.buckets (id, name, public, file_size_limit)
values ('btg', 'btg', false, 209715200)
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit;

-- ---------- 3. Funções que as Edge Functions chamam (só a chave de serviço) ----------

-- Normaliza número de conta: só dígitos, 9 posições (o Excel come os zeros à esquerda).
create or replace function public.btg_conta(p text)
returns text language sql immutable set search_path = public as $$
  select case when regexp_replace(coalesce(p, ''), '\D', '', 'g') = '' then null
              else lpad(regexp_replace(p, '\D', '', 'g'), 9, '0') end;
$$;

-- Número em texto do BTG: "235422,03", "1.234,56", "10.13", "1.06E+07".
create or replace function public.btg_numero(p text)
returns numeric language plpgsql immutable set search_path = public as $$
declare s text := btrim(coalesce(p, ''));
begin
  if s = '' then return null; end if;
  if s ~ '^-?[0-9.]+,[0-9]+$' then s := replace(replace(s, '.', ''), ',', '.');
  elsif s ~ '^-?[0-9]+,[0-9]+$' then s := replace(s, ',', '.');
  end if;
  return s::numeric;
exception when others then
  return null;
end $$;

create or replace function public.btg_token_atual()
returns text language sql stable security definer set search_path = public as $$
  select token from public.btg_token where expira_em > now() + interval '60 seconds';
$$;

create or replace function public.btg_token_guardar(p_token text, p_validade_seg int default 840)
returns void language sql security definer set search_path = public as $$
  insert into public.btg_token (id, token, expira_em) values (true, p_token, now() + make_interval(secs => p_validade_seg))
  on conflict (id) do update set token = excluded.token, expira_em = excluded.expira_em;
$$;

create or replace function public.btg_registrar_pedido(p_servico text, p_metodo text, p_caminho text, p_corpo jsonb,
  p_origem text, p_http int, p_x_id text, p_resposta text)
returns bigint language sql security definer set search_path = public as $$
  insert into public.btg_pedidos (servico, metodo, caminho, corpo, origem, http_status, x_id_pactual, resposta)
  values (p_servico, p_metodo, p_caminho, p_corpo, coalesce(p_origem, 'agendado'), p_http, p_x_id, left(p_resposta, 2000))
  returning id;
$$;

-- Registra o aviso do webhook (antes de baixar o arquivo).
create or replace function public.btg_aviso(p_servico text, p_aviso jsonb, p_status text, p_erro text default null)
returns bigint language sql security definer set search_path = public as $$
  insert into public.btg_arquivos (servico, aviso, status, erro) values (p_servico, coalesce(p_aviso, '{}'::jsonb), p_status, left(p_erro, 2000))
  returning id;
$$;

-- Recebe o arquivo já lido (linhas em JSON) e grava na área de recebimento.
create or replace function public.btg_receber(p_arquivo_id bigint, p_caminho text, p_tamanho bigint,
  p_colunas text[], p_linhas jsonb)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_servico text;
  v_n int := coalesce(jsonb_array_length(p_linhas), 0);
begin
  select servico into v_servico from public.btg_arquivos where id = p_arquivo_id;
  if v_servico is null then raise exception 'Arquivo % não existe.', p_arquivo_id; end if;

  update public.btg_arquivos set caminho = p_caminho, tamanho = p_tamanho, linhas = v_n, colunas = p_colunas,
         status = case when v_n = 0 then 'sem_dados' else 'guardado' end
   where id = p_arquivo_id;
  if v_n = 0 then return json_build_object('ok', true, 'linhas', 0); end if;

  if v_servico = 'rm-reports-account-link' then
    insert into public.btg_vinculos as v (nr_conta, cge_officer, login, nm_officer, cge_partner, ts_criado, arquivo_id, atualizado_em)
    select distinct on (public.btg_conta(x->>'nr_conta'))
           public.btg_conta(x->>'nr_conta'), x->>'cge_officer', x->>'login', x->>'nm_officer', x->>'cge_partner', x->>'ts_criado',
           p_arquivo_id, now()
      from jsonb_array_elements(p_linhas) x
     where public.btg_conta(x->>'nr_conta') is not null
    on conflict (nr_conta) do update set cge_officer = excluded.cge_officer, login = excluded.login,
      nm_officer = excluded.nm_officer, cge_partner = excluded.cge_partner, ts_criado = excluded.ts_criado,
      arquivo_id = excluded.arquivo_id, atualizado_em = now();

  elsif v_servico = 'rm-reports-account-base' then
    insert into public.btg_base as b (nr_conta, nome, nm_assessor, cge_officer, email_assessor, pl_total, dados, arquivo_id, atualizado_em)
    select distinct on (public.btg_conta(x->>'nr_conta'))
           public.btg_conta(x->>'nr_conta'), x->>'nome_completo', x->>'nm_assessor', x->>'cge_officer', x->>'email_assessor',
           public.btg_numero(x->>'pl_total'), x, p_arquivo_id, now()
      from jsonb_array_elements(p_linhas) x
     where public.btg_conta(x->>'nr_conta') is not null
    on conflict (nr_conta) do update set nome = excluded.nome, nm_assessor = excluded.nm_assessor,
      cge_officer = excluded.cge_officer, email_assessor = excluded.email_assessor, pl_total = excluded.pl_total,
      dados = excluded.dados, arquivo_id = excluded.arquivo_id, atualizado_em = now();

  else
    insert into public.btg_linhas (arquivo_id, n, nr_conta, dados)
    select p_arquivo_id, (o - 1)::int,
           public.btg_conta(coalesce(x->>'nr_conta', x->>'cod_carteira', x->>'accountNumber', x->>'account', x->>'conta')),
           x
      from jsonb_array_elements(p_linhas) with ordinality as t(x, o)
    on conflict (arquivo_id, n) do nothing;
  end if;

  update public.btg_arquivos set status = 'processado', processado_em = now() where id = p_arquivo_id;
  return json_build_object('ok', true, 'linhas', v_n);
end $$;

create or replace function public.btg_marcar_erro(p_arquivo_id bigint, p_erro text)
returns void language sql security definer set search_path = public as $$
  update public.btg_arquivos set status = 'erro', erro = left(p_erro, 2000) where id = p_arquivo_id;
$$;

-- Token do agendamento: gerado aqui, fica no Vault e nunca sai do banco. O agendamento
-- manda o token à função btg-sync, que pergunta ao banco se confere.
do $$
begin
  if not exists (select 1 from vault.secrets where name = 'btg_sync_token') then
    perform vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'), 'btg_sync_token',
                                'Token do agendamento que chama a função btg-sync');
  end if;
end $$;

create or replace function public.btg_sync_token_ok(p text)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(length(p), 0) >= 32 and exists (
    select 1 from vault.decrypted_secrets where name = 'btg_sync_token' and decrypted_secret = p);
$$;

create or replace function public.btg_ligado()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select ligado from public.btg_config limit 1), false);
$$;

revoke execute on function public.btg_token_atual(), public.btg_token_guardar(text, int),
  public.btg_registrar_pedido(text, text, text, jsonb, text, int, text, text),
  public.btg_aviso(text, jsonb, text, text),
  public.btg_receber(bigint, text, bigint, text[], jsonb),
  public.btg_marcar_erro(bigint, text), public.btg_sync_token_ok(text), public.btg_ligado()
  from public, anon, authenticated;
grant execute on function public.btg_token_atual(), public.btg_token_guardar(text, int),
  public.btg_registrar_pedido(text, text, text, jsonb, text, int, text, text),
  public.btg_aviso(text, jsonb, text, text),
  public.btg_receber(bigint, text, bigint, text[], jsonb),
  public.btg_marcar_erro(bigint, text), public.btg_sync_token_ok(text), public.btg_ligado()
  to service_role;

-- ---------- 4. Agendamento (dias úteis; horário em UTC = Brasília + 3h) ----------
--   8h30: vínculo, base, cadastro, posição de D-1 e movimentação (janelas do BTG: 7h e 8h)
--  15h30: NNM (janela das 15h)
--  20h30: movimentação do fim do dia (janela das 20h)
-- A função não faz nada enquanto btg_config.ligado = false.

do $$
declare j text;
begin
  foreach j in array array['btg-manha','btg-tarde','btg-noite'] loop
    begin perform cron.unschedule(j); exception when others then null; end;
  end loop;
end $$;

select cron.schedule('btg-manha', '30 11 * * 1-5', $c$
  select net.http_post(
    url := 'https://ghxjqmjtmbqzvogwzylo.supabase.co/functions/v1/btg-sync',
    headers := jsonb_build_object('Content-Type', 'application/json',
      'x-btg-sync', (select decrypted_secret from vault.decrypted_secrets where name = 'btg_sync_token')),
    body := '{"janela":"manha"}'::jsonb, timeout_milliseconds := 60000);
$c$);
select cron.schedule('btg-tarde', '30 18 * * 1-5', $c$
  select net.http_post(
    url := 'https://ghxjqmjtmbqzvogwzylo.supabase.co/functions/v1/btg-sync',
    headers := jsonb_build_object('Content-Type', 'application/json',
      'x-btg-sync', (select decrypted_secret from vault.decrypted_secrets where name = 'btg_sync_token')),
    body := '{"janela":"tarde"}'::jsonb, timeout_milliseconds := 60000);
$c$);
select cron.schedule('btg-noite', '30 23 * * 1-5', $c$
  select net.http_post(
    url := 'https://ghxjqmjtmbqzvogwzylo.supabase.co/functions/v1/btg-sync',
    headers := jsonb_build_object('Content-Type', 'application/json',
      'x-btg-sync', (select decrypted_secret from vault.decrypted_secrets where name = 'btg_sync_token')),
    body := '{"janela":"noite"}'::jsonb, timeout_milliseconds := 60000);
$c$);

-- Limpeza: linhas brutas com mais de 120 dias (os arquivos originais ficam no Storage).
create or replace function public.btg_limpeza()
returns void language sql security definer set search_path = public as $$
  delete from public.btg_linhas l using public.btg_arquivos a
   where a.id = l.arquivo_id and a.recebido_em < now() - interval '120 days';
  delete from public.btg_pedidos where pedido_em < now() - interval '400 days';
  delete from public.btg_token where expira_em < now() - interval '1 day';
$$;
revoke execute on function public.btg_limpeza() from public, anon, authenticated;
do $$ begin perform cron.unschedule('btg-limpeza'); exception when others then null; end $$;
select cron.schedule('btg-limpeza', '40 6 * * 0', $c$ select public.btg_limpeza(); $c$);


-- ============================================================
--  8.12. EQUIPE: EDITAR, REVOGAR E EXCLUIR (06/11/2026)
--     Ações do card da pessoa na tela de Equipe do Hub. Todas exigem
--     master (eh_super, que já exige o código do dia) e ficam na
--     auditoria. Pode rodar de novo sem estragar nada.
--
--     Travas:
--      - ninguém revoga nem exclui a si mesmo;
--      - não dá para tirar o último master ativo;
--      - EXCLUIR só vale para quem não tem cliente no CRM nem carteira:
--        apagar a pessoa deixaria os clientes sem responsável. Para quem
--        tem, o caminho é revogar o acesso (reversível) ou transferir antes.
-- ============================================================

-- A lista da Equipe passa a trazer também: acesso revogado, último acesso e
-- quantos clientes a pessoa tem (CRM e Carteiras).
drop function if exists public.listar_equipe();
create function public.listar_equipe()
returns table (user_id uuid, email text, nome text, codigo text, admin boolean, mesa_rv boolean, super boolean,
               crm_role text, crm_status text, crm_produtos text[], criado_em timestamptz,
               revogado boolean, ultimo_acesso timestamptz, qtd_leads int, qtd_carteiras int)
language sql stable security definer set search_path = public as $$
  select p.user_id, u.email::text, p.nome, p.codigo, p.admin, p.mesa_rv, p.super,
         pr.role, pr.status, pr.produtos, u.created_at,
         coalesce(u.banned_until > now(), false), u.last_sign_in_at,
         (select count(*)::int from public.leads l where l.responsavel_id = p.user_id and not coalesce(l.excluido, false)),
         (select count(*)::int from public.clientes c where c.assessor_id = p.user_id)
  from public.perfis p
  join auth.users u on u.id = p.user_id
  left join public.profiles pr on pr.id = p.user_id
  where public.eh_super()
  order by p.super desc, p.admin desc, p.mesa_rv desc, u.email;
$$;
revoke all on function public.listar_equipe() from public, anon;
grant execute on function public.listar_equipe() to authenticated;

create or replace function public.equipe_ultimo_master(p_user_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select p.super from public.perfis p where p.user_id = p_user_id), false)
     and (select count(*) from public.perfis p join auth.users u on u.id = p.user_id
           where p.super and coalesce(u.banned_until, '-infinity') <= now()) <= 1;
$$;
revoke all on function public.equipe_ultimo_master(uuid) from public, anon, authenticated;

-- Nome e e-mail.
create or replace function public.equipe_editar(p_user_id uuid, p_nome text, p_email text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_nome text := btrim(coalesce(p_nome, ''));
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_antigo text;
  v_quem text := coalesce(auth.jwt() ->> 'email', '?');
begin
  if not public.eh_super() then raise exception 'Apenas o master pode editar a equipe.'; end if;
  select email into v_antigo from auth.users where id = p_user_id;
  if v_antigo is null then raise exception 'Pessoa não encontrada.'; end if;
  if char_length(v_nome) < 2 or char_length(v_nome) > 80 then raise exception 'O nome precisa ter entre 2 e 80 letras.'; end if;
  if v_email !~ '^[^\s@<>",;]+@[^\s@<>",;]+\.[^\s@<>",;]+$' or char_length(v_email) > 200 then
    raise exception 'E-mail inválido.';
  end if;

  update public.perfis set nome = v_nome where user_id = p_user_id;
  update public.profiles set nome = v_nome where id = p_user_id;

  if v_email <> lower(v_antigo) then
    if exists (select 1 from auth.users where lower(email) = v_email and id <> p_user_id) then
      raise exception 'Já existe outra conta com o e-mail %.', v_email;
    end if;
    update auth.users set email = v_email, email_confirmed_at = coalesce(email_confirmed_at, now()), updated_at = now()
     where id = p_user_id;
    update auth.identities set identity_data = identity_data || jsonb_build_object('email', v_email), updated_at = now()
     where user_id = p_user_id and provider = 'email';
    update public.convites set email = v_email where email = lower(v_antigo);
    insert into public.auditoria (usuario, acao, alvo, detalhe)
    values (v_quem, 'trocou e-mail', v_antigo, 'novo: ' || v_email);
  end if;
  insert into public.auditoria (usuario, acao, alvo, detalhe) values (v_quem, 'editou pessoa', v_email, 'nome: ' || v_nome);
end $$;

-- Revogar: bloqueia o login, derruba as sessões abertas e tira do CRM. Reversível.
create or replace function public.equipe_revogar(p_user_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_email text; v_quem text := coalesce(auth.jwt() ->> 'email', '?');
begin
  if not public.eh_super() then raise exception 'Apenas o master pode revogar acesso.'; end if;
  if p_user_id = auth.uid() then raise exception 'Você não pode revogar o seu próprio acesso.'; end if;
  if public.equipe_ultimo_master(p_user_id) then raise exception 'Essa pessoa é o último master ativo. Dê master a outra pessoa antes.'; end if;
  select email into v_email from auth.users where id = p_user_id;
  if v_email is null then raise exception 'Pessoa não encontrada.'; end if;

  update auth.users set banned_until = '2999-12-31 00:00:00+00', updated_at = now() where id = p_user_id;
  delete from auth.sessions where user_id = p_user_id;
  delete from public.acesso_sessoes where user_id = p_user_id;
  update public.profiles set status = 'removido' where id = p_user_id;
  insert into public.auditoria (usuario, acao, alvo, detalhe) values (v_quem, 'revogou acesso', v_email, '');
end $$;

create or replace function public.equipe_reativar(p_user_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_email text; v_quem text := coalesce(auth.jwt() ->> 'email', '?');
begin
  if not public.eh_super() then raise exception 'Apenas o master pode reativar acesso.'; end if;
  select email into v_email from auth.users where id = p_user_id;
  if v_email is null then raise exception 'Pessoa não encontrada.'; end if;
  update auth.users set banned_until = null, updated_at = now() where id = p_user_id;
  update public.profiles set status = 'ativo' where id = p_user_id and status = 'removido';
  insert into public.auditoria (usuario, acao, alvo, detalhe) values (v_quem, 'reativou acesso', v_email, '');
end $$;

-- Excluir de vez (só quem não tem cliente).
create or replace function public.equipe_excluir(p_user_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_email text; v_nome text; v_leads int; v_cart int;
  v_quem text := coalesce(auth.jwt() ->> 'email', '?');
begin
  if not public.eh_super() then raise exception 'Apenas o master pode excluir alguém da equipe.'; end if;
  if p_user_id = auth.uid() then raise exception 'Você não pode excluir a si mesmo.'; end if;
  if public.equipe_ultimo_master(p_user_id) then raise exception 'Essa pessoa é o último master ativo.'; end if;
  select u.email, coalesce(p.nome, u.email) into v_email, v_nome
    from auth.users u left join public.perfis p on p.user_id = u.id where u.id = p_user_id;
  if v_email is null then raise exception 'Pessoa não encontrada.'; end if;

  select count(*) into v_leads from public.leads where responsavel_id = p_user_id and not coalesce(excluido, false);
  select count(*) into v_cart from public.clientes where assessor_id = p_user_id;
  if v_leads > 0 or v_cart > 0 then
    raise exception '% ainda tem % cliente(s) no CRM e % carteira(s). Transfira para outra pessoa antes de excluir, ou use "Revogar acesso".',
      v_nome, v_leads, v_cart;
  end if;

  insert into public.auditoria (usuario, acao, alvo, detalhe) values (v_quem, 'excluiu pessoa', v_email, v_nome);
  delete from public.convites where email = lower(v_email);
  delete from auth.users where id = p_user_id;
end $$;

revoke all on function public.equipe_editar(uuid, text, text), public.equipe_revogar(uuid),
                       public.equipe_reativar(uuid), public.equipe_excluir(uuid) from public, anon;
grant execute on function public.equipe_editar(uuid, text, text), public.equipe_revogar(uuid),
                          public.equipe_reativar(uuid), public.equipe_excluir(uuid) to authenticated;


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


-- ============================================================
--  8.14. BTG FASE 3: RENTABILIDADE MENSAL NAS CARTEIRAS (06/11/2026)
--     API de Rentabilidade Mensal do BTG (iaas-profitability), três
--     relatórios assíncronos que chegam pelo btg-webhook:
--       monthly-customer-profitability  a carteira (conta) no mês: saldo,
--                                       movimentação, lucro, rentabilidade
--                                       e os índices (CDI, Ibov, IMA-B...)
--       monthly-product-profitability   cada produto da conta no mês
--       monthly-strategy-profitability  a conta por estratégia no mês
--     Um pedido traz o histórico (até 12 meses) até o mês pedido. Fica
--     guardado por conta e mês: pedir de novo atualiza, não duplica.
--
--     Nas Carteiras, o botão "Puxar do BTG" (Preencher) lê daqui as contas
--     BTG do cliente (clientes.contas_btg) e preenche a conta BTG, a lista
--     de ativos do BTG, a alocação por estratégia e os índices. As contas e
--     ativos de outros bancos continuam na mão. Nada grava sem "Salvar mês".
--
--     Pode rodar de novo sem estragar nada.
-- ============================================================

-- ---------- 1. Contas BTG de cada cliente das Carteiras ----------
alter table public.clientes add column if not exists contas_btg text[] not null default '{}';
create index if not exists clientes_contas_btg_idx on public.clientes using gin (contas_btg);

-- Sempre 9 dígitos, sem repetir, sem vazio ("12345" e "000012345" são a mesma conta).
create or replace function public.clientes_contas_btg_normalizar()
returns trigger language plpgsql set search_path = public as $$
begin
  new.contas_btg := coalesce((select array_agg(distinct c order by c)
                                from (select public.btg_conta(x) c from unnest(new.contas_btg) x) t
                               where c is not null), '{}');
  if cardinality(new.contas_btg) > 20 then raise exception 'No máximo 20 contas BTG por cliente.'; end if;
  return new;
end $$;
drop trigger if exists clientes_contas_btg on public.clientes;
create trigger clientes_contas_btg before insert or update of contas_btg on public.clientes
  for each row execute function public.clientes_contas_btg_normalizar();
revoke all on function public.clientes_contas_btg_normalizar() from public, anon, authenticated;

-- ---------- 2. Onde a rentabilidade fica ----------
create table if not exists public.btg_rent_carteira (
  nr_conta      text not null,
  mes_ref       date not null,               -- sempre dia 1
  dados         jsonb not null,              -- a linha inteira do BTG
  arquivo_id    bigint references public.btg_arquivos(id) on delete set null,
  atualizado_em timestamptz not null default now(),
  primary key (nr_conta, mes_ref)
);
create table if not exists public.btg_rent_produto (
  nr_conta      text not null,
  mes_ref       date not null,
  produto       text not null,               -- product_key, senão product_id, senão o nome
  dados         jsonb not null,
  arquivo_id    bigint references public.btg_arquivos(id) on delete set null,
  atualizado_em timestamptz not null default now(),
  primary key (nr_conta, mes_ref, produto)
);
create table if not exists public.btg_rent_estrategia (
  nr_conta      text not null,
  mes_ref       date not null,
  estrategia    text not null,
  dados         jsonb not null,
  arquivo_id    bigint references public.btg_arquivos(id) on delete set null,
  atualizado_em timestamptz not null default now(),
  primary key (nr_conta, mes_ref, estrategia)
);
create index if not exists btg_rent_carteira_mes_idx on public.btg_rent_carteira (mes_ref);
alter table public.btg_rent_carteira   enable row level security;
alter table public.btg_rent_produto    enable row level security;
alter table public.btg_rent_estrategia enable row level security;
-- Sem política: ninguém lê direto. As Carteiras leem por btg_rent_cliente, que confere o cliente.
revoke all on public.btg_rent_carteira, public.btg_rent_produto, public.btg_rent_estrategia from anon, authenticated;

-- "2023-01-01", "2023-01", "9/1/2023" (mês/dia/ano, como no dicionário do BTG) -> dia 1 do mês.
create or replace function public.btg_mes_ref(p text)
returns date language plpgsql immutable set search_path = public as $$
declare s text := btrim(coalesce(p, '')); m text[];
begin
  m := regexp_match(s, '^(\d{4})-(\d{1,2})');
  if m is not null then return make_date(m[1]::int, m[2]::int, 1); end if;
  m := regexp_match(s, '^(\d{1,2})/(\d{1,2})/(\d{4})');
  if m is not null then return make_date(m[3]::int, m[1]::int, 1); end if;
  m := regexp_match(s, '^(\d{1,2})/(\d{4})$');
  if m is not null then return make_date(m[2]::int, m[1]::int, 1); end if;
  return null;
exception when others then return null;
end $$;

-- Recebe um lote de linhas (o btg-webhook manda o arquivo em pedaços) e, no último,
-- fecha o arquivo. Só a chave de serviço chama.
create or replace function public.btg_rent_receber(p_arquivo_id bigint, p_linhas jsonb,
  p_final boolean default false, p_total int default null, p_caminho text default null,
  p_tamanho bigint default null, p_colunas text[] default null)
returns json language plpgsql security definer set search_path = public as $$
declare v_servico text; v_n int := 0;
begin
  select servico into v_servico from public.btg_arquivos where id = p_arquivo_id;
  if v_servico is null then raise exception 'Arquivo % não existe.', p_arquivo_id; end if;

  if p_linhas is not null and jsonb_array_length(p_linhas) > 0 then
    if v_servico = 'monthly-customer-profitability' then
      insert into public.btg_rent_carteira as t (nr_conta, mes_ref, dados, arquivo_id, atualizado_em)
      select distinct on (c, m) c, m, x, p_arquivo_id, now()
        from (select public.btg_conta(x->>'cod_carteira') c,
                     public.btg_mes_ref(coalesce(nullif(x->>'reference_month', ''), x->>'reference_date')) m, x
                from jsonb_array_elements(p_linhas) x) s
       where c is not null and m is not null
       order by c, m
      on conflict (nr_conta, mes_ref) do update set dados = excluded.dados, arquivo_id = excluded.arquivo_id, atualizado_em = now();
    elsif v_servico = 'monthly-product-profitability' then
      insert into public.btg_rent_produto as t (nr_conta, mes_ref, produto, dados, arquivo_id, atualizado_em)
      select distinct on (c, m, pr) c, m, pr, x, p_arquivo_id, now()
        from (select public.btg_conta(x->>'cod_carteira') c, public.btg_mes_ref(x->>'reference_month') m,
                     coalesce(nullif(x->>'product_key', ''), nullif(x->>'product_id', ''), nullif(x->>'product_name', ''), '?') pr, x
                from jsonb_array_elements(p_linhas) x) s
       where c is not null and m is not null
       order by c, m, pr
      on conflict (nr_conta, mes_ref, produto) do update set dados = excluded.dados, arquivo_id = excluded.arquivo_id, atualizado_em = now();
    elsif v_servico = 'monthly-strategy-profitability' then
      insert into public.btg_rent_estrategia as t (nr_conta, mes_ref, estrategia, dados, arquivo_id, atualizado_em)
      select distinct on (c, m, e) c, m, e, x, p_arquivo_id, now()
        from (select public.btg_conta(x->>'cod_carteira') c, public.btg_mes_ref(x->>'reference_month') m,
                     coalesce(nullif(btrim(x->>'asset_allocation_strategy'), ''), 'Sem estratégia') e, x
                from jsonb_array_elements(p_linhas) x) s
       where c is not null and m is not null
       order by c, m, e
      on conflict (nr_conta, mes_ref, estrategia) do update set dados = excluded.dados, arquivo_id = excluded.arquivo_id, atualizado_em = now();
    else
      raise exception 'Serviço % não é de rentabilidade.', v_servico;
    end if;
    get diagnostics v_n = row_count;
  end if;

  if p_final then
    update public.btg_arquivos
       set caminho = coalesce(p_caminho, caminho), tamanho = coalesce(p_tamanho, tamanho),
           linhas = coalesce(p_total, linhas), colunas = coalesce(p_colunas, colunas),
           status = case when coalesce(p_total, 0) = 0 then 'sem_dados' else 'processado' end,
           processado_em = now()
     where id = p_arquivo_id;
  end if;
  return json_build_object('ok', true, 'gravadas', v_n);
end $$;
revoke all on function public.btg_rent_receber(bigint, jsonb, boolean, int, text, bigint, text[]) from public, anon, authenticated;
grant execute on function public.btg_rent_receber(bigint, jsonb, boolean, int, text, bigint, text[]) to service_role;

-- ---------- 3. O que as Carteiras leem ----------
-- Nome sem acento, minúsculo, só letras e números (para sugerir a conta pelo nome).
create or replace function public.btg_nome_norm(p text)
returns text language sql immutable set search_path = public as $$
  select btrim(regexp_replace(regexp_replace(lower(translate(coalesce(p, ''),
    'ÁÀÂÃÄáàâãäÉÈÊËéèêëÍÌÎÏíìîïÓÒÔÕÖóòôõöÚÙÛÜúùûüÇçÑñ',
    'AAAAAaaaaaEEEEeeeeIIIIiiiiOOOOOoooooUUUUuuuuCcNn')), '[^a-z0-9 ]', ' ', 'g'), '\s+', ' ', 'g'));
$$;

-- Rentabilidade de um cliente num mês, somando as contas BTG dele.
-- Quem vê o cliente nas Carteiras (dono ou "ver todas as carteiras") vê isto.
create or replace function public.btg_rent_cliente(p_cliente uuid, p_mes int, p_ano int)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_contas text[]; v_mes date;
begin
  if not public.meu_cliente(p_cliente) then raise exception 'Sem acesso a este cliente.'; end if;
  if p_mes not between 1 and 12 or p_ano not between 2000 and 2100 then raise exception 'Mês inválido.'; end if;
  select contas_btg into v_contas from public.clientes where id = p_cliente;
  v_mes := make_date(p_ano, p_mes, 1);
  return jsonb_build_object(
    'contas', to_jsonb(coalesce(v_contas, '{}')),
    'mes_ref', v_mes,
    'carteira', coalesce((select jsonb_agg(jsonb_build_object('nr_conta', nr_conta, 'dados', dados, 'atualizado_em', atualizado_em) order by nr_conta)
                            from public.btg_rent_carteira where nr_conta = any (v_contas) and mes_ref = v_mes), '[]'),
    'produtos', coalesce((select jsonb_agg(jsonb_build_object('nr_conta', nr_conta, 'dados', dados) order by nr_conta, produto)
                            from public.btg_rent_produto where nr_conta = any (v_contas) and mes_ref = v_mes), '[]'),
    'estrategias', coalesce((select jsonb_agg(jsonb_build_object('nr_conta', nr_conta, 'estrategia', estrategia, 'dados', dados) order by nr_conta, estrategia)
                               from public.btg_rent_estrategia where nr_conta = any (v_contas) and mes_ref = v_mes), '[]'),
    'ultimo_mes', (select max(mes_ref) from public.btg_rent_carteira where nr_conta = any (v_contas)),
    'ultimo_mes_casa', (select max(mes_ref) from public.btg_rent_carteira));
end $$;
revoke all on function public.btg_rent_cliente(uuid, int, int) from public, anon;
grant execute on function public.btg_rent_cliente(uuid, int, int) to authenticated;

-- Sugestão de conta pelo nome: base de contas do BTG e a conta anotada no CRM.
create or replace function public.btg_sugerir_contas(p_cliente uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_nome text;
begin
  if not public.meu_cliente(p_cliente) then raise exception 'Sem acesso a este cliente.'; end if;
  select public.btg_nome_norm(nome) into v_nome from public.clientes where id = p_cliente;
  if coalesce(v_nome, '') = '' then return '[]'; end if;
  return coalesce((
    select jsonb_agg(distinct jsonb_build_object('nr_conta', conta, 'nome', nome, 'fonte', fonte))
      from (
        select b.nr_conta conta, b.nome, 'BTG' fonte from public.btg_base b where public.btg_nome_norm(b.nome) = v_nome
        union all
        select public.btg_conta(l.conta), l.cliente, 'CRM' from public.leads l
         where public.btg_nome_norm(l.cliente) = v_nome and public.btg_conta(l.conta) is not null
           and not coalesce(l.excluido, false)
      ) s where conta is not null), '[]');
end $$;
revoke all on function public.btg_sugerir_contas(uuid) from public, anon;
grant execute on function public.btg_sugerir_contas(uuid) to authenticated;

-- ---------- 4. Pedido mensal ----------
-- Dias 2 e 5 de cada mês, 9h de Brasília: pede o mês corrente, que traz o histórico até
-- o dia 1 (o mês anterior fechado). Duas tentativas porque o BTG pode fechar o mês com
-- atraso; pedir de novo só atualiza. 3 relatórios por pedido, dentro do limite de 12/dia.
do $$ begin perform cron.unschedule('btg-rentabilidade'); exception when others then null; end $$;
select cron.schedule('btg-rentabilidade', '0 12 2,5 * *', $c$
  select net.http_post(
    url := 'https://ghxjqmjtmbqzvogwzylo.supabase.co/functions/v1/btg-sync',
    headers := jsonb_build_object('Content-Type', 'application/json',
      'x-btg-sync', (select decrypted_secret from vault.decrypted_secrets where name = 'btg_sync_token')),
    body := '{"janela":"rentabilidade"}'::jsonb, timeout_milliseconds := 60000);
$c$);

-- Botão do master para pedir agora (ex.: logo depois de ligar a integração).
-- O token do agendamento sai do Vault só aqui dentro, nunca para o navegador.
create or replace function public.btg_pedir_agora(p_janela text)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_id bigint;
begin
  if not public.eh_super() then raise exception 'Apenas o master pode pedir relatórios ao BTG.'; end if;
  if p_janela not in ('rentabilidade', 'manha', 'tarde', 'noite') then raise exception 'Pedido desconhecido.'; end if;
  select net.http_post(
    url := 'https://ghxjqmjtmbqzvogwzylo.supabase.co/functions/v1/btg-sync',
    headers := jsonb_build_object('Content-Type', 'application/json',
      'x-btg-sync', (select decrypted_secret from vault.decrypted_secrets where name = 'btg_sync_token')),
    body := jsonb_build_object('janela', p_janela), timeout_milliseconds := 60000) into v_id;
  insert into public.auditoria (usuario, acao, alvo, detalhe)
  values (coalesce(auth.jwt() ->> 'email', '?'), 'pediu relatório ao BTG', p_janela, '');
  return v_id;
end $$;
revoke all on function public.btg_pedir_agora(text) from public, anon;
grant execute on function public.btg_pedir_agora(text) to authenticated;


-- ============================================================
--  8.15. BTG FASE 2: ATUALIZAR A BASE DO CRM PELO BTG (06/11/2026)
--     O botão "Atualizar do BTG" na tela Atualizar base do CRM usa a base
--     que o BTG manda todo dia útil (rm-reports-account-base, guardada em
--     btg_base) e o assessor de cada conta (rm-reports-account-link, em
--     btg_vinculos), no mesmo formato da planilha. A comparação e a prévia
--     são as mesmas da planilha (crm.html, reconciliarBaseBTG): nada grava
--     antes de alguém aplicar.
--     Pode rodar de novo sem estragar nada.
-- ============================================================
create or replace function public.btg_base_crm()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  -- Mesma régua da tela: quem vê todos os clientes do CRM (crm.todos, que é o is_admin).
  if not public.is_admin() then
    raise exception 'Só quem vê todos os clientes do CRM pode atualizar a base.';
  end if;
  return jsonb_build_object(
    'atualizado_em', (select max(atualizado_em) from public.btg_base),
    'vinculos_em',   (select max(atualizado_em) from public.btg_vinculos),
    'linhas', coalesce((
      select jsonb_agg(jsonb_build_object(
               'Conta', b.nr_conta,
               'Nome', b.nome,
               'Sob Gestão', coalesce(b.pl_total, 0),
               'Assessor', coalesce(nullif(v.nm_officer, ''), b.nm_assessor, ''),
               'Código Assessor', coalesce(nullif(v.cge_officer, ''), b.cge_officer, '')
             ) order by b.nr_conta)
        from public.btg_base b
        left join public.btg_vinculos v on v.nr_conta = b.nr_conta), '[]'::jsonb));
end $$;
revoke all on function public.btg_base_crm() from public, anon;
grant execute on function public.btg_base_crm() to authenticated;


-- ============================================================
--  8.16. TELA INICIAL: AVISOS E REGISTRO DE ATIVIDADES (06/11/2026, Hub 2.96)
--     Pode rodar de novo sem estragar nada.
-- ============================================================

-- Avisos: o "de N" passa a contar só quem tem acesso (sem as contas revogadas) e o
-- resumo diz se o aviso é meu e quanto falta ler.
drop function if exists public.avisos_resumo();
create function public.avisos_resumo()
returns table (id uuid, titulo text, texto text, publicar_em timestamptz, fixado boolean,
               autor text, lidos integer, total integer, lido_por_mim boolean, criado_em timestamptz)
language sql stable security definer set search_path = public as $$
  with equipe as (
    select p.user_id from public.perfis p join auth.users u on u.id = p.user_id
     where coalesce(u.banned_until, '-infinity') <= now()
  )
  select a.id, a.titulo, a.texto, a.publicar_em, a.fixado,
         coalesce(p.nome, ''),
         (select count(*)::int from public.avisos_leitura l join equipe e on e.user_id = l.user_id where l.aviso_id = a.id),
         (select count(*)::int from equipe),
         exists (select 1 from public.avisos_leitura l where l.aviso_id = a.id and l.user_id = auth.uid()),
         a.criado_em
  from public.avisos a
  left join public.perfis p on p.user_id = a.criado_por
  where auth.uid() is not null and public.acesso_liberado()
    and (a.publicar_em <= now() or public.pode_publicar_aviso())
  order by a.fixado desc, a.publicar_em desc
  limit 100;
$$;
revoke all on function public.avisos_resumo() from public, anon;
grant execute on function public.avisos_resumo() to authenticated;

-- Quem leu e quem ainda não leu um aviso (só quem pode publicar aviso vê).
create or replace function public.aviso_leitores(p_aviso uuid)
returns table (nome text, lido_em timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.pode_publicar_aviso() then raise exception 'Só quem publica avisos vê quem leu.'; end if;
  return query
    select coalesce(nullif(p.nome, ''), split_part(u.email, '@', 1))::text, l.lido_em
      from public.perfis p
      join auth.users u on u.id = p.user_id
      left join public.avisos_leitura l on l.aviso_id = p_aviso and l.user_id = p.user_id
     where coalesce(u.banned_until, '-infinity') <= now()
     order by l.lido_em is null, l.lido_em desc, 1;
end $$;
revoke all on function public.aviso_leitores(uuid) from public, anon;
grant execute on function public.aviso_leitores(uuid) to authenticated;

-- Registro de atividades (tela do master): a auditoria com o nome de quem fez, filtros e
-- paginação. Lê só quem é master (gerenciar equipe).
create or replace function public.registro_atividades(p_de timestamptz default null, p_ate timestamptz default null,
  p_usuario text default null, p_acao text default null, p_busca text default null, p_limite int default 100, p_antes bigint default null)
returns table (id bigint, quando timestamptz, usuario text, nome text, acao text, alvo text, detalhe text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.eh_super() then raise exception 'Apenas o master vê o registro de atividades.'; end if;
  return query
    select a.id, a.quando, a.usuario, coalesce(nullif(p.nome, ''), a.usuario)::text, a.acao, a.alvo, a.detalhe
      from public.auditoria a
      left join auth.users u on lower(u.email) = lower(a.usuario)
      left join public.perfis p on p.user_id = u.id
     where (p_de is null or a.quando >= p_de)
       and (p_ate is null or a.quando < p_ate)
       and (p_usuario is null or lower(a.usuario) = lower(p_usuario))
       and (p_acao is null or a.acao = p_acao)
       and (p_busca is null or btrim(p_busca) = ''
            or (coalesce(a.alvo, '') || ' ' || coalesce(a.detalhe, '') || ' ' || coalesce(a.acao, '')) ilike '%' || p_busca || '%')
       and (p_antes is null or a.id < p_antes)
     order by a.id desc
     limit least(greatest(coalesce(p_limite, 100), 1), 500);
end $$;
revoke all on function public.registro_atividades(timestamptz, timestamptz, text, text, text, int, bigint) from public, anon;
grant execute on function public.registro_atividades(timestamptz, timestamptz, text, text, text, int, bigint) to authenticated;

-- As ações que existem, para o filtro (com a contagem dos últimos 90 dias).
create or replace function public.registro_acoes()
returns table (acao text, qtd bigint)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.eh_super() then raise exception 'Apenas o master vê o registro de atividades.'; end if;
  return query select a.acao, count(*) from public.auditoria a
    where a.quando > now() - interval '90 days' and a.acao is not null group by a.acao order by 2 desc;
end $$;
revoke all on function public.registro_acoes() from public, anon;
grant execute on function public.registro_acoes() to authenticated;

create index if not exists auditoria_usuario_idx on public.auditoria (lower(usuario));


-- ============================================================
--  8.17. ALERTA DE SALDO DO BTG: MOVIMENTAÇÕES QUE EXPLICAM A DIFERENÇA (07/11/2026)
--     Na "Atualizar do BTG" do CRM, as aplicações e resgates que o BTG informou
--     (rm-reports-movement, guardadas em btg_linhas) desde a última atualização
--     explicam a variação de saldo antes de virar alerta.
--     Conta: soma de vl_captacao das linhas com flag_nnm (dinheiro que entrou
--     ou saiu da conta); sem vl_captacao, vl_bruto com o sinal pelo tipo.
--     A calibrar com o primeiro arquivo real do BTG.
--     Pode rodar de novo sem estragar nada.
-- ============================================================
create or replace function public.btg_data(p text)
returns date language plpgsql immutable set search_path = public as $$
declare s text := btrim(coalesce(p, ''));
begin
  if s ~ '^\d{4}-\d{2}-\d{2}' then return left(s, 10)::date; end if;
  if s ~ '^\d{2}/\d{2}/\d{4}' then return to_date(left(s, 10), 'DD/MM/YYYY'); end if;
  return null;
exception when others then return null;
end $$;

create or replace function public.btg_movimentos_crm(p_desde date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  if not public.is_admin() then raise exception 'Só quem vê todos os clientes do CRM.'; end if;
  with linhas as (
    -- o mesmo movimento vem em vários arquivos (o BTG manda os últimos 20 dias a cada pedido)
    select distinct l.nr_conta, l.dados
      from public.btg_linhas l
      join public.btg_arquivos a on a.id = l.arquivo_id
     where a.servico in ('rm-reports-movement', 'rm-reports-monthly-movement') and l.nr_conta is not null
  ), mov as (
    select nr_conta,
           public.btg_data(dados->>'dt_movimentacao') dia,
           lower(btrim(coalesce(dados->>'flag_nnm', ''))) flag,
           public.btg_numero(dados->>'vl_captacao') cap,
           public.btg_numero(dados->>'vl_bruto') bruto,
           lower(coalesce(dados->>'tipo_operacao', '') || ' ' || coalesce(dados->>'tipo_lancamento', '') || ' '
                 || coalesce(dados->>'historico_movimentacao', '')) tipo
      from linhas
  ), por_conta as (
    select nr_conta,
           sum(coalesce(cap, case when tipo ~ '(resg|retir|debit|saida|saída|transf.*sai)' then -abs(bruto) else abs(bruto) end)) valor
      from mov
     where dia > p_desde and flag in ('s', 'sim', 'true', '1', 'y', 'yes')
     group by nr_conta
  )
  select jsonb_build_object('desde', p_desde, 'contas_com_movimento', count(*),
           'contas', coalesce(jsonb_object_agg(nr_conta, round(coalesce(valor, 0), 2)), '{}'::jsonb))
    into v from por_conta;
  return v;
end $$;
revoke all on function public.btg_movimentos_crm(date) from public, anon;
grant execute on function public.btg_movimentos_crm(date) to authenticated;


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
  ('Pershing', 'USD', 5, 'instalação'), ('Previdência', 'BRL', 6, 'instalação'),
  ('Seguros', 'BRL', 7, 'instalação'),   -- 2.2: a regra de seguro precisa de uma planilha para apontar
  ('BTG Banking', 'BRL', 2, 'instalação')  -- 2.3: Relatório B2B 20188910-5 (câmbio, cartão, conta PJ); entra no PJ1
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
-- divisao: [{recebedor: 'profissional' | 'escritorio' | <user_id>, pct: número ou null (= o restante), negativos: bool,
--            so_primeira: bool}]
-- pct_planilha (2.3): o "profissional da linha" recebe o % que vem na própria planilha (coluna de % do
-- profissional, como na planilha de consórcio); sem o % na linha, vale o pct da regra.
-- so_primeira (10/11/2026, pedido do Emil): o especialista de seguro e consórcio recebe só na 1ª parcela.
-- Nas parcelas seguintes a parte dele vai para quem fica com "o restante" (normalmente o escritório).
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
alter table public.comissao_lancamentos add column if not exists parcela int;   -- nº da parcela (seguro, consórcio)
alter table public.comissao_lancamentos add column if not exists empresa_id uuid references public.comissao_empresas(id) on delete set null;
create index if not exists comissao_lanc_comp_idx on public.comissao_lancamentos (competencia);
create index if not exists comissao_lanc_plan_idx on public.comissao_lancamentos (planilha_id);

-- 2.2 (10/11/2026): a regra diz em quais planilhas vale (várias) e qual empresa paga.
alter table public.comissao_regras add column if not exists cond_origens uuid[] not null default '{}';
alter table public.comissao_regras add column if not exists empresa_id uuid references public.comissao_empresas(id) on delete set null;
update public.comissao_regras set cond_origens = array[cond_origem_id], cond_origem_id = null
 where cond_origem_id is not null and cardinality(cond_origens) = 0;
alter table public.comissao_fixos add column if not exists empresa_id uuid references public.comissao_empresas(id) on delete set null;

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
alter table public.comissao_pagamentos add column if not exists por_empresa jsonb not null default '[]'::jsonb;

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
-- Ordem: código da Equipe, nomes nas planilhas, nome, nome completo, e-mail e (2.3) primeiro + último
-- nome, se só uma pessoa da Equipe combinar ("Angela Eva Adami" -> "Angela Adami").
create or replace function public.com_pessoa(p_txt text) returns uuid language sql stable security definer set search_path = public as $$
  with n as (select public.com_norm(p_txt) as t),
  cand as (
    select p.user_id from public.perfis p, n
     where n.t like '% %' and public.com_norm(p.nome) like '% %'
       and split_part(public.com_norm(p.nome), ' ', 1) = split_part(n.t, ' ', 1)
       and substring(public.com_norm(p.nome) from '[^ ]+$') = substring(n.t from '[^ ]+$'))
  select case when (select t from n) = '' then null
              when (select t from n) in ('ESCRITORIO', 'ESCRITORIO ADAMI', 'ADAMI CAPTAL') then '00000000-0000-0000-0000-000000000000'::uuid
              else (select x.uid from (
                select p.user_id as uid, 1 as ordem from public.perfis p, n where p.codigo is not null and public.com_norm(p.codigo) = n.t
                union all select d.user_id, 2 from public.comissao_dados_pagto d, n where exists (select 1 from unnest(d.nomes_planilha) a where public.com_norm(a) = n.t)
                union all select p.user_id, 3 from public.perfis p, n where public.com_norm(p.nome) = n.t
                union all select d.user_id, 4 from public.comissao_dados_pagto d, n where public.com_norm(d.nome_completo) = n.t
                union all select u.id, 5 from auth.users u, n where public.com_norm(u.email) = n.t or public.com_norm(split_part(u.email, '@', 1)) = n.t
                union all select c.user_id, 6 from cand c where (select count(*) from cand) = 1
              ) x order by x.ordem limit 1) end;
$$;

-- Condição de texto com vários valores (2.3): "ERRO OPERACIONAL, FEE DE PLATAFORMA" vale para qualquer um deles.
create or replace function public.com_bate_valor(p_cond text, p_valor text) returns boolean language sql immutable set search_path = public as $$
  select public.com_norm(p_cond) = ''
      or public.com_norm(p_valor) = any(regexp_split_to_array(public.com_norm(p_cond), '\s*[;,]\s*'));
$$;

-- Item cabe na condição de cliente (texto ou lista)? Compara com o nome e com a conta.
create or replace function public.com_bate_cliente(p_cond text, p_lista uuid, p_cliente text, p_conta text)
returns boolean language sql stable security definer set search_path = public as $$
  select (public.com_norm(p_cond) = '' or public.com_norm(p_cond) in (public.com_norm(p_cliente), public.com_norm(p_conta)))
     and (p_lista is null or exists (select 1 from public.comissao_listas l, unnest(l.itens) i
                                      where l.id = p_lista and public.com_norm(i) in (public.com_norm(p_cliente), public.com_norm(p_conta))
                                        and public.com_norm(i) <> ''));
$$;

-- O motor. p: {cliente, conta, profissional (texto: código ou nome) ou profissional_id, profissional_nome (2.3: o nome,
--            quando a planilha traz código e nome; serve de reserva), categoria, produto, valor, parcela,
--            pct_profissional (2.3: % do profissional que vem na planilha; 0,3 ou 30 = 30%)}
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
  v_parc int; v_primeira boolean := true; v_nome text := btrim(coalesce(p->>'profissional_nome', '')); v_pid2 uuid;
  v_pctl numeric; v_pct numeric;
begin
  begin
    v_pctl := nullif(replace(regexp_replace(coalesce(p->>'pct_profissional', ''), '[^0-9,.-]', '', 'g'), ',', '.'), '')::numeric;
    if v_pctl is not null and v_pctl > 0 and v_pctl <= 1 then v_pctl := v_pctl * 100; end if;   -- célula em % do Excel (0,3)
    if v_pctl is not null and (v_pctl <= 0 or v_pctl > 100) then v_pctl := null; end if;
  exception when others then v_pctl := null;
  end;
  begin
    v_orig := coalesce(nullif(btrim(p->>'valor'), '')::numeric, 0);
  exception when others then
    return jsonb_build_object('erro', 'valor da comissão não é número: ' || coalesce(p->>'valor', ''));
  end;
  v_val := round(v_orig * coalesce(p_cotacao, 1), 6);
  if v_prof = '' then v_prof := v_nome; end if;   -- sem código: vale o nome
  if public.com_norm(v_nome) = public.com_norm(v_prof) then v_nome := ''; end if;

  -- 1. troca de campos (a primeira que bate, para cada campo)
  for t in select * from public.comissao_trocas where ativo and (cond_origem_id is null or cond_origem_id = p_origem) order by prioridade, criado_em loop
    continue when t.campo = any(v_feitos);
    continue when public.com_norm(t.cond_cliente) <> '' and public.com_norm(t.cond_cliente) not in (public.com_norm(v_cli), public.com_norm(v_conta));
    continue when public.com_norm(t.cond_profissional) <> '' and public.com_norm(t.cond_profissional) <> public.com_norm(v_prof)
                  and public.com_norm(t.cond_profissional) <> public.com_norm(v_nome);
    continue when public.com_norm(t.cond_categoria) <> '' and public.com_norm(t.cond_categoria) <> public.com_norm(v_cat);
    continue when public.com_norm(t.cond_produto) <> '' and public.com_norm(t.cond_produto) <> public.com_norm(v_prod);
    if t.campo = 'profissional' then v_avisos := v_avisos || to_jsonb(v_prof || ' → ' || t.valor); v_prof := t.valor; v_nome := '';
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
    if v_pid is null and v_nome <> '' then   -- o código não está na Equipe: tenta pelo nome
      v_pid2 := public.com_pessoa(v_nome);
      if v_pid2 is not null then v_pid := v_pid2; v_prof := v_nome; end if;
    end if;
    if v_pid = '00000000-0000-0000-0000-000000000000'::uuid then v_pid := null; v_esc := true;
    elsif v_pid is null then
      return jsonb_build_object('erro', 'profissional "' || v_prof || '"' || case when v_nome <> '' then ' (' || v_nome || ')' else '' end
          || ' não está no cadastro (crie uma troca de nome ou cadastre em Pessoas)',
        'cliente', v_cli, 'conta', v_conta, 'profissional_txt', v_prof, 'categoria', v_cat, 'produto', v_prod,
        'valor_original', v_orig, 'valor', v_val, 'avisos', v_avisos);
    end if;
  end if;

  -- 3. a regra
  select * into v_regra from public.comissao_regras g
   where g.ativo and g.vigencia_inicio <= p_comp and (g.vigencia_fim is null or g.vigencia_fim >= p_comp)
     and (cardinality(g.cond_origens) = 0 or p_origem = any(g.cond_origens))
     and public.com_bate_valor(g.cond_categoria, v_cat)
     and public.com_bate_valor(g.cond_produto, v_prod)
     and (g.cond_profissional is null or g.cond_profissional = v_pid)
     and public.com_bate_cliente(g.cond_cliente, g.cond_lista_id, v_cli, v_conta)
   order by g.prioridade, g.criado_em limit 1;
  if v_regra.id is null then
    return jsonb_build_object('erro', 'nenhuma regra de repasse serve para esta linha',
      'cliente', v_cli, 'conta', v_conta, 'profissional_txt', v_prof, 'profissional_id', v_pid, 'prof_escritorio', v_esc,
      'categoria', v_cat, 'produto', v_prod, 'valor_original', v_orig, 'valor', v_val, 'avisos', v_avisos);
  end if;

  -- 4. a parcela: "1", "1/5", "Parcela 2 de 5" -> o primeiro número. Só importa se a regra tem
  --    recebedor "só na 1ª parcela". Sem a coluna, é 1ª parcela se o mesmo cliente, conta e produto
  --    ainda não apareceram, desta origem, em mês anterior.
  v_parc := nullif(substring(coalesce(p->>'parcela', '') from '(\d{1,4})'), '')::int;
  if exists (select 1 from jsonb_array_elements(v_regra.divisao) x where coalesce((x->>'so_primeira')::boolean, false)) then
    if v_parc is not null then
      v_primeira := v_parc <= 1;
    elsif v_cli <> '' or v_conta <> '' then
      v_primeira := not exists (select 1 from public.comissao_lancamentos l
         where l.tipo = 'receita' and l.competencia < p_comp and l.origem_id is not distinct from p_origem
           and public.com_norm(l.cliente) = public.com_norm(v_cli) and public.com_norm(l.conta) = public.com_norm(v_conta)
           and public.com_norm(l.produto) = public.com_norm(v_prod));
    end if;
  end if;

  -- 5. a divisão
  for d in select * from jsonb_array_elements(v_regra.divisao) loop
    if d->'pct' is null or jsonb_typeof(d->'pct') = 'null' then v_resto := d; continue; end if;
    if v_val < 0 and not coalesce((d->>'negativos')::boolean, true) then continue; end if;
    if coalesce((d->>'so_primeira')::boolean, false) and not v_primeira then continue; end if;
    v_pct := (d->>'pct')::numeric;
    if d->>'recebedor' = 'profissional' and coalesce((d->>'pct_planilha')::boolean, false) and v_pctl is not null then v_pct := v_pctl; end if;
    v_parte := round(v_val * v_pct / 100, 6);
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
  if v_resto is not null and v_parte <> 0 and (v_val >= 0 or coalesce((v_resto->>'negativos')::boolean, true))
     and (v_primeira or not coalesce((v_resto->>'so_primeira')::boolean, false)) then
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
    'regra_id', v_regra.id, 'regra_nome', v_regra.nome, 'rateio', v_saida, 'valor_escritorio', v_escr, 'avisos', v_avisos,
    'parcela', v_parc, 'primeira', v_primeira, 'empresa_id', v_regra.empresa_id, 'pct_linha', v_pctl);
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
      rateio, valor_escritorio, parcela, empresa_id, criado_por)
    values (pl.competencia, 'receita', p_id, coalesce((it->>'linha')::int, i), pl.origem_id, o.nome, c->>'cliente', c->>'conta',
      c->>'profissional_txt', nullif(c->>'profissional_id', '')::uuid, coalesce((c->>'prof_escritorio')::boolean, false),
      c->>'categoria', c->>'produto', (c->>'valor_original')::numeric, pl.cotacao, (c->>'valor')::numeric,
      (c->>'regra_id')::uuid, c->>'regra_nome', c->'rateio', (c->>'valor_escritorio')::numeric, (c->>'parcela')::int,
      nullif(c->>'empresa_id', '')::uuid, public.com_quem());
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
                       and l.valor = -f.valor and l.descricao = f.descricao and l.categoria = f.categoria and (l.rateio->0->>'user_id')::uuid = f.user_id
                       and l.empresa_id is not distinct from f.empresa_id);
  insert into public.comissao_lancamentos (competencia, tipo, fixo_id, profissional_id, profissional_txt, categoria, descricao, valor, rateio, valor_escritorio, empresa_id, criado_por)
  select v_comp, 'fixo', f.id, f.user_id, coalesce(public.com_nome(f.user_id), ''), f.categoria, f.descricao, -f.valor,
         jsonb_build_array(jsonb_build_object('user_id', f.user_id, 'papel', 'ajuste fixo', 'valor', f.valor)), -f.valor, f.empresa_id, 'automático'
    from public.comissao_fixos f
   where f.ativo and f.inicio <= v_comp and (f.fim is null or f.fim >= v_comp)
     and not exists (select 1 from public.comissao_lancamentos l where l.competencia = v_comp and l.fixo_id = f.id);
end $$;

-- Totais de cada pessoa no mês. Cada parte vem paga por uma empresa: a da regra (ou do ajuste fixo e do
-- ajuste); sem empresa, a empresa padrão da pessoa (dados de pagamento). O imposto é o da empresa,
-- sobre a parte positiva dela. por_empresa traz a conta de cada empresa (a folha usa).
drop function if exists public.com_totais(date);
create function public.com_totais(p_comp date)
returns table (user_id uuid, bruto numeric, pct_imposto numeric, imposto numeric, liquido numeric, empresa_id uuid, linhas int, por_empresa jsonb)
language sql stable security definer set search_path = public as $$
  with partes as (
    select (r->>'user_id')::uuid as uid, coalesce(l.empresa_id, d.empresa_id) as emp, (r->>'valor')::numeric as v
      from public.comissao_lancamentos l cross join jsonb_array_elements(l.rateio) r
      left join public.comissao_dados_pagto d on d.user_id = (r->>'user_id')::uuid
     where l.competencia = public.com_mes(p_comp) and nullif(r->>'user_id', '') is not null),
  por as (
    select x.uid, x.emp, round(sum(x.v), 2) as bruto, count(*)::int as n, coalesce(max(e.pct_imposto), 0) as pct
      from partes x left join public.comissao_empresas e on e.id = x.emp
     group by x.uid, x.emp),
  por2 as (
    select por.*, case when por.bruto > 0 then round(por.bruto * por.pct / 100, 2) else 0 end as imp from por)
  select uid, sum(bruto), case when sum(bruto) > 0 then round(sum(imp) / sum(bruto) * 100, 4) else 0 end, sum(imp), sum(bruto) - sum(imp),
         case when count(*) = 1 then (array_agg(emp))[1] end, sum(n)::int,
         jsonb_agg(jsonb_build_object('empresa_id', emp, 'bruto', bruto, 'pct_imposto', pct, 'imposto', imp, 'liquido', bruto - imp) order by emp)
    from por2 group by uid;
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
  public.com_bate_valor(text, text),
  public.com_calcular(jsonb, uuid, date, numeric), public.com_processar_planilha(uuid), public.com_aplicar_fixos(date),
  public.com_totais(date), public.com_minimos(date) from public, anon, authenticated;

-- 2.3: como no sistema antigo, a "Assessoria Digital" do BTG é do escritório.
insert into public.comissao_trocas (grupo, prioridade, cond_profissional, campo, valor, atualizado_por)
select 'Nomes das planilhas', 1000, 'ASSESSORIA DIGITAL', 'profissional', 'ESCRITORIO', 'instalação'
 where not exists (select 1 from public.comissao_trocas where public.com_norm(cond_profissional) = 'ASSESSORIA DIGITAL');

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
        'descricao', l.descricao, 'parcela', l.parcela, 'empresa_id', l.empresa_id, 'valor_original', l.valor_original, 'cotacao', l.cotacao, 'valor', l.valor, 'regra_nome', l.regra_nome,
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
    insert into public.comissao_lancamentos (competencia, tipo, profissional_id, profissional_txt, categoria, descricao, valor, rateio, valor_escritorio, empresa_id, criado_por)
    values (v_comp, 'ajuste', v_user, coalesce(public.com_nome(v_user), ''), coalesce(nullif(btrim(p->>'categoria'), ''), 'AJUSTE'),
            btrim(p->>'descricao'), -v_val, jsonb_build_array(jsonb_build_object('user_id', v_user, 'papel', 'ajuste', 'valor', v_val)), -v_val,
            nullif(p->>'empresa_id', '')::uuid, public.com_quem())
    returning id into v_id;
  elsif p->>'tipo' = 'receita' then
    c := public.com_calcular(p, nullif(p->>'origem_id', '')::uuid, v_comp, 1);
    if c ? 'erro' then raise exception '%', c->>'erro'; end if;
    insert into public.comissao_lancamentos (competencia, tipo, origem_id, origem_nome, cliente, conta, profissional_txt, profissional_id, prof_escritorio,
      categoria, produto, descricao, valor_original, valor, regra_id, regra_nome, rateio, valor_escritorio, parcela, empresa_id, criado_por)
    values (v_comp, 'receita', nullif(p->>'origem_id', '')::uuid, coalesce((select nome from public.comissao_origens where id = nullif(p->>'origem_id', '')::uuid), 'Lançamento avulso'),
      c->>'cliente', c->>'conta', c->>'profissional_txt', nullif(c->>'profissional_id', '')::uuid, coalesce((c->>'prof_escritorio')::boolean, false),
      c->>'categoria', c->>'produto', btrim(coalesce(p->>'descricao', '')), (c->>'valor_original')::numeric, (c->>'valor')::numeric,
      (c->>'regra_id')::uuid, c->>'regra_nome', c->'rateio', (c->>'valor_escritorio')::numeric, (c->>'parcela')::int,
      nullif(c->>'empresa_id', '')::uuid, public.com_quem())
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
-- Quantas condições a regra tem (as mais específicas ficam em cima quando a regra nasce).
create or replace function public.com_ncond(g public.comissao_regras) returns int language sql immutable set search_path = public as $$
  select (btrim(g.cond_categoria) <> '')::int + (btrim(g.cond_produto) <> '')::int + (g.cond_profissional is not null)::int
       + (btrim(g.cond_cliente) <> '')::int + (g.cond_lista_id is not null)::int + (cardinality(g.cond_origens) > 0)::int;
$$;
revoke all on function public.com_ncond(public.comissao_regras) from public, anon, authenticated;

create or replace function public.comissao_regra_salvar(p jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid := nullif(p->>'id', '')::uuid; d jsonb; v_soma numeric := 0; v_restos int := 0; v_div jsonb := '[]'::jsonb; v_rec text;
        v_origens uuid[]; v_novo boolean := false; v_regra public.comissao_regras; v_pos int;
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
    v_div := v_div || jsonb_build_object('recebedor', v_rec, 'pct', d->'pct', 'negativos', coalesce((d->>'negativos')::boolean, true),
                                         'so_primeira', coalesce((d->>'so_primeira')::boolean, false),
                                         'pct_planilha', coalesce((d->>'pct_planilha')::boolean, false) and v_rec = 'profissional');
  end loop;
  if v_restos > 1 then raise exception 'Só um recebedor pode ficar com "o restante".'; end if;
  if v_soma > 100.0001 then raise exception 'Os percentuais passam de 100%% (somam %).', v_soma; end if;
  select coalesce(array_agg(distinct x::uuid), '{}') into v_origens
    from jsonb_array_elements_text(case when jsonb_typeof(p->'cond_origens') = 'array' then p->'cond_origens' else '[]'::jsonb end) x;
  if v_id is null then
    v_novo := true;
    insert into public.comissao_regras (nome, prioridade, ativo, cond_cliente, cond_lista_id, cond_profissional, cond_origens, empresa_id,
      cond_categoria, cond_produto, divisao, tag, obs, vigencia_inicio, vigencia_fim, atualizado_por)
    values (btrim(p->>'nome'), coalesce(nullif(p->>'prioridade', '')::int, 9000),
      coalesce((p->>'ativo')::boolean, true), btrim(coalesce(p->>'cond_cliente', '')), nullif(p->>'cond_lista_id', '')::uuid,
      nullif(p->>'cond_profissional', '')::uuid, v_origens, nullif(p->>'empresa_id', '')::uuid, btrim(coalesce(p->>'cond_categoria', '')),
      btrim(coalesce(p->>'cond_produto', '')), v_div, btrim(coalesce(p->>'tag', '')), coalesce(p->>'obs', ''),
      coalesce(nullif(p->>'vigencia_inicio', '')::date, date '2026-10-01'), nullif(p->>'vigencia_fim', '')::date, public.com_quem())
    returning id into v_id;
    insert into public.auditoria (usuario, acao, alvo, detalhe) values (public.com_quem(), 'criou regra de repasse', p->>'nome', '');
  else
    update public.comissao_regras set nome = btrim(p->>'nome'), ativo = coalesce((p->>'ativo')::boolean, ativo),
      cond_cliente = btrim(coalesce(p->>'cond_cliente', '')), cond_lista_id = nullif(p->>'cond_lista_id', '')::uuid,
      cond_profissional = nullif(p->>'cond_profissional', '')::uuid, cond_origens = v_origens, cond_origem_id = null,
      empresa_id = nullif(p->>'empresa_id', '')::uuid,
      cond_categoria = btrim(coalesce(p->>'cond_categoria', '')), cond_produto = btrim(coalesce(p->>'cond_produto', '')),
      divisao = v_div, tag = btrim(coalesce(p->>'tag', '')), obs = coalesce(p->>'obs', obs),
      vigencia_inicio = coalesce(nullif(p->>'vigencia_inicio', '')::date, vigencia_inicio), vigencia_fim = nullif(p->>'vigencia_fim', '')::date,
      atualizado_em = now(), atualizado_por = public.com_quem()
     where id = v_id;
    if not found then raise exception 'Regra não encontrada.'; end if;
    insert into public.auditoria (usuario, acao, alvo, detalhe) values (public.com_quem(), 'alterou regra de repasse', p->>'nome', '');
  end if;
  -- Regra nova sem posição escolhida: entra logo acima da primeira regra mais geral que ela
  -- (com menos condições), para a específica ser testada antes. O Repasse padrão (9999) fica por último.
  if v_novo and nullif(p->>'prioridade', '') is null then
    select * into v_regra from public.comissao_regras where id = v_id;
    select min(g.prioridade) into v_pos from public.comissao_regras g
     where g.id <> v_id and g.prioridade < 9999 and public.com_ncond(g) < public.com_ncond(v_regra);
    update public.comissao_regras set prioridade = coalesce(v_pos - 5, (select coalesce(max(prioridade), 0) + 10 from public.comissao_regras where prioridade < 9000))
     where id = v_id;
    update public.comissao_regras g set prioridade = x.rn * 10
      from (select id, row_number() over (order by prioridade, criado_em) as rn from public.comissao_regras where prioridade < 9999) x
     where g.id = x.id;
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
    insert into public.comissao_fixos (grupo, user_id, descricao, valor, categoria, inicio, fim, ativo, empresa_id, atualizado_por)
    values (btrim(coalesce(p->>'grupo', '')), (p->>'user_id')::uuid, btrim(p->>'descricao'), (p->>'valor')::numeric,
            coalesce(nullif(btrim(p->>'categoria'), ''), 'AJUSTE'), v_ini, v_fim, coalesce((p->>'ativo')::boolean, true),
            nullif(p->>'empresa_id', '')::uuid, public.com_quem())
    returning id into v_id;
  else
    update public.comissao_fixos set grupo = btrim(coalesce(p->>'grupo', '')), user_id = (p->>'user_id')::uuid, descricao = btrim(p->>'descricao'),
      valor = (p->>'valor')::numeric, categoria = coalesce(nullif(btrim(p->>'categoria'), ''), 'AJUSTE'), inicio = v_ini, fim = v_fim,
      ativo = coalesce((p->>'ativo')::boolean, ativo), empresa_id = nullif(p->>'empresa_id', '')::uuid, atualizado_por = public.com_quem()
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
      insert into public.comissao_pagamentos (competencia, user_id, bruto, pct_imposto, imposto, valor, empresa_id, por_empresa)
      values (v_comp, t.user_id, t.bruto, t.pct_imposto, t.imposto, t.liquido, t.empresa_id, t.por_empresa);
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
                    'empresa', (select string_agg(e.nome, ', ' order by e.ordem) from public.comissao_empresas e
                                 where e.id in (select (x->>'empresa_id')::uuid from jsonb_array_elements(p.por_empresa) x)),
                    'por_empresa', (select jsonb_agg(x || jsonb_build_object('empresa', (select nome from public.comissao_empresas e where e.id = (x->>'empresa_id')::uuid)))
                                      from jsonb_array_elements(p.por_empresa) x))
                    from public.comissao_pagamentos p where p.competencia = v_comp and p.user_id = v_eu),
    'linhas', coalesce((select jsonb_agg(jsonb_build_object('tipo', l.tipo, 'origem', l.origem_nome, 'cliente', l.cliente, 'conta', l.conta,
        'categoria', l.categoria, 'produto', l.produto, 'descricao', l.descricao, 'parcela', l.parcela, 'gerada', l.valor, 'parte', (r->>'valor')::numeric, 'papel', r->>'papel')
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

-- ============================================================
--  8.19. AGENDA COMPARTILHADA (10/11/2026, CRM 2026.11.10.2)
--     Rodar inteiro no SQL Editor do Supabase (Run without RLS).
--     Pode rodar de novo sem estragar nada.
--
--     Cada pessoa decide se compartilha a própria agenda. Ligado:
--     qualquer pessoa ativa do CRM vê as tarefas dela, só para ler
--     (as políticas de alterar e apagar não mudam). Head comercial e
--     master continuam vendo todas, como antes.
--     Próximo contato, vencimento e régua vêm da ficha do cliente e
--     seguem a regra da carteira: o colega não vê.
-- ============================================================

alter table public.profiles add column if not exists agenda_compartilhada boolean not null default false;

-- A pessoa dona da tarefa compartilha a agenda? Usada na política de leitura.
create or replace function public.agenda_compartilhada(p_user uuid)
returns boolean language plpgsql stable security definer set search_path = public as $$
begin
  if p_user is null or not public.acesso_liberado() then return false; end if;
  return coalesce((select p.agenda_compartilhada from public.profiles p
                    where p.id = p_user and p.status = 'ativo'), false);
end $$;

-- Liga ou desliga o compartilhamento da própria agenda. Só a própria.
create or replace function public.agenda_compartilhar(p_compartilhar boolean)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or not public.acesso_liberado() or not public.is_ativo() then
    raise exception 'Sessão inválida. Entre de novo.';
  end if;
  update public.profiles set agenda_compartilhada = coalesce(p_compartilhar, false) where id = auth.uid();
  return coalesce(p_compartilhar, false);
end $$;

-- Nome do cliente das tarefas que a pessoa vê por compartilhamento. Sem isto o
-- colega veria "ligar para" sem saber para quem (a ficha do cliente não é dele).
create or replace function public.agenda_clientes_compartilhados()
returns table (lead_id text, cliente text, conta text)
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null or not public.acesso_liberado() or not public.is_ativo()
     or not public.tem_permissao('ferramenta.crm') then
    return;
  end if;
  return query
    select distinct l.id, l.cliente, l.conta
      from public.tarefas t
      join public.leads l on l.id = t.lead_id
     where t.lead_id is not null
       and t.dono_id <> auth.uid()
       and public.agenda_compartilhada(t.dono_id);
end $$;

revoke all on function public.agenda_compartilhada(uuid) from public, anon;
revoke all on function public.agenda_compartilhar(boolean) from public, anon;
revoke all on function public.agenda_clientes_compartilhados() from public, anon;
grant execute on function public.agenda_compartilhada(uuid) to authenticated;
grant execute on function public.agenda_compartilhar(boolean) to authenticated;
grant execute on function public.agenda_clientes_compartilhados() to authenticated;

drop policy if exists tarefas_ler on public.tarefas;
create policy tarefas_ler on public.tarefas for select to authenticated
  using ( public.is_ativo() and (
    dono_id = auth.uid() or criado_por = auth.uid()
    or public.is_admin() or public.eh_super()
    or public.agenda_compartilhada(dono_id) ) );

-- Conferência: a coluna existe e a política nova está no lugar.
select count(*) filter (where agenda_compartilhada) as compartilhando, count(*) as pessoas from public.profiles;

-- ============================================================
--  8.20. APP AUTENTICADOR (12/11/2026, Hub 3.01)
--     Rodar inteiro no SQL Editor do Supabase (Run without RLS).
--     Pode rodar de novo sem estragar nada.
--
--     Segundo caminho para o código de acesso, que não depende de e-mail:
--     cada pessoa liga o app (Microsoft Authenticator, Google Authenticator)
--     lendo um QR code, já dentro do Hub. Daí em diante, na tela do código,
--     vale o código do e-mail OU o do app. Motivo: em 12/11/2026 o Microsoft
--     365 parou de entregar e-mail e ninguém conseguia entrar.
--
--     O código do app (TOTP, RFC 6238: HMAC-SHA1, 30 s, 6 dígitos) é conferido
--     aqui no banco, como o do e-mail. Erros contam no mesmo limite (10 em
--     30 min). Cada código do app vale uma vez só (ultimo_passo).
-- ============================================================

alter table public.acesso_registro drop constraint if exists acesso_registro_evento_check;
alter table public.acesso_registro add constraint acesso_registro_evento_check check (evento in
  ('codigo_enviado','codigo_errado','entrou','bloqueado','saiu_de_todos',
   'entrou_app','app_ativado','app_desativado','app_zerado'));

create table if not exists public.acesso_totp (
  user_id      uuid primary key references auth.users(id) on delete cascade,
  segredo      bytea not null,
  ativo        boolean not null default false,
  criado_em    timestamptz not null default now(),
  ativado_em   timestamptz,
  ultimo_passo bigint not null default 0
);
alter table public.acesso_totp enable row level security;
revoke all on public.acesso_totp from public, anon, authenticated;
drop policy if exists exige_verificacao on public.acesso_totp;
create policy exige_verificacao on public.acesso_totp as restrictive for all to authenticated
  using ((select public.acesso_liberado())) with check ((select public.acesso_liberado()));

-- Base32 (o formato que os apps leem no QR code).
create or replace function public.totp_b32(p bytea)
returns text language plpgsql immutable set search_path = public as $$
declare
  alfa text := 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  bits text := ''; saida text := ''; i int;
begin
  for i in 0 .. length(p) - 1 loop bits := bits || get_byte(p, i)::bit(8)::text; end loop;
  while length(bits) % 5 <> 0 loop bits := bits || '0'; end loop;
  for i in 0 .. length(bits) / 5 - 1 loop
    saida := saida || substr(alfa, substring(bits from i * 5 + 1 for 5)::bit(5)::int + 1, 1);
  end loop;
  return saida;
end $$;

-- O código de 6 dígitos de um passo de 30 s.
create or replace function public.totp_codigo(p_seg bytea, p_passo bigint)
returns text language plpgsql immutable set search_path = public, extensions as $$
declare h bytea; o int; v bigint;
begin
  h := hmac(int8send(p_passo), p_seg, 'sha1');
  o := get_byte(h, 19) & 15;
  v := ((get_byte(h, o) & 127)::bigint << 24) | (get_byte(h, o + 1)::bigint << 16)
     | (get_byte(h, o + 2)::bigint << 8) | get_byte(h, o + 3)::bigint;
  return lpad((v % 1000000)::text, 6, '0');
end $$;

-- Confere um código do app (aceita o passo anterior e o seguinte, pela diferença
-- de relógio) e gasta o passo: o mesmo código não entra duas vezes.
create or replace function public.totp_confere(p_user uuid, p_cod text, p_pendente boolean default false)
returns boolean language plpgsql security definer set search_path = public, extensions as $$
declare r public.acesso_totp%rowtype; agora bigint; d int; p bigint;
begin
  if p_user is null or coalesce(p_cod, '') !~ '^[0-9]{6}$' then return false; end if;
  select * into r from public.acesso_totp where user_id = p_user and ativo = not p_pendente for update;
  if not found then return false; end if;
  agora := floor(extract(epoch from clock_timestamp()) / 30)::bigint;
  for d in -1 .. 1 loop
    p := agora + d;
    if p > r.ultimo_passo and public.totp_codigo(r.segredo, p) = p_cod then
      update public.acesso_totp set ultimo_passo = p,
             ativo = true, ativado_em = case when p_pendente then now() else ativado_em end
       where user_id = p_user;
      return true;
    end if;
  end loop;
  return false;
end $$;

-- Tela de Segurança: estado do app da própria pessoa.
create or replace function public.totp_estado()
returns json language plpgsql stable security definer set search_path = public as $$
declare r public.acesso_totp%rowtype;
begin
  if auth.uid() is null or not public.acesso_liberado() then raise exception 'Sessão inválida. Entre de novo.'; end if;
  select * into r from public.acesso_totp where user_id = auth.uid();
  return json_build_object('ativo', coalesce(r.ativo, false), 'desde', r.ativado_em);
end $$;

-- Começa a ligar o app: gera o segredo e devolve o endereço do QR code.
create or replace function public.totp_iniciar()
returns json language plpgsql security definer set search_path = public, extensions as $$
declare v_seg bytea := gen_random_bytes(20); v_email text; v_b32 text;
begin
  if auth.uid() is null or not public.acesso_liberado() then raise exception 'Sessão inválida. Entre de novo.'; end if;
  if exists (select 1 from public.acesso_totp where user_id = auth.uid() and ativo) then
    raise exception 'O app autenticador já está ligado. Desligue antes de ligar em outro celular.';
  end if;
  select email into v_email from auth.users where id = auth.uid();
  insert into public.acesso_totp (user_id, segredo, ativo, criado_em, ativado_em, ultimo_passo)
  values (auth.uid(), v_seg, false, now(), null, 0)
  on conflict (user_id) do update set segredo = excluded.segredo, ativo = false, criado_em = now(), ativado_em = null, ultimo_passo = 0;
  v_b32 := public.totp_b32(v_seg);
  return json_build_object('segredo', v_b32,
    'uri', 'otpauth://totp/Hub%20Adami:' || replace(coalesce(v_email, ''), '+', '%2B') || '?secret=' || v_b32
           || '&issuer=Hub%20Adami&algorithm=SHA1&digits=6&period=30');
end $$;

-- Confirma o primeiro código lido no app: só aí o app passa a valer.
create or replace function public.totp_ativar(p_codigo text)
returns json language plpgsql security definer set search_path = public as $$
declare v_cod text := regexp_replace(coalesce(p_codigo, ''), '\D', '', 'g');
begin
  if auth.uid() is null or not public.acesso_liberado() then raise exception 'Sessão inválida. Entre de novo.'; end if;
  if (select count(*) from public.acesso_registro
       where user_id = auth.uid() and evento = 'codigo_errado' and em > now() - interval '30 minutes') >= 10 then
    return json_build_object('ok', false, 'msg', 'Muitas tentativas erradas. Espere 30 minutos.');
  end if;
  if not public.totp_confere(auth.uid(), v_cod, true) then
    insert into public.acesso_registro (user_id, evento, ip, navegador)
    values (auth.uid(), 'codigo_errado', left(split_part(public.cabecalho_req('x-forwarded-for'), ',', 1), 100), left(public.cabecalho_req('user-agent'), 300));
    return json_build_object('ok', false, 'msg', 'Código não confere. Digite o código que aparece agora no app.');
  end if;
  insert into public.acesso_registro (user_id, evento, ip, navegador)
  values (auth.uid(), 'app_ativado', left(split_part(public.cabecalho_req('x-forwarded-for'), ',', 1), 100), left(public.cabecalho_req('user-agent'), 300));
  return json_build_object('ok', true);
end $$;

-- Desliga o app da própria pessoa (celular novo, por exemplo).
create or replace function public.totp_desativar()
returns json language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or not public.acesso_liberado() then raise exception 'Sessão inválida. Entre de novo.'; end if;
  delete from public.acesso_totp where user_id = auth.uid();
  insert into public.acesso_registro (user_id, evento, ip, navegador)
  values (auth.uid(), 'app_desativado', left(split_part(public.cabecalho_req('x-forwarded-for'), ',', 1), 100), left(public.cabecalho_req('user-agent'), 300));
  return json_build_object('ok', true);
end $$;

-- Master zera o app de alguém que perdeu o celular.
create or replace function public.totp_zerar(p_user uuid)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not public.eh_super() then raise exception 'Apenas o master pode zerar o app de outra pessoa.'; end if;
  delete from public.acesso_totp where user_id = p_user;
  insert into public.acesso_registro (user_id, evento, ip, navegador)
  values (p_user, 'app_zerado', left(split_part(public.cabecalho_req('x-forwarded-for'), ',', 1), 100), left(public.cabecalho_req('user-agent'), 300));
  return json_build_object('ok', true);
end $$;

-- Tela do código: vale o código do e-mail OU o do app.
create or replace function public.verificar_codigo(p_codigo text)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare
  v_uid uuid := auth.uid();
  v_sessao uuid := public.sessao_jwt();
  v_ip text := left(split_part(public.cabecalho_req('x-forwarded-for'), ',', 1), 100);
  v_nav text := left(public.cabecalho_req('user-agent'), 300);
  v_cod text := regexp_replace(coalesce(p_codigo, ''), '\D', '', 'g');
  v_app boolean;
  v_evento text := 'entrou';
  r public.acesso_codigos%rowtype;
begin
  if v_uid is null or v_sessao is null then
    return json_build_object('ok', false, 'msg', 'Sessão inválida. Entre de novo.');
  end if;
  if (select count(*) from public.acesso_registro
       where user_id = v_uid and evento = 'codigo_errado' and em > now() - interval '30 minutes') >= 10 then
    insert into public.acesso_registro (user_id, evento, ip, navegador) values (v_uid, 'bloqueado', v_ip, v_nav);
    return json_build_object('ok', false, 'bloqueado', true,
      'msg', 'Muitas tentativas erradas. Espere 30 minutos ou peça ajuda a um master.');
  end if;
  v_app := exists (select 1 from public.acesso_totp where user_id = v_uid and ativo);

  -- 1) O código do app (12/11/2026).
  if v_app and public.totp_confere(v_uid, v_cod, false) then
    v_evento := 'entrou_app';
  else
    -- 2) Qualquer código ainda válido desta sessão, vindo por e-mail.
    select * into r from public.acesso_codigos
     where user_id = v_uid and sessao = v_sessao and usado_em is null and expira_em > now()
       and length(v_cod) = 6 and codigo_hash = encode(digest(v_cod || ':' || v_sessao::text, 'sha256'), 'hex')
     order by criado_em desc limit 1
     for update;
    if not found then
      select * into r from public.acesso_codigos
       where user_id = v_uid and sessao = v_sessao and usado_em is null and expira_em > now()
       order by criado_em desc limit 1
       for update;
      if not found then
        if v_app then
          insert into public.acesso_registro (user_id, evento, ip, navegador) values (v_uid, 'codigo_errado', v_ip, v_nav);
          return json_build_object('ok', false, 'msg', 'Código não confere. Digite o código que aparece agora no app autenticador.');
        end if;
        return json_build_object('ok', false, 'expirado', true, 'msg', 'Esse código expirou ou já foi usado. Peça um novo.');
      end if;
    end if;

    if length(v_cod) <> 6 or r.codigo_hash <> encode(digest(v_cod || ':' || v_sessao::text, 'sha256'), 'hex') then
      update public.acesso_codigos
         set tentativas = tentativas + 1,
             usado_em = case when tentativas + 1 >= 5 then now() else null end
       where id = r.id;
      insert into public.acesso_registro (user_id, evento, ip, navegador) values (v_uid, 'codigo_errado', v_ip, v_nav);
      if r.tentativas + 1 >= 5 then
        return json_build_object('ok', false, 'expirado', true, 'msg', 'Código errado 5 vezes. Peça um novo código.');
      end if;
      return json_build_object('ok', false, 'restantes', 4 - r.tentativas,
        'msg', 'Código errado. Você ainda tem ' || (4 - r.tentativas) || ' tentativa(s) com este código.');
    end if;
  end if;

  update public.acesso_codigos set usado_em = now() where user_id = v_uid and sessao = v_sessao and usado_em is null;
  insert into public.acesso_sessoes (sessao, user_id, dia, ip, navegador)
  values (v_sessao, v_uid, public.dia_brasilia(), v_ip, v_nav)
  on conflict (sessao) do update
    set dia = excluded.dia, verificado_em = now(), ip = excluded.ip, navegador = excluded.navegador
    where public.acesso_sessoes.user_id = excluded.user_id;
  insert into public.acesso_registro (user_id, evento, ip, navegador) values (v_uid, v_evento, v_ip, v_nav);
  return json_build_object('ok', true, 'dia', public.dia_brasilia());
end $$;

revoke all on function public.totp_b32(bytea) from public, anon, authenticated;
revoke all on function public.totp_codigo(bytea, bigint) from public, anon, authenticated;
revoke all on function public.totp_confere(uuid, text, boolean) from public, anon, authenticated;
revoke all on function public.totp_estado() from public, anon;
revoke all on function public.totp_iniciar() from public, anon;
revoke all on function public.totp_ativar(text) from public, anon;
revoke all on function public.totp_desativar() from public, anon;
revoke all on function public.totp_zerar(uuid) from public, anon;
revoke all on function public.verificar_codigo(text) from public, anon;
grant execute on function public.totp_estado() to authenticated;
grant execute on function public.totp_iniciar() to authenticated;
grant execute on function public.totp_ativar(text) to authenticated;
grant execute on function public.totp_desativar() to authenticated;
grant execute on function public.totp_zerar(uuid) to authenticated;
grant execute on function public.verificar_codigo(text) to authenticated;

-- Conferência: quantas pessoas já ligaram o app.
select count(*) filter (where ativo) as com_app, count(*) as total from public.acesso_totp;


-- ============================================================
-- 3.10 (12/11/2026): usabilidade.sql
-- ============================================================
-- ============================================================
-- usabilidade.sql · Hub 3.10 (12/11/2026)
--
-- Melhorias de uso pedidas pelo Emil depois do manual do Hub:
--   1. Lembrar o aparelho por 7 dias (só para quem tem o app autenticador).
--      A senha continua sendo pedida todo dia; só o código é dispensado.
--   2. Checklist do primeiro acesso na tela inicial (meu_checklist).
--   3. Reportar problema: tabela problemas + bucket privado "problemas".
--   4. Painel de adoção para o master (painel_adocao).
--
-- Como instalar: SQL Editor do Supabase, colar o arquivo inteiro, Run.
-- O aviso "Potential issues detected" é falso positivo: Run without RLS.
-- Pode rodar mais de uma vez.
-- ============================================================

-- ---------- 0. Novos eventos no registro de acessos ----------
alter table public.acesso_registro drop constraint if exists acesso_registro_evento_check;
alter table public.acesso_registro add constraint acesso_registro_evento_check check (evento in
  ('codigo_enviado','codigo_errado','entrou','bloqueado','saiu_de_todos',
   'entrou_app','app_ativado','app_desativado','app_zerado',
   'aparelho_lembrado','entrou_aparelho','aparelho_esquecido'));

-- ---------- 1. Aparelhos lembrados ----------
-- O navegador guarda um token aleatório de 256 bits; aqui fica só o hash.
-- Vale 7 dias a partir de quando foi criado (não renova sozinho) e só
-- enquanto a pessoa tiver o app autenticador ligado.
create table if not exists public.acesso_aparelhos (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  token_hash  text not null unique,
  criado_em   timestamptz not null default now(),
  expira_em   timestamptz not null,
  ultimo_uso  timestamptz,
  ip          text not null default '',
  navegador   text not null default ''
);
create index if not exists acesso_aparelhos_user_idx on public.acesso_aparelhos (user_id);
alter table public.acesso_aparelhos enable row level security;
revoke all on public.acesso_aparelhos from public, anon, authenticated;
drop policy if exists exige_verificacao on public.acesso_aparelhos;
create policy exige_verificacao on public.acesso_aparelhos as restrictive for all to authenticated
  using ( public.acesso_liberado() ) with check ( public.acesso_liberado() );

-- Cria o token deste aparelho. Só com o acesso do dia já confirmado e o app ligado.
create or replace function public.aparelho_lembrar()
returns json language plpgsql security definer set search_path = public, extensions as $$
declare
  v_uid uuid := auth.uid();
  v_token text;
  v_id uuid;
begin
  if v_uid is null or not public.acesso_liberado() then
    return json_build_object('ok', false, 'msg', 'Sessão inválida. Entre de novo.');
  end if;
  if not exists (select 1 from public.acesso_totp where user_id = v_uid and ativo) then
    return json_build_object('ok', false, 'sem_app', true,
      'msg', 'Para lembrar este aparelho, ligue antes o app autenticador em Segurança.');
  end if;
  delete from public.acesso_aparelhos where user_id = v_uid and expira_em < now();
  -- No máximo 5 aparelhos por pessoa: o mais antigo sai.
  delete from public.acesso_aparelhos where id in (
    select id from public.acesso_aparelhos where user_id = v_uid order by criado_em desc offset 4);
  v_token := encode(gen_random_bytes(32), 'hex');
  insert into public.acesso_aparelhos (user_id, token_hash, expira_em, ip, navegador)
  values (v_uid, encode(digest(v_token, 'sha256'), 'hex'), now() + interval '7 days',
          left(split_part(public.cabecalho_req('x-forwarded-for'), ',', 1), 100),
          left(public.cabecalho_req('user-agent'), 300))
  returning id into v_id;
  insert into public.acesso_registro (user_id, evento, ip, navegador)
  values (v_uid, 'aparelho_lembrado', left(split_part(public.cabecalho_req('x-forwarded-for'), ',', 1), 100), left(public.cabecalho_req('user-agent'), 300));
  return json_build_object('ok', true, 'id', v_id, 'token', v_token, 'expira_em', now() + interval '7 days');
end $$;

-- Depois da senha: se o token deste aparelho vale, libera a sessão sem código.
-- Usa as mesmas travas da verificar_codigo (bloqueio por erros).
create or replace function public.aparelho_entrar(p_token text)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare
  v_uid uuid := auth.uid();
  v_sessao uuid := public.sessao_jwt();
  v_ip text := left(split_part(public.cabecalho_req('x-forwarded-for'), ',', 1), 100);
  v_nav text := left(public.cabecalho_req('user-agent'), 300);
  v_id uuid;
begin
  if v_uid is null or v_sessao is null or coalesce(p_token, '') !~ '^[0-9a-f]{64}$' then
    return json_build_object('ok', false);
  end if;
  if (select count(*) from public.acesso_registro
       where user_id = v_uid and evento = 'codigo_errado' and em > now() - interval '30 minutes') >= 10 then
    return json_build_object('ok', false);
  end if;
  select a.id into v_id from public.acesso_aparelhos a
   where a.user_id = v_uid and a.token_hash = encode(digest(p_token, 'sha256'), 'hex') and a.expira_em > now()
     and exists (select 1 from public.acesso_totp t where t.user_id = v_uid and t.ativo);
  if v_id is null then return json_build_object('ok', false); end if;
  update public.acesso_aparelhos set ultimo_uso = now(), ip = v_ip, navegador = v_nav where id = v_id;
  insert into public.acesso_sessoes (sessao, user_id, dia, ip, navegador)
  values (v_sessao, v_uid, public.dia_brasilia(), v_ip, v_nav)
  on conflict (sessao) do update
    set dia = excluded.dia, verificado_em = now(), ip = excluded.ip, navegador = excluded.navegador
    where public.acesso_sessoes.user_id = excluded.user_id;
  insert into public.acesso_registro (user_id, evento, ip, navegador) values (v_uid, 'entrou_aparelho', v_ip, v_nav);
  return json_build_object('ok', true, 'dia', public.dia_brasilia());
end $$;

-- Lista dos aparelhos lembrados da própria pessoa (tela Segurança).
drop function if exists public.aparelhos_meus();
create function public.aparelhos_meus()
returns table (id uuid, criado_em timestamptz, expira_em timestamptz, ultimo_uso timestamptz, navegador text, ip text)
language sql stable security definer set search_path = public as $$
  select a.id, a.criado_em, a.expira_em, a.ultimo_uso, a.navegador, a.ip
    from public.acesso_aparelhos a
   where a.user_id = auth.uid() and a.expira_em > now() and public.acesso_liberado()
   order by a.criado_em desc;
$$;

-- Esquece um aparelho (p_id) ou todos (p_id nulo).
create or replace function public.aparelho_esquecer(p_id uuid default null)
returns json language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or not public.acesso_liberado() then raise exception 'Sessão inválida. Entre de novo.'; end if;
  delete from public.acesso_aparelhos where user_id = auth.uid() and (p_id is null or id = p_id);
  insert into public.acesso_registro (user_id, evento, ip, navegador)
  values (auth.uid(), 'aparelho_esquecido', left(split_part(public.cabecalho_req('x-forwarded-for'), ',', 1), 100), left(public.cabecalho_req('user-agent'), 300));
  return json_build_object('ok', true);
end $$;

-- "Sair de todos os aparelhos" também esquece os aparelhos lembrados.
create or replace function public.registrar_saida_geral()
returns void language sql security definer set search_path = public as $$
  delete from public.acesso_aparelhos where user_id = auth.uid() and public.acesso_liberado();
  insert into public.acesso_registro (user_id, evento, ip, navegador)
  select auth.uid(), 'saiu_de_todos',
         left(split_part(public.cabecalho_req('x-forwarded-for'), ',', 1), 100),
         left(public.cabecalho_req('user-agent'), 300)
  where auth.uid() is not null and public.acesso_liberado();
$$;

-- Desligar o app (ou o master zerar) também esquece os aparelhos.
create or replace function public.totp_desativar()
returns json language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or not public.acesso_liberado() then raise exception 'Sessão inválida. Entre de novo.'; end if;
  delete from public.acesso_totp where user_id = auth.uid();
  delete from public.acesso_aparelhos where user_id = auth.uid();
  insert into public.acesso_registro (user_id, evento, ip, navegador)
  values (auth.uid(), 'app_desativado', left(split_part(public.cabecalho_req('x-forwarded-for'), ',', 1), 100), left(public.cabecalho_req('user-agent'), 300));
  return json_build_object('ok', true);
end $$;

create or replace function public.totp_zerar(p_user uuid)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not public.eh_super() then raise exception 'Apenas o master pode zerar o app de outra pessoa.'; end if;
  delete from public.acesso_totp where user_id = p_user;
  delete from public.acesso_aparelhos where user_id = p_user;
  insert into public.acesso_registro (user_id, evento, ip, navegador)
  values (p_user, 'app_zerado', left(split_part(public.cabecalho_req('x-forwarded-for'), ',', 1), 100), left(public.cabecalho_req('user-agent'), 300));
  return json_build_object('ok', true);
end $$;

-- ---------- 2. Checklist do primeiro acesso ----------
create or replace function public.meu_checklist()
returns json language plpgsql stable security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null or not public.acesso_liberado() then return null; end if;
  return json_build_object(
    'app', exists (select 1 from public.acesso_totp where user_id = v_uid and ativo),
    'atividade', exists (select 1 from public.leads l
                          where l.responsavel_id = v_uid and not coalesce(l.excluido, false)
                            and jsonb_typeof(l.atividades) = 'array' and jsonb_array_length(l.atividades) > 0),
    'jornada', (select count(*) from public.leads l
                 where l.responsavel_id = v_uid and l.esteira = 'novo'
                   and not coalesce(l.excluido, false) and not coalesce(l.perdido, false) and not coalesce(l.ganho, false)),
    'jornada_sem_contato', (select count(*) from public.leads l
                 where l.responsavel_id = v_uid and l.esteira = 'novo'
                   and not coalesce(l.excluido, false) and not coalesce(l.perdido, false) and not coalesce(l.ganho, false)
                   and l.proximo_contato is null),
    'aparelho', exists (select 1 from public.acesso_aparelhos where user_id = v_uid and expira_em > now()));
end $$;

-- ---------- 3. Reportar problema ----------
create table if not exists public.problemas (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null default auth.uid() references auth.users(id) on delete cascade,
  criado_em     timestamptz not null default now(),
  modulo        text not null default '' check (length(modulo) <= 80),
  versao        text not null default '' check (length(versao) <= 80),
  url           text not null default '' check (length(url) <= 500),
  navegador     text not null default '' check (length(navegador) <= 400),
  tela          text not null default '' check (length(tela) <= 40),
  texto         text not null check (length(texto) between 3 and 4000),
  erros         jsonb not null default '[]'::jsonb,
  print_caminho text,
  resolvido_em  timestamptz,
  resolvido_por uuid references auth.users(id) on delete set null
);
create index if not exists problemas_criado_idx on public.problemas (criado_em desc);
alter table public.problemas enable row level security;
revoke all on public.problemas from public, anon, authenticated;
grant select, insert on public.problemas to authenticated;
drop policy if exists exige_verificacao on public.problemas;
create policy exige_verificacao on public.problemas as restrictive for all to authenticated
  using ( public.acesso_liberado() ) with check ( public.acesso_liberado() );
drop policy if exists problemas_criar on public.problemas;
create policy problemas_criar on public.problemas for insert to authenticated
  with check ( user_id = auth.uid() and resolvido_em is null and resolvido_por is null );
drop policy if exists problemas_ler on public.problemas;
create policy problemas_ler on public.problemas for select to authenticated
  using ( user_id = auth.uid() or public.eh_super() );

-- Lista para o master, com o nome de quem reportou.
drop function if exists public.problemas_lista();
create function public.problemas_lista()
returns table (id uuid, criado_em timestamptz, nome text, email text, modulo text, versao text, url text,
               navegador text, tela text, texto text, erros jsonb, print_caminho text, resolvido_em timestamptz)
language sql stable security definer set search_path = public as $$
  select pr.id, pr.criado_em, coalesce(p.nome, ''), coalesce(u.email::text, ''), pr.modulo, pr.versao, pr.url,
         pr.navegador, pr.tela, pr.texto, pr.erros, pr.print_caminho, pr.resolvido_em
    from public.problemas pr
    left join public.perfis p on p.user_id = pr.user_id
    left join auth.users u on u.id = pr.user_id
   where public.eh_super()
   order by (pr.resolvido_em is null) desc, pr.criado_em desc
   limit 200;
$$;

create or replace function public.problema_resolver(p_id uuid, p_resolvido boolean default true)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not public.eh_super() then raise exception 'Apenas o master marca problema como resolvido.'; end if;
  update public.problemas
     set resolvido_em = case when p_resolvido then now() end,
         resolvido_por = case when p_resolvido then auth.uid() end
   where id = p_id;
  return json_build_object('ok', true);
end $$;

-- Prints dos problemas: bucket privado; cada um grava na própria pasta, o master lê tudo.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('problemas', 'problemas', false, 4194304, array['image/jpeg','image/png'])
on conflict (id) do update set public = false, file_size_limit = 4194304, allowed_mime_types = array['image/jpeg','image/png'];
drop policy if exists problemas_print_enviar on storage.objects;
create policy problemas_print_enviar on storage.objects for insert to authenticated
  with check ( bucket_id = 'problemas' and (storage.foldername(name))[1] = auth.uid()::text );
drop policy if exists problemas_print_ler on storage.objects;
create policy problemas_print_ler on storage.objects for select to authenticated
  using ( bucket_id = 'problemas' and ((storage.foldername(name))[1] = auth.uid()::text or public.eh_super()) );

-- ---------- 4. Painel de adoção (só master) ----------
drop function if exists public.painel_adocao();
create function public.painel_adocao()
returns table (user_id uuid, nome text, email text, papel text, ativo boolean, app boolean, aparelhos int,
               ultimo_acesso timestamptz, dias_acesso_30 int, atividades_30 int, clientes int,
               jornada int, jornada_sem_contato int, contatos_atrasados int, tarefas_atrasadas int)
language sql stable security definer set search_path = public as $$
  with gente as (
    select p.user_id, coalesce(nullif(p.nome, ''), pr.nome, '') as nome, u.email::text as email,
           coalesce(pr.role, case when p.super then 'master' when p.admin then 'administrador' else '' end) as papel,
           coalesce(pr.status, 'ativo') = 'ativo' as ativo
      from public.perfis p
      join auth.users u on u.id = p.user_id
      left join public.profiles pr on pr.id = p.user_id
  ), ld as (
    select l.responsavel_id as uid,
           count(*) filter (where not coalesce(l.perdido, false)) as clientes,
           count(*) filter (where l.esteira = 'novo' and not coalesce(l.perdido, false) and not coalesce(l.ganho, false)) as jornada,
           count(*) filter (where l.esteira = 'novo' and not coalesce(l.perdido, false) and not coalesce(l.ganho, false) and l.proximo_contato is null) as jornada_sem_contato,
           count(*) filter (where not coalesce(l.perdido, false) and l.proximo_contato < public.dia_brasilia()) as atrasados,
           sum((select count(*) from jsonb_array_elements(case when jsonb_typeof(l.atividades) = 'array' then l.atividades else '[]'::jsonb end) a
                 where (a->>'data') ~ '^\d{4}-\d{2}-\d{2}' and left(a->>'data', 10)::date >= public.dia_brasilia() - 30)) as ativ30
      from public.leads l
     where not coalesce(l.excluido, false)
     group by l.responsavel_id
  ), ac as (
    select r.user_id as uid, max(r.em) as ultimo,
           count(distinct (r.em at time zone 'America/Sao_Paulo')::date) filter (where r.em > now() - interval '30 days') as dias
      from public.acesso_registro r
     where r.evento in ('entrou', 'entrou_app', 'entrou_aparelho')
     group by r.user_id
  ), tf as (
    select t.dono_id as uid, count(*) as atrasadas
      from public.tarefas t
     where t.repeticao = 'nao' and t.data < public.dia_brasilia() and coalesce(array_length(t.concluidas, 1), 0) = 0
     group by t.dono_id
  )
  select g.user_id, g.nome, g.email, g.papel, g.ativo,
         exists (select 1 from public.acesso_totp t where t.user_id = g.user_id and t.ativo),
         (select count(*)::int from public.acesso_aparelhos a where a.user_id = g.user_id and a.expira_em > now()),
         ac.ultimo, coalesce(ac.dias, 0)::int, coalesce(ld.ativ30, 0)::int, coalesce(ld.clientes, 0)::int,
         coalesce(ld.jornada, 0)::int, coalesce(ld.jornada_sem_contato, 0)::int, coalesce(ld.atrasados, 0)::int,
         coalesce(tf.atrasadas, 0)::int
    from gente g
    left join ld on ld.uid = g.user_id
    left join ac on ac.uid = g.user_id
    left join tf on tf.uid = g.user_id
   where public.eh_super()
   order by g.ativo desc, g.nome;
$$;

-- ---------- 4b. Origens novas dos arquivos da ficha ----------
-- Liberdade Financeira, Ágio, Boletas e o Relatório Consolidado também gravam na ficha.
alter table public.anexos drop constraint if exists anexos_origem_check;
alter table public.anexos add constraint anexos_origem_check check (origem in
  ('upload','wealth_planning','plano_patrimonial','enquadramento','liberdade','agio','boletas','relatorio'));

-- ---------- 5. Permissões das funções ----------
revoke all on function public.aparelho_lembrar() from public, anon;
revoke all on function public.aparelho_entrar(text) from public, anon;
revoke all on function public.aparelhos_meus() from public, anon;
revoke all on function public.aparelho_esquecer(uuid) from public, anon;
revoke all on function public.meu_checklist() from public, anon;
revoke all on function public.problemas_lista() from public, anon;
revoke all on function public.problema_resolver(uuid, boolean) from public, anon;
revoke all on function public.painel_adocao() from public, anon;
grant execute on function public.aparelho_lembrar() to authenticated;
grant execute on function public.aparelho_entrar(text) to authenticated;
grant execute on function public.aparelhos_meus() to authenticated;
grant execute on function public.aparelho_esquecer(uuid) to authenticated;
grant execute on function public.meu_checklist() to authenticated;
grant execute on function public.problemas_lista() to authenticated;
grant execute on function public.problema_resolver(uuid, boolean) to authenticated;
grant execute on function public.painel_adocao() to authenticated;

-- Conferência
select (select count(*) from public.acesso_aparelhos) as aparelhos,
       (select count(*) from public.problemas) as problemas,
       (select count(*) from storage.buckets where id = 'problemas') as bucket_problemas;


-- ============================================================
-- 3.11 (12/11/2026): carteiras_feito.sql
-- ============================================================
-- ============================================================
-- carteiras_feito.sql · Hub 3.11 (12/11/2026)
--
-- Carteiras: "Marcar mês como feito". Cada lançamento (cliente + mês) ganha a data
-- em que foi dado como pronto e quem marcou. O "quem" é carimbado aqui no banco
-- (auth.uid()), nunca vem da tela. Quem pode gravar continua sendo quem já podia
-- gravar lançamentos (políticas lanc_inserir / lanc_alterar: eh_admin()).
--
-- Como instalar: SQL Editor do Supabase, colar o arquivo inteiro, Run.
-- O aviso "Potential issues detected" é falso positivo: Run without RLS.
-- Pode rodar mais de uma vez.
-- ============================================================

alter table public.lancamentos add column if not exists feito_em  timestamptz;
alter table public.lancamentos add column if not exists feito_por uuid references auth.users(id) on delete set null;

create or replace function public.lancamentos_carimba_feito()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    new.feito_por := case when new.feito_em is null then null else auth.uid() end;
  elsif new.feito_em is distinct from old.feito_em then
    new.feito_por := case when new.feito_em is null then null else auth.uid() end;
  else
    new.feito_por := old.feito_por;
  end if;
  return new;
end $$;
revoke all on function public.lancamentos_carimba_feito() from public, anon, authenticated;

drop trigger if exists lancamentos_carimba_feito_trg on public.lancamentos;
create trigger lancamentos_carimba_feito_trg before insert or update on public.lancamentos
  for each row execute function public.lancamentos_carimba_feito();

-- Conferência
select count(*) as lancamentos, count(feito_em) as feitos from public.lancamentos;


-- ============================================================
-- 3.20 (12/11/2026): carteiras_envio.sql
-- ============================================================
-- ============================================================
-- carteiras_envio.sql · Hub 3.20 (12/11/2026)
--
-- 1. clientes.lead_id: a carteira ligada à ficha do CRM (escolhida na tela; ao ligar,
--    a conta do BTG da ficha entra em contas_btg). Substitui a ligação pelo nome, que
--    errava: clientes cadastrados pelo primeiro nome batem com vários cartões.
-- 2. clientes.emails_relatorio: para quem vai o Relatório Consolidado.
-- 3. relatorios_envios + funções: o envio sai pela função relatorio-enviar (caixa
--    hub@adamicaptal.com.br). Os destinatários vêm daqui, nunca da tela, e só com o mês
--    marcado como feito. Cada envio fica registrado.
--
-- Como instalar: SQL Editor do Supabase, colar o arquivo inteiro, Run.
-- O aviso "Potential issues detected" é falso positivo: Run without RLS.
-- Pode rodar mais de uma vez.
-- ============================================================

alter table public.clientes add column if not exists lead_id text references public.leads(id) on delete set null;
alter table public.clientes add column if not exists emails_relatorio text[] not null default '{}';
create index if not exists clientes_lead_idx on public.clientes (lead_id);
alter table public.clientes drop constraint if exists clientes_emails_relatorio_check;
alter table public.clientes add constraint clientes_emails_relatorio_check check (
  coalesce(array_length(emails_relatorio, 1), 0) <= 5);

create table if not exists public.relatorios_envios (
  id          uuid primary key default gen_random_uuid(),
  cliente_id  uuid not null references public.clientes(id) on delete cascade,
  mes         smallint not null check (mes between 1 and 12),
  ano         smallint not null,
  para        text[] not null default '{}',
  enviado_por uuid references auth.users(id) on delete set null,
  enviado_em  timestamptz not null default now(),
  erro        text
);
create index if not exists relatorios_envios_cli_idx on public.relatorios_envios (cliente_id, ano, mes, enviado_em desc);
alter table public.relatorios_envios enable row level security;
revoke all on public.relatorios_envios from public, anon, authenticated;
grant select on public.relatorios_envios to authenticated;
drop policy if exists exige_verificacao on public.relatorios_envios;
create policy exige_verificacao on public.relatorios_envios as restrictive for all to authenticated
  using ( public.acesso_liberado() ) with check ( public.acesso_liberado() );
drop policy if exists envios_ler on public.relatorios_envios;
create policy envios_ler on public.relatorios_envios for select to authenticated
  using ( public.meu_cliente(cliente_id) or public.eh_admin() );

-- Prepara o envio: confere quem pede, o mês feito e devolve destinatários e assessor.
create or replace function public.relatorio_envio_preparar(p_cliente uuid, p_mes int, p_ano int)
returns json language plpgsql stable security definer set search_path = public as $$
declare
  c record; l record; v_assessor text; v_assessor_email text;
begin
  if auth.uid() is null or not public.acesso_liberado() then raise exception 'Sessão inválida. Entre de novo.'; end if;
  if not (public.meu_cliente(p_cliente) or public.eh_admin()) then raise exception 'Você não tem acesso a este cliente.'; end if;
  select * into c from public.clientes where id = p_cliente;
  if not found then raise exception 'Cliente não encontrado.'; end if;
  select * into l from public.lancamentos where cliente_id = p_cliente and mes = p_mes and ano = p_ano;
  if not found then raise exception 'Este mês ainda não foi lançado.'; end if;
  if l.feito_em is null then raise exception 'Marque o mês como feito antes de enviar ao cliente.'; end if;
  if coalesce(array_length(c.emails_relatorio, 1), 0) = 0 then raise exception 'Cadastre o e-mail para relatórios deste cliente.'; end if;
  select p.nome, u.email::text into v_assessor, v_assessor_email
    from auth.users u left join public.perfis p on p.user_id = u.id where u.id = c.assessor_id;
  return json_build_object('cliente', c.nome, 'para', c.emails_relatorio,
    'assessor', coalesce(v_assessor, ''), 'assessor_email', coalesce(v_assessor_email, ''),
    'eu_email', (select email::text from auth.users where id = auth.uid()),
    'eu_nome', (select nome from public.perfis where user_id = auth.uid()));
end $$;

create or replace function public.relatorio_envio_registrar(p_cliente uuid, p_mes int, p_ano int, p_para text[], p_erro text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or not public.acesso_liberado() then raise exception 'Sessão inválida.'; end if;
  if not (public.meu_cliente(p_cliente) or public.eh_admin()) then raise exception 'Sem acesso.'; end if;
  insert into public.relatorios_envios (cliente_id, mes, ano, para, enviado_por, erro)
  values (p_cliente, p_mes, p_ano, coalesce(p_para, '{}'), auth.uid(), left(p_erro, 400));
end $$;

revoke all on function public.relatorio_envio_preparar(uuid, int, int) from public, anon;
revoke all on function public.relatorio_envio_registrar(uuid, int, int, text[], text) from public, anon;
grant execute on function public.relatorio_envio_preparar(uuid, int, int) to authenticated;
grant execute on function public.relatorio_envio_registrar(uuid, int, int, text[], text) to authenticated;

-- Conferência
select count(*) filter (where lead_id is not null) as ligados, count(*) as clientes from public.clientes;


-- ============================================================
-- 3.26 (13/11/2026): seguranca_326.sql
-- ============================================================
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


-- ============================================================
-- 3.27 (13/11/2026): seguranca_327.sql
-- ============================================================
-- ============================================================
-- seguranca_327.sql · Hub 3.27 (13/11/2026)
--
-- Decisões do Emil depois da varredura de segurança (seção 30):
-- 1. Convites só para domínios liberados. Começa com adamicaptal.com.br; o master inclui
--    outros (tabela convites_dominios). Vale para convidar e para trocar o e-mail de alguém.
-- 2. App autenticador obrigatório para master e financeiro. Quem ainda não ligou o app
--    entra pelo código do e-mail uma última vez e o Hub obriga a ligar. Com o app ligado,
--    o código do e-mail deixa de valer para essas pessoas (não é enviado nem aceito).
--
-- Como instalar: SQL Editor do Supabase, colar o arquivo inteiro, Run.
-- O aviso "Potential issues detected" é falso positivo: Run without RLS.
-- Pode rodar mais de uma vez.
-- ============================================================

-- ---------- 1. Domínios liberados para convite ----------
create table if not exists public.convites_dominios (
  dominio    text primary key check (dominio ~ '^[a-z0-9.-]+\.[a-z]{2,}$'),
  criado_em  timestamptz not null default now(),
  criado_por uuid references auth.users(id) on delete set null
);
insert into public.convites_dominios (dominio) values ('adamicaptal.com.br') on conflict do nothing;
alter table public.convites_dominios enable row level security;
revoke all on public.convites_dominios from public, anon, authenticated;
grant select, insert, delete on public.convites_dominios to authenticated;
drop policy if exists exige_verificacao on public.convites_dominios;
create policy exige_verificacao on public.convites_dominios as restrictive for all to authenticated
  using ((select public.acesso_liberado())) with check ((select public.acesso_liberado()));
drop policy if exists dominios_master on public.convites_dominios;
create policy dominios_master on public.convites_dominios for all to authenticated
  using ((select public.eh_super())) with check ((select public.eh_super()));

create or replace function public.dominio_liberado(p_email text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.convites_dominios
                  where dominio = lower(split_part(btrim(coalesce(p_email, '')), '@', 2)));
$$;
revoke all on function public.dominio_liberado(text) from public, anon, authenticated;

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
  if lower(btrim(coalesce(p_email,''))) !~ '^[^\s@<>",;]+@[^\s@<>",;]+\.[^\s@<>",;]+$' then
    raise exception 'E-mail invalido.';
  end if;
  if not public.dominio_liberado(p_email) then
    raise exception 'O domínio @% não está liberado para convites. Confira se o e-mail está certo; se estiver, libere o domínio em Equipe > Domínios.',
      lower(split_part(p_email, '@', 2));
  end if;
  if exists (select 1 from auth.users u where lower(u.email) = lower(p_email)) then
    raise exception 'Ja existe conta com este e-mail. Use a tela de Equipe para ajustar os acessos.';
  end if;

  insert into public.convites (email, nome, role, produtos, master, admin, mesa_rv, financeiro, convidado_por)
  values (lower(btrim(p_email)), p_nome, p_role, coalesce(p_produtos,'{}'),
          p_master, p_admin, p_mesa_rv, coalesce(p_financeiro,false), auth.uid())
  on conflict (email) do update
    set nome=excluded.nome, role=excluded.role, produtos=excluded.produtos,
        master=excluded.master, admin=excluded.admin, mesa_rv=excluded.mesa_rv,
        financeiro=excluded.financeiro, convidado_por=excluded.convidado_por, criado_em=now(),
        consumido_em=null;

  insert into public.auditoria(usuario, acao, alvo, detalhe)
  values (coalesce(auth.jwt() ->> 'email','?'), 'convite', lower(p_email),
          'papel CRM '||p_role||case when p_master then ', master' else '' end
          ||case when coalesce(p_financeiro,false) then ', financeiro' else '' end);
end $$;
revoke all on function public.convidar(text,text,text,boolean,boolean,boolean,text[],boolean) from public, anon;
grant execute on function public.convidar(text,text,text,boolean,boolean,boolean,text[],boolean) to authenticated;

create or replace function public.equipe_editar(p_user_id uuid, p_nome text, p_email text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_nome text := btrim(coalesce(p_nome, ''));
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_antigo text;
  v_quem text := coalesce(auth.jwt() ->> 'email', '?');
begin
  if not public.eh_super() then raise exception 'Apenas o master pode editar a equipe.'; end if;
  select email into v_antigo from auth.users where id = p_user_id;
  if v_antigo is null then raise exception 'Pessoa não encontrada.'; end if;
  if char_length(v_nome) < 2 or char_length(v_nome) > 80 then raise exception 'O nome precisa ter entre 2 e 80 letras.'; end if;
  if v_email !~ '^[^\s@<>",;]+@[^\s@<>",;]+\.[^\s@<>",;]+$' or char_length(v_email) > 200 then
    raise exception 'E-mail inválido.';
  end if;

  update public.perfis set nome = v_nome where user_id = p_user_id;
  update public.profiles set nome = v_nome where id = p_user_id;

  if v_email <> lower(v_antigo) then
    if not public.dominio_liberado(v_email) then
      raise exception 'O domínio @% não está liberado. Libere em Equipe > Domínios antes de trocar o e-mail.', split_part(v_email, '@', 2);
    end if;
    if exists (select 1 from auth.users where lower(email) = v_email and id <> p_user_id) then
      raise exception 'Já existe outra conta com o e-mail %.', v_email;
    end if;
    update auth.users set email = v_email, email_confirmed_at = coalesce(email_confirmed_at, now()), updated_at = now()
     where id = p_user_id;
    update auth.identities set identity_data = identity_data || jsonb_build_object('email', v_email), updated_at = now()
     where user_id = p_user_id and provider = 'email';
    update public.convites set email = v_email where email = lower(v_antigo);
    insert into public.auditoria (usuario, acao, alvo, detalhe)
    values (v_quem, 'trocou e-mail', v_antigo, 'novo: ' || v_email);
  end if;
  insert into public.auditoria (usuario, acao, alvo, detalhe) values (v_quem, 'editou pessoa', v_email, 'nome: ' || v_nome);
end $$;
revoke all on function public.equipe_editar(uuid, text, text) from public, anon;
grant execute on function public.equipe_editar(uuid, text, text) to authenticated;

-- Lista e altera os domínios (tela Equipe, só master).
create or replace function public.dominios_lista()
returns setof text language sql stable security definer set search_path = public as $$
  select dominio from public.convites_dominios where public.eh_super() order by dominio;
$$;
create or replace function public.dominio_salvar(p_dominio text, p_liberar boolean)
returns void language plpgsql security definer set search_path = public as $$
declare v text := lower(btrim(coalesce(p_dominio, ''))); v_quem text := coalesce(auth.jwt() ->> 'email', '?');
begin
  if not public.eh_super() then raise exception 'Apenas o master libera domínios.'; end if;
  v := regexp_replace(v, '^@', '');
  if v !~ '^[a-z0-9.-]+\.[a-z]{2,}$' then raise exception 'Domínio inválido. Exemplo: adamicaptal.com.br'; end if;
  if p_liberar then
    insert into public.convites_dominios (dominio, criado_por) values (v, auth.uid()) on conflict do nothing;
  else
    if v = 'adamicaptal.com.br' then raise exception 'O domínio da Adami não pode ser retirado.'; end if;
    delete from public.convites_dominios where dominio = v;
  end if;
  insert into public.auditoria (usuario, acao, alvo, detalhe)
  values (v_quem, case when p_liberar then 'liberou domínio' else 'retirou domínio' end, v, '');
end $$;
revoke all on function public.dominios_lista() from public, anon;
revoke all on function public.dominio_salvar(text, boolean) from public, anon;
grant execute on function public.dominios_lista() to authenticated;
grant execute on function public.dominio_salvar(text, boolean) to authenticated;

-- ---------- 2. App autenticador obrigatório para master e financeiro ----------
create or replace function public.exige_app(p_user uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.perfis p
                  where p.user_id = p_user
                    and (coalesce(p.super, false) or coalesce(p.financeiro, false)));
$$;
revoke all on function public.exige_app(uuid) from public, anon, authenticated;

-- Para a tela: se esta pessoa precisa do app e se ele já está ligado.
create or replace function public.app_obrigatorio()
returns json language sql stable security definer set search_path = public as $$
  select json_build_object(
    'obrigatorio', public.exige_app(auth.uid()),
    'ativo', exists (select 1 from public.acesso_totp where user_id = auth.uid() and ativo))
  where auth.uid() is not null;
$$;
revoke all on function public.app_obrigatorio() from public, anon;
grant execute on function public.app_obrigatorio() to authenticated;

-- Código por e-mail: não sai para quem é obrigado a usar o app e já ligou.
create or replace function public.acesso_novo_codigo(p_user uuid, p_sessao uuid, p_ip text default '', p_navegador text default '')
returns text language plpgsql security definer set search_path = public, extensions as $$
declare
  v_codigo text;
  v_ultimo timestamptz;
begin
  if p_user is null or p_sessao is null then
    raise exception 'Sessão inválida. Entre de novo.';
  end if;
  if public.exige_app(p_user) and exists (select 1 from public.acesso_totp where user_id = p_user and ativo) then
    raise exception 'Para master e financeiro, o código vem só do app autenticador. Abra o app no celular e digite o código que aparece nele.';
  end if;
  if (select count(*) from public.acesso_registro
       where user_id = p_user and evento = 'codigo_errado' and em > now() - interval '30 minutes') >= 10 then
    raise exception 'Muitas tentativas erradas. Espere 30 minutos ou peça ajuda a um master.';
  end if;
  select max(criado_em) into v_ultimo from public.acesso_codigos where user_id = p_user;
  if v_ultimo > now() - interval '30 seconds' then
    raise exception 'Acabamos de mandar um código. Espere 30 segundos antes de pedir outro.';
  end if;
  if (select count(*) from public.acesso_codigos where user_id = p_user and criado_em > now() - interval '1 hour') >= 8 then
    raise exception 'Muitos códigos pedidos na última hora. Tente de novo mais tarde.';
  end if;
  v_codigo := lpad(((('x' || encode(gen_random_bytes(4), 'hex'))::bit(32)::bigint) % 1000000)::text, 6, '0');
  insert into public.acesso_codigos (user_id, sessao, codigo_hash, expira_em, ip, navegador)
  values (p_user, p_sessao, encode(digest(v_codigo || ':' || p_sessao::text, 'sha256'), 'hex'),
          now() + interval '10 minutes', left(coalesce(p_ip, ''), 100), left(coalesce(p_navegador, ''), 300));
  insert into public.acesso_registro (user_id, evento, ip, navegador)
  values (p_user, 'codigo_enviado', left(coalesce(p_ip, ''), 100), left(coalesce(p_navegador, ''), 300));
  return v_codigo;
end $$;
revoke all on function public.acesso_novo_codigo(uuid, uuid, text, text) from public, anon, authenticated;

-- Conferência do código: para quem é obrigado e tem o app ligado, só o código do app vale.
create or replace function public.verificar_codigo(p_codigo text)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare
  v_uid uuid := auth.uid();
  v_sessao uuid := public.sessao_jwt();
  v_ip text := left(split_part(public.cabecalho_req('x-forwarded-for'), ',', 1), 100);
  v_nav text := left(public.cabecalho_req('user-agent'), 300);
  v_cod text := regexp_replace(coalesce(p_codigo, ''), '\D', '', 'g');
  v_app boolean;
  v_so_app boolean;
  v_evento text := 'entrou';
  r public.acesso_codigos%rowtype;
begin
  if v_uid is null or v_sessao is null then
    return json_build_object('ok', false, 'msg', 'Sessão inválida. Entre de novo.');
  end if;
  if (select count(*) from public.acesso_registro
       where user_id = v_uid and evento = 'codigo_errado' and em > now() - interval '30 minutes') >= 10 then
    insert into public.acesso_registro (user_id, evento, ip, navegador) values (v_uid, 'bloqueado', v_ip, v_nav);
    return json_build_object('ok', false, 'bloqueado', true,
      'msg', 'Muitas tentativas erradas. Espere 30 minutos ou peça ajuda a um master.');
  end if;
  v_app := exists (select 1 from public.acesso_totp where user_id = v_uid and ativo);
  v_so_app := v_app and public.exige_app(v_uid);

  if v_app and public.totp_confere(v_uid, v_cod, false) then
    v_evento := 'entrou_app';
  elsif v_so_app then
    insert into public.acesso_registro (user_id, evento, ip, navegador) values (v_uid, 'codigo_errado', v_ip, v_nav);
    return json_build_object('ok', false, 'msg', 'Código não confere. Para master e financeiro vale só o código do app autenticador: digite o que aparece agora no app.');
  else
    select * into r from public.acesso_codigos
     where user_id = v_uid and sessao = v_sessao and usado_em is null and expira_em > now()
       and length(v_cod) = 6 and codigo_hash = encode(digest(v_cod || ':' || v_sessao::text, 'sha256'), 'hex')
     order by criado_em desc limit 1
     for update;
    if not found then
      select * into r from public.acesso_codigos
       where user_id = v_uid and sessao = v_sessao and usado_em is null and expira_em > now()
       order by criado_em desc limit 1
       for update;
      if not found then
        if v_app then
          insert into public.acesso_registro (user_id, evento, ip, navegador) values (v_uid, 'codigo_errado', v_ip, v_nav);
          return json_build_object('ok', false, 'msg', 'Código não confere. Digite o código que aparece agora no app autenticador.');
        end if;
        return json_build_object('ok', false, 'expirado', true, 'msg', 'Esse código expirou ou já foi usado. Peça um novo.');
      end if;
    end if;

    if length(v_cod) <> 6 or r.codigo_hash <> encode(digest(v_cod || ':' || v_sessao::text, 'sha256'), 'hex') then
      update public.acesso_codigos
         set tentativas = tentativas + 1,
             usado_em = case when tentativas + 1 >= 5 then now() else null end
       where id = r.id;
      insert into public.acesso_registro (user_id, evento, ip, navegador) values (v_uid, 'codigo_errado', v_ip, v_nav);
      if r.tentativas + 1 >= 5 then
        return json_build_object('ok', false, 'expirado', true, 'msg', 'Código errado 5 vezes. Peça um novo código.');
      end if;
      return json_build_object('ok', false, 'restantes', 4 - r.tentativas,
        'msg', 'Código errado. Você ainda tem ' || (4 - r.tentativas) || ' tentativa(s) com este código.');
    end if;
  end if;

  update public.acesso_codigos set usado_em = now() where user_id = v_uid and sessao = v_sessao and usado_em is null;
  insert into public.acesso_sessoes (sessao, user_id, dia, ip, navegador)
  values (v_sessao, v_uid, public.dia_brasilia(), v_ip, v_nav)
  on conflict (sessao) do update
    set dia = excluded.dia, verificado_em = now(), ip = excluded.ip, navegador = excluded.navegador
    where public.acesso_sessoes.user_id = excluded.user_id;
  insert into public.acesso_registro (user_id, evento, ip, navegador) values (v_uid, v_evento, v_ip, v_nav);
  return json_build_object('ok', true, 'dia', public.dia_brasilia());
end $$;
revoke all on function public.verificar_codigo(text) from public, anon;
grant execute on function public.verificar_codigo(text) to authenticated;

-- Conferência
select (select count(*) from public.convites_dominios) as dominios,
       (select count(*) from public.perfis p where public.exige_app(p.user_id)) as pessoas_com_app_obrigatorio;


-- ============================================================
-- seguranca_328.sql · Hub 3.28 (13/11/2026)
--
-- O Emil quer o código de entrada pelos dois caminhos: e-mail E app no celular.
-- Desfaz a parte da 3.27 que parava de mandar o código por e-mail para master e
-- financeiro com o app ligado. O resto da 3.27 continua: app obrigatório de ligar,
-- domínios de convite.
--
-- Como instalar: SQL Editor do Supabase, colar o arquivo inteiro, Run.
-- O aviso "Potential issues detected" é falso positivo: Run without RLS.
-- Pode rodar mais de uma vez.
-- ============================================================

-- Código por e-mail: sai sempre, para todos (3.28). O app é um segundo caminho, não substitui.
create or replace function public.acesso_novo_codigo(p_user uuid, p_sessao uuid, p_ip text default '', p_navegador text default '')
returns text language plpgsql security definer set search_path = public, extensions as $$
declare
  v_codigo text;
  v_ultimo timestamptz;
begin
  if p_user is null or p_sessao is null then
    raise exception 'Sessão inválida. Entre de novo.';
  end if;
  if (select count(*) from public.acesso_registro
       where user_id = p_user and evento = 'codigo_errado' and em > now() - interval '30 minutes') >= 10 then
    raise exception 'Muitas tentativas erradas. Espere 30 minutos ou peça ajuda a um master.';
  end if;
  select max(criado_em) into v_ultimo from public.acesso_codigos where user_id = p_user;
  if v_ultimo > now() - interval '30 seconds' then
    raise exception 'Acabamos de mandar um código. Espere 30 segundos antes de pedir outro.';
  end if;
  if (select count(*) from public.acesso_codigos where user_id = p_user and criado_em > now() - interval '1 hour') >= 8 then
    raise exception 'Muitos códigos pedidos na última hora. Tente de novo mais tarde.';
  end if;
  v_codigo := lpad(((('x' || encode(gen_random_bytes(4), 'hex'))::bit(32)::bigint) % 1000000)::text, 6, '0');
  insert into public.acesso_codigos (user_id, sessao, codigo_hash, expira_em, ip, navegador)
  values (p_user, p_sessao, encode(digest(v_codigo || ':' || p_sessao::text, 'sha256'), 'hex'),
          now() + interval '10 minutes', left(coalesce(p_ip, ''), 100), left(coalesce(p_navegador, ''), 300));
  insert into public.acesso_registro (user_id, evento, ip, navegador)
  values (p_user, 'codigo_enviado', left(coalesce(p_ip, ''), 100), left(coalesce(p_navegador, ''), 300));
  return v_codigo;
end $$;
revoke all on function public.acesso_novo_codigo(uuid, uuid, text, text) from public, anon, authenticated;

-- Conferência do código: vale o do app (se ligado) ou o do e-mail, para todos (3.28).
create or replace function public.verificar_codigo(p_codigo text)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare
  v_uid uuid := auth.uid();
  v_sessao uuid := public.sessao_jwt();
  v_ip text := left(split_part(public.cabecalho_req('x-forwarded-for'), ',', 1), 100);
  v_nav text := left(public.cabecalho_req('user-agent'), 300);
  v_cod text := regexp_replace(coalesce(p_codigo, ''), '\D', '', 'g');
  v_app boolean;
  v_evento text := 'entrou';
  r public.acesso_codigos%rowtype;
begin
  if v_uid is null or v_sessao is null then
    return json_build_object('ok', false, 'msg', 'Sessão inválida. Entre de novo.');
  end if;
  if (select count(*) from public.acesso_registro
       where user_id = v_uid and evento = 'codigo_errado' and em > now() - interval '30 minutes') >= 10 then
    insert into public.acesso_registro (user_id, evento, ip, navegador) values (v_uid, 'bloqueado', v_ip, v_nav);
    return json_build_object('ok', false, 'bloqueado', true,
      'msg', 'Muitas tentativas erradas. Espere 30 minutos ou peça ajuda a um master.');
  end if;
  v_app := exists (select 1 from public.acesso_totp where user_id = v_uid and ativo);

  if v_app and public.totp_confere(v_uid, v_cod, false) then
    v_evento := 'entrou_app';
  else
    select * into r from public.acesso_codigos
     where user_id = v_uid and sessao = v_sessao and usado_em is null and expira_em > now()
       and length(v_cod) = 6 and codigo_hash = encode(digest(v_cod || ':' || v_sessao::text, 'sha256'), 'hex')
     order by criado_em desc limit 1
     for update;
    if not found then
      select * into r from public.acesso_codigos
       where user_id = v_uid and sessao = v_sessao and usado_em is null and expira_em > now()
       order by criado_em desc limit 1
       for update;
      if not found then
        if v_app then
          insert into public.acesso_registro (user_id, evento, ip, navegador) values (v_uid, 'codigo_errado', v_ip, v_nav);
          return json_build_object('ok', false, 'msg', 'Código não confere. Digite o código que aparece agora no app autenticador ou o do e-mail.');
        end if;
        return json_build_object('ok', false, 'expirado', true, 'msg', 'Esse código expirou ou já foi usado. Peça um novo.');
      end if;
    end if;

    if length(v_cod) <> 6 or r.codigo_hash <> encode(digest(v_cod || ':' || v_sessao::text, 'sha256'), 'hex') then
      update public.acesso_codigos
         set tentativas = tentativas + 1,
             usado_em = case when tentativas + 1 >= 5 then now() else null end
       where id = r.id;
      insert into public.acesso_registro (user_id, evento, ip, navegador) values (v_uid, 'codigo_errado', v_ip, v_nav);
      if r.tentativas + 1 >= 5 then
        return json_build_object('ok', false, 'expirado', true, 'msg', 'Código errado 5 vezes. Peça um novo código.');
      end if;
      return json_build_object('ok', false, 'restantes', 4 - r.tentativas,
        'msg', 'Código errado. Você ainda tem ' || (4 - r.tentativas) || ' tentativa(s) com este código.');
    end if;
  end if;

  update public.acesso_codigos set usado_em = now() where user_id = v_uid and sessao = v_sessao and usado_em is null;
  insert into public.acesso_sessoes (sessao, user_id, dia, ip, navegador)
  values (v_sessao, v_uid, public.dia_brasilia(), v_ip, v_nav)
  on conflict (sessao) do update
    set dia = excluded.dia, verificado_em = now(), ip = excluded.ip, navegador = excluded.navegador
    where public.acesso_sessoes.user_id = excluded.user_id;
  insert into public.acesso_registro (user_id, evento, ip, navegador) values (v_uid, v_evento, v_ip, v_nav);
  return json_build_object('ok', true, 'dia', public.dia_brasilia());
end $$;
revoke all on function public.verificar_codigo(text) from public, anon;
grant execute on function public.verificar_codigo(text) to authenticated;

-- Conferência: deve aparecer "ok" nas duas colunas.
select case when pg_get_functiondef('public.acesso_novo_codigo(uuid,uuid,text,text)'::regprocedure) not like '%exige_app%'
            then 'ok' else 'ERRO' end as email_volta_a_sair,
       case when pg_get_functiondef('public.verificar_codigo(text)'::regprocedure) not like '%so_app%'
            then 'ok' else 'ERRO' end as email_volta_a_valer;
