// Explicit local data preparation; never imported by the server request path.
import fs from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
const end = process.argv[2], output = process.argv[3];
if (!/^\d{4}-\d{2}-\d{2}$/.test(end ?? '') || !output) throw new Error('Usage: node scripts/build-strategy-etf-inputs.mjs YYYY-MM-DD private-output.json');
const sha = v => crypto.createHash('sha256').update(v).digest('hex');
const series = {};
for (const [symbol, inception] of [['KMLM', '2020-12-01'], ['DBMF', '2019-05-07']]) {
  const url = `https://query1.finance.yahoo.com/v8/finance/chart/${symbol}?period1=${Date.parse(inception)/1000}&period2=${Date.parse(end)/1000+86400}&interval=1d&events=div%7Csplits&includeAdjustedClose=true`;
  const response = await fetch(url, {headers:{'User-Agent':'ThesisForge local research'},signal:AbortSignal.timeout(30000)});
  if (!response.ok) throw new Error(`${symbol}: HTTP ${response.status}`);
  const raw = await response.text(), result = JSON.parse(raw).chart?.result?.[0];
  if (result?.meta?.symbol !== symbol || result.meta.currency !== 'USD' || !result.indicators?.adjclose?.[0]) throw new Error(`${symbol}: invalid source identity or basis`);
  const rows = result.timestamp.map((t,i) => ({date:new Date(t*1000).toISOString().slice(0,10),close:result.indicators.quote[0].close[i],adjustedClose:result.indicators.adjclose[0].adjclose[i]}));
  const dates = new Set();
  for (const r of rows) {
    if(r.date < inception || r.date > end || dates.has(r.date) || !Number.isFinite(r.close) || r.close<=0 || !Number.isFinite(r.adjustedClose) || r.adjustedClose<=0) throw new Error(`${symbol}: invalid or duplicate observation ${r.date}`);
    dates.add(r.date);
  }
  if(rows.length<20)throw new Error(`${symbol}: insufficient observations`);
  series[symbol] = {symbol,currency:'USD',inception,source:'Yahoo Finance chart API',url,downloadedAt:new Date().toISOString(),rawSha256:sha(raw),pointsSha256:sha(JSON.stringify(rows)),returnBasis:'total_return_adjusted_close',first:rows[0].date,last:rows.at(-1).date,points:rows};
}
const artifact = {version:'strategy-etfs-v1',asOf:end,series};
await fs.mkdir(path.dirname(output),{recursive:true,mode:0o700});
// Do not overwrite a prior frozen artifact accidentally.
await fs.writeFile(output, JSON.stringify(artifact), {flag:'wx',mode:0o600});
console.log(JSON.stringify({output,asOf:end,series:Object.fromEntries(Object.entries(series).map(([s,v])=>[s,{first:v.first,last:v.last,points:v.points.length,hash:v.pointsSha256}]))},null,2));
