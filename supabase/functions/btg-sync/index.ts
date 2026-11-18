// Função "btg-sync" do Supabase (Edge Functions): pede os relatórios ao BTG.
//
// Fase 1 da integração (06/11/2026, btg.sql). Quem chama é o agendamento do banco (pg_cron),
// em dias úteis, logo depois das janelas em que o BTG gera os arquivos:
//   "manha" 8h30: vínculo conta-assessor, base de contas, cadastro, movimentação e a posição
//                 do dia útil anterior (posição por data);
//   "tarde" 15h30: NNM (captação líquida);
//   "noite" 20h30: movimentação e cadastro do fim do dia.
//   "rentabilidade" (dias 2 e 5 do mês, 9h): os três relatórios de Rentabilidade Mensal
//                 (carteira, produto, estratégia) do MÊS ANTERIOR, já fechado. Conferido em
//                 17/11/2026: a API devolve só o mês pedido (o corrente vem parcial, até o
//                 último dia útil), em arquivo .zip, com os valores em fração (0,0122 = 1,22%).
//   "performance" (dias 2 e 5, depois da rentabilidade): o Relatório de Performance em PDF do mês anterior
//                 de cada conta vinculada no cadastro das Carteiras (clientes.contas_btg), uma por vez
//                 (limite do BTG: 60 por minuto). {"conta": "..."} pede só uma conta (teste).
//   "reforco" {"de":"manha"|"tarde"} (10h e 17h, dias úteis): pede de novo só o relatório daquela janela que não
//                 chegou processado hoje (o BTG às vezes responde "relatório não disponível" ou atrasa).
//   "limpeza-arquivos" (domingo): apaga do Storage os originais dos relatórios diários com mais de 60 dias. Os PDFs do
//                 Relatório de Performance e a Rentabilidade Mensal ficam.
// O BTG responde 202 e entrega o arquivo depois, na função btg-webhook.
// Cada pedido fica registrado em btg_pedidos, com a resposta do BTG.
//
// Segurança:
//  - Só roda com o cabeçalho x-btg-sync igual ao token guardado no Vault do banco (o próprio
//    agendamento manda). O token nunca sai do banco; quem confere é btg_sync_token_ok.
//  - Não faz nada enquanto btg_config.ligado = false (liga depois de cadastrar os webhooks).
//  - Usa a credencial própria do Hub (BTG_CLIENT_ID / BTG_CLIENT_SECRET, em Edge Functions >
//    Secrets). Nunca pede os relatórios que a Protego usa.
//  - "Verify JWT" desligado (quem chama é o banco, sem login).
const SB_URL = Deno.env.get("SUPABASE_URL") ?? "https://ghxjqmjtmbqzvogwzylo.supabase.co";
const CHAVE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const BTG = Deno.env.get("BTG_API_URL") ?? "https://api.btgpactual.com";
const ID = (Deno.env.get("BTG_CLIENT_ID") ?? "").trim();
const SEGREDO = (Deno.env.get("BTG_CLIENT_SECRET") ?? "").trim();

type Pedido = { servico: string; metodo: "GET" | "POST"; caminho: string; corpo?: Record<string, string>; pausa?: number };

function resposta(corpo: unknown, status = 200): Response {
  return new Response(JSON.stringify(corpo), { status, headers: { "Content-Type": "application/json; charset=utf-8" } });
}

async function rpc(nome: string, args: Record<string, unknown>): Promise<unknown> {
  const r = await fetch(`${SB_URL}/rest/v1/rpc/${nome}`, {
    method: "POST",
    headers: { apikey: CHAVE, Authorization: "Bearer " + CHAVE, "Content-Type": "application/json" },
    body: JSON.stringify(args),
  });
  const t = await r.text();
  if (!r.ok) throw new Error(`${nome}: ${r.status} ${t.slice(0, 300)}`);
  return t ? JSON.parse(t) : null;
}

