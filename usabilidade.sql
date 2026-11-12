-- ============================================================
-- usabilidade.sql · Hub 3.10 (12/11/2026)
--
-- Melhorias de uso pedidas pelo Emil depois do manual do Hub:
--   1. Lembrar o aparelho por 7 dias (só para quem tem o app autenticador).
--      A senha continua sendo pedida todo dia; só o código é dispensado.
--   2. Checklist do primeiro acesso na tela inicial (meu_checklist).
--   3. Reportar problema: tabela problemas + bucket privado "problemas".
--   4. Painel de adoção para o master (painel_adocao).
--
-- Como instalar: SQL Editor do Supabase, colar o arquivo inteiro, Run.
-- O aviso "Potential issues detected" é falso positivo: Run without RLS.
-- Pode rodar mais de uma vez.
-- ============================================================

-- ---------- 0. Novos eventos no registro de acessos ----------
alter table public.acesso_registro drop constraint if exists acesso_registro_evento_check;
alter table public.acesso_registro add constraint acesso_registro_evento_check check (evento in
  ('codigo_enviado','codigo_errado','entrou','bloqueado','saiu_de_todos',
   'entrou_app','app_ativado','app_desativado','app_zerado',
   'aparelho_lembrado','entrou_aparelho','aparelho_esquecido'));

-- ---------- 1. Aparelhos lembrados ----------
-- O navegador guarda um token aleatório de 256 bits; aqui fica só o hash.
-- Vale 7 dias a partir de quando foi criado (não renova sozinho) e só
-- enquanto a pessoa tiver o app autenticador ligado.
create table if not exists public.acesso_aparelhos (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  token_hash  text not null unique,
  criado_em   timestamptz not null default now(),
  expira_em   timestamptz not null,
  ultimo_uso  timestamptz,
  ip          text not null default '',
  navegador   text not null default ''
);
create index if not exists acesso_aparelhos_user_idx on public.acesso_aparelhos (user_id);
alter table public.acesso_aparelhos enable row level security;
revoke all on public.acesso_aparelhos from public, anon, authenticated;
drop policy if exists exige_verificacao on public.acesso_aparelhos;
create policy exige_verificacao on public.acesso_aparelhos as restrictive for all to authenticated
  using ( public.acesso_liberado() ) with check ( public.acesso_liberado() );

-- Cria o token deste aparelho. Só com o acesso do dia já confirmado e o app ligado.
create or replace function public.aparelho_lembrar()
returns json language plpgsql security definer set search_path = public, extensions as $$
declare
  v_uid uuid := auth.uid();
  v_token text;
  v_id uuid;
begin
  if v_uid is null or not public.acesso_liberado() then
    return json_build_object('ok', false, 'msg', 'Sessão inválida. Entre de novo.');
  end if;
  if not exists (select 1 from public.acesso_totp where user_id = v_uid and ativo) then
    return json_build_object('ok', false, 'sem_app', true,
      'msg', 'Para lembrar este aparelho, ligue antes o app autenticador em Segurança.');
  end if;
  delete from public.acesso_aparelhos where user_id = v_uid and expira_em < now();
  -- No máximo 5 aparelhos por pessoa: o mais antigo sai.
  delete from public.acesso_aparelhos where id in (
    select id from public.acesso_aparelhos where user_id = v_uid order by criado_em desc offset 4);
  v_token := encode(gen_random_bytes(32), 'hex');
  insert into public.acesso_aparelhos (user_id, token_hash, expira_em, ip, navegador)
  values (v_uid, encode(digest(v_token, 'sha256'), 'hex'), now() + interval '7 days',
          left(split_part(public.cabecalho_req('x-forwarded-for'), ',', 1), 100),
          left(public.cabecalho_req('user-agent'), 300))
  returning id into v_id;
  insert into public.acesso_registro (user_id, evento, ip, navegador)
  values (v_uid, 'aparelho_lembrado', left(split_part(public.cabecalho_req('x-forwarded-for'), ',', 1), 100), left(public.cabecalho_req('user-agent'), 300));
  return json_build_object('ok', true, 'id', v_id, 'token', v_token, 'expira_em', now() + interval '7 days');
end $$;

-- Depois da senha: se o token deste aparelho vale, libera a sessão sem código.
-- Usa as mesmas travas da verificar_codigo (bloqueio por erros).
create or replace function public.aparelho_entrar(p_token text)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare
  v_uid uuid := auth.uid();
  v_sessao uuid := public.sessao_jwt();
  v_ip text := left(split_part(public.cabecalho_req('x-forwarded-for'), ',', 1), 100);
  v_nav text := left(public.cabecalho_req('user-agent'), 300);
  v_id uuid;
