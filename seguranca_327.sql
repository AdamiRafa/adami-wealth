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
