const { chromium } = require('playwright');
const {prep}=require('./mock.js');
const D=process.argv[2]+'/img/';
(async()=>{
  const b=await chromium.launch({proxy:{server:process.env.HTTPS_PROXY,bypass:'127.0.0.1,localhost'}});
  const ctx=await b.newContext({viewport:{width:1440,height:900},deviceScaleFactor:2}); await prep(ctx);
  const p=await ctx.newPage(); const er=[]; p.on('pageerror',e=>er.push(e.message)); p.on('dialog',d=>d.accept());
  await p.goto('http://127.0.0.1:8770/crm.html'); await p.waitForTimeout(2000);
  await p.screenshot({path:D+'09-crm-entrada-demo.png'});
  await p.click('button:has-text("'+process.argv[3]+'")'); await p.waitForTimeout(2000);
  const fecha=async()=>{ for(let i=0;i<3;i++){ const e=p.locator('.overlay button:has-text("Entendi"), .overlay button[aria-label="Fechar"]').first(); if(await e.count()){ await e.click(); await p.waitForTimeout(500);} else break; } };
  await fecha();
  await p.screenshot({path:D+'10-crm-dashboard.png'});
  const aba=async(txt,arq)=>{ const t=p.locator('button',{hasText:txt}).first(); if(await t.count()){ await t.click(); await p.waitForTimeout(900); await p.screenshot({path:D+arq}); console.log('ok aba',txt);} };
  await aba('Carteira','10b-crm-dash-carteira.png');
  await aba('Rotina do dia','10c-crm-dash-rotina.png');
  const tira=async(txt,arq)=>{ await fecha(); const el=p.locator('.mn-item',{hasText:txt}).first(); if(await el.count()){ await el.click(); await p.waitForTimeout(1300); await fecha(); await p.screenshot({path:D+arq}); console.log('ok',txt);} else console.log('não achei',txt); };
  await tira('Agenda','11-crm-agenda.png');
  await tira('Relacionamento','12-crm-relacionamento.png');
  await tira('Minha carteira','13-crm-carteira.png');
  // jornada (kanban)
  const nav=await p.$$eval('.mn-item',x=>x.map(e=>e.innerText.replace(/\s+/g,' ').trim())); console.log('menu', nav.join(' | '));
  await p.locator('button',{hasText:'Negócios'}).first().click(); await p.waitForTimeout(1000); await fecha();
  await p.screenshot({path:D+'14b-crm-negocios.png'});
  const nav2=await p.$$eval('.mn-item',x=>x.map(e=>e.innerText.replace(/\s+/g,' ').trim())); console.log('menu negócios', nav2.join(' | '));
  await p.locator('button',{hasText:'Jornada'}).first().click(); await p.waitForTimeout(1000); await fecha();
  console.log('erros', er.slice(0,5)); await b.close();
})();
