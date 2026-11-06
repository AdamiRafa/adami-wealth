-- ============================================================
--  INSTALAR AS NOVIDADES DE NOVEMBRO/2026 (um arquivo só)
--     Agenda do CRM + e-mail da manhã, Avisos da casa e Arquivos do
--     cliente. É a soma de agenda.sql, avisos.sql e anexos.sql, que
--     continuam no repositório como fonte. Rodar inteiro no SQL Editor
--     do Supabase. Pode rodar de novo sem estragar nada.
--     No fim aparece uma linha "agenda-manha": é a conferência.
-- ============================================================

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


-- ============================================================
--  8.8. AVISOS DA CASA (05/11/2026)
--     Recados para a equipe na tela inicial do Hub, com quantos já
--     leram. Rodar inteiro no SQL Editor do Supabase. Pode rodar de
--     novo sem estragar nada.
--
--     Quem publica: administrador ou master do portal (eh_admin) e o
--     head comercial (admin do CRM, is_admin). Todo mundo lê.
--     "publicar_em" no futuro = aviso agendado: só quem publica vê
--     até chegar a hora.
-- ============================================================

create table if not exists public.avisos (
  id          uuid primary key default gen_random_uuid(),
  titulo      text not null check (char_length(btrim(titulo)) between 1 and 120),
  texto       text not null default '' check (char_length(texto) <= 2000),
  publicar_em timestamptz not null default now(),
  fixado      boolean not null default false,
  criado_por  uuid default auth.uid() references auth.users(id) on delete set null,
  criado_em   timestamptz not null default now()
);
create index if not exists avisos_publicar_idx on public.avisos (publicar_em desc);

create table if not exists public.avisos_leitura (
  aviso_id uuid not null references public.avisos(id) on delete cascade,
  user_id  uuid not null default auth.uid() references auth.users(id) on delete cascade,
  lido_em  timestamptz not null default now(),
  primary key (aviso_id, user_id)
);

create or replace function public.pode_publicar_aviso()
returns boolean language sql stable security definer set search_path = public as $$
  select public.eh_admin() or public.is_admin();
$$;
revoke all on function public.pode_publicar_aviso() from public;
grant execute on function public.pode_publicar_aviso() to authenticated;

alter table public.avisos enable row level security;
alter table public.avisos_leitura enable row level security;

drop policy if exists avisos_ler on public.avisos;
create policy avisos_ler on public.avisos for select to authenticated
  using ( publicar_em <= now() or public.pode_publicar_aviso() );

drop policy if exists avisos_publicar on public.avisos;
create policy avisos_publicar on public.avisos for insert to authenticated
  with check ( public.pode_publicar_aviso() and criado_por = auth.uid() );

drop policy if exists avisos_alterar on public.avisos;
create policy avisos_alterar on public.avisos for update to authenticated
  using ( public.pode_publicar_aviso() ) with check ( public.pode_publicar_aviso() );

drop policy if exists avisos_apagar on public.avisos;
create policy avisos_apagar on public.avisos for delete to authenticated
  using ( public.pode_publicar_aviso() );

-- Cada um marca só a própria leitura, e só de aviso que já pode ver.
drop policy if exists avisos_leitura_ler on public.avisos_leitura;
create policy avisos_leitura_ler on public.avisos_leitura for select to authenticated
  using ( user_id = auth.uid() or public.pode_publicar_aviso() );

drop policy if exists avisos_leitura_marcar on public.avisos_leitura;
create policy avisos_leitura_marcar on public.avisos_leitura for insert to authenticated
  with check ( user_id = auth.uid()
    and exists (select 1 from public.avisos a where a.id = aviso_id and a.publicar_em <= now()) );

grant select, insert, update, delete on public.avisos to authenticated;
grant select, insert on public.avisos_leitura to authenticated;

-- A tela pede tudo de uma vez: os avisos visíveis, quem publicou, quantos
-- já leram e se a própria pessoa leu. "total" é quem tem perfil no portal.
drop function if exists public.avisos_resumo();
create function public.avisos_resumo()
returns table (id uuid, titulo text, texto text, publicar_em timestamptz, fixado boolean,
               autor text, lidos integer, total integer, lido_por_mim boolean)
language sql stable security definer set search_path = public as $$
  select a.id, a.titulo, a.texto, a.publicar_em, a.fixado,
         coalesce(p.nome, ''),
         (select count(*)::int from public.avisos_leitura l where l.aviso_id = a.id),
         (select count(*)::int from public.perfis),
         exists (select 1 from public.avisos_leitura l where l.aviso_id = a.id and l.user_id = auth.uid())
  from public.avisos a
  left join public.perfis p on p.user_id = a.criado_por
  where auth.uid() is not null
    and (a.publicar_em <= now() or public.pode_publicar_aviso())
  order by a.fixado desc, a.publicar_em desc
  limit 30;
