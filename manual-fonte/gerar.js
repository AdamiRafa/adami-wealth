const { chromium } = require('playwright');
const fs=require('fs');
const B='http://127.0.0.1:8771/';
const pe=`<div style="width:100%;font-family:Inter,Arial,sans-serif;font-size:7.5pt;color:#7a8698;padding:0 18mm;display:flex;justify-content:space-between;align-items:center"><span><span style="color:#C0A265;letter-spacing:.18em;font-weight:600">ADAMI CAPTAL</span>&nbsp;&nbsp;·&nbsp;&nbsp;Manual do Hub</span><span class="pageNumber"></span></div>`;
(async()=>{
  const b=await chromium.launch({proxy:{server:process.env.HTTPS_PROXY,bypass:'127.0.0.1,localhost'}});
  const p=await b.newPage();
  const gera=async(arq,pag)=>{
    await p.goto(B+'manual.html',{waitUntil:'networkidle'});
    if(pag){ await p.evaluate(P=>{ document.querySelectorAll('[data-pg]').forEach(e=>{ e.textContent=P[e.getAttribute('data-pg')]||''; }); },pag); }
    await p.evaluate(()=>document.fonts.ready);
    await p.pdf({path:arq,format:'A4',printBackground:true,preferCSSPageSize:true,displayHeaderFooter:true,headerTemplate:'<div></div>',footerTemplate:pe});
  };
  await gera('miolo1.pdf',null);
  await p.goto(B+'capa.html',{waitUntil:'networkidle'}); await p.evaluate(()=>document.fonts.ready);
  await p.pdf({path:'capa.pdf',format:'A4',printBackground:true,preferCSSPageSize:true});
  // fontes carregadas?
  console.log(await p.evaluate(()=>[...document.fonts].filter(f=>f.status==='loaded').map(f=>f.family).join(',')));
  await b.close();
})();