begin
  if v_uid is null or v_sessao is null or coalesce(p_token, '') !~ '^[0-9a-f]{64}$' then
    return json_build_object('ok', false);
  end if;
  if (select count(*) from public.acesso_registro
       where user_id = v_uid and evento = 'codigo_errado' and em > now() - interval '30 minutes') >= 10 then
    return json_build_object('ok', false);
  end if;
  select a.id into v_id from public.acesso_aparelhos a
   where a.user_id = v_uid and a.token_hash = encode(digest(p_token, 'sha256'), 'hex') and a.expira_em > now()
     and exists (select 1 from public.acesso_totp t where t.user_id = v_uid and t.ativo);
  if v_id is null then return json_build_object('ok', false); end if;
  update public.acesso_aparelhos set ultimo_uso = now(), ip = v_ip, navegador = v_nav where id = v_id;
  insert into public.acesso_sessoes (sessao, user_id, dia, ip, navegador)
  values (v_sessao, v_uid, public.dia_brasilia(), v_ip, v_nav)
  on conflict (sessao) do update
    set dia = excluded.dia, verificado_em = now(), ip = excluded.ip, navegador = excluded.navegador
    where public.acesso_sessoes.user_id = excluded.user_id;
  insert into public.acesso_registro (user_id, evento, ip, navegador) values (v_uid, 'entrou_aparelho', v_ip, v_nav);
  return json_build_object('ok', true, 'dia', public.dia_brasilia());
end $$;

-- Lista dos aparelhos lembrados da própria pessoa (tela Segurança).
drop function if exists public.aparelhos_meus();
create function public.aparelhos_meus()
returns table (id uuid, criado_em timestamptz, expira_em timestamptz, ultimo_uso timestamptz, navegador text, ip text)
language sql stable security definer set search_path = public as $$
  select a.id, a.criado_em, a.expira_em, a.ultimo_uso, a.navegador, a.ip
    from public.acesso_aparelhos a
   where a.user_id = auth.uid() and a.expira_em > now() and public.acesso_liberado()
   order by a.criado_em desc;
$$;

-- Esquece um aparelho (p_id) ou todos (p_id nulo).
create or replace function public.aparelho_esquecer(p_id uuid default null)
returns json language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or not public.acesso_liberado() then raise exception 'Sessão inválida. Entre de novo.'; end if;
  delete from public.acesso_aparelhos where user_id = auth.uid() and (p_id is null or id = p_id);
  insert into public.acesso_registro (user_id, evento, ip, navegador)
  values (auth.uid(), 'aparelho_esquecido', left(split_part(public.cabecalho_req('x-forwarded-for'), ',', 1), 100), left(public.cabecalho_req('user-agent'), 300));
  return json_build_object('ok', true);
end $$;

-- "Sair de todos os aparelhos" também esquece os aparelhos lembrados.
create or replace function public.registrar_saida_geral()
returns void language sql security definer set search_path = public as $$
  delete from public.acesso_aparelhos where user_id = auth.uid() and public.acesso_liberado();
  insert into public.acesso_registro (user_id, evento, ip, navegador)
  select auth.uid(), 'saiu_de_todos',
         left(split_part(public.cabecalho_req('x-forwarded-for'), ',', 1), 100),
         left(public.cabecalho_req('user-agent'), 300)
  where auth.uid() is not null and public.acesso_liberado();
$$;

-- Desligar o app (ou o master zerar) também esquece os aparelhos.
create or replace function public.totp_desativar()
returns json language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or not public.acesso_liberado() then raise exception 'Sessão inválida. Entre de novo.'; end if;
  delete from public.acesso_totp where user_id = auth.uid();
  delete from public.acesso_aparelhos where user_id = auth.uid();
  insert into public.acesso_registro (user_id, evento, ip, navegador)
  values (auth.uid(), 'app_desativado', left(split_part(public.cabecalho_req('x-forwarded-for'), ',', 1), 100), left(public.cabecalho_req('user-agent'), 300));
  return json_build_object('ok', true);
end $$;

create or replace function public.totp_zerar(p_user uuid)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not public.eh_super() then raise exception 'Apenas o master pode zerar o app de outra pessoa.'; end if;
  delete from public.acesso_totp where user_id = p_user;
  delete from public.acesso_aparelhos where user_id = p_user;
  insert into public.acesso_registro (user_id, evento, ip, navegador)
  values (p_user, 'app_zerado', left(split_part(public.cabecalho_req('x-forwarded-for'), ',', 1), 100), left(public.cabecalho_req('user-agent'), 300));
  return json_build_object('ok', true);
end $$;

