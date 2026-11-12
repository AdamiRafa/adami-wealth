// Função "relatorio-enviar" do Supabase (Edge Functions): manda o Relatório Consolidado ao cliente.
//
// A aba Relatório das Carteiras (index.html) gera o PDF do mês e chama esta função. O e-mail sai
// pela caixa hub@adamicaptal.com.br, em nome da Adami Captal, com resposta para o assessor.
//
// Segurança: quem decide é o banco, com a sessão de quem clicou. relatorio_envio_preparar só
// responde a quem enxerga o cliente (meu_cliente ou admin), só com o mês marcado como feito, e é
// de lá que vêm os destinatários (clientes.emails_relatorio). A tela não escolhe para quem vai:
// manda só o PDF, uma mensagem opcional e se quer cópia. O envio fica registrado
// (relatorio_envio_registrar).
//
// Configuração: Edge Functions > Secrets: SMTP_SENHA (a mesma do enviar-convite).
// "Verify JWT" desligado: a conferência é feita aqui dentro, pelo banco.
const SB_URL = Deno.env.get("SUPABASE_URL") ?? "https://ghxjqmjtmbqzvogwzylo.supabase.co";
const SB_KEY = "sb_publishable_-M5rRFdjNXtFr1td-NVWPQ_GGkd_liB"; // pública, a mesma do portal
const SMTP_HOST = Deno.env.get("SMTP_HOST") ?? "br542.hostgator.com.br";
const SMTP_PORTA = Number(Deno.env.get("SMTP_PORTA") ?? "465");
const SMTP_USUARIO = "hub@adamicaptal.com.br";
const REMETENTE_NOME = "Adami Captal";
const LIMITE_ANEXO = 9 * 1024 * 1024; // base64 (~6,7 MB de PDF)

const ORIGENS = ["https://adamicaptal.com.br", "https://www.adamicaptal.com.br"];
let CORS: Record<string, string> = {};
function definirCors(req: Request): void {
  const origem = req.headers.get("Origin") ?? "";
  CORS = {
    "Access-Control-Allow-Origin": ORIGENS.includes(origem) ? origem : ORIGENS[0],
    "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
}
function resposta(corpo: unknown, status = 200): Response {
  return new Response(JSON.stringify(corpo), { status, headers: { ...CORS, "Content-Type": "application/json; charset=utf-8" } });
}
function esc(s: string): string {
  return s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));
}

const enc = new TextEncoder();
const dec = new TextDecoder();
function b64(s: string): string {
  const bytes = enc.encode(s);
  let bin = "";
  for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(bin);
}
function linhas76(s: string): string { return (s.match(/.{1,76}/g) ?? []).join("\r\n"); }
function cabecalhoUtf8(s: string): string { return /^[\x20-\x7e]*$/.test(s) ? s : "=?UTF-8?B?" + b64(s) + "?="; }

function montarMensagem(para: string[], cc: string[], responder: string, assunto: string, html: string, texto: string, anexoNome: string, anexoB64: string): string {
  const id = crypto.randomUUID();
  const misto = "hubm_" + id.replace(/-/g, ""), alt = "huba_" + id.replace(/-/g, "");
  return [
    `From: ${cabecalhoUtf8(REMETENTE_NOME)} <${SMTP_USUARIO}>`,
    `To: ${para.map((x) => "<" + x + ">").join(", ")}`,
    ...(cc.length ? [`Cc: ${cc.map((x) => "<" + x + ">").join(", ")}`] : []),
    ...(responder ? [`Reply-To: <${responder}>`] : []),
    `Subject: ${cabecalhoUtf8(assunto)}`,
    `Date: ${new Date().toUTCString()}`,
    `Message-ID: <${id}@adamicaptal.com.br>`,
    "MIME-Version: 1.0",
    `Content-Type: multipart/mixed; boundary="${misto}"`,
    "",
    `--${misto}`,
    `Content-Type: multipart/alternative; boundary="${alt}"`,
    "",
    `--${alt}`,
    "Content-Type: text/plain; charset=UTF-8",
    "Content-Transfer-Encoding: base64",
    "",
    linhas76(b64(texto)),
    `--${alt}`,
    "Content-Type: text/html; charset=UTF-8",
    "Content-Transfer-Encoding: base64",
    "",
    linhas76(b64(html)),
    `--${alt}--`,
    `--${misto}`,
    `Content-Type: application/pdf; name="${cabecalhoUtf8(anexoNome)}"`,
    "Content-Transfer-Encoding: base64",
    `Content-Disposition: attachment; filename="${cabecalhoUtf8(anexoNome)}"`,
    "",
    linhas76(anexoB64),
    `--${misto}--`,
    "",
  ].join("\r\n");
}

