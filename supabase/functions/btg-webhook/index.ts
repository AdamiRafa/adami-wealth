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
  "performance-report",
]);

// Rentabilidade Mensal (btg_rentabilidade.sql): arquivos que podem passar de 100 MB (todas as
// contas, até 12 meses, um registro por produto). São lidos em pedaços e gravados em lotes,
// sem carregar o arquivo inteiro na memória.
const RENTABILIDADE = new Set(["monthly-customer-profitability", "monthly-product-profitability", "monthly-strategy-profitability"]);
// Do relatório por produto só guardamos o que as Carteiras usam (o arquivo tem ~50 colunas).
const CAMPOS_PRODUTO = ["cod_carteira", "reference_month", "product_id", "product_name", "product_cnpj", "market_id",
  "product_key", "auc_end", "inflow_and_outflow", "taxes_paid", "profit_mtd", "profit_ytd", "profit_12m", "profit_ttd",
  "profitability_mtd", "profitability_ytd", "profitability_3m", "profitability_6m", "profitability_12m", "profitability_ttd"];
const LOTE = 1000;
const LIMITE_ORIGINAL = 45 * 1024 * 1024; // o Storage aceita até 50 MB por arquivo

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
// Leitor em pedaços: recebe o texto aos poucos (arquivos de centenas de MB não cabem
// inteiros na memória da função) e devolve os registros prontos. Separador decidido pela
// primeira linha (; , tab |), aspas com "" dentro, \r\n ou \n, BOM no começo.
export class LeitorCsv {
  private sep = "";
  private inicio = "";          // texto guardado até achar a primeira quebra de linha
  private campo = "";
  private reg: string[] = [];
  private aspas = false;
  private aspaNoFim = false;     // pedaço terminou numa " dentro de aspas: só o próximo diz se é ""
  private pularLF = false;       // pedaço terminou num \r: um \n logo depois é a mesma quebra
  colunas: string[] | null = null;

  constructor(private aoLer: (linha: Record<string, string>) => void) {}

  private decidirSeparador(t: string) {
    const q = t.search(/\r|\n/);
    const primeira = q < 0 ? t : t.slice(0, q);
    const contar = (c: string) => primeira.split(c).length - 1;
    this.sep = [";", ",", "\t", "|"].sort((a, b) => contar(b) - contar(a))[0];
  }

  private fecharRegistro() {
    this.reg.push(this.campo); this.campo = "";
    const r = this.reg; this.reg = [];
    if (!r.some((x) => x !== "")) return;
    if (!this.colunas) {
      // Cabeçalho: sem BOM (inclusive o BOM do UTF-8 lido como latin1, "ï»¿") e sem espaços.
      this.colunas = r.map((c, i) => (i === 0 ? c.replace(/^(\uFEFF|ï»¿|ÿþ|þÿ)/, "") : c).trim());
      return;
    }
    const o: Record<string, string> = {};
    this.colunas.forEach((c, i) => { if (c) o[c] = (r[i] ?? "").trim(); });
    this.aoLer(o);
  }

  ler(texto: string) {
    if (!this.sep) {
      this.inicio += texto;
      if (this.inicio.search(/\r|\n/) < 0 && this.inicio.length < 1_000_000) return;
      texto = this.inicio.replace(/^\uFEFF/, ""); this.inicio = "";
      this.decidirSeparador(texto);
    }
    let i = 0;
    if (this.aspaNoFim) {
      this.aspaNoFim = false;
      if (texto[0] === '"') { this.campo += '"'; i = 1; } else this.aspas = false;
    }
    if (this.pularLF) { this.pularLF = false; if (texto[i] === "\n") i++; }
    for (; i < texto.length; i++) {
      const c = texto[i];
      if (this.aspas) {
        if (c === '"') {
          if (i + 1 === texto.length) { this.aspaNoFim = true; return; }
          if (texto[i + 1] === '"') { this.campo += '"'; i++; } else this.aspas = false;
        } else this.campo += c;
      } else if (c === '"' && this.campo === "") this.aspas = true;
      else if (c === this.sep) { this.reg.push(this.campo); this.campo = ""; }
      else if (c === "\n" || c === "\r") {
        this.fecharRegistro();
        if (c === "\r") { if (i + 1 === texto.length) this.pularLF = true; else if (texto[i + 1] === "\n") i++; }
      } else this.campo += c;
    }
  }

