-- ============================================================
--  8.14. BTG FASE 3: RENTABILIDADE MENSAL NAS CARTEIRAS (06/11/2026)
--     API de Rentabilidade Mensal do BTG (iaas-profitability), três
--     relatórios assíncronos que chegam pelo btg-webhook:
--       monthly-customer-profitability  a carteira (conta) no mês: saldo,
--                                       movimentação, lucro, rentabilidade
--                                       e os índices (CDI, Ibov, IMA-B...)
--       monthly-product-profitability   cada produto da conta no mês
--       monthly-strategy-profitability  a conta por estratégia no mês
--     Um pedido traz o histórico (até 12 meses) até o mês pedido. Fica
--     guardado por conta e mês: pedir de novo atualiza, não duplica.
--
--     Nas Carteiras, o botão "Puxar do BTG" (Preencher) lê daqui as contas
--     BTG do cliente (clientes.contas_btg) e preenche a conta BTG, a lista
--     de ativos do BTG, a alocação por estratégia e os índices. As contas e
--     ativos de outros bancos continuam na mão. Nada grava sem "Salvar mês".
--
--     Pode rodar de novo sem estragar nada.
-- ============================================================

-- ---------- 1. Contas BTG de cada cliente das Carteiras ----------
alter table public.clientes add column if not exists contas_btg text[] not null default '{}';
create index if not exists clientes_contas_btg_idx on public.clientes using gin (contas_btg);

-- Sempre 9 dígitos, sem repetir, sem vazio ("12345" e "000012345" são a mesma conta).
create or replace function public.clientes_contas_btg_normalizar()
returns trigger language plpgsql set search_path = public as $$
begin
  new.contas_btg := coalesce((select array_agg(distinct c order by c)
                                from (select public.btg_conta(x) c from unnest(new.contas_btg) x) t
                               where c is not null), '{}');
  if cardinality(new.contas_btg) > 20 then raise exception 'No máximo 20 contas BTG por cliente.'; end if;
  return new;
end $$;
drop trigger if exists clientes_contas_btg on public.clientes;
create trigger clientes_contas_btg before insert or update of contas_btg on public.clientes
  for each row execute function public.clientes_contas_btg_normalizar();
revoke all on function public.clientes_contas_btg_normalizar() from public, anon, authenticated;

-- ---------- 2. Onde a rentabilidade fica ----------
create table if not exists public.btg_rent_carteira (
  nr_conta      text not null,
  mes_ref       date not null,               -- sempre dia 1
  dados         jsonb not null,              -- a linha inteira do BTG
  arquivo_id    bigint references public.btg_arquivos(id) on delete set null,
  atualizado_em timestamptz not null default now(),
  primary key (nr_conta, mes_ref)
);
create table if not exists public.btg_rent_produto (
  nr_conta      text not null,
  mes_ref       date not null,
  produto       text not null,               -- product_key, senão product_id, senão o nome
  dados         jsonb not null,
  arquivo_id    bigint references public.btg_arquivos(id) on delete set null,
  atualizado_em timestamptz not null default now(),
  primary key (nr_conta, mes_ref, produto)
);
create table if not exists public.btg_rent_estrategia (
  nr_conta      text not null,
  mes_ref       date not null,
  estrategia    text not null,
  dados         jsonb not null,
  arquivo_id    bigint references public.btg_arquivos(id) on delete set null,
  atualizado_em timestamptz not null default now(),
  primary key (nr_conta, mes_ref, estrategia)
);
create index if not exists btg_rent_carteira_mes_idx on public.btg_rent_carteira (mes_ref);
alter table public.btg_rent_carteira   enable row level security;
alter table public.btg_rent_produto    enable row level security;
alter table public.btg_rent_estrategia enable row level security;
-- Sem política: ninguém lê direto. As Carteiras leem por btg_rent_cliente, que confere o cliente.
revoke all on public.btg_rent_carteira, public.btg_rent_produto, public.btg_rent_estrategia from anon, authenticated;

-- "2023-01-01", "2023-01", "9/1/2023" (mês/dia/ano, como no dicionário do BTG) -> dia 1 do mês.
create or replace function public.btg_mes_ref(p text)
returns date language plpgsql immutable set search_path = public as $$
declare s text := btrim(coalesce(p, '')); m text[];
begin
  m := regexp_match(s, '^(\d{4})-(\d{1,2})');
  if m is not null then return make_date(m[1]::int, m[2]::int, 1); end if;
  m := regexp_match(s, '^(\d{1,2})/(\d{1,2})/(\d{4})');
  if m is not null then return make_date(m[3]::int, m[1]::int, 1); end if;
  m := regexp_match(s, '^(\d{1,2})/(\d{4})$');
  if m is not null then return make_date(m[2]::int, m[1]::int, 1); end if;
  return null;
exception when others then return null;
end $$;

-- Recebe um lote de linhas (o btg-webhook manda o arquivo em pedaços) e, no último,
-- fecha o arquivo. Só a chave de serviço chama.
create or replace function public.btg_rent_receber(p_arquivo_id bigint, p_linhas jsonb,
  p_final boolean default false, p_total int default null, p_caminho text default null,
  p_tamanho bigint default null, p_colunas text[] default null)
