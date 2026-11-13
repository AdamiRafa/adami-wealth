/* Barra comum do Hub Adami (3.10, 12/11/2026).
   Um botão redondo no canto inferior direito de todos os módulos, que abre um painel com:
   - Busca (Ctrl+K ou Cmd+K): clientes do CRM, carteiras e ferramentas. Abre a ficha
     (crm.html#ficha=ID), o relatório (index.html#carteira=ID) ou a ferramenta.
   - Ajuda desta tela: o essencial do módulo e o link para a página certa do manual.
   - Reportar problema: texto + foto da tela + versão + últimos erros do navegador,
     gravados no banco (tabela problemas, bucket privado "problemas"). Só o master lê.
   Quem decide o que cada pessoa vê é o banco: a busca devolve só os clientes que a
   pessoa enxerga no CRM e nas Carteiras.
   Carregado no <head> de cada módulo, depois do comum/sessao.js. Sem biblioteca. */
(function(){
  "use strict";
  if(window.AWBarra) return;
  var SB_URL = "https://ghxjqmjtmbqzvogwzylo.supabase.co";
  var SB_KEY = "sb_publishable_-M5rRFdjNXtFr1td-NVWPQ_GGkd_liB"; // pública, a mesma do portal
  var MANUAL = "ajuda/Manual-do-Hub.pdf";

  /* ---------- Erros do navegador (para o Reportar problema) ---------- */
  var ERROS = [];
  function guardaErro(txt){
    ERROS.push({ em: new Date().toISOString(), msg: String(txt || "").slice(0, 400) });
    if(ERROS.length > 12) ERROS.shift();
  }
  window.addEventListener("error", function(e){
    guardaErro((e && e.message ? e.message : "erro") + (e && e.filename ? " @ " + String(e.filename).split("/").pop() + ":" + e.lineno : ""));
  });
  window.addEventListener("unhandledrejection", function(e){
    var r = e && e.reason; guardaErro("promessa: " + (r && r.message ? r.message : String(r)));
  });

  /* ---------- Onde estou ---------- */
  var ARQ = (location.pathname.split("/").pop() || "index.html").toLowerCase();
  function moduloAtual(){
    if(ARQ === "index.html" || ARQ === "") return (window.S && window.S.app === "carteiras") ? "carteiras" : "inicio";
    return ARQ.replace(/\.html$/, "");
  }
  /* Ajuda de cada tela. "pag" é a página do capítulo no PDF do manual. */
  var AJUDA = {
    inicio: { nome: "Tela inicial", pag: 10, itens: [
      "Os números do alto são os mesmos do Dashboard do CRM. Clique para abrir o CRM.",
      "Hoje mostra as tarefas da Agenda do CRM. Clique num dia do calendário para ver o que há nele.",
      "Avisos da casa: abra e clique em Marcar como lido.",
      "Segurança (menu da esquerda): ligue o app autenticador para não depender do e-mail."] },
    carteiras: { nome: "Carteiras", pag: 23, itens: [
      "Escolha o cliente à esquerda e o mês no alto (setas ou calendário). Ponto verde: mês feito; amarelo: falta marcar.",
      "Preencher: arraste o Relatório de Performance do BTG (PDF) na área do alto. Ele preenche a conta do BTG, todos os ativos com a rentabilidade, os índices e os próximos vencimentos.",
      "A Conferência mostra o que não bate. Clique no nome para ir direto ao ativo; marque Conferido no que já viu. Com tudo certo, Salvar e marcar como feito.",
      "Fechamento (administração): todos os clientes do mês numa tela, com o que falta em cada um. Importar extratos de vários clientes sobe vários PDFs de uma vez.",
      "Relatório: confira com Conferir dados e use Gerar PDF. O arquivo sai com o nome do cliente e do mês.",
      "Enviar ao cliente (no Relatório): manda o PDF por e-mail, só com o mês marcado como feito. O e-mail do cliente fica no Preencher.",
      "PDF de todos faz os relatórios do mês de todos os seus clientes, um arquivo por cliente.",
      "Os números vêm do lançamento do mês, feito pela administração na aba Preencher."] },
    crm: { nome: "CRM", pag: 14, itens: [
      "Toda conversa com cliente vira uma atividade na ficha, e todo cliente em jornada tem um próximo contato.",
      "Na ficha, Ferramentas para este cliente abre o Wealth Planning, a Liberdade Financeira e o relatório já preenchidos.",
      "Arraste o cartão para a próxima etapa quando a reunião acontecer.",
      "Agenda: tarefas, próximos contatos e vencimentos. Pode ser compartilhada com a equipe."] },
    processo: { nome: "Processo Comercial", pag: 21, itens: [
      "Segmentos: Advisory até R$ 1 mi, Exclusive de R$ 1 a 5 mi, Private acima de R$ 5 mi.",
      "Trilha do cliente novo: R1 Descoberta, R2 Proposta, R2.1 Consolidação, R3 Liberdade Financeira, R4 Produto.",
      "Cliente da base começa na R2 (Entrada)."] },
    diagnostico: { nome: "Wealth Planning", pag: 28, itens: [
      "Preencha à esquerda; o relatório se monta sozinho à direita.",
      "Aberto pela ficha do CRM, nome, idade e patrimônio já vêm preenchidos. Confira.",
      "Salvar no CRM grava o PDF na ficha do cliente.",
      "As projeções são estimativas em valores de hoje e não garantem resultado."] },
    patrimonial: { nome: "Planos Patrimoniais", pag: 32, itens: [
      "Preencha as seções à esquerda e confira o quadro Consistência.",
      "Plano Patrimonial e Análise de Enquadramento saem em Word.",
      "Salvar JSON guarda o preenchimento para continuar depois."] },
    imobiliario: { nome: "Relatório Imobiliário", pag: 34, itens: [
      "Cliente, Imóveis, Projetos e Histórico, nessa ordem; o que falta aparece em vermelho.",
      "Muitos imóveis: Baixar modelo, preencher a planilha e Importar planilha.",
      "Gerar PPTX cria a apresentação. Salvar projeto guarda para o mês seguinte."] },
    alocacao: { nome: "Política de Alocação", pag: 35, itens: [
      "Material do comitê do mês. Escolha o mês e use Baixar PDF.",
      "Leia as Alterações no mês: é o que muda na conversa com os clientes."] },
    rv: { nome: "Mesa RV", pag: 36, itens: [
      "Escolha o tipo de operação, preencha os campos e confira a prévia do card.",
      "Baixar imagem para o grupo ou Copiar imagem para colar no WhatsApp.",
      "Registrar e encerrar no histórico é com a Mesa RV."] },
    boletas: { nome: "Controle de Boletas", pag: 37, itens: [
      "Informe o cliente e o valor disponível; cada ativo boletado atualiza o quanto falta alocar.",
      "Copiar resumo para mandar à mesa. Salvar no CRM grava o PDF na ficha."] },
    liberdade: { nome: "Liberdade Financeira", pag: 38, itens: [
      "Tudo em valores reais, já descontada a inflação.",
      "Aberta pela ficha do CRM, nome, idade e patrimônio já vêm preenchidos.",
      "Salvar no CRM grava a simulação em PDF na ficha do cliente."] },
    agio: { nome: "Ágio e Troca de Ativos", pag: 38, itens: [
      "Ativo atual: valor na curva e taxa. Ativo novo: valor que será aplicado e a taxa nova.",
      "O resultado mostra em quantos meses a taxa nova compensa o deságio."] },
    simulador: { nome: "Simulador de Receita RV", pag: 38, itens: [
      "Para swing trade e estruturadas: clientes, volume por cliente, ordens e ROA.",
      "Os cartões do alto mostram a receita do escritório, a sua e quanto da meta está coberto."] },
    "minha-comissao": { nome: "Minha comissão", pag: 41, itens: [
      "Aparece depois que o Financeiro fecha e libera o mês.",
      "Por categoria ou por cliente; clique numa linha para ver o detalhe.",
      "Dúvida em algum valor: anote cliente, conta e produto e fale com o Financeiro."] },
    comissoes: { nome: "Comissões", pag: 2, itens: [
      "Módulo do Financeiro: planilhas do mês, regras, fechamento e pagamentos."] },
    fluxo: { nome: "Fluxo e Captação", pag: 2, itens: [
      "Mapa das movimentações do BTG, base do comitê de alocação. Acesso só master."] }
  };
  var FERRAMENTAS = [
    ["Início do Hub", "index.html", "hub inicio tela inicial"],
    ["CRM", "crm.html", "crm clientes jornada agenda negocios dashboard"],
    ["Agenda", "crm.html#agenda", "agenda tarefas compromissos"],
    ["Carteiras e relatórios", "index.html#carteiras", "carteiras relatorio consolidado"],
    ["Processo Comercial", "processo.html", "processo comercial trilha r1 r2 r3 r4"],
    ["Wealth Planning", "diagnostico.html", "wealth planning diagnostico sucessao protecao"],
    ["Planos Patrimoniais", "patrimonial.html", "plano patrimonial enquadramento"],
    ["Relatório Imobiliário", "imobiliario.html", "imobiliario imoveis"],
    ["Política de Alocação", "alocacao.html", "politica alocacao comite"],
    ["Mesa RV", "rv.html", "mesa rv renda variavel acoes"],
    ["Controle de Boletas", "boletas.html", "boletas"],
    ["Liberdade Financeira", "liberdade.html", "liberdade financeira aposentadoria"],
    ["Ágio e Troca de Ativos", "agio.html", "agio desagio troca"],
    ["Simulador de Receita RV", "simulador.html", "simulador receita rv"],
    ["Minha comissão", "minha-comissao.html", "minha comissao"]
  ];

  /* ---------- Sessão e API ---------- */
  function hoje(){
    try{ return new Date().toLocaleDateString("en-CA", { timeZone: "America/Sao_Paulo" }); }
    catch(e){ return new Date(Date.now() - 3 * 3600 * 1000).toISOString().slice(0, 10); }
  }
  function sessao(){ try{ return JSON.parse(localStorage.getItem("aw_sessao") || "null"); }catch(e){ return null; } }
  function logado(){ var s = sessao(); return !!(s && s.access_token && s.dia === hoje()); }
  /* No CRM quem renova o token é o próprio CRM; nas outras telas, aqui. */
  function renovar(){
    var s = sessao();
    if(ARQ === "crm.html" || !s || !s.refresh_token) return Promise.reject(new Error("Sua sessão expirou. Recarregue a página."));
    return fetch(SB_URL + "/auth/v1/token?grant_type=refresh_token", {
      method: "POST", headers: { apikey: SB_KEY, "Content-Type": "application/json" },
      body: JSON.stringify({ refresh_token: s.refresh_token })
    }).then(function(r){ if(!r.ok) throw new Error("Sua sessão expirou. Entre no Hub de novo."); return r.json(); })
      .then(function(j){
        var atual = sessao() || s;
        atual.access_token = j.access_token; atual.refresh_token = j.refresh_token;
        try{ localStorage.setItem("aw_sessao", JSON.stringify(atual)); }catch(e){}
      });
  }
  function chamar(url, opts, jaTentou){
    opts = opts || {};
    var s = sessao();
    var h = { apikey: SB_KEY, Authorization: "Bearer " + ((s && s.access_token) || SB_KEY) };
    Object.keys(opts.headers || {}).forEach(function(k){ h[k] = opts.headers[k]; });
    return fetch(SB_URL + url, { method: opts.method || "GET", headers: h, body: opts.body }).then(function(r){
      if(r.status === 401 && !jaTentou) return renovar().then(function(){ return chamar(url, opts, true); });
      if(!r.ok) return r.text().then(function(t){
        var j = null; try{ j = JSON.parse(t); }catch(e){}
        throw new Error((j && (j.message || j.msg || j.error)) || ("Erro " + r.status));
      });
      return r.text().then(function(t){ return t ? JSON.parse(t) : null; });
    });
  }

  /* ---------- Utilidades ---------- */
  function esc(s){ return String(s == null ? "" : s).replace(/[&<>"']/g, function(c){ return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]; }); }
  function semAcento(s){ return String(s || "").normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase(); }
  function uuid(){
    if(window.crypto && crypto.randomUUID) return crypto.randomUUID();
    return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, function(c){ var r = Math.random() * 16 | 0; return (c === "x" ? r : (r & 3 | 8)).toString(16); });
  }
  function versao(){
    var v = "";
    Object.keys(window).forEach(function(k){ if(!v && /^VERSAO/.test(k) && typeof window[k] === "string") v = window[k]; });
    if(!v){ var m = /vers[aã]o(?: do CRM)? [\d.]+/i.exec(document.body ? document.body.innerText : ""); v = m ? m[0] : ""; }
    return v.slice(0, 80);
  }
  function carregar(src){
    return new Promise(function(ok, erro){
      if(document.querySelector('script[data-awb="' + src + '"]')) return ok();
      var s = document.createElement("script"); s.src = src; s.setAttribute("data-awb", src);
      s.onload = function(){ ok(); }; s.onerror = function(){ erro(new Error("Não foi possível carregar " + src)); };
      document.head.appendChild(s);
    });
  }

  /* ---------- Visual ---------- */
  var CSS =
    ".awb-bt{position:fixed;right:18px;bottom:18px;z-index:99990;width:46px;height:46px;border-radius:50%;border:0;background:#12263F;color:#fff;" +
      "font:600 20px/46px Georgia,serif;cursor:pointer;box-shadow:0 6px 20px rgba(5,19,42,.28);display:flex;align-items:center;justify-content:center}" +
    ".awb-bt:hover{background:#1B3A5F}.awb-bt:focus-visible{outline:3px solid #C0A265;outline-offset:2px}" +
    ".awb-fundo{position:fixed;inset:0;z-index:99995;background:rgba(5,19,42,.32);display:flex;justify-content:flex-end}" +
    ".awb{width:min(420px,100%);height:100%;background:#fff;color:#0C1626;box-shadow:-12px 0 40px rgba(5,19,42,.22);display:flex;flex-direction:column;" +
      "font:14px/1.5 Inter,'Segoe UI',system-ui,sans-serif}" +
    ".awb-cab{display:flex;align-items:center;justify-content:space-between;padding:16px 18px;border-bottom:1px solid #E2E6ED}" +
    ".awb-cab h2{margin:0;font:600 17px Georgia,'Iowan Old Style',serif;color:#05132A}" +
    ".awb-x{border:0;background:none;font-size:24px;line-height:1;width:36px;height:36px;border-radius:8px;color:#5C6B7F;cursor:pointer}" +
    ".awb-corpo{flex:1;overflow:auto;padding:16px 18px 24px;display:flex;flex-direction:column;gap:18px}" +
    ".awb-busca{width:100%;box-sizing:border-box;height:44px;border:1px solid #D5DCE5;border-radius:12px;padding:0 14px;font:15px Inter,'Segoe UI',sans-serif;color:#0C1626;background:#F7F9FB}" +
    ".awb-busca:focus{outline:2px solid #C0A265;outline-offset:1px;background:#fff}" +
    ".awb-dica{font-size:12px;color:#7A8698;margin-top:6px}" +
    ".awb-res{display:flex;flex-direction:column;gap:2px;margin-top:8px}" +
    ".awb-res a,.awb-res .awb-vazio{display:flex;justify-content:space-between;gap:10px;padding:9px 10px;border-radius:10px;color:#0C1626;text-decoration:none;font-size:14px}" +
    ".awb-res a:hover,.awb-res a.on{background:#F1F4F8}.awb-res small{color:#7A8698;font-size:12px;white-space:nowrap}" +
    ".awb-res .awb-grupo{font-size:10.5px;letter-spacing:.14em;text-transform:uppercase;color:#A07F3A;font-weight:600;padding:8px 10px 2px}" +
    ".awb-res .awb-vazio{color:#7A8698}" +
    ".awb h3{margin:0 0 8px;font-size:11px;letter-spacing:.14em;text-transform:uppercase;color:#5C6B7F;font-weight:600}" +
    ".awb ul{margin:0;padding-left:18px}.awb li{margin-bottom:6px;color:#2A3646}" +
    ".awb-links{display:flex;flex-direction:column;gap:8px}" +
    ".awb-link{display:flex;align-items:center;justify-content:center;height:42px;border-radius:999px;border:1px solid #D5DCE5;background:#fff;color:#0C1626;font:600 14px Inter,'Segoe UI',sans-serif;text-decoration:none;cursor:pointer}" +
    ".awb-link.p{background:#12263F;border-color:#12263F;color:#fff}" +
    ".awb textarea{width:100%;box-sizing:border-box;min-height:120px;border:1px solid #D5DCE5;border-radius:12px;padding:10px 12px;font:14px Inter,'Segoe UI',sans-serif;resize:vertical}" +
    ".awb-op{display:flex;gap:10px;align-items:flex-start;font-size:13px;color:#2A3646}.awb-op input{margin-top:3px;width:16px;height:16px}" +
    ".awb-msg{font-size:13px;padding:10px 12px;border-radius:10px}.awb-msg.ok{background:#E6F1EC;color:#1F6B47}.awb-msg.erro{background:#FBEBEA;color:#8E2B25}" +
    ".awb-pe{font-size:11.5px;color:#7A8698}" +
    "html[data-cor=noite] .awb{background:#0F1F33;color:#E6ECF3}html[data-cor=noite] .awb-cab{border-color:rgba(255,255,255,.1)}" +
    "html[data-cor=noite] .awb-cab h2{color:#F3F6FA}html[data-cor=noite] .awb li{color:#C9D3DF}" +
    "html[data-cor=noite] .awb-busca,html[data-cor=noite] .awb textarea{background:#15283F;border-color:rgba(255,255,255,.14);color:#E6ECF3}" +
    "html[data-cor=noite] .awb-res a{color:#E6ECF3}html[data-cor=noite] .awb-res a:hover,html[data-cor=noite] .awb-res a.on{background:rgba(255,255,255,.07)}" +
    "html[data-cor=noite] .awb-link{background:transparent;border-color:rgba(255,255,255,.18);color:#E6ECF3}" +
    "html[data-cor=noite] .awb-link.p{background:#C0A265;border-color:#C0A265;color:#0C1626}html[data-cor=noite] .awb-op{color:#C9D3DF}" +
    "html[data-cor=noite] .awb-x{color:#AAB6C6}html[data-cor=noite] .awb-bt{background:#C0A265;color:#0C1626}" +
    "@media screen and (max-width:640px){.awb-bt{right:12px;bottom:12px;width:42px;height:42px}}" +
    "@media print{.awb-bt,.awb-fundo{display:none!important}}";

  var botao = null, fundo = null, ESTADO = { tela: "inicio", resultados: [], sel: -1, buscaId: 0 };
  function css(){
    if(document.getElementById("awb-css")) return;
    var st = document.createElement("style"); st.id = "awb-css"; st.textContent = CSS; document.head.appendChild(st);
  }
  function montarBotao(){
    if(botao || !document.body) return;
    css();
    botao = document.createElement("button");
    botao.type = "button"; botao.className = "awb-bt"; botao.textContent = "?";
    botao.setAttribute("aria-label", "Ajuda, busca e reportar problema (Ctrl+K)");
    botao.title = "Ajuda, busca e reportar problema (Ctrl+K)";
    botao.onclick = function(){ abrir("inicio"); };
    document.body.appendChild(botao);
    atualizarBotao();
  }
  /* Some enquanto há uma janela aberta na página (ficha do CRM, Salvar no CRM, telas do
     master): no celular ele cobria o botão Fechar. */
  function janelaAberta(){
    var els = document.querySelectorAll(".overlay, .eqv, .acrm-fundo, .modal-backdrop");
    for(var i = 0; i < els.length; i++){ if(els[i].offsetParent !== null || getComputedStyle(els[i]).position === "fixed" && getComputedStyle(els[i]).display !== "none") return true; }
    return false;
  }
  function atualizarBotao(){ if(botao) botao.style.display = logado() && !fundo && !janelaAberta() ? "" : "none"; }

  function abrir(tela){
    if(!logado()) return;
    css();
    if(!fundo){
      fundo = document.createElement("div"); fundo.className = "awb-fundo";
      fundo.onclick = function(e){ if(e.target === fundo) fechar(); };
      document.body.appendChild(fundo);
    }
    ESTADO.tela = tela || "inicio";
    pintar();
    atualizarBotao();
  }
  function fechar(){ if(fundo){ fundo.remove(); fundo = null; } atualizarBotao(); }

  function pintar(){
    if(!fundo) return;
    var mod = moduloAtual(), aj = AJUDA[mod] || AJUDA.inicio;
    var h = '<div class="awb" role="dialog" aria-modal="true" aria-label="Ajuda do Hub">';
    if(ESTADO.tela === "reportar"){
      h += '<div class="awb-cab"><h2>Reportar um problema</h2><button type="button" class="awb-x" data-a="fechar" aria-label="Fechar">&times;</button></div>' +
        '<div class="awb-corpo">' +
          '<div><label for="awbTexto"><h3>O que aconteceu?</h3></label>' +
          '<textarea id="awbTexto" maxlength="4000" placeholder="O que você estava tentando fazer, o que apareceu e o que esperava que acontecesse."></textarea></div>' +
          '<label class="awb-op"><input type="checkbox" id="awbFoto" checked> <span>Incluir uma foto desta tela. Só o master vê. Desmarque se houver algo que não deva ir.</span></label>' +
          '<p class="awb-pe">Vão junto, sem você precisar copiar: a tela (' + esc(aj.nome) + '), a versão (' + esc(versao() || "sem selo") + '), o navegador e os últimos erros registrados. Nunca escreva senha nem código aqui.</p>' +
          '<div id="awbMsg"></div>' +
          '<div class="awb-links"><button type="button" class="awb-link p" id="awbEnviar">Enviar</button>' +
          '<button type="button" class="awb-link" data-a="voltar">Voltar</button></div>' +
        '</div>';
    } else {
      h += '<div class="awb-cab"><h2>Ajuda · ' + esc(aj.nome) + '</h2><button type="button" class="awb-x" data-a="fechar" aria-label="Fechar">&times;</button></div>' +
        '<div class="awb-corpo">' +
          '<div><input type="search" class="awb-busca" id="awbBusca" placeholder="Buscar cliente, conta ou ferramenta" aria-label="Buscar cliente, conta ou ferramenta" autocomplete="off">' +
            '<div class="awb-dica">Atalho: Ctrl+K (no Mac, Cmd+K). Setas e Enter para abrir.</div>' +
            '<div class="awb-res" id="awbRes" role="listbox"></div></div>' +
          '<div><h3>Nesta tela</h3><ul>' + aj.itens.map(function(t){ return "<li>" + esc(t) + "</li>"; }).join("") + '</ul></div>' +
          '<div class="awb-links">' +
            '<a class="awb-link" href="' + MANUAL + '#page=' + aj.pag + '" target="_blank" rel="noopener">Abrir o manual nesta parte</a>' +
            '<button type="button" class="awb-link" data-a="reportar">Reportar um problema</button>' +
          '</div>' +
          '<p class="awb-pe">' + esc(versao()) + '</p>' +
        '</div>';
    }
    h += '</div>';
    fundo.innerHTML = h;
    [].forEach.call(fundo.querySelectorAll("[data-a]"), function(b){
      b.onclick = function(){
        var a = b.getAttribute("data-a");
        if(a === "fechar") fechar();
        else if(a === "reportar"){ ESTADO.tela = "reportar"; pintar(); }
        else if(a === "voltar"){ ESTADO.tela = "inicio"; pintar(); }
      };
    });
    var busca = fundo.querySelector("#awbBusca");
    if(busca){
      busca.oninput = function(){ buscar(busca.value); };
      busca.onkeydown = teclaBusca;
      setTimeout(function(){ busca.focus(); }, 30);
      mostrarResultados();
    }
    var env = fundo.querySelector("#awbEnviar");
    if(env){ env.onclick = enviarProblema; setTimeout(function(){ var t = fundo && fundo.querySelector("#awbTexto"); if(t) t.focus(); }, 30); }
  }

  /* ---------- Busca ---------- */
  var tBusca = null;
  function buscar(txt){
    clearTimeout(tBusca);
    var q = String(txt || "").trim();
    if(q.length < 2){ ESTADO.resultados = []; ESTADO.sel = -1; mostrarResultados(); return; }
    var qs = semAcento(q);
    var ferr = FERRAMENTAS.filter(function(f){ return semAcento(f[0] + " " + f[2]).indexOf(qs) !== -1; }).slice(0, 4)
      .map(function(f){ return { grupo: "Ferramentas", rotulo: f[0], dir: "", url: f[1] }; });
    ESTADO.resultados = ferr; ESTADO.sel = ferr.length ? 0 : -1; mostrarResultados(true);
    var id = ++ESTADO.buscaId;
    tBusca = setTimeout(function(){
      var limpo = q.replace(/[,()*%"'\\:]/g, " ").replace(/\s+/g, " ").trim().slice(0, 60);
      if(limpo.length < 2) return;
      var padrao = "*" + limpo + "*";
      var pLeads = chamar("/rest/v1/leads?select=id,cliente,conta,etapa,funil,ganho,esteira&excluido=eq.false&perdido=eq.false" +
        "&or=" + encodeURIComponent("(cliente.ilike." + padrao + ",conta.ilike." + padrao + ")") + "&order=cliente.asc&limit=8").catch(function(){ return []; });
      var pCart = chamar("/rest/v1/clientes?select=id,nome,contas_btg&nome=ilike." + encodeURIComponent(padrao) + "&order=nome.asc&limit=5").catch(function(){ return []; });
      Promise.all([pLeads, pCart]).then(function(r){
        if(id !== ESTADO.buscaId) return;
        var leads = (r[0] || []).map(function(l){
          return { grupo: "Clientes no CRM", rotulo: l.cliente || l.conta || "Cliente", dir: [l.conta, l.funil === "especialista" ? "negócio" : (l.esteira === "base" ? "carteira" : l.etapa)].filter(Boolean).join(" · "),
            url: "crm.html#ficha=" + encodeURIComponent(l.id) };
        });
        var cart = (r[1] || []).map(function(c){
          return { grupo: "Relatórios (Carteiras)", rotulo: c.nome, dir: (c.contas_btg || []).join(", "), url: "index.html#carteira=" + c.id };
        });
        ESTADO.resultados = ferr.concat(leads, cart);
        if(ESTADO.sel < 0 && ESTADO.resultados.length) ESTADO.sel = 0;
        mostrarResultados();
      });
    }, 250);
  }
  function mostrarResultados(carregando){
    var el = fundo && fundo.querySelector("#awbRes"); if(!el) return;
    var busca = fundo.querySelector("#awbBusca");
    if(!busca || busca.value.trim().length < 2){ el.innerHTML = ""; return; }
    var h = "", grupo = "";
    ESTADO.resultados.forEach(function(r, i){
      if(r.grupo !== grupo){ grupo = r.grupo; h += '<div class="awb-grupo">' + esc(grupo) + "</div>"; }
      h += '<a href="' + esc(r.url) + '" data-i="' + i + '" role="option"' + (i === ESTADO.sel ? ' class="on" aria-selected="true"' : "") + "><span>" + esc(r.rotulo) + "</span><small>" + esc(r.dir) + "</small></a>";
    });
    if(!ESTADO.resultados.length) h = '<div class="awb-vazio">' + (carregando ? "Procurando…" : "Nada encontrado. Tente parte do nome ou o número da conta.") + "</div>";
    else if(carregando) h += '<div class="awb-vazio">Procurando clientes…</div>';
    el.innerHTML = h;
    [].forEach.call(el.querySelectorAll("a[data-i]"), function(a){ a.onclick = function(e){ e.preventDefault(); ir(ESTADO.resultados[+a.getAttribute("data-i")]); }; });
  }
  function teclaBusca(e){
    var n = ESTADO.resultados.length;
    if(e.key === "ArrowDown" && n){ e.preventDefault(); ESTADO.sel = (ESTADO.sel + 1) % n; mostrarResultados(); }
    else if(e.key === "ArrowUp" && n){ e.preventDefault(); ESTADO.sel = (ESTADO.sel - 1 + n) % n; mostrarResultados(); }
    else if(e.key === "Enter" && ESTADO.sel >= 0 && ESTADO.resultados[ESTADO.sel]){ e.preventDefault(); ir(ESTADO.resultados[ESTADO.sel]); }
  }
  /* Mesma página: só troca o endereço (#...) e a página reage; outra página: navega. */
  function ir(r){
    if(!r) return;
    var partes = r.url.split("#"), pagina = partes[0], hash = partes[1] ? "#" + partes[1] : "";
    fechar();
    if(pagina === ARQ && hash){ if(location.hash === hash) window.dispatchEvent(new HashChangeEvent("hashchange")); else location.hash = hash; }
    else location.href = r.url;
  }

  /* ---------- Reportar problema ---------- */
  function msg(t, tipo){ var el = fundo && fundo.querySelector("#awbMsg"); if(el) el.innerHTML = t ? '<div class="awb-msg ' + tipo + '" role="' + (tipo === "erro" ? "alert" : "status") + '">' + esc(t) + "</div>" : ""; }
  function foto(){
    return carregar("vendor/html2canvas-1.4.1.min.js").then(function(){
      var largura = Math.max(document.documentElement.clientWidth, 320);
      var escala = Math.min(1, 1600 / largura);
      return window.html2canvas(document.body, {
        scale: escala, logging: false, useCORS: false, backgroundColor: getComputedStyle(document.body).backgroundColor || "#ffffff",
        x: window.scrollX, y: window.scrollY, width: window.innerWidth, height: window.innerHeight,
        windowWidth: document.documentElement.clientWidth, windowHeight: window.innerHeight,
        ignoreElements: function(n){ return n.classList && (n.classList.contains("awb-fundo") || n.classList.contains("awb-bt")); }
      });
    }).then(function(cv){
      return new Promise(function(ok){ cv.toBlob(function(b){ ok(b); }, "image/jpeg", 0.72); });
    });
  }
  function enviarProblema(){
    var t = (fundo.querySelector("#awbTexto").value || "").trim();
    if(t.length < 3){ msg("Escreva em poucas palavras o que aconteceu.", "erro"); return; }
    var comFoto = fundo.querySelector("#awbFoto").checked;
    var bt = fundo.querySelector("#awbEnviar"); bt.disabled = true; bt.textContent = comFoto ? "Tirando a foto da tela…" : "Enviando…";
    var s = sessao(), uid = s && s.id;
    var registro = { modulo: (AJUDA[moduloAtual()] || {}).nome || moduloAtual(), versao: versao(),
      url: (location.pathname.split("/").pop() || "index.html") + location.hash.replace(/=[^&]*/g, "=…"), navegador: navigator.userAgent.slice(0, 400),
      tela: window.innerWidth + "x" + window.innerHeight, texto: t.slice(0, 4000), erros: ERROS.slice(-12) };
    /* A foto é tirada com o painel escondido, para mostrar a tela como estava. */
    var painel = fundo; painel.style.visibility = "hidden";
    var passo = comFoto && uid ? foto().catch(function(){ return null; }) : Promise.resolve(null);
    passo.then(function(blob){
      painel.style.visibility = "";
      bt.textContent = "Enviando…";
      if(!blob || blob.size > 4 * 1024 * 1024) return null;
      var caminho = uid + "/" + uuid() + ".jpg";
      return chamar("/storage/v1/object/problemas/" + caminho, { method: "POST", headers: { "Content-Type": "image/jpeg", "x-upsert": "false" }, body: blob })
        .then(function(){ return caminho; }).catch(function(){ return null; });
    }).then(function(caminho){
      if(caminho) registro.print_caminho = caminho;
      return chamar("/rest/v1/problemas", { method: "POST", headers: { "Content-Type": "application/json", Prefer: "return=minimal" }, body: JSON.stringify(registro) });
    }).then(function(){
      if(!fundo) return;
      fundo.querySelector("#awbTexto").value = "";
      msg("Recebido. Obrigado! O master vê o problema com a foto e a versão da tela.", "ok");
      bt.textContent = "Enviado";
    }).catch(function(e){
      if(painel) painel.style.visibility = "";
      if(!fundo) return;
      msg("Não foi possível enviar: " + (e && e.message ? e.message : e) + ". Mande um print ao master pelo WhatsApp.", "erro");
      bt.disabled = false; bt.textContent = "Tentar de novo";
    });
  }

  /* ---------- Teclado e ciclo de vida ---------- */
  document.addEventListener("keydown", function(e){
    if((e.ctrlKey || e.metaKey) && !e.altKey && (e.key === "k" || e.key === "K")){
      if(!logado()) return;
      e.preventDefault();
      if(fundo && ESTADO.tela === "inicio") fechar(); else abrir("inicio");
    } else if(e.key === "Escape" && fundo){ fechar(); }
  });
  if(document.readyState === "loading") document.addEventListener("DOMContentLoaded", montarBotao); else montarBotao();
  /* O Hub troca de tela sem recarregar (login, código, início): o botão acompanha. */
  setInterval(atualizarBotao, 700);

  window.AWBarra = { abrir: abrir, fechar: fechar, erros: function(){ return ERROS.slice(); } };
})();
