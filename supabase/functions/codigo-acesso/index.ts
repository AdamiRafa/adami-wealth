// Função "codigo-acesso" do Supabase (Edge Functions).
//
// Verificação em duas etapas por e-mail (desde 06/11/2026). Depois da senha, o Hub chama esta
// função com o token de quem acabou de entrar. Ela confere o token no próprio Supabase, pede
// ao banco um código de 6 dígitos para AQUELA sessão (função acesso_novo_codigo, que só a
// chave de serviço chama e que aplica os limites: 1 código a cada 30 s, 8 por hora, bloqueio
// depois de 10 erros) e manda o código pela caixa hub@adamicaptal.com.br.
//
// Quem confere o código digitado é o banco (verificar_codigo), não esta função. O código
// nunca volta para o navegador: só pelo e-mail.
//
// Configuração no Supabase (uma vez):
//   - Edge Functions > Secrets: SMTP_SENHA (a mesma das outras funções)
//   - "Verify JWT" desligado nesta função (a conferência do token é feita aqui dentro, e o
//     navegador precisa da resposta ao "OPTIONS" sem token).
//   - seguranca.sql rodado no SQL Editor.
//
// O modelo do e-mail é gerado por emails/_base.py (não editar à mão o bloco MODELO).
const SB_URL = Deno.env.get("SUPABASE_URL") ?? "https://ghxjqmjtmbqzvogwzylo.supabase.co";
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
const MODELO = "<!doctype html>\n<html lang=\"pt-BR\">\n<head>\n<meta charset=\"utf-8\">\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n<meta name=\"color-scheme\" content=\"light\">\n<meta name=\"supported-color-schemes\" content=\"light\">\n<title>Seu código de acesso</title>\n</head>\n<body style=\"margin:0;padding:0;background:#EDF0F4;-webkit-text-size-adjust:100%;\">\n<div style=\"display:none;max-height:0;overflow:hidden;opacity:0;color:#EDF0F4;\">Seu código de acesso ao Hub Adami. Vale por 10 minutos.</div>\n<table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\" border=\"0\" style=\"background:#EDF0F4;\">\n<tr><td align=\"center\" style=\"padding:32px 16px;\">\n  <table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\" border=\"0\" style=\"max-width:560px;background:#FFFFFF;border-radius:10px;overflow:hidden;border:1px solid #DCE2EA;\">\n    <tr><td align=\"center\" style=\"background:#1B3A5F;padding:28px 24px 26px;\">\n      <img src=\"https://adamicaptal.com.br/hub/img/logo-branco.png\" width=\"172\" height=\"40\" alt=\"Adami Captal\" style=\"display:block;border:0;width:172px;height:auto;\">\n      <div style=\"font-family:Helvetica, Arial, sans-serif;font-size:11px;letter-spacing:3px;text-transform:uppercase;color:#C0A265;padding-top:12px;\">Hub Adami</div>\n    </td></tr>\n    <tr><td style=\"height:3px;line-height:3px;font-size:0;background:#C0A265;\">&nbsp;</td></tr>\n    <tr><td style=\"padding:36px 40px 8px;\" class=\"miolo\">\n      <img src=\"https://adamicaptal.com.br/hub/img/icone-chave.png\" width=\"56\" height=\"56\" alt=\"\" style=\"display:block;border:0;width:56px;height:56px;\">\n      <h1 style=\"margin:20px 0 12px;font-family:Georgia, 'Times New Roman', serif;font-weight:normal;font-size:26px;line-height:1.25;color:#16324F;\">Seu código de acesso</h1>\n      <p style=\"margin:0 0 14px;font-family:Helvetica, Arial, sans-serif;font-size:15px;line-height:1.6;color:#3C4C60;\">Use o código abaixo para entrar no Hub Adami. Ele vale por <strong style=\"color:#16324F;\">10 minutos</strong> e só funciona uma vez.</p><div style=\"margin:22px 0 8px;padding:18px 0;text-align:center;background:#EDF0F4;border:1px solid #DCE2EA;border-radius:8px;font-family:Helvetica, Arial, sans-serif;font-size:34px;font-weight:bold;letter-spacing:10px;color:#16324F;\">{{CODIGO}}</div>\n    </td></tr>\n\n    <tr><td style=\"padding:20px 40px 32px;font-family:Helvetica, Arial, sans-serif;font-size:13px;line-height:1.6;color:#3C4C60;\">\n      <p style=\"margin:0 0 10px;\">Pedido feito em {{QUANDO}} (horário de Brasília), de {{ORIGEM}}.</p><p style=\"margin:0;\"><strong>Não foi você?</strong> Alguém está tentando entrar com a sua senha. Troque a senha agora, na tela de login, em <strong>Esqueci minha senha</strong>, e avise um master. Nunca passe este código para ninguém: a Adami nunca vai pedir.</p>\n\n    </td></tr>\n  </table>\n  <table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\" border=\"0\" style=\"max-width:560px;\">\n    <tr><td align=\"center\" style=\"padding:20px 24px 0;font-family:Helvetica, Arial, sans-serif;font-size:12px;line-height:1.6;color:#7A8698;\">\n      <strong style=\"color:#3C4C60;\">Hub Adami</strong> &middot; Adami Captal<br>\n      <a href=\"https://adamicaptal.com.br/hub\" style=\"color:#7A8698;\">adamicaptal.com.br/hub</a><br>\n      E-mail automático, não precisa responder.\n    </td></tr>\n  </table>\n</td></tr>\n</table>\n</body>\n</html>\n";
const MODELO_TEXTO = "Seu código de acesso ao Hub Adami:\n\n{{CODIGO}}\n\nEle vale por 10 minutos e só funciona uma vez.\nPedido feito em {{QUANDO}} (horário de Brasília), de {{ORIGEM}}.\n\nNão foi você? Alguém está tentando entrar com a sua senha. Troque a senha agora, na tela de login, em Esqueci minha senha, e avise um master. Nunca passe este código para ninguém: a Adami nunca vai pedir.\n\nHub Adami · Adami Captal\nE-mail automático, não precisa responder.\n";
// </modelo>