// Feriados nacionais da B3 no ano (fixos + Carnaval, Sexta-feira Santa e Corpus Christi, pela Páscoa), "MM-DD".
function feriados(ano: number): Set<string> {
  const a = ano % 19, b = Math.floor(ano / 100), c = ano % 100, d = Math.floor(b / 4), e = b % 4;
  const f = Math.floor((b + 8) / 25), g = Math.floor((b - f + 1) / 3), h = (19 * a + b - d - g + 15) % 30;
  const i = Math.floor(c / 4), k = c % 4, l = (32 + 2 * e + 2 * i - h - k) % 7, m = Math.floor((a + 11 * h + 22 * l) / 451);
  const pascoa = new Date(ano, Math.floor((h + l - 7 * m + 114) / 31) - 1, ((h + l - 7 * m + 114) % 31) + 1);
  const mmdd = (x: Date) => String(x.getMonth() + 1).padStart(2, "0") + "-" + String(x.getDate()).padStart(2, "0");
  const desloc = (n: number) => { const x = new Date(pascoa); x.setDate(x.getDate() + n); return mmdd(x); };
  return new Set(["01-01", "04-21", "05-01", "09-07", "10-12", "11-02", "11-15", "11-20", "12-25",
    desloc(-48), desloc(-47), desloc(-2), desloc(60)]);
}
function diaUtil(d: Date): boolean {
  if (d.getDay() === 0 || d.getDay() === 6) return false;
  const k = String(d.getMonth() + 1).padStart(2, "0") + "-" + String(d.getDate()).padStart(2, "0");
  return !feriados(d.getFullYear()).has(k);
}

// Dia útil anterior em Brasília (pula fim de semana e feriado nacional).
function diaUtilAnterior(): { refDay: string; refMonth: string; refYear: string } {
  const hoje = new Date(new Date().toLocaleString("en-US", { timeZone: "America/Sao_Paulo" }));
  const d = new Date(hoje);
  do { d.setDate(d.getDate() - 1); } while (!diaUtil(d));
  const p = (n: number) => String(n).padStart(2, "0");
  return { refDay: p(d.getDate()), refMonth: p(d.getMonth() + 1), refYear: String(d.getFullYear()) };
}

// Mês anterior em Brasília, no formato da API de Rentabilidade ("10", "2026"). Em janeiro, dezembro do ano anterior.
function mesAnterior(): { referenceMonth: string; referenceYear: string } {
  const hoje = new Date(new Date().toLocaleString("en-US", { timeZone: "America/Sao_Paulo" }));
  const d = new Date(hoje.getFullYear(), hoje.getMonth() - 1, 1);
  return { referenceMonth: String(d.getMonth() + 1).padStart(2, "0"), referenceYear: String(d.getFullYear()) };
}

// Contas vinculadas no cadastro das Carteiras, sem repetir, com 9 dígitos.
async function contasVinculadas(): Promise<string[]> {
  const r = await fetch(`${SB_URL}/rest/v1/clientes?select=contas_btg&contas_btg=not.is.null`, { headers: { apikey: CHAVE, Authorization: "Bearer " + CHAVE } });
  if (!r.ok) throw new Error("clientes: " + r.status);
  const out = new Set<string>();
  for (const c of await r.json()) for (const k of (c.contas_btg || [])) {
    const s = String(k).replace(/\D/g, "").replace(/^0+/, "");
    if (s) out.add(s.padStart(9, "0"));
  }
  return [...out];
}
function planoPerformance(contas: string[], ref?: { referenceMonth: string; referenceYear: string }): Pedido[] {
  const m = ref ?? mesAnterior();
  const ano = Number(m.referenceYear), mes = Number(m.referenceMonth);
  const ultimo = new Date(Date.UTC(ano, mes, 0)).getUTCDate();
  const startDate = `${ano}-${m.referenceMonth}-01`, endDate = `${ano}-${m.referenceMonth}-${String(ultimo).padStart(2, "0")}`;
  return contas.map((accountNumber) => ({ servico: "performance-report", metodo: "POST" as const,
    caminho: "/iaas-profitability/api/v1/performance-report/account", corpo: { startDate, endDate, accountNumber }, pausa: 1100 }));
}

const cabSb = () => ({ apikey: CHAVE, Authorization: "Bearer " + CHAVE, "Content-Type": "application/json" });

