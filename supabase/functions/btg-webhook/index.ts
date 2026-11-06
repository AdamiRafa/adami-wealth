// Função "btg-webhook" do Supabase (Edge Functions): o receptor dos relatórios do BTG.
//
// Fase 1 da integração (06/11/2026, btg.sql): só recebe e guarda. Não mexe em cliente.
//
// Como o BTG entrega: o Hub pede um relatório (função btg-sync); quando fica pronto, o BTG faz
// POST aqui com um aviso {"errors":[...], "response":{"url": "<link assinado do S3>", ...}}.
// O arquivo (CSV) está no link, que expira: esta função baixa na hora, guarda o original no
// Storage privado "btg" e grava as linhas no banco (função btg_receber).
//
// Endereço cadastrado no portal do BTG, um por serviço (o serviço vai no fim do caminho):
//   https://ghxjqmjtmbqzvogwzylo.supabase.co/functions/v1/btg-webhook/<serviço>
//   ex.: .../btg-webhook/rm-reports-account-link
//
// Segurança:
//  - Autenticação "API Key" do portal: o BTG manda a chave que cadastramos lá. Ela fica só
//    no Supabase, em Edge Functions > Secrets, como BTG_WEBHOOK_KEY. Sem a chave certa: 401.
//    (O nome do cabeçalho não está documentado; aceitamos a chave em qualquer cabeçalho.)
//  - Só baixa de link https do S3 do BTG (invest-reports*.amazonaws.com): um aviso falso não
//    consegue fazer esta função buscar outro endereço.
//  - Só aceita os serviços da lista abaixo. Os 5 serviços que a Protego usa não estão nela.
//  - "Verify JWT" desligado: quem chama é o BTG, sem login do Supabase.
const SB_URL = Deno.env.get("SUPABASE_URL") ?? "https://ghxjqmjtmbqzvogwzylo.supabase.co";
const CHAVE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const CHAVE_WEBHOOK = (Deno.env.get("BTG_WEBHOOK_KEY") ?? "").trim();
const HOST_ARQUIVO = /^invest-reports[a-z0-9.-]*\.amazonaws\.com$/i;
// Só para o teste local (S3 falso em http://localhost). Nunca definir no Supabase.
const TESTE_LOCAL = Deno.env.get("BTG_TESTE_LOCAL") === "1";
const LIMITE_BYTES = 200 * 1024 * 1024;

const SERVICOS = new Set([
  "rm-reports-account-link", "rm-reports-account-base", "rm-reports-registration-data",
  "rm-reports-movement", "rm-reports-monthly-movement", "rm-reports-position-by-date",
  "rm-reports-nnm", "rm-reports-monthly-nnm", "rm-reports-monthly-account-base", "rm-reports-monthly-tir",
  "monthly-customer-profitability", "monthly-product-profitability", "monthly-strategy-profitability",
]);

function resposta(corpo: unknown, status = 200): Response {
  return new Response(JSON.stringify(corpo), { status, headers: { "Content-Type": "application/json; charset=utf-8" } });
}

