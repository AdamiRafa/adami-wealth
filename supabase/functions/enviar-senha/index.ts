// Função "enviar-senha" do Supabase (Edge Functions).
//
// A tela "Esqueci minha senha" do portal chama esta função. Ela gera o link de troca de
// senha pelo próprio Supabase (generate_link, que NÃO manda e-mail nenhum) e envia o
// e-mail do Hub Adami pela caixa hub@adamicaptal.com.br da HostGator, o mesmo caminho do
// e-mail de boas-vindas. Antes o reset saía pelo SMTP configurado no painel do Supabase, que
// não deixa rastro de erro: quando o e-mail não chegava, ninguém sabia por quê. Aqui a
// resposta do servidor de e-mail volta para a tela e fica no registro (pedidos_senha).
//
// O link é ?token_hash=...&type=recovery, igual ao do modelo antigo: abre a tela de nova
// senha e o código só é gasto no clique em "Salvar nova senha" (o robô de segurança do
// Microsoft 365, que abre os links para conferir, não queima o código).
//
// Segurança:
//  - a resposta é a mesma exista ou não a conta, para ninguém descobrir quem tem acesso;
//  - no máximo 1 pedido por minuto e 5 por hora para o mesmo e-mail, e 40 por hora no total;
//  - usa a chave de serviço do Supabase, que só existe aqui dentro (variável de ambiente
//    SUPABASE_SERVICE_ROLE_KEY, preenchida pelo próprio Supabase). Ela nunca vai ao navegador.
//
// Configuração no Supabase (uma vez):
//   - Edge Functions > Secrets: SMTP_SENHA (a mesma da função enviar-convite)
//   - "Verify JWT" desligado nesta função: quem pede senha não está logado.
//   - Tabela pedidos_senha criada pelo agenda.sql.
//
// O modelo do e-mail é gerado por emails/_base.py (não editar à mão o bloco MODELO).
const SB_URL = Deno.env.get("SUPABASE_URL") ?? "https://ghxjqmjtmbqzvogwzylo.supabase.co";
const PORTAL = "https://adamicaptal.com.br/hub/";
const SMTP_HOST = Deno.env.get("SMTP_HOST") ?? "br542.hostgator.com.br";
const SMTP_PORTA = Number(Deno.env.get("SMTP_PORTA") ?? "465");
const SMTP_USUARIO = "hub@adamicaptal.com.br";
const REMETENTE_NOME = "Hub Adami";
const LIMITE_MINUTO = 1, LIMITE_HORA = 5, LIMITE_HORA_TOTAL = 40;

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
const MODELO = "<!doctype html>\n<html lang=\"pt-BR\">\n<head>\n<meta charset=\"utf-8\">\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n<meta name=\"color-scheme\" content=\"light\">\n<meta name=\"supported-color-schemes\" content=\"light\">\n<title>Redefinir sua senha</title>\n</head>\n<body style=\"margin:0;padding:0;background:#EDF0F4;-webkit-text-size-adjust:100%;\">\n<div style=\"display:none;max-height:0;overflow:hidden;opacity:0;color:#EDF0F4;\">Use o botão para criar uma nova senha no Hub Adami.</div>\n<table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\" border=\"0\" style=\"background:#EDF0F4;\">\n<tr><td align=\"center\" style=\"padding:32px 16px;\">\n  <table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\" border=\"0\" style=\"max-width:560px;background:#FFFFFF;border-radius:10px;overflow:hidden;border:1px solid #DCE2EA;\">\n    <tr><td align=\"center\" style=\"background:#1B3A5F;padding:28px 24px 26px;\">\n      <img src=\"https://adamicaptal.com.br/hub/img/logo-branco.png\" width=\"172\" height=\"40\" alt=\"Adami Captal\" style=\"display:block;border:0;width:172px;height:auto;\">\n      <div style=\"font-family:Helvetica, Arial, sans-serif;font-size:11px;letter-spacing:3px;text-transform:uppercase;color:#C0A265;padding-top:12px;\">Hub Adami</div>\n    </td></tr>\n    <tr><td style=\"height:3px;line-height:3px;font-size:0;background:#C0A265;\">&nbsp;</td></tr>\n    <tr><td style=\"padding:36px 40px 8px;\" class=\"miolo\">\n      <img src=\"https://adamicaptal.com.br/hub/img/icone-chave.png\" width=\"56\" height=\"56\" alt=\"\" style=\"display:block;border:0;width:56px;height:56px;\">\n      <h1 style=\"margin:20px 0 12px;font-family:Georgia, 'Times New Roman', serif;font-weight:normal;font-size:26px;line-height:1.25;color:#16324F;\">Redefinir sua senha</h1>\n      <p style=\"margin:0 0 14px;font-family:Helvetica, Arial, sans-serif;font-size:15px;line-height:1.6;color:#3C4C60;\">Recebemos um pedido para redefinir a senha do Hub Adami da conta <strong style=\"color:#16324F;\">{{EMAIL}}</strong>.</p><p style=\"margin:0 0 14px;font-family:Helvetica, Arial, sans-serif;font-size:15px;line-height:1.6;color:#3C4C60;\">Clique no botão abaixo e escolha a nova senha.</p>\n    </td></tr>\n    <tr><td style=\"padding:20px 40px 8px;\">\n      <table role=\"presentation\" cellpadding=\"0\" cellspacing=\"0\" border=\"0\"><tr>\n        <td align=\"center\" bgcolor=\"#1B3A5F\" style=\"border-radius:6px;\">\n          <a href=\"{{LINK}}\" target=\"_blank\" style=\"display:inline-block;padding:14px 28px;font-family:Helvetica, Arial, sans-serif;font-size:15px;font-weight:bold;color:#FFFFFF;text-decoration:none;border-radius:6px;\">Criar nova senha</a>\n        </td>\n      </tr></table>\n    </td></tr>\n    <tr><td style=\"padding:20px 40px 32px;font-family:Helvetica, Arial, sans-serif;font-size:13px;line-height:1.6;color:#3C4C60;\">\n      <p style=\"margin:0 0 10px;\">O link vale por tempo limitado e só pode ser usado uma vez. Se expirar, peça outro na tela de login, em <strong>Esqueci minha senha</strong>.</p><p style=\"margin:0;\">Não foi você? Pode ignorar este e-mail. A sua senha continua a mesma.</p>\n      <p style=\"margin:20px 0 0;padding-top:16px;border-top:1px solid #DCE2EA;font-size:12px;color:#7A8698;\">Se o botão não funcionar, copie e cole este endereço no navegador:<br>\n      <a href=\"{{LINK}}\" style=\"color:#1B3A5F;word-break:break-all;\">{{LINK}}</a></p>\n    </td></tr>\n  </table>\n  <table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\" border=\"0\" style=\"max-width:560px;\">\n    <tr><td align=\"center\" style=\"padding:20px 24px 0;font-family:Helvetica, Arial, sans-serif;font-size:12px;line-height:1.6;color:#7A8698;\">\n      <strong style=\"color:#3C4C60;\">Hub Adami</strong> &middot; Adami Captal<br>\n      <a href=\"https://adamicaptal.com.br/hub\" style=\"color:#7A8698;\">adamicaptal.com.br/hub</a><br>\n      E-mail automático, não precisa responder.\n    </td></tr>\n  </table>\n</td></tr>\n</table>\n</body>\n</html>\n";
const MODELO_TEXTO = "Recebemos um pedido para redefinir a senha do Hub Adami da conta {{EMAIL}}.\n\nAbra o link abaixo e escolha a nova senha:\n\n{{LINK}}\n\nO link vale por tempo limitado e só pode ser usado uma vez. Se expirar, peça outro na tela de login, em Esqueci minha senha.\nNão foi você? Pode ignorar este e-mail. A sua senha continua a mesma.\n\nHub Adami · Adami Captal\nE-mail automático, não precisa responder.\n";
// </modelo>

