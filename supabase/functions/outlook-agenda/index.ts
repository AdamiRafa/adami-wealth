// Função "outlook-agenda" do Supabase (Edge Functions): traz para o Hub os compromissos do Outlook.
//
// Preparada em 19/11/2026; liga quando o administrador do Microsoft 365 registrar o aplicativo "Hub Adami - Agenda"
// (Microsoft Graph, permissão de aplicativo Calendars.Read, consentimento do administrador, acesso restrito ao grupo da
// equipe comercial) e alguém cadastrar em Edge Functions > Secrets: M365_TENANT_ID, M365_CLIENT_ID e M365_CLIENT_SECRET.
// Quem chama é o agendamento "outlook-agenda" do banco (agenda_outlook.sql), a cada 30 minutos em dia útil; ele nasce
// desligado. Só lê: para cada pessoa ativa do Hub com e-mail @adamicaptal.com.br, busca o calendário de ontem até 15 dias
// à frente e regrava a tabela agenda_outlook (a Agenda do CRM e o e-mail da manhã mostram como Compromissos).
// Compromisso marcado como particular no Outlook entra só como "Compromisso particular", sem assunto nem local.
// Pessoa que o Microsoft 365 não deixa ler (fora do grupo liberado) fica de fora, sem erro.
//
// Segurança: só roda com o cabeçalho x-btg-sync igual ao token guardado no Vault do banco (o mesmo dos pedidos ao BTG;
// quem confere é btg_sync_token_ok). "Verify JWT" desligado (quem chama é o banco). A resposta só traz contagens.
const SB_URL = Deno.env.get("SUPABASE_URL") ?? "https://ghxjqmjtmbqzvogwzylo.supabase.co";
const CHAVE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const TENANT = (Deno.env.get("M365_TENANT_ID") ?? "").trim();
const CLIENTE = (Deno.env.get("M365_CLIENT_ID") ?? "").trim();
const SEGREDO = (Deno.env.get("M365_CLIENT_SECRET") ?? "").trim();
const DOMINIO = "@adamicaptal.com.br";
const DIA_MS = 86400000;

function resposta(corpo: unknown, status = 200): Response {
  return new Response(JSON.stringify(corpo), { status, headers: { "Content-Type": "application/json; charset=utf-8" } });
}
const cab = () => ({ apikey: CHAVE, Authorization: "Bearer " + CHAVE, "Content-Type": "application/json" });
async function rpc(nome: string, args: Record<string, unknown>): Promise<unknown> {
  const r = await fetch(`${SB_URL}/rest/v1/rpc/${nome}`, { method: "POST", headers: cab(), body: JSON.stringify(args) });
  const t = await r.text();
  if (!r.ok) throw new Error(`${nome}: ${r.status} ${t.slice(0, 200)}`);
  return t ? JSON.parse(t) : null;
}

type Evento = { id: string; subject?: string; isAllDay?: boolean; isCancelled?: boolean; isOnlineMeeting?: boolean;
  showAs?: string; sensitivity?: string; start?: { dateTime?: string }; end?: { dateTime?: string };
  location?: { displayName?: string }; organizer?: { emailAddress?: { name?: string } } };

// Data e hora que o Graph devolve em UTC (Prefer: outlook.timezone="UTC"), sem o "Z".
const utc = (s?: string) => s ? (/[zZ]|[+-]\d\d:\d\d$/.test(s) ? s : s.replace(/\.\d+$/, "") + "Z") : null;

