/* Tutorial em vídeo do primeiro acesso (Hub 3.43). Pedido do Emil: "faz um vídeo de tutorial quando todos acessarem
   o CRM e o Hub pela primeira vez, passando em cada função [...] com uma caixa de não aparecer novamente; enquanto ele
   não selecionar, vai ser apresentada toda vez que ele entrar".
   - Hub: aparece quando a tela inicial (.hb-ola) está na tela. CRM: quando o menu (.mn-item) aparece, depois do login.
   - Toda entrada (uma vez por dia em cada aba) mostra o vídeo, até a pessoa marcar "Não mostrar novamente". A marca fica
     no banco, por pessoa e por módulo (tutorial_marcar / tutorial_vistos, tutorial.sql): vale em qualquer aparelho.
   - Dá para rever a qualquer hora pelo botão ? (Ver o tutorial em vídeo).
   - Os vídeos (ajuda/tutorial-hub.mp4 e ajuda/tutorial-crm.mp4) foram gravados com dados fictícios. */
(function(){
  if(window.AWTutorial) return;
  var VIDEOS = {
    hub: { titulo: "Tutorial do Hub", arq: "ajuda/tutorial-hub.mp4", capa: "ajuda/tutorial-hub.jpg", sub: "Um passeio pelo Hub: a tela inicial, o menu e cada ferramenta." },
    crm: { titulo: "Tutorial do CRM", arq: "ajuda/tutorial-crm.mp4", capa: "ajuda/tutorial-crm.jpg", sub: "Dashboard, Agenda, jornada do cliente, ficha, Minha carteira e Negócios." }
  };
  var ARQ = (location.pathname.split("/").pop() || "index.html").toLowerCase();
  var MOD = ARQ === "crm.html" ? "crm" : (ARQ === "index.html" || ARQ === "") ? "hub" : null;
  var checado = false, aberto = false;

  function hoje(){ try{ return new Date().toLocaleDateString("en-CA", { timeZone: "America/Sao_Paulo" }); }catch(e){ return ""; } }
  function chave(m){ return "aw_tut_" + m + "_" + hoje(); }
  function gravando(){ try{ return localStorage.getItem("aw_tutorial_gravacao") === "1"; }catch(e){ return false; } }
  function api(url, opts){ return window.AWBarra && window.AWBarra.api ? window.AWBarra.api(url, opts) : Promise.reject(new Error("sem API")); }

  var CSS = "@media print{.awt-fundo{display:none!important}}" +
    "@media screen{.awt-fundo{position:fixed;inset:0;z-index:2147482000;background:rgba(5,19,42,.62);display:flex;align-items:center;justify-content:center;padding:16px;" +
    "font-family:Inter,Helvetica,Arial,sans-serif;-webkit-backdrop-filter:blur(4px);backdrop-filter:blur(4px)}" +
    ".awt-caixa{background:#fff;color:#16243A;border-radius:20px;width:min(960px,100%);max-height:calc(100vh - 32px);overflow:auto;box-shadow:0 30px 80px rgba(5,19,42,.45)}" +
    ".awt-cab{display:flex;align-items:flex-start;justify-content:space-between;gap:12px;padding:20px 24px 10px}" +
    ".awt-cab small{display:block;font-size:11px;letter-spacing:.22em;text-transform:uppercase;color:#9A7A3E;font-weight:600;margin-bottom:4px}" +
    ".awt-cab h2{margin:0;font:500 24px Fraunces,Georgia,serif;color:#05132A}.awt-cab p{margin:4px 0 0;color:#5B6676;font-size:14px}" +
    ".awt-x{border:0;background:#EEF2F7;color:#05132A;width:36px;height:36px;border-radius:50%;font-size:20px;cursor:pointer;flex:none}" +
    ".awt-video{padding:0 24px}.awt-video video{display:block;width:100%;border-radius:12px;background:#05132A;aspect-ratio:16/9}" +
    ".awt-pe{display:flex;align-items:center;justify-content:space-between;gap:12px;flex-wrap:wrap;padding:16px 24px 22px}" +
    ".awt-pe label{display:flex;align-items:center;gap:10px;font-size:15px;color:#16243A;cursor:pointer}.awt-pe input{width:18px;height:18px;accent-color:#05132A}" +
    ".awt-ok{border:0;background:#05132A;color:#fff;border-radius:999px;padding:11px 26px;font:600 15px Inter,Helvetica,Arial,sans-serif;cursor:pointer}" +
    ".awt-msg{font-size:13px;color:#B3261E;width:100%}" +
    "html[data-cor=noite] .awt-caixa,body.noite .awt-caixa{background:#0F1E33;color:#E6ECF4}" +
    "html[data-cor=noite] .awt-cab h2,body.noite .awt-cab h2{color:#F4F7FB}html[data-cor=noite] .awt-pe label,body.noite .awt-pe label{color:#E6ECF4}" +
    "@media (max-width:600px){.awt-cab{padding:16px 16px 8px}.awt-video{padding:0 12px}.awt-pe{padding:14px 16px 18px}.awt-ok{width:100%}}}";

  function abrir(m, obrigatorio){
    var v = VIDEOS[m]; if(!v || aberto) return;
    aberto = true;
    if(!document.getElementById("awt-css")){ var st = document.createElement("style"); st.id = "awt-css"; st.textContent = CSS; document.head.appendChild(st); }
    var f = document.createElement("div"); f.className = "awt-fundo"; f.setAttribute("role", "dialog"); f.setAttribute("aria-modal", "true"); f.setAttribute("aria-label", v.titulo);
    f.innerHTML = '<div class="awt-caixa"><div class="awt-cab"><div><small>Bem-vindo</small><h2>' + v.titulo + '</h2><p>' + v.sub + '</p></div>' +
      '<button type="button" class="awt-x" aria-label="Fechar">&times;</button></div>' +
      '<div class="awt-video"><video src="' + v.arq + '" poster="' + v.capa + '" controls playsinline preload="metadata"></video></div>' +
      '<div class="awt-pe">' + (obrigatorio ? '<label><input type="checkbox" id="awtNao"> Não mostrar novamente</label>' : '<span></span>') +
      '<button type="button" class="awt-ok">Fechar</button><div class="awt-msg" id="awtMsg"></div></div></div>';
    document.body.appendChild(f);
    var vid = f.querySelector("video");
    try{ var tentativa = vid.play(); if(tentativa && tentativa.catch) tentativa.catch(function(){}); }catch(e){}
    function fechar(){
      var nao = f.querySelector("#awtNao");
      var marcar = nao && nao.checked;
      try{ vid.pause(); }catch(e){}
      if(!marcar){ f.remove(); aberto = false; return; }
      api("/rest/v1/rpc/tutorial_marcar", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ p_modulo: m }) })
        .then(function(){ f.remove(); aberto = false; })
        .catch(function(e){ var x = f.querySelector("#awtMsg"); if(x) x.textContent = "Não consegui guardar a escolha agora (" + (e && e.message || e) + "). Feche e tente de novo na próxima entrada."; });
    }
    f.querySelector(".awt-x").onclick = fechar; f.querySelector(".awt-ok").onclick = fechar;
    f.addEventListener("click", function(e){ if(e.target === f) fechar(); });
    document.addEventListener("keydown", function esc(e){ if(e.key === "Escape" && document.body.contains(f)){ document.removeEventListener("keydown", esc); fechar(); } });
  }

  /* Na entrada: se ainda não marcou "Não mostrar novamente", mostra uma vez por dia em cada aba. */
  function talvez(m){
    if(!m || checado || gravando()) return;
    try{ if(sessionStorage.getItem(chave(m))) { checado = true; return; } }catch(e){}
    checado = true;
    api("/rest/v1/rpc/tutorial_vistos", { method: "POST", headers: { "Content-Type": "application/json" }, body: "{}" }).then(function(lista){
      if(Array.isArray(lista) && lista.indexOf(m) >= 0) return;
      try{ sessionStorage.setItem(chave(m), "1"); }catch(e){}
      abrir(m, true);
    }).catch(function(){ checado = false; });
  }

  /* Espera a tela certa aparecer (login feito): Hub = tela inicial; CRM = menu lateral. */
  if(MOD){
    var seletor = MOD === "crm" ? ".mn-item" : ".hb-ola";
    var voltas = 0;
    var t = setInterval(function(){
      voltas++;
      if(checado || voltas > 1800){ clearInterval(t); return; }
      if(document.querySelector(seletor)) talvez(MOD);
    }, 1000);
  }
  window.AWTutorial = { abrir: function(m){ abrir(m || MOD || "hub", false); }, talvez: talvez, modulo: MOD };
})();
