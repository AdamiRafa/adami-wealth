// Função "enviar-convite" do Supabase (Edge Functions).
//
// O portal chama esta função logo depois de criar um convite (Equipe > Convidar pessoa),
// e de novo no botão "reenviar e-mail". Ela manda o e-mail de boas-vindas do Hub Adami
// pelo e-mail da HostGator, com um link que abre a tela de "Primeiro acesso" já com o
// e-mail preenchido. Não cria conta nem gera link que expira: a conta só nasce quando a
// pessoa escolhe a senha, pelo fluxo de sempre.
//
// Segurança: quem decide se pode enviar é o banco. A função chama listar_convites com a
// sessão de quem pediu; essa função só devolve convites para master (eh_super). Se o
// e-mail não está na lista, nada é enviado. Nenhuma chave secreta do Supabase é usada.
//
// Configuração no Supabase (uma vez):
//   - Edge Functions > Secrets: SMTP_SENHA = senha da caixa hub@adamicaptal.com.br
//   - "Verify JWT" desligado nesta função: a conferência é feita aqui dentro, pelo banco.
//
// O modelo do e-mail é gerado por emails/_base.py (não editar à mão o bloco MODELO).
//
// O envio fala SMTP direto (porta 465, TLS desde o início), sem biblioteca: o nodemailer
// não conclui o TLS no runtime Deno das Edge Functions ("Greeting never received").
const SB_URL = Deno.env.get("SUPABASE_URL") ?? "https://ghxjqmjtmbqzvogwzylo.supabase.co";
const SB_KEY = "sb_publishable_-M5rRFdjNXtFr1td-NVWPQ_GGkd_liB"; // pública, a mesma do portal
const PORTAL = "https://adamicaptal.com.br/hub/";
const SMTP_HOST = Deno.env.get("SMTP_HOST") ?? "br542.hostgator.com.br";
const SMTP_PORTA = Number(Deno.env.get("SMTP_PORTA") ?? "465");
const SMTP_USUARIO = "hub@adamicaptal.com.br";
const REMETENTE_NOME = "Hub Adami";

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
  return new Response(JSON.stringify(corpo), {
    status,
    headers: { ...CORS, "Content-Type": "application/json; charset=utf-8" },
  });
}

function esc(s: string): string {
  return s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));
}

// ---------- envio SMTP ----------
const enc = new TextEncoder();
const dec = new TextDecoder();

function b64(s: string): string {
  const bytes = enc.encode(s);
  let bin = "";
  for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(bin);
}
function b64Linhas(s: string): string {
  return (b64(s).match(/.{1,76}/g) ?? []).join("\r\n");
}
function cabecalhoUtf8(s: string): string {
  return /^[\x20-\x7e]*$/.test(s) ? s : "=?UTF-8?B?" + b64(s) + "?=";
}

function montarMensagem(para: string, assunto: string, html: string, texto: string): string {
  const id = crypto.randomUUID();
  const limite = "hub_" + id.replace(/-/g, "");
  return [
    `From: ${cabecalhoUtf8(REMETENTE_NOME)} <${SMTP_USUARIO}>`,
    `To: <${para}>`,
    `Subject: ${cabecalhoUtf8(assunto)}`,
    `Date: ${new Date().toUTCString()}`,
    `Message-ID: <${id}@adamicaptal.com.br>`,
    "MIME-Version: 1.0",
    `Content-Type: multipart/alternative; boundary="${limite}"`,
    "",
    `--${limite}`,
    "Content-Type: text/plain; charset=UTF-8",
    "Content-Transfer-Encoding: base64",
    "",
    b64Linhas(texto),
    `--${limite}`,
    "Content-Type: text/html; charset=UTF-8",
    "Content-Transfer-Encoding: base64",
    "",
    b64Linhas(html),
    `--${limite}--`,
    "",
  ].join("\r\n");
}