  fim() {
    if (!this.sep && this.inicio) { const t = this.inicio; this.inicio = ""; this.sep = ""; this.ler(t + "\n"); }
    this.aspaNoFim = false;
    if (this.campo !== "" || this.reg.length) this.fecharRegistro();
  }
}

export function lerCsv(texto: string): { colunas: string[]; linhas: Record<string, string>[] } {
  const linhas: Record<string, string>[] = [];
  const l = new LeitorCsv((o) => linhas.push(o));
  l.ler(texto); l.fim();
  return { colunas: l.colunas ?? [], linhas };
}

// .zip (17/11/2026: o BTG manda os relatórios assim). Lê o diretório central e devolve as
// entradas de arquivo (CSV primeiro), cada uma como fluxo já descompactado. Só "guardado" (0) e
// "deflate" (8), que é o que qualquer gerador de zip usa; zip64 não (arquivos acima de 4 GB).
export type EntradaZip = { nome: string; fluxo: () => ReadableStream<Uint8Array> };
export function entradasZip(z: Uint8Array): EntradaZip[] {
  const dv = new DataView(z.buffer, z.byteOffset, z.byteLength);
  let fim = -1;
  for (let i = z.length - 22; i >= Math.max(0, z.length - 65557); i--) if (dv.getUint32(i, true) === 0x06054b50) { fim = i; break; }
  if (fim < 0) throw new Error("zip sem diretório central (arquivo cortado?)");
  const total = dv.getUint16(fim + 10, true);
  let p = dv.getUint32(fim + 16, true);
  const lista: (EntradaZip & { csv: boolean })[] = [];
  for (let k = 0; k < total; k++) {
    if (p + 46 > z.length || dv.getUint32(p, true) !== 0x02014b50) throw new Error("zip corrompido (diretório)");
    const metodo = dv.getUint16(p + 10, true), comp = dv.getUint32(p + 20, true);
    const ln = dv.getUint16(p + 28, true), lx = dv.getUint16(p + 30, true), lc = dv.getUint16(p + 32, true);
    const local = dv.getUint32(p + 42, true);
    const nome = new TextDecoder().decode(z.subarray(p + 46, p + 46 + ln));
    p += 46 + ln + lx + lc;
    if (nome.endsWith("/") || /(^|\/)(__MACOSX|\.)/.test(nome)) continue;
    if (comp === 0xffffffff || local === 0xffffffff) throw new Error("zip64 não suportado");
    if (metodo !== 0 && metodo !== 8) throw new Error("zip com compressão não suportada (método " + metodo + ")");
    if (dv.getUint32(local, true) !== 0x04034b50) throw new Error("zip corrompido (entrada " + nome + ")");
    const ini = local + 30 + dv.getUint16(local + 26, true) + dv.getUint16(local + 28, true);
    const dados = z.subarray(ini, ini + comp);
    lista.push({
      nome, csv: /\.(csv|txt)$/i.test(nome),
      fluxo: () => {
        // Entrega o compactado em partes de 64 KB, para o descompactado também sair em pedaços.
        let pos = 0;
        const s = new ReadableStream<Uint8Array>({
          pull(c) { if (pos >= dados.length) { c.close(); return; } c.enqueue(dados.slice(pos, pos + 65536)); pos += 65536; },
        });
        return metodo === 8 ? s.pipeThrough(new DecompressionStream("deflate-raw" as CompressionFormat) as unknown as ReadableWritablePair<Uint8Array, Uint8Array>) : s;
      },
    });
  }
  if (!lista.length) throw new Error("zip sem arquivos");
  const csvs = lista.filter((e) => e.csv);
  return csvs.length ? csvs : lista;
}
const ehZip = (b: Uint8Array) => b[0] === 0x50 && b[1] === 0x4b && b[2] === 0x03 && b[3] === 0x04;

function textoDe(bytes: Uint8Array): string {
  const utf8 = new TextDecoder("utf-8").decode(bytes);
  return utf8.includes("\uFFFD") ? new TextDecoder("windows-1252").decode(bytes) : utf8;
}

