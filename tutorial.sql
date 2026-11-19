-- ============================================================
--  Tutorial em vídeo do primeiro acesso (19/11/2026, Hub 3.43, comum/tutorial.js).
--  Guarda quem marcou "Não mostrar novamente" no tutorial do Hub e no do CRM. Enquanto a pessoa não
--  marca, o vídeo aparece a cada entrada. A tabela não tem política: só as duas funções leem e gravam,
--  e cada pessoa só mexe na própria marca.
--  Para mostrar de novo a alguém:  delete from public.tutorial_vistos where user_id = '<id>';
--  Rodar inteiro no SQL Editor (Run without RLS). Pode rodar de novo.
-- ============================================================
create table if not exists public.tutorial_vistos (
  user_id  uuid not null references auth.users(id) on delete cascade,
  modulo   text not null check (modulo in ('hub', 'crm')),
  visto_em timestamptz not null default now(),
  primary key (user_id, modulo)
);
alter table public.tutorial_vistos enable row level security;
revoke all on public.tutorial_vistos from anon, authenticated;

create or replace function public.tutorial_vistos()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.acesso_liberado() then raise exception 'Acesso não liberado.'; end if;
  return coalesce((select jsonb_agg(modulo) from public.tutorial_vistos where user_id = auth.uid()), '[]'::jsonb);
end $$;
revoke all on function public.tutorial_vistos() from public, anon;
grant execute on function public.tutorial_vistos() to authenticated;

create or replace function public.tutorial_marcar(p_modulo text)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if not public.acesso_liberado() then raise exception 'Acesso não liberado.'; end if;
  if p_modulo not in ('hub', 'crm') then raise exception 'Módulo inválido.'; end if;
  insert into public.tutorial_vistos (user_id, modulo) values (auth.uid(), p_modulo)
  on conflict (user_id, modulo) do update set visto_em = now();
  return true;
end $$;
revoke all on function public.tutorial_marcar(text) from public, anon;
grant execute on function public.tutorial_marcar(text) to authenticated;

-- Regra da casa: toda tabela com RLS tem a política restritiva exige_verificacao.
drop policy if exists exige_verificacao on public.tutorial_vistos;
create policy exige_verificacao on public.tutorial_vistos as restrictive for all to authenticated
  using ((select public.acesso_liberado())) with check ((select public.acesso_liberado()));
