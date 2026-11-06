// Função "agenda-manha" do Supabase (Edge Functions).
//
// O e-mail da manhã da Agenda do CRM. Quem chama é o próprio banco, pelo agendamento
// "agenda-manha" criado no agenda.sql (pg_cron, dias úteis às 6h50 de Brasília). Para cada
// pessoa ativa no CRM, junta o que está atrasado e o que é de hoje, com uma prévia de
// amanhã, e manda pela caixa hub@adamicaptal.com.br. Quem não tem nada no dia não recebe.
//
// O que entra (o mesmo que a aba Agenda mostra para a própria pessoa):
//  - tarefas da tabela `tarefas` marcadas "Incluir no e-mail da manhã";
//  - próximo contato marcado na ficha, vencimento (alerta aberto) e régua de relacionamento.
//
// Segurança: chamar esta função não dá acesso a nada. A resposta só traz contagens (o
// detalhe por pessoa vai para os Logs da função). Ela não recebe parâmetro, só envia
// entre 6h e 11h de Brasília em dia útil, e no máximo um e-mail por pessoa por dia (tabela
// agenda_emails). A chave de serviço do Supabase (SUPABASE_SERVICE_ROLE_KEY) é preenchida
// pelo próprio Supabase e só existe aqui dentro.
//
// Configuração no Supabase (uma vez):
//   - Edge Functions > Secrets: SMTP_SENHA (a mesma da função enviar-convite)
//   - "Verify JWT" desligado nesta função: quem chama é o agendamento do banco.
//
// As regras de régua e de recorrência espelham o crm.html (reguaStatus, tarefaCaiEm,
// agendaAtrasadas). Mudou lá, muda aqui.
// O modelo do e-mail é gerado por emails/_base.py (não editar à mão o bloco MODELO).
const SB_URL = Deno.env.get("SUPABASE_URL") ?? "https://ghxjqmjtmbqzvogwzylo.supabase.co";
const PORTAL = "https://adamicaptal.com.br/hub/";
const LINK_AGENDA = PORTAL + "crm.html#agenda";
const SMTP_HOST = Deno.env.get("SMTP_HOST") ?? "br542.hostgator.com.br";
const SMTP_PORTA = Number(Deno.env.get("SMTP_PORTA") ?? "465");
const SMTP_USUARIO = "hub@adamicaptal.com.br";
const REMETENTE_NOME = "Hub Adami";
const FUSO = "America/Sao_Paulo";
const MAX_POR_SECAO = 15;
const JANELA_ATRASO = 31;

