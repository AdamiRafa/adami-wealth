// 1) node --check em cada <script>; 2) variáveis usadas sem declaração (acorn + eslint-scope)
const fs=require('fs'),acorn=require('acorn'),es=require('eslint-scope'),{execSync}=require('child_process');
const arq=process.argv[2]; const html=fs.readFileSync(arq,'utf8');
const blocos=[...html.matchAll(/<script(?![^>]*src=)[^>]*>([\s\S]*?)<\/script>/g)].map(m=>m[1]);
const globaisNav=new Set(Object.getOwnPropertyNames(globalThis).concat(['window','document','location','history','localStorage','sessionStorage','navigator','fetch','alert','confirm','prompt','setTimeout','clearTimeout','setInterval','clearInterval','URLSearchParams','URL','Blob','FileReader','atob','btoa','escape','unescape','requestAnimationFrame','getComputedStyle','Image','Event','CustomEvent','HTMLElement','Node','MutationObserver','performance','crypto','TextEncoder','TextDecoder','AbortController','FormData','Headers','Response','Request','structuredClone','queueMicrotask','print','open','close','scrollTo','innerWidth','innerHeight','devicePixelRatio','matchMedia','DOMParser','XMLSerializer','supabase','XLSX','jspdf','pdfjsLib','React','ReactDOM','event']));
let todos=''; blocos.forEach((b,i)=>{ const tmp=require('os').tmpdir()+'/_b.js'; fs.writeFileSync(tmp,b); execSync('node --check '+tmp); todos+=b+'\n;\n'; });
const ast=acorn.parse(todos,{ecmaVersion:2022,sourceType:'script',locations:true,ranges:true});
const sm=es.analyze(ast,{ecmaVersion:2022});
const g=sm.globalScope; const decl=new Set(g.variables.map(v=>v.name));
const faltando=new Map();
g.through.forEach(r=>{ const n=r.identifier.name; if(!decl.has(n)&&!globaisNav.has(n)) faltando.set(n,r.identifier.loc.start.line); });
console.log(arq.split('/').pop(), '| blocos:',blocos.length,'| sintaxe ok | sem declaração:', faltando.size?[...faltando].map(([n,l])=>n+'@'+l).join(', '):'nenhuma');
