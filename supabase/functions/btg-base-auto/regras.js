// GERADO por gerar-regras.js a partir do crm.html. Não edite aqui: edite o crm.html e gere de novo.
// deno-lint-ignore-file
const sinalMov = (tipo) => tipo === 'retirada' ? -1 : 1;

const custodiaDe = (m) => (m && m.custodia) === 'offshore' ? 'offshore' : 'onshore';

function saldoMovimentacoes(lead, ate, custodia){
  const qual = custodia || 'onshore';
  return ((lead && lead.movimentacoes) || []).reduce((acc, m) => {
    if(custodiaDe(m) !== qual) return acc;
    if(ate && m.data && m.data > ate) return acc;
    const v = parseValor(m.valor);
    return acc + (v === null ? 0 : v * sinalMov(m.tipo));
  }, 0);
}

function valorEmCarteira(lead){
  const base = valorInicialEmCarteira(lead);
  if(base === null) return 0;
  /* Nunca negativo: uma retirada maior que o registrado indica dado
     incompleto, não patrimônio negativo. */
  return Math.max(0, base + saldoMovimentacoes(lead));
}

function valorInicialEmCarteira(lead){
  if(!lead || (lead.funil || 'assessor') === 'especialista') return null;
  if(lead.perdido) return null;
  if((lead.esteira || 'novo') === 'base'){
    const saldo = parseValor(lead.saldoInicial);
    return saldo !== null ? saldo : (parseValor(lead.valorPotencial) || 0);
  }
  if(lead.ganho) return parseValor(lead.valorFechado) || parseValor(lead.valorPotencial) || 0;
  return null;
}

function congelarSaldoInicial(atual, editado){
  if(!editado || (editado.funil || 'assessor') === 'especialista') return editado;
  if((editado.esteira || 'novo') !== 'base') return editado;
  if(parseValor(editado.saldoInicial) !== null) return editado;
  const origem = atual && (atual.esteira || 'novo') === 'base' ? atual.valorPotencial : editado.valorPotencial;
  const v = parseValor(origem);
  return { ...editado, saldoInicial: fmtBRL(v === null ? 0 : v) };
}

function congelarSaldoInicialOffshore(atual, editado){
  if(!editado || (editado.funil || 'assessor') === 'especialista') return editado;
  if((editado.esteira || 'novo') !== 'base' && !editado.ganho) return editado;
  if(parseValor(editado.saldoInicialOffshore) !== null) return editado;
  const v = parseValor(atual ? atual.valorOffshore : editado.valorOffshore);
  return { ...editado, saldoInicialOffshore: fmtUSD(v === null ? 0 : v) };
}

const DIA_MS = 86400000;

const custodiaCaptacao = (lead) => (lead && lead.captacaoCustodia === 'offshore') ? 'offshore' : 'onshore';

function segmentoPorPatrimonio(valor){
  if(valor === null || valor === undefined) return null;
  if(valor >= 5000000) return 'Private';
  if(valor >= 1000000) return 'Exclusive';
  return 'Advisory';
}

function nomeSemConta(cliente, conta){
  const nome = cliente || '';
  const c = (conta || '').trim();
  if(!c || !nome.trim().endsWith(c)) return nome;
  return nome.trim().replace(new RegExp('\\s*[·\\-–]?\\s*' + c.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '$'), '').trim();
}

const BTG_FAIXA_RENDIMENTO = 0.005;

function faixaBTG(ultimaMs, agoraMs){
  if(!ultimaMs || !isFinite(ultimaMs)) return { faixa: BTG_FAIXA_RENDIMENTO, dias: null };
  const dias = Math.max(0, ((agoraMs || Date.now()) - ultimaMs) / DIA_MS);
  return { faixa: Math.max(BTG_FAIXA_RENDIMENTO, BTG_FAIXA_RENDIMENTO * dias / 7), dias: Math.round(dias) };
}

