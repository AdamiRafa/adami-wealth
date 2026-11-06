-- ============================================================
--  8.12. EQUIPE: EDITAR, REVOGAR E EXCLUIR (06/11/2026)
--     Ações do card da pessoa na tela de Equipe do Hub. Todas exigem
--     master (eh_super, que já exige o código do dia) e ficam na
--     auditoria. Pode rodar de novo sem estragar nada.
--
--     Travas:
--      - ninguém revoga nem exclui a si mesmo;
--      - não dá para tirar o último master ativo;
--      - EXCLUIR só vale para quem não tem cliente no CRM nem carteira:
--        apagar a pessoa deixaria os clientes sem responsável. Para quem
--        tem, o caminho é revogar o acesso (reversível) ou transferir antes.
-- ============================================================

-- A lista da Equipe passa a trazer também: acesso revogado, último acesso e
-- quantos clientes a pessoa tem (CRM e Carteiras).
drop function if exists public.listar_equipe();
create function public.listar_equipe()
returns table (user_id uuid, email text, nome text, codigo text, admin boolean, mesa_rv boolean, super boolean,
               crm_role text, crm_status text, crm_produtos text[], criado_em timestamptz,
               revogado boolean, ultimo_acesso timestamptz, qtd_leads int, qtd_carteiras int)
language sql stable security definer set search_path = public as $$
  select p.user_id, u.email::text, p.nome, p.codigo, p.admin, p.mesa_rv, p.super,
         pr.role, pr.status, pr.produtos, u.created_at,
         coalesce(u.banned_until > now(), false), u.last_sign_in_at,
         (select count(*)::int from public.leads l where l.responsavel_id = p.user_id and not coalesce(l.excluido, false)),
         (select count(*)::int from public.clientes c where c.assessor_id = p.user_id)
  from public.perfis p
  join auth.users u on u.id = p.user_id
  left join public.profiles pr on pr.id = p.user_id
  where public.eh_super()
  order by p.super desc, p.admin desc, p.mesa_rv desc, u.email;
$$;
revoke all on function public.listar_equipe() from public, anon;
grant execute on function public.listar_equipe() to authenticated;

create or replace function public.equipe_ultimo_master(p_user_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select p.super from public.perfis p where p.user_id = p_user_id), false)
     and (select count(*) from public.perfis p join auth.users u on u.id = p.user_id
           where p.super and coalesce(u.banned_until, '-infinity') <= now()) <= 1;
$$;
revoke all on function public.equipe_ultimo_master(uuid) from public, anon, authenticated;