function resposta(corpo: unknown, status = 200): Response {
  return new Response(JSON.stringify(corpo), { status, headers: { "Content-Type": "application/json; charset=utf-8" } });
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
const MODELO = "<!doctype html>\n<html lang=\"pt-BR\">\n<head>\n<meta charset=\"utf-8\">\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n<meta name=\"color-scheme\" content=\"light\">\n<meta name=\"supported-color-schemes\" content=\"light\">\n<title>Sua agenda de hoje</title>\n</head>\n<body style=\"margin:0;padding:0;background:#EDF0F4;-webkit-text-size-adjust:100%;\">\n<div style=\"display:none;max-height:0;overflow:hidden;opacity:0;color:#EDF0F4;\">Suas tarefas de hoje e as atrasadas, da Agenda do CRM.</div>\n<table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\" border=\"0\" style=\"background:#EDF0F4;\">\n<tr><td align=\"center\" style=\"padding:32px 16px;\">\n  <table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\" border=\"0\" style=\"max-width:560px;background:#FFFFFF;border-radius:10px;overflow:hidden;border:1px solid #DCE2EA;\">\n    <tr><td align=\"center\" style=\"background:#1B3A5F;padding:28px 24px 26px;\">\n      <img src=\"https://adamicaptal.com.br/hub/img/logo-branco.png\" width=\"172\" height=\"40\" alt=\"Adami Captal\" style=\"display:block;border:0;width:172px;height:auto;\">\n      <div style=\"font-family:Helvetica, Arial, sans-serif;font-size:11px;letter-spacing:3px;text-transform:uppercase;color:#C0A265;padding-top:12px;\">Hub Adami</div>\n    </td></tr>\n    <tr><td style=\"height:3px;line-height:3px;font-size:0;background:#C0A265;\">&nbsp;</td></tr>\n    <tr><td style=\"padding:36px 40px 8px;\" class=\"miolo\">\n      <img src=\"https://adamicaptal.com.br/hub/img/icone-agenda.png\" width=\"56\" height=\"56\" alt=\"\" style=\"display:block;border:0;width:56px;height:56px;\">\n      <h1 style=\"margin:20px 0 12px;font-family:Georgia, 'Times New Roman', serif;font-weight:normal;font-size:26px;line-height:1.25;color:#16324F;\">{{SAUDACAO}}</h1>\n      {{CONTEUDO}}\n    </td></tr>\n    <tr><td style=\"padding:20px 40px 8px;\">\n      <table role=\"presentation\" cellpadding=\"0\" cellspacing=\"0\" border=\"0\"><tr>\n        <td align=\"center\" bgcolor=\"#1B3A5F\" style=\"border-radius:6px;\">\n          <a href=\"{{LINK}}\" target=\"_blank\" style=\"display:inline-block;padding:14px 28px;font-family:Helvetica, Arial, sans-serif;font-size:15px;font-weight:bold;color:#FFFFFF;text-decoration:none;border-radius:6px;\">Abrir a Agenda</a>\n        </td>\n      </tr></table>\n    </td></tr>\n    <tr><td style=\"padding:20px 40px 32px;font-family:Helvetica, Arial, sans-serif;font-size:13px;line-height:1.6;color:#3C4C60;\">\n      <p style=\"margin:0;\">Este resumo sai nos dias úteis, por volta das 7h. Para tirar uma tarefa daqui, desmarque \"Incluir no e-mail da manhã\" nela, na Agenda do CRM.</p>\n      <p style=\"margin:20px 0 0;padding-top:16px;border-top:1px solid #DCE2EA;font-size:12px;color:#7A8698;\">Se o botão não funcionar, copie e cole este endereço no navegador:<br>\n      <a href=\"{{LINK}}\" style=\"color:#1B3A5F;word-break:break-all;\">{{LINK}}</a></p>\n    </td></tr>\n  </table>\n  <table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\" border=\"0\" style=\"max-width:560px;\">\n    <tr><td align=\"center\" style=\"padding:20px 24px 0;font-family:Helvetica, Arial, sans-serif;font-size:12px;line-height:1.6;color:#7A8698;\">\n      <strong style=\"color:#3C4C60;\">Hub Adami</strong> &middot; Adami Captal<br>\n      <a href=\"https://adamicaptal.com.br/hub\" style=\"color:#7A8698;\">adamicaptal.com.br/hub</a><br>\n      E-mail automático, não precisa responder.\n    </td></tr>\n  </table>\n</td></tr>\n</table>\n</body>\n</html>\n";
const MODELO_TEXTO = "{{SAUDACAO}}\n\n{{CONTEUDO}}\n\nAbrir a Agenda: {{LINK}}\n\nEste resumo sai nos dias úteis, por volta das 7h.\nHub Adami · Adami Captal\n";
// </modelo>

// ---------- datas (sempre no horário de Brasília) ----------
const DIA_MS = 86400000;
function agoraEmBrasilia(): { iso: string; hora: number; diaSemana: number } {
  const partes = new Intl.DateTimeFormat("en-CA", {
    timeZone: FUSO, year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", hour12: false, weekday: "short",
  }).formatToParts(new Date());
  const p = (t: string) => partes.find((x) => x.type === t)?.value ?? "";
  const semana = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"].indexOf(p("weekday")) + 1;
  return { iso: `${p("year")}-${p("month")}-${p("day")}`, hora: Number(p("hour")) % 24, diaSemana: semana };
}
const data = (iso: string) => new Date(iso + "T12:00:00Z");
const isoDe = (d: Date) => d.toISOString().slice(0, 10);
const soma = (iso: string, n: number) => isoDe(new Date(data(iso).getTime() + n * DIA_MS));
const diaSemana = (iso: string) => { const g = data(iso).getUTCDay(); return g === 0 ? 7 : g; };
const DIAS = ["seg", "ter", "qua", "qui", "sex", "sáb", "dom"];
const curta = (iso: string) => DIAS[diaSemana(iso) - 1] + ", " + iso.slice(8, 10) + "/" + iso.slice(5, 7);
function isoBrasiliaDeTimestamp(ts: string | null): string | null {
  if (!ts) return null;
  return new Intl.DateTimeFormat("en-CA", { timeZone: FUSO, year: "numeric", month: "2-digit", day: "2-digit" }).format(new Date(ts));
}

// ---------- tarefas e fichas ----------
type Tarefa = { id: string; titulo: string; tipo: string; lead_id: string | null; dono_id: string; criado_por: string | null;
  data: string; hora: string | null; repeticao: string; dias_semana: number[]; concluidas: string[]; email_manha: boolean };
type Lead = { id: string; cliente: string; conta: string | null; oportunidade: string | null; responsavel_id: string | null;
  proximo_contato: string | null; alertas: Array<Record<string, unknown>>; atividades: Array<Record<string, unknown>>;
  segmento: string; funil: string; esteira: string; perdido: boolean; ganho: boolean; criado_em: string | null };
type Item = { dia: string; hora: string; titulo: string; cliente: string; origem: string; repete: string };

function caiEm(t: Tarefa, dia: string): boolean {
  if (!t.data || dia < t.data) return false;
  if (t.repeticao === "dia_util") return diaSemana(dia) <= 5;
  if (t.repeticao === "semana") return (t.dias_semana ?? []).includes(diaSemana(dia));
  if (t.repeticao === "mes") {
    const alvo = Number(t.data.slice(8, 10));
    const d = data(dia);
    const ultimo = new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth() + 1, 0)).getUTCDate();
    return Number(dia.slice(8, 10)) === Math.min(alvo, ultimo);
  }
  return dia === t.data;
}
function repeteTexto(t: Tarefa): string {
  if (t.repeticao === "dia_util") return "todo dia útil";
  if (t.repeticao === "semana") return "toda " + (t.dias_semana ?? []).slice().sort().map((n) => DIAS[n - 1]).join(", ");
  if (t.repeticao === "mes") return "todo dia " + Number(t.data.slice(8, 10));
  return "";
}
function nomeCliente(l: Lead | undefined): string {
  if (!l) return "";
  const nome = (l.cliente ?? "").trim(), conta = (l.conta ?? "").trim();
  if (!conta) return nome || "Sem nome";
  if (!nome) return conta;
  return nome.endsWith(conta) ? nome : nome + " · " + conta;
}
const naCarteira = (l: Lead) => (l.funil || "assessor") !== "especialista" && !l.perdido && ((l.esteira || "novo") === "base" || l.ganho);
const saiuDoQuadro = (l: Lead) => l.perdido || ((l.funil || "assessor") === "especialista" && l.ganho);
const REGUA: Record<string, Array<{ tipo: string; qtd: number; label: string }>> = {
  Private: [{ tipo: "relacionamento", qtd: 8, label: "Relacionamento" }, { tipo: "performance", qtd: 3, label: "Acompanhamento" }, { tipo: "revisao", qtd: 1, label: "Revisão de carteira" }],
  Exclusive: [{ tipo: "relacionamento", qtd: 4, label: "Relacionamento" }, { tipo: "performance", qtd: 1, label: "Acompanhamento" }, { tipo: "revisao", qtd: 1, label: "Revisão de carteira" }],
};
function itensDaFicha(l: Lead, hoje: string): Item[] {
  const itens: Item[] = [];
  const cliente = nomeCliente(l);
  if (l.proximo_contato) {
    itens.push({ dia: l.proximo_contato, hora: "", titulo: "Contato agendado" + (l.oportunidade ? " · " + l.oportunidade : ""), cliente, origem: "Próximo contato", repete: "" });
  }
  for (const a of l.alertas ?? []) {
    if (a.tipo === "vencimento" && a.data && !a.resolvido) {
      itens.push({ dia: String(a.data), hora: "", titulo: a.texto ? "Vencimento · " + String(a.texto) : "Vencimento", cliente, origem: "Vencimento", repete: "" });
    }
  }
  if (naCarteira(l)) {
    for (const r of REGUA[l.segmento] ?? []) {
      const datas = (l.atividades ?? []).filter((x) => x.tipo === r.tipo && x.data).map((x) => String(x.data)).sort();
      const baseIso = datas.length ? datas[datas.length - 1] : (isoBrasiliaDeTimestamp(l.criado_em) ?? hoje);
      const prevista = soma(baseIso, Math.round(365 / r.qtd));
      itens.push({ dia: prevista, hora: "", titulo: r.label + " (régua " + l.segmento + ")", cliente, origem: "Régua", repete: "" });
    }
  }
  return itens;
}
const ordenar = (a: Item, b: Item) => a.dia.localeCompare(b.dia) || (a.hora || "99").localeCompare(b.hora || "99") || a.titulo.localeCompare(b.titulo);

