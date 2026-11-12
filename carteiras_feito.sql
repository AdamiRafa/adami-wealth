-- ============================================================
-- carteiras_feito.sql · Hub 3.11 (12/11/2026)
--
-- Carteiras: "Marcar mês como feito". Cada lançamento (cliente + mês) ganha a data
-- em que foi dado como pronto e quem marcou. O "quem" é carimbado aqui no banco
-- (auth.uid()), nunca vem da tela. Quem pode gravar continua sendo quem já podia
-- gravar lançamentos (políticas lanc_inserir / lanc_alterar: eh_admin()).
--
-- Como instalar: SQL Editor do Supabase, colar o arquivo inteiro, Run.
-- O aviso "Potential issues detected" é falso positivo: Run without RLS.
-- Pode rodar mais de uma vez.
-- ============================================================

alter table public.lancamentos add column if not exists feito_em  timestamptz;
alter table public.lancamentos add column if not exists feito_por uuid references auth.users(id) on delete set null;

create or replace function public.lancamentos_carimba_feito()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    new.feito_por := case when new.feito_em is null then null else auth.uid() end;
  elsif new.feito_em is distinct from old.feito_em then
    new.feito_por := case when new.feito_em is null then null else auth.uid() end;
  else
    new.feito_por := old.feito_por;
  end if;
  return new;
end $$;
revoke all on function public.lancamentos_carimba_feito() from public, anon, authenticated;

drop trigger if exists lancamentos_carimba_feito_trg on public.lancamentos;
create trigger lancamentos_carimba_feito_trg before insert or update on public.lancamentos
  for each row execute function public.lancamentos_carimba_feito();

-- Conferência
select count(*) as lancamentos, count(feito_em) as feitos from public.lancamentos;
