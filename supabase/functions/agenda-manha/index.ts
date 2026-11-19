// Função "agenda-manha" do Supabase (Edge Functions).
//
// O e-mail da manhã da Agenda do CRM. Quem chama é o próprio banco, pelo agendamento
// "agenda-manha" criado no agenda.sql (pg_cron, dias úteis às 6h50 de Brasília). Para cada
// pessoa ativa no CRM, junta o que está atrasado e o que é de hoje, com uma prévia de
// amanhã, e manda pela caixa hub@adamicaptal.com.br. Quem não tem nada no dia não recebe.
//
// O que entra (o mesmo que a aba Agenda mostra para a própria pessoa):
//  - tarefas da tabela `tarefas` marcadas "Incluir no e-mail da manhã";
//  - próximo contato marcado na ficha, vencimento (alerta aberto) e régua de relacionamento;
//  - desde 19/11/2026, os gatilhos que o master ligou (agenda_gatilhos.sql): avisos da carteira pelos dados do BTG
//    (agenda_btg_montar), processo comercial, indicações dos especialistas, rotina e capacitação. Separados em
//    Compromissos (o que tem hora ou é reunião) e Tarefas (pela prioridade). O catálogo AG abaixo espelha o
//    AG_GATILHOS do crm.html (prio, padrão, quando). Mudou lá, muda aqui. Também entram os compromissos do Outlook
//    (agenda_outlook, função outlook-agenda) e as validades das certificações da ficha de cadastro (equipe_cadastro).
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
const MODELO = "<!doctype html>\n<html lang=\"pt-BR\">\n<head>\n<meta charset=\"utf-8\">\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n<meta name=\"color-scheme\" content=\"light\">\n<meta name=\"supported-color-schemes\" content=\"light\">\n<title>Sua agenda de hoje</title>\n</head>\n<body style=\"margin:0;padding:0;background:#EDF0F4;-webkit-text-size-adjust:100%;\">\n<div style=\"display:none;max-height:0;overflow:hidden;opacity:0;color:#EDF0F4;\">Seus compromissos e tarefas de hoje, da Agenda do CRM.</div>\n<table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\" border=\"0\" style=\"background:#EDF0F4;\">\n<tr><td align=\"center\" style=\"padding:32px 16px;\">\n  <table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\" border=\"0\" style=\"max-width:560px;background:#FFFFFF;border-radius:10px;overflow:hidden;border:1px solid #DCE2EA;\">\n    <tr><td align=\"center\" style=\"background:#1B3A5F;padding:28px 24px 26px;\">\n      <img src=\"https://adamicaptal.com.br/hub/img/logo-branco.png\" width=\"172\" height=\"40\" alt=\"Adami Captal\" style=\"display:block;border:0;width:172px;height:auto;\">\n      <div style=\"font-family:Helvetica, Arial, sans-serif;font-size:11px;letter-spacing:3px;text-transform:uppercase;color:#C0A265;padding-top:12px;\">Hub Adami</div>\n    </td></tr>\n    <tr><td style=\"height:3px;line-height:3px;font-size:0;background:#C0A265;\">&nbsp;</td></tr>\n    <tr><td style=\"padding:36px 40px 8px;\" class=\"miolo\">\n      <img src=\"https://adamicaptal.com.br/hub/img/icone-agenda.png\" width=\"56\" height=\"56\" alt=\"\" style=\"display:block;border:0;width:56px;height:56px;\">\n      <h1 style=\"margin:20px 0 12px;font-family:Georgia, 'Times New Roman', serif;font-weight:normal;font-size:26px;line-height:1.25;color:#16324F;\">{{SAUDACAO}}</h1>\n      {{CONTEUDO}}\n    </td></tr>\n    <tr><td style=\"padding:20px 40px 8px;\">\n      <table role=\"presentation\" cellpadding=\"0\" cellspacing=\"0\" border=\"0\"><tr>\n        <td align=\"center\" bgcolor=\"#1B3A5F\" style=\"border-radius:6px;\">\n          <a href=\"{{LINK}}\" target=\"_blank\" style=\"display:inline-block;padding:14px 28px;font-family:Helvetica, Arial, sans-serif;font-size:15px;font-weight:bold;color:#FFFFFF;text-decoration:none;border-radius:6px;\">Abrir a Agenda</a>\n        </td>\n      </tr></table>\n    </td></tr>\n    <tr><td style=\"padding:20px 40px 32px;font-family:Helvetica, Arial, sans-serif;font-size:13px;line-height:1.6;color:#3C4C60;\">\n      <p style=\"margin:0;\">Este resumo sai nos dias úteis, por volta das 7h. Os avisos da carteira usam os dados do BTG do último dia útil. Para tirar um item daqui, marque como feito na Agenda do CRM; nas tarefas criadas por você, também dá para desmarcar \"Incluir no e-mail da manhã\".</p>\n      <p style=\"margin:20px 0 0;padding-top:16px;border-top:1px solid #DCE2EA;font-size:12px;color:#7A8698;\">Se o botão não funcionar, copie e cole este endereço no navegador:<br>\n      <a href=\"{{LINK}}\" style=\"color:#1B3A5F;word-break:break-all;\">{{LINK}}</a></p>\n    </td></tr>\n  </table>\n  <table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\" border=\"0\" style=\"max-width:560px;\">\n    <tr><td align=\"center\" style=\"padding:20px 24px 0;font-family:Helvetica, Arial, sans-serif;font-size:12px;line-height:1.6;color:#7A8698;\">\n      <strong style=\"color:#3C4C60;\">Hub Adami</strong> &middot; Adami Captal<br>\n      <a href=\"https://adamicaptal.com.br/hub\" style=\"color:#7A8698;\">adamicaptal.com.br/hub</a><br>\n      E-mail automático, não precisa responder.\n    </td></tr>\n  </table>\n</td></tr>\n</table>\n</body>\n</html>\n";
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
  segmento: string; funil: string; esteira: string; perdido: boolean; ganho: boolean; criado_em: string | null;
  etapa: string | null; etapa_desde: string | null; ultimo_contato: string | null; ganho_em: string | null;
  valor_em_captacao: unknown; tarefa_tipo?: string };
