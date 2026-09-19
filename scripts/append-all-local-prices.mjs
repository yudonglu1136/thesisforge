// Promote verified extensions into a NEW local generation. Never rewrite old prices,
// financials, Guru filings, saved assumptions, users, or portfolios.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {DatabaseSync, backup} from 'node:sqlite';
import {fileURLToPath} from 'node:url';
import {signature} from '../server/investmentMath.js';
import {openStrategyDatabase} from '../server/strategyDatabase.js';
import {comparisonPricesEqual} from '../server/valuationComparisonPrice.js';
import {valuationMarketPriceSymbol} from '../server/tickerAliases.js';

const good = x => Number.isFinite(x) && x > 0;
export function validateMarketCutoff(previous, cutoff, sessions, now = new Date()) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(cutoff ?? '') ||
      !Number.isFinite(Date.parse(cutoff)) || new Date(cutoff).toISOString().slice(0,10) !== cutoff ||
      cutoff < previous || cutoff >= now.toISOString().slice(0,10)) throw Error('invalid_completed_market_cutoff');
  if (!sessions.length || sessions.at(-1) !== cutoff || new Set(sessions).size !== sessions.length ||
      sessions.some((d,i) => d > cutoff || (i > 0 && d <= sessions[i-1]))) throw Error('benchmark_target_session_unavailable');
}

export function reconcileCtaExtension(existing, fresh, metadata, symbol, cutoff) {
  if (metadata.symbol !== symbol || metadata.currency !== 'USD' || metadata.instrumentType !== 'ETF')
    throw Error('cta_identity_or_currency_mismatch');
  if (!existing.length || fresh.at(-1)?.date !== cutoff) throw Error('cta_target_session_unavailable');
  const verified = reconcileAppend(existing, fresh);
  // A new catalog version must preserve the complete old history, including its
  // original adjustment basis. No calendar padding or synthetic inception rows.
  return {...verified, rows: verified.rows.filter(p => p.date > existing.at(-1).date)};
}
export function confirmPriceSeries(fresh, confirmed) {
  // Existing repository contracts: quoted closes use comparisonPricesEqual;
  // adjusted series use the same 1e-5 all-overlap basis check as price-gap repair.
  const ratios=[];
  for(const p of fresh) {
    const n=confirmed.get(p.date);
    if(!n || !comparisonPricesEqual(n.close,p.close) || !good(n.adj))throw Error('confirmation_close_disagrees');
    ratios.push(p.adjusted_close/n.adj);
  }
  ratios.sort((a,b)=>a-b);const scale=ratios[Math.floor(ratios.length/2)];
  const deviation=Math.max(...ratios.map(r=>Math.abs(r/scale-1)));
  if(Math.abs(scale-1)>1e-5 || deviation>1e-5)throw Error('confirmation_adjustment_disagrees');
  return {scale,maxScaleDeviation:deviation,overlap:ratios.length};
}
export function reconcileConfirmedHistory(existing, fresh) {
  // A complete new vendor history, not a waiver of execution coverage. All
  // existing values must agree; absent adjusted fields remain distinct from zero.
  const mapped = new Map(fresh.map(p=>[p.date,p]));
  const ratios = [];
  for(const p of existing) {
    const n=mapped.get(p.date);
    if(!n || !good(p.close) || Math.abs(p.close/n.close-1)>1e-5)throw Error('confirmed_history_close_conflict');
    if(good(p.adjusted_close))ratios.push(p.adjusted_close/n.adjusted_close);
  }
  ratios.sort((a,b)=>a-b);
  const scale=ratios.length?ratios[Math.floor(ratios.length/2)]:1;
  if(ratios.some(r=>Math.abs(r/scale-1)>1e-5))throw Error('confirmed_history_adjustment_conflict');
  const old=new Map(existing.map(p=>[p.date,p]));
  return {scale,overlap:existing.length,maxScaleDeviation:0,
    rows:fresh.filter(p=>!good(old.get(p.date)?.adjusted_close)).map(p=>({...p,adjusted_close:p.adjusted_close*scale})),
    assurance:'complete_vendor_history_confirmed_twice; every existing close reconciled; no synthetic session'};
}
export function reconcileAppend(existing, fresh, minimumOverlap = 60) {
  const byDate = new Map(fresh.map(p => [p.date, p])), old = new Map(), ratios = [];
  for (const p of existing) {
    const duplicate = old.get(p.date);
    if (duplicate && (duplicate.close !== p.close || duplicate.adjusted_close !== p.adjusted_close))
      throw Error('conflicting_existing_series');
    old.set(p.date, p);
    const n = byDate.get(p.date);
    if (!n) continue;
    if (!good(p.close) || Math.abs(p.close / n.close - 1) > 1e-5) throw Error('historical_close_basis_conflict');
    if (good(p.adjusted_close)) ratios.push(p.adjusted_close / n.adjusted_close);
  }
  if (ratios.length < minimumOverlap) throw Error('insufficient_return_basis_overlap');
  ratios.sort((a, b) => a - b);
  const scale = ratios[Math.floor(ratios.length / 2)];
  const deviation = Math.max(...ratios.map(r => Math.abs(r / scale - 1)));
  if (deviation > 1e-5) throw Error('historical_adjusted_return_basis_conflict');
  return {scale, overlap: ratios.length, maxScaleDeviation: deviation,
    rows: fresh.filter(p => !old.has(p.date)).map(p => ({...p, adjusted_close: p.adjusted_close * scale}))};
}