function montarAgenda(donoId: string, tarefas: Tarefa[], leads: Lead[], hoje: string) {
  const porLead = new Map(leads.map((l) => [l.id, l]));
  const amanha = soma(hoje, diaSemana(hoje) === 5 ? 3 : 1); // sexta: a prévia é da segunda
  const atrasadas: Item[] = [], doDia: Item[] = [], proximo: Item[] = [];
  for (const t of tarefas) {
    if (t.dono_id !== donoId || !t.email_manha) continue;
    const base = { hora: (t.hora ?? "").slice(0, 5), titulo: t.titulo, cliente: nomeCliente(porLead.get(t.lead_id ?? "")),
      origem: t.criado_por && t.criado_por !== t.dono_id ? "Atribuída" : "Tarefa", repete: repeteTexto(t) };
    const feitas = t.concluidas ?? [];
    if (caiEm(t, hoje) && !feitas.includes(hoje)) doDia.push({ ...base, dia: hoje });
    if (caiEm(t, amanha)) proximo.push({ ...base, dia: amanha });
    if (t.data < hoje) {
      let dia: string | null = null;
      if (t.repeticao === "nao") dia = t.data;
      else if (!caiEm(t, hoje)) {
        for (let d = soma(hoje, -1); d >= t.data && d >= soma(hoje, -JANELA_ATRASO); d = soma(d, -1)) {
          if (caiEm(t, d)) { dia = d; break; }
        }
      }
      if (dia && !feitas.includes(dia)) atrasadas.push({ ...base, dia });
    }
  }
  for (const l of leads) {
    if (l.responsavel_id !== donoId || saiuDoQuadro(l)) continue;
    for (const it of itensDaFicha(l, hoje)) {
      if (it.dia < hoje) atrasadas.push(it);
      else if (it.dia === hoje) doDia.push(it);
      else if (it.dia === amanha) proximo.push(it);
    }
  }
  return { atrasadas: atrasadas.sort(ordenar), doDia: doDia.sort(ordenar), proximo: proximo.sort(ordenar), amanha };
}

