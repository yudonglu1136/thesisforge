// Explicit offline preparation from the local Sharadar Fact OS. No provider
// network request, interpolation, or cross-provider splice is permitted.
import fs from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
import {PRICE_TYPES,queryFactsBatch} from '../server/factRepository.js';

const end=process.argv[2],output=process.argv[3];
if(!/^\d{4}-\d{2}-\d{2}$/.test(end??'')||!output)throw new Error('Usage: node scripts/build-strategy-etf-inputs.mjs YYYY-MM-DD private-output.json');
const sha=value=>crypto.createHash('sha256').update(value).digest('hex');
const specs=[['KMLM','2020-12-01'],['DBMF','2019-05-07']];
const requests=specs.flatMap(([symbol,inception])=>[
  {method:'get_price_history',args:[symbol,inception,end,PRICE_TYPES.RAW_CLOSE],kwargs:{dataset:'funds'}},
  {method:'get_price_history',args:[symbol,inception,end,PRICE_TYPES.TOTAL_RETURN_ADJUSTED_CLOSE],kwargs:{dataset:'funds'}}
]);
const responses=await queryFactsBatch(requests);
const series={};
for(let index=0;index<specs.length;index++){
  const [symbol,inception]=specs[index],raw=responses[index*2],adjusted=responses[index*2+1];
  if(!raw?.ok||!adjusted?.ok)throw new Error(`${symbol}: Sharadar Fact OS unavailable`);
  const adjustedByDate=new Map(adjusted.result.map(row=>[row.date,row.value]));
  const points=raw.result.map(row=>({date:row.date,close:row.value,adjustedClose:adjustedByDate.get(row.date)}));
  const dates=new Set();
  for(const row of points){
    if(row.date<inception||row.date>end||dates.has(row.date)||!Number.isFinite(row.close)||row.close<=0||!Number.isFinite(row.adjustedClose)||row.adjustedClose<=0)
      throw new Error(`${symbol}: invalid, missing, or duplicate Sharadar observation ${row.date}`);
    dates.add(row.date);
  }
  if(points.length<20||points.length!==adjusted.result.length)throw new Error(`${symbol}: incomplete aligned Sharadar observations`);
  const provenance=raw.result.at(-1)?.provenance??{};
  series[symbol]={symbol,currency:'USD',inception,source:'Sharadar Local Fact OS',sourceLabel:'sharadar_fact_os_sfp',
    url:`local-fact-os://funds/${symbol}`,
    dataset:'SFP',catalogGeneration:provenance.catalog_generation??null,downloadedAt:new Date().toISOString(),
    rawSha256:sha(JSON.stringify({raw:raw.result,adjusted:adjusted.result})),pointsSha256:sha(JSON.stringify(points)),
    returnBasis:'total_return_adjusted_close',first:points[0].date,last:points.at(-1).date,points};
}
const artifact={version:'strategy-etfs-v1',asOf:end,series};
await fs.mkdir(path.dirname(output),{recursive:true,mode:0o700});
await fs.writeFile(output,JSON.stringify(artifact),{flag:'wx',mode:0o600});
console.log(JSON.stringify({output,asOf:end,provider:'Sharadar Local Fact OS',series:Object.fromEntries(Object.entries(series).map(([symbol,value])=>[symbol,{first:value.first,last:value.last,points:value.points.length,hash:value.pointsSha256}]))},null,2));
