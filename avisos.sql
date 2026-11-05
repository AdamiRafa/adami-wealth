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
