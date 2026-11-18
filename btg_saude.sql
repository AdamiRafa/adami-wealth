-- Automação do BTG sem cuidado manual (Hub, 18/11/2026).
-- 1. Limpeza diária: posição por data e cadastro ficam 10 dias (só o mais recente é usado; ~8 mil linhas por dia),
--    o resto 120 dias. Antes: tudo 120 dias, uma vez por semana (a posição sozinha passaria de 1 GB).
-- 2. Segunda tentativa: às 10h (13h UTC) a btg-sync pede de novo o relatório da manhã que não chegou; às 17h (20h UTC),
--    a captação líquida. Arquivos originais com mais de 60 dias saem do Storage (janela "limpeza-arquivos", domingo).
-- 3. btg_saude(): último recebimento de cada relatório, para a tela Atualizar base do CRM (só quem vê todos os clientes).
-- Rodar inteiro no SQL Editor (Run without RLS).
create or replace function public.btg_limpeza()
returns void language sql security definer set search_path = public as $$
  delete from public.btg_linhas l using public.btg_arquivos a
   where a.id = l.arquivo_id and a.servico in ('rm-reports-position-by-date', 'rm-reports-registration-data')
     and a.recebido_em < now() - interval '10 days';
  delete from public.btg_linhas l using public.btg_arquivos a
   where a.id = l.arquivo_id and a.recebido_em < now() - interval '120 days';
  delete from public.btg_pedidos where pedido_em < now() - interval '400 days';
  delete from public.btg_token where expira_em < now() - interval '1 day';
$$;
revoke all on function public.btg_limpeza() from public, anon, authenticated;

create or replace function public.btg_saude()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.acesso_liberado() then raise exception 'Acesso não liberado.'; end if;
  if not public.is_admin() then raise exception 'Só quem vê todos os clientes do CRM.'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('servico', s.servico, 'ultimo_ok', ok.em, 'linhas', ok.linhas,
             'ultimo_aviso', av.em, 'ultimo_status', av.status, 'ultimo_erro', av.erro) order by s.servico)
      from (select distinct servico from public.btg_arquivos) s
      left join lateral (select recebido_em em, linhas from public.btg_arquivos a
                          where a.servico = s.servico and a.status = 'processado' order by a.id desc limit 1) ok on true
      left join lateral (select recebido_em em, status, left(erro, 200) erro from public.btg_arquivos a
                          where a.servico = s.servico order by a.id desc limit 1) av on true), '[]'::jsonb);
end $$;
revoke all on function public.btg_saude() from public, anon;
grant execute on function public.btg_saude() to authenticated;

do $$ begin perform cron.unschedule('btg-limpeza'); exception when others then null; end $$;
select cron.schedule('btg-limpeza', '40 6 * * *', $c$ select public.btg_limpeza(); $c$);

do $$ begin perform cron.unschedule('btg-reforco-manha'); exception when others then null; end $$;
select cron.schedule('btg-reforco-manha', '0 13 * * 1-5', $c$
  select net.http_post(
    url := 'https://ghxjqmjtmbqzvogwzylo.supabase.co/functions/v1/btg-sync',
    headers := jsonb_build_object('Content-Type', 'application/json',
      'x-btg-sync', (select decrypted_secret from vault.decrypted_secrets where name = 'btg_sync_token')),
    body := '{"janela":"reforco","de":"manha"}'::jsonb, timeout_milliseconds := 60000);
$c$);

do $$ begin perform cron.unschedule('btg-reforco-tarde'); exception when others then null; end $$;
select cron.schedule('btg-reforco-tarde', '0 20 * * 1-5', $c$
  select net.http_post(
    url := 'https://ghxjqmjtmbqzvogwzylo.supabase.co/functions/v1/btg-sync',
    headers := jsonb_build_object('Content-Type', 'application/json',
      'x-btg-sync', (select decrypted_secret from vault.decrypted_secrets where name = 'btg_sync_token')),
    body := '{"janela":"reforco","de":"tarde"}'::jsonb, timeout_milliseconds := 60000);
$c$);

do $$ begin perform cron.unschedule('btg-limpeza-arquivos'); exception when others then null; end $$;
select cron.schedule('btg-limpeza-arquivos', '50 6 * * 0', $c$
  select net.http_post(
    url := 'https://ghxjqmjtmbqzvogwzylo.supabase.co/functions/v1/btg-sync',
    headers := jsonb_build_object('Content-Type', 'application/json',
      'x-btg-sync', (select decrypted_secret from vault.decrypted_secrets where name = 'btg_sync_token')),
    body := '{"janela":"limpeza-arquivos"}'::jsonb, timeout_milliseconds := 120000);
$c$);