function btgSaldoAtual(lead){
  if(valorInicialEmCarteira(lead) === null){
    /* Fora da carteira (perdido, por exemplo): compara com o mesmo campo que a importação grava
       (btgCampoValor). Comparar com o potencial e gravar no saldo fazia a diferença nunca fechar, e o
       alerta voltaria todo dia na atualização automática (18/11/2026: 4 clientes perdidos com saldo). */
    const v = parseValor(lead[btgCampoValor(lead)]);
    return v === null ? (parseValor(lead.valorPotencial) || 0) : v;
  }
  return valorEmCarteira(lead);
}

function btgCampoValor(lead){
  /* Cliente da base: o saldo tem coluna própria, e o patrimônio do
     formulário não é mais tocado pela importação. */
  if((lead.esteira || 'novo') === 'base') return 'saldoInicial';
  if(lead.ganho && parseValor(lead.valorFechado) !== null) return 'valorFechado';
  return 'valorPotencial';
}

function btgValorAlvo(lead, saldoBTG){
  if(valorInicialEmCarteira(lead) === null) return saldoBTG;
  return Math.max(0, saldoBTG - saldoMovimentacoes(lead));
}

const CHAVE_COL = (s) => String(s == null ? '' : s)
  .normalize('NFD').replace(/[\u0300-\u036f]/g, '')
  .toLowerCase().replace(/[^a-z0-9]/g, '');

const COL_CODIGO = new Set([
  'codigoassessor','codigodoassessor','codassessor','coddoassessor',
  'idassessor','iddoassessor','assessorid','assessorcodigo','codigoaai',
]);

function acharColunaCodigo(linhas){
  for(const c of Object.keys((linhas && linhas[0]) || {})){
    if(COL_CODIGO.has(CHAVE_COL(c))) return c;
  }
  return '';
}

const chaveCodigo = (s) => String(s == null ? '' : s).trim().toUpperCase();

const chaveConta = (s) => String(s == null ? '' : s).trim().replace(/^0+(?=\d)/, '');

function mapaPorConta(leads){
  const porConta = new Map();
  for(const l of (leads || [])){
    if(l.excluido) continue;
    if((l.funil || 'assessor') !== 'assessor') continue;
    const k = chaveConta(l.conta);
    if(k) porConta.set(k, l);
  }
  return porConta;
}

function dataBrParaISO(s){
  const m = String(s || '').trim().match(/^(\d{1,2})\/(\d{1,2})\/(\d{4})$/);
  if(!m) return '';
  return m[3] + '-' + m[2].padStart(2,'0') + '-' + m[1].padStart(2,'0');
}

function tipoPessoaDoArquivo(s){
  const v = String(s == null ? '' : s).trim().toUpperCase();
  return (v === 'PF' || v === 'PJ') ? v : '';
}