type Item = { dia: string; hora: string; titulo: string; cliente: string; origem: string; repete: string;
  prio?: number; compromisso?: boolean; detalhe?: string; valor?: number; k?: string };
type Gat = Record<string, { ligado: boolean; params: Record<string, unknown> }>;
type BtgItem = { gatilho: string; chave: string; lead_id: string; dono_id: string | null; valor: number | null; data: string | null;
  info: { ativos?: string[]; emissor?: string } };
type Oport = { id: string; lead_id: string; produto: string; nota: string | null; especialista_id: string; dono_id: string | null };
type Perfil = { id: string; nome: string; role: string | null };
type Ol = { user_id: string; inicio: string; fim: string | null; dia_inteiro: boolean; assunto: string; local: string; online: boolean };
type Cert = { pessoa: string; cert: string; vence: string };
type Extra = { gat: Gat; btg: BtgItem[]; feitas: Set<string>; oport: Oport[]; perfis: Perfil[]; outlook: Ol[]; certs: Cert[] };

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
  Advisory: [{ tipo: "relacionamento", qtd: 2, label: "Relacionamento" }],
};
// Segmento que entrou na régua depois (crm.html, REGUA_INICIO e reguaDeslocamento): sem contato registrado, a
// primeira data sai da entrada do segmento mais um deslocamento fixo por cliente.
const REGUA_INICIO: Record<string, string> = { Advisory: "2026-11-12" };
function reguaDeslocamento(texto: string, dias: number): number {
  let h = 0;
  for (let i = 0; i < texto.length; i++) h = (h * 31 + texto.charCodeAt(i)) >>> 0;
  return dias > 0 ? h % dias : 0;
}
function itensDaFicha(l: Lead, hoje: string): Item[] {
  const itens: Item[] = [];
  const cliente = nomeCliente(l);
  if (l.proximo_contato) {
    itens.push({ dia: l.proximo_contato, hora: "", titulo: "Contato agendado" + (l.oportunidade ? " · " + l.oportunidade : ""), cliente, origem: "Próximo contato", repete: "", k: "contato" });
  }
  for (const a of l.alertas ?? []) {
    if (a.tipo === "vencimento" && a.data && !a.resolvido) {
      itens.push({ dia: String(a.data), hora: "", titulo: a.texto ? "Vencimento · " + String(a.texto) : "Vencimento", cliente, origem: "Vencimento", repete: "", k: "vencimento" });
    }
  }
  if (naCarteira(l)) {
    for (const r of REGUA[l.segmento] ?? []) {
      const datas = (l.atividades ?? []).filter((x) => x.tipo === r.tipo && x.data).map((x) => String(x.data)).sort();
      const intervalo = Math.round(365 / r.qtd);
      const criado = isoBrasiliaDeTimestamp(l.criado_em) ?? hoje;
      const inicio = REGUA_INICIO[l.segmento];
      const prevista = !datas.length && inicio && criado < inicio
        ? soma(inicio, reguaDeslocamento(String(l.id) + r.tipo, intervalo))
        : soma(datas.length ? datas[datas.length - 1] : criado, intervalo);
      itens.push({ dia: prevista, hora: "", titulo: r.label + " (régua " + l.segmento + ")", cliente, origem: "Régua", repete: "", k: "regua" });
    }
  }
  return itens;
}
const ordenar = (a: Item, b: Item) => a.dia.localeCompare(b.dia) || (a.hora || "99").localeCompare(b.hora || "99") || a.titulo.localeCompare(b.titulo);