// ---------- banco, com a chave de serviço ----------
const CHAVE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
function cabecalhosServico(extra: Record<string, string> = {}): Record<string, string> {
  return { apikey: CHAVE, Authorization: "Bearer " + CHAVE, "Content-Type": "application/json", ...extra };
}
async function contarPedidos(email: string | null, desde: Date): Promise<number> {
  const filtro = (email ? "email=eq." + encodeURIComponent(email) + "&" : "") + "pedido_em=gte." + encodeURIComponent(desde.toISOString());
  const r = await fetch(`${SB_URL}/rest/v1/pedidos_senha?select=id&${filtro}`, {
    headers: cabecalhosServico({ Prefer: "count=exact", Range: "0-0" }),
  });
  if (!r.ok) throw new Error("pedidos_senha " + r.status + " " + (await r.text()).slice(0, 200));
  const total = (r.headers.get("Content-Range") ?? "").split("/")[1];
  return Number(total ?? "0") || 0;
}
async function registrarPedido(email: string): Promise<number | null> {
  const r = await fetch(`${SB_URL}/rest/v1/pedidos_senha?select=id`, {
    method: "POST",
    headers: cabecalhosServico({ Prefer: "return=representation" }),
    body: JSON.stringify({ email, resultado: "pedido" }),
  });
  if (!r.ok) return null;
  const linhas = await r.json();
  return Array.isArray(linhas) && linhas[0] ? linhas[0].id : null;
}
async function anotar(id: number | null, resultado: string): Promise<void> {
  if (id === null) return;
  try {
    await fetch(`${SB_URL}/rest/v1/pedidos_senha?id=eq.${id}`, {
      method: "PATCH", headers: cabecalhosServico(), body: JSON.stringify({ resultado: resultado.slice(0, 500) }),
    });
  } catch (_) { /* o registro é só para consulta */ }
}