// ---------- e-mail ----------
const COR: Record<string, string> = { "Tarefa": "#195AB4", "Atribuída": "#7C5CC4", "Próximo contato": "#2F7A56", "Vencimento": "#B3403A", "Régua": "#8A6A18" };
const F = "font-family:Helvetica, Arial, sans-serif;";
function linhaHtml(it: Item, comDia: boolean): string {
  const meta = [comDia ? "desde " + curta(it.dia) : "", it.cliente, it.origem, it.repete ? "repete " + it.repete : ""].filter(Boolean).join(" · ");
  return `<tr><td style="padding:10px 12px;border-bottom:1px solid #E6EAF0;border-left:4px solid ${COR[it.origem] ?? "#195AB4"};${F}">` +
    `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0"><tr>` +
    (it.hora ? `<td width="52" valign="top" style="${F}font-size:13px;font-weight:bold;color:#16324F;padding-top:1px;">${esc(it.hora)}</td>` : "") +
    `<td valign="top" style="${F}"><div style="font-size:14px;font-weight:bold;color:#16324F;line-height:1.35;">${esc(it.titulo)}</div>` +
    `<div style="font-size:12px;color:#7A8698;padding-top:3px;line-height:1.4;">${esc(meta)}</div></td></tr></table></td></tr>`;
}
function secaoHtml(titulo: string, cor: string, itens: Item[], comDia: boolean): string {
  if (!itens.length) return "";
  const mostrar = itens.slice(0, MAX_POR_SECAO);
  const resto = itens.length - mostrar.length;
  return `<p style="margin:22px 0 8px;${F}font-size:11px;letter-spacing:2px;text-transform:uppercase;font-weight:bold;color:${cor};">${esc(titulo)}</p>` +
    `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border:1px solid #DCE2EA;border-radius:6px;border-collapse:separate;overflow:hidden;">` +
    mostrar.map((it) => linhaHtml(it, comDia)).join("") + `</table>` +
    (resto > 0 ? `<p style="margin:6px 0 0;${F}font-size:12px;color:#7A8698;">e mais ${resto} na Agenda</p>` : "");
}
function linhaTexto(it: Item, comDia: boolean): string {
  return "- " + (it.hora ? it.hora + " " : "") + it.titulo + [comDia ? "desde " + curta(it.dia) : "", it.cliente, it.origem].filter(Boolean).map((x) => " · " + x).join("");
}
const plural = (n: number, um: string, varios: string) => n + " " + (n === 1 ? um : varios);

