const { chromium } = require('playwright');
const {prep,UID}=require('./mock.js');
const D=process.argv[2]+'/img/';
const CID='c0000000-0000-0000-0000-000000000001';
const CDI=[1.01,0.99,0.96,1.06,1.14,1.10,1.28,1.16,1.22,1.25,1.05];
const IBOV=[4.86,-2.64,6.08,3.69,1.45,1.33,-4.17,6.28,3.40,2.26,1.1];
const SP=[2.7,-1.4,-5.8,-0.8,6.2,5.0,2.2,1.9,3.5,2.3,1.0];
function lanc(){
  const out=[]; let s1=3800000,s2=1250000,s3=420000;
  for(let m=1;m<=10;m++){
    const r1=+(CDI[m-1]*1.06).toFixed(2), r2=+(IBOV[m-1]*0.45+0.3).toFixed(2), r3=+(SP[m-1]*0.6+0.2).toFixed(2);
    const apl1=m===4?300000:(m===8?150000:0), res1=m===6?120000:0;
    const rr1=Math.round(s1*r1/100), rr2=Math.round(s2*r2/100), rr3=Math.round(s3*r3/100);
    s1=s1+rr1+apl1-res1; s2=s2+rr2; s3=s3+rr3;
    const ativos=[
      {nome:'CDB BTG Pactual 104% CDI',categoria:'Renda Fixa',subcategoria:'Pós-fixado',inst:'BTG Pactual',taxa:'104% CDI',vencimento:'2028-03-15',posicao:Math.round(s1*0.32),rentMes:CDI[m-1]*1.04,rentAno:0,rent12m:0,rentInicio:0},
      {nome:'LCA IPCA + 6,8%',categoria:'Renda Fixa',subcategoria:'Inflação',inst:'BTG Pactual',taxa:'IPCA + 6,8%',vencimento:'2029-08-15',posicao:Math.round(s1*0.24),rentMes:0.92,rentAno:0,rent12m:0,rentInicio:0},
      {nome:'Tesouro Prefixado 2029',categoria:'Renda Fixa',subcategoria:'Pré-fixado',inst:'BTG Pactual',taxa:'13,1% a.a.',vencimento:'2029-01-01',posicao:Math.round(s1*0.14),rentMes:1.02,rentAno:0,rent12m:0,rentInicio:0},
      {nome:'Fundo Multimercado Macro',categoria:'Fundos',subcategoria:'Multimercado',inst:'BTG Pactual',taxa:'',vencimento:'',posicao:Math.round(s1*0.18),rentMes:1.1,rentAno:0,rent12m:0,rentInicio:0},
      {nome:'Previdência VGBL Renda Fixa',categoria:'Previdência',subcategoria:'Pós-fixado',inst:'BTG Pactual',taxa:'',vencimento:'',posicao:Math.round(s1*0.12),rentMes:0.98,rentAno:0,rent12m:0,rentInicio:0},
      {nome:'Carteira de Ações Dividendos',categoria:'Renda Variável',subcategoria:'',inst:'BTG Pactual',taxa:'',vencimento:'',posicao:s2,rentMes:r2,rentAno:0,rent12m:0,rentInicio:0}];
    ativos.forEach(a=>{a.rentMes=+(+a.rentMes).toFixed(2); a.rentAno=+(a.rentMes*m*0.97).toFixed(2); a.rent12m=+(a.rentMes*11.4).toFixed(2); a.rentInicio=+(a.rentMes*m*0.97).toFixed(2);});
    out.push({cliente_id:CID,mes:m,ano:2026,contas:[
      {nome:'Conta principal',inst:'BTG Pactual',saldo:s1,apl:apl1,res:res1,rendPct:r1,rendRs:rr1,moeda:'BRL'},
      {nome:'Renda variável',inst:'BTG Pactual',saldo:s2,apl:0,res:0,rendPct:r2,rendRs:rr2,moeda:'BRL'},
      {nome:'Conta internacional',inst:'BTG Pactual Cayman',saldo:s3,apl:0,res:0,rendPct:r3,rendRs:rr3,moeda:'USD'}],
      indicadores:{cdi:CDI[m-1],ipca:[0.9,0.6,1.1,0.8,0.4,0.7,0.5,0.9,0.6,0.8][m-1],ibov:IBOV[m-1],sp500:SP[m-1],poup:0.6,dolar:[-1.5,0.8,-2.1,1.0,0.3,-0.9,1.6,-0.4,0.2,-0.7][m-1],ouro:1.2,ifix:0.8,ptax:5.35,carta:'',
        vencimentos:[{ativo:'CDB BTG Pactual 104% CDI',inst:'BTG Pactual',taxa:'104% CDI',data:'2026-12-15',valor:350000},{ativo:'LCI 95% CDI',inst:'BTG Pactual',taxa:'95% CDI',data:'2027-02-10',valor:200000}],
        ativos, estrategias:{pos:0,infl:0,pre:0,ma:0,rv:0,intl:0,alt:0}}});
  }
  return out;
}
const CARTA='<p><b>Outubro em resumo.</b> O mês foi de juros ainda altos e bolsa em recuperação. A carteira manteve o foco em renda fixa atrelada ao CDI e à inflação, com a parcela de ações contribuindo para o resultado.</p><p>Para os próximos meses, seguimos com a estratégia definida no comitê: proteção contra inflação, liquidez para os compromissos da família e exposição internacional gradual.</p>';
const COM={nome:'Ana Ribeiro',competencia:'2026-10-01',meses:['2026-10-01','2026-09-01','2026-08-01'],
  pagamento:{bruto:18640.5,pct_imposto:6,imposto:1118.43,valor:17522.07,pago_em:null,empresa:'Adami Captal'},
  linhas:[
   {tipo:'receita',origem:'BTG',cliente:'Família Exemplo',conta:'001234',categoria:'Renda Fixa',produto:'CDB',descricao:'Comissão de distribuição',gerada:9800,parte:4900},
   {tipo:'receita',origem:'BTG',cliente:'Família Exemplo',conta:'001234',categoria:'Fundos',produto:'Multimercado',descricao:'Taxa de administração',gerada:6200,parte:3100},
   {tipo:'receita',origem:'BTG',cliente:'Cliente Modelo',conta:'004567',categoria:'Renda Variável',produto:'Corretagem',descricao:'Operações do mês',gerada:8400,parte:4200},
   {tipo:'receita',origem:'BTG',cliente:'Cliente Modelo',conta:'004567',categoria:'Previdência',produto:'VGBL',descricao:'Comissão de distribuição',gerada:5200,parte:2600},
   {tipo:'receita',origem:'Seguros',cliente:'Família Exemplo',conta:'',categoria:'Seguros',produto:'Vida',descricao:'Apólice nova',gerada:7681,parte:3840.5}]};