// ---------- gatilhos da Agenda (espelho do AG_GATILHOS do crm.html) ----------
type Cat = { grupo: string; prio: number; ligado: boolean; padrao: Record<string, unknown>; quando?: string; nome: string };
const AG: Record<string, Cat> = {
  btg_caixa: { grupo: "carteira", prio: 75, ligado: true, padrao: { min: 10000 }, nome: "Dinheiro parado em conta" },
  btg_vencimento: { grupo: "carteira", prio: 90, ligado: true, padrao: { dias: 15 }, nome: "Vencimento" },
  btg_cotizacao: { grupo: "carteira", prio: 62, ligado: true, padrao: { dias: 15 }, nome: "Resgate em cotização" },
  btg_fgc: { grupo: "carteira", prio: 40, ligado: true, padrao: { limite: 250000 }, nome: "Acima do FGC" },
  btg_ativar: { grupo: "carteira", prio: 48, ligado: true, padrao: { dias: 90 }, nome: "Conta sem dinheiro" },
  btg_aniversario: { grupo: "carteira", prio: 82, ligado: true, padrao: {}, nome: "Aniversário" },
  btg_suitability: { grupo: "carteira", prio: 55, ligado: true, padrao: { dias: 30 }, nome: "Suitability" },
  btg_aporte: { grupo: "carteira", prio: 85, ligado: true, padrao: { min: 50000, dias: 3 }, nome: "Aporte" },
  btg_saida: { grupo: "carteira", prio: 95, ligado: true, padrao: { min: 100000, dias: 3 }, nome: "Saída" },
  crm_lead_novo: { grupo: "processo", prio: 72, ligado: true, padrao: { dias: 1 }, nome: "Primeiro contato" },
  crm_sla: { grupo: "processo", prio: 68, ligado: true, padrao: {}, nome: "Prazo da etapa" },
  crm_proposta: { grupo: "processo", prio: 70, ligado: true, padrao: { dias: 5 }, nome: "Follow-up da proposta" },
  crm_parado: { grupo: "processo", prio: 52, ligado: true, padrao: { dias: 15 }, nome: "Negócio parado" },
  crm_boas_vindas: { grupo: "processo", prio: 64, ligado: true, padrao: {}, nome: "Cliente captado" },
  crm_indicacao: { grupo: "processo", prio: 45, ligado: true, padrao: { dias: 60 }, nome: "Pedir indicação" },
  esp_oportunidade: { grupo: "especialista", prio: 80, ligado: true, padrao: {}, nome: "Indicação do especialista" },
  rot_cenario: { grupo: "rotina", prio: 30, ligado: false, quando: "dia_util", padrao: { titulo: "Ler o cenário do dia", hora: "08:30" }, nome: "Ler o cenário do dia" },
  rot_prospeccao: { grupo: "rotina", prio: 30, ligado: false, quando: "dia_util", padrao: { titulo: "Bloco de prospecção", meta: 10, hora: "10:00" }, nome: "Bloco de prospecção" },
  rot_registro: { grupo: "rotina", prio: 30, ligado: false, quando: "dia_util", padrao: { titulo: "Registrar as atividades do dia no CRM", hora: "17:30" }, nome: "Registrar as atividades" },
  rot_reuniao_semanal: { grupo: "rotina", prio: 30, ligado: false, quando: "semana", padrao: { titulo: "Reunião comercial da semana", dia_semana: 1, hora: "09:00" }, nome: "Reunião comercial" },
  rot_pipeline: { grupo: "rotina", prio: 30, ligado: false, quando: "semana", padrao: { titulo: "Revisar o pipeline e a temperatura dos negócios", dia_semana: 5 }, nome: "Revisar o pipeline" },
  rot_comite: { grupo: "rotina", prio: 30, ligado: false, quando: "mes", padrao: { titulo: "Comitê de alocação do mês", dia_mes: 10 }, nome: "Comitê de alocação" },
  rot_fechamento: { grupo: "rotina", prio: 30, ligado: false, quando: "mes", padrao: { titulo: "Fechar as carteiras do mês", dia_mes: 2 }, nome: "Fechar as carteiras" },
  rot_comissao: { grupo: "rotina", prio: 30, ligado: false, quando: "mes", padrao: { titulo: "Conferir a comissão do mês", dia_mes: 15 }, nome: "Conferir a comissão" },
  cap_conteudo: { grupo: "capacitacao", prio: 25, ligado: false, quando: "semana", padrao: { titulo: "", dia_semana: 1 }, nome: "Conteúdo da semana" },
  cap_produto: { grupo: "capacitacao", prio: 25, ligado: false, quando: "semana", padrao: { titulo: "", dia_semana: 1 }, nome: "Produto da semana" },
  cap_certificacao: { grupo: "capacitacao", prio: 58, ligado: false, padrao: { dias: 90, lista: [] }, nome: "Certificação" },
  cap_roleplay: { grupo: "capacitacao", prio: 25, ligado: false, quando: "mes", padrao: { titulo: "Roleplay com o head comercial (R1 ou proposta)", dia_mes: 20 }, nome: "Roleplay" },
  cap_especialista: { grupo: "capacitacao", prio: 25, ligado: false, quando: "mes", padrao: { titulo: "Acompanhar uma reunião de especialista", dia_mes: 25 }, nome: "Acompanhar especialista" },
};
const ROTINA_COMPROMISSO: Record<string, boolean> = { rot_reuniao_semanal: true, rot_comite: true };
const PRIO_ORIGEM: Record<string, number> = { "Atribuída": 88, "Vencimento": 86, "Tarefa": 78, "Próximo contato": 74, "Régua": 50 };
const SLA_DIAS: Record<string, number> = { "R1": 3, "R2": 7, "R2.1": 7, "R3": 7 };
// Prazo da etapa, proposta e negócio parado só para quem mudou de etapa a partir daqui (crm.html, agMoveuNoPipe):
// os clientes da base nasceram na R2 e não são proposta sem retorno.
const CORTE_PROCESSO = Date.parse("2026-11-19T12:00:00Z");
const moveuNoPipe = (l: Lead) => {
  const t = l.etapa_desde ? Date.parse(l.etapa_desde) : 0, c = l.criado_em ? Date.parse(l.criado_em) : 0;
  return !!t && t >= CORTE_PROCESSO && (!c || t - c > 60000);
};
const ROTULO_GRUPO: Record<string, string> = { carteira: "Carteira", processo: "Processo", especialista: "Especialista", rotina: "Rotina", capacitacao: "Capacitação" };

