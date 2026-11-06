-- ============================================================
--  8.16. TELA INICIAL: AVISOS E REGISTRO DE ATIVIDADES (06/11/2026, Hub 2.96)
--     Pode rodar de novo sem estragar nada.
-- ============================================================

-- Avisos: o "de N" passa a contar só quem tem acesso (sem as contas revogadas) e o
-- resumo diz se o aviso é meu e quanto falta ler.
drop function if exists public.avisos_resumo();
create function public.avisos_resumo()
returns table (id uuid, titulo text, texto text, publicar_em timestamptz, fixado boolean,
               autor text, lidos integer, total integer, lido_por_mim boolean, criado_em timestamptz)
language sql stable security definer set search_path = public as $$
  with equipe as (
    select p.user_id from public.perfis p join auth.users u on u.id = p.user_id
     where coalesce(u.banned_until, '-infinity') <= now()
  )
  select a.id, a.titulo, a.texto, a.publicar_em, a.fixado,
         coalesce(p.nome, ''),
         (select count(*)::int from public.avisos_leitura l join equipe e on e.user_id = l.user_id where l.aviso_id = a.id),
         (select count(*)::int from equipe),
         exists (select 1 from public.avisos_leitura l where l.aviso_id = a.id and l.user_id = auth.uid()),
         a.criado_em
  from public.avisos a
  left join public.perfis p on p.user_id = a.criado_por
  where auth.uid() is not null and public.acesso_liberado()
    and (a.publicar_em <= now() or public.pode_publicar_aviso())
  order by a.fixado desc, a.publicar_em desc
  limit 100;
$$;
revoke all on function public.avisos_resumo() from public, anon;
grant execute on function public.avisos_resumo() to authenticated;

-- Quem leu e quem ainda não leu um aviso (só quem pode publicar aviso vê).
create or replace function public.aviso_leitores(p_aviso uuid)
returns table (nome text, lido_em timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.pode_publicar_aviso() then raise exception 'Só quem publica avisos vê quem leu.'; end if;
  return query
    select coalesce(nullif(p.nome, ''), split_part(u.email, '@', 1))::text, l.lido_em
      from public.perfis p
      join auth.users u on u.id = p.user_id
      left join public.avisos_leitura l on l.aviso_id = p_aviso and l.user_id = p.user_id
     where coalesce(u.banned_until, '-infinity') <= now()
     order by l.lido_em is null, l.lido_em desc, 1;
end $$;
revoke all on function public.aviso_leitores(uuid) from public, anon;
grant execute on function public.aviso_leitores(uuid) to authenticated;

-- Registro de atividades (tela do master): a auditoria com o nome de quem fez, filtros e
-- paginação. Lê só quem é master (gerenciar equipe).
create or replace function public.registro_atividades(p_de timestamptz default null, p_ate timestamptz default null,
  p_usuario text default null, p_acao text default null, p_busca text default null, p_limite int default 100, p_antes bigint default null)
returns table (id bigint, quando timestamptz, usuario text, nome text, acao text, alvo text, detalhe text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.eh_super() then raise exception 'Apenas o master vê o registro de atividades.'; end if;
  return query
    select a.id, a.quando, a.usuario, coalesce(nullif(p.nome, ''), a.usuario)::text, a.acao, a.alvo, a.detalhe
      from public.auditoria a
      left join auth.users u on lower(u.email) = lower(a.usuario)
      left join public.perfis p on p.user_id = u.id
     where (p_de is null or a.quando >= p_de)
       and (p_ate is null or a.quando < p_ate)
       and (p_usuario is null or lower(a.usuario) = lower(p_usuario))
       and (p_acao is null or a.acao = p_acao)
       and (p_busca is null or btrim(p_busca) = ''
            or (coalesce(a.alvo, '') || ' ' || coalesce(a.detalhe, '') || ' ' || coalesce(a.acao, '')) ilike '%' || p_busca || '%')
       and (p_antes is null or a.id < p_antes)
     order by a.id desc
     limit least(greatest(coalesce(p_limite, 100), 1), 500);
end $$;
revoke all on function public.registro_atividades(timestamptz, timestamptz, text, text, text, int, bigint) from public, anon;
grant execute on function public.registro_atividades(timestamptz, timestamptz, text, text, text, int, bigint) to authenticated;

-- As ações que existem, para o filtro (com a contagem dos últimos 90 dias).
create or replace function public.registro_acoes()
returns table (acao text, qtd bigint)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.eh_super() then raise exception 'Apenas o master vê o registro de atividades.'; end if;
  return query select a.acao, count(*) from public.auditoria a
    where a.quando > now() - interval '90 days' and a.acao is not null group by a.acao order by 2 desc;
end $$;
revoke all on function public.registro_acoes() from public, anon;
grant execute on function public.registro_acoes() to authenticated;

create index if not exists auditoria_usuario_idx on public.auditoria (lower(usuario));