-- ---------- 2. Checklist do primeiro acesso ----------
create or replace function public.meu_checklist()
returns json language plpgsql stable security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null or not public.acesso_liberado() then return null; end if;
  return json_build_object(
    'app', exists (select 1 from public.acesso_totp where user_id = v_uid and ativo),
    'atividade', exists (select 1 from public.leads l
                          where l.responsavel_id = v_uid and not coalesce(l.excluido, false)
                            and jsonb_typeof(l.atividades) = 'array' and jsonb_array_length(l.atividades) > 0),
    'jornada', (select count(*) from public.leads l
                 where l.responsavel_id = v_uid and l.esteira = 'novo'
                   and not coalesce(l.excluido, false) and not coalesce(l.perdido, false) and not coalesce(l.ganho, false)),
    'jornada_sem_contato', (select count(*) from public.leads l
                 where l.responsavel_id = v_uid and l.esteira = 'novo'
                   and not coalesce(l.excluido, false) and not coalesce(l.perdido, false) and not coalesce(l.ganho, false)
                   and l.proximo_contato is null),
    'aparelho', exists (select 1 from public.acesso_aparelhos where user_id = v_uid and expira_em > now()));
end $$;

-- ---------- 3. Reportar problema ----------
create table if not exists public.problemas (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null default auth.uid() references auth.users(id) on delete cascade,
  criado_em     timestamptz not null default now(),
  modulo        text not null default '' check (length(modulo) <= 80),
  versao        text not null default '' check (length(versao) <= 80),
  url           text not null default '' check (length(url) <= 500),
  navegador     text not null default '' check (length(navegador) <= 400),
  tela          text not null default '' check (length(tela) <= 40),
  texto         text not null check (length(texto) between 3 and 4000),
  erros         jsonb not null default '[]'::jsonb,
  print_caminho text,
  resolvido_em  timestamptz,
  resolvido_por uuid references auth.users(id) on delete set null
);
create index if not exists problemas_criado_idx on public.problemas (criado_em desc);
alter table public.problemas enable row level security;
revoke all on public.problemas from public, anon, authenticated;
grant select, insert on public.problemas to authenticated;
drop policy if exists exige_verificacao on public.problemas;
create policy exige_verificacao on public.problemas as restrictive for all to authenticated
  using ( public.acesso_liberado() ) with check ( public.acesso_liberado() );
drop policy if exists problemas_criar on public.problemas;
create policy problemas_criar on public.problemas for insert to authenticated
  with check ( user_id = auth.uid() and resolvido_em is null and resolvido_por is null );
drop policy if exists problemas_ler on public.problemas;
create policy problemas_ler on public.problemas for select to authenticated
  using ( user_id = auth.uid() or public.eh_super() );

-- Lista para o master, com o nome de quem reportou.
drop function if exists public.problemas_lista();
create function public.problemas_lista()
returns table (id uuid, criado_em timestamptz, nome text, email text, modulo text, versao text, url text,
               navegador text, tela text, texto text, erros jsonb, print_caminho text, resolvido_em timestamptz)
language sql stable security definer set search_path = public as $$
  select pr.id, pr.criado_em, coalesce(p.nome, ''), coalesce(u.email::text, ''), pr.modulo, pr.versao, pr.url,
         pr.navegador, pr.tela, pr.texto, pr.erros, pr.print_caminho, pr.resolvido_em
    from public.problemas pr
    left join public.perfis p on p.user_id = pr.user_id
    left join auth.users u on u.id = pr.user_id
   where public.eh_super()
   order by (pr.resolvido_em is null) desc, pr.criado_em desc
   limit 200;
$$;

create or replace function public.problema_resolver(p_id uuid, p_resolvido boolean default true)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not public.eh_super() then raise exception 'Apenas o master marca problema como resolvido.'; end if;
  update public.problemas
     set resolvido_em = case when p_resolvido then now() end,
         resolvido_por = case when p_resolvido then auth.uid() end
   where id = p_id;
  return json_build_object('ok', true);
end $$;

-- Prints dos problemas: bucket privado; cada um grava na própria pasta, o master lê tudo.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('problemas', 'problemas', false, 4194304, array['image/jpeg','image/png'])
on conflict (id) do update set public = false, file_size_limit = 4194304, allowed_mime_types = array['image/jpeg','image/png'];
drop policy if exists problemas_print_enviar on storage.objects;
create policy problemas_print_enviar on storage.objects for insert to authenticated
  with check ( bucket_id = 'problemas' and (storage.foldername(name))[1] = auth.uid()::text );
drop policy if exists problemas_print_ler on storage.objects;
create policy problemas_print_ler on storage.objects for select to authenticated
  using ( bucket_id = 'problemas' and ((storage.foldername(name))[1] = auth.uid()::text or public.eh_super()) );

-- ---------- 4. Painel de adoção (só master) ----------
drop function if exists public.painel_adocao();
create function public.painel_adocao()
returns table (user_id uuid, nome text, email text, papel text, ativo boolean, app boolean, aparelhos int,
               ultimo_acesso timestamptz, dias_acesso_30 int, atividades_30 int, clientes int,
               jornada int, jornada_sem_contato int, contatos_atrasados int, tarefas_atrasadas int)