function gatOn(gat: Gat, k: string): Record<string, unknown> | null {
  const cat = AG[k];
  if (!cat) return null;
  const g = gat[k];
  const ligado = g ? !!g.ligado : cat.ligado;
  return ligado ? { ...cat.padrao, ...((g && g.params) || {}) } : null;
}
const nnum = (v: unknown, padrao: number) => { const n = Number(v); return Number.isFinite(n) && n > 0 ? n : padrao; };
function valorNum(v: unknown): number {
  if (typeof v === "number") return v;
  const t = String(v ?? "").replace(/[^\d,.-]/g, "");
  if (!t) return 0;
  const n = /,\d{1,2}$/.test(t) ? Number(t.replace(/\./g, "").replace(",", ".")) : Number(t.replace(/,/g, ""));
  return Number.isFinite(n) ? n : 0;
}
const reais = (v: unknown) => "R$ " + Math.round(Number(v) || 0).toLocaleString("pt-BR");
const ddmm = (iso: string | null | undefined) => iso && iso.length >= 10 ? iso.slice(8, 10) + "/" + iso.slice(5, 7) : "";
const diasEntre = (de: string, ate: string) => Math.round((data(ate).getTime() - data(de).getTime()) / DIA_MS);
function diaDoMes(iso: string, dia: unknown): string {
  const d = data(iso);
  const ultimo = new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth() + 1, 0)).getUTCDate();
  let alvo = iso.slice(0, 8) + String(Math.min(Math.max(1, Number(dia) || 1), ultimo)).padStart(2, "0");
  while (diaSemana(alvo) > 5) alvo = soma(alvo, 1);
  return alvo;
}
function rotinaCai(cat: Cat, p: Record<string, unknown>, dia: string): boolean {
  if (cat.quando === "dia_util") return diaSemana(dia) <= 5;
  if (cat.quando === "semana") return diaSemana(dia) === (Number(p.dia_semana) || 1);
  if (cat.quando === "mes") return dia === diaDoMes(dia, p.dia_mes);
  return false;
}
function tituloRotina(k: string, p: Record<string, unknown>): string {
  if (k === "cap_conteudo") return "Conteúdo da semana: " + String(p.titulo ?? "");
  if (k === "cap_produto") return "Produto da semana: " + String(p.titulo ?? "");
  return String(p.titulo || AG[k].nome) + (k === "rot_prospeccao" && Number(p.meta) ? " · meta de " + Number(p.meta) + " ligações" : "");
}
function ultimoContato(l: Lead): string {
  let u = l.ultimo_contato ?? "";
  for (const a of l.atividades ?? []) if (a.data && String(a.data) > u) u = String(a.data);
  return u;
}

