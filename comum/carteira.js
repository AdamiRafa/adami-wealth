/* Números da carteira para a tela inicial do Hub (2.96, 06/11/2026).

   As regras são cópia fiel das do CRM (crm.html), para o Hub e o CRM nunca discordarem:
   parseValor, valorInicialEmCarteira, valorInicialOffshore, saldoMovimentacoes,
   valorEmCarteira(Offshore), naCarteira, entradaNaCarteira e a captação líquida de
   computeAssessoriaStats (entrada de cliente captado + aportes - retiradas, só de quem já é
   carteira, offshore convertido pela cotação do escritório). Mudou lá, muda aqui.

   Entrada: linhas cruas da tabela leads (nomes do banco, snake_case). */
(function(){
  function parseValor(v){
    if(v === null || v === undefined || v === '') return null;
    var n = Number(String(v).replace(/[^\d.,-]/g, '').replace(/\.(?=\d{3})/g, '').replace(',', '.'));
    return isNaN(n) ? null : n;
  }
  function ms(t){ return t ? new Date(t).getTime() : null; }
  function custodia(m){ return (m && m.custodia) === 'offshore' ? 'offshore' : 'onshore'; }
  function esteira(l){ return l.esteira || 'novo'; }
  function especialista(l){ return (l.funil || 'assessor') === 'especialista'; }

  function inicialOn(l){
    if(!l || especialista(l) || l.perdido) return null;
    if(esteira(l) === 'base'){
      var s = parseValor(l.saldo_inicial);
      return s !== null ? s : (parseValor(l.valor_potencial) || 0);
    }
    if(l.ganho) return parseValor(l.valor_fechado) || parseValor(l.valor_potencial) || 0;
    return null;
  }
  function inicialOff(l){
    if(!l || especialista(l) || l.perdido) return null;
    if(esteira(l) !== 'base' && !l.ganho) return null;
    var s = parseValor(l.saldo_inicial_offshore);
    if(s !== null) return s;
    var d = parseValor(l.valor_offshore);
    return d !== null ? d : 0;
  }
  function saldoMov(l, ate, qual){
    return (l.movimentacoes || []).reduce(function(acc, m){
      if(custodia(m) !== qual) return acc;
      if(ate && m.data && m.data > ate) return acc;
      var v = parseValor(m.valor);
      return acc + (v === null ? 0 : v * (m.tipo === 'retirada' ? -1 : 1));
    }, 0);
  }
  function naCarteira(l){ return inicialOn(l) !== null || inicialOff(l) !== null; }
  function entrada(l){
    if(inicialOn(l) === null) return null;
    if(esteira(l) === 'base') return ms(l.criado_em);
    return ms(l.ganho_em) || ms(l.etapa_desde) || ms(l.criado_em);
  }
  function iso(d){ return d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0') + '-' + String(d.getDate()).padStart(2, '0'); }

  /* Carteira (R$, offshore convertido se houver cotação) no fim do dia `ateIso`, contando só
     quem já tinha entrado na carteira até lá. */
  function carteiraEm(lista, ateIso, ateMs, cot){
    return lista.reduce(function(acc, l){
      var on = inicialOn(l), off = inicialOff(l);
      if(on === null && off === null) return acc;
      var ent = entrada(l);
      if(ent !== null && ent > ateMs) return acc;
      var v = on === null ? 0 : Math.max(0, on + saldoMov(l, ateIso, 'onshore'));
      if(cot && off !== null) v += Math.max(0, off + saldoMov(l, ateIso, 'offshore')) * cot;
      return acc + v;
    }, 0);
  }

  /* Captação líquida entre [de, ate) em ms: a mesma conta do CRM. */
  function liquido(lista, de, ate, cot){
    var f = { entradas: 0, aportes: 0, retiradas: 0 };
    lista.forEach(function(l){
      var e = entrada(l);
      if(e !== null && e >= de && e < ate && esteira(l) !== 'base'){
        f.entradas += inicialOn(l) || 0;
        if(cot) f.entradas += (inicialOff(l) || 0) * cot;
      }
      if(!naCarteira(l)) return;
      (l.movimentacoes || []).forEach(function(m){
        var v = parseValor(m.valor);
        if(v === null || !m.data) return;
        var t = new Date(m.data + 'T12:00:00').getTime();
        if(t < de || t >= ate) return;
        if(custodia(m) === 'offshore'){ if(!cot) return; v = v * cot; }
        if(m.tipo === 'retirada') f.retiradas += v; else f.aportes += v;
      });
    });
    return f.entradas + f.aportes - f.retiradas;
  }

  window.AWCarteira = {
    /* rows: leads crus; cotacao: número (R$ por US$) ou null; agora: Date. */
    numeros: function(rows, cotacao, agora){
      agora = agora || new Date();
      var cot = cotacao && cotacao > 0 ? cotacao : null;
      var lista = (rows || []).filter(function(l){ return !l.excluido && !especialista(l); });
      var iniMes = new Date(agora.getFullYear(), agora.getMonth(), 1);
      var iniAnt = new Date(agora.getFullYear(), agora.getMonth() - 1, 1);
      var fimAnt = new Date(iniMes.getTime() - 1);
      var hojeMs = agora.getTime();
      var clientes = lista.filter(function(l){
        var on = inicialOn(l), off = inicialOff(l);
        return (on !== null && Math.max(0, on + saldoMov(l, null, 'onshore')) > 0)
            || (off !== null && Math.max(0, off + saldoMov(l, null, 'offshore')) > 0);
      }).length;
      var novos = function(de, ate){
        return lista.filter(function(l){ var e = entrada(l); return e !== null && e >= de && e < ate && esteira(l) !== 'base'; }).length;
      };
      /* Mesmo ponto do mês passado (dia de hoje no mês anterior), para a comparação ser justa. */
      var mesmoDiaAnt = new Date(agora.getFullYear(), agora.getMonth() - 1, Math.min(agora.getDate(),
        new Date(agora.getFullYear(), agora.getMonth(), 0).getDate()), 23, 59, 59);
      return {
        sobGestao: carteiraEm(lista, iso(agora), hojeMs, cot),
        sobGestaoMesPassado: carteiraEm(lista, iso(fimAnt), fimAnt.getTime(), cot),
        liquidoMes: liquido(lista, iniMes.getTime(), hojeMs + 1, cot),
        liquidoMesPassadoAteHoje: liquido(lista, iniAnt.getTime(), mesmoDiaAnt.getTime() + 1, cot),
        liquidoMesPassado: liquido(lista, iniAnt.getTime(), iniMes.getTime(), cot),
        clientes: clientes,
        captadosMes: novos(iniMes.getTime(), hojeMs + 1),
        captadosMesPassado: novos(iniAnt.getTime(), iniMes.getTime()),
        comOffshore: !!cot
      };
    },
    _parseValor: parseValor
  };
})();