language sql stable security definer set search_path = public as $$
  with gente as (
    select p.user_id, coalesce(nullif(p.nome, ''), pr.nome, '') as nome, u.email::text as email,
           coalesce(pr.role, case when p.super then 'master' when p.admin then 'administrador' else '' end) as papel,
           coalesce(pr.status, 'ativo') = 'ativo' as ativo
      from public.perfis p
      join auth.users u on u.id = p.user_id
      left join public.profiles pr on pr.id = p.user_id
  ), ld as (
    select l.responsavel_id as uid,
           count(*) filter (where not coalesce(l.perdido, false)) as clientes,
           count(*) filter (where l.esteira = 'novo' and not coalesce(l.perdido, false) and not coalesce(l.ganho, false)) as jornada,
           count(*) filter (where l.esteira = 'novo' and not coalesce(l.perdido, false) and not coalesce(l.ganho, false) and l.proximo_contato is null) as jornada_sem_contato,
           count(*) filter (where not coalesce(l.perdido, false) and l.proximo_contato < public.dia_brasilia()) as atrasados,
           sum((select count(*) from jsonb_array_elements(case when jsonb_typeof(l.atividades) = 'array' then l.atividades else '[]'::jsonb end) a
                 where (a->>'data') ~ '^\d{4}-\d{2}-\d{2}' and left(a->>'data', 10)::date >= public.dia_brasilia() - 30)) as ativ30
      from public.leads l
     where not coalesce(l.excluido, false)
     group by l.responsavel_id
  ), ac as (
    select r.user_id as uid, max(r.em) as ultimo,
           count(distinct (r.em at time zone 'America/Sao_Paulo')::date) filter (where r.em > now() - interval '30 days') as dias
      from public.acesso_registro r
     where r.evento in ('entrou', 'entrou_app', 'entrou_aparelho')
     group by r.user_id
  ), tf as (
    select t.dono_id as uid, count(*) as atrasadas
      from public.tarefas t
     where t.repeticao = 'nao' and t.data < public.dia_brasilia() and coalesce(array_length(t.concluidas, 1), 0) = 0
     group by t.dono_id
  )
  select g.user_id, g.nome, g.email, g.papel, g.ativo,
         exists (select 1 from public.acesso_totp t where t.user_id = g.user_id and t.ativo),
         (select count(*)::int from public.acesso_aparelhos a where a.user_id = g.user_id and a.expira_em > now()),
         ac.ultimo, coalesce(ac.dias, 0)::int, coalesce(ld.ativ30, 0)::int, coalesce(ld.clientes, 0)::int,
         coalesce(ld.jornada, 0)::int, coalesce(ld.jornada_sem_contato, 0)::int, coalesce(ld.atrasados, 0)::int,
         coalesce(tf.atrasadas, 0)::int
    from gente g
    left join ld on ld.uid = g.user_id
    left join ac on ac.uid = g.user_id
    left join tf on tf.uid = g.user_id
   where public.eh_super()
   order by g.ativo desc, g.nome;
$$;

-- ---------- 4b. Origens novas dos arquivos da ficha ----------
-- Liberdade Financeira, Ágio, Boletas e o Relatório Consolidado também gravam na ficha.
alter table public.anexos drop constraint if exists anexos_origem_check;
alter table public.anexos add constraint anexos_origem_check check (origem in
  ('upload','wealth_planning','plano_patrimonial','enquadramento','liberdade','agio','boletas','relatorio'));

-- ---------- 5. Permissões das funções ----------
revoke all on function public.aparelho_lembrar() from public, anon;
revoke all on function public.aparelho_entrar(text) from public, anon;
revoke all on function public.aparelhos_meus() from public, anon;
revoke all on function public.aparelho_esquecer(uuid) from public, anon;
revoke all on function public.meu_checklist() from public, anon;
revoke all on function public.problemas_lista() from public, anon;
revoke all on function public.problema_resolver(uuid, boolean) from public, anon;
revoke all on function public.painel_adocao() from public, anon;
grant execute on function public.aparelho_lembrar() to authenticated;
grant execute on function public.aparelho_entrar(text) to authenticated;
grant execute on function public.aparelhos_meus() to authenticated;
grant execute on function public.aparelho_esquecer(uuid) to authenticated;
grant execute on function public.meu_checklist() to authenticated;
grant execute on function public.problemas_lista() to authenticated;
grant execute on function public.problema_resolver(uuid, boolean) to authenticated;
grant execute on function public.painel_adocao() to authenticated;

-- Conferência
select (select count(*) from public.acesso_aparelhos) as aparelhos,
       (select count(*) from public.problemas) as problemas,
       (select count(*) from storage.buckets where id = 'problemas') as bucket_problemas;