function reconciliarBaseBTG(linhas, leads, users, opc){
  opc = opc || {};
  const faixa = opc.faixa || BTG_FAIXA_RENDIMENTO;
  const norm = (s) => String(s == null ? '' : s).trim();
  const porConta = mapaPorConta(leads);
  const nomeDoUsuario = (id) => {
    const u = (users || []).find(x => x.id === id);
    return u ? u.nome : '';
  };

  /* Quem é cada código. Só entra quem tem código cadastrado; duas pessoas
     com o mesmo código não acontecem, porque o banco tem índice único —
     mas se um dia acontecer, a primeira ganha e a segunda vira desconhecida,
     o que é melhor do que sortear a carteira. */
  const porCodigo = new Map();
  for(const u of (users || [])){
    const k = chaveCodigo(u.codigo);
    if(k && !porCodigo.has(k)) porCodigo.set(k, u);
  }
  const colCodigo = acharColunaCodigo(linhas);
  /* Coluna presente mas ninguém cadastrado: ler o código não levaria a
     lugar nenhum, e cada linha viraria "código desconhecido". Melhor
     ignorar a coluna e dizer isso uma vez só, no rodapé da prévia. */
  const usaCodigo = !!colCodigo && porCodigo.size > 0;

  const atualizacoes = [], novas = [], trocaAssessor = [], semConta = [];
  const codigosDesconhecidos = new Map();
  const vistas = new Set();

  for(const d of (linhas || [])){
    const conta = norm(d['Conta']);
    if(!conta){ semConta.push(d); continue; }
    vistas.add(chaveConta(conta));
    const nome = norm(d['Nome']);
    /* Nunca negativo, como a carteira (valorEmCarteira): conta com saldo devedor no BTG vale 0 aqui,
       senão a diferença para o 0 gravado nunca fecharia e o alerta voltaria todo dia (18/11/2026). */
    const saldoBTG = Math.max(0, Math.round((parseFloat(d['Sob Gestão'] ?? d['PL Total']) || 0) * 100) / 100);
    const assessorBTG = norm(d['Assessor']);

    /* O código, quando a planilha traz. Célula vazia não é erro: é linha que
       não quis dizer nada sobre assessor, e o vínculo atual fica de pé. */
    const codigo = usaCodigo ? chaveCodigo(d[colCodigo]) : '';
    const donoPorCodigo = codigo ? porCodigo.get(codigo) : null;
    if(codigo && !donoPorCodigo){
      if(!codigosDesconhecidos.has(codigo)) codigosDesconhecidos.set(codigo, []);
      codigosDesconhecidos.get(codigo).push({ conta, nome });
    }

    const lead = porConta.get(chaveConta(conta));

    if(!lead){
      /* Com código reconhecido, a conta nova ganha card sozinha — é o mesmo
         código que autoriza transferência, agora autorizando também quem
         recebe a carteira que ainda não tinha registro nenhum. Sem código,
         segue a regra antiga: só a lista, cadastro é manual. */
      novas.push({ conta, nome, saldo: saldoBTG,
        assessor: (donoPorCodigo && donoPorCodigo.nome) || assessorBTG,
        codigo, donoPorCodigo,
        tipoPessoa: tipoPessoaDoArquivo(d['Tipo']) || 'PF',
        nascimento: dataBrParaISO(d['Aniversário']) });
      continue;
    }

    const saldoAtual = btgSaldoAtual(lead);
    const delta = Math.round((saldoBTG - saldoAtual) * 100) / 100;
    /* A faixa mede sobre o maior dos dois: evita divisão por zero e trata
       igual quem cresceu e quem encolheu. */
    const base = Math.max(saldoAtual, saldoBTG);
    const limiar = base * faixa;
    /* As movimentações já estão dentro de saldoAtual, então `delta` é o que
       sobra DEPOIS de descontar o que o assessor lançou. Não há segunda
       subtração a fazer: um aporte de 300k lançado na semana deixa aqui só o
       rendimento dos dias entre o lançamento e o export.

       Pela API (Atualizar do BTG), as aplicações e resgates que o próprio BTG informa desde a
       última atualização também explicam a diferença: desconta-se o que o BTG viu e o assessor
       ainda não lançou (o que ele já lançou está em saldoAtual e não pode contar duas vezes). */
    let movBtg = 0;
    if(opc.movs && opc.movs.has(chaveConta(conta))){
      const doBtg = opc.movs.get(chaveConta(conta)) || 0;
      const lancadoDesde = opc.desdeISO ? saldoMovimentacoes(lead) - saldoMovimentacoes(lead, opc.desdeISO) : 0;
      movBtg = Math.round((doBtg - lancadoDesde) * 100) / 100;
    }
    const dentroDaFaixa = Math.abs(delta - movBtg) <= limiar;
    const mudouSaldo = Math.abs(delta) >= 0.01;

    /* `campos` é o que a prévia mostra; `patch` é o que a gravação aplica.
       Os dois saem do mesmo lugar de propósito: se divergissem, a tela
       prometeria uma coisa e o banco receberia outra. */
    const campos = [], patch = {};
    const cmp = (campo, rotulo, atual, novo) => {
      if(norm(novo) && norm(atual) !== norm(novo)){
        campos.push({ rotulo, de: norm(atual), para: norm(novo) });
        patch[campo] = norm(novo);
      }
    };
    cmp('email', 'E-mail', lead.email, d['E-Mail Comunicação']);
    cmp('profissao', 'Profissão', lead.profissao, d['Profissão / Setor']);
    cmp('tipoPessoa', 'Tipo', lead.tipoPessoa, tipoPessoaDoArquivo(d['Tipo']));
    cmp('nascimento', 'Nascimento', lead.nascimento, dataBrParaISO(d['Aniversário']));

    /* O padrão do nome, garantido a cada importação.

       Duas coisas acontecem aqui, e nenhuma delas encurta um nome:

       1. LIMPEZA. A base carregada trazia a conta colada no texto
          ("Silvana · 4417029") porque não havia coluna para ela. Agora há, e a
          tela compõe — o texto colado viraria conta repetida. A importação
          descola.

       2. COMPLEMENTO. Se o arquivo trouxer um nome MAIOR do que o nosso, ele
          completa: é assim que a correção em bloco vai acontecer no dia em que
          o BTG mandar o export com sobrenome.

       O que ela nunca faz é ENCURTAR. Hoje o arquivo traz só o primeiro nome:
       adotá-lo cegamente apagaria, toda semana, exatamente os sobrenomes que
       este padrão existe para ter. Por isso a comparação é por prefixo — o
       arquivo só ganha quando acrescenta. */
    const nomeLimpo = nomeSemConta(lead.cliente, conta);
    const arquivoAmplia = nome && nome.length > nomeLimpo.length
      && nome.toLowerCase().startsWith(nomeLimpo.toLowerCase());
    const nomeAlvo = arquivoAmplia ? nome : nomeLimpo;
    if(nomeAlvo && nomeAlvo !== (lead.cliente || '').trim()){
      campos.push({ rotulo:'Nome', de: (lead.cliente || '').trim() || '—', para: nomeAlvo });
      patch.cliente = nomeAlvo;
    }

    const segmentoNovo = segmentoPorPatrimonio(saldoBTG);
    if(segmentoNovo && segmentoNovo !== lead.segmento){
      campos.push({ rotulo:'Segmento', de: lead.segmento || '—', para: segmentoNovo });
      patch.segmento = segmentoNovo;
    }

    const respAtual = nomeDoUsuario(lead.responsavelId);

    /* CÓDIGO x NOME — a diferença é o que se faz com a divergência.

       O código foi digitado por quem monta a planilha, olhando a tela de
       Equipe: é uma instrução, e a importação a cumpre — grava o vínculo e
       registra no histórico do cliente.

       O nome vem do export do BTG, e continua valendo a regra antiga: vira
       aviso, nunca transferência. "RAFAEL" pode ser dois Rafaéis, e mover
       carteira mexe em comissão e em relacionamento. */
    let vinculoAssessor = null;
    if(donoPorCodigo && donoPorCodigo.id !== lead.responsavelId){
      vinculoAssessor = { de: respAtual || '—', para: donoPorCodigo.nome, id: donoPorCodigo.id, codigo };
      campos.push({ rotulo:'Assessor', de: respAtual || '—', para: donoPorCodigo.nome });
      patch.responsavelId = donoPorCodigo.id;
    }

    /* Só reclama do nome quando não houve código mandando: com código, o
       nome do BTG já foi respondido, e o aviso seria ruído. */
    const divergeAssessor = !donoPorCodigo && !!assessorBTG && !!respAtual
      && assessorBTG.toUpperCase() !== respAtual.toUpperCase();
    if(divergeAssessor) trocaAssessor.push({ conta, nome, lead, de: respAtual, para: assessorBTG });

    if(mudouSaldo || campos.length){
      atualizacoes.push({
        conta, nome, lead,
        saldoAtual, saldoBTG, delta, limiar,
        /* Fora da faixa e sem lançamento que explique: é isto que vira alerta
           no card e entra no resumo do admin. */
        alerta: mudouSaldo && !dentroDaFaixa,
        explicadoPeloBtg: mudouSaldo && !(Math.abs(delta) <= limiar) && dentroDaFaixa && movBtg !== 0,
        movBtg,
        segmento: segmentoNovo,
        campoValor: btgCampoValor(lead),
        valorAlvo: btgValorAlvo(lead, saldoBTG),
        vinculoAssessor,
        campos, patch,
      });
    }
  }

  /* Quem a base tem e o arquivo não trouxe. Não se mexe: uma linha faltando
     por erro de export não pode apagar carteira. */
  const ausentes = [];
  for(const [chave, lead] of porConta){
    if(!vistas.has(chave)) ausentes.push({ conta: (lead.conta || '').trim(), lead, saldo: btgSaldoAtual(lead) });
  }

  const comAlerta = atualizacoes.filter(a => a.alerta);
  const desconhecidos = [...codigosDesconhecidos.entries()]
    .map(([codigo, contas]) => ({ codigo, contas }));
  return {
    tipo: 'onshore',
    atualizacoes, novas, ausentes, trocaAssessor, conflitos: [], semConta,
    /* A prévia precisa saber por que a coluna não foi usada: "tem coluna e
       não fez nada" é exatamente o tipo de silêncio que esconde erro. */
    colunaCodigo: colCodigo, usaCodigo, codigosDesconhecidos: desconhecidos,
    resumo: {
      linhas: (linhas || []).length,
      conciliadas: vistas.size - novas.length,
      alteradas: atualizacoes.length,
      alertas: comAlerta.length,
      explicadasPeloBtg: atualizacoes.filter(a => a.explicadoPeloBtg).length,
      faixa, diasDesde: opc.dias == null ? null : opc.dias,
      novas: novas.length,
      novasComCodigo: novas.filter(n => n.donoPorCodigo).length,
      ausentes: ausentes.length,
      trocas: trocaAssessor.length,
      vinculosAssessor: atualizacoes.filter(a => a.vinculoAssessor).length,
      deltaTotal: atualizacoes.reduce((a, x) => a + x.delta, 0),
    },
  };
}