returns json language plpgsql security definer set search_path = public as $$
declare v_servico text; v_n int := 0;
begin
  select servico into v_servico from public.btg_arquivos where id = p_arquivo_id;
  if v_servico is null then raise exception 'Arquivo % não existe.', p_arquivo_id; end if;

  if p_linhas is not null and jsonb_array_length(p_linhas) > 0 then
    if v_servico = 'monthly-customer-profitability' then
      insert into public.btg_rent_carteira as t (nr_conta, mes_ref, dados, arquivo_id, atualizado_em)
      select distinct on (c, m) c, m, x, p_arquivo_id, now()
        from (select public.btg_conta(x->>'cod_carteira') c,
                     public.btg_mes_ref(coalesce(nullif(x->>'reference_month', ''), x->>'reference_date')) m, x
                from jsonb_array_elements(p_linhas) x) s
       where c is not null and m is not null
       order by c, m
      on conflict (nr_conta, mes_ref) do update set dados = excluded.dados, arquivo_id = excluded.arquivo_id, atualizado_em = now();
    elsif v_servico = 'monthly-product-profitability' then
      insert into public.btg_rent_produto as t (nr_conta, mes_ref, produto, dados, arquivo_id, atualizado_em)
      select distinct on (c, m, pr) c, m, pr, x, p_arquivo_id, now()
        from (select public.btg_conta(x->>'cod_carteira') c, public.btg_mes_ref(x->>'reference_month') m,
                     coalesce(nullif(x->>'product_key', ''), nullif(x->>'product_id', ''), nullif(x->>'product_name', ''), '?') pr, x
                from jsonb_array_elements(p_linhas) x) s
       where c is not null and m is not null
       order by c, m, pr
      on conflict (nr_conta, mes_ref, produto) do update set dados = excluded.dados, arquivo_id = excluded.arquivo_id, atualizado_em = now();
    elsif v_servico = 'monthly-strategy-profitability' then
      insert into public.btg_rent_estrategia as t (nr_conta, mes_ref, estrategia, dados, arquivo_id, atualizado_em)
      select distinct on (c, m, e) c, m, e, x, p_arquivo_id, now()
        from (select public.btg_conta(x->>'cod_carteira') c, public.btg_mes_ref(x->>'reference_month') m,
                     coalesce(nullif(btrim(x->>'asset_allocation_strategy'), ''), 'Sem estratégia') e, x
                from jsonb_array_elements(p_linhas) x) s
       where c is not null and m is not null
       order by c, m, e
      on conflict (nr_conta, mes_ref, estrategia) do update set dados = excluded.dados, arquivo_id = excluded.arquivo_id, atualizado_em = now();
    else
      raise exception 'Serviço % não é de rentabilidade.', v_servico;
    end if;
    get diagnostics v_n = row_count;
  end if;

  if p_final then
    update public.btg_arquivos
       set caminho = coalesce(p_caminho, caminho), tamanho = coalesce(p_tamanho, tamanho),
           linhas = coalesce(p_total, linhas), colunas = coalesce(p_colunas, colunas),
           status = case when coalesce(p_total, 0) = 0 then 'sem_dados' else 'processado' end,
           processado_em = now()
     where id = p_arquivo_id;
  end if;
  return json_build_object('ok', true, 'gravadas', v_n);
end $$;
revoke all on function public.btg_rent_receber(bigint, jsonb, boolean, int, text, bigint, text[]) from public, anon, authenticated;
grant execute on function public.btg_rent_receber(bigint, jsonb, boolean, int, text, bigint, text[]) to service_role;

-- ---------- 3. O que as Carteiras leem ----------
-- Nome sem acento, minúsculo, só letras e números (para sugerir a conta pelo nome).
create or replace function public.btg_nome_norm(p text)
returns text language sql immutable set search_path = public as $$
  select btrim(regexp_replace(regexp_replace(lower(translate(coalesce(p, ''),
    'ÁÀÂÃÄáàâãäÉÈÊËéèêëÍÌÎÏíìîïÓÒÔÕÖóòôõöÚÙÛÜúùûüÇçÑñ',
    'AAAAAaaaaaEEEEeeeeIIIIiiiiOOOOOoooooUUUUuuuuCcNn')), '[^a-z0-9 ]', ' ', 'g'), '\s+', ' ', 'g'));
$$;

