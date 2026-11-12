const { chromium } = require('playwright');
const M=process.argv[2]; const {prep}=require(M+'/mock.js'); const D=M+'/img/';
(async()=>{
  const b=await chromium.launch({proxy:{server:process.env.HTTPS_PROXY,bypass:'127.0.0.1,localhost'}});
  const ctx=await b.newContext({viewport:{width:1440,height:900},deviceScaleFactor:2}); await prep(ctx);
  let p=await ctx.newPage();
  await p.goto('http://127.0.0.1:8768/simulador.html'); await p.waitForTimeout(1500);
  for(const [id,v] of [['clientesAcoes',12],['volumeClienteAcoes',400],['ordensEnviadasAcoes',30],['roaAcoes',0.8],['clientesEstruturada',6],['volumeClienteEstruturada',800],['ordensEnviadasEstruturada',8],['roaEstruturada',1.5]])
    await p.evaluate(([id,v])=>{ const e=document.getElementById(id); e.value=v; e.dispatchEvent(new Event('input',{bubbles:true})); e.dispatchEvent(new Event('change',{bubbles:true})); },[id,v]);
  await p.waitForTimeout(600); await p.screenshot({path:D+'38-simulador.png'});
  for(const [f,a] of [['patrimonial.html','39-patrimonial.png'],['imobiliario.html','40-imobiliario.png']]){ p=await ctx.newPage(); await p.goto('http://127.0.0.1:8768/'+f); await p.waitForTimeout(1500); await p.screenshot({path:D+a}); }
  await b.close();
})();