-- Nome e e-mail.
create or replace function public.equipe_editar(p_user_id uuid, p_nome text, p_email text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_nome text := btrim(coalesce(p_nome, ''));
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_antigo text;
  v_quem text := coalesce(auth.jwt() ->> 'email', '?');
begin
  if not public.eh_super() then raise exception 'Apenas o master pode editar a equipe.'; end if;
  select email into v_antigo from auth.users where id = p_user_id;
  if v_antigo is null then raise exception 'Pessoa não encontrada.'; end if;
  if char_length(v_nome) < 2 or char_length(v_nome) > 80 then raise exception 'O nome precisa ter entre 2 e 80 letras.'; end if;
  if v_email !~ '^[^\s@<>",;]+@[^\s@<>",;]+\.[^\s@<>",;]+$' or char_length(v_email) > 200 then
    raise exception 'E-mail inválido.';
  end if;

  update public.perfis set nome = v_nome where user_id = p_user_id;
  update public.profiles set nome = v_nome where id = p_user_id;

  if v_email <> lower(v_antigo) then
    if exists (select 1 from auth.users where lower(email) = v_email and id <> p_user_id) then
      raise exception 'Já existe outra conta com o e-mail %.', v_email;
    end if;
    update auth.users set email = v_email, email_confirmed_at = coalesce(email_confirmed_at, now()), updated_at = now()
     where id = p_user_id;
    update auth.identities set identity_data = identity_data || jsonb_build_object('email', v_email), updated_at = now()
     where user_id = p_user_id and provider = 'email';
    update public.convites set email = v_email where email = lower(v_antigo);
    insert into public.auditoria (usuario, acao, alvo, detalhe)
    values (v_quem, 'trocou e-mail', v_antigo, 'novo: ' || v_email);
  end if;
  insert into public.auditoria (usuario, acao, alvo, detalhe) values (v_quem, 'editou pessoa', v_email, 'nome: ' || v_nome);
end $$;

-- Revogar: bloqueia o login, derruba as sessões abertas e tira do CRM. Reversível.
create or replace function public.equipe_revogar(p_user_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_email text; v_quem text := coalesce(auth.jwt() ->> 'email', '?');
begin
  if not public.eh_super() then raise exception 'Apenas o master pode revogar acesso.'; end if;
  if p_user_id = auth.uid() then raise exception 'Você não pode revogar o seu próprio acesso.'; end if;
  if public.equipe_ultimo_master(p_user_id) then raise exception 'Essa pessoa é o último master ativo. Dê master a outra pessoa antes.'; end if;
  select email into v_email from auth.users where id = p_user_id;
  if v_email is null then raise exception 'Pessoa não encontrada.'; end if;

  update auth.users set banned_until = '2999-12-31 00:00:00+00', updated_at = now() where id = p_user_id;
  delete from auth.sessions where user_id = p_user_id;
  delete from public.acesso_sessoes where user_id = p_user_id;
  update public.profiles set status = 'removido' where id = p_user_id;
  insert into public.auditoria (usuario, acao, alvo, detalhe) values (v_quem, 'revogou acesso', v_email, '');
end $$;

create or replace function public.equipe_reativar(p_user_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_email text; v_quem text := coalesce(auth.jwt() ->> 'email', '?');
begin
  if not public.eh_super() then raise exception 'Apenas o master pode reativar acesso.'; end if;
  select email into v_email from auth.users where id = p_user_id;
  if v_email is null then raise exception 'Pessoa não encontrada.'; end if;
  update auth.users set banned_until = null, updated_at = now() where id = p_user_id;
  update public.profiles set status = 'ativo' where id = p_user_id and status = 'removido';
  insert into public.auditoria (usuario, acao, alvo, detalhe) values (v_quem, 'reativou acesso', v_email, '');
end $$;

-- Excluir de vez (só quem não tem cliente).
create or replace function public.equipe_excluir(p_user_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_email text; v_nome text; v_leads int; v_cart int;
  v_quem text := coalesce(auth.jwt() ->> 'email', '?');
begin
  if not public.eh_super() then raise exception 'Apenas o master pode excluir alguém da equipe.'; end if;
  if p_user_id = auth.uid() then raise exception 'Você não pode excluir a si mesmo.'; end if;
  if public.equipe_ultimo_master(p_user_id) then raise exception 'Essa pessoa é o último master ativo.'; end if;
  select u.email, coalesce(p.nome, u.email) into v_email, v_nome
    from auth.users u left join public.perfis p on p.user_id = u.id where u.id = p_user_id;
  if v_email is null then raise exception 'Pessoa não encontrada.'; end if;

  select count(*) into v_leads from public.leads where responsavel_id = p_user_id and not coalesce(excluido, false);
  select count(*) into v_cart from public.clientes where assessor_id = p_user_id;
  if v_leads > 0 or v_cart > 0 then
    raise exception '% ainda tem % cliente(s) no CRM e % carteira(s). Transfira para outra pessoa antes de excluir, ou use "Revogar acesso".',
      v_nome, v_leads, v_cart;
  end if;

  insert into public.auditoria (usuario, acao, alvo, detalhe) values (v_quem, 'excluiu pessoa', v_email, v_nome);
  delete from public.convites where email = lower(v_email);
  delete from auth.users where id = p_user_id;
end $$;

revoke all on function public.equipe_editar(uuid, text, text), public.equipe_revogar(uuid),
                       public.equipe_reativar(uuid), public.equipe_excluir(uuid) from public, anon;
grant execute on function public.equipe_editar(uuid, text, text), public.equipe_revogar(uuid),
                          public.equipe_reativar(uuid), public.equipe_excluir(uuid) to authenticated;
