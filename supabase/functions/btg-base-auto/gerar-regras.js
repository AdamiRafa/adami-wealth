// Gera regras.js a partir do crm.html: as mesmas funções que a tela "Atualizar base" usa
// (reconciliarBaseBTG, montarAplicacaoBase e o que elas chamam), copiadas como estão.
// Assim a atualização automática do servidor nunca tem uma regra diferente da prévia do CRM.
//
//   node supabase/functions/btg-base-auto/gerar-regras.js            grava regras.js
//   node supabase/functions/btg-base-auto/gerar-regras.js --conferir  só confere (usado em testes/verificar.sh)
//
// Precisa de acorn e eslint-scope (os mesmos de testes/escopo.js).
const fs = require('fs'), path = require('path'), acorn = require('acorn'), es = require('eslint-scope');
const RAIZ = path.join(__dirname, '..', '..', '..');
const DESTINO = path.join(__dirname, 'regras.js');
const RAIZES = ['reconciliarBaseBTG', 'montarAplicacaoBase', 'faixaBTG', 'leadToRow', 'leadFromRow',
  'chaveCodigo', 'chaveConta', 'mapaPorConta', 'DIA_MS'];
const PERMITIDOS = new Set(['Map', 'Set', 'String', 'Math', 'parseFloat', 'parseInt', 'isFinite', 'Date', 'undefined',
  'Object', 'RegExp', 'Number', 'isNaN', 'Array', 'JSON', 'Boolean', 'Infinity', 'NaN', 'Error']);

const html = fs.readFileSync(path.join(RAIZ, 'crm.html'), 'utf8');
const m = html.match(/<script type="module">([\s\S]*?)<\/script>/);
if(!m) throw new Error('crm.html: bloco <script type="module"> não encontrado');
const src = m[1];
const ast = acorn.parse(src, { ecmaVersion: 2022, sourceType: 'module', ranges: true });
const decl = new Map();
for(const n of ast.body){
  if(n.type === 'FunctionDeclaration') decl.set(n.id.name, n);
  else if(n.type === 'VariableDeclaration') for(const d of n.declarations){ if(d.id.type === 'Identifier') decl.set(d.id.name, n); }
}
const sm = es.analyze(ast, { ecmaVersion: 2022, sourceType: 'module' });
const mod = sm.scopes.find(x => x.type === 'module');
const refs = [];
for(const sc of sm.scopes) for(const r of sc.references) refs.push(r);
function livres(no){
  const s = new Set();
  for(const r of refs){
    const id = r.identifier;
    if(id.range[0] < no.range[0] || id.range[1] > no.range[1]) continue;
    if(r.resolved && r.resolved.scope === mod) s.add(id.name);
    else if(!r.resolved) s.add('@' + id.name);
  }
  return s;
}
const vistos = new Set(), fila = [...RAIZES], estranhos = new Set();
while(fila.length){
  const n = fila.shift(); if(vistos.has(n)) continue; vistos.add(n);
  const no = decl.get(n); if(!no) throw new Error('crm.html: ' + n + ' não é declaração de topo');
  for(const x of livres(no)){
    if(x[0] === '@'){ if(!PERMITIDOS.has(x.slice(1))) estranhos.add(x.slice(1)); }
    else if(!vistos.has(x)) fila.push(x);
  }
}
if(estranhos.size) throw new Error('As regras passaram a usar coisas do navegador: ' + [...estranhos].join(', ') + '. O servidor não tem isso.');
const nos = [...new Set([...vistos].map(n => decl.get(n)))].sort((a, b) => a.range[0] - b.range[0]);
const nomes = [];
for(const no of nos){
  if(no.type === 'FunctionDeclaration') nomes.push(no.id.name);
  else for(const d of no.declarations) nomes.push(d.id.name);
}
const texto = '// GERADO por gerar-regras.js a partir do crm.html. Não edite aqui: edite o crm.html e gere de novo.\n'
  + '// deno-lint-ignore-file\n'
  + nos.map(no => src.slice(no.range[0], no.range[1])).join('\n\n') + '\n\n'
  + 'export { ' + RAIZES.join(', ') + ' };\n';
if(process.argv.includes('--conferir')){
  const atual = fs.existsSync(DESTINO) ? fs.readFileSync(DESTINO, 'utf8') : '';
  if(atual !== texto){ console.error('supabase/functions/btg-base-auto/regras.js está diferente do crm.html. Rode: node supabase/functions/btg-base-auto/gerar-regras.js e publique a função btg-base-auto de novo.'); process.exit(1); }
  console.log('regras.js da btg-base-auto: igual ao crm.html (' + nomes.length + ' declarações)');
} else {
  fs.writeFileSync(DESTINO, texto);
  console.log('regras.js gravado: ' + nomes.length + ' declarações, ' + texto.split('\n').length + ' linhas');
}
