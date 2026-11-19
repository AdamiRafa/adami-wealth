-- ============================================================
--  Segurança 3.36 (19/11/2026): verificação em duas etapas desligada a pedido do Emil.
--  Fica só a regra do acesso que vence todo dia: depois da meia-noite de Brasília todo mundo
--  entra de novo com e-mail e senha. Sai o código de 6 dígitos (e-mail ou app) e o app
--  autenticador obrigatório para master e financeiro.
--
--  Como funciona sem o código:
--    - Depois da senha, o Hub chama liberar_sessao_do_dia(). Ela só libera a sessão se o
--      login (auth.sessions) foi criado HOJE no horário de Brasília, ou seja, se a senha foi
--      digitada hoje. Renovar o token não cria sessão nova, então um login de ontem não se
--      libera sozinho; e o agendamento "acesso-virada" (0h01) já derruba todas as sessões.
--    - Toda a proteção do banco continua igual: as políticas exige_verificacao seguem
--      valendo e acesso_liberado() segue exigindo a sessão liberada no dia.
--    - As tabelas e funções do código e do app ficam instaladas, sem uso.
--
--  Para religar o código (e o app obrigatório para master e financeiro):
--      update public.acesso_config set segundo_fator = true;
--  Rodar inteiro no SQL Editor (Run without RLS). Pode rodar de novo.
-- ============================================================

alter table public.acesso_config add column if not exists segundo_fator boolean not null default true;
update public.acesso_config set segundo_fator = false;

-- O que a tela de login precisa saber. "segundo_fator" diz se ainda pede código.
create or replace function public.estado_acesso()
returns json language sql stable security definer set search_path = public as $$
  select json_build_object(
    'exige', coalesce((select c.exigir_codigo from public.acesso_config c limit 1), true),
    'segundo_fator', coalesce((select c.segundo_fator from public.acesso_config c limit 1), true),
    'liberado', public.acesso_liberado(),
    'dia', public.dia_brasilia());
$$;

-- Libera a sessão de quem digitou a senha hoje (só quando o segundo fator está desligado).
create or replace function public.liberar_sessao_do_dia()
returns json language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_sessao uuid := public.sessao_jwt();
  v_ip text := left(split_part(public.cabecalho_req('x-forwarded-for'), ',', 1), 100);
  v_nav text := left(public.cabecalho_req('user-agent'), 300);
begin
  if v_uid is null or v_sessao is null then
    return json_build_object('ok', false, 'msg', 'Sessão inválida. Entre de novo.');
  end if;
  if coalesce((select c.segundo_fator from public.acesso_config c limit 1), true) then
    return json_build_object('ok', false, 'codigo', true, 'msg', 'A verificação em duas etapas está ligada: use o código.');
  end if;
  if not exists (select 1 from auth.sessions s
                  where s.id = v_sessao and s.user_id = v_uid
                    and (s.created_at at time zone 'America/Sao_Paulo')::date = public.dia_brasilia()) then
    return json_build_object('ok', false, 'msg', 'Este login é de outro dia. Entre de novo com a senha.');
  end if;
  insert into public.acesso_sessoes (sessao, user_id, dia, ip, navegador)
  values (v_sessao, v_uid, public.dia_brasilia(), v_ip, v_nav)
  on conflict (sessao) do update
    set dia = excluded.dia, verificado_em = now(), ip = excluded.ip, navegador = excluded.navegador
    where public.acesso_sessoes.user_id = excluded.user_id;
  insert into public.acesso_registro (user_id, evento, ip, navegador) values (v_uid, 'entrou', v_ip, v_nav);
  return json_build_object('ok', true, 'dia', public.dia_brasilia());
end $$;
revoke all on function public.liberar_sessao_do_dia() from public, anon;
grant execute on function public.liberar_sessao_do_dia() to authenticated;

-- App autenticador só é obrigatório (master e financeiro) com o segundo fator ligado.
create or replace function public.app_obrigatorio()
returns json language sql stable security definer set search_path = public as $$
  select json_build_object(
    'obrigatorio', public.exige_app(auth.uid())
                   and coalesce((select c.segundo_fator from public.acesso_config c limit 1), true),
    'ativo', exists (select 1 from public.acesso_totp where user_id = auth.uid() and ativo))
  where auth.uid() is not null;
$$;
