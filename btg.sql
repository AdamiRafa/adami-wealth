-- ============================================================
--  8.11. INTEGRAÇÃO COM O BTG, FASE 1: RECEBER E GUARDAR (06/11/2026)
--     O Hub pede os relatórios ao BTG (função btg-sync, agendada) e o
--     BTG entrega por webhook (função btg-webhook). Esta fase só RECEBE
--     e GUARDA numa área separada: não mexe em cliente, carteira nem
--     assessor. O CRM passa a usar esses dados na fase 2, pela mesma
--     prévia do "Atualizar base" (regras das seções 6 e 7).
--
--     Ninguém do navegador escreve aqui. Só master lê (tela de
--     conferência). Quem grava são as duas funções, com a chave de
--     serviço, pelas funções btg_* abaixo.
--
--     O agendamento começa DESLIGADO (btg_config.ligado = false): liga
--     depois que os webhooks estiverem cadastrados no portal do BTG.
-- ============================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------- 1. Tabelas ----------

create table if not exists public.btg_config (
  id        boolean primary key default true check (id),
  ligado    boolean not null default false,
  alterado_em timestamptz not null default now()
);
insert into public.btg_config (id) values (true) on conflict (id) do nothing;

-- O token do BTG vale 15 minutos: guardado para não pedir um novo a cada chamada.
create table if not exists public.btg_token (
  id        boolean primary key default true check (id),
  token     text not null,
  expira_em timestamptz not null
);

-- Cada pedido feito ao BTG (o que foi pedido e o que ele respondeu na hora).
create table if not exists public.btg_pedidos (
  id           bigint generated always as identity primary key,
  servico      text not null,
  metodo       text not null,
  caminho      text not null,
  corpo        jsonb,
  origem       text not null default 'agendado',
  pedido_em    timestamptz not null default now(),
  http_status  int,
  x_id_pactual text,
  resposta     text
);
create index if not exists btg_pedidos_em_idx on public.btg_pedidos (pedido_em desc);

-- Cada aviso que o BTG mandou ao webhook, e o arquivo baixado.
create table if not exists public.btg_arquivos (
  id            bigint generated always as identity primary key,
  servico       text not null,
  recebido_em   timestamptz not null default now(),
  aviso         jsonb not null default '{}'::jsonb,
  caminho       text,
  tamanho       bigint,
  linhas        int,
  colunas       text[],
  status        text not null check (status in ('recebido','guardado','processado','sem_dados','erro')),
  erro          text,
  processado_em timestamptz
);
create index if not exists btg_arquivos_em_idx on public.btg_arquivos (recebido_em desc);

-- Quem é o assessor de cada conta (rm-reports-account-link). Última versão recebida.
create table if not exists public.btg_vinculos (
  nr_conta     text primary key,
  cge_officer  text,
  login        text,
  nm_officer   text,
  cge_partner  text,
  ts_criado    text,
  arquivo_id   bigint references public.btg_arquivos(id) on delete set null,
  atualizado_em timestamptz not null default now()
);

-- Base de contas (rm-reports-account-base). Última versão recebida; a linha inteira fica em "dados".
create table if not exists public.btg_base (
  nr_conta      text primary key,
  nome          text,
  nm_assessor   text,
  cge_officer   text,
  email_assessor text,
  pl_total      numeric,
  dados         jsonb not null,
  arquivo_id    bigint references public.btg_arquivos(id) on delete set null,
  atualizado_em timestamptz not null default now()
);

-- Demais relatórios: linhas guardadas como vieram, por arquivo (posição, movimentação,
-- NNM, cadastro...). A fase 2 lê daqui conforme cada tela precisar.
create table if not exists public.btg_linhas (
  arquivo_id bigint not null references public.btg_arquivos(id) on delete cascade,
  n          int not null,
  nr_conta   text,
  dados      jsonb not null,
  primary key (arquivo_id, n)
);
create index if not exists btg_linhas_conta_idx on public.btg_linhas (nr_conta);

