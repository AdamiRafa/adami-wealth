-- Relatório de Performance do BTG nas Carteiras (Hub 3.33, 19/11/2026).
-- O Hub pede ao BTG, nos dias 2 e 5, o Relatório de Performance (PDF) do mês anterior de cada conta vinculada
-- no cadastro dos clientes (função btg-sync, janela "performance"); o PDF chega pela btg-webhook, fica no
-- Storage privado "btg" (performance-report/pdf/AAAA-MM/<conta>.pdf) e uma linha em btg_linhas.
-- As Carteiras mostram "Aplicar relatório do BTG" no mês do cliente. Rodar inteiro no SQL Editor (Run without RLS).

-- 1. Quem pode baixar o PDF: só quem enxerga um cliente que tem aquela conta vinculada (e com o acesso do dia).
create or replace function public.btg_pode_ler_pdf(p_nome text)
returns boolean language sql stable security definer set search_path = public as $$
  select public.acesso_liberado() and p_nome like 'performance-report/pdf/%' and exists (
    select 1 from public.btg_linhas l join public.btg_arquivos a on a.id = l.arquivo_id
     where a.servico = 'performance-report' and l.dados->>'caminho' = p_nome and l.nr_conta is not null
       and exists (select 1 from public.clientes c
                    where public.meu_cliente(c.id)
                      and exists (select 1 from unnest(coalesce(c.contas_btg, '{}')) k
                                   where ltrim(regexp_replace(k, '\D', '', 'g'), '0') = ltrim(l.nr_conta, '0'))));
$$;
revoke all on function public.btg_pode_ler_pdf(text) from public, anon;
grant execute on function public.btg_pode_ler_pdf(text) to authenticated;

drop policy if exists btg_performance_ler on storage.objects;
create policy btg_performance_ler on storage.objects for select to authenticated
  using (bucket_id = 'btg' and (select public.btg_pode_ler_pdf(name)));

-- 2. Os relatórios do mês de um cliente: o mais recente de cada conta vinculada.
create or replace function public.btg_performance_cliente(p_cliente uuid, p_mes int, p_ano int)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.acesso_liberado() then raise exception 'Acesso não liberado.'; end if;
  if not public.meu_cliente(p_cliente) then raise exception 'Sem acesso a este cliente.'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('conta', conta, 'caminho', caminho, 'arquivo', arquivo, 'inicio', inicio,
                                        'fim', fim, 'recebido_em', recebido_em) order by conta)
      from (select distinct on (ltrim(l.nr_conta, '0'))
                   l.nr_conta conta, l.dados->>'caminho' caminho, l.dados->>'arquivo' arquivo,
                   l.dados->>'inicio' inicio, l.dados->>'fim' fim, a.recebido_em
              from public.btg_linhas l join public.btg_arquivos a on a.id = l.arquivo_id
             where a.servico = 'performance-report' and a.status = 'processado'
               and left(l.dados->>'fim', 7) = to_char(make_date(p_ano, p_mes, 1), 'YYYY-MM')
               and ltrim(l.nr_conta, '0') in (select ltrim(regexp_replace(k, '\D', '', 'g'), '0')
                                                from public.clientes c, unnest(coalesce(c.contas_btg, '{}')) k
                                               where c.id = p_cliente)
             order by ltrim(l.nr_conta, '0'), a.recebido_em desc) s), '[]'::jsonb);
end $$;
revoke all on function public.btg_performance_cliente(uuid, int, int) from public, anon;
grant execute on function public.btg_performance_cliente(uuid, int, int) to authenticated;

-- 3. Pedido mensal: dias 2 e 5, 9h10 de Brasília (12h10 UTC), depois da rentabilidade.
do $$ begin perform cron.unschedule('btg-performance'); exception when others then null; end $$;
select cron.schedule('btg-performance', '10 12 2,5 * *', $c$
  select net.http_post(
    url := 'https://ghxjqmjtmbqzvogwzylo.supabase.co/functions/v1/btg-sync',
    headers := jsonb_build_object('Content-Type', 'application/json',
      'x-btg-sync', (select decrypted_secret from vault.decrypted_secrets where name = 'btg_sync_token')),
    body := '{"janela":"performance"}'::jsonb, timeout_milliseconds := 120000);
$c$);
