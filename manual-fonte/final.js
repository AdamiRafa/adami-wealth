const { chromium } = require('playwright');
const fs=require('fs');
const B='http://127.0.0.1:8771/';
const P=JSON.parse(fs.readFileSync('paginas.json','utf8'));
const pe=`<div style="width:100%;font-family:Inter,Arial,sans-serif;font-size:7.5pt;color:#7a8698;padding:0 18mm;display:flex;justify-content:space-between;align-items:center"><span><span style="color:#C0A265;letter-spacing:.18em;font-weight:600">ADAMI CAPTAL</span>&nbsp;&nbsp;·&nbsp;&nbsp;Manual do Hub</span><span class="pageNumber"></span></div>`;
(async()=>{
  const b=await chromium.launch({proxy:{server:process.env.HTTPS_PROXY,bypass:'127.0.0.1,localhost'}});
  const p=await b.newPage();
  await p.goto(B+'manual.html',{waitUntil:'networkidle'});
  await p.evaluate(P=>{ document.querySelectorAll('[data-pg]').forEach(e=>{ e.textContent=P[e.getAttribute('data-pg')]||''; }); },P);
  await p.evaluate(()=>document.fonts.ready);
  await p.pdf({path:'miolo.pdf',format:'A4',printBackground:true,preferCSSPageSize:true,displayHeaderFooter:true,headerTemplate:'<div></div>',footerTemplate:pe});
  await b.close();
})();