function uid(prefix){ return (prefix||'id') + Date.now().toString(36) + Math.random().toString(36).slice(2,7); }

function toISODate(d){
  return d.getFullYear() + '-' + String(d.getMonth()+1).padStart(2,'0') + '-' + String(d.getDate()).padStart(2,'0');
}

function todayISO(){ return toISODate(new Date()); }

function parseValor(v){
  if(v===null || v===undefined || v==='') return null;
  const n = Number(String(v).replace(/[^\d.,-]/g,'').replace(/\.(?=\d{3})/g,'').replace(',','.'));
  return isNaN(n) ? null : n;
}

function valorParaBanco(v){
  if(v === null || v === undefined || String(v).trim() === '') return null;
  if(!/\d/.test(String(v))) return null;
  return parseValor(v);
}

function valorDoBanco(v){
  if(v === null || v === undefined || v === '') return '';
  const n = Number(v);
  return isNaN(n) ? '' : String(n);
}

function fmtBRL(n){
  return 'R$ ' + n.toLocaleString('pt-BR', { minimumFractionDigits: n % 1 === 0 ? 0 : 2, maximumFractionDigits: 2 });
}

function fmtUSD(n){
  return 'US$ ' + n.toLocaleString('pt-BR', { minimumFractionDigits: n % 1 === 0 ? 0 : 2, maximumFractionDigits: 2 });
}

