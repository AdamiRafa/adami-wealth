// Função "btg-base-auto" do Supabase (Edge Functions): atualização automática da base do CRM pelo BTG.
//
// Faz sozinha, todo dia útil, o que a tela "Atualizar base > Atualizar do BTG" do CRM faz com o
// clique em Aplicar (18/11/2026, pedido do Emil). As regras NÃO são reescritas aqui: regras.js é
// gerado a partir do crm.html (gerar-regras.js), então a prévia do CRM e esta função dão sempre o
// mesmo resultado. Mudou a regra no CRM: rode gerar-regras.js e publique esta função de novo
// (testes/verificar.sh recusa a publicação se regras.js estiver diferente do crm.html).
//
// Quem chama: o agendamento do banco (pg_cron "btg-base-auto", 9h15 e 11h15 de Brasília, dias úteis),
// depois da janela das 8h30 em que chega a base de contas (account-base) e o vínculo com o assessor
// (account-link). Mesma regra de sempre: não exclui quem sumiu, não transfere carteira pelo nome; conta
// nova só nasce com o código do assessor reconhecido na Equipe; diferença de saldo fora da faixa vira
// alerta no card do assessor.
//
// Segurança:
//  - Só roda com o cabeçalho x-btg-sync igual ao token do Vault (o próprio agendamento manda), igual
//    à btg-sync. Verify JWT desligado (quem chama é o banco, sem login).
//  - Não faz nada com btg_config.ligado = false.
//  - Aplica cada base uma vez só (configuracoes "btg_auto_base_aplicada" guarda a data da base).
//  - Não aplica base com mais de 20 horas: se o BTG não mandou a de hoje, espera a próxima.
//  - {"simular": true} só calcula e devolve o que faria, sem gravar nada (para conferir).
import { reconciliarBaseBTG, montarAplicacaoBase, faixaBTG, leadToRow, leadFromRow, chaveCodigo, chaveConta, DIA_MS } from "./regras.js";

const SB_URL = Deno.env.get("SUPABASE_URL") ?? "https://ghxjqmjtmbqzvogwzylo.supabase.co";
const CHAVE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const AUTOR = "Atualização automática do BTG";
const BLOCO = 100;

function resposta(corpo: unknown, status = 200): Response {
  return new Response(JSON.stringify(corpo), { status, headers: { "Content-Type": "application/json; charset=utf-8" } });
}
const cab = (extra: Record<string, string> = {}) => ({ apikey: CHAVE, Authorization: "Bearer " + CHAVE, "Content-Type": "application/json", ...extra });

async function rpc(nome: string, args: Record<string, unknown>): Promise<any> {
  const r = await fetch(`${SB_URL}/rest/v1/rpc/${nome}`, { method: "POST", headers: cab(), body: JSON.stringify(args) });
  const t = await r.text();
  if (!r.ok) throw new Error(`${nome}: ${r.status} ${t.slice(0, 300)}`);
  return t ? JSON.parse(t) : null;
}

// Lê a tabela inteira, em páginas de 1000 (limite do PostgREST).
async function tudo(tabela: string, colunas: string, ordem: string): Promise<any[]> {
  const out: any[] = [];
  for (let de = 0; ; de += 1000) {
    const r = await fetch(`${SB_URL}/rest/v1/${tabela}?select=${colunas}&order=${ordem}`,
      { headers: cab({ Range: `${de}-${de + 999}`, "Range-Unit": "items" }) });
    if (!r.ok) throw new Error(`${tabela}: ${r.status} ${(await r.text()).slice(0, 300)}`);
    const pg = await r.json();
    out.push(...pg);
    if (pg.length < 1000) return out;
  }
}

