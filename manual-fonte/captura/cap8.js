const { chromium, devices } = require('playwright');
const M=process.argv[2]; const {prep,UID}=require(M+'/mock.js'); const D=M+'/img/';
const fs=require('fs'); const src=fs.readFileSync(M+'/cap5.js','utf8');
const CID='c0000000-0000-0000-0000-000000000001';
eval(src.slice(src.indexOf('const CDI='), src.indexOf('(async()=>')).replace(/^const /gm,'var '));
(async()=>{
  const b=await chromium.launch({proxy:{server:process.env.HTTPS_PROXY,bypass:'127.0.0.1,localhost'}});
  const extra=async(u,n)=>{
    if(n==='meu_checklist') return {app:false,atividade:false,jornada:4,jornada_sem_contato:2,aparelho:false};
    if(n==='clientes') return [{id:CID,nome:'Família Exemplo',assessor_id:UID,contas_btg:['001234']}];
    if(n==='lancamentos' && u.search.includes('select=')) return lanc();
    if(n==='cartas') return [{mes:10,ano:2026,conteudo:CARTA}];
  };
  const ctx=await b.newContext({viewport:{width:1440,height:900},deviceScaleFactor:2}); await prep(ctx,extra);
  const er=[]; let p=await ctx.newPage(); p.on('pageerror',e=>er.push(e.message)); p.on('dialog',d=>d.accept());
  await p.goto('http://127.0.0.1:8768/index.html'); await p.waitForTimeout(2500);
  await p.screenshot({path:D+'60-inicio-passos.png'});
  await p.evaluate(()=>{ CODIGO_EMAIL='ana.ribeiro@adamicaptal.com.br'; CODIGO_ESTADO='enviado'; mostrarCodigo(null); }); await p.waitForTimeout(1200);
  await p.screenshot({path:D+'63-codigo-lembrar.png'});
  await p.goto('http://127.0.0.1:8768/index.html'); await p.waitForTimeout(2500);
  await p.evaluate(()=>{ irParaApp('carteiras'); S.mes=10; S.ano=2026; S.cliente=db.clientes[0].id; S.tab='relatorio'; montarRascunho(); render(); }); await p.waitForTimeout(1000);
  await p.screenshot({path:D+'64-cart-botoes.png'});
  await p.click('#btnPdfTodos'); await p.waitForTimeout(500); await p.screenshot({path:D+'66-pdf-todos.png'});
  // CRM demo: ficha com ferramentas e painel de ajuda
  p=await ctx.newPage(); p.on('pageerror',e=>er.push('crm '+e.message)); p.on('dialog',d=>d.accept());
  await p.goto('http://127.0.0.1:8770/crm.html'); await p.waitForTimeout(1500);
  await p.click('button:has-text("Pedro Forini")'); await p.waitForTimeout(2000);
  for(let i=0;i<3;i++){ const e=p.locator('.overlay button:has-text("Entendi")').first(); if(await e.count()){ await e.click(); await p.waitForTimeout(400);} else break; }
  await p.evaluate(()=>{ location.hash='#ficha=l-3'; }); await p.waitForTimeout(1200);
  await p.locator('.ferr-cliente').scrollIntoViewIfNeeded(); await p.waitForTimeout(300); await p.screenshot({path:D+'62-ficha-ferr.png'});
  await p.locator('.modal-close').first().click(); await p.waitForTimeout(400);
  await p.locator('.mn-item',{hasText:'Relacionamento'}).first().click(); await p.waitForTimeout(800);
  await p.keyboard.press('Control+k'); await p.waitForTimeout(300); await p.fill('#awbBusca','pras'); await p.waitForTimeout(900);
  await p.screenshot({path:D+'61-ajuda.png'});
  await p.click('button[data-a="reportar"]'); await p.fill('#awbTexto','Ao salvar a atividade, a tela ficou em branco.'); await p.waitForTimeout(200);
  await p.screenshot({path:D+'67-reportar.png'});
  // Liberdade aberta pela ficha
  p=await ctx.newPage(); p.on('pageerror',e=>er.push('lib '+e.message));
  await p.goto('http://127.0.0.1:8768/liberdade.html'); await p.waitForTimeout(1200);
  await p.evaluate(()=>{ window.AdamiCRM.faixa({id:'l-3',nome:'Família Exemplo'},3); document.getElementById('nome').value='Família Exemplo'; document.getElementById('idade').value='48'; document.getElementById('patrimonio').value='R$ 6.049.066'; ['nome','idade','patrimonio'].forEach(i=>document.getElementById(i).dispatchEvent(new Event('input',{bubbles:true}))); });
  await p.waitForTimeout(600); await p.screenshot({path:D+'65-liberdade-ficha.png'});
  // celular
  const cc=await b.newContext({...devices['iPhone 13']}); await prep(cc,extra);
  p=await cc.newPage(); await p.goto('http://127.0.0.1:8768/index.html'); await p.waitForTimeout(2500);
  await p.screenshot({path:D+'68-celular.png'});
  console.log('erros',er); await b.close();
})();