export function comparisonExtension(snapshot, fresh, events, providerCurrency, cutoff) {
  const history = snapshot.priceHistory ?? [], last = history.at(-1)?.date;
  if (!last) throw Error('missing_comparison_anchor');
  const factor = snapshot.currency === providerCurrency ? 1 : snapshot.currency === 'GBP' && providerCurrency === 'GBp' ? .01 : null;
  if (factor == null) throw Error('comparison_currency_unverified');
  if (Object.values(events.splits ?? {}).some(s => new Date(s.date * 1000).toISOString().slice(0, 10) > last))
    throw Error('intervening_split_requires_model_share_basis_review');
  if (factor !== 1) {
    const old = new Map(history.map(p => [p.date, p.close]));
    const overlap = fresh.filter(p => old.has(p.date));
    if (overlap.length < 20 || overlap.some(p => Math.abs(old.get(p.date) / (p.close * factor) - 1) > 1e-5))
      throw Error('pence_to_pounds_anchor_not_confirmed');
  }
  return {factor, rows: fresh.filter(p => p.date > last && p.date <= cutoff).map(p => ({...p,
    open: p.open == null ? null : p.open * factor, high: p.high * factor,
    low: p.low * factor, close: p.close * factor, adjusted_close: null}))};
}

async function main() {
  const args = process.argv.slice(2,5);
  if (args.length !== 3 || args.some(p => p.startsWith('--'))) throw Error('Usage: ORIGINAL_GENERATION HARVEST_DIRECTORY NEW_PRIVATE_GENERATION');
  const [input, harvestDir, out] = args.map(p => path.resolve(p));
  const confirmShort = process.argv.includes('--confirm-short');
  if (!input || !harvestDir || !out || fs.existsSync(out) || out === input)
    throw Error('Usage: ORIGINAL_GENERATION HARVEST_DIRECTORY NEW_PRIVATE_GENERATION');
  process.umask(0o077); fs.mkdirSync(out, {mode: 0o700});
  const source = openStrategyDatabase(path.join(input, 'strategy.sqlite'));
  const origin = new DatabaseSync(path.join(input, 'runtime.sqlite'), {readOnly: true});
  const staged = new DatabaseSync(path.join(harvestDir, 'prices.sqlite'), {readOnly: true});
  const plan = JSON.parse(fs.readFileSync(path.join(harvestDir, 'plan.json'))), cutoff = plan.cutoff;
  if (staged.prepare('SELECT COUNT(*) n FROM audit').get().n !== plan.symbols.length) throw Error('Harvest population incomplete');
  const now = new Date().toISOString(), sha = s => crypto.createHash('sha256').update(s).digest('hex');
  const audits = [], repairs = [], comparisons = [], ctaRepairs = [];
  const select = source.db.prepare(`SELECT p.* FROM price_series s JOIN price_observations p ON s.id=p.series_id
    WHERE s.symbol=? AND s.storage_kind='raw_price_points' ORDER BY p.date`);
  const sessions = staged.prepare("SELECT date FROM prices WHERE symbol='SPY' AND date<=? ORDER BY date").all(cutoff).map(r => r.date);
  validateMarketCutoff(source.meta.cutoff, cutoff, sessions);
  for (const catalog of source.db.prepare('SELECT * FROM etf_catalog ORDER BY symbol').all()) {
    const series = staged.prepare('SELECT * FROM series WHERE symbol=?').get(catalog.symbol);
    if (!series) throw Error('mandatory_cta_series_unavailable_' + catalog.symbol);
    const existing = source.db.prepare('SELECT * FROM price_observations WHERE series_id=? ORDER BY date').all(catalog.series_id);
    const fresh = staged.prepare('SELECT * FROM prices WHERE symbol=? ORDER BY date').all(catalog.symbol);
    const verified = reconcileCtaExtension(existing, fresh, JSON.parse(series.metadata_json), catalog.symbol, cutoff);
    const dates = new Set([...existing.map(p=>p.date), ...verified.rows.map(p=>p.date)]);
    if (sessions.some(d=>d >= catalog.first_date && !dates.has(d))) throw Error('cta_session_gap_' + catalog.symbol);
    if (verified.rows.length) ctaRepairs.push({symbol:catalog.symbol,catalog,series,...verified});
  }
  for (const symbol of plan.symbols) {
    const harvest = JSON.parse(staged.prepare('SELECT payload_json FROM audit WHERE symbol=?').get(symbol).payload_json);
    const s = staged.prepare('SELECT * FROM series WHERE symbol=?').get(symbol);
    const audit = {symbol, providerStatus: harvest.status, last: s?.last_date ?? null,
      rejectedObservations: harvest.rejected?.length ?? 0, returnExtension: 'unavailable', comparisonExtension: 'not_a_research_security'};
    if (!s) {audit.reason = harvest.error; audits.push(audit); continue;}
    const fresh = staged.prepare('SELECT * FROM prices WHERE symbol=? ORDER BY date').all(symbol);
    const existing = select.all(symbol);
    try {
      if (s.currency !== 'USD') throw Error('return_currency_requires_separate_audit');
      if (harvest.catalogDelisted && existing.some(p => p.date > s.last_date)) throw Error('delisting_identity_conflict');
      // Invariant: every old observation is reconciled, not only the final close.
      let verified;
      try {verified = reconcileAppend(existing, fresh);}
      catch(e) {
        if(!confirmShort || e.message!=='insufficient_return_basis_overlap')throw e;
        if(harvest.catalogDelisted || harvest.status!=='current')throw Error('short_history_not_current');
        // Never resolve a recycled or renamed ticker from a loose name match.
        if(!origin.prepare('SELECT 1 FROM valuation_ticker_snapshots WHERE ticker=?').get(symbol) && !existing.length)
          throw Error('new_series_identity_anchor_missing');
        const file=path.join(harvestDir,'confirmed-'+encodeURIComponent(symbol)+'.json');
        let text;
        if(fs.existsSync(file))text=fs.readFileSync(file,'utf8');
        else {
          const url=`https://query2.finance.yahoo.com/v8/finance/chart/${encodeURIComponent(s.provider_symbol)}?period1=${Date.parse(harvest.requestedStart)/1000}&period2=${Date.parse(cutoff)/1000+86400}&interval=1d&events=div%2Csplits&includeAdjustedClose=true`;
          const response=await fetch(url,{headers:{'User-Agent':'Mozilla/5.0'},signal:AbortSignal.timeout(30000)});
          if(!response.ok)throw Error('confirmation_http_'+response.status);
          text=await response.text();fs.writeFileSync(file,text,{flag:'wx',mode:0o600});
        }
        const c=JSON.parse(text).chart?.result?.[0];
        if(c?.meta?.symbol!==s.provider_symbol || c.meta.currency!==s.currency || c.meta.instrumentType!==JSON.parse(s.metadata_json).instrumentType)
          throw Error('confirmation_identity_mismatch');
        const q=c.indicators.quote[0],adj=c.indicators.adjclose[0].adjclose;
        const confirmed=new Map(c.timestamp.map((t,i)=>[new Date(t*1000).toISOString().slice(0,10),{close:q.close[i],adj:adj[i]}]));
        const confirmation=confirmPriceSeries(fresh,confirmed);
        verified=reconcileConfirmedHistory(existing,fresh);
        verified.confirmation=confirmation;
        verified.confirmationHash=sha(text);
      }
      const dates = new Set([...existing.map(p => p.date), ...verified.rows.map(p => p.date)]);
      const first = existing[0]?.date ?? s.first_date, end = harvest.catalogDelisted ? s.last_date : cutoff;
      audit.remainingSessions = sessions.filter(d => d >= first && d <= end && !dates.has(d));
      audit.returnExtension = verified.rows.length ? 'verified_append' : 'already_present';
      audit.addedReturnRows = verified.rows.length;
      if (verified.rows.length) repairs.push({symbol, series: s, ...verified});
    } catch (e) {audit.returnExtension = 'blocked'; audit.returnReason = e.message;}
    audits.push(audit);
  }
  // Research identity is not necessarily the US return-price ticker (e.g.
  // AZN's GBP model uses AZN.L, not its USD ADR). Reuse the app's exact aliases;
  // do not infer an exchange or silently convert a currency.
  for (const snapshot of origin.prepare('SELECT ticker,payload_json FROM valuation_ticker_snapshots ORDER BY ticker').all()) {
    const symbol = snapshot.ticker, marketSymbol = valuationMarketPriceSymbol(symbol);
    const audit = audits.find(a => a.symbol === symbol) ?? {symbol, returnExtension:'not_in_harvest'};
    if (!audits.includes(audit)) audits.push(audit);
    audit.comparisonSymbol = marketSymbol;
    try {
      const s = staged.prepare('SELECT * FROM series WHERE symbol=?').get(marketSymbol);
      if (!s) throw Error('comparison_market_series_unavailable');
      const fresh = staged.prepare('SELECT * FROM prices WHERE symbol=? ORDER BY date').all(marketSymbol);
      const snap = JSON.parse(snapshot.payload_json);
      const extension = comparisonExtension(snap, fresh, JSON.parse(s.events_json), s.currency, cutoff);
      audit.comparisonExtension = extension.rows.length ? 'verified_append' : 'already_present';
      audit.addedComparisonRows = extension.rows.length;
      if (extension.rows.length) comparisons.push({symbol, series: s, snapshot: snap, ...extension});
    } catch (e) {audit.comparisonExtension = 'blocked'; audit.comparisonReason = e.message;}
  }
  fs.writeFileSync(path.join(out, 'population-audit.json'), JSON.stringify({cutoff, audits}, null, 2));
  console.log(JSON.stringify({phase: 'validated', scope: audits.length, returnRepairs: repairs.length, comparisons: comparisons.length}));
  await backup(source.db, path.join(out, 'strategy.sqlite')); await backup(origin, path.join(out, 'runtime.sqlite'));
  const db = new DatabaseSync(path.join(out, 'strategy.sqlite')), runtime = new DatabaseSync(path.join(out, 'runtime.sqlite'));
  try {
    db.exec('PRAGMA foreign_keys=ON; BEGIN IMMEDIATE'); runtime.exec('BEGIN IMMEDIATE');
    const documentIds = new Map();
    const document = s => {
      if (documentIds.has(s.symbol)) return documentIds.get(s.symbol);
      const content = fs.readFileSync(path.join(harvestDir, 'responses', encodeURIComponent(s.symbol) + '.json'), 'utf8');
      if (sha(content) !== s.source_sha256) throw Error('Source response hash mismatch');
      const id = signature(['full_population_price_refresh', s.symbol, s.source_sha256]);
      db.prepare('INSERT INTO source_documents VALUES (?,?,?,?,?,?)').run(id, 'full_population_price_refresh',
        'yahoo:chart/' + s.provider_symbol, s.source_sha256, content, now);
      documentIds.set(s.symbol, id); return id;
    };
    const put = db.prepare('INSERT INTO price_observations VALUES (?,?,?,?,?,?,?,?,?,?)');
    const rawPut = runtime.prepare(`INSERT INTO price_points(symbol,date,open,high,low,close,adjusted_close,volume,source,updated_at)
      VALUES (?,?,?,?,?,?,?,?,?,?) ON CONFLICT(symbol,date) DO NOTHING`);
    let runtimeAdded = 0;
    for (const r of repairs) {
      const sid = document(r.series), id = signature([sid, 'raw_price_points', r.scale]);
      if(r.confirmationHash) {
        const content=fs.readFileSync(path.join(harvestDir,'confirmed-'+encodeURIComponent(r.symbol)+'.json'),'utf8');
        if(sha(content)!==r.confirmationHash)throw Error('Confirmation hash mismatch');
        db.prepare('INSERT INTO source_documents VALUES (?,?,?,?,?,?)').run(signature(['all_price_confirmation',r.symbol,r.confirmationHash]),
          'all_price_confirmation','yahoo:query2/'+r.series.provider_symbol,r.confirmationHash,content,now);
      }
      db.prepare('INSERT INTO price_series VALUES (?,?,?,?,?,?,?,?,?,?)').run(id, r.symbol, 'yahoo',
        'audited-series:yahoo_query1_chart', 'raw_price_points', 'yahoo_provider_historical_close',
        'total_return_adjusted_close', 'USD', 'overlap_verified', sid);
      for (const p of r.rows) {
        put.run(id,p.date,p.open,p.high,p.low,p.close,p.adjusted_close,p.volume,now,p.quality_status);
        runtimeAdded += Number(rawPut.run(r.symbol,p.date,p.open,p.high,p.low,p.close,p.adjusted_close,p.volume,
          'audited-series:yahoo_query1_chart',now).changes);
      }
    }
    for (const r of comparisons) {
      const sid = document(r.series), id = signature([sid, 'valuation_snapshot', r.factor]);
      const label = r.factor === 1 ? 'audited-series:yahoo_query1_chart' : 'audited-series:yahoo_chart_gbp_from_gbpence';
      db.prepare('INSERT INTO price_series VALUES (?,?,?,?,?,?,?,?,?,?)').run(id, r.symbol,'yahoo',label,
        'valuation_snapshot','provider_quote_in_snapshot_currency',null,r.snapshot.currency,'current_quote_identity_verified',sid);
      for (const p of r.rows) put.run(id,p.date,p.open,p.high,p.low,p.close,null,p.volume,now,p.quality_status);
      r.snapshot.priceHistory.push(...r.rows.map(({date,open,high,low,close,volume}) => ({date,open,high,low,close,volume,source:label})));
      r.snapshot.marketDataRefresh = {cutoff,priceDate:r.snapshot.priceHistory.at(-1).date,refreshedAt:now,
        provider:'yahoo',priceSymbol:r.series.provider_symbol,sourceHash:r.series.source_sha256,modelInputsChanged:false};
      runtime.prepare('UPDATE valuation_ticker_snapshots SET generated_at=?,payload_json=? WHERE ticker=?')
        .run(now,JSON.stringify(r.snapshot),r.symbol);
    }
    for (const r of ctaRepairs) {
      const sid=document(r.series), id=signature([sid,'cta_etf',r.scale]);
      const prior=source.db.prepare('SELECT * FROM price_series WHERE id=?').get(r.catalog.series_id);
      db.prepare('INSERT INTO price_series VALUES (?,?,?,?,?,?,?,?,?,?)').run(id,r.symbol,'yahoo',
        'audited-series:yahoo_query1_chart','cta_etf',prior.close_basis,prior.return_basis,
        'USD','overlap_verified',sid);
      db.prepare('INSERT INTO price_observations SELECT ?,date,open,high,low,close,adjusted_close,volume,observed_at,quality_status FROM price_observations WHERE series_id=?')
        .run(id,r.catalog.series_id);
      for(const p of r.rows) put.run(id,p.date,p.open,p.high,p.low,p.close,p.adjusted_close,p.volume,now,p.quality_status);
      const points=db.prepare('SELECT date,close,adjusted_close adjustedClose FROM price_observations WHERE series_id=? ORDER BY date').all(id);
      db.prepare('UPDATE etf_catalog SET last_date=?,series_id=?,source_url=?,points_hash=?,downloaded_at=? WHERE symbol=?')
        .run(cutoff,id,'yahoo:chart/'+r.series.provider_symbol,sha(JSON.stringify(points)),now,r.symbol);
    }
    const summary = {cutoff,scope:audits.length,rawSecuritiesCurrent:db.prepare(`SELECT COUNT(DISTINCT s.symbol) n
      FROM price_series s JOIN price_observations p ON p.series_id=s.id WHERE s.storage_kind='raw_price_points' AND p.date=?`).get(cutoff).n,
      comparisonSecuritiesCurrent:db.prepare(`SELECT COUNT(DISTINCT s.symbol) n FROM price_series s JOIN price_observations p
      ON p.series_id=s.id WHERE s.storage_kind='valuation_snapshot' AND p.date=?`).get(cutoff).n,
      rawRowsAdded:repairs.reduce((n,r)=>n+r.rows.length,0),runtimeRowsAdded:runtimeAdded,
      comparisonRowsAdded:comparisons.reduce((n,r)=>n+r.rows.length,0),
      ctaRowsAdded:ctaRepairs.reduce((n,r)=>n+r.rows.length,0),
      ctaUpdated:ctaRepairs.map(r=>r.symbol),previousCutoff:source.meta.cutoff,
      financialApiStatus:'deferred_by_user',financialsAndFilingsRefreshed:false,
      vendorCurrent:audits.filter(r=>r.providerStatus==='current').length,
      allSecuritiesReady:false,policy:'Append verified observations; rejected series retained with explicit audit. No financial or model refresh.'};
    const content = JSON.stringify(summary);
    db.prepare('INSERT INTO source_documents VALUES (?,?,?,?,?,?)').run(signature(['market_refresh_summary',content]),
      'market_refresh_summary','local:all-security-price-refresh',sha(content),content,now);
    const counts = {}, tableHashes = {};
    for (const {name:table} of db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name!='warehouse_meta' ORDER BY name").all()) {
      counts[table]=db.prepare(`SELECT COUNT(*) n FROM ${table}`).get().n;
      const columns=db.prepare(`PRAGMA table_info(${table})`).all(),fields=columns.map(c=>c.name).filter(c=>table!=='source_documents'||!['content','stored_at'].includes(c));
      const order=columns.filter(c=>c.pk).sort((a,b)=>a.pk-b.pk).map(c=>c.name),hash=crypto.createHash('sha256');
      for(const row of db.prepare(`SELECT ${fields.join(',')} FROM ${table} ORDER BY ${order.join(',')}`).iterate()) hash.update(JSON.stringify(row)+'\n');
      tableHashes[table]=hash.digest('hex');
    }
    const previous=JSON.parse(fs.readFileSync(path.join(input,'strategy.sqlite.import.json')));
    const changedTables=Object.keys(tableHashes).filter(t=>tableHashes[t]!==previous.tableHashes[t]);
    if(changedTables.some(t=>!['source_documents','price_series','price_observations','etf_catalog'].includes(t)))throw Error('Protected strategy table changed');
    const sourceCounts=JSON.parse(source.meta.source_counts_json),manifestHash=signature({cutoff,counts,sourceCounts,tableHashes,security:source.meta.security_version,actions:source.meta.action_version});
    db.prepare('UPDATE warehouse_meta SET cutoff=?,generated_at=?,manifest_hash=? WHERE id=1').run(cutoff,now,manifestHash);
    if(db.prepare('PRAGMA foreign_key_check').all().length)throw Error('Foreign key violation');
    db.exec('COMMIT'); runtime.exec('COMMIT');
    for(const d of [db,runtime])if(d.prepare('PRAGMA integrity_check').get().integrity_check!=='ok')throw Error('Integrity failure');
    // Attach original snapshots read-only and prove all original daily observations survived.
    runtime.prepare('ATTACH DATABASE ? AS original').run(path.join(input,'runtime.sqlite'));
    const oldPriceChanges=runtime.prepare('SELECT COUNT(*) n FROM (SELECT * FROM original.price_points EXCEPT SELECT * FROM main.price_points)').get().n;
    if(oldPriceChanges)throw Error('Existing runtime prices changed');
    const cacheChanges=runtime.prepare(`SELECT m.scope,m.revision-o.revision delta FROM main.cache_revisions m
      JOIN original.cache_revisions o ON o.scope=m.scope WHERE m.revision<>o.revision`).all();
    if(cacheChanges.some(r=>r.scope!=='valuation_ticker_snapshots'||r.delta!==comparisons.length))
      throw Error('Unexpected cache revision change');
    const protectedTables=runtime.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name NOT IN ('price_points','valuation_ticker_snapshots','cache_revisions')").all();
    for(const {name:t} of protectedTables) {
      const changed=runtime.prepare(`SELECT COUNT(*) n FROM (SELECT * FROM main.${t} EXCEPT SELECT * FROM original.${t})`).get().n;
      const removed=runtime.prepare(`SELECT COUNT(*) n FROM (SELECT * FROM original.${t} EXCEPT SELECT * FROM main.${t})`).get().n;
      if(changed||removed)throw Error('Protected runtime table changed: '+t);
    }
    const report={schemaVersion:1,cutoff,counts,sourceCounts,tableHashes,manifestHash,sourceGeneration:source.meta.manifest_hash,
      changedTables,summary,oldPriceChanges,cacheChanges,protectedRuntimeTables:protectedTables.length,sourceWrites:0,integrity:'ok',foreignKeys:0};
    for(const file of ['strategy.sqlite.import.json','verification.json'])fs.writeFileSync(path.join(out,file),JSON.stringify(report,null,2));
    console.log(JSON.stringify({phase:'complete',...summary,generation:manifestHash,integrity:'ok'}));
  } finally {db.close();runtime.close();source.close();origin.close();staged.close();}
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) await main();