function leadFromRow(r){
  const lead = {
    id: r.id, cliente: r.cliente || '', oportunidade: r.oportunidade || '',
    telefone: r.telefone || '', email: r.email || '', observacoes: r.observacoes || '',
    responsavelId: r.responsavel_id || '',
    ultimoContato: r.ultimo_contato || '', proximoContato: r.proximo_contato || '',
    etapa: r.etapa, produtoServico: r.produto_servico || '',
    valorPotencial: valorDoBanco(r.valor_potencial), valorFechado: valorDoBanco(r.valor_fechado),
    valorEmNegociacao: valorDoBanco(r.valor_em_negociacao),
    /* Saldo sob gestão do cliente da base, separado do patrimônio. */
    saldoInicial: valorDoBanco(r.saldo_inicial),
    /* O mesmo, lá fora: saldo offshore sob gestão, em dólar. */
    saldoInicialOffshore: valorDoBanco(r.saldo_inicial_offshore),
    /* Cliente da base: a captação nova em negociação, em reais. */
    valorEmCaptacao: valorDoBanco(r.valor_em_captacao),
    /* Em que custódia — e por isso em que moeda — está o valor acima. */
    captacaoCustodia: r.captacao_custodia || '',
    /* Em dólar, sempre. A conversão para real acontece na leitura, pela
       cotação que o admin mantém — nunca na gravação. */
    valorOffshore: valorDoBanco(r.valor_offshore),
    perdido: !!r.perdido, motivoPerda: r.motivo_perda || '',
    perdidoEm: r.perdido_em ? new Date(r.perdido_em).getTime() : null,
    ganho: !!r.ganho, ganhoEm: r.ganho_em ? new Date(r.ganho_em).getTime() : null,
    excluido: !!r.excluido, excluidoEm: r.excluido_em ? new Date(r.excluido_em).getTime() : null,
    historico: r.historico || [], atividades: r.atividades || [], alertas: r.alertas || [],
    briefing: r.briefing || {}, movimentacoes: r.movimentacoes || [],
    funil: r.funil || 'assessor', segmento: r.segmento || 'Advisory', esteira: r.esteira || 'novo',
    origem: r.origem || '', profissao: r.profissao || '', bancoAtual: r.banco_atual || '',
    tipoPessoa: r.tipo_pessoa || 'PF', contatoNome: r.contato_nome || '', contatoCargo: r.contato_cargo || '',
    /* Chave de reconciliação da atualização semanal da base. Sem ela nos dois
       tradutores, o assessor digita a conta na ficha e ela some no recarregar. */
    conta: r.conta || '',
    /* A conta do outro lado. Não é chave de nada — o vínculo vem pela conta
       onshore — mas é o número que o assessor precisa para falar com o BTG
       sobre o dinheiro lá fora. */
    contaOffshore: r.conta_offshore || '',
    nascimento: r.nascimento || '',
    grupoFamiliar: r.grupo_familiar || '',
    temperatura: r.temperatura || '',
    patrimonio: r.patrimonio || '', renda: r.renda || '', estadoCivil: r.estado_civil || '',
    produto: r.produto || '', origemLeadId: r.origem_lead_id || null,
    pautas: r.pautas || {},
    etapaDesde: r.etapa_desde ? new Date(r.etapa_desde).getTime() : null,
    criadoEm: r.criado_em ? new Date(r.criado_em).getTime() : Date.now(),
    atualizadoEm: r.atualizado_em ? new Date(r.atualizado_em).getTime() : 0,
  };
  return lead;
}

