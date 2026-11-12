-- ============================================================
-- carteiras_envio.sql · Hub 3.20 (12/11/2026)
--
-- 1. clientes.lead_id: a carteira ligada à ficha do CRM (escolhida na tela; ao ligar,
--    a conta do BTG da ficha entra em contas_btg). Substitui a ligação pelo nome, que
--    errava: clientes cadastrados pelo primeiro nome batem com vários cartões.
-- 2. clientes.emails_relatorio: para quem vai o Relatório Consolidado.
-- 3. relatorios_envios + funções: o envio sai pela função relatorio-enviar (caixa
--    hub@adamicaptal.com.br). Os destinatários vêm daqui, nunca da tela, e só com o mês
--    marcado como feito. Cada envio fica registrado.
--
-- Como instalar: SQL Editor do Supabase, colar o arquivo inteiro, Run.
-- O aviso "Potential issues detected" é falso positivo: Run without RLS.
-- Pode rodar mais de uma vez.
-- ============================================================

alter table public.clientes add column if not exists lead_id text references public.leads(id) on delete set null;
alter table public.clientes add column if not exists emails_relatorio text[] not null default '{}';
create index if not exists clientes_lead_idx on public.clientes (lead_id);
alter table public.clientes drop constraint if exists clientes_emails_relatorio_check;
alter table public.clientes add constraint clientes_emails_relatorio_check check (
  coalesce(array_length(emails_relatorio, 1), 0) <= 5);

create table if not exists public.relatorios_envios (
  id          uuid primary key default gen_random_uuid(),
  cliente_id  uuid not null references public.clientes(id) on delete cascade,
  mes         smallint not null check (mes between 1 and 12),
  ano         smallint not null,
  para        text[] not null default '{}',
  enviado_por uuid references auth.users(id) on delete set null,
  enviado_em  timestamptz not null default now(),
  erro        text
);
create index if not exists relatorios_envios_cli_idx on public.relatorios_envios (cliente_id, ano, mes, enviado_em desc);
alter table public.relatorios_envios enable row level security;
revoke all on public.relatorios_envios from public, anon, authenticated;
grant select on public.relatorios_envios to authenticated;
drop policy if exists exige_verificacao on public.relatorios_envios;
create policy exige_verificacao on public.relatorios_envios as restrictive for all to authenticated
  using ( public.acesso_liberado() ) with check ( public.acesso_liberado() );
drop policy if exists envios_ler on public.relatorios_envios;
create policy envios_ler on public.relatorios_envios for select to authenticated
  using ( public.meu_cliente(cliente_id) or public.eh_admin() );

-- Prepara o envio: confere quem pede, o mês feito e devolve destinatários e assessor.
create or replace function public.relatorio_envio_preparar(p_cliente uuid, p_mes int, p_ano int)
returns json language plpgsql stable security definer set search_path = public as $$
declare
  c record; l record; v_assessor text; v_assessor_email text;
begin
  if auth.uid() is null or not public.acesso_liberado() then raise exception 'Sessão inválida. Entre de novo.'; end if;
  if not (public.meu_cliente(p_cliente) or public.eh_admin()) then raise exception 'Você não tem acesso a este cliente.'; end if;
  select * into c from public.clientes where id = p_cliente;
  if not found then raise exception 'Cliente não encontrado.'; end if;
  select * into l from public.lancamentos where cliente_id = p_cliente and mes = p_mes and ano = p_ano;
  if not found then raise exception 'Este mês ainda não foi lançado.'; end if;
  if l.feito_em is null then raise exception 'Marque o mês como feito antes de enviar ao cliente.'; end if;
  if coalesce(array_length(c.emails_relatorio, 1), 0) = 0 then raise exception 'Cadastre o e-mail para relatórios deste cliente.'; end if;
  select p.nome, u.email::text into v_assessor, v_assessor_email
    from auth.users u left join public.perfis p on p.user_id = u.id where u.id = c.assessor_id;
  return json_build_object('cliente', c.nome, 'para', c.emails_relatorio,
    'assessor', coalesce(v_assessor, ''), 'assessor_email', coalesce(v_assessor_email, ''),
    'eu_email', (select email::text from auth.users where id = auth.uid()),
    'eu_nome', (select nome from public.perfis where user_id = auth.uid()));
end $$;

create or replace function public.relatorio_envio_registrar(p_cliente uuid, p_mes int, p_ano int, p_para text[], p_erro text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or not public.acesso_liberado() then raise exception 'Sessão inválida.'; end if;
  if not (public.meu_cliente(p_cliente) or public.eh_admin()) then raise exception 'Sem acesso.'; end if;
  insert into public.relatorios_envios (cliente_id, mes, ano, para, enviado_por, erro)
  values (p_cliente, p_mes, p_ano, coalesce(p_para, '{}'), auth.uid(), left(p_erro, 400));
end $$;

revoke all on function public.relatorio_envio_preparar(uuid, int, int) from public, anon;
revoke all on function public.relatorio_envio_registrar(uuid, int, int, text[], text) from public, anon;
grant execute on function public.relatorio_envio_preparar(uuid, int, int) to authenticated;
grant execute on function public.relatorio_envio_registrar(uuid, int, int, text[], text) to authenticated;

-- Conferência
select count(*) filter (where lead_id is not null) as ligados, count(*) as clientes from public.clientes;