async function enviarSmtp(para: string, assunto: string, html: string, texto: string, senha: string): Promise<void> {
  const conn = await Deno.connectTls({ hostname: SMTP_HOST, port: SMTP_PORTA });
  const leitor = conn.readable.getReader();
  const escritor = conn.writable.getWriter();
  let buffer = "";
  const prazo = setTimeout(() => { try { conn.close(); } catch (_) { /* já fechada */ } }, 25000);

  async function ler(): Promise<{ codigo: number; texto: string }> {
    while (true) {
      const linhas = buffer.split("\r\n");
      for (let i = 0; i < linhas.length - 1; i++) {
        if (/^\d{3} /.test(linhas[i])) {
          const texto = linhas.slice(0, i + 1).join(" | ");
          buffer = linhas.slice(i + 1).join("\r\n");
          return { codigo: parseInt(linhas[i].slice(0, 3), 10), texto };
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
    await passo(`RCPT TO:<${para}>`, [250, 251], "destinatário");
    await passo("DATA", [354], "DATA");
    const corpo = montarMensagem(para, assunto, html, texto).replace(/\r\n\./g, "\r\n..");
    await passo(corpo + "\r\n.", [250], "envio");
    try { await passo("QUIT", [221], "QUIT"); } catch (_) { /* a mensagem já foi aceita */ }
  } finally {
    clearTimeout(prazo);
    try { conn.close(); } catch (_) { /* já fechada */ }
  }
}

// <modelo> gerado por emails/_base.py
const MODELO = "<!doctype html>\n<html lang=\"pt-BR\">\n<head>\n<meta charset=\"utf-8\">\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n<meta name=\"color-scheme\" content=\"light\">\n<meta name=\"supported-color-schemes\" content=\"light\">\n<title>Bem-vindo ao Hub Adami</title>\n</head>\n<body style=\"margin:0;padding:0;background:#EDF0F4;-webkit-text-size-adjust:100%;\">\n<div style=\"display:none;max-height:0;overflow:hidden;opacity:0;color:#EDF0F4;\">Seu acesso ao Hub Adami está liberado. Crie sua senha para entrar.</div>\n<table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\" border=\"0\" style=\"background:#EDF0F4;\">\n<tr><td align=\"center\" style=\"padding:32px 16px;\">\n  <table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\" border=\"0\" style=\"max-width:560px;background:#FFFFFF;border-radius:10px;overflow:hidden;border:1px solid #DCE2EA;\">\n    <tr><td align=\"center\" style=\"background:#1B3A5F;padding:28px 24px 26px;\">\n      <img src=\"https://adamicaptal.com.br/hub/img/logo-branco.png\" width=\"172\" height=\"40\" alt=\"Adami Captal\" style=\"display:block;border:0;width:172px;height:auto;\">\n      <div style=\"font-family:Helvetica, Arial, sans-serif;font-size:11px;letter-spacing:3px;text-transform:uppercase;color:#C0A265;padding-top:12px;\">Hub Adami</div>\n    </td></tr>\n    <tr><td style=\"height:3px;line-height:3px;font-size:0;background:#C0A265;\">&nbsp;</td></tr>\n    <tr><td style=\"padding:36px 40px 8px;\" class=\"miolo\">\n      <img src=\"https://adamicaptal.com.br/hub/img/icone-entrada.png\" width=\"56\" height=\"56\" alt=\"\" style=\"display:block;border:0;width:56px;height:56px;\">\n      <h1 style=\"margin:20px 0 12px;font-family:Georgia, 'Times New Roman', serif;font-weight:normal;font-size:26px;line-height:1.25;color:#16324F;\">Bem-vindo ao Hub Adami</h1>\n      <p style=\"margin:0 0 14px;font-family:Helvetica, Arial, sans-serif;font-size:15px;line-height:1.6;color:#3C4C60;\">{{SAUDACAO}}</p><p style=\"margin:0 0 14px;font-family:Helvetica, Arial, sans-serif;font-size:15px;line-height:1.6;color:#3C4C60;\">Seu acesso ao <strong style=\"color:#16324F;\">Hub Adami</strong> está liberado. É o ambiente interno da Adami Captal, com carteiras, CRM, Mesa RV e as ferramentas da casa em um só lugar.</p><p style=\"margin:0 0 14px;font-family:Helvetica, Arial, sans-serif;font-size:15px;line-height:1.6;color:#3C4C60;\">Para entrar pela primeira vez, clique no botão abaixo e escolha a sua senha. O seu login é <strong style=\"color:#16324F;\">{{EMAIL}}</strong>.</p>\n    </td></tr>\n    <tr><td style=\"padding:20px 40px 8px;\">\n      <table role=\"presentation\" cellpadding=\"0\" cellspacing=\"0\" border=\"0\"><tr>\n        <td align=\"center\" bgcolor=\"#1B3A5F\" style=\"border-radius:6px;\">\n          <a href=\"{{LINK}}\" target=\"_blank\" style=\"display:inline-block;padding:14px 28px;font-family:Helvetica, Arial, sans-serif;font-size:15px;font-weight:bold;color:#FFFFFF;text-decoration:none;border-radius:6px;\">Criar minha senha</a>\n        </td>\n      </tr></table>\n    </td></tr>\n    <tr><td style=\"padding:20px 40px 32px;font-family:Helvetica, Arial, sans-serif;font-size:13px;line-height:1.6;color:#3C4C60;\">\n      <p style=\"margin:0 0 10px;\">Depois disso, é só entrar em <strong>adamicaptal.com.br/hub</strong> com o seu e-mail e a senha que escolheu. Vale salvar nos favoritos.</p><p style=\"margin:0;\">Este link não expira. Se você já criou a senha, use <strong>Entrar</strong> na mesma tela.</p>\n      <p style=\"margin:20px 0 0;padding-top:16px;border-top:1px solid #DCE2EA;font-size:12px;color:#7A8698;\">Se o botão não funcionar, copie e cole este endereço no navegador:<br>\n      <a href=\"{{LINK}}\" style=\"color:#1B3A5F;word-break:break-all;\">{{LINK}}</a></p>\n    </td></tr>\n  </table>\n  <table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\" border=\"0\" style=\"max-width:560px;\">\n    <tr><td align=\"center\" style=\"padding:20px 24px 0;font-family:Helvetica, Arial, sans-serif;font-size:12px;line-height:1.6;color:#7A8698;\">\n      <strong style=\"color:#3C4C60;\">Hub Adami</strong> &middot; Adami Captal<br>\n      <a href=\"https://adamicaptal.com.br/hub\" style=\"color:#7A8698;\">adamicaptal.com.br/hub</a><br>\n      E-mail automático, não precisa responder.\n    </td></tr>\n  </table>\n</td></tr>\n</table>\n</body>\n</html>\n";
const MODELO_TEXTO = "{{SAUDACAO}}\n\nSeu acesso ao Hub Adami está liberado. É o ambiente interno da Adami Captal, com carteiras, CRM, Mesa RV e as ferramentas da casa em um só lugar.\n\nPara entrar pela primeira vez, abra o link abaixo e escolha a sua senha. O seu login é {{EMAIL}}.\n\n{{LINK}}\n\nDepois disso, é só entrar em adamicaptal.com.br/hub com o seu e-mail e a senha que escolheu. Este link não expira.\n\nHub Adami · Adami Captal\nE-mail automático, não precisa responder.\n";
// </modelo>

Deno.serve(async (req: Request) => {
  definirCors(req);
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return resposta({ erro: "Use POST." }, 405);

  const auth = req.headers.get("Authorization") ?? "";
  if (!/^Bearer\s+\S+/i.test(auth)) return resposta({ erro: "Entre no portal de novo." }, 401);

  let email = "";
  try {
    const corpo = await req.json();
    email = String(corpo?.email ?? "").trim().toLowerCase();
  } catch (_) { /* corpo inválido cai na checagem abaixo */ }
  if (!/^[^\s<>@",;]+@[^\s<>@",;]+\.[^\s<>@",;]+$/.test(email)) return resposta({ erro: "E-mail inválido." }, 400);

  // O banco decide: listar_convites só devolve convites pendentes para quem é master.
  let convites: Array<{ email?: string; nome?: string }>;
  try {
    const r = await fetch(`${SB_URL}/rest/v1/rpc/listar_convites`, {
      method: "POST",
      headers: { apikey: SB_KEY, Authorization: auth, "Content-Type": "application/json" },
      body: "{}",
    });
    if (r.status === 401) return resposta({ erro: "Sua sessão expirou. Entre novamente." }, 401);
    if (!r.ok) return resposta({ erro: "Não foi possível conferir o convite (" + r.status + ")." }, 502);
    convites = await r.json();
  } catch (_) {
    return resposta({ erro: "Não foi possível conferir o convite." }, 502);
  }
  const cv = Array.isArray(convites) ? convites.find((c) => (c.email ?? "").toLowerCase() === email) : undefined;
  if (!cv) return resposta({ erro: "Não há convite pendente para esse e-mail, ou você não é master." }, 403);

  const senha = Deno.env.get("SMTP_SENHA");
  if (!senha) return resposta({ erro: "Falta cadastrar a senha do e-mail (SMTP_SENHA) no Supabase." }, 500);

  const link = PORTAL + "?primeiro=" + encodeURIComponent(email);
  const nome = String(cv.nome ?? "").trim().split(/\s+/)[0] || "";
  const saudacao = nome ? "Olá, " + nome + "." : "Olá.";
  const html = MODELO.replaceAll("{{LINK}}", esc(link)).replaceAll("{{EMAIL}}", esc(email)).replaceAll("{{SAUDACAO}}", esc(saudacao));
  const texto = MODELO_TEXTO.replaceAll("{{LINK}}", link).replaceAll("{{EMAIL}}", email).replaceAll("{{SAUDACAO}}", saudacao);

  try {
    await enviarSmtp(email, "Bem-vindo ao Hub Adami", html, texto, senha);
  } catch (e) {
    console.error("falha no envio", e);
    const motivo = String((e as Error)?.message ?? e);
    const dica = /autentica/i.test(motivo) ? " Confira a senha (SMTP_SENHA)." : "";
    return resposta({ erro: "O servidor de e-mail recusou o envio (" + motivo + ")." + dica }, 502);
  }
  return resposta({ ok: true });
});