async function tokenGraph(): Promise<string> {
  const corpo = new URLSearchParams({ client_id: CLIENTE, client_secret: SEGREDO, grant_type: "client_credentials",
    scope: "https://graph.microsoft.com/.default" });
  const r = await fetch(`https://login.microsoftonline.com/${encodeURIComponent(TENANT)}/oauth2/v2.0/token`,
    { method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" }, body: corpo });
  const j = await r.json().catch(() => ({}));
  if (!r.ok || !j.access_token) throw new Error("Microsoft não deu acesso: " + r.status + " " + String(j.error_description ?? j.error ?? "").slice(0, 200));
  return j.access_token as string;
}

async function eventos(tk: string, email: string, ini: string, fim: string): Promise<Evento[] | null> {
  let url: string | null = `https://graph.microsoft.com/v1.0/users/${encodeURIComponent(email)}/calendarView?startDateTime=${ini}&endDateTime=${fim}` +
    "&$select=id,subject,start,end,isAllDay,location,isOnlineMeeting,organizer,showAs,isCancelled,sensitivity&$top=250";
  const todos: Evento[] = [];
  for (let pagina = 0; url && pagina < 20; pagina++) {
    const r: Response = await fetch(url, { headers: { Authorization: "Bearer " + tk, Prefer: 'outlook.timezone="UTC"' } });
    if (r.status === 403 || r.status === 404) return null; // fora do grupo liberado ou sem caixa no Microsoft 365
    if (!r.ok) throw new Error(email + ": " + r.status + " " + (await r.text()).slice(0, 200));
    const j = await r.json();
    todos.push(...((j.value ?? []) as Evento[]));
    url = j["@odata.nextLink"] ?? null;
  }
  return todos;
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return resposta({ erro: "Use POST." }, 405);
  if (!CHAVE) return resposta({ erro: "Sem a chave de serviço do Supabase." }, 500);
  if (!(await rpc("btg_sync_token_ok", { p: req.headers.get("x-btg-sync") ?? "" }))) return resposta({ erro: "não autorizado" }, 401);
  if (!TENANT || !CLIENTE || !SEGREDO) {
    return resposta({ ok: false, motivo: "Faltam M365_TENANT_ID, M365_CLIENT_ID e M365_CLIENT_SECRET nos Secrets do Supabase." });
  }

  // Quem: pessoas ativas do Hub com e-mail da Adami.
  const perfis = await (await fetch(`${SB_URL}/rest/v1/profiles?select=id&status=eq.ativo`, { headers: cab() })).json() as Array<{ id: string }>;
  const ativos = new Set(perfis.map((p) => p.id));
  const pessoas: Array<{ id: string; email: string }> = [];
  for (let pagina = 1; ; pagina++) {
    const r = await fetch(`${SB_URL}/auth/v1/admin/users?page=${pagina}&per_page=500`, { headers: cab() });
    if (!r.ok) return resposta({ erro: "usuários " + r.status }, 500);
    const lista = ((await r.json())?.users ?? []) as Array<{ id: string; email?: string }>;
    for (const u of lista) if (u.email && ativos.has(u.id) && u.email.toLowerCase().endsWith(DOMINIO)) pessoas.push({ id: u.id, email: u.email.toLowerCase() });
    if (lista.length < 500) break;
  }

  const agora = Date.now();
  const ini = new Date(agora - DIA_MS).toISOString().slice(0, 10) + "T03:00:00Z"; // ontem, 0h em Brasília
  const fim = new Date(agora + 15 * DIA_MS).toISOString().slice(0, 10) + "T03:00:00Z";
  let tk: string;
  try { tk = await tokenGraph(); } catch (e) { console.error(e); return resposta({ ok: false, erro: String((e as Error).message) }, 502); }

  const resultado = { pessoas: pessoas.length, lidas: 0, sem_acesso: 0, falhas: 0, compromissos: 0 };
  for (const p of pessoas) {
    let lista: Evento[] | null;
    try { lista = await eventos(tk, p.email, ini, fim); } catch (e) { console.error(e); resultado.falhas++; continue; }
    if (lista === null) { resultado.sem_acesso++; continue; }
    const linhas = lista.filter((e) => !e.isCancelled && e.start?.dateTime).map((e) => {
      const particular = e.sensitivity === "private" || e.sensitivity === "confidential";
      return { id: p.id + ":" + e.id, user_id: p.id, inicio: utc(e.start?.dateTime), fim: utc(e.end?.dateTime), dia_inteiro: !!e.isAllDay,
        assunto: particular ? "Compromisso particular" : String(e.subject ?? "").slice(0, 300),
        local: particular ? "" : String(e.location?.displayName ?? "").slice(0, 200), online: !!e.isOnlineMeeting,
        organizador: particular ? "" : String(e.organizer?.emailAddress?.name ?? "").slice(0, 120), mostrar_como: String(e.showAs ?? ""),
        atualizado_em: new Date().toISOString() };
    });
    // Regrava a janela da pessoa: o que foi apagado ou remarcado no Outlook some daqui também.
    const del = await fetch(`${SB_URL}/rest/v1/agenda_outlook?user_id=eq.${p.id}&inicio=gte.${encodeURIComponent(ini)}&inicio=lt.${encodeURIComponent(fim)}`,
      { method: "DELETE", headers: cab() });
    if (!del.ok) { resultado.falhas++; continue; }
    if (linhas.length) {
      const ins = await fetch(`${SB_URL}/rest/v1/agenda_outlook`, { method: "POST",
        headers: { ...cab(), Prefer: "resolution=merge-duplicates,return=minimal" }, body: JSON.stringify(linhas) });
      if (!ins.ok) { console.error("gravar", p.email, ins.status, (await ins.text()).slice(0, 200)); resultado.falhas++; continue; }
    }
    resultado.lidas++; resultado.compromissos += linhas.length;
  }
  // Limpeza: compromissos com mais de 45 dias saem.
  await fetch(`${SB_URL}/rest/v1/agenda_outlook?inicio=lt.${encodeURIComponent(new Date(agora - 45 * DIA_MS).toISOString())}`, { method: "DELETE", headers: cab() });
  console.log("outlook-agenda", JSON.stringify(resultado));
  return resposta({ ok: true, ...resultado });
});