// As tarefas dos gatilhos de uma pessoa: as de hoje, as rotinas de "amanhã" e as rotinas semanais/mensais atrasadas.
function itensGatilhos(donoId: string, leads: Lead[], ex: Extra, hoje: string, amanha: string) {
  const doDia: Item[] = [], proximo: Item[] = [], atrasadas: Item[] = [];
  const porLead = new Map(leads.map((l) => [l.id, l]));
  const eu = ex.perfis.find((p) => p.id === donoId);
  const nomeDe = (id: string) => ex.perfis.find((p) => p.id === id)?.nome ?? "";
  const add = (k: string, titulo: string, l: Lead | undefined, detalhe = "", valor = 0) =>
    doDia.push({ dia: hoje, hora: "", titulo, cliente: nomeCliente(l), origem: ROTULO_GRUPO[AG[k].grupo], repete: "", prio: AG[k].prio, detalhe, valor, k });
  // Carteira (BTG)
  for (const b of ex.btg) {
    if (ex.feitas.has(b.chave) || !gatOn(ex.gat, b.gatilho)) continue;
    const l = porLead.get(b.lead_id);
    if (!l || (l.responsavel_id ?? b.dono_id) !== donoId || saiuDoQuadro(l)) continue;
    const ativos = (b.info?.ativos ?? []).slice(0, 3).join(", ");
    const t: Record<string, string> = {
      btg_caixa: reais(b.valor) + " parados em conta",
      btg_vencimento: "Vence em " + ddmm(b.data) + ": " + reais(b.valor),
      btg_cotizacao: "Resgate de fundo cai em " + ddmm(b.data) + ": " + reais(b.valor),
      btg_fgc: "Acima do FGC: " + reais(b.valor) + " num só emissor",
      btg_ativar: "Conta aberta sem dinheiro: ativar",
      btg_aniversario: b.data === hoje ? "Aniversário hoje" : "Aniversário em " + ddmm(b.data),
      btg_suitability: "Suitability vence em " + ddmm(b.data),
      btg_aporte: "Aporte de " + reais(b.valor) + " em " + ddmm(b.data) + ": agradecer e alocar",
      btg_saida: "Saída de " + reais(b.valor) + " em " + ddmm(b.data) + ": entender o motivo",
    };
    add(b.gatilho, t[b.gatilho] ?? AG[b.gatilho].nome, l, b.gatilho === "btg_fgc" ? (b.info?.emissor ?? "") : ativos, Number(b.valor) || 0);
  }
  // Processo comercial: uma por ficha, a de maior prioridade
  const pNovo = gatOn(ex.gat, "crm_lead_novo"), pSla = gatOn(ex.gat, "crm_sla"), pProp = gatOn(ex.gat, "crm_proposta"),
    pParado = gatOn(ex.gat, "crm_parado"), pBoas = gatOn(ex.gat, "crm_boas_vindas"), pInd = gatOn(ex.gat, "crm_indicacao");
  for (const l of leads) {
    if (l.responsavel_id !== donoId || saiuDoQuadro(l) || (l.funil || "assessor") !== "assessor") continue;
    const ultimo = ultimoContato(l);
    const criado = isoBrasiliaDeTimestamp(l.criado_em) ?? hoje;
    const naEtapa = isoBrasiliaDeTimestamp(l.etapa_desde) ?? criado;
    const diasEtapa = diasEntre(naEtapa, hoje), semContato = diasEntre(ultimo || naEtapa, hoje);
    const ganho = l.ganho && l.ganho_em ? isoBrasiliaDeTimestamp(l.ganho_em) ?? "" : "";
    if (pNovo && l.etapa === "Cliente Novo" && (l.esteira || "novo") !== "base" && !ultimo && soma(criado, Number(pNovo.dias) || 0) <= hoje) { add("crm_lead_novo", "Primeiro contato com o lead", l); continue; }
    const moveu = moveuNoPipe(l);
    if (pProp && !ganho && moveu && l.etapa === "R2" && diasEtapa >= nnum(pProp.dias, 5) && semContato >= nnum(pProp.dias, 5)) { add("crm_proposta", "Follow-up da proposta (sem retorno há " + semContato + " dias)", l); continue; }
    const sla = SLA_DIAS[l.etapa ?? ""];
    if (pSla && !ganho && moveu && sla && diasEtapa > sla && semContato >= sla) { add("crm_sla", l.etapa + " há " + diasEtapa + " dias: marcar a próxima reunião", l); continue; }
    const emAndamento = (moveu && ["R1", "R2", "R2.1", "R3", "R4"].includes(l.etapa ?? "")) || ((l.esteira || "novo") === "base" && valorNum(l.valor_em_captacao) > 0);
    if (pParado && !ganho && emAndamento && semContato >= nnum(pParado.dias, 15)) { add("crm_parado", "Negócio parado há " + semContato + " dias", l); continue; }
    if (pBoas && ganho) {
      let feito = false;
      for (const [n, rot, folga] of [[30, "Primeira revisão da carteira", 25], [7, "Conferir a primeira semana do cliente", 5], [1, "Boas-vindas ao cliente novo", 1]] as Array<[number, string, number]>) {
        const vence = soma(ganho, n);
        if (vence > hoje || diasEntre(vence, hoje) > 21) continue;
        if (!(l.atividades ?? []).some((a) => a.data && String(a.data) >= soma(ganho, folga))) { add("crm_boas_vindas", rot, l); feito = true; }
        break;
      }
      if (feito) continue;
    }
    if (pInd && ganho) {
      const quando = soma(ganho, nnum(pInd.dias, 60));
      if (quando <= hoje && diasEntre(quando, hoje) <= 30 && !ex.feitas.has("ind:" + l.id)) add("crm_indicacao", "Pedir indicação", l);
    }
  }
  // Indicações dos especialistas
  if (gatOn(ex.gat, "esp_oportunidade")) {
    for (const o of ex.oport) {
      const l = porLead.get(o.lead_id);
      if ((l?.responsavel_id ?? o.dono_id) !== donoId) continue;
      add("esp_oportunidade", o.produto + ": indicado por " + (nomeDe(o.especialista_id) || "especialista"), l, o.nota ?? "");
    }
  }
  // Rotina e capacitação: só para assessor
  if (eu?.role === "vendedor") {
    for (const k of Object.keys(AG)) {
      const cat = AG[k];
      const p = cat.quando ? gatOn(ex.gat, k) : null;
      if (!p || (cat.grupo === "capacitacao" && !String(p.titulo ?? "").trim())) continue;
      const hora = /^\d{2}:\d{2}$/.test(String(p.hora ?? "")) ? String(p.hora) : "";
      const item = (dia: string): Item => ({ dia, hora, titulo: tituloRotina(k, p), cliente: "", origem: ROTULO_GRUPO[cat.grupo], repete: "",
        prio: cat.prio, compromisso: !!ROTINA_COMPROMISSO[k], k });
      const chave = (dia: string) => (cat.grupo === "rotina" ? "rot:" : "cap:") + k + ":" + dia + ":" + donoId;
      if (rotinaCai(cat, p, hoje) && !ex.feitas.has(chave(hoje))) doDia.push(item(hoje));
      if (rotinaCai(cat, p, amanha)) proximo.push(item(amanha));
      if ((cat.quando === "semana" || cat.quando === "mes") && !rotinaCai(cat, p, hoje)) {
        for (let d = soma(hoje, -1); d >= soma(hoje, -JANELA_ATRASO); d = soma(d, -1)) {
          if (rotinaCai(cat, p, d)) { if (!ex.feitas.has(chave(d))) atrasadas.push(item(d)); break; }
        }
      }
    }
  }
  // Compromissos do Outlook (agenda_outlook): hoje e a prévia de amanhã, no horário de Brasília.
  for (const ev of ex.outlook) {
    if (ev.user_id !== donoId) continue;
    const dia = ev.dia_inteiro ? String(ev.inicio).slice(0, 10) : isoBrasiliaDeTimestamp(ev.inicio);
    const hm = (ts: string | null) => ts ? new Intl.DateTimeFormat("en-GB", { timeZone: FUSO, hour: "2-digit", minute: "2-digit", hour12: false }).format(new Date(ts)) : "";
    const it: Item = { dia: dia ?? "", hora: ev.dia_inteiro ? "" : hm(ev.inicio), titulo: ev.assunto || "(sem assunto)", cliente: "", origem: "Outlook", repete: "",
      prio: 92, compromisso: true, detalhe: [ev.dia_inteiro ? "dia inteiro" : (ev.fim ? "até " + hm(ev.fim) : ""), ev.local, ev.online ? "online" : ""].filter(Boolean).join(" · ") };
    if (dia === hoje) doDia.push(it); else if (dia === amanha) proximo.push(it);
  }
  const pCert = gatOn(ex.gat, "cap_certificacao");
  if (pCert) {
    const lista = (Array.isArray(pCert.lista) ? pCert.lista : []) as Array<{ pessoa?: string; cert?: string; vence?: string }>;
    for (const c of lista.concat(ex.certs)) {
      if (!c || c.pessoa !== donoId || !c.cert || !/^\d{4}-\d{2}-\d{2}$/.test(c.vence ?? "")) continue;
      if (soma(c.vence!, -nnum(pCert.dias, 90)) > hoje) continue;
      const chave = "cert:" + String(c.cert).toLowerCase().replace(/[^a-z0-9]+/g, "-").slice(0, 30) + ":" + c.vence + ":" + donoId;
      if (!ex.feitas.has(chave)) doDia.push({ dia: hoje, hora: "", titulo: "Certificação " + c.cert + (c.vence! < hoje ? " venceu em " : " vence em ") + ddmm(c.vence) + "/" + c.vence!.slice(0, 4),
        cliente: "", origem: "Capacitação", repete: "", prio: AG.cap_certificacao.prio, k: "cap_certificacao" });
    }
  }
  return { doDia, proximo, atrasadas };
}
// Hierarquia que o master escolhe na Agenda (crm.html, agOrdem/agPrioMapa): agenda_gatilhos "geral", params.ordem.
// O de cima vale 1000, o seguinte 999... Tipo que não está na ordem salva vai para o fim.
const ORIGENS_TAREFA: Record<string, number> = { atribuida: 88, vencimento: 86, manual: 78, contato: 74, regua: 50 };
function prioMapa(gat: Gat): Record<string, number> {
  const todos = Object.entries(ORIGENS_TAREFA).map(([k, prio]) => ({ k, prio }))
    .concat(Object.keys(AG).filter((k) => !ROTINA_COMPROMISSO[k]).map((k) => ({ k, prio: AG[k].prio })))
    .sort((a, b) => b.prio - a.prio);
  const porK = new Map(todos.map((x) => [x.k, x]));
  const salva = Array.isArray(gat.geral?.params?.ordem) ? gat.geral.params.ordem as string[] : [];
  const vistos = new Set<string>(), out: Array<{ k: string; prio: number }> = [];
  for (const k of salva) if (porK.has(k) && !vistos.has(k)) { vistos.add(k); out.push(porK.get(k)!); }
  // Sem ordem salva, vale a padrão; com ordem salva, ela manda e o tipo que não está nela vai para o fim.
  for (const x of todos) if (!vistos.has(x.k)) { vistos.add(x.k); out.push(x); }
  const m: Record<string, number> = {};
  out.forEach((x, i) => { m[x.k] = 1000 - i; });
  return m;
}
const ordenarTarefas = (a: Item, b: Item) => (b.prio ?? 0) - (a.prio ?? 0) || (b.valor ?? 0) - (a.valor ?? 0) || a.titulo.localeCompare(b.titulo);