// Serviços com arquivo processado hoje (dia de Brasília).
async function recebidosHoje(): Promise<Set<string>> {
  const h = new Date(new Date().toLocaleString("en-US", { timeZone: "America/Sao_Paulo" }));
  const ini = new Date(Date.UTC(h.getFullYear(), h.getMonth(), h.getDate(), 3, 0, 0)).toISOString(); // 0h em Brasília
  const r = await fetch(`${SB_URL}/rest/v1/btg_arquivos?select=servico&status=in.(processado,sem_dados)&recebido_em=gte.${encodeURIComponent(ini)}`, { headers: cabSb() });
  if (!r.ok) throw new Error("btg_arquivos: " + r.status);
  return new Set((await r.json()).map((x: { servico: string }) => x.servico));
}

// Apaga do Storage os originais dos relatórios diários com mais de `dias` dias (pastas <serviço>/<AAAA-MM-DD>/).
async function limparArquivos(dias = 60): Promise<number> {
  const limite = new Date(Date.now() - dias * 864e5).toISOString().slice(0, 10);
  const listar = async (prefix: string) => {
    const r = await fetch(`${SB_URL}/storage/v1/object/list/btg`, { method: "POST", headers: cabSb(), body: JSON.stringify({ prefix, limit: 1000, offset: 0 }) });
    return r.ok ? await r.json() as { name: string; id: string | null }[] : [];
  };
  const pastas = ["rm-reports-account-link", "rm-reports-account-base", "rm-reports-registration-data", "rm-reports-movement",
    "rm-reports-position-by-date", "rm-reports-nnm", "rm-reports-monthly-movement", "rm-reports-monthly-nnm",
    "rm-reports-monthly-account-base", "rm-reports-monthly-tir"];
  let apagados = 0;
  for (const s of pastas) {
    for (const d of await listar(s + "/")) {
      if (!/^\d{4}-\d{2}-\d{2}$/.test(d.name) || d.name >= limite) continue;
      const nomes = (await listar(`${s}/${d.name}/`)).filter((a) => a.id).map((a) => `${s}/${d.name}/${a.name}`);
      if (!nomes.length) continue;
      const r = await fetch(`${SB_URL}/storage/v1/object/btg`, { method: "DELETE", headers: cabSb(), body: JSON.stringify({ prefixes: nomes }) });
      if (r.ok) apagados += nomes.length;
    }
  }
  return apagados;
}

function plano(janela: string, ref?: { referenceMonth: string; referenceYear: string }): Pedido[] {
  const rm = "/api-rm-reports/api/v1/rm-reports";
  if (janela === "manha") return [
    { servico: "rm-reports-account-link", metodo: "GET", caminho: rm + "/account-link" },
    { servico: "rm-reports-account-base", metodo: "GET", caminho: rm + "/account-base" },
    { servico: "rm-reports-registration-data", metodo: "GET", caminho: rm + "/registration-data" },
    { servico: "rm-reports-movement", metodo: "GET", caminho: rm + "/movement" },
    { servico: "rm-reports-position-by-date", metodo: "POST", caminho: rm + "/position-by-date", corpo: diaUtilAnterior() },
  ];
  if (janela === "tarde") return [{ servico: "rm-reports-nnm", metodo: "GET", caminho: rm + "/nnm" }];
  if (janela === "noite") return [
    { servico: "rm-reports-movement", metodo: "GET", caminho: rm + "/movement" },
    { servico: "rm-reports-registration-data", metodo: "GET", caminho: rm + "/registration-data" },
  ];
  if (janela === "rentabilidade") {
    const pf = "/iaas-profitability/api/v1/profitability/monthly";
    const corpo = ref ?? mesAnterior();
    return [
      { servico: "monthly-customer-profitability", metodo: "POST", caminho: pf + "/customer-profitability", corpo },
      { servico: "monthly-product-profitability", metodo: "POST", caminho: pf + "/product-profitability", corpo },
      { servico: "monthly-strategy-profitability", metodo: "POST", caminho: pf + "/strategy-profitability", corpo },
    ];
  }
  return [];
}

async function novoToken(): Promise<string> {
  const r = await fetch(BTG + "/iaas-auth/api/v1/authorization/oauth2/accesstoken", {
    method: "POST",
    headers: { Authorization: "Basic " + btoa(ID + ":" + SEGREDO), "x-id-partner-request": crypto.randomUUID(),
               "Content-Type": "application/x-www-form-urlencoded" },
    body: "grant_type=client_credentials",
  });
  const tok = r.headers.get("access_token") ?? "";
  if (!r.ok || !tok) throw new Error("autorizador do BTG: " + r.status + " " + (await r.text()).slice(0, 200));
  await rpc("btg_token_guardar", { p_token: tok, p_validade_seg: 840 });
  return tok;
}

