-- ============================================================
--  8.7. AGENDA DO CRM (05/11/2026)
--     Rodar inteiro no SQL Editor do Supabase. Pode rodar de novo
--     sem estragar nada: tudo aqui é "se não existir" ou "troca".
--
--     tarefas         as tarefas criadas na mão (a aba Agenda do CRM).
--                     Próximo contato, vencimento e régua NÃO moram
--                     aqui: o CRM calcula a partir da ficha do cliente,
--                     para os dois nunca discordarem.
--     agenda_emails   um registro por pessoa por dia do e-mail da
--                     manhã. É o que impede o mesmo e-mail de sair duas
--                     vezes no dia.
--     pedidos_senha   cada pedido de "Esqueci minha senha", para a
--                     função enviar-senha limitar a frequência.
--
--     As duas últimas não têm política nenhuma de propósito: só as
--     funções do Supabase (com a chave de serviço) leem e escrevem.
-- ============================================================

create table if not exists public.tarefas (
  id            uuid primary key default gen_random_uuid(),
  titulo        text not null check (char_length(btrim(titulo)) between 1 and 200),
  tipo          text not null default 'tarefa'
                  check (tipo in ('ligacao','reuniao','email','tarefa')),
  -- Cliente ligado à tarefa (opcional). Concluir uma tarefa ligada a
  -- cliente registra a atividade na ficha dele, pelo próprio CRM.
  lead_id       text references public.leads(id) on delete set null,
  -- De quem é a tarefa. Assessor só cria para si; head comercial
  -- (admin do CRM) e master podem criar para qualquer pessoa.
  dono_id       uuid not null references public.profiles(id) on delete cascade,
  -- Quem criou. Preenchido pelo gatilho abaixo, nunca pelo navegador.
  criado_por    uuid default auth.uid() references public.profiles(id) on delete set null,
  data          date not null,
  hora          time,
  -- nao | dia_util (seg a sex) | semana (dias_semana) | mes (mesmo dia
  -- do mês de "data"). A repetição começa em "data".
  repeticao     text not null default 'nao'
                  check (repeticao in ('nao','dia_util','semana','mes')),
  -- 1 = segunda ... 7 = domingo. Só vale para repeticao = 'semana'.
  dias_semana   smallint[] not null default '{}'
                  check (dias_semana <@ array[1,2,3,4,5,6,7]::smallint[]),
  -- Dias já concluídos. Tarefa que não repete tem no máximo um; a que
  -- repete guarda um por ocorrência feita.
  concluidas    date[] not null default '{}',
  email_manha   boolean not null default true,
  nota          text not null default '' check (char_length(nota) <= 2000),
  criado_em     timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);
create index if not exists tarefas_dono_idx on public.tarefas (dono_id);
create index if not exists tarefas_lead_idx on public.tarefas (lead_id) where lead_id is not null;

-- Quem criou não é informado pelo navegador: é a sessão. E a tarefa
-- atribuída pelo head comercial não pode ser reescrita por quem a
-- recebeu: ele só marca como feita (e liga ou desliga o e-mail).
create or replace function public.tarefas_carimbo()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    if auth.uid() is not null then new.criado_por := auth.uid(); end if;
    new.criado_em := now();
  else
    new.criado_por := old.criado_por;
    new.criado_em := old.criado_em;
    if auth.uid() is not null
       and old.criado_por is distinct from auth.uid()
       and not (public.is_admin() or public.eh_super())
       and (new.titulo, new.tipo, new.lead_id, new.dono_id, new.data, new.hora,
            new.repeticao, new.dias_semana, new.nota)
           is distinct from
           (old.titulo, old.tipo, old.lead_id, old.dono_id, old.data, old.hora,
            old.repeticao, old.dias_semana, old.nota)
    then
      raise exception 'Esta tarefa foi atribuída a você. Só quem atribuiu pode mudar o texto, o dia ou a repetição.';
    end if;
  end if;
  new.atualizado_em := now();
  return new;
end;
$$;
drop trigger if exists tarefas_carimbo on public.tarefas;
create trigger tarefas_carimbo before insert or update on public.tarefas
  for each row execute function public.tarefas_carimbo();

alter table public.tarefas enable row level security;

drop policy if exists tarefas_ler on public.tarefas;
create policy tarefas_ler on public.tarefas for select to authenticated
  using ( public.is_ativo() and (
    dono_id = auth.uid() or criado_por = auth.uid()
    or public.is_admin() or public.eh_super() ) );

drop policy if exists tarefas_criar on public.tarefas;
create policy tarefas_criar on public.tarefas for insert to authenticated
  with check ( public.is_ativo() and (
    dono_id = auth.uid() or public.is_admin() or public.eh_super() ) );

drop policy if exists tarefas_alterar on public.tarefas;
create policy tarefas_alterar on public.tarefas for update to authenticated
  using ( public.is_ativo() and (
    dono_id = auth.uid() or criado_por = auth.uid()
    or public.is_admin() or public.eh_super() ) )
  with check ( public.is_ativo() and (
    dono_id = auth.uid() or public.is_admin() or public.eh_super() ) );

drop policy if exists tarefas_apagar on public.tarefas;
create policy tarefas_apagar on public.tarefas for delete to authenticated
  using ( public.is_ativo() and (
    criado_por = auth.uid() or public.is_admin() or public.eh_super() ) );

grant select, insert, update, delete on public.tarefas to authenticated;

-- E-mail da manhã: um por pessoa por dia.
create table if not exists public.agenda_emails (
  user_id    uuid not null references auth.users(id) on delete cascade,
  dia        date not null,
  enviado_em timestamptz not null default now(),
  resultado  text,
  primary key (user_id, dia)
);
alter table public.agenda_emails enable row level security;
revoke all on public.agenda_emails from anon, authenticated;

-- Pedidos de "Esqueci minha senha".
create table if not exists public.pedidos_senha (
  id        bigint generated always as identity primary key,
  email     text not null,
  pedido_em timestamptz not null default now(),
  resultado text
);
create index if not exists pedidos_senha_email_idx on public.pedidos_senha (email, pedido_em desc);
alter table public.pedidos_senha enable row level security;
revoke all on public.pedidos_senha from anon, authenticated;

-- Agendamento do e-mail da manhã: dias úteis, 9h50 em UTC = 6h50 em
-- Brasília. Chama a função agenda-manha, que só envia uma vez por dia
-- para cada pessoa e só entre 6h e 11h de Brasília.
create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron with schema pg_catalog;
select cron.schedule(
  'agenda-manha',
  '50 9 * * 1-5',
  $cron$
  select net.http_post(
    url := 'https://ghxjqmjtmbqzvogwzylo.supabase.co/functions/v1/agenda-manha',
    headers := '{"Content-Type":"application/json"}'::jsonb,
    body := '{}'::jsonb,
    timeout_milliseconds := 60000
  );
  $cron$
);

-- Conferência: deve listar a tarefa agendada "agenda-manha".
select jobname, schedule, active from cron.job where jobname = 'agenda-manha';