function montarAgenda(donoId: string, tarefas: Tarefa[], leads: Lead[], hoje: string, ex: Extra) {
  const porLead = new Map(leads.map((l) => [l.id, l]));
  const amanha = soma(hoje, diaSemana(hoje) === 5 ? 3 : 1); // sexta: a prévia é da segunda
  const atrasadas: Item[] = [], doDia: Item[] = [], proximo: Item[] = [];
  for (const t of tarefas) {
    if (t.dono_id !== donoId || !t.email_manha) continue;
    const origemT = t.criado_por && t.criado_por !== t.dono_id ? "Atribuída" : "Tarefa";
    const base = { hora: (t.hora ?? "").slice(0, 5), titulo: t.titulo, cliente: nomeCliente(porLead.get(t.lead_id ?? "")),
      origem: origemT, repete: repeteTexto(t), prio: PRIO_ORIGEM[origemT], compromisso: t.tipo === "reuniao" || !!t.hora,
      k: origemT === "Atribuída" ? "atribuida" : "manual" };
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
      const comPrio = { ...it, prio: PRIO_ORIGEM[it.origem] ?? 50 };
      if (it.dia < hoje) atrasadas.push(comPrio);
      else if (it.dia === hoje) doDia.push(comPrio);
      else if (it.dia === amanha) proximo.push(comPrio);
    }
  }
  const g = itensGatilhos(donoId, leads, ex, hoje, amanha);
  doDia.push(...g.doDia); proximo.push(...g.proximo); atrasadas.push(...g.atrasadas);
  const rank = prioMapa(ex.gat);
  for (const it of doDia) if (it.k && rank[it.k]) it.prio = rank[it.k];
  const compromissos = doDia.filter((i) => i.compromisso).sort(ordenar);
  const tarefasDia = doDia.filter((i) => !i.compromisso).sort(ordenarTarefas);
  return { atrasadas: atrasadas.sort(ordenar), compromissos, tarefasDia, doDia, proximo: proximo.sort(ordenar), amanha };
}