async function config(chave: string): Promise<string | null> {
  const r = await fetch(`${SB_URL}/rest/v1/configuracoes?select=valor&chave=eq.${encodeURIComponent(chave)}`, { headers: cab() });
  if (!r.ok) throw new Error(`configuracoes: ${r.status}`);
  const d = await r.json();
  return d && d[0] ? d[0].valor : null;
}
async function gravarConfig(chave: string, valor: string): Promise<void> {
  const r = await fetch(`${SB_URL}/rest/v1/configuracoes`, {
    method: "POST", headers: cab({ Prefer: "resolution=merge-duplicates,return=minimal" }),
    body: JSON.stringify({ chave, valor, atualizado_em: new Date().toISOString() }),
  });
  if (!r.ok) throw new Error(`configuracoes ${chave}: ${r.status} ${(await r.text()).slice(0, 200)}`);
}

// Upsert em blocos de 100, com até 3 tentativas por bloco (regravar o mesmo bloco é seguro).
async function gravarLeads(lista: any[]): Promise<void> {
  for (let i = 0; i < lista.length; i += BLOCO) {
    const corpo = JSON.stringify(lista.slice(i, i + BLOCO).map(leadToRow));
    for (let t = 1; ; t++) {
      let erro = "";
      try {
        const r = await fetch(`${SB_URL}/rest/v1/leads`, { method: "POST", headers: cab({ Prefer: "resolution=merge-duplicates,return=minimal" }), body: corpo });
        if (!r.ok) erro = `${r.status} ${(await r.text()).slice(0, 300)}`;
      } catch (e) { erro = String((e as Error)?.message ?? e); }
      if (!erro) break;
      if (t >= 3) throw new Error(`gravando clientes ${i + 1} a ${Math.min(i + BLOCO, lista.length)} de ${lista.length}: ${erro}`);
      await new Promise((ok) => setTimeout(ok, 1500 * t));
    }
  }
}

function hojeBrasilia(): string {
  const d = new Date(new Date().toLocaleString("en-US", { timeZone: "America/Sao_Paulo" }));
  return d.getFullYear() + "-" + String(d.getMonth() + 1).padStart(2, "0") + "-" + String(d.getDate()).padStart(2, "0");
}