-- Rentabilidade de um cliente num mês, somando as contas BTG dele.
-- Quem vê o cliente nas Carteiras (dono ou "ver todas as carteiras") vê isto.
create or replace function public.btg_rent_cliente(p_cliente uuid, p_mes int, p_ano int)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_contas text[]; v_mes date;
begin
  if not public.meu_cliente(p_cliente) then raise exception 'Sem acesso a este cliente.'; end if;
  if p_mes not between 1 and 12 or p_ano not between 2000 and 2100 then raise exception 'Mês inválido.'; end if;
  select contas_btg into v_contas from public.clientes where id = p_cliente;
  v_mes := make_date(p_ano, p_mes, 1);
  return jsonb_build_object(
    'contas', to_jsonb(coalesce(v_contas, '{}')),
    'mes_ref', v_mes,
    'carteira', coalesce((select jsonb_agg(jsonb_build_object('nr_conta', nr_conta, 'dados', dados, 'atualizado_em', atualizado_em) order by nr_conta)
                            from public.btg_rent_carteira where nr_conta = any (v_contas) and mes_ref = v_mes), '[]'),
    'produtos', coalesce((select jsonb_agg(jsonb_build_object('nr_conta', nr_conta, 'dados', dados) order by nr_conta, produto)
                            from public.btg_rent_produto where nr_conta = any (v_contas) and mes_ref = v_mes), '[]'),
    'estrategias', coalesce((select jsonb_agg(jsonb_build_object('nr_conta', nr_conta, 'estrategia', estrategia, 'dados', dados) order by nr_conta, estrategia)
                               from public.btg_rent_estrategia where nr_conta = any (v_contas) and mes_ref = v_mes), '[]'),
    'ultimo_mes', (select max(mes_ref) from public.btg_rent_carteira where nr_conta = any (v_contas)),
    'ultimo_mes_casa', (select max(mes_ref) from public.btg_rent_carteira));
end $$;
revoke all on function public.btg_rent_cliente(uuid, int, int) from public, anon;
grant execute on function public.btg_rent_cliente(uuid, int, int) to authenticated;

-- Sugestão de conta pelo nome: base de contas do BTG e a conta anotada no CRM.
create or replace function public.btg_sugerir_contas(p_cliente uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_nome text;
begin
  if not public.meu_cliente(p_cliente) then raise exception 'Sem acesso a este cliente.'; end if;
  select public.btg_nome_norm(nome) into v_nome from public.clientes where id = p_cliente;
  if coalesce(v_nome, '') = '' then return '[]'; end if;
  return coalesce((
    select jsonb_agg(distinct jsonb_build_object('nr_conta', conta, 'nome', nome, 'fonte', fonte))
      from (
        select b.nr_conta conta, b.nome, 'BTG' fonte from public.btg_base b where public.btg_nome_norm(b.nome) = v_nome
        union all
        select public.btg_conta(l.conta), l.cliente, 'CRM' from public.leads l
         where public.btg_nome_norm(l.cliente) = v_nome and public.btg_conta(l.conta) is not null
           and not coalesce(l.excluido, false)
      ) s where conta is not null), '[]');
end $$;
revoke all on function public.btg_sugerir_contas(uuid) from public, anon;
grant execute on function public.btg_sugerir_contas(uuid) to authenticated;

-- ---------- 4. Pedido mensal ----------
-- Dias 2 e 5 de cada mês, 9h de Brasília: pede o mês corrente, que traz o histórico até
-- o dia 1 (o mês anterior fechado). Duas tentativas porque o BTG pode fechar o mês com
-- atraso; pedir de novo só atualiza. 3 relatórios por pedido, dentro do limite de 12/dia.
do $$ begin perform cron.unschedule('btg-rentabilidade'); exception when others then null; end $$;
select cron.schedule('btg-rentabilidade', '0 12 2,5 * *', $c$
  select net.http_post(
    url := 'https://ghxjqmjtmbqzvogwzylo.supabase.co/functions/v1/btg-sync',
    headers := jsonb_build_object('Content-Type', 'application/json',
      'x-btg-sync', (select decrypted_secret from vault.decrypted_secrets where name = 'btg_sync_token')),
    body := '{"janela":"rentabilidade"}'::jsonb, timeout_milliseconds := 60000);
$c$);

-- Botão do master para pedir agora (ex.: logo depois de ligar a integração).
-- O token do agendamento sai do Vault só aqui dentro, nunca para o navegador.
create or replace function public.btg_pedir_agora(p_janela text)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_id bigint;
begin
  if not public.eh_super() then raise exception 'Apenas o master pode pedir relatórios ao BTG.'; end if;
  if p_janela not in ('rentabilidade', 'manha', 'tarde', 'noite') then raise exception 'Pedido desconhecido.'; end if;
  select net.http_post(
    url := 'https://ghxjqmjtmbqzvogwzylo.supabase.co/functions/v1/btg-sync',
    headers := jsonb_build_object('Content-Type', 'application/json',
      'x-btg-sync', (select decrypted_secret from vault.decrypted_secrets where name = 'btg_sync_token')),
    body := jsonb_build_object('janela', p_janela), timeout_milliseconds := 60000) into v_id;
  insert into public.auditoria (usuario, acao, alvo, detalhe)
  values (coalesce(auth.jwt() ->> 'email', '?'), 'pediu relatório ao BTG', p_janela, '');
  return v_id;
end $$;
revoke all on function public.btg_pedir_agora(text) from public, anon;
grant execute on function public.btg_pedir_agora(text) to authenticated;