async function enviarSmtp(para: string[], mensagem: string, senha: string): Promise<void> {
  const conn = await Deno.connectTls({ hostname: SMTP_HOST, port: SMTP_PORTA });
  const leitor = conn.readable.getReader();
  const escritor = conn.writable.getWriter();
  let buffer = "";
  const prazo = setTimeout(() => { try { conn.close(); } catch (_) { /* já fechada */ } }, 30000);
  async function ler(): Promise<{ codigo: number; texto: string }> {
    while (true) {
      const ls = buffer.split("\r\n");
      for (let i = 0; i < ls.length - 1; i++) {
        if (/^\d{3} /.test(ls[i])) {
          const texto = ls.slice(0, i + 1).join(" | ");
          buffer = ls.slice(i + 1).join("\r\n");
          return { codigo: parseInt(ls[i].slice(0, 3), 10), texto };
        }
      }
      const { value, done } = await leitor.read();
      if (done) throw new Error("o servidor de e-mail fechou a conexão");
      buffer += dec.decode(value, { stream: true });
    }
  }
  async function passo(comando: string | null, esperado: number[], rotulo: string): Promise<void> {
    if (comando !== null) await escritor.write(enc.encode(comando + "\r\n"));
    const r = await ler();
    if (!esperado.includes(r.codigo)) throw new Error(`${rotulo}: ${r.texto}`);
  }
  try {
    await passo(null, [220], "conexão");
    await passo("EHLO adamicaptal.com.br", [250], "EHLO");
    await passo("AUTH PLAIN " + b64("\0" + SMTP_USUARIO + "\0" + senha), [235], "autenticação");
    await passo(`MAIL FROM:<${SMTP_USUARIO}>`, [250], "remetente");
    for (const p of para) await passo(`RCPT TO:<${p}>`, [250, 251], "destinatário " + p);
    await passo("DATA", [354], "DATA");
    await passo(mensagem.replace(/\r\n\./g, "\r\n..") + "\r\n.", [250], "envio");
    try { await passo("QUIT", [221], "QUIT"); } catch (_) { /* a mensagem já foi aceita */ }
  } finally {
    clearTimeout(prazo);
    try { conn.close(); } catch (_) { /* já fechada */ }
  }
}

