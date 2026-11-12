const { chromium } = require('playwright');
const {prep}=require('./mock.js');
const D=process.argv[2]+'/img/';
(async()=>{
  const b=await chromium.launch({proxy:{server:process.env.HTTPS_PROXY,bypass:'127.0.0.1,localhost'}});
  const ctx=await b.newContext({viewport:{width:1440,height:900},deviceScaleFactor:2}); await prep(ctx);
  const er=[];
  // login (sem sessão)
  const ctx0=await b.newContext({viewport:{width:1440,height:900},deviceScaleFactor:2});
  const p0=await ctx0.newPage(); p0.on('pageerror',e=>er.push('login '+e.message));
  await p0.goto('http://127.0.0.1:8768/index.html'); await p0.waitForTimeout(1500); await p0.screenshot({path:D+'01-login.png'});
  await p0.evaluate(()=>{ try{ modoLogin('novo'); }catch(e){} }); await p0.waitForTimeout(400); await p0.screenshot({path:D+'02-primeiro-acesso.png'});
  // código
  const p=await ctx.newPage(); p.on('pageerror',e=>er.push(e.message)); p.on('dialog',d=>d.accept());
  await p.goto('http://127.0.0.1:8768/index.html'); await p.waitForTimeout(2500);
  await p.screenshot({path:D+'04-inicio.png'});
  await p.evaluate(()=>{ CODIGO_EMAIL='ana.ribeiro@adamicaptal.com.br'; CODIGO_ESTADO='enviado'; mostrarCodigo(null); }); await p.waitForTimeout(300);
  await p.screenshot({path:D+'03-codigo.png'});
  await p.goto('http://127.0.0.1:8768/index.html'); await p.waitForTimeout(2500);
  await p.evaluate(()=>abrirSeguranca()); await p.waitForSelector('text=App autenticador'); await p.waitForTimeout(300);
  await p.screenshot({path:D+'05-seguranca.png'});
  await p.click('#segx button:has-text("Ligar o app")'); await p.waitForSelector('#appQr svg'); await p.waitForTimeout(300);
  await p.screenshot({path:D+'06-qr.png'});
  console.log('erros', er); await b.close();
})();
