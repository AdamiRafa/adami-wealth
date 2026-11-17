/* Site novo Adami Captal, proposta navegável.
   Convertido do protótipo do editor de design para HTML comum: este arquivo faz as partes
   que se mexem (topo que escurece ao rolar, números que contam, mapa do patrimônio,
   calculadora de liberdade financeira, jornada das cinco reuniões e o formulário de agendar).
   Nada aqui envia dado para lugar nenhum: o formulário só mostra a confirmação. */
(function(){
  "use strict";
  var reduz = !!(window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches);
  function $(s, el){ return (el || document).querySelector(s); }
  function $$(s, el){ return Array.prototype.slice.call((el || document).querySelectorAll(s)); }
  function reanima(el){ if(!el) return; el.classList.remove("troca"); void el.offsetWidth; el.classList.add("troca"); }
  function brl(v){ return "R$ " + Math.round(v).toLocaleString("pt-BR"); }
  function curto(v){ return v >= 1e6 ? "R$ " + (v / 1e6).toLocaleString("pt-BR", { maximumFractionDigits: 1 }) + " mi" : brl(v); }

  /* ---- topo: transparente sobre a capa, sólido depois de rolar ---- */
  var topo = $("header.topo");
  if(topo && !topo.classList.contains("solido")){
    var rolou = function(){ topo.classList.toggle("solido", window.scrollY > 40); };
    window.addEventListener("scroll", rolou, { passive: true }); rolou();
  }

  /* ---- números que contam quando aparecem ---- */
  var faixa = $("[data-contador]");
  if(faixa && !reduz){
    var spans = $$("[data-n]", faixa);
    var n = function(v, p){ return Math.round(v * p); };
    var fmt = spans.length === 2
      ? [function(p){ return "+" + n(300, p); }, function(p){ return "+R$ " + (1.29 * p).toFixed(2).replace(".", ",") + " bi"; }]
      : [function(p){ return "+" + n(20, p) + " anos"; }, function(p){ return "+" + n(2100, p).toLocaleString("pt-BR"); },
         function(p){ return "+R$ " + (1.1 * p).toFixed(1).replace(".", ",") + " bi"; }, function(p){ return "NPS " + n(98, p); }];
    var pinta = function(p){ spans.forEach(function(s, i){ if(fmt[i]) s.textContent = fmt[i](p); }); };
    var foi = false;
    var vai = function(){
      if(foi) return; foi = true;
      var t0 = performance.now(), dur = 1700;
      var passo = function(t){ var x = Math.min(1, (t - t0) / dur); pinta(1 - Math.pow(1 - x, 3)); if(x < 1) requestAnimationFrame(passo); };
      requestAnimationFrame(passo);
    };
    pinta(0);
    if("IntersectionObserver" in window){
      var io = new IntersectionObserver(function(es){ if(es.some(function(e){ return e.isIntersecting; })){ vai(); io.disconnect(); } }, { threshold: 0.3 });
      io.observe(faixa);
    } else { vai(); }
    setTimeout(vai, 2500);
  }

  /* ---- mapa do patrimônio (Home) ---- */
  var mapa = $("#mapa");
  if(mapa){
    var P = [
      { titulo: "Patrimônio financeiro", foto: "img/9dec044863cc37053989e54cbe873b2f.jpg", alt: "Edifícios corporativos", texto: "Investimentos no Brasil e no exterior, em todos os bancos, organizados em uma carteira só e acompanhados de perto.", itens: ["Relatório Consolidado de todos os bancos", "Carteira guiada pela Política de Alocação", "Conta internacional e offshore"] },
      { titulo: "Patrimônio imobilizado", foto: "img/7aec8de551da29cfd7843b700b4e1e69.jpg", alt: "Sala de estar de um imóvel", texto: "Os imóveis da família com valor atualizado, rentabilidade dos aluguéis e a estrutura certa para cada um.", itens: ["Relatório Imobiliário", "Impostos e viabilidade de holding", "Simulação de divisão de bens"] },
      { titulo: "Empresa", foto: "img/0ef4bf731904827f23308efd76e639d7.jpg", alt: "Escritório com vista para a cidade", texto: "A empresa e a família andam juntas: caixa, conta e estrutura societária alinhados ao patrimônio pessoal.", itens: ["Conta e investimentos da empresa", "Estrutura societária", "Proteção dos sócios"] },
      { titulo: "Família e legado", foto: "img/9275fe4e30616515bf173545abf48bda.jpg", alt: "Família reunida na praia ao pôr do sol", texto: "Os objetivos de cada geração, com proteção para hoje e um plano para a sucessão.", itens: ["Plano Patrimonial e sucessório", "Seguros e previdência", "Planejamento para quem vai morar fora"] }
    ];
    var botoes = $$("[data-pilar]", mapa), atual = 0, parado = false;
    var mostra = function(i){
      if(i === atual) return; atual = i;
      botoes.forEach(function(b, k){ b.classList.toggle("on", k === i); b.setAttribute("aria-pressed", k === i ? "true" : "false"); });
      var a = P[i], foto = $("#pFoto");
      foto.src = a.foto; foto.alt = a.alt;
      $("#pNum").textContent = "0" + (i + 1);
      $("#pTitulo").textContent = a.titulo;
      $("#pDesc").textContent = a.texto;
      var ul = $("#pItens"); ul.innerHTML = "";
      a.itens.forEach(function(t){ var li = document.createElement("li"); li.textContent = t; ul.appendChild(li); });
      reanima(foto); reanima($("#pTexto"));
    };
    botoes.forEach(function(b, k){
      var escolhe = function(){ parado = true; mostra(k); };
      b.addEventListener("click", escolhe); b.addEventListener("focus", escolhe);
    });
    mapa.addEventListener("mouseenter", function(){ parado = true; });
    P.forEach(function(a){ var im = new Image(); im.src = a.foto; });
    if(!reduz) setInterval(function(){ if(!parado) mostra((atual + 1) % 4); }, 5000);
  }

  /* ---- calculadora de liberdade financeira (Home) ---- */
  if($("#c-idade")){
    var ent = { idade: $("#c-idade"), pat: $("#c-pat"), ap: $("#c-ap"), renda: $("#c-renda") };
    var calcula = function(){
      var idade = +ent.idade.value, pat = +ent.pat.value, ap = +ent.ap.value, renda = +ent.renda.value;
      var real = 1.10 / 1.04 - 1, rm = Math.pow(1 + real, 1 / 12) - 1, meta = renda / rm;
      var saldo = pat, meses = 0;
      while(saldo < meta && meses < 720){ saldo = saldo * (1 + rm) + ap; meses++; }
      var pct = Math.min(100, pat / meta * 100), rotulo, destaque, frase;
      if(pat >= meta){ rotulo = "Você já chegou lá"; destaque = "Hoje"; frase = "O seu patrimônio já pagaria " + brl(renda) + " por mês, só com a renda, sem consumir o principal."; }
      else if(saldo < meta){ rotulo = "Com esses números"; destaque = "Além dos 60 anos"; frase = "O prazo passa de 60 anos. Vale ajustar aportes ou objetivo com um especialista."; }
      else { var anos = meses / 12, ra = Math.round(anos); rotulo = "Liberdade financeira aos"; destaque = Math.round(idade + anos) + " anos";
        frase = "Em cerca de " + (anos < 1 ? "menos de um ano" : ra + (ra === 1 ? " ano" : " anos")) + ", o seu patrimônio passaria a pagar " + brl(renda) + " por mês, só com a renda."; }
      $("#o-idade").textContent = idade + " anos"; $("#o-pat").textContent = curto(pat);
      $("#o-ap").textContent = brl(ap); $("#o-renda").textContent = brl(renda);
      $("#c-rotulo").textContent = rotulo; $("#c-destaque").textContent = destaque; $("#c-frase").textContent = frase;
      $("#c-pct").textContent = Math.round(pct) + "%"; $("#c-meta").textContent = curto(meta);
      $("#c-barra").style.width = pct.toFixed(1) + "%";
    };
    Object.keys(ent).forEach(function(k){ ent[k].addEventListener("input", calcula); });
    calcula();
  }

  /* ---- jornada: as cinco reuniões avançam com a rolagem ---- */
  var trilho = $("#trilho");
  if(trilho){
    var E = [
      { t: "Descoberta", modo: "Presencial, no escritório", texto: "Um café no escritório para conhecer você, sua família, sua empresa e o que você espera do seu patrimônio. Apresentamos a Adami Captal bem como nosso modelo de trabalho que propomos implementar.", leva: "Um direcionamento para abertura de cadastro junto ao BTG Pactual e a data para a próxima reunião." },
      { t: "Proposta", modo: "Presencial ou por vídeo", texto: "A proposta para o seu perfil, com o modelo de remuneração explicado com transparência, e uma prévia do relatório que você vai receber todo mês.", leva: "Proposta de investimentos e modelo do Relatório Consolidado. Nos clientes Private, também os modelos de Plano Patrimonial e de Análise de Enquadramento." },
      { t: "Consolidação", modo: "Presencial, no escritório", texto: "Reunimos o que você tem em todos os bancos em uma só visão. É aqui que aparecem sobreposições, custos escondidos e oportunidades.", leva: "O seu Relatório Consolidado real. Nos clientes Private, o Plano Patrimonial e a Análise de Enquadramento feitos para a sua família." },
      { t: "Liberdade Financeira", modo: "Presencial ou por vídeo", texto: "Mostramos quando o seu patrimônio passa a sustentar o padrão de vida que você quer, e o que muda esse prazo.", leva: "O seu Plano de Liberdade Financeira. Nos clientes Private, também o Planejamento Imobiliário e a apresentação do Wealth Planning." },
      { t: "Soluções sob medida", modo: "Presencial ou por vídeo", texto: "Para cada lacuna encontrada no caminho, um especialista da casa: proteção, previdência ou consórcio.", leva: "A proposta do especialista para fechar a lacuna, com números e alternativas." }
    ];
    var etapa = 0, marcos = $$(".marco", trilho);
    var total = function(){ return Math.max(1, trilho.offsetHeight - Math.min(window.innerHeight, 900)); };
    var poe = function(k){
      if(k === etapa) return; etapa = k; var a = E[k];
      $("#j-ordinal").textContent = (k + 1) + "ª"; $("#j-num").textContent = "0" + (k + 1);
      $("#j-titulo").textContent = a.t; $("#j-modo").textContent = a.modo;
      $("#j-texto").textContent = a.texto; $("#j-leva").textContent = a.leva;
      marcos.forEach(function(m, i){ m.className = "marco" + (i === k ? " on" : (i < k ? " feito" : "")); });
      reanima($("#jA")); reanima($("#jB"));
    };
    var aoRolar = function(){
      if(!trilho.offsetParent) return;
      var prog = Math.min(1, Math.max(0, -trilho.getBoundingClientRect().top / total()));
      poe(Math.min(4, Math.floor(prog * 5)));
    };
    window.addEventListener("scroll", aoRolar, { passive: true }); window.addEventListener("resize", aoRolar); aoRolar();
    $$("[data-ir]").forEach(function(b){
      b.addEventListener("click", function(){
        var i = +b.getAttribute("data-ir");
        if(!trilho.offsetParent){ var el = document.getElementById("e" + (i + 1)); if(el) el.scrollIntoView({ behavior: reduz ? "auto" : "smooth" }); return; }
        var topoT = trilho.getBoundingClientRect().top + window.scrollY;
        window.scrollTo({ top: topoT + total() * ((i + 0.5) / 5), behavior: reduz ? "auto" : "smooth" });
      });
    });
  }




  /* ---- vitrine "O que oferecemos" (Investimentos): troca sozinha a cada 7 s, pausa com o mouse,
     abas clicáveis e arrastar para o lado no celular ---- */
  $$("[data-vitrine]").forEach(function(v){
    var fundos = $$(".vit-fundo", v), itens = $$(".vit-item", v), abas = $$(".vit-aba", v), atualV = 0;
    var mostra = function(i){
      i = (i + itens.length) % itens.length; atualV = i;
      fundos.forEach(function(f, k){ f.classList.toggle("on", k === i); });
      itens.forEach(function(it, k){ it.classList.toggle("on", k === i); if(k === i) it.removeAttribute("aria-hidden"); else it.setAttribute("aria-hidden", "true"); });
      abas.forEach(function(a, k){
        a.classList.remove("on"); a.classList.toggle("feito", k < i); a.setAttribute("aria-selected", k === i ? "true" : "false");
        if(k === i){ void a.offsetWidth; a.classList.add("on"); }
      });
    };
    abas.forEach(function(a, k){ a.addEventListener("click", function(){ mostra(k); }); });
    v.addEventListener("animationend", function(ev){ if(ev.animationName === "enche") mostra(atualV + 1); });
    v.addEventListener("mouseenter", function(){ v.classList.add("parado"); });
    v.addEventListener("mouseleave", function(){ v.classList.remove("parado"); });
    v.addEventListener("focusin", function(){ v.classList.add("parado"); });
    v.addEventListener("focusout", function(){ v.classList.remove("parado"); });
    $(".vit-abas", v).addEventListener("keydown", function(ev){
      if(ev.key === "ArrowRight" || ev.key === "ArrowLeft"){ ev.preventDefault(); mostra(atualV + (ev.key === "ArrowRight" ? 1 : -1)); abas[atualV].focus(); }
    });
    var x0 = null;
    v.addEventListener("touchstart", function(ev){ x0 = ev.touches[0].clientX; }, { passive: true });
    v.addEventListener("touchend", function(ev){
      if(x0 === null) return; var dx = ev.changedTouches[0].clientX - x0; x0 = null;
      if(Math.abs(dx) > 50) mostra(atualV + (dx < 0 ? 1 : -1));
    }, { passive: true });
    if("IntersectionObserver" in window){
      new IntersectionObserver(function(es){ v.classList.toggle("parado", !es[0].isIntersecting); }, { threshold: 0.35 }).observe(v);
    }
  });

  /* ---- roda de serviços (Wealth): lista vertical que gira, foto redonda e anel de marcações ---- */
  $$("[data-roda]").forEach(function(r){
    var nomes = $$(".roda-nome", r), fotos = $$(".roda-foto img", r), infos = $$(".roda-info-i", r);
    var trilhoR = $(".roda-trilho", r), lista = $(".roda-lista", r), dial = $(".roda-dial g", r);
    var cima = $(".roda-seta.cima", r), baixo = $(".roda-seta.baixo", r), atualR = 0, ALT = 70;
    var poe = function(i){
      i = Math.max(0, Math.min(nomes.length - 1, i)); atualR = i;
      nomes.forEach(function(nm, k){
        var d = Math.min(3, Math.abs(k - i)); nm.setAttribute("data-d", String(d));
        nm.classList.toggle("on", k === i); nm.setAttribute("aria-selected", k === i ? "true" : "false");
        nm.tabIndex = k === i ? 0 : -1;
      });
      fotos.forEach(function(f, k){ f.classList.toggle("on", k === i); });
      infos.forEach(function(it, k){ it.classList.toggle("on", k === i); if(k === i) it.removeAttribute("aria-hidden"); else it.setAttribute("aria-hidden", "true"); });
      trilhoR.style.transform = "translateY(" + (lista.clientHeight / 2 - ALT / 2 - i * ALT) + "px)";
      dial.style.transform = "rotate(" + (-i * 36) + "deg)";
      cima.disabled = i === 0; baixo.disabled = i === nomes.length - 1;
    };
    nomes.forEach(function(nm, k){ nm.addEventListener("click", function(){ poe(k); }); });
    cima.addEventListener("click", function(){ poe(atualR - 1); });
    baixo.addEventListener("click", function(){ poe(atualR + 1); });
    trilhoR.addEventListener("keydown", function(ev){
      if(ev.key === "ArrowDown" || ev.key === "ArrowUp"){ ev.preventDefault(); poe(atualR + (ev.key === "ArrowDown" ? 1 : -1)); nomes[atualR].focus(); }
    });
    var y0 = null, x1 = null;
    r.addEventListener("touchstart", function(ev){ y0 = ev.touches[0].clientY; x1 = ev.touches[0].clientX; }, { passive: true });
    r.addEventListener("touchend", function(ev){
      if(y0 === null) return; var dx = ev.changedTouches[0].clientX - x1; y0 = null;
      if(Math.abs(dx) > 50) poe(atualR + (dx < 0 ? 1 : -1));
    }, { passive: true });
    window.addEventListener("resize", function(){ poe(atualR); });
    poe(0);
  });


  /* ---- menu do celular: abre em tela cheia, fecha no X, no Esc ou ao escolher um link ---- */
  var menuBt = $(".menu-bt"), menuCel = $("#menuCel");
  if(menuBt && menuCel){
    var abre = function(){
      menuCel.hidden = false; void menuCel.offsetWidth; menuCel.classList.add("aberto");
      document.body.classList.add("menu-aberto"); document.body.style.overflow = "hidden";
      menuBt.setAttribute("aria-expanded", "true"); $(".menu-fecha", menuCel).focus();
    };
    var fecha = function(){
      menuCel.classList.remove("aberto"); document.body.classList.remove("menu-aberto"); document.body.style.overflow = "";
      menuBt.setAttribute("aria-expanded", "false");
      setTimeout(function(){ if(!menuCel.classList.contains("aberto")) menuCel.hidden = true; }, reduz ? 0 : 350);
      menuBt.focus();
    };
    menuBt.addEventListener("click", abre);
    $(".menu-fecha", menuCel).addEventListener("click", fecha);
    $$("a", menuCel).forEach(function(a){ a.addEventListener("click", function(){ if(a.getAttribute("href").indexOf("#") >= 0) fecha(); }); });
    menuCel.addEventListener("keydown", function(ev){ if(ev.key === "Escape") fecha(); });
  }

  /* ---- agendar conversa: escolha do assunto e confirmação (nada é enviado) ---- */
  var form = $("#agForm");
  if(form){
    var pilulas = $$("[data-interesse]", form);
    pilulas.forEach(function(b){
      b.addEventListener("click", function(){
        pilulas.forEach(function(x){ var on = x === b; x.classList.toggle("pilula-on", on); x.setAttribute("aria-pressed", on ? "true" : "false"); });
      });
    });
    form.addEventListener("submit", function(ev){
      ev.preventDefault();
      var primeiro = ($("#ag-nome").value || "").trim().split(/\s+/)[0] || "";
      $("#agNome").textContent = primeiro ? ", " + primeiro : "";
      form.hidden = true; $("#agOk").hidden = false;
      window.scrollTo({ top: 0, behavior: reduz ? "auto" : "smooth" });
    });
  }
})();
