/* Salvar no CRM (06/11/2026). Usado pelo Wealth Planning (diagnostico.html) e pelos
   Planos Patrimoniais (patrimonial.html): a pessoa escolhe o cliente, o arquivo gerado
   vai para a ficha dele no CRM (Storage "anexos" + tabela anexos, ver anexos.sql) com a
   origem e uma observação ("Enviado ao cliente em ..."). Quem decide se pode é o banco:
   só aparecem e só aceitam os clientes que a pessoa enxerga no CRM.
   Sem biblioteca: fala direto com a API do Supabase, com a sessão do portal (aw_sessao).
   Uso:
     AdamiCRM.abrir({ titulo, cliente: "nome sugerido", opcoes: [
       { id, rotulo, marcado: true, gerar: function(){ return Promise.resolve({ blob, nome, origem }); } } ] });
*/
(function(){
  "use strict";
  var SB_URL = "https://ghxjqmjtmbqzvogwzylo.supabase.co";
  var SB_KEY = "sb_publishable_-M5rRFdjNXtFr1td-NVWPQ_GGkd_liB"; // pública, a mesma do portal
  var LIMITE = 25 * 1024 * 1024;

  function sessao(){ try{ return JSON.parse(localStorage.getItem("aw_sessao") || "null"); }catch(e){ return null; } }
  function renovar(){
    var s = sessao();
    if(!s || !s.refresh_token) return Promise.reject(new Error("Sua sessão expirou. Entre no Hub de novo."));
    return fetch(SB_URL + "/auth/v1/token?grant_type=refresh_token", {
      method: "POST", headers: { apikey: SB_KEY, "Content-Type": "application/json" },
      body: JSON.stringify({ refresh_token: s.refresh_token })
    }).then(function(r){
      if(!r.ok) throw new Error("Sua sessão expirou. Entre no Hub de novo.");
      return r.json();
    }).then(function(j){
      s.access_token = j.access_token; s.refresh_token = j.refresh_token;
      if(j.expires_at) s.expires_at = j.expires_at;
      try{ localStorage.setItem("aw_sessao", JSON.stringify(s)); }catch(e){}
    });
  }
  function chamar(url, opts, jaTentou){
    var s = sessao();
    var h = { apikey: SB_KEY, Authorization: "Bearer " + ((s && s.access_token) || SB_KEY) };
    Object.keys(opts.headers || {}).forEach(function(k){ h[k] = opts.headers[k]; });
    return fetch(SB_URL + url, { method: opts.method || "GET", headers: h, body: opts.body }).then(function(r){
      if(r.status === 401 && !jaTentou) return renovar().then(function(){ return chamar(url, opts, true); });
      if(!r.ok) return r.text().then(function(t){
        var j = null; try{ j = JSON.parse(t); }catch(e){}
        var m = (j && (j.message || j.msg || j.error)) || t || ("HTTP " + r.status);
        if(/anexos|relation|bucket not found|schema cache/i.test(m)) m = "Os arquivos do CRM ainda não estão ligados: falta rodar o anexos.sql no Supabase.";
        throw new Error(m);
      });
      return r.status === 204 ? null : r.text().then(function(t){ return t ? JSON.parse(t) : null; });
    });
  }
  function uuid(){
    if(window.crypto && crypto.randomUUID) return crypto.randomUUID();
    return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, function(c){ var r = Math.random() * 16 | 0; return (c === "x" ? r : (r & 3 | 8)).toString(16); });
  }
  function semAcento(s){ return String(s || "").normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase(); }
  function nomeSeguro(n){ return String(n).normalize("NFD").replace(/[̀-ͯ]/g, "").replace(/[^A-Za-z0-9._-]+/g, "_").slice(-80) || "arquivo"; }
  function esc(s){ return String(s == null ? "" : s).replace(/[&<>"]/g, function(c){ return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]; }); }
  function nomeCliente(l){ var n = (l.cliente || "").trim(), c = (l.conta || "").trim(); return !c ? n : (!n ? c : (n.slice(-c.length) === c ? n : n + " · " + c)); }

  function clientes(){
    return chamar("/rest/v1/leads?select=id,cliente,conta&excluido=eq.false&perdido=eq.false&funil=eq.assessor&order=cliente.asc", {});
  }
  function enviar(lead, arq, nota){
    if(!arq.blob || !arq.blob.size) return Promise.reject(new Error(arq.nome + " saiu vazio."));
    if(arq.blob.size > LIMITE) return Promise.reject(new Error(arq.nome + " passou de 25 MB."));
    var s = sessao(); var eu = s && s.id;
    var caminho = lead.id + "/" + uuid() + "-" + nomeSeguro(arq.nome);
    var tipo = arq.blob.type || "application/octet-stream";
    return chamar("/storage/v1/object/anexos/" + caminho.split("/").map(encodeURIComponent).join("/"), {
      method: "POST", headers: { "Content-Type": tipo, "x-upsert": "false" }, body: arq.blob
    }).then(function(){
      return chamar("/rest/v1/anexos", {
        method: "POST", headers: { "Content-Type": "application/json", Prefer: "return=representation" },
        body: JSON.stringify({ lead_id: lead.id, nome: String(arq.nome).slice(0, 200), caminho: caminho, tamanho: arq.blob.size,
          tipo: tipo, origem: arq.origem, nota: String(nota || "").slice(0, 500), enviado_por: eu })
      }).catch(function(e){
        return chamar("/storage/v1/object/anexos", { method: "DELETE", headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ prefixes: [caminho] }) }).then(function(){ throw e; }, function(){ throw e; });
      });
    });
  }

  var CSS = ".acrm-fundo{position:fixed;inset:0;z-index:100000;background:rgba(5,19,42,.38);display:flex;align-items:flex-start;justify-content:center;padding:6vh 16px;overflow:auto;font-family:Inter,'Segoe UI',system-ui,sans-serif}" +
    ".acrm{width:100%;max-width:520px;background:#fff;border-radius:20px;box-shadow:0 24px 60px rgba(5,19,42,.28);color:#0C1626;overflow:hidden}" +
    ".acrm-cab{display:flex;justify-content:space-between;align-items:center;padding:18px 22px;border-bottom:1px solid #E2E6ED}" +
    ".acrm-cab h2{margin:0;font:600 17px Georgia,serif;color:#05132A}" +
    ".acrm-x{border:0;background:none;font-size:22px;line-height:1;color:#5C6B7F;cursor:pointer;width:36px;height:36px;border-radius:8px}" +
    ".acrm-corpo{padding:18px 22px;display:flex;flex-direction:column;gap:14px}" +
    ".acrm label.t{display:block;font-size:11px;font-weight:600;letter-spacing:.06em;text-transform:uppercase;color:#5C6B7F;margin-bottom:6px}" +
    ".acrm input[type=text],.acrm textarea{width:100%;box-sizing:border-box;border:1px solid #E2E6ED;border-radius:10px;padding:10px 12px;font:14px Inter,'Segoe UI',sans-serif;color:#0C1626;background:#fff}" +
    ".acrm textarea{min-height:56px;resize:vertical}" +
    ".acrm-lista{max-height:210px;overflow:auto;border:1px solid #E2E6ED;border-radius:10px;margin-top:6px}" +
    ".acrm-cli{display:block;width:100%;text-align:left;border:0;border-top:1px solid #EEF1F5;background:#fff;padding:9px 12px;font:13.5px Inter,'Segoe UI',sans-serif;color:#0C1626;cursor:pointer}" +
    ".acrm-cli:first-child{border-top:0}.acrm-cli:hover{background:#F4F6F9}.acrm-cli.on{background:#05132A;color:#fff}" +
    ".acrm-op{display:flex;gap:10px;align-items:center;font-size:14px;padding:4px 0}.acrm-op input{width:18px;height:18px}" +
    ".acrm-msg{font-size:13px;line-height:1.45;padding:10px 12px;border-radius:10px}.acrm-msg.erro{background:#FBEBEA;color:#8E2B25}.acrm-msg.ok{background:#E6F1EC;color:#1F6B47}" +
    ".acrm-pe{display:flex;justify-content:flex-end;gap:8px;padding:14px 22px;border-top:1px solid #E2E6ED}" +
    ".acrm-bt{height:40px;padding:0 18px;border-radius:999px;border:1px solid #E2E6ED;background:#fff;color:#0C1626;font:600 13.5px Inter,'Segoe UI',sans-serif;cursor:pointer}" +
    ".acrm-bt.p{background:#05132A;border-color:#05132A;color:#fff}.acrm-bt:disabled{opacity:.55;cursor:default}" +
    ".acrm-faixa{position:sticky;top:0;z-index:9990;display:flex;gap:14px;align-items:center;flex-wrap:wrap;padding:10px 18px;background:#F7F0DC;color:#5A4712;border-bottom:1px solid #E8D9AE;font:13px Inter,'Segoe UI',system-ui,sans-serif}" +
    ".acrm-faixa span{flex:1;min-width:220px}.acrm-faixa b{color:#3E300A}.acrm-faixa a{color:#12263F;font-weight:600}" +
    ".acrm-faixa button{border:0;background:none;font-size:20px;line-height:1;color:#5A4712;cursor:pointer;width:30px;height:30px;border-radius:8px}" +
    "html[data-cor=noite] .acrm-faixa{background:#2A2516;color:#E9DDB8;border-color:#4A3F22}html[data-cor=noite] .acrm-faixa b{color:#F3E7C4}html[data-cor=noite] .acrm-faixa a{color:#E1C27A}html[data-cor=noite] .acrm-faixa button{color:#E9DDB8}" +
    "@media print{.acrm-fundo,.acrm-faixa{display:none!important}}";

  function abrir(cfg){
    if(!document.getElementById("acrm-css")){ var st = document.createElement("style"); st.id = "acrm-css"; st.textContent = CSS; document.head.appendChild(st); }
    var hoje = new Date().toLocaleDateString("pt-BR");
    var estado = { lista: null, escolhido: null, busca: cfg.cliente || "", erro: "", ok: "", salvando: false };
    var fundo = document.createElement("div"); fundo.className = "acrm-fundo";
    fundo.innerHTML = '<div class="acrm" role="dialog" aria-modal="true" aria-label="' + esc(cfg.titulo || "Salvar no CRM") + '">' +
      '<div class="acrm-cab"><h2>' + esc(cfg.titulo || "Salvar no CRM") + '</h2><button type="button" class="acrm-x" aria-label="Fechar">&times;</button></div>' +
      '<div class="acrm-corpo">' +
        '<div><label class="t" for="acrmBusca">Cliente</label><input type="text" id="acrmBusca" autocomplete="off" placeholder="Digite o nome ou a conta"><div class="acrm-lista" id="acrmLista"><div class="acrm-cli" style="cursor:default">Carregando clientes…</div></div></div>' +
        '<div><span class="t" style="display:block;font-size:11px;font-weight:600;letter-spacing:.06em;text-transform:uppercase;color:#5C6B7F;margin-bottom:6px">O que salvar</span>' +
          cfg.opcoes.map(function(o, i){ return '<label class="acrm-op"><input type="checkbox" data-op="' + i + '"' + (o.marcado === false ? "" : " checked") + '> ' + esc(o.rotulo) + '</label>'; }).join("") + '</div>' +
        '<div><label class="t" for="acrmNota">Observação</label><textarea id="acrmNota" maxlength="500">Enviado ao cliente em ' + hoje + '.</textarea></div>' +
        '<div id="acrmMsg"></div>' +
      '</div>' +
      '<div class="acrm-pe"><button type="button" class="acrm-bt" id="acrmFechar">Fechar</button><button type="button" class="acrm-bt p" id="acrmSalvar">Salvar no CRM</button></div></div>';
    document.body.appendChild(fundo);
    var $ = function(id){ return fundo.querySelector("#" + id); };
    var fechar = function(){ document.removeEventListener("keydown", tecla); fundo.remove(); };
    var tecla = function(e){ if(e.key === "Escape") fechar(); };
    document.addEventListener("keydown", tecla);
    fundo.querySelector(".acrm-x").onclick = fechar; $("acrmFechar").onclick = fechar;
    fundo.onclick = function(e){ if(e.target === fundo) fechar(); };
    var busca = $("acrmBusca"); busca.value = estado.busca;
    function msg(){ $("acrmMsg").innerHTML = estado.erro ? '<div class="acrm-msg erro" role="alert">' + esc(estado.erro) + '</div>' : (estado.ok ? '<div class="acrm-msg ok" role="status">' + esc(estado.ok) + '</div>' : ""); }
    function lista(){
      var el = $("acrmLista");
      if(estado.lista === null) return;
      var q = semAcento(busca.value).trim();
      var itens = estado.lista.filter(function(l){ return !q || semAcento(nomeCliente(l)).indexOf(q) !== -1; }).slice(0, 60);
      if(!itens.length){ el.innerHTML = '<div class="acrm-cli" style="cursor:default">Nenhum cliente com esse nome na sua carteira.</div>'; return; }
      el.innerHTML = itens.map(function(l){ return '<button type="button" class="acrm-cli' + (estado.escolhido && estado.escolhido.id === l.id ? " on" : "") + '" data-id="' + esc(l.id) + '">' + esc(nomeCliente(l)) + '</button>'; }).join("");
      [].forEach.call(el.querySelectorAll("button[data-id]"), function(b){
        b.onclick = function(){ estado.escolhido = estado.lista.filter(function(l){ return l.id === b.getAttribute("data-id"); })[0]; estado.erro = ""; msg(); lista(); };
      });
    }
    busca.oninput = lista;
    clientes().then(function(l){
      estado.lista = l || [];
      var q = semAcento(cfg.cliente).trim();
      var alvo = cfg.leadId || leadIdDaUrl();
      var porId = alvo ? estado.lista.filter(function(x){ return x.id === alvo; }) : [];
      var exatos = q ? estado.lista.filter(function(x){ return semAcento(x.cliente).trim() === q; }) : [];
      if(porId.length === 1){ estado.escolhido = porId[0]; busca.value = nomeCliente(porId[0]); }
      else if(exatos.length === 1) estado.escolhido = exatos[0];
      lista(); busca.focus();
    }).catch(function(e){ estado.lista = []; estado.erro = e.message; msg(); $("acrmLista").innerHTML = ""; });
    $("acrmSalvar").onclick = function(){
      if(estado.salvando) return;
      if(!estado.escolhido){ estado.erro = "Escolha o cliente na lista."; estado.ok = ""; msg(); return; }
      var marcadas = [].filter.call(fundo.querySelectorAll("input[data-op]"), function(c){ return c.checked; }).map(function(c){ return cfg.opcoes[+c.getAttribute("data-op")]; });
      if(!marcadas.length){ estado.erro = "Marque pelo menos um documento."; msg(); return; }
      var nota = $("acrmNota").value.trim();
      var bt = $("acrmSalvar"); bt.disabled = true; estado.salvando = true; estado.erro = ""; estado.ok = "";
      var feitos = [];
      var passo = Promise.resolve();
      marcadas.forEach(function(o){
        passo = passo.then(function(){
          bt.textContent = "Gerando " + o.rotulo + "…";
          return o.gerar();
        }).then(function(arq){
          bt.textContent = "Enviando…";
          return enviar(estado.escolhido, arq, nota).then(function(){ feitos.push(arq.nome); });
        });
      });
      passo.then(function(){
        estado.ok = "Salvo na ficha de " + nomeCliente(estado.escolhido) + " no CRM: " + feitos.join(", ") + ".";
        msg(); bt.textContent = "Salvo"; estado.salvando = false;
        if(cfg.aoSalvar) try{ cfg.aoSalvar(estado.escolhido); }catch(e){}
      }).catch(function(e){
        estado.erro = (feitos.length ? "Salvo: " + feitos.join(", ") + ". " : "") + "Não foi possível salvar: " + e.message;
        msg(); bt.disabled = false; bt.textContent = "Tentar de novo"; estado.salvando = false;
      });
    };
  }
  /* ===== Ficha do CRM -> ferramenta já preenchida (3.10) =====
     A ficha do cliente no CRM abre as ferramentas com ?lead=ID. Aqui a ferramenta lê o
     cliente (o banco só devolve se a pessoa enxerga esse cliente no CRM), preenche só os
     campos que estão vazios e mostra de onde vieram os dados. */
  function leadIdDaUrl(){
    try{ var v = new URLSearchParams(location.search).get("lead"); return v && /^[\w-]{1,80}$/.test(v) ? v : null; }
    catch(e){ return null; }
  }
  var CAMPOS_LEAD = "id,cliente,conta,nascimento,profissao,estado_civil,segmento,tipo_pessoa,grupo_familiar,esteira,ganho,perdido,funil," +
    "saldo_inicial,saldo_inicial_offshore,valor_potencial,valor_fechado,valor_offshore,movimentacoes,patrimonio,renda";
  function leadDaUrl(){
    var id = leadIdDaUrl();
    if(!id) return Promise.resolve(null);
    return chamar("/rest/v1/leads?select=" + CAMPOS_LEAD + "&id=eq." + encodeURIComponent(id) + "&excluido=eq.false", {})
      .then(function(r){ return (r && r[0]) || null; }).catch(function(){ return null; });
  }
  function valor(v){
    if(v === null || v === undefined || v === "") return null;
    if(typeof v === "number") return isFinite(v) ? v : null;
    var t = String(v).trim().toLowerCase(), mult = 1;
    if(/\bmi(lh|l)?(ão|ões|ao|oes)?\b|\bmm\b|\bmi\b/.test(t) && !/\bmil\b/.test(t)) mult = 1e6;
    else if(/\bmil\b|\d\s*k\b/.test(t)) mult = 1e3;
    var n = Number(t.replace(/[^\d.,-]/g, "").replace(/\.(?=\d{3}(\D|$))/g, "").replace(",", "."));
    return isNaN(n) || !t.match(/\d/) ? null : n * mult;
  }
  function idade(nasc){
    if(!nasc || !/^\d{4}-\d{2}-\d{2}/.test(nasc)) return null;
    var h = new Date(), d = new Date(nasc.slice(0, 10) + "T12:00:00");
    var a = h.getFullYear() - d.getFullYear();
    if(h.getMonth() < d.getMonth() || (h.getMonth() === d.getMonth() && h.getDate() < d.getDate())) a--;
    return a > 0 && a < 120 ? a : null;
  }
  /* Patrimônio onshore: o mesmo número do CRM para quem já é cliente (saldo + movimentações);
     para prospect, o patrimônio estimado da ficha. */
  function patrimonio(l){
    if(!l) return null;
    var base = l.esteira === "base", cliente = base || l.ganho;
    var ini = cliente ? (base ? valor(l.saldo_inicial) : (valor(l.valor_fechado) || valor(l.valor_potencial))) : null;
    if(ini !== null){
      var mov = (l.movimentacoes || []).reduce(function(acc, m){
        if((m && m.custodia) === "offshore") return acc;
        var v = valor(m && m.valor); return acc + (v === null ? 0 : v * (m.tipo === "retirada" ? -1 : 1));
      }, 0);
      return Math.max(0, ini + mov);
    }
    return valor(l.valor_potencial) || valor(l.patrimonio);
  }
  function dadosLead(l){
    if(!l) return null;
    return { id: l.id, nome: (l.cliente || "").trim(), conta: l.conta || "", idade: idade(l.nascimento),
      profissao: l.profissao || "", estadoCivil: l.estado_civil || "", segmento: l.segmento || "",
      patrimonio: patrimonio(l), renda: valor(l.renda) };
  }
  function brl(n){ return "R$ " + Math.round(n).toLocaleString("pt-BR"); }
  /* campos: [[id, valor, "moeda"|"numero"|"texto"]]. Só escreve em campo vazio ou no valor
     padrão da página (data-padrao ou o value original do HTML). */
  function preencher(campos){
    var n = 0;
    campos.forEach(function(c){
      var el = document.getElementById(c[0]), v = c[1];
      if(!el || v === null || v === undefined || v === "") return;
      var atual = String(el.value || "").trim();
      var padrao = String(el.defaultValue || "").trim();
      if(atual && atual !== padrao) return;
      var txt = c[2] === "moeda" ? brl(v) : String(v);
      if(el.tagName === "SELECT"){
        var alvo = semAcento(txt), op = [].filter.call(el.options, function(o){ return semAcento(o.text) === alvo || semAcento(o.value) === alvo; })[0];
        if(!op) return; el.value = op.value;
      } else el.value = txt;
      el.dispatchEvent(new Event("input", { bubbles: true }));
      el.dispatchEvent(new Event("change", { bubbles: true }));
      n++;
    });
    return n;
  }
  function faixa(d, quantos){
    if(!d || document.getElementById("acrmFaixa")) return;
    if(!document.getElementById("acrm-css")){ var st = document.createElement("style"); st.id = "acrm-css"; st.textContent = CSS; document.head.appendChild(st); }
    var f = document.createElement("div"); f.id = "acrmFaixa"; f.className = "acrm-faixa"; f.setAttribute("role", "status");
    f.innerHTML = '<span><b>' + esc(d.nome || "Cliente") + '</b> · ' + (quantos ? quantos + ' campo(s) preenchido(s) com os dados da ficha no CRM. Confira antes de apresentar.' : 'aberto a partir da ficha no CRM.') + '</span>' +
      '<a href="crm.html#ficha=' + encodeURIComponent(d.id) + '">Voltar para a ficha</a><button type="button" aria-label="Fechar aviso">&times;</button>';
    f.querySelector("button").onclick = function(){ f.remove(); };
    document.body.insertBefore(f, document.body.firstChild);
  }
  /* Uso: AdamiCRM.daFicha(function(d){ return [["nome", d.nome, "texto"], ...]; }) */
  function daFicha(montar){
    return leadDaUrl().then(function(l){
      var d = dadosLead(l); if(!d) return null;
      var n = 0; try{ n = preencher(montar(d) || []); }catch(e){}
      faixa(d, n);
      return d;
    });
  }

  /* ===== PDF a partir dos blocos da tela (3.10) =====
     Mesma técnica do Wealth Planning: cada bloco vira uma imagem numa folha A4, bloco que
     não cabe vai para a folha seguinte, bloco maior que a folha é cortado. Botões (.acoes,
     button) ficam fora da imagem. */
  function carregar(src){
    return new Promise(function(ok, erro){
      if(document.querySelector('script[data-acrm="' + src + '"]')) return ok();
      var s = document.createElement("script"); s.src = src; s.setAttribute("data-acrm", src);
      s.onload = function(){ ok(); }; s.onerror = function(){ erro(new Error("Não foi possível carregar " + src)); };
      document.head.appendChild(s);
    });
  }
  function pdfDeBlocos(blocos, nome, origem){
    return carregar("vendor/jspdf-2.5.1.umd.min.js").then(function(){ return carregar("vendor/html2canvas-1.4.1.min.js"); }).then(function(){
      var lista = [].filter.call(blocos, function(e){ return e && e.offsetHeight > 0; });
      if(!lista.length) throw new Error("Nada para salvar: preencha a ferramenta antes.");
      var pdf = new window.jspdf.jsPDF({ unit: "mm", format: "a4" });
      var M = 12, W = 186, H = 273, y = M, primeira = true;
      var passo = Promise.resolve();
      lista.forEach(function(el){
        passo = passo.then(function(){
          return window.html2canvas(el, { scale: 2, backgroundColor: "#ffffff", logging: false,
            ignoreElements: function(n){ return n.classList && (n.classList.contains("acoes") || n.tagName === "BUTTON" || n.id === "awVoltar"); } });
        }).then(function(cv){
          var alt = cv.height * W / cv.width;
          if(!primeira && y + alt > M + H && y > M){ pdf.addPage(); y = M; }
          if(alt <= H - (y - M)){ pdf.addImage(cv.toDataURL("image/jpeg", 0.9), "JPEG", M, y, W, alt); y += alt + 4; }
          else {
            var pxmm = cv.width / W, feito = 0;
            while(feito < cv.height){
              var fatia = Math.min(Math.floor((M + H - y) * pxmm), cv.height - feito);
              var c2 = document.createElement("canvas"); c2.width = cv.width; c2.height = fatia;
              c2.getContext("2d").drawImage(cv, 0, feito, cv.width, fatia, 0, 0, cv.width, fatia);
              pdf.addImage(c2.toDataURL("image/jpeg", 0.9), "JPEG", M, y, W, fatia / pxmm);
              feito += fatia; y += fatia / pxmm;
              if(feito < cv.height){ pdf.addPage(); y = M; }
            }
            y += 4;
          }
          primeira = false;
        });
      });
      return passo.then(function(){
        var d = new Date(), dd = String(d.getDate()).padStart(2, "0") + "-" + String(d.getMonth() + 1).padStart(2, "0") + "-" + d.getFullYear();
        return { blob: pdf.output("blob"), nome: String(nome).replace(/[^\wÀ-ÿ .-]/g, "").replace(/\s+/g, "_") + "_" + dd + ".pdf", origem: origem };
      });
    });
  }

  window.AdamiCRM = { abrir: abrir, enviar: enviar, clientes: clientes, leadDaUrl: leadDaUrl, leadIdDaUrl: leadIdDaUrl, dadosLead: dadosLead,
    preencher: preencher, daFicha: daFicha, faixa: faixa, pdfDeBlocos: pdfDeBlocos, valor: valor };
})();