async function token(forcarNovo = false): Promise<string> {
  if (!forcarNovo) {
    const t = await rpc("btg_token_atual", {});
    if (typeof t === "string" && t) return t;
  }
  return await novoToken();
}

async function chamar(p: Pedido, tok: string): Promise<Response> {
  return await fetch(BTG + p.caminho, {
    method: p.metodo,
    headers: { "x-id-partner-request": crypto.randomUUID(), access_token: tok, "Content-Type": "application/json" },
    body: p.corpo ? JSON.stringify(p.corpo) : undefined,
  });
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return resposta({ erro: "Use POST." }, 405);
  if (!CHAVE) return resposta({ erro: "Sem a chave de serviço do Supabase." }, 500);

  const chave = req.headers.get("x-btg-sync") ?? "";
  if (!(await rpc("btg_sync_token_ok", { p: chave }))) return resposta({ erro: "não autorizado" }, 401);

  const corpo = await req.json().catch(() => ({})) as { janela?: string; forcar?: boolean; mes?: number; ano?: number; conta?: string; de?: string };
  const janela = String(corpo.janela ?? "");
  const m = Number(corpo.mes), a = Number(corpo.ano);
  const ref = m >= 1 && m <= 12 && a >= 2020 && a <= 2100
    ? { referenceMonth: String(m).padStart(2, "0"), referenceYear: String(a) } : undefined;
  if (janela === "limpeza-arquivos") {
    const n = await limparArquivos(60);
    console.log("btg-sync limpeza-arquivos", n);
    return resposta({ ok: true, janela, apagados: n });
  }
  let pedidos = plano(janela, ref);
  if (janela === "reforco") {
    const de = corpo.de === "tarde" ? "tarde" : "manha";
    const ok = await recebidosHoje();
    pedidos = plano(de).filter((p) => !ok.has(p.servico));
    if (!pedidos.length) return resposta({ ok: true, janela, de, nada: "tudo chegou hoje" });
  }
  if (janela === "performance") {
    const uma = String(corpo.conta ?? "").replace(/\D/g, "").replace(/^0+/, "");
    pedidos = planoPerformance(uma ? [uma.padStart(9, "0")] : await contasVinculadas(), ref);
    if (!pedidos.length) return resposta({ ok: true, janela, nada: "nenhuma conta vinculada nas Carteiras" });
  }
  if (!pedidos.length) return resposta({ erro: "janela desconhecida: " + janela }, 400);
  if (!(await rpc("btg_ligado", {})) && !corpo.forcar) return resposta({ ok: true, desligado: true });
  if (!ID || !SEGREDO) return resposta({ erro: "Faltam BTG_CLIENT_ID e BTG_CLIENT_SECRET nos Secrets." }, 500);

  let tok = await token();
  const resultado: Record<string, number | string> = {};
  for (const p of pedidos) {
    try {
      let r = await chamar(p, tok);
      if (r.status === 401) { tok = await token(true); r = await chamar(p, tok); }
      const texto = await r.text();
      await rpc("btg_registrar_pedido", {
        p_servico: p.servico, p_metodo: p.metodo, p_caminho: p.caminho, p_corpo: p.corpo ?? null,
        p_origem: corpo.forcar ? "manual" : "agendado", p_http: r.status, p_x_id: r.headers.get("x-id-pactual"),
        p_resposta: texto.slice(0, 2000),
      });
      resultado[p.servico + (p.corpo?.accountNumber ? " " + p.corpo.accountNumber : "")] = r.status;
    } catch (e) {
      resultado[p.servico + (p.corpo?.accountNumber ? " " + p.corpo.accountNumber : "")] = "erro: " + String((e as Error)?.message ?? e).slice(0, 200);
    }
    await new Promise((ok) => setTimeout(ok, p.pausa ?? 400));
  }
  console.log("btg-sync", janela, JSON.stringify(resultado));
  return resposta({ ok: true, janela, resultado });
});
