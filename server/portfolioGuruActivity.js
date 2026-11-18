import {finite} from './investmentMath.js';
import {opportunityOwnership,opportunityBooks} from './investmentOpportunities.js';
import {DatabaseSync} from 'node:sqlite';

// Use the verified, complete common-long warehouse, not top-80 UI snapshots.
// This reads existing evidence only: no provider requests or database writes.
export function portfolioGuruBooks(source, asOf, file=process.env.STRATEGY_DATA_DB_PATH) {
  const data=opportunityBooks(source,asOf);
  data.books=data.books.map(b=>{
    const claims=new Map(b.holdings.map(h=>[h.cusip??h.id,h]));
    for(const a of b.activity)if(a.shares>0&&!claims.has(a.cusip??a.id))claims.set(a.cusip??a.id,a);
    const holdings=[...claims.values()];
    const activity=[...b.activity];
    // The compact holdings retain raw action/delta even when the activity
    // preview was truncated. Only use explicitly present deltas.
    for(const h of holdings)if(!activity.some(a=>(a.cusip??a.id)===(h.cusip??h.id))&&finite(h.changeShares))
      activity.push({...h,prevShares:h.shares-h.changeShares});
    return {...b,holdings,activity,full:b.full&&Number.isInteger(b.reportedPositionCount)&&claims.size===b.reportedPositionCount};
  });
  if(!file)return data;
  let db;
  try {
    db=new DatabaseSync(file,{readOnly:true});
    const meta=db.prepare('SELECT state FROM warehouse_meta WHERE id=1').get();
    if(meta?.state!=='complete')return data;
    const currentQuery=db.prepare('SELECT * FROM filings WHERE manager_id=? AND accession=? AND report_date=? AND public_date<=?');
    const priorQuery=db.prepare("SELECT * FROM filings WHERE manager_id=? AND report_date=? AND public_date<=? AND form='13F-HR' ORDER BY public_date DESC,accession DESC LIMIT 1");
    const holdingQuery=db.prepare(`SELECT h.*,r.ticker,r.status resolution_status FROM filing_holdings h
      LEFT JOIN holding_resolutions r ON r.filing_id=h.filing_id AND r.ordinal=h.ordinal WHERE h.filing_id=?`);
    const read=f=>{
      if(!f||f.book_scope!=='original_common_book'||f.classification_status!=='verified'||f.form!=='13F-HR'||!(f.common_value_usd>0))return null;
      const rows=holdingQuery.all(f.id);
      if(rows.length!==f.row_count||rows.length!==f.expected_position_count||rows.some(h=>h.claim_type!=='common'||h.classification_status!=='verified'||!finite(h.reported_shares)||h.reported_shares<0||!finite(h.value_usd)||h.value_usd<0))return null;
      if(Math.abs(rows.reduce((s,h)=>s+h.value_usd,0)-f.common_value_usd)>Math.max(1,f.common_value_usd*1e-8))return null;
      const claims=new Map();
      for(const h of rows) {
        const previous=claims.get(h.cusip);
        const ticker=h.resolution_status==='resolved'?h.ticker:null;
        claims.set(h.cusip,{id:h.cusip+'-COMMON',cusip:h.cusip,holdingBucket:'common_long',issuer:h.issuer,
          ticker:previous&&previous.ticker!==ticker?null:ticker,
          shares:(previous?.shares??0)+h.reported_shares,value:(previous?.value??0)+h.value_usd,
          pctCommonLong:(previous?.pctCommonLong??0)+h.value_usd/f.common_value_usd});
      }
      return claims;
    };
    data.books=data.books.map(b=>{
      const f=currentQuery.get(b.guru.id,b.filing.accessionNumber,b.filing.reportDate,asOf);
      const current=read(f);if(!current)return b;
      const q=new Date(b.filing.reportDate+'T00:00:00Z');
      const priorDate=new Date(Date.UTC(q.getUTCFullYear(),q.getUTCMonth()-2,0)).toISOString().slice(0,10);
      const priorFiling=priorQuery.get(b.guru.id,priorDate,f.public_date);
      const prior=read(priorFiling);
      const activity=[];
      if(prior)for(const cusip of new Set([...current.keys(),...prior.keys()])) {
        const now=current.get(cusip),before=prior.get(cusip);
        const shares=now?.shares??0,prevShares=before?.shares??0;
        // An explicit different ticker on the same claim is an identity
        // transition, not a comparable stock trade. Do not invent an exit.
        if(now&&before&&now.ticker!==before.ticker)continue;
        activity.push({...now??before,shares,prevShares,changeShares:shares-prevShares,
          value:now?.value??0,pctCommonLong:now?.pctCommonLong??0,
          action:!shares&&prevShares?'sold_out':shares&&!prevShares?'new':shares>prevShares?'increased':shares<prevShares?'reduced':'unchanged',
          corporateActionAdjusted:false});
      }
      return {...b,full:true,holdings:[...current.values()],activity,
        filing:{...b.filing,filingDate:f.public_date,filing:{...b.filing.filing,secUrl:f.source_url}},
        previousReportDate:priorFiling?.report_date??null};
    });
  } catch {
    // Existing account balances still render with explicitly partial evidence.
    data.warehouseStatus='unavailable';
  } finally {db?.close();}
  return data;
}

