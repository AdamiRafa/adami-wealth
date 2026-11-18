-- Gravação em lotes dos relatórios grandes do BTG (19/11/2026). A posição por data tem ~8 mil linhas e passava do
-- limite de 8 s por chamada do banco; a btg-webhook grava em lotes de 1.000 (btg_linhas_lote) e fecha o arquivo
-- (btg_linhas_fim). Só a chave de serviço executa. Rodar inteiro no SQL Editor (Run without RLS).
create or replace function public.btg_linhas_lote(p_arquivo_id bigint, p_inicio int, p_linhas jsonb)
returns int language plpgsql security definer set search_path = public as $$
begin
  insert into public.btg_linhas (arquivo_id, n, nr_conta, dados)
  select p_arquivo_id, p_inicio + (o - 1)::int,
         public.btg_conta(coalesce(x->>'nr_conta', x->>'cod_carteira', x->>'accountNumber', x->>'account', x->>'conta')), x
    from jsonb_array_elements(p_linhas) with ordinality as t(x, o)
  on conflict (arquivo_id, n) do nothing;
  return coalesce(jsonb_array_length(p_linhas), 0);
end $$;
revoke all on function public.btg_linhas_lote(bigint, int, jsonb) from public, anon, authenticated;
grant execute on function public.btg_linhas_lote(bigint, int, jsonb) to service_role;

create or replace function public.btg_linhas_fim(p_arquivo_id bigint, p_caminho text, p_tamanho bigint, p_colunas text[], p_total int)
returns json language plpgsql security definer set search_path = public as $$
begin
  update public.btg_arquivos set caminho = p_caminho, tamanho = p_tamanho, linhas = p_total, colunas = p_colunas,
         status = case when coalesce(p_total, 0) = 0 then 'sem_dados' else 'processado' end, processado_em = now()
   where id = p_arquivo_id;
  return json_build_object('ok', true, 'linhas', p_total);
end $$;
revoke all on function public.btg_linhas_fim(bigint, text, bigint, text[], int) from public, anon, authenticated;
grant execute on function public.btg_linhas_fim(bigint, text, bigint, text[], int) to service_role;
