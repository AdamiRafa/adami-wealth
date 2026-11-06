// Função "btg-sync" do Supabase (Edge Functions): pede os relatórios ao BTG.
//
// Fase 1 da integração (06/11/2026, btg.sql). Quem chama é o agendamento do banco (pg_cron),
// em dias úteis, logo depois das janelas em que o BTG gera os arquivos:
//   "manha" 8h30: vínculo conta-assessor, base de contas, cadastro, movimentação e a posição
//                 do dia útil anterior (posição por data);
//   "tarde" 15h30: NNM (captação líquida);
//   "noite" 20h30: movimentação do fim do dia.
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

type Pedido = { servico: string; metodo: "GET" | "POST"; caminho: string; corpo?: Record<string, string> };

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

// Dia útil anterior em Brasília (fim de semana não conta; feriado ainda não).
function diaUtilAnterior(): { refDay: string; refMonth: string; refYear: string } {
  const hoje = new Date(new Date().toLocaleString("en-US", { timeZone: "America/Sao_Paulo" }));
  const d = new Date(hoje);
  do { d.setDate(d.getDate() - 1); } while (d.getDay() === 0 || d.getDay() === 6);
  const p = (n: number) => String(n).padStart(2, "0");
  return { refDay: p(d.getDate()), refMonth: p(d.getMonth() + 1), refYear: String(d.getFullYear()) };
}

function plano(janela: string): Pedido[] {
  const rm = "/api-rm-reports/api/v1/rm-reports";
  if (janela === "manha") return [
    { servico: "rm-reports-account-link", metodo: "GET", caminho: rm + "/account-link" },
    { servico: "rm-reports-account-base", metodo: "GET", caminho: rm + "/account-base" },
    { servico: "rm-reports-registration-data", metodo: "GET", caminho: rm + "/registration-data" },
    { servico: "rm-reports-movement", metodo: "GET", caminho: rm + "/movement" },
    { servico: "rm-reports-position-by-date", metodo: "POST", caminho: rm + "/position-by-date", corpo: diaUtilAnterior() },
  ];
  if (janela === "tarde") return [{ servico: "rm-reports-nnm", metodo: "GET", caminho: rm + "/nnm" }];
  if (janela === "noite") return [{ servico: "rm-reports-movement", metodo: "GET", caminho: rm + "/movement" }];
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

  const corpo = await req.json().catch(() => ({})) as { janela?: string; forcar?: boolean };
  const janela = String(corpo.janela ?? "");
  const pedidos = plano(janela);
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
      resultado[p.servico] = r.status;
    } catch (e) {
      resultado[p.servico] = "erro: " + String((e as Error)?.message ?? e).slice(0, 200);
    }
    await new Promise((ok) => setTimeout(ok, 400));
  }
  console.log("btg-sync", janela, JSON.stringify(resultado));
  return resposta({ ok: true, janela, resultado });
});
