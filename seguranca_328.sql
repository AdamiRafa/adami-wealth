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
