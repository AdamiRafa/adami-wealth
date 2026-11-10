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
