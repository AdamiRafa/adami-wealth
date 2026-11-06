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