const ts = (ms) => ms ? new Date(ms).toISOString() : null;

function leadToRow(l){
  return {
    id: l.id, cliente: l.cliente || '', oportunidade: l.oportunidade || '',
    telefone: l.telefone || '', email: l.email || '', observacoes: l.observacoes || '',
    responsavel_id: l.responsavelId || null,
    ultimo_contato: l.ultimoContato || null, proximo_contato: l.proximoContato || null,
    etapa: l.etapa, produto_servico: l.produtoServico || '',
    valor_potencial: valorParaBanco(l.valorPotencial), valor_fechado: valorParaBanco(l.valorFechado),
    valor_em_negociacao: valorParaBanco(l.valorEmNegociacao),
    saldo_inicial: valorParaBanco(l.saldoInicial),
    saldo_inicial_offshore: valorParaBanco(l.saldoInicialOffshore),
    valor_em_captacao: valorParaBanco(l.valorEmCaptacao),
    /* Só existe com captação aberta: sem valor, a custódia não diz nada. */
    captacao_custodia: parseValor(l.valorEmCaptacao) ? custodiaCaptacao(l) : null,
    valor_offshore: valorParaBanco(l.valorOffshore),
    perdido: !!l.perdido, motivo_perda: l.motivoPerda || '', perdido_em: ts(l.perdidoEm),
    ganho: !!l.ganho, ganho_em: ts(l.ganhoEm),
    excluido: !!l.excluido, excluido_em: ts(l.excluidoEm),
    historico: l.historico || [], atividades: l.atividades || [], alertas: l.alertas || [],
    briefing: l.briefing || {}, movimentacoes: l.movimentacoes || [],
    funil: l.funil || 'assessor', segmento: l.segmento || 'Advisory', esteira: l.esteira || 'novo',
    origem: l.origem || null, profissao: l.profissao || null, banco_atual: l.bancoAtual || null,
    tipo_pessoa: l.tipoPessoa || 'PF', contato_nome: l.contatoNome || null, contato_cargo: l.contatoCargo || null,
    /* null e não '': a coluna tem índice único parcial, e vários '' colidiriam
       entre si — quem não tem conta precisa ficar nulo para ficar de fora. */
    conta: (l.conta || '').trim() || null,
    /* Mesmo motivo: índice único parcial. */
    conta_offshore: (l.contaOffshore || '').trim().toUpperCase() || null,
    nascimento: l.nascimento || null,
    grupo_familiar: (l.grupoFamiliar || '').trim() || null,
    temperatura: l.temperatura || null,
    patrimonio: l.patrimonio || null, renda: l.renda || null, estado_civil: l.estadoCivil || null,
    produto: l.produto || null, origem_lead_id: l.origemLeadId || null,
    pautas: l.pautas || {},
    etapa_desde: ts(l.etapaDesde) || new Date().toISOString(),
    criado_em: ts(l.criadoEm) || new Date().toISOString(),
    atualizado_em: new Date().toISOString(),
  };
}

