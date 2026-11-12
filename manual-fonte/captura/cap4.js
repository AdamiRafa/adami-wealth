const { chromium } = require('playwright');
const {prep}=require('./mock.js');
const D=process.argv[2]+'/img/';
(async()=>{
  const b=await chromium.launch({proxy:{server:process.env.HTTPS_PROXY,bypass:'127.0.0.1,localhost'}});
  const ctx=await b.newContext({viewport:{width:1440,height:900},deviceScaleFactor:2}); await prep(ctx);
  const er=[];
  const abre=async(f)=>{ const p=await ctx.newPage(); p.on('pageerror',e=>er.push(f+': '+e.message)); p.on('dialog',d=>d.accept()); await p.goto('http://127.0.0.1:8768/'+f); await p.waitForTimeout(1800); return p; };
  const set=async(p,id,v)=>{ const el=p.locator('#'+id); if(await el.count() && await el.isVisible()){ await el.fill(String(v)); await el.dispatchEvent('input'); await el.dispatchEvent('change'); await el.blur().catch(()=>{});} else console.log('sem campo',id); };
  // Wealth Planning
  let p=await abre('diagnostico.html');
  for(const [id,v] of [['nome','Família Exemplo'],['idade','48'],['idadeAposentadoria','62'],['profissao','Empresário'],['rendaMensalExtra','R$ 45.000'],['patrimonioTotal','R$ 6.800.000'],['rentabilidadeAnual','4.5'],['aportesMensais','R$ 30.000'],['valorImoveis','R$ 4.200.000'],['valorEmpresas','R$ 9.000.000'],['coberturaAtual','R$ 2.000.000'],['custoVidaMensal','R$ 55.000'],['dividasRelevantes','R$ 800.000']]) await set(p,id,v);
  await p.selectOption('#uf',{label:'RS'}).catch(()=>p.selectOption('#uf','RS').catch(()=>{}));
  await p.waitForTimeout(1200);
  await p.screenshot({path:D+'30-wealth-form.png'});
  await p.screenshot({path:D+'31-wealth-relatorio-full.png',fullPage:true});
  console.log('wealth altura', await p.evaluate(()=>document.documentElement.scrollHeight));
  // Liberdade
  p=await abre('liberdade.html');
  for(const [id,v] of [['nome','Família Exemplo'],['idade','45'],['idadeApos','60'],['patrimonio','R$ 2.400.000,00'],['aporte','R$ 15.000,00'],['retirada','R$ 25.000,00']]) await set(p,id,v);
  await p.waitForTimeout(1000); await p.screenshot({path:D+'32-liberdade.png'}); await p.screenshot({path:D+'33-liberdade-full.png',fullPage:true});
  // Ágio
  p=await abre('agio.html');
  for(const [id,v] of [['vAtual','R$ 500.000,00'],['tAtual','11'],['vNovo','R$ 480.000,00'],['tNovo','13.5']]) await set(p,id,v);
  await p.waitForTimeout(900); await p.screenshot({path:D+'34-agio.png'});
  // Boletas
  p=await abre('boletas.html');
  await set(p,'cliente','Família Exemplo'); await set(p,'disponivel','R$ 1.000.000,00'); await p.waitForTimeout(500);
  await p.screenshot({path:D+'35-boletas.png'});
  // Processo comercial
  p=await abre('processo.html'); await p.screenshot({path:D+'36-processo.png'}); await p.screenshot({path:D+'37-processo-full.png',fullPage:true});
  // Simulador RV, Patrimonial, Imobiliário, Alocação, Mesa RV, Minha comissão
  for(const [f,a] of [['simulador.html','38-simulador.png'],['patrimonial.html','39-patrimonial.png'],['imobiliario.html','40-imobiliario.png'],['alocacao.html','41-alocacao.png'],['rv.html','42-mesa-rv.png'],['minha-comissao.html','43-minha-comissao.png']]){ p=await abre(f); await p.screenshot({path:D+a}); }
  console.log('erros', er); await b.close();
})();
