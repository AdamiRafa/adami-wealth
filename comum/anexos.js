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
    "@media print{.acrm-fundo{display:none!important}}";

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
      var exatos = q ? estado.lista.filter(function(x){ return semAcento(x.cliente).trim() === q; }) : [];
      if(exatos.length === 1) estado.escolhido = exatos[0];
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
  window.AdamiCRM = { abrir: abrir };
})();
