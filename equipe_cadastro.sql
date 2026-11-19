-- Ficha de cadastro da pessoa (19/11/2026, Hub 3.35). Pedido do Emil: ao criar o acesso de um assessor, ter a ficha
-- completa (dados pessoais, vínculo, certificações, contato de emergência), como o Financeiro já tem os dados de
-- pagamento. A ficha é guardada pelo e-mail para poder ser preenchida já no convite, antes de a conta existir; o
-- user_id é ligado sozinho quando a conta aparece.
-- Quem lê e grava: master e quem opera Comissões (Financeiro). A própria pessoa lê a sua. A auditoria registra quais
-- campos mudaram, nunca os valores (CPF, RG, endereço).
-- As validades das certificações alimentam o gatilho "Certificação vencendo" da Agenda (equipe_certificacoes).
-- Rodar inteiro no SQL Editor (Run without RLS).

create table if not exists public.equipe_cadastro (
  email          text primary key check (email = lower(btrim(email)) and email like '%@%'),
  user_id        uuid,
  dados          jsonb not null default '{}'::jsonb check (jsonb_typeof(dados) = 'object'),
  atualizado_em  timestamptz not null default now(),
  atualizado_por text
);
create index if not exists equipe_cadastro_user on public.equipe_cadastro (user_id);
alter table public.equipe_cadastro enable row level security;
drop policy if exists equipe_cadastro_ler on public.equipe_cadastro;
create policy equipe_cadastro_ler on public.equipe_cadastro for select to authenticated
  using (user_id = (select auth.uid()) or (select public.eh_super()) or (select public.com_pode_ver()));
drop policy if exists exige_verificacao on public.equipe_cadastro;
create policy exige_verificacao on public.equipe_cadastro as restrictive for all to authenticated
  using ((select public.acesso_liberado())) with check ((select public.acesso_liberado()));

create or replace function public.equipe_cadastro_pode()
returns boolean language sql stable security definer set search_path = public as $$
  select public.acesso_liberado() and (public.eh_super() or public.com_pode_ver());
$$;
revoke all on function public.equipe_cadastro_pode() from public, anon;
grant execute on function public.equipe_cadastro_pode() to authenticated;

-- Liga o e-mail à conta (quando ela já existe).
create or replace function public.equipe_cadastro_conta(p_email text)
returns uuid language sql stable security definer set search_path = public, auth as $$
  select id from auth.users where lower(email) = lower(btrim(p_email)) limit 1;
$$;
revoke all on function public.equipe_cadastro_conta(text) from public, anon, authenticated;

create or replace function public.equipe_cadastro_ler(p_email text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_email text := lower(btrim(coalesce(p_email, ''))); v_uid uuid; r public.equipe_cadastro;
begin
  if not public.acesso_liberado() then raise exception 'Acesso não liberado.'; end if;
  v_uid := public.equipe_cadastro_conta(v_email);
  if not (public.equipe_cadastro_pode() or (v_uid is not null and v_uid = auth.uid())) then
    raise exception 'Só o master e o Financeiro veem a ficha de cadastro.';
  end if;
  select * into r from public.equipe_cadastro c where c.email = v_email or (v_uid is not null and c.user_id = v_uid)
   order by (c.email = v_email) desc limit 1;
  return jsonb_build_object('email', v_email, 'dados', coalesce(r.dados, '{}'::jsonb),
    'atualizado_em', r.atualizado_em, 'atualizado_por', r.atualizado_por);
end $$;
revoke all on function public.equipe_cadastro_ler(text) from public, anon;
grant execute on function public.equipe_cadastro_ler(text) to authenticated;

create or replace function public.equipe_cadastro_salvar(p_email text, p_dados jsonb)
returns boolean language plpgsql security definer set search_path = public as $$
declare v_email text := lower(btrim(coalesce(p_email, ''))); v_uid uuid; v_antes jsonb; v_mudou text;
begin
  if not (public.acesso_liberado() and (public.eh_super() or public.com_pode_operar())) then raise exception 'Só o master e o Financeiro editam a ficha de cadastro.'; end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'E-mail inválido.'; end if;
  if p_dados is null or jsonb_typeof(p_dados) <> 'object' then raise exception 'Ficha inválida.'; end if;
  if length(p_dados::text) > 30000 then raise exception 'Ficha grande demais.'; end if;
  v_uid := public.equipe_cadastro_conta(v_email);
  -- quem trocou de e-mail na Equipe: a ficha segue a conta
  if v_uid is not null then
    update public.equipe_cadastro set email = v_email where user_id = v_uid and email <> v_email
      and not exists (select 1 from public.equipe_cadastro x where x.email = v_email);
  end if;
  select dados into v_antes from public.equipe_cadastro where email = v_email;
  insert into public.equipe_cadastro (email, user_id, dados, atualizado_em, atualizado_por)
  values (v_email, v_uid, p_dados, now(), coalesce((select email from auth.users where id = auth.uid()), auth.uid()::text))
  on conflict (email) do update set user_id = coalesce(excluded.user_id, equipe_cadastro.user_id), dados = excluded.dados,
    atualizado_em = now(), atualizado_por = excluded.atualizado_por;
  select string_agg(k, ', ' order by k) into v_mudou from (
    select k from jsonb_object_keys(coalesce(v_antes, '{}'::jsonb) || p_dados) k
     where (coalesce(v_antes, '{}'::jsonb) -> k) is distinct from (p_dados -> k)) x;
  insert into public.auditoria (quando, usuario, acao, alvo, detalhe)
  values (now(), coalesce((select email from auth.users where id = auth.uid()), auth.uid()::text), 'equipe_cadastro', v_email,
          'campos alterados: ' || coalesce(v_mudou, 'nenhum'));
  return true;
end $$;
revoke all on function public.equipe_cadastro_salvar(text, jsonb) from public, anon;
grant execute on function public.equipe_cadastro_salvar(text, jsonb) to authenticated;

-- Certificações com validade, para o gatilho da Agenda: a própria pessoa vê as suas; master e admin do CRM, as de todos.
create or replace function public.equipe_certificacoes()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.acesso_liberado() then raise exception 'Acesso não liberado.'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('pessoa', u, 'cert', c.key, 'vence', c.value #>> '{}'))
      from (select coalesce(e.user_id, public.equipe_cadastro_conta(e.email)) u, e.dados from public.equipe_cadastro e) x
     cross join lateral jsonb_each(coalesce(x.dados -> 'certificacoes', '{}'::jsonb)) c
     where x.u is not null and (c.value #>> '{}') ~ '^\d{4}-\d{2}-\d{2}$'
       and (x.u = auth.uid() or public.eh_super() or public.is_admin())), '[]'::jsonb);
end $$;
revoke all on function public.equipe_certificacoes() from public, anon;
grant execute on function public.equipe_certificacoes() to authenticated;
