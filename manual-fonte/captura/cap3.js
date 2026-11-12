const { chromium } = require('playwright');
const {prep}=require('./mock.js');
const D=process.argv[2]+'/img/';
(async()=>{
  const b=await chromium.launch({proxy:{server:process.env.HTTPS_PROXY,bypass:'127.0.0.1,localhost'}});
  const ctx=await b.newContext({viewport:{width:1440,height:900},deviceScaleFactor:2}); await prep(ctx);
  const p=await ctx.newPage(); const er=[]; p.on('pageerror',e=>er.push(e.message)); p.on('dialog',d=>d.accept());
  await p.goto('http://127.0.0.1:8770/crm.html'); await p.waitForTimeout(1800);
  await p.click('button:has-text("Pedro Forini")'); await p.waitForTimeout(2000);
  const fecha=async()=>{ for(let i=0;i<3;i++){ const e=p.locator('.overlay button:has-text("Entendi")').first(); if(await e.count()){ await e.click(); await p.waitForTimeout(500);} else break; } };
  await fecha();
  await p.screenshot({path:D+'20-crm-dashboard-casa.png'});
  // abas do painel (dentro do conteúdo)
  const aba=async(txt,arq)=>{ const t=p.locator('.pn-abas button',{hasText:txt}).first(); if(await t.count()){ await t.click(); await p.waitForTimeout(900); await p.screenshot({path:D+arq}); console.log('ok aba',txt);} else console.log('sem aba',txt); };
  await aba('Carteira','21-crm-dash-carteira.png');
  await aba('Assessores','22-crm-dash-assessores.png');
  await p.locator('.mn-item',{hasText:'Minha carteira'}).first().click().catch(()=>{}); await p.waitForTimeout(1200); await fecha();
  const nav=await p.$$eval('.mn-item',x=>x.map(e=>e.innerText.replace(/\s+/g,' ').trim())); console.log('menu', nav.join(' | '));
  await p.screenshot({path:D+'23-crm-indicadores.png'});
  await p.locator('.mn-item',{hasText:'Relacionamento'}).first().click(); await p.waitForTimeout(1200); await fecha();
  await p.screenshot({path:D+'24-crm-jornada.png'});
  // abre uma ficha
  const c=p.locator('text=Grupo Bertoldi').first(); if(await c.count()){ await c.click(); await p.waitForTimeout(1500); await p.screenshot({path:D+'25-crm-ficha.png'}); console.log('ficha ok'); }
  console.log('erros', er.slice(0,5)); await b.close();
})();