const RESPOSTA_PADRAO = { ok: true };

Deno.serve(async (req: Request) => {
  definirCors(req);
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return resposta({ erro: "Use POST." }, 405);

  let email = "";
  try {
    const corpo = await req.json();
    email = String(corpo?.email ?? "").trim().toLowerCase();
  } catch (_) { /* corpo inválido cai na checagem abaixo */ }
  if (!/^[^\s<>@",;]+@[^\s<>@",;]+\.[^\s<>@",;]+$/.test(email) || email.length > 200) {
    return resposta({ erro: "Digite um e-mail válido." }, 400);
  }

  const senha = Deno.env.get("SMTP_SENHA");
  if (!CHAVE) return resposta({ erro: "A função não encontrou a chave de serviço do Supabase." }, 500);
  if (!senha) return resposta({ erro: "Falta cadastrar a senha do e-mail (SMTP_SENHA) no Supabase." }, 500);

  // Limites antes de qualquer outra coisa.
  try {
    const agora = Date.now();
    if (await contarPedidos(email, new Date(agora - 60_000)) >= LIMITE_MINUTO) {
      return resposta({ erro: "Já mandamos um e-mail há menos de um minuto. Espere um pouco antes de pedir outro." }, 429);
    }
    if (await contarPedidos(email, new Date(agora - 3_600_000)) >= LIMITE_HORA) {
      return resposta({ erro: "Muitos pedidos para este e-mail na última hora. Tente de novo mais tarde, ou peça a um master para trocar sua senha." }, 429);
    }
    if (await contarPedidos(null, new Date(agora - 3_600_000)) >= LIMITE_HORA_TOTAL) {
      return resposta({ erro: "Muitos pedidos de senha na última hora. Tente de novo mais tarde." }, 429);
    }
  } catch (e) {
    console.error("limite", e);
    return resposta({ erro: "Falta criar a tabela pedidos_senha (arquivo agenda.sql) no Supabase." }, 500);
  }
  const pedido = await registrarPedido(email);

  // O Supabase gera o código de troca de senha. Conta inexistente: mesma resposta de sucesso.
  let tokenHash = "";
  try {
    const r = await fetch(`${SB_URL}/auth/v1/admin/generate_link`, {
      method: "POST",
      headers: cabecalhosServico(),
      body: JSON.stringify({ type: "recovery", email, redirect_to: PORTAL }),
    });
    const j = await r.json().catch(() => ({}));
    if (!r.ok) {
      const motivo = String(j?.msg ?? j?.message ?? j?.error_description ?? r.status);
      await anotar(pedido, "sem link: " + motivo);
      if (r.status === 404 || r.status === 422 || /not found|no user/i.test(motivo)) return resposta(RESPOSTA_PADRAO);
      return resposta({ erro: "O Supabase não gerou o link (" + motivo + ")." }, 502);
    }
    tokenHash = String(j?.hashed_token ?? j?.properties?.hashed_token ?? "");
  } catch (e) {
    await anotar(pedido, "sem link: " + String((e as Error)?.message ?? e));
    return resposta({ erro: "Não foi possível falar com o Supabase." }, 502);
  }
  if (!tokenHash) {
    await anotar(pedido, "sem link: resposta sem hashed_token");
    return resposta({ erro: "O Supabase não devolveu o código do link." }, 502);
  }

  const link = PORTAL + "?token_hash=" + encodeURIComponent(tokenHash) + "&type=recovery";
  const html = MODELO.replaceAll("{{LINK}}", esc(link)).replaceAll("{{EMAIL}}", esc(email));
  const texto = MODELO_TEXTO.replaceAll("{{LINK}}", link).replaceAll("{{EMAIL}}", email);
  try {
    await enviarSmtp(email, "Redefinir sua senha do Hub Adami", html, texto, senha);
  } catch (e) {
    const motivo = String((e as Error)?.message ?? e);
    console.error("falha no envio", motivo);
    await anotar(pedido, "falha no envio: " + motivo);
    const dica = /autentica/i.test(motivo) ? " Confira a senha (SMTP_SENHA)." : "";
    return resposta({ erro: "O servidor de e-mail recusou o envio (" + motivo + ")." + dica }, 502);
  }
  await anotar(pedido, "enviado");
  return resposta(RESPOSTA_PADRAO);
});
