/* Ficha de cadastro da pessoa da equipe (Hub 3.36): um componente só, usado na Equipe (index.html, master)
   e em Comissões > Pessoas e acordos (comissoes.html, Financeiro). Pedido do Emil: "cadastro unificado".
   - Dados pessoais, endereço, vínculo, contato de emergência, observações e certificações ficam em
     equipe_cadastro (equipe_cadastro.sql), pelo e-mail: dá para preencher já no convite.
   - Os dados de pagamento ficam em comissao_dados_pagto (comissoes.sql), pela conta: só depois do primeiro acesso.
   Cada página desenha os campos no próprio estilo: form() recebe como embrulhar um campo e um grupo.
   Tudo que vem do banco passa por esc(). */
(function(){
  var GRUPOS = [
    ["Dados pessoais", [["nome_completo","Nome completo"],["cpf","CPF"],["rg","RG e órgão emissor"],["nascimento","Data de nascimento","date"],
      ["estado_civil","Estado civil","sel",["","Solteiro(a)","Casado(a)","União estável","Divorciado(a)","Viúvo(a)"]],
      ["celular","Celular"],["email_pessoal","E-mail pessoal","email"]]],
    ["Endereço", [["cep","CEP"],["endereco","Rua e número"],["complemento","Complemento"],["bairro","Bairro"],["cidade","Cidade"],["uf","UF"]]],
    ["Vínculo com a Adami", [["cargo","Cargo ou função"],["area","Área","sel",["","Comercial","Wealth Planning","Especialista de produto","Mesa RV","Financeiro","Operações","Marketing","Diretoria"]],
      ["vinculo","Tipo de vínculo","sel",["","Sócio(a)","Assessor(a) PJ","CLT","Estágio","Outro"]],["admissao","Data de entrada","date"],
      ["empresa_pj","Razão social da PJ (se houver)"],["cnpj_pj","CNPJ da PJ"],["gestor","Gestor direto"],
      ["cod_btg","Código de assessor no BTG"],["registro_ancord","Registro Ancord / CVM"]]],
    ["Contato de emergência", [["emerg_nome","Nome"],["emerg_parentesco","Parentesco"],["emerg_telefone","Telefone"]]],
    ["Observações", [["obs","Observações","area"]]]
  ];
  var CERTS = ["CPA-10","CPA-20","CEA","CFP","Ancord","CNPI","CGA"];
  /* Pagamento da comissão (comissao_dados_pagto). O nome completo é o da ficha; não se repete aqui. */
  var PAGTO = [["cpf_cnpj","CPF ou CNPJ que recebe"],["pix_tipo","Tipo de PIX","sel",["","CPF","CNPJ","E-mail","Celular","Aleatória"]],["pix_chave","Chave PIX"],
    ["banco","Banco"],["agencia","Agência"],["conta","Conta"],["tipo_conta","Tipo de conta","sel",["","Corrente","Poupança","Pagamento"]],
    ["titular","Titular da conta (se for outra pessoa ou a empresa)"],["observacao","Observação do pagamento"]];

  function esc(s){ return String(s == null ? "" : s).replace(/[&<>"']/g, function(c){ return {"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]; }); }

  function entrada(c, id, valor, desab){
    var v = valor == null ? "" : String(valor), tipo = c[2] || "text", d = desab ? " disabled" : "";
    if(tipo === "sel"){
      var ops = c[3].slice(); if(v && ops.indexOf(v) < 0) ops.push(v);
      return '<select id="' + id + '"' + d + '>' + ops.map(function(o){ return '<option' + (v === o ? " selected" : "") + '>' + esc(o) + '</option>'; }).join("") + '</select>';
    }
    if(tipo === "area") return '<textarea id="' + id + '" maxlength="2000" rows="3"' + d + '>' + esc(v) + '</textarea>';
    return '<input id="' + id + '" type="' + tipo + '" maxlength="160" value="' + esc(v) + '"' + d + '>';
  }
  /* op.campo(rotulo, id, htmlDaEntrada, largo) e op.grupo(titulo, htmlDosCampos) desenham no estilo da página. */
  function form(px, d, op){
    d = d || {}; var certs = d.certificacoes || {}, des = !!op.desabilitado;
    var h = GRUPOS.map(function(g){
      return op.grupo(g[0], g[1].map(function(c){ var id = px + "_" + c[0]; return op.campo(c[1], id, entrada(c, id, d[c[0]], des), c[2] === "area"); }).join(""));
    }).join("");
    if(op.pagto) h += op.grupo("Pagamento da comissão", PAGTO.map(function(c){ var id = px + "_pg_" + c[0];
      return op.campo(c[1], id, entrada(c, id, op.pagto[c[0]], des), false); }).join(""));
    return h + op.grupo("Certificações (deixe em branco a que a pessoa não tem)", CERTS.map(function(c, i){ var id = px + "_cert_" + i;
      return op.campo(c + ": válida até", id, '<input id="' + id + '" type="date" value="' + esc(certs[c] || "") + '"' + (des ? " disabled" : "") + '>', false); }).join(""));
  }
  function valor(id){ var e = document.getElementById(id); return e ? String(e.value || "").trim() : ""; }
  function ler(px){
    var d = {}, certs = {};
    GRUPOS.forEach(function(g){ g[1].forEach(function(c){ var x = valor(px + "_" + c[0]); if(x) d[c[0]] = x; }); });
    CERTS.forEach(function(c, i){ var x = valor(px + "_cert_" + i); if(/^\d{4}-\d{2}-\d{2}$/.test(x)) certs[c] = x; });
    if(Object.keys(certs).length) d.certificacoes = certs;
    return d;
  }
  /* Os campos de pagamento lidos da tela, mais o nome completo da ficha. Devolve null se o bloco não está na tela. */
  function lerPagto(px, nome){
    if(!document.getElementById(px + "_pg_cpf_cnpj")) return null;
    var p = { nome_completo: nome || "" };
    PAGTO.forEach(function(c){ p[c[0]] = valor(px + "_pg_" + c[0]); });
    return p;
  }
  window.AWCadastro = { GRUPOS: GRUPOS, CERTS: CERTS, PAGTO: PAGTO, form: form, ler: ler, lerPagto: lerPagto };
})();