alter table public.btg_config   enable row level security;
alter table public.btg_token    enable row level security;
alter table public.btg_pedidos  enable row level security;
alter table public.btg_arquivos enable row level security;
alter table public.btg_vinculos enable row level security;
alter table public.btg_base     enable row level security;
alter table public.btg_linhas   enable row level security;

revoke all on public.btg_config, public.btg_token, public.btg_pedidos, public.btg_arquivos,
              public.btg_vinculos, public.btg_base, public.btg_linhas from public, anon, authenticated;
grant select on public.btg_config, public.btg_pedidos, public.btg_arquivos,
                public.btg_vinculos, public.btg_base, public.btg_linhas to authenticated;

-- Só master lê. O token nunca é lido por ninguém pela API.
do $$
declare t text;
begin
  foreach t in array array['btg_config','btg_pedidos','btg_arquivos','btg_vinculos','btg_base','btg_linhas'] loop
    execute format('drop policy if exists btg_master_ler on public.%I', t);
    execute format('create policy btg_master_ler on public.%I for select to authenticated using (public.eh_super())', t);
    execute format('drop policy if exists exige_verificacao on public.%I', t);
    execute format('create policy exige_verificacao on public.%I as restrictive for all to authenticated '
                   'using ((select public.acesso_liberado())) with check ((select public.acesso_liberado()))', t);
  end loop;
end $$;

-- ---------- 2. Arquivos brutos (Storage privado, só a chave de serviço) ----------

insert into storage.buckets (id, name, public, file_size_limit)
values ('btg', 'btg', false, 209715200)
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit;

-- ---------- 3. Funções que as Edge Functions chamam (só a chave de serviço) ----------

-- Normaliza número de conta: só dígitos, 9 posições (o Excel come os zeros à esquerda).
create or replace function public.btg_conta(p text)
returns text language sql immutable set search_path = public as $$
  select case when regexp_replace(coalesce(p, ''), '\D', '', 'g') = '' then null
              else lpad(regexp_replace(p, '\D', '', 'g'), 9, '0') end;
$$;

-- Número em texto do BTG: "235422,03", "1.234,56", "10.13", "1.06E+07".
create or replace function public.btg_numero(p text)
returns numeric language plpgsql immutable set search_path = public as $$
declare s text := btrim(coalesce(p, ''));
begin
  if s = '' then return null; end if;
  if s ~ '^-?[0-9.]+,[0-9]+$' then s := replace(replace(s, '.', ''), ',', '.');
  elsif s ~ '^-?[0-9]+,[0-9]+$' then s := replace(s, ',', '.');
  end if;
  return s::numeric;
exception when others then
  return null;
end $$;

create or replace function public.btg_token_atual()
returns text language sql stable security definer set search_path = public as $$
  select token from public.btg_token where expira_em > now() + interval '60 seconds';
$$;

create or replace function public.btg_token_guardar(p_token text, p_validade_seg int default 840)
returns void language sql security definer set search_path = public as $$
  insert into public.btg_token (id, token, expira_em) values (true, p_token, now() + make_interval(secs => p_validade_seg))
  on conflict (id) do update set token = excluded.token, expira_em = excluded.expira_em;
$$;

create or replace function public.btg_registrar_pedido(p_servico text, p_metodo text, p_caminho text, p_corpo jsonb,
  p_origem text, p_http int, p_x_id text, p_resposta text)
returns bigint language sql security definer set search_path = public as $$
  insert into public.btg_pedidos (servico, metodo, caminho, corpo, origem, http_status, x_id_pactual, resposta)
  values (p_servico, p_metodo, p_caminho, p_corpo, coalesce(p_origem, 'agendado'), p_http, p_x_id, left(p_resposta, 2000))
  returning id;
$$;

-- Registra o aviso do webhook (antes de baixar o arquivo).
create or replace function public.btg_aviso(p_servico text, p_aviso jsonb, p_status text, p_erro text default null)
returns bigint language sql security definer set search_path = public as $$
  insert into public.btg_arquivos (servico, aviso, status, erro) values (p_servico, coalesce(p_aviso, '{}'::jsonb), p_status, left(p_erro, 2000))
  returning id;
