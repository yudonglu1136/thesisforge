import {HedgeSource,BundledHedgeSource} from './hedgeLab.js';
export function registerHedgeRoutes(app,service,{file=()=>process.env.HEDGE_DB_PATH,source=null}={}){
 const withSource=fn=>{
  const resolved=file();
  const s=source??(resolved?new HedgeSource(resolved):new BundledHedgeSource());
  try{return fn(s);}finally{if(!source)s.close();}
 };
 const route=(method,url,fn)=>app[method]('/api/investment/hedge'+url,(req,res)=>{
  res.setHeader('Cache-Control','private, no-store');
  if(!req.user?.id)return res.status(401).json({error:'unauthorized'});
  try{res.json(fn(req));}catch(e){res.status(e.status??500).json({error:e.status?e.message:'hedge_request_failed'});}
 });
 route('get','',r=>({...withSource(s=>s.catalog(r.query.date??null)),saved:service.store.list(r.user.id,'hedge_experiment')}));
 route('post','/calculate',r=>withSource(s=>s.calculate(r.body)));
 route('post','/save',r=>{
  const result=withSource(s=>s.calculate(r.body));
  const name=String(r.body.name??'QQQ hedge').trim().slice(0,80);
  return service.store.write(r.user.id,'hedge_experiment','QQQ',r.body.operationId,{name,rules:result.rules},()=>({name,asOf:result.rules.date,...result}));
 });
}