// Devolve um texto por arquivo (o zip pode trazer mais de um CSV; cada um com o seu cabeçalho).
async function decodificar(bytes: Uint8Array): Promise<string[]> {
  if (bytes[0] === 0x1f && bytes[1] === 0x8b) {
    const fluxo = new Blob([bytes as unknown as BlobPart]).stream().pipeThrough(new DecompressionStream("gzip"));
    bytes = new Uint8Array(await new Response(fluxo).arrayBuffer());
  } else if (ehZip(bytes)) {
    const textos: string[] = [];
    for (const e of entradasZip(bytes)) textos.push(textoDe(new Uint8Array(await new Response(e.fluxo()).arrayBuffer())));
    return textos;
  }
  return [textoDe(bytes)];
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
    const zip = ehZip(bytes);
    const caminho = `${servico}/${dia}/${id}.${zip ? "zip" : "csv"}`;
    const up = await fetch(`${SB_URL}/storage/v1/object/btg/${caminho}`, {
      method: "POST",
      headers: { apikey: CHAVE, Authorization: "Bearer " + CHAVE, "Content-Type": zip ? "application/zip" : "text/csv", "x-upsert": "true" },
      body: bytes,
    });
    if (!up.ok) throw new Error("storage " + up.status + " " + (await up.text()).slice(0, 200));

    let colunas: string[] = [];
    const linhas: Record<string, string>[] = [];
    for (const texto of await decodificar(bytes)) {
      const r = lerCsv(texto);
      if (!colunas.length) colunas = r.colunas;
      for (const l of r.linhas) linhas.push(l);
    }
    // Arquivo grande (a posição por data passa de dezenas de milhares de linhas): grava em lotes de 1.000, senão o
    // banco corta por tempo (8 s por chamada; 18/11/2026). A base de contas e o vínculo têm tratamento próprio.
    if (linhas.length > 1500 && servico !== "rm-reports-account-base" && servico !== "rm-reports-account-link") {
      for (let i = 0; i < linhas.length; i += LOTE) {
        await rpc("btg_linhas_lote", { p_arquivo_id: id, p_inicio: i, p_linhas: linhas.slice(i, i + LOTE) });
      }
      await rpc("btg_linhas_fim", { p_arquivo_id: id, p_caminho: caminho, p_tamanho: bytes.length, p_colunas: colunas, p_total: linhas.length });
    } else {
      await rpc("btg_receber", { p_arquivo_id: id, p_caminho: caminho, p_tamanho: bytes.length, p_colunas: colunas, p_linhas: linhas });
    }
    console.log("btg-webhook", servico, id, linhas.length, "linhas");
  } catch (e) {
    const msg = String((e as Error)?.message ?? e);
    console.error("btg-webhook", servico, id, msg);
    try { await rpc("btg_marcar_erro", { p_arquivo_id: id, p_erro: msg }); } catch (_) { /* registro é melhor esforço */ }
  }
}