$$;

-- Recebe o arquivo já lido (linhas em JSON) e grava na área de recebimento.
create or replace function public.btg_receber(p_arquivo_id bigint, p_caminho text, p_tamanho bigint,
  p_colunas text[], p_linhas jsonb)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_servico text;
  v_n int := coalesce(jsonb_array_length(p_linhas), 0);
begin
  select servico into v_servico from public.btg_arquivos where id = p_arquivo_id;
  if v_servico is null then raise exception 'Arquivo % não existe.', p_arquivo_id; end if;

  update public.btg_arquivos set caminho = p_caminho, tamanho = p_tamanho, linhas = v_n, colunas = p_colunas,
         status = case when v_n = 0 then 'sem_dados' else 'guardado' end
   where id = p_arquivo_id;
  if v_n = 0 then return json_build_object('ok', true, 'linhas', 0); end if;

  if v_servico = 'rm-reports-account-link' then
    insert into public.btg_vinculos as v (nr_conta, cge_officer, login, nm_officer, cge_partner, ts_criado, arquivo_id, atualizado_em)
    select distinct on (public.btg_conta(x->>'nr_conta'))
           public.btg_conta(x->>'nr_conta'), x->>'cge_officer', x->>'login', x->>'nm_officer', x->>'cge_partner', x->>'ts_criado',
           p_arquivo_id, now()
      from jsonb_array_elements(p_linhas) x
     where public.btg_conta(x->>'nr_conta') is not null
    on conflict (nr_conta) do update set cge_officer = excluded.cge_officer, login = excluded.login,
      nm_officer = excluded.nm_officer, cge_partner = excluded.cge_partner, ts_criado = excluded.ts_criado,
      arquivo_id = excluded.arquivo_id, atualizado_em = now();

  elsif v_servico = 'rm-reports-account-base' then
    insert into public.btg_base as b (nr_conta, nome, nm_assessor, cge_officer, email_assessor, pl_total, dados, arquivo_id, atualizado_em)
    select distinct on (public.btg_conta(x->>'nr_conta'))
           public.btg_conta(x->>'nr_conta'), x->>'nome_completo', x->>'nm_assessor', x->>'cge_officer', x->>'email_assessor',
           public.btg_numero(x->>'pl_total'), x, p_arquivo_id, now()
      from jsonb_array_elements(p_linhas) x
     where public.btg_conta(x->>'nr_conta') is not null
    on conflict (nr_conta) do update set nome = excluded.nome, nm_assessor = excluded.nm_assessor,
      cge_officer = excluded.cge_officer, email_assessor = excluded.email_assessor, pl_total = excluded.pl_total,
      dados = excluded.dados, arquivo_id = excluded.arquivo_id, atualizado_em = now();

  else
    insert into public.btg_linhas (arquivo_id, n, nr_conta, dados)
    select p_arquivo_id, (o - 1)::int,
           public.btg_conta(coalesce(x->>'nr_conta', x->>'cod_carteira', x->>'accountNumber', x->>'account', x->>'conta')),
           x
      from jsonb_array_elements(p_linhas) with ordinality as t(x, o)
    on conflict (arquivo_id, n) do nothing;
  end if;

  update public.btg_arquivos set status = 'processado', processado_em = now() where id = p_arquivo_id;
  return json_build_object('ok', true, 'linhas', v_n);
end $$;

create or replace function public.btg_marcar_erro(p_arquivo_id bigint, p_erro text)
returns void language sql security definer set search_path = public as $$
  update public.btg_arquivos set status = 'erro', erro = left(p_erro, 2000) where id = p_arquivo_id;
$$;

-- Token do agendamento: gerado aqui, fica no Vault e nunca sai do banco. O agendamento
-- manda o token à função btg-sync, que pergunta ao banco se confere.
do $$
begin
  if not exists (select 1 from vault.secrets where name = 'btg_sync_token') then
    perform vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'), 'btg_sync_token',
                                'Token do agendamento que chama a função btg-sync');
  end if;
end $$;

