-- Compromissos do Outlook na Agenda (19/11/2026, preparado; liga quando o administrador do Microsoft 365 autorizar).
-- A função outlook-agenda (Edge Function) lê, só para leitura, o calendário de cada pessoa do Hub com e-mail
-- @adamicaptal.com.br, do dia anterior até 14 dias à frente, pelo Microsoft Graph com a credencial do aplicativo
-- (M365_TENANT_ID, M365_CLIENT_ID, M365_CLIENT_SECRET nos Secrets do Supabase). Guarda aqui; a Agenda do CRM e o
-- e-mail da manhã mostram como Compromissos. Quem lê: a própria pessoa, o admin do CRM e o master.
-- O agendamento "outlook-agenda" nasce DESLIGADO; liga-se depois de cadastrar os três Secrets.
-- Rodar inteiro no SQL Editor (Run without RLS).

create table if not exists public.agenda_outlook (
  id           text primary key,              -- <user_id>:<id do evento no Outlook>
  user_id      uuid not null,
  inicio       timestamptz not null,
  fim          timestamptz,
  dia_inteiro  boolean not null default false,
  assunto      text not null default '',
  local        text not null default '',
  online       boolean not null default false,
  organizador  text not null default '',
  mostrar_como text not null default '',
  atualizado_em timestamptz not null default now()
);
create index if not exists agenda_outlook_user on public.agenda_outlook (user_id, inicio);
alter table public.agenda_outlook enable row level security;
drop policy if exists agenda_outlook_ler on public.agenda_outlook;
create policy agenda_outlook_ler on public.agenda_outlook for select to authenticated
  using ((select public.is_ativo()) and (user_id = (select auth.uid()) or (select public.is_admin()) or (select public.eh_super())));
drop policy if exists exige_verificacao on public.agenda_outlook;
create policy exige_verificacao on public.agenda_outlook as restrictive for all to authenticated
  using ((select public.acesso_liberado())) with check ((select public.acesso_liberado()));
drop policy if exists exige_ferramenta on public.agenda_outlook;
create policy exige_ferramenta on public.agenda_outlook as restrictive for all to authenticated
  using ((select public.tem_permissao('ferramenta.crm'))) with check ((select public.tem_permissao('ferramenta.crm')));

-- Agendamento: a cada 30 minutos, das 6h às 20h30 de Brasília, dias úteis. Nasce desligado.
do $$ begin perform cron.unschedule('outlook-agenda'); exception when others then null; end $$;
select cron.schedule('outlook-agenda', '*/30 9-23 * * 1-5', $c$
  select net.http_post(
    url := 'https://ghxjqmjtmbqzvogwzylo.supabase.co/functions/v1/outlook-agenda',
    headers := jsonb_build_object('Content-Type', 'application/json',
      'x-btg-sync', (select decrypted_secret from vault.decrypted_secrets where name = 'btg_sync_token')),
    body := '{}'::jsonb, timeout_milliseconds := 60000);
$c$);
select cron.alter_job(job_id := (select jobid from cron.job where jobname = 'outlook-agenda'), active := false);