export async function atualizar(forcar = false, simular = false): Promise<Record<string, unknown>> {
  // 1. A base do BTG, no mesmo formato que a função btg_base_crm entrega para o CRM.
  const [base, vinc] = await Promise.all([
    tudo("btg_base", "nr_conta,nome,pl_total,nm_assessor,cge_officer,atualizado_em", "nr_conta"),
    tudo("btg_vinculos", "nr_conta,nm_officer,cge_officer", "nr_conta"),
  ]);
  if (!base.length) return { ok: true, nada: "o BTG ainda não mandou a base de contas" };
  const baseEm = base.reduce((m, b) => (b.atualizado_em > m ? b.atualizado_em : m), "");
  const idadeH = (Date.now() - new Date(baseEm).getTime()) / 36e5;
  if (!forcar && idadeH > 20) return { ok: true, nada: "a base de hoje ainda não chegou", base_em: baseEm };
  if (!forcar && (await config("btg_auto_base_aplicada")) === baseEm) return { ok: true, nada: "esta base já foi aplicada", base_em: baseEm };

  const porConta = new Map(vinc.map((v) => [v.nr_conta, v]));
  let linhas = base.map((b) => {
    const v = porConta.get(b.nr_conta) || {};
    return {
      "Conta": b.nr_conta, "Nome": b.nome, "Sob Gestão": Number(b.pl_total) || 0,
      "Assessor": (v.nm_officer || "") || b.nm_assessor || "",
      "Código Assessor": (v.cge_officer || "") || b.cge_officer || "",
    };
  });

  // 2. A Equipe, como o CRM monta (fetchProfiles + códigos dos assessores).
  const [perfisP, codigos] = await Promise.all([tudo("profiles", "*", "nome"), tudo("perfis", "user_id,codigo", "user_id")]);
  const codPor = new Map(codigos.filter((c) => c.codigo).map((c) => [c.user_id, String(c.codigo)]));
  const users = perfisP.map((p) => ({ id: p.id, nome: p.nome, role: p.role, status: p.status, produtos: p.produtos || [],
    especialistasPadrao: p.especialistas_padrao || {}, codigo: codPor.get(p.id) || "", agendaCompartilhada: p.agenda_compartilhada === true }));
  const codigosEquipe = new Set(users.map((u) => chaveCodigo(u.codigo)).filter(Boolean));
  const bate = linhas.some((l) => codigosEquipe.has(chaveCodigo(l["Código Assessor"])));
  if (!bate) linhas = linhas.map((l) => { const c: any = { ...l }; delete c["Código Assessor"]; return c; });

  // 3. Os clientes do CRM.
  const leads = (await tudo("leads", "*", "id")).map(leadFromRow);

  // 4. Faixa de rendimento e movimentações informadas pelo BTG desde a última atualização (como o CRM).
  const ultimaTxt = await config("btg_ultima_onshore");
  const ultima = ultimaTxt && isFinite(Number(ultimaTxt)) ? Number(ultimaTxt) : null;
  const f = faixaBTG(ultima, Date.now());
  const opc: any = { faixa: f.faixa, dias: f.dias, ultima };
  opc.desdeISO = new Date(ultima ?? Date.now() - 7 * DIA_MS).toISOString().slice(0, 10);
  try {
    const mv = await rpc("btg_movimentos_calc", { p_desde: opc.desdeISO });
    if (mv && mv.contas) opc.movs = new Map(Object.entries(mv.contas).map(([c, v]) => [chaveConta(c), Number(v) || 0]));
  } catch (_e) { /* sem movimentações: só a faixa */ }

  // 5. A mesma reconciliação e a mesma montagem da tela do CRM.
  const res = reconciliarBaseBTG(linhas, leads, users, opc);
  const { novos, criados } = montarAplicacaoBase(res, leads, AUTOR, Date.now(), hojeBrasilia());

  if (simular) {
    // Só calcula: devolve o que faria, sem gravar nada.
    const amostra = res.atualizacoes.slice(0, 5).map((a: any) => ({ conta: a.lead && a.lead.conta, delta: a.delta, alerta: !!a.alerta, campos: (a.campos || []).map((c: any) => c.rotulo) }));
    return { ok: true, simulacao: true, base_em: baseEm, linhas: linhas.length, atualizariam: novos.length, criariam: criados.length,
      com_diferenca: res.atualizacoes.filter((a: any) => Math.abs(a.delta) >= 0.01).length,
      alertas: (res.resumo && res.resumo.alertas) || 0, assessor_pelo_codigo: bate, faixa: f.faixa, dias: f.dias, amostra };
  }

  // 6. Grava.
  await gravarLeads([...novos, ...criados]);
  await gravarConfig("btg_ultima_onshore", String(Date.now()));
  await gravarConfig("btg_auto_base_aplicada", baseEm);
  const resumo = {
    quando: new Date().toISOString(), base_em: baseEm, linhas: linhas.length,
    atualizados: novos.length, criados: criados.length, alertas: (res.resumo && res.resumo.alertas) || 0,
    assessor_pelo_codigo: bate, faixa: f.faixa, dias: f.dias,
  };
  await gravarConfig("btg_auto_resultado", JSON.stringify(resumo));
  return { ok: true, ...resumo };
}

if (import.meta.main) Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return resposta({ erro: "Use POST." }, 405);
  if (!CHAVE) return resposta({ erro: "Sem a chave de serviço do Supabase." }, 500);
  try {
    if (!(await rpc("btg_sync_token_ok", { p: req.headers.get("x-btg-sync") ?? "" }))) return resposta({ erro: "não autorizado" }, 401);
    const corpo = await req.json().catch(() => ({})) as { forcar?: boolean; simular?: boolean };
    if (!(await rpc("btg_ligado", {}))) return resposta({ ok: true, desligado: true });
    const r = await atualizar(!!corpo.forcar || !!corpo.simular, !!corpo.simular);
    console.log("btg-base-auto", JSON.stringify(r));
    return resposta(r);
  } catch (e) {
    const msg = String((e as Error)?.message ?? e).slice(0, 500);
    console.error("btg-base-auto", msg);
    try { await gravarConfig("btg_auto_resultado", JSON.stringify({ quando: new Date().toISOString(), erro: msg })); } catch (_e) { /* nada */ }
    return resposta({ erro: msg }, 500);
  }
});
