-- ============================================================
--  Conferência 360 (19/11/2026, Hub 3.41). Pedido do Emil: "confere 360 no detalhe em TODAS
--  funções, usabilidade, acessos, para validar e corrigir aquilo que precisar".
--  Rodar inteiro no SQL Editor (Run without RLS). Pode rodar de novo.
-- ============================================================

-- 1. CRM lento para o assessor. crm_fichas_visiveis() chamava pode_ver_lead() ficha por ficha
--    (cada chamada refaz as checagens de acesso): ~5 s para quem tem 140 fichas, e o NNM, a
--    Captação, os Vencimentos, o Dinheiro parado e os itens do BTG na Agenda passavam do limite
--    de 8 s do Supabase (erro 500 visto nos registros de 19/11, 16h). Agora as checagens rodam
--    uma vez e as fichas saem numa consulta só, com a MESMA regra de pode_ver_lead():
--    responsável pela ficha, ficha que veio de indicação de uma ficha dele, ou ficha de origem
--    de uma indicação que ele recebeu. Conferido para as 15 pessoas: listas idênticas.
create or replace function public.crm_fichas_visiveis()
returns text[] language plpgsql stable security definer set search_path = public as $$
declare v_uid uuid := auth.uid();
begin
  if not public.acesso_liberado() then raise exception 'Acesso não liberado.'; end if;
  if not public.tem_permissao('ferramenta.crm') then return '{}'::text[]; end if;
  if public.is_admin() then return null; end if;
  if not public.is_ativo() then return '{}'::text[]; end if;
  return array(
    select l.id from public.leads l
     where not coalesce(l.excluido, false)
       and (l.responsavel_id = v_uid
            or l.origem_lead_id in (select o.id from public.leads o where o.responsavel_id = v_uid)
            or l.id in (select x.origem_lead_id from public.leads x
                         where x.responsavel_id = v_uid and x.origem_lead_id is not null)));
end $$;
revoke all on function public.crm_fichas_visiveis() from public, anon, authenticated;

-- 2. Registro de atividades confiável. A tabela auditoria aceitava qualquer "usuario" vindo do
--    navegador: dava para registrar uma ação no nome de outra pessoa. Agora, quando quem grava é
--    alguém logado, o banco põe o e-mail do login e a hora do servidor. Gravações do próprio
--    banco (agendamentos, funções automáticas) seguem com o nome que trazem.
create or replace function public.auditoria_autor()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null then
    new.usuario := coalesce(nullif(auth.jwt() ->> 'email', ''), auth.uid()::text);
    new.quando := now();
  end if;
  new.acao := left(new.acao, 120);
  new.alvo := left(new.alvo, 300);
  new.detalhe := left(new.detalhe, 2000);
  return new;
end $$;
revoke all on function public.auditoria_autor() from public, anon, authenticated;
drop trigger if exists auditoria_autor on public.auditoria;
create trigger auditoria_autor before insert on public.auditoria
  for each row execute function public.auditoria_autor();

-- 3. Comentários do mês (cartas) só o master escreve. O texto sai no relatório de TODOS os
--    clientes do mês; antes qualquer pessoa com Carteiras podia alterar ou apagar. Ler continua
--    liberado para quem tem Carteiras (o relatório usa).
drop policy if exists cartas_escrever_master on public.cartas;
drop policy if exists cartas_alterar_master on public.cartas;
drop policy if exists cartas_apagar_master on public.cartas;
create policy cartas_escrever_master on public.cartas as restrictive for insert to authenticated
  with check ((select public.eh_admin()));
create policy cartas_alterar_master on public.cartas as restrictive for update to authenticated
  using ((select public.eh_admin())) with check ((select public.eh_admin()));
create policy cartas_apagar_master on public.cartas as restrictive for delete to authenticated
  using ((select public.eh_admin()));

-- 4. Funções de apoio do BTG (só formatam número, conta e data) não precisam ficar abertas a
--    quem não entrou.
do $$
declare f text;
begin
  foreach f in array array['btg_conta(text)','btg_numero(text)','btg_nome_norm(text)','btg_data(text)','btg_mes_ref(text)'] loop
    if to_regprocedure('public.' || f) is null then continue; end if;
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated, service_role', f);
  end loop;
end $$;

-- 5. NNM, Captação e Contas novas do CRM (btg_captacao.sql): a lista de fichas entra "materialized" para o banco
--    cruzar conta com ficha uma vez só. Antes eram ~800 mil comparações (3 s para o assessor); agora ~0,3 s.
--    A mudança está no próprio btg_captacao.sql; rode-o de novo junto com este.

-- 6. E-mail da manhã só pelo agendamento. A função agenda-manha (versão 9) passou a exigir o cabeçalho x-btg-sync
--    com o token do Vault, como as funções do BTG; o agendamento manda o cabeçalho.
select cron.alter_job(job_id := (select jobid from cron.job where jobname = 'agenda-manha'), command := $c$
  select net.http_post(
    url := 'https://ghxjqmjtmbqzvogwzylo.supabase.co/functions/v1/agenda-manha',
    headers := jsonb_build_object('Content-Type', 'application/json',
      'x-btg-sync', (select decrypted_secret from vault.decrypted_secrets where name = 'btg_sync_token')),
    body := '{}'::jsonb, timeout_milliseconds := 60000);
$c$);