function montarAplicacaoBase(res, leads, autor, agora, hoje){
  /* Offshore e Pershing gravam e escrevem em dólar: é a moeda de valorOffshore. */
  const off = res.tipo === 'offshore';
  const dolar = off || res.tipo === 'pershing';
  const fmt = dolar ? fmtUSD : fmtBRL;
  /* Lote: marca as entradas desta aplicação. Se a gravação cair no meio (celular perdeu a
     conexão, 18/11/2026) e alguém tentar de novo, o histórico e o alerta já gravados não se
     repetem, e a conta nova já criada não nasce duas vezes. */
  if(!res.lote) res.lote = uid('lote');
  const lote = res.lote;
  const doLote = (lista) => (lista || []).some(x => x && x.lote === lote);
  const porContaAtual = mapaPorConta(leads);
  const novos = res.atualizacoes.map((a) => {
    const l = leads.find(x => x.id === a.lead.id) || a.lead;
    const novo = { ...l, ...a.patch };
    const notas = [];

    if(Math.abs(a.delta) >= 0.01){
      /* O que se grava é o valor INICIAL, não o saldo do arquivo: as
         movimentações lançadas pelo assessor continuam somando por cima e
         seriam contadas duas vezes. Ver btgValorAlvo e btgCampoValor. */
      novo[a.campoValor] = fmt(a.valorAlvo);
      notas.push(a.vinculo ? 'saldo inicial ' + fmt(a.saldoBTG)
        : 'saldo ' + fmt(a.saldoAtual) + ' → ' + fmt(a.saldoBTG)
          + ' (' + (a.delta >= 0 ? '+' : '−') + fmt(Math.abs(a.delta)) + ')');
    }
    for(const c of a.campos) notas.unshift(!c.de && a.vinculo
      ? c.rotulo.toLowerCase() + ' ' + c.para + ' vinculada'
      : c.rotulo.toLowerCase() + ': ' + (c.de || '—') + ' → ' + c.para);

    /* Histórico só quando há o que contar: divergência fora da faixa ou
       mudança de cadastro. Rendimento dentro de 0,5% atualiza o saldo em
       silêncio.

       O motivo é de escala, e só aparece no volume real: quase toda conta
       rende alguma coisa toda semana, então registrar a variação de todas
       somaria ~52 entradas por cliente por ano, todas dizendo "rendeu
       0,2%". O histórico da ficha é cronológico — em um ano as transições
       que importam (R1→R2, a captação efetivada, a indicação na R4)
       ficariam soterradas sob extrato de rendimento.

       Nada se perde em auditoria: o saldo continua sendo o do arquivo, e o
       que se descarta é o registro de uma variação que ninguém iria ler. */
    if((a.alerta || a.campos.length) && !doLote(l.historico)){
      novo.historico = [...(l.historico || []), {
        id: uid('h'), lote, de: l.etapa, para: l.etapa, data: agora,
        resumo: (off ? 'Base BTG offshore · ' : 'Base BTG · ') + notas.join(' · ') + (a.alerta ? ' · fora da faixa de rendimento' : ''),
        autor,
        /* Marca como reconciliação pra timeline poder recolher esta
           entrada: é diferença de importação, não um fato que alguém
           contou — não deve competir em destaque com o que o assessor
           de fato escreveu. */
        reconciliacao: true,
      }];
    }

    /* 19/11/2026, pedido do Emil: a variação de saldo fora da faixa NÃO vira mais aviso "Divergência de saldo" no
       card. Com o BTG atualizando todo dia (posição, movimentação e captação líquida), o saldo é sempre o do BTG e
       a explicação está nas movimentações; o aviso só gerava ruído. A variação continua no histórico da ficha. */
    return stampLead(novo);
  });

  /* Conta nova com código reconhecido: nasce card, na hora, com o
     assessor já vinculado pelo código — é a mesma autorização que já
     valia para transferir carteira existente. Sem código, a conta
     continua só listada; cadastro manual, como sempre foi.
     Só o onshore cria: offshore e Pershing nunca criam cliente — a conta
     lá fora só existe depois que a onshore existe (ou, na Pershing, depois
     que alguém liga o número na ficha manualmente). */
  const criados = res.tipo !== 'onshore' ? [] : (res.novas || []).filter(n => n.donoPorCodigo && !porContaAtual.has(chaveConta(n.conta))).map((n) => {
    /* Cliente da base já é carteira de verdade — veio com saldo do BTG,
       não é prospect a triar. Por isso entra direto na R2, apresentação
       da proposta, pulando o Cliente Novo: esteira 'base' já autoriza esse
       pulo (ver TRAJETOS — de Cliente Novo só se vai para R2 quando a
       esteira é 'base'). */
    const historico = [{ id: uid('h'), de: null, para: 'R2', data: agora,
      resumo: 'Cadastrado pela importação da base BTG · vínculo pelo código ' + n.codigo,
      autor }];
    return stampLead(congelarSaldoInicialOffshore(null, congelarSaldoInicial(null, {
      ...emptyLead(n.donoPorCodigo.id),
      cliente: n.nome, conta: n.conta,
      etapa: 'R2', funil: 'assessor', esteira: 'base',
      segmento: segmentoPorPatrimonio(n.saldo) || 'Advisory',
      saldoInicial: fmtBRL(n.saldo),
      tipoPessoa: n.tipoPessoa || 'PF', nascimento: n.nascimento || '',
      origem: 'Base BTG', criadoEm: agora, etapaDesde: agora,
      historico, atividades: [],
    })));
  });
  return { novos, criados };
}

