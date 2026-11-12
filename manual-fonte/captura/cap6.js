const { chromium } = require('playwright');
const {prep}=require('./mock.js');
const D=process.argv[2]+'/img/';
(async()=>{
  const b=await chromium.launch({proxy:{server:process.env.HTTPS_PROXY,bypass:'127.0.0.1,localhost'}});
  const ctx=await b.newContext({viewport:{width:1440,height:900},deviceScaleFactor:2}); await prep(ctx);
  const p=await ctx.newPage(); const er=[]; p.on('pageerror',e=>er.push(e.message));
  await p.goto('http://127.0.0.1:8768/diagnostico.html'); await p.waitForTimeout(1800);
  const set=async(id,v)=>{ const el=p.locator('#'+id); if(await el.count() && await el.isVisible()){ await el.fill(String(v)); await el.dispatchEvent('input'); await el.dispatchEvent('change'); await el.blur().catch(()=>{});} };
  for(const [id,v] of [['nome','Família Exemplo'],['idade','48'],['idadeAposentadoria','62'],['profissao','Empresário'],['rendaMensalExtra','R$ 45.000'],['patrimonioTotal','R$ 6.800.000'],['rentabilidadeAnual','4.5'],['aportesMensais','R$ 30.000'],['valorImoveis','R$ 4.200.000'],['valorEmpresas','R$ 9.000.000'],['coberturaAtual','R$ 2.000.000'],['custoVidaMensal','R$ 55.000'],['dividasRelevantes','R$ 800.000']]) await set(id,v);
  await p.waitForTimeout(1200);
  const info=await p.evaluate(()=>{ const out=[]; document.querySelectorAll('*').forEach(e=>{ const cs=getComputedStyle(e); if(/(auto|scroll)/.test(cs.overflowY) && e.scrollHeight>e.clientHeight+50) out.push([e.tagName,e.id,e.className,e.scrollHeight,e.clientHeight]); }); return out; });
  console.log(JSON.stringify(info));
  await p.addStyleTag({content:'html,body{height:auto!important;overflow:visible!important} *{max-height:none!important} '+info.map(x=>x[1]?'#'+x[1]:'.'+String(x[2]).split(' ')[0]).join(',')+'{overflow:visible!important;height:auto!important}'});
  await p.waitForTimeout(600);
  await p.locator('#reportPane').screenshot({path:D+'31-wealth-relatorio-full.png'});
  console.log(await p.evaluate(()=>document.documentElement.scrollHeight), er); await b.close();
})();