// Comparação em tempo constante (não vaza, pelo tempo de resposta, quanto da chave acertou).
function igual(a: string, b: string): boolean {
  const ea = new TextEncoder().encode(a), eb = new TextEncoder().encode(b);
  let d = ea.length ^ eb.length;
  for (let i = 0; i < Math.max(ea.length, eb.length); i++) d |= (ea[i] ?? 0) ^ (eb[i] ?? 0);
  return d === 0;
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

// ---------- CSV ----------
export function lerCsv(texto: string): { colunas: string[]; linhas: Record<string, string>[] } {
  texto = texto.replace(/^\uFEFF/, "");
  const primeira = texto.split(/\r?\n/, 1)[0] ?? "";
  const contar = (c: string) => primeira.split(c).length - 1;
  const sep = [";", ",", "\t", "|"].sort((a, b) => contar(b) - contar(a))[0];
  const registros: string[][] = [];
  let campo = "", reg: string[] = [], aspas = false;
  for (let i = 0; i < texto.length; i++) {
    const c = texto[i];
    if (aspas) {
      if (c === '"') { if (texto[i + 1] === '"') { campo += '"'; i++; } else aspas = false; }
      else campo += c;
    } else if (c === '"' && campo === "") aspas = true;
    else if (c === sep) { reg.push(campo); campo = ""; }
    else if (c === "\n" || c === "\r") {
      if (c === "\r" && texto[i + 1] === "\n") i++;
      reg.push(campo); campo = "";
      if (reg.some((x) => x !== "")) registros.push(reg);
      reg = [];
    } else campo += c;
  }
  reg.push(campo);
  if (reg.some((x) => x !== "")) registros.push(reg);
  const colunas = (registros.shift() ?? []).map((c) => c.trim());
  const linhas = registros.map((r) => {
    const o: Record<string, string> = {};
    colunas.forEach((c, i) => { if (c) o[c] = (r[i] ?? "").trim(); });
    return o;
  });
  return { colunas, linhas };
}

async function decodificar(bytes: Uint8Array): Promise<string> {
  if (bytes[0] === 0x1f && bytes[1] === 0x8b) {
    const fluxo = new Blob([bytes as unknown as BlobPart]).stream().pipeThrough(new DecompressionStream("gzip"));
    bytes = new Uint8Array(await new Response(fluxo).arrayBuffer());
  } else if (bytes[0] === 0x50 && bytes[1] === 0x4b) {
    throw new Error("o BTG mandou um arquivo .zip; falta o suporte a zip (o original ficou guardado no Storage)");
  }
  const utf8 = new TextDecoder("utf-8").decode(bytes);
  return utf8.includes("\uFFFD") ? new TextDecoder("windows-1252").decode(bytes) : utf8;
}

async function processar(id: number, servico: string, url: string): Promise<void> {
  try {
    const controle = new AbortController();
    const prazo = setTimeout(() => controle.abort(), 90_000);
    const r = await fetch(url, { signal: controle.signal, redirect: "error" });
    clearTimeout(prazo);
    if (!r.ok) throw new Error("download " + r.status);
    const bytes = new Uint8Array(await r.arrayBuffer());
    if (bytes.length > LIMITE_BYTES) throw new Error("arquivo maior que 200 MB");

    const dia = new Date().toISOString().slice(0, 10);
    const caminho = `${servico}/${dia}/${id}.csv`;
    const up = await fetch(`${SB_URL}/storage/v1/object/btg/${caminho}`, {
      method: "POST",
      headers: { apikey: CHAVE, Authorization: "Bearer " + CHAVE, "Content-Type": "text/csv", "x-upsert": "true" },
      body: bytes,
    });
    if (!up.ok) throw new Error("storage " + up.status + " " + (await up.text()).slice(0, 200));

    const { colunas, linhas } = lerCsv(await decodificar(bytes));
    await rpc("btg_receber", { p_arquivo_id: id, p_caminho: caminho, p_tamanho: bytes.length, p_colunas: colunas, p_linhas: linhas });
    console.log("btg-webhook", servico, id, linhas.length, "linhas");
  } catch (e) {
    const msg = String((e as Error)?.message ?? e);
    console.error("btg-webhook", servico, id, msg);
    try { await rpc("btg_marcar_erro", { p_arquivo_id: id, p_erro: msg }); } catch (_) { /* registro é melhor esforço */ }
  }
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return resposta({ erro: "Use POST." }, 405);
  if (!CHAVE) return resposta({ erro: "Sem a chave de serviço do Supabase." }, 500);
  if (CHAVE_WEBHOOK.length < 20) return resposta({ erro: "BTG_WEBHOOK_KEY não configurada." }, 503);

  let autorizado = false;
  const nomes: string[] = [];
  for (const [nome, valor] of req.headers) {
    nomes.push(nome);
    const v = valor.replace(/^(bearer|apikey|api-key|key)\s+/i, "").trim();
    if (igual(v, CHAVE_WEBHOOK)) autorizado = true;
  }
  if (!autorizado) {
    console.warn("btg-webhook: chave ausente ou errada; cabeçalhos:", nomes.join(","));
    return resposta({ erro: "não autorizado" }, 401);
  }

  const servico = new URL(req.url).pathname.split("/").filter(Boolean).pop() ?? "";
  if (!SERVICOS.has(servico)) return resposta({ erro: "serviço não aceito: " + servico }, 404);

  const corpo = await req.json().catch(() => null) as Record<string, unknown> | null;
  if (!corpo || typeof corpo !== "object") return resposta({ erro: "corpo inválido" }, 400);
  const info = ((corpo as { response?: unknown }).response ?? corpo) as Record<string, unknown>;
  const erros = (Array.isArray((corpo as { errors?: unknown }).errors) ? (corpo as { errors: unknown[] }).errors : [])
    .filter((e) => e && typeof e === "object" && ((e as { code?: unknown }).code || (e as { message?: unknown }).message));
  const url = typeof info?.url === "string" ? info.url : "";

  if (erros.length || !url) {
    const msg = erros.map((e) => String((e as { message?: unknown }).message ?? (e as { code?: unknown }).code)).join(" | ");
    await rpc("btg_aviso", { p_servico: servico, p_aviso: corpo, p_status: erros.length ? "erro" : "sem_dados", p_erro: msg || null });
    return resposta({ ok: true });
  }

  let host = "";
  try {
    const u = new URL(url);
    if (TESTE_LOCAL ? u.hostname === "localhost" : (u.protocol === "https:" && HOST_ARQUIVO.test(u.hostname))) host = u.hostname;
  } catch (_) { /* inválida */ }
  if (!host) {
    await rpc("btg_aviso", { p_servico: servico, p_aviso: corpo, p_status: "erro", p_erro: "link de arquivo fora do S3 do BTG: " + (host || "inválido") });
    return resposta({ erro: "link não aceito" }, 400);
  }

  const id = await rpc("btg_aviso", { p_servico: servico, p_aviso: corpo, p_status: "recebido" }) as number;
  // Responde logo ao BTG e baixa em segundo plano (o link expira, mas em minutos, não segundos).
  const tarefa = processar(id, servico, url);
  const er = (globalThis as { EdgeRuntime?: { waitUntil(p: Promise<unknown>): void } }).EdgeRuntime;
  if (er?.waitUntil) er.waitUntil(tarefa); else await tarefa;
  return resposta({ ok: true, id });
});