async function servico(caminho: string, init: RequestInit = {}): Promise<Response> {
  const chave = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  return await fetch(SB_URL + caminho, { ...init, headers: { apikey: chave, Authorization: "Bearer " + chave, "Content-Type": "application/json", ...(init.headers ?? {}) } });
}
async function lerTudo<T>(caminho: string): Promise<T[]> {
  const todos: T[] = [];
  for (let de = 0; ; de += 1000) {
    const r = await servico(caminho, { headers: { Range: `${de}-${de + 999}` } });
    if (!r.ok) throw new Error(caminho.split("?")[0] + " " + r.status + " " + (await r.text()).slice(0, 200));
    const lote = await r.json() as T[];
    todos.push(...lote);
    if (lote.length < 1000) return todos;
  }
}

Deno.serve(async (_req: Request) => {
  const agora = agoraEmBrasilia();
  if (agora.diaSemana > 5 || agora.hora < 6 || agora.hora >= 11) {
    return resposta({ ok: true, enviados: 0, motivo: "fora do horário (dia útil, 6h às 11h de Brasília)" });
  }
  const senha = Deno.env.get("SMTP_SENHA");
  if (!senha) return resposta({ erro: "Falta cadastrar SMTP_SENHA no Supabase." }, 500);
  if (!Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")) return resposta({ erro: "Sem a chave de serviço do Supabase." }, 500);
  const hoje = agora.iso;

  let perfis: Array<{ id: string; nome: string }>, tarefas: Tarefa[], leads: Lead[];
  const emails = new Map<string, string>();
  try {
    perfis = await lerTudo("/rest/v1/profiles?select=id,nome&status=eq.ativo");
    tarefas = await lerTudo<Tarefa>("/rest/v1/tarefas?select=*");
    leads = await lerTudo<Lead>("/rest/v1/leads?select=id,cliente,conta,oportunidade,responsavel_id,proximo_contato,alertas,atividades,segmento,funil,esteira,perdido,ganho,criado_em&excluido=eq.false");
    for (let pagina = 1; ; pagina++) {
      const r = await servico(`/auth/v1/admin/users?page=${pagina}&per_page=500`);
      if (!r.ok) throw new Error("usuários " + r.status);
      const j = await r.json();
      const lista = (j?.users ?? []) as Array<{ id: string; email?: string }>;
      for (const u of lista) if (u.email) emails.set(u.id, u.email.toLowerCase());
      if (lista.length < 500) break;
    }
  } catch (e) {
    console.error("leitura", e);
    return resposta({ erro: "Não foi possível ler o banco: " + String((e as Error)?.message ?? e) }, 500);
  }

  const resultado: Record<string, string> = {};
  for (const p of perfis) {
    const email = emails.get(p.id);
    if (!email) { resultado[p.nome] = "sem e-mail"; continue; }
    const ag = montarAgenda(p.id, tarefas, leads, hoje);
    if (!ag.atrasadas.length && !ag.doDia.length) { resultado[p.nome] = "nada no dia"; continue; }

    // Reserva o envio do dia antes de mandar: duas chamadas ao mesmo tempo não duplicam.
    const reserva = await servico("/rest/v1/agenda_emails?select=user_id", {
      method: "POST", headers: { Prefer: "resolution=ignore-duplicates,return=representation" },
      body: JSON.stringify({ user_id: p.id, dia: hoje, resultado: "enviando" }),
    });
    const reservado = reserva.ok ? await reserva.json() : [];
    if (!Array.isArray(reservado) || !reservado.length) { resultado[p.nome] = reserva.ok ? "já enviado hoje" : "falha na reserva " + reserva.status; continue; }

    const nome = String(p.nome ?? "").trim().split(/\s+/)[0];
    const resumo = [plural(ag.doDia.length, "tarefa hoje", "tarefas hoje"), ag.atrasadas.length ? plural(ag.atrasadas.length, "atrasada", "atrasadas") : ""].filter(Boolean).join(" e ");
    const amanhaRot = diaSemana(hoje) === 5 ? "Segunda-feira" : "Amanhã";
    const conteudo =
      `<p style="margin:0 0 4px;${F}font-size:15px;line-height:1.6;color:#3C4C60;">Você tem <strong style="color:#16324F;">${esc(resumo)}</strong>.</p>` +
      secaoHtml("Atrasadas", "#B3403A", ag.atrasadas, true) +
      secaoHtml("Hoje", "#195AB4", ag.doDia, false) +
      secaoHtml(amanhaRot, "#7A8698", ag.proximo, false);
    const texto = [
      "Você tem " + resumo + ".",
      ag.atrasadas.length ? "\nATRASADAS\n" + ag.atrasadas.slice(0, MAX_POR_SECAO).map((i) => linhaTexto(i, true)).join("\n") : "",
      ag.doDia.length ? "\nHOJE\n" + ag.doDia.slice(0, MAX_POR_SECAO).map((i) => linhaTexto(i, false)).join("\n") : "",
      ag.proximo.length ? "\n" + amanhaRot.toUpperCase() + "\n" + ag.proximo.slice(0, MAX_POR_SECAO).map((i) => linhaTexto(i, false)).join("\n") : "",
    ].filter(Boolean).join("\n");
    const saudacao = nome ? "Bom dia, " + nome + "." : "Bom dia.";
    const html = MODELO.replaceAll("{{SAUDACAO}}", esc(saudacao)).replaceAll("{{LINK}}", esc(LINK_AGENDA)).replaceAll("{{CONTEUDO}}", conteudo);
    const txt = MODELO_TEXTO.replaceAll("{{SAUDACAO}}", saudacao).replaceAll("{{LINK}}", LINK_AGENDA).replaceAll("{{CONTEUDO}}", texto);
    const assunto = "Sua agenda de hoje: " + resumo;
    let situacao = "enviado";
    try {
      await enviarSmtp(email, assunto, html, txt, senha);
    } catch (e) {
      situacao = "falha: " + String((e as Error)?.message ?? e).slice(0, 300);
      console.error("envio", p.nome, situacao);
    }
    await servico(`/rest/v1/agenda_emails?user_id=eq.${p.id}&dia=eq.${hoje}`, { method: "PATCH", body: JSON.stringify({ resultado: situacao }) });
    resultado[p.nome] = situacao;
  }
  // O detalhe por pessoa fica só no registro da função (Edge Functions > Logs): esta função
  // não exige login, e a resposta não pode contar a ninguém quem é da equipe.
  console.log("agenda-manha", hoje, JSON.stringify(resultado));
  const enviados = Object.values(resultado).filter((v) => v === "enviado").length;
  const falhas = Object.values(resultado).filter((v) => v.startsWith("falha")).length;
  return resposta({ ok: true, dia: hoje, enviados, falhas });
});