const CHAVE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const CHAVE_PUBLICA = Deno.env.get("SUPABASE_ANON_KEY") ?? "";

// Lê o miolo do token sem conferir a assinatura. Só é usado DEPOIS que o próprio Supabase
// aceitou o token em /auth/v1/user (é lá que a assinatura e a sessão são conferidas).
function miolo(token: string): Record<string, unknown> {
  try {
    const p = token.split(".")[1].replace(/-/g, "+").replace(/_/g, "/");
    const bin = atob(p + "=".repeat((4 - (p.length % 4)) % 4));
    return JSON.parse(new TextDecoder().decode(Uint8Array.from(bin, (c) => c.charCodeAt(0))));
  } catch (_) {
    return {};
  }
}

// "Chrome no Mac", "Safari no iPhone"... só para a pessoa reconhecer o pedido no e-mail.
function aparelho(ua: string): string {
  const nav = /Edg\//.test(ua) ? "Edge" : /OPR\//.test(ua) ? "Opera" : /Firefox\//.test(ua) ? "Firefox"
    : /Chrome\//.test(ua) ? "Chrome" : /Safari\//.test(ua) ? "Safari" : "navegador";
  const so = /iPhone/.test(ua) ? "iPhone" : /iPad/.test(ua) ? "iPad" : /Android/.test(ua) ? "Android"
    : /Mac OS X|Macintosh/.test(ua) ? "Mac" : /Windows/.test(ua) ? "Windows" : /Linux/.test(ua) ? "Linux" : "";
  return so ? nav + " no " + so : nav;
}
function quandoBrasilia(): string {
  return new Intl.DateTimeFormat("pt-BR", {
    timeZone: "America/Sao_Paulo", day: "2-digit", month: "2-digit", year: "numeric", hour: "2-digit", minute: "2-digit",
  }).format(new Date()).replace(",", " às");
}
function mascarar(email: string): string {
  const [u, d] = email.split("@");
  if (!d) return email;
  return (u.length <= 2 ? u[0] + "*" : u.slice(0, 2) + "*".repeat(Math.min(6, u.length - 2))) + "@" + d;
}