$$;
revoke all on function public.avisos_resumo() from public;
grant execute on function public.avisos_resumo() to authenticated;

-- ============================================================
--  8.9. ARQUIVOS DO CLIENTE (06/11/2026)
--     Anexos na ficha do cliente do CRM (foto, PDF, Word, Excel) e
--     os documentos que o Wealth Planning e os Planos Patrimoniais
--     mandam direto para a ficha. Rodar inteiro no SQL Editor. Pode
--     rodar de novo sem estragar nada.
--
--     Os arquivos ficam no Storage do Supabase, no "bucket" privado
--     "anexos", numa pasta por cliente: anexos/<id do cliente>/...
--     Limite de 25 MB por arquivo, só os tipos da lista abaixo.
--     Quem enxerga o cliente no CRM enxerga os arquivos dele, e mais
--     ninguém: a regra é a mesma da ficha (pode_ver_lead).
-- ============================================================

-- A mesma regra de leitura da tabela leads (política leads_select).
create or replace function public.pode_ver_lead(p_id text)
returns boolean language sql security definer stable set search_path = public as $$
  select exists (
    select 1 from public.leads l
    where l.id = p_id
      and ( public.is_admin()
            or (public.is_ativo() and l.responsavel_id = auth.uid())
            or (public.is_ativo() and l.origem_lead_id is not null and public.lead_meu(l.origem_lead_id))
            or (public.is_ativo() and public.lead_origem_minha(l.id)) )
  );
$$;
revoke all on function public.pode_ver_lead(text) from public;
grant execute on function public.pode_ver_lead(text) to authenticated;

create table if not exists public.anexos (
  id          uuid primary key default gen_random_uuid(),
  lead_id     text not null references public.leads(id) on delete cascade,
  nome        text not null check (char_length(nome) between 1 and 200),
  caminho     text not null unique,
  tamanho     bigint not null check (tamanho > 0 and tamanho <= 26214400),
  tipo        text not null default '',
  -- De onde veio: enviado na ficha, ou gerado por uma ferramenta do Hub.
  origem      text not null default 'upload'
                check (origem in ('upload','wealth_planning','plano_patrimonial','enquadramento')),
  nota        text not null default '' check (char_length(nota) <= 500),
  enviado_por uuid default auth.uid() references auth.users(id) on delete set null,
  enviado_em  timestamptz not null default now()
);
create index if not exists anexos_lead_idx on public.anexos (lead_id, enviado_em desc);

alter table public.anexos enable row level security;

drop policy if exists anexos_ler on public.anexos;
create policy anexos_ler on public.anexos for select to authenticated
  using ( public.pode_ver_lead(lead_id) );

-- O caminho tem de estar na pasta do próprio cliente: sem isto, alguém
-- registraria aqui um arquivo guardado na pasta de outro cliente.
drop policy if exists anexos_criar on public.anexos;
create policy anexos_criar on public.anexos for insert to authenticated
  with check ( public.pode_ver_lead(lead_id)
               and enviado_por = auth.uid()
               and caminho like lead_id || '/%' );

drop policy if exists anexos_apagar on public.anexos;
create policy anexos_apagar on public.anexos for delete to authenticated
  using ( public.pode_ver_lead(lead_id) and (enviado_por = auth.uid() or public.is_admin()) );

grant select, insert, delete on public.anexos to authenticated;

-- Bucket privado com limite de tamanho e de tipo.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('anexos', 'anexos', false, 26214400, array[
  'application/pdf',
  'image/jpeg', 'image/png', 'image/webp', 'image/heic', 'image/heif',
  'application/msword',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'application/vnd.ms-excel',
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'application/vnd.ms-powerpoint',
  'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  'text/plain', 'text/csv'
])
on conflict (id) do update
  set public = false,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists anexos_arquivo_ler on storage.objects;
create policy anexos_arquivo_ler on storage.objects for select to authenticated
  using ( bucket_id = 'anexos' and public.pode_ver_lead((storage.foldername(name))[1]) );

drop policy if exists anexos_arquivo_enviar on storage.objects;
create policy anexos_arquivo_enviar on storage.objects for insert to authenticated
  with check ( bucket_id = 'anexos' and public.pode_ver_lead((storage.foldername(name))[1]) );

drop policy if exists anexos_arquivo_apagar on storage.objects;
create policy anexos_arquivo_apagar on storage.objects for delete to authenticated
  using ( bucket_id = 'anexos'
          and public.pode_ver_lead((storage.foldername(name))[1])
          and (owner_id = (auth.uid())::text or public.is_admin()) );

-- Conferência: deve listar a tarefa agendada "agenda-manha".
select jobname, schedule, active from cron.job where jobname = 'agenda-manha';
