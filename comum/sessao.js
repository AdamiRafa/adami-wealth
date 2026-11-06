/* Guarda de sessão dos módulos do Hub Adami (06/11/2026).
   Carregado no <head> de cada módulo, antes de tudo. Manda de volta para o Hub quem:
   - não está logado;
   - não confirmou hoje o código de 6 dígitos que chega por e-mail;
   - entrou ontem (o acesso vale só até a meia-noite de Brasília).
   É a parte da tela. Quem protege os dados é o banco (seguranca.sql): sem o código do
   dia, nenhuma tabela responde, mesmo que alguém pule esta checagem. */
(function(){
  function hoje(){
    try{ return new Date().toLocaleDateString("en-CA", { timeZone: "America/Sao_Paulo" }); }
    catch(e){
      var d = new Date(Date.now() - 3 * 3600 * 1000);
      return d.toISOString().slice(0, 10);
    }
  }
  function sessaoValida(){
    var s = null;
    try{ s = JSON.parse(localStorage.getItem("aw_sessao") || "null"); }catch(e){}
    return !!(s && s.access_token && s.dia === hoje());
  }
  window.AW_HOJE = hoje;
  if(!sessaoValida()){ location.replace("index.html"); return; }
  /* O banco é quem sabe se esta sessão confirmou o código hoje. Se não confirmou
     (ex.: entrou antes de a verificação ser ligada), volta para a tela do código. */
  try{
    var s = JSON.parse(localStorage.getItem("aw_sessao") || "null");
    fetch("https://ghxjqmjtmbqzvogwzylo.supabase.co/rest/v1/rpc/estado_acesso", {
      method: "POST",
      headers: { "apikey": "sb_publishable_-M5rRFdjNXtFr1td-NVWPQ_GGkd_liB", "Authorization": "Bearer " + s.access_token, "Content-Type": "application/json" },
      body: "{}"
    }).then(function(r){ return r.ok ? r.json() : null; }).then(function(st){
      if(st && st.exige && !st.liberado){
        var atual = JSON.parse(localStorage.getItem("aw_sessao") || "null");
        if(atual){ atual.dia = null; atual.login_dia = hoje(); localStorage.setItem("aw_sessao", JSON.stringify(atual)); }
        location.replace("index.html");
      }
    }).catch(function(){});
  }catch(e){}
  /* Aba aberta de um dia para o outro, ou logout em outra aba. */
  setInterval(function(){ if(!sessaoValida()) location.replace("index.html"); }, 60000);
  document.addEventListener("visibilitychange", function(){
    if(document.visibilityState === "visible" && !sessaoValida()) location.replace("index.html");
  });
})();
