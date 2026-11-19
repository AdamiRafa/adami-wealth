-- ============================================================
--  Assessor automático (19/11/2026, Hub 3.39). Pedido do Emil: "não consigo automatizar
--  essa relação do código do assessor?" e "na hora que eu crio o cliente e linko as contas
--  já deve puxar quem é o assessor responsável".
--
--  1. Código do assessor vindo do BTG
--     A base diária do BTG (btg_base) traz, em cada conta, o código do assessor (cge_officer)
--     e o e-mail dele (dados->>'email_assessor'). Esse e-mail é o mesmo do login no Hub.
--     btg_sincronizar_codigos() grava em perfis.codigo o código que o BTG usa para aquele
--     e-mail. É casamento por identidade (o próprio BTG diz qual é o e-mail do assessor),
--     nunca por nome. E-mail com mais de um código no BTG fica de fora. Cada troca vai
--     para a auditoria. Roda todo dia útil às 8h50, depois que a base chega (8h30) e antes
--     da importação automática (9h15).
--
--  2. Assessor do cliente nas Carteiras
--     Quando as contas BTG de um cliente mudam (criar ou "Salvar cadastro"), o assessor do
--     cliente passa a ser o dono, no BTG, da conta de maior patrimônio entre as ligadas,
--     desde que esse código pertença a alguém do Hub. Só vale quando quem grava é o master
--     (as Carteiras são preenchidas por ele). Se nenhuma conta casar, fica como estava.
--     Salvar só o nome, sem mexer nas contas, não troca o assessor.
--
--  3. Ficha do CRM ligada sozinha (pedido do Emil no mesmo dia)
--     Quando as contas BTG de um cliente mudam e ele ainda não está ligado a uma ficha do CRM,
--     liga à ficha (funil do assessor, não excluída) cuja conta está entre as vinculadas. Se
--     mais de uma ficha casar (pessoa e holding, por exemplo), fica a que tem o primeiro nome
--     do cliente; empatando, a da conta de maior patrimônio. Ligação já feita não é trocada.
--
--  Rodar inteiro no SQL Editor (Run without RLS). Pode rodar de novo.
-- ============================================================

create or replace function public.btg_sincronizar_codigos()
returns integer language plpgsql security definer set search_path = public as $$
declare r record; n integer := 0;
begin
  for r in
    with b as (
      select lower(btrim(dados->>'email_assessor')) em, min(btrim(cge_officer)) cge
        from public.btg_base
       where coalesce(dados->>'email_assessor', '') like '%@%' and coalesce(btrim(cge_officer), '') <> ''
       group by 1 having count(distinct btrim(cge_officer)) = 1)
    select p.user_id, p.nome, p.codigo antigo, b.cge novo, b.em
      from b join auth.users u on lower(u.email) = b.em
      join public.perfis p on p.user_id = u.id
     where coalesce(btrim(p.codigo), '') is distinct from b.cge
  loop
    update public.perfis set codigo = r.novo where user_id = r.user_id;
    insert into public.auditoria (usuario, acao, alvo, detalhe)
    values ('BTG (automático)', 'código do assessor', coalesce(r.nome, r.em),
            coalesce(nullif(r.antigo, ''), 'sem código') || ' → ' || r.novo);
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function public.btg_sincronizar_codigos() from public, anon, authenticated;

select cron.unschedule(jobid) from cron.job where jobname = 'btg-codigos';
select cron.schedule('btg-codigos', '50 11 * * 1-5', $c$ select public.btg_sincronizar_codigos(); $c$);

-- Assessor do cliente pelo dono da conta no BTG.
create or replace function public.clientes_assessor_pelo_btg()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_uid uuid;
begin
  if tg_op = 'UPDATE' and new.contas_btg is not distinct from old.contas_btg then return new; end if;
  if not public.eh_admin() then return new; end if;
  select p.user_id into v_uid
    from unnest(coalesce(new.contas_btg, '{}')) x
    join public.btg_base b on ltrim(b.nr_conta, '0') = ltrim(regexp_replace(x, '\D', '', 'g'), '0')
    left join public.btg_vinculos v on v.nr_conta = b.nr_conta
    join public.perfis p on upper(btrim(p.codigo)) = upper(btrim(coalesce(nullif(v.cge_officer, ''), b.cge_officer, '')))
   order by b.pl_total desc nulls last limit 1;
  if v_uid is not null then new.assessor_id := v_uid; end if;
  return new;
end $$;
revoke all on function public.clientes_assessor_pelo_btg() from public, anon, authenticated;
drop trigger if exists clientes_zz_assessor_btg on public.clientes;
create trigger clientes_zz_assessor_btg before insert or update of contas_btg on public.clientes
  for each row execute function public.clientes_assessor_pelo_btg();

-- Ficha do CRM pela conta.
create or replace function public.clientes_ficha_pela_conta(p_nome text, p_contas text[])
returns text language sql stable security definer set search_path = public as $$
  select l.id
    from public.leads l
    left join public.btg_base b on ltrim(b.nr_conta, '0') = ltrim(regexp_replace(l.conta, '\D', '', 'g'), '0')
   where not coalesce(l.excluido, false) and coalesce(l.funil, 'assessor') = 'assessor' and coalesce(l.conta, '') <> ''
     and ltrim(regexp_replace(l.conta, '\D', '', 'g'), '0') in
         (select ltrim(regexp_replace(x, '\D', '', 'g'), '0') from unnest(coalesce(p_contas, '{}')) x)
   order by (translate(lower(coalesce(l.cliente, '')), 'áàâãéêíóôõúç', 'aaaaeeiooouc')
             like translate(lower(split_part(btrim(coalesce(p_nome, '')), ' ', 1)), 'áàâãéêíóôõúç', 'aaaaeeiooouc') || '%') desc,
            b.pl_total desc nulls last, l.id
   limit 1;
$$;
revoke all on function public.clientes_ficha_pela_conta(text, text[]) from public, anon, authenticated;

create or replace function public.clientes_ficha_pelo_btg()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.lead_id is not null then return new; end if;
  if tg_op = 'UPDATE' and new.contas_btg is not distinct from old.contas_btg then return new; end if;
  new.lead_id := public.clientes_ficha_pela_conta(new.nome, new.contas_btg);
  return new;
end $$;
revoke all on function public.clientes_ficha_pelo_btg() from public, anon, authenticated;
drop trigger if exists clientes_zz_ficha_btg on public.clientes;
create trigger clientes_zz_ficha_btg before insert or update of contas_btg on public.clientes
  for each row execute function public.clientes_ficha_pelo_btg();

-- Acerta os códigos agora (Marcelo e Gabriel estavam com código interno).
select public.btg_sincronizar_codigos();

-- Liga agora as carteiras que ainda não têm ficha.
update public.clientes c set lead_id = public.clientes_ficha_pela_conta(c.nome, c.contas_btg)
 where c.lead_id is null and cardinality(c.contas_btg) > 0;