const MESES = ["janeiro", "fevereiro", "março", "abril", "maio", "junho", "julho", "agosto", "setembro", "outubro", "novembro", "dezembro"];
const emailOk = (s: string) => /^[^\s@<>,;"]+@[^\s@<>,;"]+\.[^\s@<>,;"]+$/.test(s);

async function rpc(nome: string, args: unknown, auth: string): Promise<{ ok: boolean; status: number; dados: unknown }> {
  const r = await fetch(`${SB_URL}/rest/v1/rpc/${nome}`, {
    method: "POST", headers: { apikey: SB_KEY, Authorization: auth, "Content-Type": "application/json" }, body: JSON.stringify(args),
  });
  const t = await r.text();
  let dados: unknown = null; try { dados = t ? JSON.parse(t) : null; } catch (_) { dados = t; }
  return { ok: r.ok, status: r.status, dados };
}

Deno.serve(async (req: Request) => {
  definirCors(req);
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return resposta({ erro: "Use POST." }, 405);
  const auth = req.headers.get("Authorization") ?? "";
  if (!/^Bearer\s+\S+/i.test(auth)) return resposta({ erro: "Entre no Hub de novo." }, 401);

  const corpo = await req.json().catch(() => null) as { cliente_id?: string; mes?: number; ano?: number; nome_arquivo?: string; arquivo_base64?: string; mensagem?: string; copia?: boolean } | null;
  const cid = String(corpo?.cliente_id ?? "");
  const mes = Number(corpo?.mes), ano = Number(corpo?.ano);
  const arquivo = String(corpo?.arquivo_base64 ?? "").replace(/\s/g, "");
  let nomeArq = String(corpo?.nome_arquivo ?? "Relatorio.pdf").replace(/[\\/:*?"<>|\r\n]/g, "-").slice(0, 140);
  if (!/\.pdf$/i.test(nomeArq)) nomeArq += ".pdf";
  const mensagem = String(corpo?.mensagem ?? "").replace(/\r/g, "").slice(0, 2000).trim();
  if (!/^[0-9a-f-]{36}$/i.test(cid) || !(mes >= 1 && mes <= 12) || !(ano >= 2000 && ano <= 2100)) return resposta({ erro: "Pedido inválido." }, 400);
  if (!arquivo || arquivo.length > LIMITE_ANEXO || !/^[A-Za-z0-9+/=]+$/.test(arquivo)) return resposta({ erro: "PDF inválido ou grande demais." }, 400);
  if (!arquivo.startsWith("JVBER")) return resposta({ erro: "O anexo não é um PDF." }, 400);

  const prep = await rpc("relatorio_envio_preparar", { p_cliente: cid, p_mes: mes, p_ano: ano }, auth);
  if (prep.status === 401) return resposta({ erro: "Sua sessão expirou. Entre novamente." }, 401);
  if (!prep.ok) return resposta({ erro: (prep.dados as { message?: string })?.message ?? "não foi possível conferir o envio" }, 403);
  const d = prep.dados as { cliente: string; para: string[]; assessor: string; assessor_email: string; eu_email: string; eu_nome: string };
  const para = (d.para ?? []).map((x) => String(x).trim()).filter(emailOk).slice(0, 5);
  if (!para.length) return resposta({ erro: "Cadastre um e-mail válido para relatórios deste cliente." }, 400);
  const responder = emailOk(d.assessor_email ?? "") ? d.assessor_email : (emailOk(d.eu_email ?? "") ? d.eu_email : "");
  const cc = corpo?.copia && emailOk(d.eu_email ?? "") && !para.includes(d.eu_email) ? [d.eu_email] : [];

  const senha = Deno.env.get("SMTP_SENHA");
  if (!senha) return resposta({ erro: "Falta cadastrar a senha do e-mail (SMTP_SENHA) no Supabase." }, 500);

  const ref = MESES[mes - 1] + " de " + ano;
  const assunto = `Relatório Consolidado de Investimentos · ${ref.charAt(0).toUpperCase() + ref.slice(1)}`;
  const quem = (d.assessor || d.eu_nome || "").trim();
  const msgHtml = mensagem ? esc(mensagem).replace(/\n/g, "<br>") : `Segue o seu Relatório Consolidado de Investimentos de <strong>${esc(ref)}</strong>.`;
  const html = `<!doctype html><html lang="pt-BR"><body style="margin:0;padding:0;background:#EDF0F4;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#EDF0F4;"><tr><td align="center" style="padding:32px 16px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:560px;background:#fff;border-radius:10px;border:1px solid #DCE2EA;">
<tr><td align="center" style="background:#1B3A5F;padding:24px;"><img src="https://adamicaptal.com.br/hub/img/logo-branco.png" width="160" alt="Adami Captal" style="display:block;border:0;width:160px;height:auto;"></td></tr>
<tr><td style="height:3px;background:#C0A265;font-size:0;line-height:3px;">&nbsp;</td></tr>
<tr><td style="padding:32px 36px;font-family:Helvetica,Arial,sans-serif;font-size:15px;line-height:1.6;color:#3C4C60;">
<p style="margin:0 0 14px;">Olá.</p>
<p style="margin:0 0 14px;">${msgHtml}</p>
<p style="margin:0 0 14px;">O relatório está em anexo, em PDF.${quem ? " Qualquer dúvida, é só responder este e-mail: ele chega a " + esc(quem) + "." : ""}</p>
<p style="margin:20px 0 0;padding-top:14px;border-top:1px solid #DCE2EA;font-size:12px;color:#7A8698;">Adami Captal · adamicaptal.com.br<br>Este e-mail e o anexo são de uso exclusivo do destinatário.</p>
</td></tr></table></td></tr></table></body></html>`;
  const texto = `Olá.\n\n${mensagem || "Segue o seu Relatório Consolidado de Investimentos de " + ref + "."}\n\nO relatório está em anexo, em PDF.` +
    (quem ? ` Qualquer dúvida, é só responder este e-mail: ele chega a ${quem}.` : "") + `\n\nAdami Captal · adamicaptal.com.br\n`;

  try {
    await enviarSmtp(para.concat(cc), montarMensagem(para, cc, responder, assunto, html, texto, nomeArq, arquivo), senha);
  } catch (e) {
    const motivo = String((e as Error)?.message ?? e).slice(0, 300);
    await rpc("relatorio_envio_registrar", { p_cliente: cid, p_mes: mes, p_ano: ano, p_para: para, p_erro: "não saiu: " + motivo }, auth).catch(() => null);
    return resposta({ erro: "O servidor de e-mail recusou (" + motivo + ")." }, 502);
  }
  await rpc("relatorio_envio_registrar", { p_cliente: cid, p_mes: mes, p_ano: ano, p_para: para.concat(cc), p_erro: null }, auth).catch(() => null);
  return resposta({ ok: true, para, cc });
});