Deno.serve(async (req: Request) => {
  definirCors(req);
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return resposta({ erro: "Use POST." }, 405);

  const senha = Deno.env.get("SMTP_SENHA");
  if (!CHAVE) return resposta({ erro: "A função não encontrou a chave de serviço do Supabase." }, 500);
  if (!senha) return resposta({ erro: "Falta cadastrar a senha do e-mail (SMTP_SENHA) no Supabase." }, 500);

  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
  if (!token || token.split(".").length !== 3) return resposta({ erro: "Entre de novo com e-mail e senha." }, 401);

  // 1. O Supabase confere o token (assinatura, validade e se a sessão ainda existe).
  let usuario: { id?: string; email?: string } = {};
  try {
    const r = await fetch(`${SB_URL}/auth/v1/user`, {
      headers: { apikey: CHAVE_PUBLICA || CHAVE, Authorization: "Bearer " + token },
    });
    if (!r.ok) return resposta({ erro: "Sua sessão expirou. Entre de novo com e-mail e senha." }, 401);
    usuario = await r.json();
  } catch (_) {
    return resposta({ erro: "Não foi possível falar com o Supabase." }, 502);
  }
  const sessao = String(miolo(token).session_id ?? "");
  const email = String(usuario.email ?? "").toLowerCase();
  if (!usuario.id || !email || !/^[0-9a-f-]{36}$/i.test(sessao)) {
    return resposta({ erro: "Sessão inválida. Entre de novo com e-mail e senha." }, 401);
  }

  // 2. O banco gera o código e aplica os limites.
  const ip = (req.headers.get("x-forwarded-for") ?? "").split(",")[0].trim().slice(0, 100);
  const ua = (req.headers.get("user-agent") ?? "").slice(0, 300);
  let codigo = "";
  try {
    const r = await fetch(`${SB_URL}/rest/v1/rpc/acesso_novo_codigo`, {
      method: "POST",
      headers: { apikey: CHAVE, Authorization: "Bearer " + CHAVE, "Content-Type": "application/json" },
      body: JSON.stringify({ p_user: usuario.id, p_sessao: sessao, p_ip: ip, p_navegador: ua }),
    });
    const j = await r.json().catch(() => null);
    if (!r.ok) {
      const msg = String(j?.message ?? "");
      if (r.status === 404 || /could not find the function|does not exist/i.test(msg)) {
        return resposta({ erro: "Falta rodar o seguranca.sql no Supabase." }, 500);
      }
      return resposta({ erro: msg || "O banco recusou o pedido de código." }, 429);
    }
    codigo = String(j ?? "");
  } catch (_) {
    return resposta({ erro: "Não foi possível falar com o banco." }, 502);
  }
  if (!/^\d{6}$/.test(codigo)) return resposta({ erro: "O banco não gerou o código." }, 502);

  // 3. E-mail.
  const quando = quandoBrasilia();
  const origem = aparelho(ua);
  const trocar = (m: string, html: boolean) => m.replaceAll("{{CODIGO}}", codigo)
    .replaceAll("{{QUANDO}}", html ? esc(quando) : quando)
    .replaceAll("{{ORIGEM}}", html ? esc(origem) : origem);
  try {
    await enviarSmtp(email, codigo + " é o seu código de acesso ao Hub Adami", trocar(MODELO, true), trocar(MODELO_TEXTO, false), senha);
  } catch (e) {
    const motivo = String((e as Error)?.message ?? e);
    console.error("falha no envio", motivo);
    return resposta({ erro: "O servidor de e-mail recusou o envio (" + motivo + "). Tente de novo em um minuto." }, 502);
  }
  return resposta({ ok: true, email: mascarar(email) });
});