create or replace function public.btg_sync_token_ok(p text)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(length(p), 0) >= 32 and exists (
    select 1 from vault.decrypted_secrets where name = 'btg_sync_token' and decrypted_secret = p);
$$;

create or replace function public.btg_ligado()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select ligado from public.btg_config limit 1), false);
$$;

revoke execute on function public.btg_token_atual(), public.btg_token_guardar(text, int),
  public.btg_registrar_pedido(text, text, text, jsonb, text, int, text, text),
  public.btg_aviso(text, jsonb, text, text),
  public.btg_receber(bigint, text, bigint, text[], jsonb),
  public.btg_marcar_erro(bigint, text), public.btg_sync_token_ok(text), public.btg_ligado()
  from public, anon, authenticated;
grant execute on function public.btg_token_atual(), public.btg_token_guardar(text, int),
  public.btg_registrar_pedido(text, text, text, jsonb, text, int, text, text),
  public.btg_aviso(text, jsonb, text, text),
  public.btg_receber(bigint, text, bigint, text[], jsonb),
  public.btg_marcar_erro(bigint, text), public.btg_sync_token_ok(text), public.btg_ligado()
  to service_role;

-- ---------- 4. Agendamento (dias úteis; horário em UTC = Brasília + 3h) ----------
--   8h30: vínculo, base, cadastro, posição de D-1 e movimentação (janelas do BTG: 7h e 8h)
--  15h30: NNM (janela das 15h)
--  20h30: movimentação do fim do dia (janela das 20h)
-- A função não faz nada enquanto btg_config.ligado = false.

do $$
declare j text;
begin
  foreach j in array array['btg-manha','btg-tarde','btg-noite'] loop
    begin perform cron.unschedule(j); exception when others then null; end;
  end loop;
end $$;

select cron.schedule('btg-manha', '30 11 * * 1-5', $c$
  select net.http_post(
    url := 'https://ghxjqmjtmbqzvogwzylo.supabase.co/functions/v1/btg-sync',
    headers := jsonb_build_object('Content-Type', 'application/json',
      'x-btg-sync', (select decrypted_secret from vault.decrypted_secrets where name = 'btg_sync_token')),
    body := '{"janela":"manha"}'::jsonb, timeout_milliseconds := 60000);
$c$);
select cron.schedule('btg-tarde', '30 18 * * 1-5', $c$
  select net.http_post(
    url := 'https://ghxjqmjtmbqzvogwzylo.supabase.co/functions/v1/btg-sync',
    headers := jsonb_build_object('Content-Type', 'application/json',
      'x-btg-sync', (select decrypted_secret from vault.decrypted_secrets where name = 'btg_sync_token')),
    body := '{"janela":"tarde"}'::jsonb, timeout_milliseconds := 60000);
$c$);
select cron.schedule('btg-noite', '30 23 * * 1-5', $c$
  select net.http_post(
    url := 'https://ghxjqmjtmbqzvogwzylo.supabase.co/functions/v1/btg-sync',
    headers := jsonb_build_object('Content-Type', 'application/json',
      'x-btg-sync', (select decrypted_secret from vault.decrypted_secrets where name = 'btg_sync_token')),
    body := '{"janela":"noite"}'::jsonb, timeout_milliseconds := 60000);
$c$);

-- Limpeza: linhas brutas com mais de 120 dias (os arquivos originais ficam no Storage).
create or replace function public.btg_limpeza()
returns void language sql security definer set search_path = public as $$
  delete from public.btg_linhas l using public.btg_arquivos a
   where a.id = l.arquivo_id and a.recebido_em < now() - interval '120 days';
  delete from public.btg_pedidos where pedido_em < now() - interval '400 days';
  delete from public.btg_token where expira_em < now() - interval '1 day';
$$;
revoke execute on function public.btg_limpeza() from public, anon, authenticated;
do $$ begin perform cron.unschedule('btg-limpeza'); exception when others then null; end $$;
select cron.schedule('btg-limpeza', '40 6 * * 0', $c$ select public.btg_limpeza(); $c$);
