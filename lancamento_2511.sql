-- ============================================================
--  Acesso restrito até o lançamento (19/11/2026, Hub 3.42). Pedido do Emil: "deixa só eu, o Rafael
--  e a Bibiana com acesso até quarta-feira, vamos soltar para todo mundo na quarta".
--
--  Até acesso_config.restrito_ate (25/11/2026, 0h de Brasília) só quem está em restrito_a entra.
--  Para os demais:
--    - acesso_liberado() responde "não", então o banco não devolve nem grava nada (todas as
--      políticas exige_verificacao e as funções usam essa checagem);
--    - liberar_sessao_do_dia() recusa o login com a mensagem de quando o Hub abre;
--    - o e-mail da manhã não sai para eles (o gatilho em agenda_emails recusa a reserva do envio,
--      e a função agenda-manha pula a pessoa como "já enviado hoje").
--  Na hora marcada abre sozinho, sem precisar rodar nada.
--    Abrir antes:      update public.acesso_config set restrito_ate = now();
--    Mudar a data:     update public.acesso_config set restrito_ate = '2026-11-25 14:00-03';
--  Rodar inteiro no SQL Editor (Run without RLS). Pode rodar de novo.
-- ============================================================

alter table public.acesso_config add column if not exists restrito_ate timestamptz;
alter table public.acesso_config add column if not exists restrito_a uuid[] not null default '{}';
update public.acesso_config set
  restrito_ate = '2026-11-25 00:00:00-03',
  restrito_a = array['d5ff1b2f-95e2-46cf-8577-d9d47236aa39',   -- Emil Stade
                     '24e8c324-838a-4e84-8acc-36862383de70',   -- Rafael Adami
                     'f658af86-809d-4586-a478-8240830f4a00']::uuid[];  -- Bibiana Adami

-- Verdadeiro quando o Hub ainda está fechado para esta pessoa.
create or replace function public.acesso_fechado(p_user uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select c.restrito_ate is not null and c.restrito_ate > now()
                          and not (coalesce(p_user, '00000000-0000-0000-0000-000000000000'::uuid) = any (c.restrito_a))
                     from public.acesso_config c limit 1), false);
$$;
revoke all on function public.acesso_fechado(uuid) from public, anon, authenticated;

create or replace function public.acesso_liberado()
returns boolean language sql stable security definer set search_path = public as $$
  select (coalesce((select not c.exigir_codigo from public.acesso_config c limit 1), false)
          or exists (select 1 from public.acesso_sessoes s
                      where s.sessao = public.sessao_jwt()
                        and s.user_id = auth.uid()
                        and s.dia = public.dia_brasilia()))
     and not public.acesso_fechado(auth.uid());
$$;

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
  if public.acesso_fechado(v_uid) then
    return json_build_object('ok', false, 'fechado', true,
      'msg', 'O Hub abre para toda a equipe na quarta-feira, 25/11, com a apresentação no Teams. Até lá o acesso está fechado.');
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

-- E-mail da manhã só para quem já pode entrar.
create or replace function public.agenda_emails_so_liberados()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if public.acesso_fechado(new.user_id) then return null; end if;
  return new;
end $$;
revoke all on function public.agenda_emails_so_liberados() from public, anon, authenticated;
drop trigger if exists agenda_emails_so_liberados on public.agenda_emails;
create trigger agenda_emails_so_liberados before insert on public.agenda_emails
  for each row execute function public.agenda_emails_so_liberados();
