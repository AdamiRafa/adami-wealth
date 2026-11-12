// Ambiente simulado para capturar telas do Hub sem dados reais.
const b64=o=>Buffer.from(JSON.stringify(o)).toString('base64url');
const agora=Math.floor(Date.now()/1000);
const UID='00000000-0000-0000-0000-0000000000a1';
const TK=b64({alg:'HS256',typ:'JWT'})+'.'+b64({sub:UID,role:'authenticated',email:'ana.ribeiro@adamicaptal.com.br',exp:agora+3000,session_id:'s1',aud:'authenticated'})+'.assinatura';
const hoje=new Date().toLocaleDateString('en-CA',{timeZone:'America/Sao_Paulo'});
const PERMS=['ferramenta.crm','ferramenta.carteiras','ferramenta.planos','ferramenta.imobiliario','ferramenta.rv','ferramenta.simrv','ferramenta.diagnostico','ferramenta.boletas','ferramenta.alocacao','ferramenta.agio','ferramenta.liberdade','ferramenta.processo','ferramenta.minhacomissao'];
function dia(d){ const x=new Date(); x.setDate(x.getDate()+d); return x.toISOString().slice(0,10); }
const TAREFAS=[
 {id:'t1',titulo:'Ligar para apresentar a proposta',tipo:'ligacao',dono_id:UID,criado_por:UID,data:hoje,hora:'10:00',repeticao:'nao',dias_semana:[],concluidas:[],email_manha:true,nota:''},
 {id:'t2',titulo:'Reunião de consolidação',tipo:'reuniao',dono_id:UID,criado_por:UID,data:hoje,hora:'15:30',repeticao:'nao',dias_semana:[],concluidas:[],email_manha:true,nota:''},
 {id:'t3',titulo:'Enviar relatório do mês',tipo:'email',dono_id:UID,criado_por:UID,data:dia(1),hora:'',repeticao:'nao',dias_semana:[],concluidas:[],email_manha:true,nota:''},
 {id:'t4',titulo:'Revisar vencimentos',tipo:'tarefa',dono_id:UID,criado_por:UID,data:dia(3),hora:'09:00',repeticao:'nao',dias_semana:[],concluidas:[],email_manha:true,nota:''}];
const AVISOS=[
 {id:'a1',titulo:'Comitê de alocação na quinta, 9h',texto:'Pauta: revisão das carteiras recomendadas e ofertas do mês.',fixado:true,lido_por_mim:false,lidos:7,total:12,autor:'Bibiana',publicado_em:new Date().toISOString(),criado_em:new Date().toISOString()},
 {id:'a2',titulo:'Nova versão do Hub: app autenticador',texto:'Ligue o app em Segurança para entrar mesmo quando o e-mail atrasar.',fixado:false,lido_por_mim:true,lidos:10,total:12,autor:'Emil',publicado_em:new Date(Date.now()-86400e3).toISOString(),criado_em:new Date(Date.now()-86400e3).toISOString()}];
async function prep(ctx,extra){
  await ctx.addInitScript(([tk,h,u])=>{ try{ if(!sessionStorage.getItem('semSessao')) localStorage.setItem('aw_sessao',JSON.stringify({access_token:tk,refresh_token:'R',id:u,email:'ana.ribeiro@adamicaptal.com.br',dia:h,login_dia:h})); localStorage.setItem('aw_cor','dia'); }catch(e){} },[TK,hoje,UID]);
  await ctx.route(/supabase\.co/,async r=>{
    const u=new URL(r.request().url()); const n=u.pathname.split('/').pop();
    const j=(o,st)=>r.fulfill({status:st||200,contentType:'application/json',headers:{'access-control-allow-origin':'*','access-control-allow-headers':'*'},body:JSON.stringify(o)});
    if(r.request().method()==='OPTIONS') return r.fulfill({status:200,headers:{'access-control-allow-origin':'*','access-control-allow-headers':'*','access-control-allow-methods':'*'}});
    if(extra){ const x=await extra(u,n,r); if(x!==undefined) return j(x); }
    if(n==='estado_acesso') return j({exige:true,liberado:true});
    if(n==='minhas_permissoes') return j({perfis:['assessor'],permissoes:PERMS});
    if(n==='avisos_resumo') return j(AVISOS);
    if(n==='pode_publicar_aviso') return j(false);
    if(n==='tarefas') return j(TAREFAS);
    if(n==='perfis') return j([{user_id:UID,nome:'Ana Ribeiro',admin:false,mesa_rv:false,super:false}]);
    if(n==='leads' && u.search.includes('saldo_inicial')){
      const mes=new Date(); const ini=new Date(mes.getFullYear(),mes.getMonth(),3).toISOString(); const ant=new Date(mes.getFullYear()-1,2,1).toISOString();
      return j([
        {funil:'assessor',esteira:'base',perdido:false,ganho:false,criado_em:ant,saldo_inicial:'4.200.000',valor_potencial:null,movimentacoes:[{tipo:'aporte',valor:'250000',data:dia(-5),custodia:'onshore'}],excluido:false,responsavel_id:UID},
        {funil:'assessor',esteira:'base',perdido:false,ganho:false,criado_em:ant,saldo_inicial:'2.850.000',movimentacoes:[],excluido:false,responsavel_id:UID},
        {funil:'assessor',esteira:'base',perdido:false,ganho:false,criado_em:ant,saldo_inicial:'1.640.000',movimentacoes:[{tipo:'retirada',valor:'80000',data:dia(-2),custodia:'onshore'}],excluido:false,responsavel_id:UID},
        {funil:'assessor',esteira:'novo',perdido:false,ganho:true,ganho_em:ini,criado_em:ant,etapa_desde:ini,valor_fechado:'1.300.000',movimentacoes:[],excluido:false,responsavel_id:UID},
        {funil:'assessor',esteira:'novo',perdido:false,ganho:true,ganho_em:ini,criado_em:ant,etapa_desde:ini,valor_fechado:'650.000',movimentacoes:[],excluido:false,responsavel_id:UID}
      ]);
    }
    if(n==='totp_estado') return j({ativo:false});
    if(n==='totp_iniciar') return j({segredo:'JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP',uri:'otpauth://totp/Hub%20Adami:ana.ribeiro@adamicaptal.com.br?secret=JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP&issuer=Hub%20Adami'});
    if(n==='meus_acessos') return j([{em:new Date().toISOString(),evento:'entrou_app',navegador:'Mozilla/5.0 (Macintosh) Chrome/130',ip:'189.29.144.10'},{em:new Date(Date.now()-86400e3).toISOString(),evento:'entrou',navegador:'Mozilla/5.0 (iPhone) Safari/17',ip:'189.29.144.10'}]);
    if(u.pathname.includes('/rpc/')) return j(null);
    return j([]);
  });
}
module.exports={prep,UID,hoje,TK};
