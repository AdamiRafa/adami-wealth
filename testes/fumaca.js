// Teste de fumaça: abre cada módulo num Chromium de verdade, com o Supabase simulado
// (testes/simulador.js), e falha se aparecer erro de JavaScript. No Hub, percorre
// também as abas das Carteiras e confere que o relatório desenha as páginas.
// Uso: node testes/fumaca.js http://127.0.0.1:8768
const { chromium } = require('playwright');
const fs = require('fs'), path = require('path');
const { prep, CID } = require('./simulador.js');
const BASE = (process.argv[2] || 'http://127.0.0.1:8768').replace(/\/$/, '');
const RAIZ = path.join(__dirname, '..');
(async () => {
  const b = await chromium.launch();
  const ctx = await b.newContext({ viewport: { width: 1440, height: 900 } });
  await prep(ctx);
  let falhas = 0;
  const arqs = fs.readdirSync(RAIZ).filter(f => f.endsWith('.html')).sort();
  for (const f of arqs) {
    const p = await ctx.newPage(); const er = [];
    p.on('pageerror', e => er.push(e.message));
    p.on('console', m => { if (m.type() === 'error' && !/Failed to load resource|net::|ERR_FAILED|Content Security Policy/.test(m.text())) er.push('console: ' + m.text().slice(0, 160)); });
    p.on('dialog', d => d.accept());
    await p.goto(BASE + '/' + f); await p.waitForTimeout(1800);
    const barra = await p.locator('.awb-bt').count();
    if (!barra) er.push('sem o botão ? da barra comum (comum/barra.js)');
    if (f === 'index.html') {
      for (const tab of ['fechamento', 'preencher', 'carta', 'historico', 'relatorio']) {
        try {
          await p.evaluate(([c, t]) => { if (S.app !== 'carteiras') irParaApp('carteiras'); S.cliente = c; montarRascunho(); irMes(10, 2026); setTab(t); }, [CID, tab]);
          await p.waitForTimeout(tab === 'relatorio' ? 1500 : 500);
        } catch (e) { er.push('aba ' + tab + ': ' + e.message.split('\n')[0]); }
      }
      const pgs = await p.locator('#view .pg').count();
      if (!pgs) er.push('o Relatório Consolidado não desenhou nenhuma página');
    }
    console.log((er.length ? 'FALHOU ' : 'ok     ') + f + (er.length ? '\n   ' + er.slice(0, 5).join('\n   ') : ''));
    if (er.length) falhas++;
    await p.close();
  }
  await b.close();
  if (falhas) { console.error(falhas + ' módulo(s) com erro.'); process.exit(1); }
  console.log('Todos os ' + arqs.length + ' módulos abriram sem erro.');
})().catch(e => { console.error(e); process.exit(1); });