(async()=>{
  const b=await chromium.launch({proxy:{server:process.env.HTTPS_PROXY,bypass:'127.0.0.1,localhost'}});
  const er=[];
  const L=lanc();
  for(const admin of [true,false]){
    const ctx=await b.newContext({viewport:{width:1440,height:900},deviceScaleFactor:2});
    await prep(ctx,async(u,n)=>{
      if(n==='clientes') return [{id:CID,nome:'Família Exemplo',assessor_id:UID,contas_btg:['001234']}];
      if(n==='lancamentos' && r0(u)) return L;
      if(n==='cartas') return [{mes:10,ano:2026,conteudo:CARTA}];
      if(n==='perfis') return [{user_id:UID,nome:'Ana Ribeiro',admin:admin,mesa_rv:false,super:false}];
      if(n==='minhas_permissoes') return {perfis:[admin?'administrador':'assessor'],permissoes:['ferramenta.crm','ferramenta.carteiras','ferramenta.minhacomissao'].concat(admin?['carteiras.todas']:[])};
      if(n==='comissao_minha') return COM;
    });
    function r0(u){ return u.search.includes('select='); }
    const p=await ctx.newPage(); p.on('pageerror',e=>er.push(e.message)); p.on('dialog',d=>d.accept());
    await p.goto('http://127.0.0.1:8768/index.html'); await p.waitForTimeout(2200);
    await p.evaluate(()=>{ irParaApp('carteiras'); }); await p.waitForTimeout(800);
    await p.evaluate(()=>{ S.mes=10; S.ano=2026; S.cliente=db.clientes[0]&&db.clientes[0].id; montarRascunho(); render(); }); await p.waitForTimeout(800);
    if(admin){
      S0=await p.evaluate(()=>S.tab);
      await p.screenshot({path:D+'50-cart-preencher.png'});
      await p.screenshot({path:D+'50b-cart-preencher-full.png',fullPage:true});
      await p.evaluate(()=>{ S.tab='carta'; render(); }); await p.waitForTimeout(500); await p.screenshot({path:D+'51-cart-carta.png'});
      await p.evaluate(()=>{ S.tab='historico'; render(); }); await p.waitForTimeout(700); await p.screenshot({path:D+'53-cart-historico.png'});
    } else {
      await p.evaluate(()=>{ S.tab='relatorio'; render(); }); await p.waitForTimeout(1200);
      await p.screenshot({path:D+'52-cart-relatorio.png'});
      await p.screenshot({path:D+'52b-cart-relatorio-full.png',fullPage:true});
      // PDF do relatório
      await p.emulateMedia({media:'print'});
      await p.pdf({path:process.argv[2]+'/exemplo-relatorio.pdf',format:'A4',printBackground:true,preferCSSPageSize:true});
      await p.emulateMedia({media:'screen'});
      const q=await ctx.newPage(); q.on('pageerror',e=>er.push('com '+e.message));
      await q.goto('http://127.0.0.1:8768/minha-comissao.html'); await q.waitForTimeout(1800);
      await q.click('tr.clica >> nth=0').catch(()=>{}); await q.waitForTimeout(300);
      await q.screenshot({path:D+'43-minha-comissao.png'});
    }
    await ctx.close();
  }
  console.log('erros',er); await b.close();
})();
var S0;