// Relatório de Performance (API de Performance, 19/11/2026): o PDF que o Emil baixava do BTG e subia nas
// Carteiras, um por conta, dentro de um zip. O aviso não diz a conta nem o período (só url, fileSize,
// lastModified): os dois vêm no nome do arquivo, no link e no PDF de dentro
// ("performance_004180373_2026-10-01_2026-10-31.zip", conferido em 18/11/2026). Cada PDF vai para o Storage privado "btg" em
// performance-report/pdf/<AAAA-MM>/<conta>.pdf e vira uma linha em btg_linhas (nr_conta, caminho, período),
// que as Carteiras usam para achar o relatório do cliente.
export function periodoDoNome(nome: string): { inicio: string; fim: string } {
  const m = String(nome).match(/(\d{4}-\d{2}-\d{2})\D+(\d{4}-\d{2}-\d{2})/);
  return m ? { inicio: m[1], fim: m[2] } : { inicio: "", fim: "" };
}
export function contaDoNome(nome: string): string {
  const base = String(nome).replace(/^.*\//, "");
  const m = base.match(/(?<!\d)(\d{9})(?!\d)/) || base.match(/(\d{6,12})/); // a conta do BTG tem 9 dígitos
  return m ? m[1] : "";
}
async function processarPerformance(id: number, url: string, info: Record<string, unknown>): Promise<void> {
  try {
    const controle = new AbortController();
    const prazo = setTimeout(() => controle.abort(), 90_000);
    const r = await fetch(url, { signal: controle.signal, redirect: "error" });
    clearTimeout(prazo);
    if (!r.ok) throw new Error("download " + r.status);
    const bytes = new Uint8Array(await r.arrayBuffer());
    if (bytes.length > LIMITE_ORIGINAL) throw new Error("arquivo maior que 45 MB");
    const dia = new Date().toISOString().slice(0, 10);
    const zip = ehZip(bytes);
    const ehPdf = (b: Uint8Array) => b[0] === 0x25 && b[1] === 0x50 && b[2] === 0x44 && b[3] === 0x46; // %PDF
    if (!zip && !ehPdf(bytes)) throw new Error("o BTG mandou um arquivo que não é zip nem PDF");
    const guardar = async (caminho: string, corpo: Uint8Array, tipo: string) => {
      const up = await fetch(`${SB_URL}/storage/v1/object/btg/${caminho}`, {
        method: "POST", headers: { apikey: CHAVE, Authorization: "Bearer " + CHAVE, "Content-Type": tipo, "x-upsert": "true" }, body: corpo,
      });
      if (!up.ok) throw new Error("storage " + up.status + " " + (await up.text()).slice(0, 200));
    };
    const caminho = `performance-report/${dia}/${id}.${zip ? "zip" : "pdf"}`;
    await guardar(caminho, bytes, zip ? "application/zip" : "application/pdf");
    let nomeLink = "";
    try { nomeLink = decodeURIComponent(new URL(url).pathname.split("/").pop() ?? ""); } catch (_) { /* sem nome */ }
    const perLink = periodoDoNome(nomeLink);
    const pdfs: { nome: string; bytes: Uint8Array }[] = [];
    if (zip) {
      for (const e of entradasZip(bytes)) {
        if (!/\.pdf$/i.test(e.nome)) continue;
        pdfs.push({ nome: e.nome, bytes: new Uint8Array(await new Response(e.fluxo()).arrayBuffer()) });
      }
    } else pdfs.push({ nome: "relatorio.pdf", bytes });
    if (!pdfs.length) throw new Error("o zip não tem PDF");
    const linhas: Record<string, string>[] = [];
    for (let i = 0; i < pdfs.length; i++) {
      const conta = contaDoNome(pdfs[i].nome) || contaDoNome(nomeLink);
      const perPdf = periodoDoNome(pdfs[i].nome);
      const inicio = perPdf.inicio || perLink.inicio || String(info.startDate ?? "").slice(0, 10);
      const fim = perPdf.fim || perLink.fim || String(info.endDate ?? "").slice(0, 10);
      const destino = `performance-report/pdf/${(fim || inicio || dia).slice(0, 7)}/${conta || ("sem-conta-" + id + "-" + i)}.pdf`;
      await guardar(destino, pdfs[i].bytes, "application/pdf");
      linhas.push({ nr_conta: conta, arquivo: pdfs[i].nome, caminho: destino, inicio, fim, tamanho: String(pdfs[i].bytes.length) });
    }
    await rpc("btg_receber", { p_arquivo_id: id, p_caminho: caminho, p_tamanho: bytes.length,
      p_colunas: ["nr_conta", "arquivo", "caminho", "inicio", "fim", "tamanho"], p_linhas: linhas });
    console.log("btg-webhook performance-report", id, linhas.map((l) => l.nr_conta || l.arquivo).join(","));
  } catch (e) {
    const msg = String((e as Error)?.message ?? e);
    console.error("btg-webhook performance-report", id, msg);
    try { await rpc("btg_marcar_erro", { p_arquivo_id: id, p_erro: msg }); } catch (_) { /* melhor esforço */ }
  }
}

async function processarEmLotes(id: number, servico: string, url: string): Promise<void> {
  try {
    const controle = new AbortController();
    const prazo = setTimeout(() => controle.abort(), 300_000);
    const r = await fetch(url, { signal: controle.signal, redirect: "error" });
    if (!r.ok || !r.body) throw new Error("download " + r.status);

    // Guarda o original (até 45 MB) enquanto lê.
    const brutos: Uint8Array[] = [];
    let tamanho = 0, grande = false;
    const leitorBruto = r.body.getReader();
    const primeiro = await leitorBruto.read();
    const b0 = primeiro.value ?? new Uint8Array();
    const guardar = (b: Uint8Array) => {
      tamanho += b.length;
      if (tamanho > LIMITE_BYTES * 2) throw new Error("arquivo maior que 400 MB");
      if (!grande) { if (tamanho > LIMITE_ORIGINAL) { grande = true; brutos.length = 0; } else brutos.push(b); }
    };
    const zip = ehZip(b0);
    const gzip = b0[0] === 0x1f && b0[1] === 0x8b;

    const lote: Record<string, string>[] = [];
    const ehProduto = servico === "monthly-product-profitability";
    const aoLer = (o: Record<string, string>) => {
      if (ehProduto) { const f: Record<string, string> = {}; for (const k of CAMPOS_PRODUTO) if (k in o) f[k] = o[k]; lote.push(f); }
      else lote.push(o);
    };
    let total = 0;
    let colunas: string[] = [];
    const enviar = async (tudo: boolean) => {
      while (lote.length >= LOTE || (tudo && lote.length)) {
        const parte = lote.splice(0, LOTE);
        total += parte.length;
        await rpc("btg_rent_receber", { p_arquivo_id: id, p_linhas: parte });
      }
    };
    // Lê um CSV em pedaços. Codificação: UTF-8, a não ser que o começo não seja UTF-8 válido (aí, latin1).
    const consumir = async (leitor: ReadableStreamDefaultReader<Uint8Array>) => {
      const csv = new LeitorCsv(aoLer);
      let dec: TextDecoder | null = null;
      for (;;) {
        const x = await leitor.read();
        if (x.done) break;
        if (!dec) {
          const teste = new TextDecoder("utf-8").decode(x.value.subarray(0, Math.max(0, x.value.length - 4)));
          dec = new TextDecoder(teste.includes("�") ? "windows-1252" : "utf-8");
        }
        csv.ler(dec.decode(x.value, { stream: true }));
        await enviar(false);
      }
      if (dec) csv.ler(dec.decode());
      csv.fim();
      if (!colunas.length && csv.colunas) colunas = csv.colunas;
    };

    if (zip) {
      // O zip só abre inteiro (o índice fica no fim). O compactado é bem menor que o CSV, e cada
      // arquivo de dentro continua sendo lido em pedaços.
      if (!primeiro.done) guardar(b0);
      const partes: Uint8Array[] = primeiro.done ? [] : [b0];
      for (;;) { const x = await leitorBruto.read(); if (x.done) break; guardar(x.value); partes.push(x.value); }
      const z = new Uint8Array(tamanho); let q = 0; for (const b of partes) { z.set(b, q); q += b.length; }
      partes.length = 0;
      for (const e of entradasZip(z)) await consumir(e.fluxo().getReader());
    } else {
      const fonte = new ReadableStream<Uint8Array>({
        start(c) { if (!primeiro.done && b0.length) { guardar(b0); c.enqueue(b0); } if (primeiro.done) c.close(); },
        async pull(c) {
          const x = await leitorBruto.read();
          if (x.done) { c.close(); return; }
          guardar(x.value); c.enqueue(x.value);
        },
      });
      await consumir((gzip
        ? fonte.pipeThrough(new DecompressionStream("gzip") as unknown as ReadableWritablePair<Uint8Array, Uint8Array>)
        : fonte).getReader());
    }
    clearTimeout(prazo);
    await enviar(true);

    let caminho: string | null = null;
    if (!grande && tamanho) {
      const dia = new Date().toISOString().slice(0, 10);
      caminho = `${servico}/${dia}/${id}.${zip ? "zip" : gzip ? "csv.gz" : "csv"}`;
      const tudo = new Uint8Array(tamanho); let p = 0; for (const b of brutos) { tudo.set(b, p); p += b.length; }
      const up = await fetch(`${SB_URL}/storage/v1/object/btg/${caminho}`, {
        method: "POST",
        headers: { apikey: CHAVE, Authorization: "Bearer " + CHAVE, "Content-Type": zip ? "application/zip" : gzip ? "application/gzip" : "text/csv", "x-upsert": "true" },
        body: tudo,
      });
      if (!up.ok) { console.warn("btg-webhook: original não guardado", up.status); caminho = null; }
    }
    await rpc("btg_rent_receber", { p_arquivo_id: id, p_linhas: [], p_final: true, p_total: total,
      p_caminho: caminho ?? (grande ? "(original maior que 45 MB, não guardado)" : null), p_tamanho: tamanho, p_colunas: colunas });
    console.log("btg-webhook", servico, id, total, "linhas", tamanho, "bytes");
  } catch (e) {
    const msg = String((e as Error)?.message ?? e);
    console.error("btg-webhook", servico, id, msg);
    try { await rpc("btg_marcar_erro", { p_arquivo_id: id, p_erro: msg }); } catch (_) { /* melhor esforço */ }
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
  const tarefa = servico === "performance-report" ? processarPerformance(id, url, info)
    : RENTABILIDADE.has(servico) ? processarEmLotes(id, servico, url) : processar(id, servico, url);
  const er = (globalThis as { EdgeRuntime?: { waitUntil(p: Promise<unknown>): void } }).EdgeRuntime;
  if (er?.waitUntil) er.waitUntil(tarefa); else await tarefa;
  return resposta({ ok: true, id });
});