// One common disclosed quarter, one manager/claim. No issuer-level aliases:
// e.g. GOOG never inherits GOOGL holders, even when valuations share a model.
export function portfolioGuruContext(books, asOf, coverage = {}) {
  const visible=books.filter(b=>b.filing.filingDate<=asOf && b.filing.reportDate<=asOf);
  const reportDate=coverage.reportDate??visible.map(b=>b.filing.reportDate).sort().at(-1)??null;
  const selected=new Map();
  for(const b of visible.filter(b=>b.filing.reportDate===reportDate)) {
    const prior=selected.get(b.guru.id);
    if(!prior || prior.filing.filingDate<=b.filing.filingDate)selected.set(b.guru.id,b);
  }
  const current=[...selected.values()];
  return {ownership:opportunityOwnership(current),reportDate,
    reportedManagers:current.length,eligibleManagers:coverage.eligibleManagers??current.length,
    fullBooks:current.filter(b=>b.full).length,extractedBooks:current.filter(b=>!b.full).length};
}

export function portfolioGuruActivity(position, context) {
  const {ownership,...coverage}=context;
  const empty={...coverage,holders:null,adds:null,trims:null,unchanged:null,unknown:null,
    balance:'unknown',identityConflicts:0,rows:[]};
  if(position.kind!=='equity'||!(position.quantity>0))return {...empty,status:'outside_scope'};
  if(!coverage.reportedManagers)return {...empty,status:'unavailable'};
  const matches=ownership.get(position.ticker)?.managers??[];
  const rows=matches.filter(m=>!position.cusip || m.claims.every(c=>c===position.cusip)).map(m=>{
    // Missing / conflicting share-change inputs are unknown, never zero or a
    // buy/sell signal. Preserve the common source's corporate-action warning.
    const reconciled=finite(m.previousShares)&&m.previousShares>=0&&finite(m.shares)&&m.shares>=0&&
      finite(m.changeShares)&&Math.abs(m.previousShares+m.changeShares-m.shares)<Math.max(1e-6,m.shares*1e-8);
    const action=reconciled && (
      m.action==='new' && m.previousShares===0 && m.shares>0 ||
      m.action==='increased' && m.previousShares>0 && m.changeShares>0 ||
      m.action==='reduced' && m.shares>0 && m.previousShares>0 && m.changeShares<0 ||
      m.action==='sold_out' && m.shares===0 && m.previousShares>0 ||
      m.action==='unchanged' && m.shares>0 && m.changeShares===0
    )?m.action:'reported_holding';
    // Do not send monetary Guru values to the private holding's renderer.
    return {guruId:m.guruId,name:m.name,chineseName:m.chineseName??null,avatar:m.avatar,accession:m.accession,
      reportDate:m.reportDate,availableAt:m.availableAt,sourceUrl:m.sourceUrl,
      weight:m.weight,held:m.shares>0,action,
      shareChange:reconciled&&m.previousShares>0?m.changeShares/m.previousShares:null,
      comparisonStatus:m.comparisonStatus,coverage:m.coverage};
  }).sort((a,b)=>(b.weight??-1)-(a.weight??-1)||a.name.localeCompare(b.name));
  const adds=rows.filter(m=>['new','increased'].includes(m.action)).length;
  const trims=rows.filter(m=>['reduced','sold_out'].includes(m.action)).length;
  const unknown=rows.filter(m=>m.action==='reported_holding').length;
  return {...coverage,status:matches.length&&!rows.length?'identity_unresolved':rows.length?'available':'no_matches',
    identityConflicts:matches.length-rows.length,holders:rows.filter(m=>m.held).length,
    adds,trims,unchanged:rows.filter(m=>m.action==='unchanged').length,unknown,
    balance:adds>trims?'more_adds':trims>adds?'more_trims':adds?'balanced':unknown?'unknown':'no_changes',rows};
}
