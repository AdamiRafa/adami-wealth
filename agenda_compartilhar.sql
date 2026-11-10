-- ============================================================
--  8.19. AGENDA COMPARTILHADA (10/11/2026, CRM 2026.11.10.2)
--     Rodar inteiro no SQL Editor do Supabase (Run without RLS).
--     Pode rodar de novo sem estragar nada.
--
--     Cada pessoa decide se compartilha a própria agenda. Ligado:
--     qualquer pessoa ativa do CRM vê as tarefas dela, só para ler
--     (as políticas de alterar e apagar não mudam). Head comercial e
--     master continuam vendo todas, como antes.
--     Próximo contato, vencimento e régua vêm da ficha do cliente e
--     seguem a regra da carteira: o colega não vê.
-- ============================================================

alter table public.profiles add column if not exists agenda_compartilhada boolean not null default false;

-- A pessoa dona da tarefa compartilha a agenda? Usada na política de leitura.
create or replace function public.agenda_compartilhada(p_user uuid)
returns boolean language plpgsql stable security definer set search_path = public as $$
begin
  if p_user is null or not public.acesso_liberado() then return false; end if;
  return coalesce((select p.agenda_compartilhada from public.profiles p
                    where p.id = p_user and p.status = 'ativo'), false);
end $$;

-- Liga ou desliga o compartilhamento da própria agenda. Só a própria.
create or replace function public.agenda_compartilhar(p_compartilhar boolean)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or not public.acesso_liberado() or not public.is_ativo() then
    raise exception 'Sessão inválida. Entre de novo.';
  end if;
  update public.profiles set agenda_compartilhada = coalesce(p_compartilhar, false) where id = auth.uid();
  return coalesce(p_compartilhar, false);
end $$;

-- Nome do cliente das tarefas que a pessoa vê por compartilhamento. Sem isto o
-- colega veria "ligar para" sem saber para quem (a ficha do cliente não é dele).
create or replace function public.agenda_clientes_compartilhados()
returns table (lead_id text, cliente text, conta text)
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null or not public.acesso_liberado() or not public.is_ativo()
     or not public.tem_permissao('ferramenta.crm') then
    return;
  end if;
  return query
    select distinct l.id, l.cliente, l.conta
      from public.tarefas t
      join public.leads l on l.id = t.lead_id
     where t.lead_id is not null
       and t.dono_id <> auth.uid()
       and public.agenda_compartilhada(t.dono_id);
end $$;

revoke all on function public.agenda_compartilhada(uuid) from public, anon;
revoke all on function public.agenda_compartilhar(boolean) from public, anon;
revoke all on function public.agenda_clientes_compartilhados() from public, anon;
grant execute on function public.agenda_compartilhada(uuid) to authenticated;
grant execute on function public.agenda_compartilhar(boolean) to authenticated;
grant execute on function public.agenda_clientes_compartilhados() to authenticated;

drop policy if exists tarefas_ler on public.tarefas;
create policy tarefas_ler on public.tarefas for select to authenticated
  using ( public.is_ativo() and (
    dono_id = auth.uid() or criado_por = auth.uid()
    or public.is_admin() or public.eh_super()
    or public.agenda_compartilhada(dono_id) ) );

-- Conferência: a coluna existe e a política nova está no lugar.
select count(*) filter (where agenda_compartilhada) as compartilhando, count(*) as pessoas from public.profiles;
