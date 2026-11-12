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
