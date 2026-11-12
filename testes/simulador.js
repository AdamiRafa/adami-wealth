// Supabase simulado para os testes de tela: nenhuma chamada sai para a internet e
// nenhum dado real é usado. prep(ctx) instala a sessão de teste e responde às rotas.
const b64=o=>Buffer.from(JSON.stringify(o)).toString('base64url');
const agora=Math.floor(Date.now()/1000);
const UID='00000000-0000-0000-0000-0000000000a1';
const TK=b64({alg:'HS256',typ:'JWT'})+'.'+b64({sub:UID,role:'authenticated',email:'teste@exemplo.com',exp:agora+3000,session_id:'s1',aud:'authenticated'})+'.assinatura';
const hoje=new Date().toLocaleDateString('en-CA',{timeZone:'America/Sao_Paulo'});
const PERMS=['ferramenta.crm','ferramenta.carteiras','ferramenta.planos','ferramenta.imobiliario','ferramenta.rv','ferramenta.simrv',
  'ferramenta.diagnostico','ferramenta.boletas','ferramenta.alocacao','ferramenta.agio','ferramenta.liberdade','ferramenta.processo',
  'ferramenta.minhacomissao','ferramenta.comissoes','ferramenta.fluxo','carteiras.todas'];
const CID='c0000000-0000-0000-0000-000000000001';
function mes(m,feito){
  const ativos=[
    {nome:'CDB Banco Teste',categoria:'Renda Fixa',subcategoria:'Pós-fixado',inst:'BTG Pactual',taxa:'105% CDI',vencimento:'2028-01-10',posicao:600000+m*1000,rentMes:0.9,rentAno:8,rent12m:11,rentInicio:20},
    {nome:'Fundo Teste',categoria:'Multimercado',subcategoria:'Macro',inst:'BTG Pactual',taxa:'',vencimento:'',posicao:400000,rentMes:1.1,rentAno:9,rent12m:12,rentInicio:25}];
  return {cliente_id:CID,mes:m,ano:2026,atualizado_em:'2026-11-01T12:00:00Z',feito_em:feito?'2026-11-05T12:00:00Z':null,feito_por:feito?UID:null,
    contas:[{nome:'Conta BTG',inst:'BTG Pactual',saldo:1000000+m*1000,apl:0,res:0,rendPct:0.95,rendRs:9500,moeda:'BRL'},
            {nome:'Conta Cayman',inst:'BTG Pactual Cayman',saldo:100000,apl:0,res:0,rendPct:0.4,rendRs:400,moeda:'USD'}],
    indicadores:{cdi:0.9,ipca:0.4,ibov:1.2,ptax:5.4,ativos}};
}
const LANC=[1,2,3,4,5,6,7,8,9,10].map(m=>mes(m,m<10));
async function prep(ctx){
  await ctx.addInitScript(([tk,h,u])=>{ try{ localStorage.setItem('aw_sessao',JSON.stringify({access_token:tk,refresh_token:'R',id:u,email:'teste@exemplo.com',dia:h,login_dia:h})); localStorage.setItem('aw_cor','dia'); }catch(e){} },[TK,hoje,UID]);
  // só o servidor local responde; o resto (fontes, Supabase) é simulado ou bloqueado
  await ctx.route(u=>!/^http:\/\/127\.0\.0\.1/.test(String(u)) && !/supabase\.co/.test(String(u)), r=>r.abort());
  await ctx.route(/supabase\.co/,async r=>{
    const u=new URL(r.request().url()); const n=u.pathname.split('/').pop(); const m=r.request().method();
    const cab={'access-control-allow-origin':'*','access-control-allow-headers':'*','access-control-allow-methods':'*'};
    const j=(o,st)=>r.fulfill({status:st||200,contentType:'application/json',headers:cab,body:JSON.stringify(o)});
    if(m==='OPTIONS') return r.fulfill({status:200,headers:cab});
    if(n==='estado_acesso') return j({exige:true,liberado:true});
    if(n==='minhas_permissoes') return j({perfis:['master'],permissoes:PERMS});
    if(n==='perfis') return j([{user_id:UID,nome:'Pessoa Teste',admin:true,mesa_rv:true,super:true}]);
    if(n==='clientes'&&m==='GET') return j([{id:CID,nome:'Cliente Teste',assessor_id:UID,contas_btg:['1234567'],lead_id:null,emails_relatorio:['cliente@exemplo.com']}]);
    if(n==='lancamentos'&&m==='GET') return j(LANC);
    if(n==='totp_estado') return j({ativo:false});
    if(u.pathname.includes('/rpc/')) return j(null);
    if(m!=='GET') return j([]);
    return j([]);
  });
}
module.exports={prep,CID};