function stampLead(lead){ return { ...lead, atualizadoEm: Date.now() }; }

function emptyLead(ownerId){
  return {
    id: uid('l'), cliente:'', conta:'', oportunidade:'', telefone:'', email:'', observacoes:'',
    responsavelId: ownerId || '', ultimoContato: todayISO(), proximoContato:'',
    etapa: 'Cliente Novo', produtoServico:'', valorPotencial:'', valorEmNegociacao:'', valorOffshore:'', criadoEm: Date.now(),
    perdido:false, motivoPerda:'', perdidoEm:null,
    ganho:false, valorFechado:'', ganhoEm:null,
    historico: [], atividades: [], alertas: [], briefing: {}, movimentacoes: [],
    funil:'assessor', segmento:'Advisory', esteira:'novo',
    origem:'', profissao:'', bancoAtual:'',
    tipoPessoa:'PF', contatoNome:'', contatoCargo:'', grupoFamiliar:'', nascimento:'',
    temperatura:'',
    patrimonio:'', renda:'', estadoCivil:'',
    produto:'', origemLeadId:null, pautas:{}, etapaDesde: Date.now(),
    excluido:false, atualizadoEm: Date.now(),
  };
}

export { reconciliarBaseBTG, montarAplicacaoBase, faixaBTG, leadToRow, leadFromRow, chaveCodigo, chaveConta, mapaPorConta, DIA_MS };
