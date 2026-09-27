import {buildFundamentalCompany} from './fundamentalResearch.js';

// A separate serving scope: Research only. This never blesses Strategy ledgers,
// substitutes model snapshots for financial statements, or changes global data.
export async function verifyReleasedResearch(asOf,build=buildFundamentalCompany) {
  const companies=[];
  for(const ticker of ['AMZN','PLTR']) {
    const value=await build(null,ticker,asOf);
    if(value.ticker!==ticker||value.asOf!==asOf||!value.quarterly?.length||!value.annual?.length||
      [...value.quarterly,...value.annual].some(row=>!row.date||row.date>asOf))
      throw Error('research_release_read_invalid');
    companies.push({ticker,quarters:value.quarterly.length,years:value.annual.length});
  }
  return {status:'ready',asOf,companies};
}