// ---------- e-mail ----------
const COR: Record<string, string> = { "Tarefa": "#195AB4", "Atribuída": "#7C5CC4", "Próximo contato": "#2F7A56", "Vencimento": "#B3403A", "Régua": "#8A6A18",
  "Carteira": "#0E7490", "Processo": "#C2410C", "Especialista": "#B4357A", "Rotina": "#5B6676", "Capacitação": "#4D7C0F", "Outlook": "#0F6CBD" };
const F = "font-family:Helvetica, Arial, sans-serif;";
function linhaHtml(it: Item, comDia: boolean): string {
  const meta = [comDia ? "desde " + curta(it.dia) : "", it.detalhe ?? "", it.cliente, it.origem, it.repete ? "repete " + it.repete : ""].filter(Boolean).join(" · ");
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

/* Só o agendamento chama (3.41): ele manda o cabeçalho x-btg-sync com o token do Vault, o mesmo das funções do
   BTG. Sem isso, qualquer pessoa com o endereço disparava o e-mail da manhã para a equipe inteira. */
async function chamadaAutorizada(req: Request): Promise<boolean> {
  const tk = req.headers.get("x-btg-sync") ?? "";
  if (!tk) return false;
  try {
    const r = await servico("/rest/v1/rpc/btg_sync_token_ok", { method: "POST", body: JSON.stringify({ p: tk }) });
    return r.ok && (await r.text()).trim() === "true";
  } catch (_) { return false; }
}

Deno.serve(async (req: Request) => {
  if (!(await chamadaAutorizada(req))) return resposta({ erro: "não autorizado" }, 401);
  const agora = agoraEmBrasilia();
  if (agora.diaSemana > 5 || agora.hora < 6 || agora.hora >= 11) {
    return resposta({ ok: true, enviados: 0, motivo: "fora do horário (dia útil, 6h às 11h de Brasília)" });
  }
  const senha = Deno.env.get("SMTP_SENHA");
  if (!senha) return resposta({ erro: "Falta cadastrar SMTP_SENHA no Supabase." }, 500);
  if (!Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")) return resposta({ erro: "Sem a chave de serviço do Supabase." }, 500);
  const hoje = agora.iso;

  let perfis: Perfil[], tarefas: Tarefa[], leads: Lead[];
  const emails = new Map<string, string>();
  const ex: Extra = { gat: {}, btg: [], feitas: new Set(), oport: [], perfis: [], outlook: [], certs: [] };
  try {
    perfis = await lerTudo<Perfil>("/rest/v1/profiles?select=id,nome,role&status=eq.ativo");
    ex.perfis = perfis;
    tarefas = await lerTudo<Tarefa>("/rest/v1/tarefas?select=*");
    leads = await lerTudo<Lead>("/rest/v1/leads?select=id,cliente,conta,oportunidade,responsavel_id,proximo_contato,alertas,atividades,segmento,funil,esteira,perdido,ganho,criado_em,etapa,etapa_desde,ultimo_contato,ganho_em,valor_em_captacao&excluido=eq.false");
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
  // Gatilhos da Agenda (agenda_gatilhos.sql). Se faltar alguma parte no banco, o e-mail sai como antes.
  try {
    for (const g of await lerTudo<{ chave: string; ligado: boolean; params: Record<string, unknown> }>("/rest/v1/agenda_gatilhos?select=chave,ligado,params")) {
      ex.gat[g.chave] = { ligado: !!g.ligado, params: g.params ?? {} };
    }
    for (const r of await lerTudo<{ chave: string }>("/rest/v1/agenda_resolvidos?select=chave&dia=gte." + soma(hoje, -60))) ex.feitas.add(r.chave);
    ex.oport = await lerTudo<Oport>("/rest/v1/oportunidades_produto?select=id,lead_id,produto,nota,especialista_id,dono_id&status=eq.aberta");
    const rb = await servico("/rest/v1/rpc/agenda_btg_montar", { method: "POST", body: JSON.stringify({ p_dono: null, v_vis: null }) });
    if (rb.ok) { const j = await rb.json(); if (Array.isArray(j)) ex.btg = j as BtgItem[]; }
    else console.error("agenda_btg_montar", rb.status, (await rb.text()).slice(0, 200));
    ex.outlook = await lerTudo<Ol>("/rest/v1/agenda_outlook?select=user_id,inicio,fim,dia_inteiro,assunto,local,online&inicio=gte." +
      encodeURIComponent(soma(hoje, -1) + "T03:00:00Z") + "&inicio=lt." + encodeURIComponent(soma(hoje, 5) + "T03:00:00Z"));
    // Validades das certificações da ficha de cadastro (equipe_cadastro), pelo e-mail ou pela conta.
    const porEmail = new Map<string, string>(); for (const [id, em] of emails) porEmail.set(em, id);
    // Só as certificações: o resto da ficha (CPF, endereço) não sai do banco.
    for (const c of await lerTudo<{ email: string; user_id: string | null; certificacoes: Record<string, string> | null }>("/rest/v1/equipe_cadastro?select=email,user_id,certificacoes:dados->certificacoes")) {
      const pessoa = c.user_id ?? porEmail.get(c.email);
      if (!pessoa) continue;
      for (const [cert, vence] of Object.entries(c.certificacoes ?? {})) ex.certs.push({ pessoa, cert, vence: String(vence) });
    }
  } catch (e) {
    console.error("gatilhos", e);
  }

  const resultado: Record<string, string> = {};
  for (const p of perfis) {
    const email = emails.get(p.id);
    if (!email) { resultado[p.nome] = "sem e-mail"; continue; }
    const ag = montarAgenda(p.id, tarefas, leads, hoje, ex);
    if (!ag.atrasadas.length && !ag.doDia.length) { resultado[p.nome] = "nada no dia"; continue; }

    // Reserva o envio do dia antes de mandar: duas chamadas ao mesmo tempo não duplicam.
    const reserva = await servico("/rest/v1/agenda_emails?select=user_id", {
      method: "POST", headers: { Prefer: "resolution=ignore-duplicates,return=representation" },
      body: JSON.stringify({ user_id: p.id, dia: hoje, resultado: "enviando" }),
    });
    const reservado = reserva.ok ? await reserva.json() : [];
    if (!Array.isArray(reservado) || !reservado.length) { resultado[p.nome] = reserva.ok ? "já enviado hoje" : "falha na reserva " + reserva.status; continue; }

    const nome = String(p.nome ?? "").trim().split(/\s+/)[0];
    const resumo = [ag.compromissos.length ? plural(ag.compromissos.length, "compromisso", "compromissos") : "",
      ag.tarefasDia.length ? plural(ag.tarefasDia.length, "tarefa hoje", "tarefas hoje") : "",
      ag.atrasadas.length ? plural(ag.atrasadas.length, "atrasada", "atrasadas") : ""].filter(Boolean).join(", ").replace(/, ([^,]*)$/, " e $1");
    const amanhaRot = diaSemana(hoje) === 5 ? "Segunda-feira" : "Amanhã";
    const conteudo =
      `<p style="margin:0 0 4px;${F}font-size:15px;line-height:1.6;color:#3C4C60;">Você tem <strong style="color:#16324F;">${esc(resumo)}</strong>.</p>` +
      secaoHtml("Compromissos de hoje", "#16324F", ag.compromissos, false) +
      secaoHtml("Tarefas de hoje", "#195AB4", ag.tarefasDia, false) +
      secaoHtml("Atrasadas", "#B3403A", ag.atrasadas, true) +
      secaoHtml(amanhaRot, "#7A8698", ag.proximo, false);
    const texto = [
      "Você tem " + resumo + ".",
      ag.compromissos.length ? "\nCOMPROMISSOS DE HOJE\n" + ag.compromissos.slice(0, MAX_POR_SECAO).map((i) => linhaTexto(i, false)).join("\n") : "",
      ag.tarefasDia.length ? "\nTAREFAS DE HOJE\n" + ag.tarefasDia.slice(0, MAX_POR_SECAO).map((i) => linhaTexto(i, false)).join("\n") : "",
      ag.atrasadas.length ? "\nATRASADAS\n" + ag.atrasadas.slice(0, MAX_POR_SECAO).map((i) => linhaTexto(i, true)).join("\n") : "",
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
