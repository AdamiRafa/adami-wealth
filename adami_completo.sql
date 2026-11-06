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

  -- O código novo cancela os anteriores desta sessão.
  update public.acesso_codigos set usado_em = now()
   where user_id = p_user and sessao = p_sessao and usado_em is null;

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

  select * into r from public.acesso_codigos
   where user_id = v_uid and sessao = v_sessao and usado_em is null and expira_em > now()
   order by criado_em desc limit 1
   for update;
  if not found then
    return json_build_object('ok', false, 'expirado', true, 'msg', 'Esse código expirou ou já foi usado. Peça um novo.');
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

  update public.acesso_codigos set usado_em = now() where id = r.id;
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
