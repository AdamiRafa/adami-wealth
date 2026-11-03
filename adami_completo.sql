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
  id_origem        text,
  criado_em        timestamptz not null default now()
);
create index if not exists fluxo_dist_snapshot_idx on public.fluxo_distribuicao(snapshot_id);
create index if not exists fluxo_dist_mes_ano_idx on public.fluxo_distribuicao(ano, mes);

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
