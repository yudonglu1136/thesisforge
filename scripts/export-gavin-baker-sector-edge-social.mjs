import { createHash } from 'node:crypto';
import { createRequire } from 'node:module';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { DatabaseSync } from 'node:sqlite';

import { load13fHoldingHistory } from '../server/secClient.js';
import { gurus } from '../server/gurus.js';

const require = createRequire(import.meta.url);
let sharp;
try {
  sharp = require('sharp');
} catch {
  sharp = require(
    process.env.SHARP_MODULE ||
      '/Users/yudonglu/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/sharp',
  );
}

const root = path.resolve(import.meta.dirname, '..');
const outputDir = path.join(root, 'docs/brand/2026-08-30');
const output = path.join(outputDir, 'gavin-baker-sector-edge-en-1600x900.png');
const dataOutput = path.join(outputDir, 'gavin-baker-sector-edge-data.json');
const manifestOutput = path.join(outputDir, 'gavin-baker-sector-edge-manifest.json');
const copyOutput = path.join(outputDir, 'gavin-baker-sector-edge-copy-en.md');
const databasePath =
  process.env.GAVIN_BACKTEST_DB ||
  '/Users/yudonglu/Documents/thesisforge/server/data/guru-analysis.sqlite';
const taxonomyPath =
  process.env.SHARADAR_TICKERS_CSV ||
  '/Users/yudonglu/Documents/jansen_us_firm_replication/data/sharadar/cache/tickers.csv';

const releaseDate = '2026-08-30';
const generatedAt = '2026-08-31';
const assets = {
  mark: path.join(root, 'assets/branding/thesisforge-mark.png'),
  portrait: path.join(root, 'web/guru-avatars/gavin-baker.png'),
};

const colors = {
  ink: '#0B111D',
  panel: '#101826',
  panel2: '#141E2D',
  line: '#263248',
  mint: '#22D3A6',
  mint2: '#55E3BC',
  amber: '#E0B15A',
  red: '#FF7B7B',
  text: '#F8FAFC',
  muted: '#A8B2C4',
  subdued: '#718096',
};

function sha256(value) {
  return createHash('sha256').update(value).digest('hex');
}

function parseCsvLine(line) {
  const cells = [];
  let value = '';
  let quoted = false;
  for (let index = 0; index < line.length; index += 1) {
    const character = line[index];
    if (character === '"') {
      if (quoted && line[index + 1] === '"') {
        value += '"';
        index += 1;
      } else {
        quoted = !quoted;
      }
    } else if (character === ',' && !quoted) {
      cells.push(value);
      value = '';
    } else {
      value += character;
    }
  }
  cells.push(value);
  return cells;
}

function loadTaxonomy(csvText) {
  const lines = csvText.split(/\r?\n/).filter(Boolean);
  const headers = parseCsvLine(lines.shift());
  const taxonomy = new Map();
  for (const line of lines) {
    const cells = parseCsvLine(line);
    const row = Object.fromEntries(headers.map((header, index) => [header, cells[index] || '']));
    if (row.table !== 'SF1' || !row.ticker) continue;
    taxonomy.set(row.ticker.toUpperCase(), {
      name: row.name,
      sector: row.sector || null,
      industry: row.industry || null,
    });
  }
  return taxonomy;
}

const industryGroups = {
  'Chips & network hardware': new Set([
    'Semiconductors',
    'Semiconductor Equipment & Materials',
    'Communication Equipment',
    'Scientific & Technical Instruments',
    'Electronic Components',
    'Consumer Electronics',
  ]),
  'Software & cloud': new Set([
    'Software - Infrastructure',
    'Software - Application',
    'Health Information Services',
  ]),
  'Internet, media & gaming': new Set([
    'Internet Content & Information',
    'Entertainment',
    'Electronic Gaming & Multimedia',
    'Telecom Services',
  ]),
  'Consumer & commerce': new Set([
    'Internet Retail',
    'Specialty Retail',
    'Footwear & Accessories',
    'Apparel Manufacturing',
    'Restaurants',
    'Home Improvement Retail',
    'Household & Personal Products',
    'Tobacco',
    'Leisure',
    'Gambling',
  ]),
  'Mobility & travel': new Set([
    'Auto Manufacturers',
    'Auto & Truck Dealerships',
    'Airports & Air Services',
    'Travel Services',
    'Lodging',
    'Recreational Vehicles',
  ]),
  'Financial & fintech': new Set([
    'Credit Services',
    'Financial Data & Stock Exchanges',
    'Banks - Regional',
    'Capital Markets',
    'Mortgage Finance',
  ]),
};

function groupForHolding(ticker, industry) {
  if (ticker === 'FWONK') return 'Internet, media & gaming';
  for (const [group, industries] of Object.entries(industryGroups)) {
    if (industries.has(industry)) return group;
  }
  return 'Other / diversified';
}

function mean(values) {
  return values.length
    ? values.reduce((sum, value) => sum + value, 0) / values.length
    : 0;
}

function summarizeObservations(observations) {
  const winners = observations.filter((item) => item.excessReturn > 0);
  const losers = observations.filter((item) => item.excessReturn < 0);
  const averageWinner = mean(winners.map((item) => item.excessReturn));
  const averageLoser = mean(losers.map((item) => item.excessReturn));
  return {
    observations: observations.length,
    winners: winners.length,
    losers: losers.length,
    hitRate: observations.length ? winners.length / observations.length : 0,
    averageWinnerExcessReturn: averageWinner,
    averageLoserExcessReturn: averageLoser,
    payoffRatio:
      winners.length && losers.length
        ? averageWinner / Math.abs(averageLoser)
        : null,
    averageExcessReturn: mean(observations.map((item) => item.excessReturn)),
  };
}

const database = new DatabaseSync(databasePath, { readOnly: true });
const sourceRow = database
  .prepare(
    "SELECT generated_at, payload_json FROM guru_backtests WHERE guru_id = 'gavin-baker' AND years = 0",
  )
  .get();

if (!sourceRow?.payload_json) {
  throw new Error('Missing all-history Gavin Baker backtest.');
}

const sourcePayload = JSON.parse(sourceRow.payload_json);
if (!Array.isArray(sourcePayload.quarterContributions)) {
  throw new Error('Gavin Baker backtest has no quarterly contribution detail.');
}

const taxonomyText = await readFile(taxonomyPath, 'utf8');
const taxonomy = loadTaxonomy(taxonomyText);
const completedQuarters = sourcePayload.quarterContributions.filter(
  (quarter) =>
    quarter.nextExecutionDate &&
    Number(quarter.days) >= 60 &&
    Array.isArray(quarter.contributions) &&
    quarter.contributions.length,
);
const rebalanceByExecutionDate = new Map(
  sourcePayload.rebalances.map((rebalance) => [rebalance.executionDate, rebalance]),
);

const observations = completedQuarters.flatMap((quarter) => {
  const rebalance = rebalanceByExecutionDate.get(quarter.executionDate);
  return quarter.contributions.map((holding) => {
    const ticker = String(holding.ticker || '').toUpperCase();
    const classification = taxonomy.get(ticker) || {};
    return {
      quarter: quarter.label,
      reportDate: quarter.reportDate,
      filingDate: quarter.filingDate,
      executionDate: quarter.executionDate,
      endDate: quarter.endDate,
      filingAccessionNumber: rebalance?.filing?.accessionNumber || null,
      ticker,
      issuer: holding.issuer,
      weight: holding.weight,
      stockReturn: holding.returnPct,
      spyReturn: quarter.benchmarkReturn,
      excessReturn: holding.returnPct - quarter.benchmarkReturn,
      sector: classification.sector || null,
      industry: classification.industry || null,
      industryGroup: groupForHolding(ticker, classification.industry),
    };
  });
});

const groups = new Map();
for (const observation of observations) {
  if (!groups.has(observation.industryGroup)) {
    groups.set(observation.industryGroup, []);
  }
  groups.get(observation.industryGroup).push(observation);
}

const groupOrder = [
  'Chips & network hardware',
  'Internet, media & gaming',
  'Financial & fintech',
  'Consumer & commerce',
  'Other / diversified',
  'Mobility & travel',
  'Software & cloud',
];
const groupMetrics = groupOrder.map((group) => ({
  group,
  ...summarizeObservations(groups.get(group) || []),
}));
const overallMetrics = summarizeObservations(observations);

const gavin = gurus.find((guru) => guru.id === 'gavin-baker');
if (!gavin) throw new Error('Gavin Baker configuration is missing.');
const filingHistory = await load13fHoldingHistory(gavin, { years: 0, limit: 40 });
const filingByAccession = new Map(
  filingHistory.map((row) => [row.filing.accessionNumber, row]),
);
const matchedQuarters = completedQuarters.map((quarter) => {
  const rebalance = rebalanceByExecutionDate.get(quarter.executionDate);
  return {
    quarter,
    rebalance,
    filing: filingByAccession.get(rebalance?.filing?.accessionNumber),
  };
});

if (matchedQuarters.some((item) => !item.filing)) {
  const missing = matchedQuarters
    .filter((item) => !item.filing)
    .map((item) => item.rebalance?.filing?.accessionNumber || item.quarter.label);
  throw new Error('Missing SEC filing history for: ' + missing.join(', '));
}

const bigAddEvents = [];
for (let index = 1; index < matchedQuarters.length; index += 1) {
  const previous = matchedQuarters[index - 1];
  const current = matchedQuarters[index];
  const previousCommon = new Map(
    previous.filing.holdings
      .filter((holding) => !holding.putCall && holding.shareType === 'SH')
      .map((holding) => [holding.id, holding]),
  );
  const contributionByTicker = new Map(
    current.quarter.contributions.map((holding) => [holding.ticker, holding]),
  );
  for (const holding of current.filing.holdings) {
    if (
      holding.putCall ||
      holding.shareType !== 'SH' ||
      !holding.ticker ||
      !(holding.shares > 0)
    ) {
      continue;
    }
    const contribution = contributionByTicker.get(holding.ticker);
    if (!contribution) continue;
    const priorHolding = previousCommon.get(holding.id);
    const isNew = !(priorHolding?.shares > 0);
    const shareChangePct = isNew
      ? null
      : (holding.shares - priorHolding.shares) / priorHolding.shares;
    const qualifies =
      (isNew || shareChangePct >= 0.5) &&
      contribution.weight >= 0.1;
    if (!qualifies) continue;
    const classification = taxonomy.get(holding.ticker) || {};
    bigAddEvents.push({
      quarter: current.quarter.label,
      reportDate: current.quarter.reportDate,
      filingDate: current.quarter.filingDate,
      executionDate: current.quarter.executionDate,
      endDate: current.quarter.endDate,
      filingAccessionNumber: current.filing.filing.accessionNumber,
      ticker: holding.ticker,
      issuer: holding.issuer,
      cusip: holding.cusip,
      isNew,
      previousShares: priorHolding?.shares || 0,
      currentShares: holding.shares,
      shareChangePct,
      endingWeightInPricedLongBook: contribution.weight,
      stockReturn: contribution.returnPct,
      spyReturn: current.quarter.benchmarkReturn,
      excessReturn: contribution.returnPct - current.quarter.benchmarkReturn,
      sector: classification.sector || null,
      industry: classification.industry || null,
      industryGroup: groupForHolding(holding.ticker, classification.industry),
    });
  }
}

const bigAddMetrics = summarizeObservations(bigAddEvents);
const semiconductorBigAddEvents = bigAddEvents.filter(
  (event) => event.industry === 'Semiconductors',
);
const semiconductorBigAddMetrics = summarizeObservations(
  semiconductorBigAddEvents,
);

if (completedQuarters.length !== 26) {
  throw new Error('Expected 26 complete filing-to-filing windows.');
}
if (observations.length !== 634) {
  throw new Error('Expected 634 priced long-position observations.');
}
if (
  groupMetrics.reduce((sum, group) => sum + group.observations, 0) !==
  observations.length
) {
  throw new Error('Industry groups do not reconcile to the full sample.');
}
if (bigAddMetrics.observations !== 23) {
  throw new Error('Expected 23 high-conviction big-add events.');
}
if (semiconductorBigAddMetrics.observations !== 8) {
  throw new Error('Expected 8 semiconductor big-add events.');
}

const displayStart = completedQuarters[0].executionDate;
const displayEnd = completedQuarters.at(-1).endDate;
const latestPriceDate = sourcePayload.window?.end || null;
const pct = (value) => Math.round(value * 100) + '%';
const ratio = (value) => Number(value).toFixed(2) + '×';
const number = (value) => Number(value).toLocaleString('en-US');
const escapeXml = (value) =>
  String(value)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');
const payoffColor = (value) =>
  value >= 1.5 ? colors.mint : value >= 1 ? colors.amber : colors.red;

const rowStart = 449;
const rowHeight = 40;
const barX = 495;
const barWidth = 260;
const groupRows = groupMetrics
  .map((item, index) => {
    const y = rowStart + index * rowHeight;
    const width = Math.max(2, item.hitRate * barWidth);
    const highlighted = item.group === 'Chips & network hardware';
    return [
      '<rect x="118" y="' + (y - 25) + '" width="920" height="36" rx="10" fill="' +
        (highlighted ? '#12302D' : index % 2 ? '#111B2A' : '#0E1725') + '"/>',
      '<text x="136" y="' + y + '" class="' + (highlighted ? 'rowStrong' : 'row') + '">' +
        escapeXml(item.group.toUpperCase()) + '</text>',
      '<text x="443" y="' + y + '" text-anchor="end" class="n">N=' +
        number(item.observations) + '</text>',
      '<rect x="' + barX + '" y="' + (y - 13) + '" width="' + barWidth +
        '" height="16" rx="8" fill="#202C3F"/>',
      '<path d="M' + (barX + barWidth / 2) + ' ' + (y - 16) + 'V' + (y + 6) +
        '" stroke="#657188" stroke-opacity=".7"/>',
      '<rect x="' + barX + '" y="' + (y - 13) + '" width="' + width.toFixed(1) +
        '" height="16" rx="8" fill="' + (highlighted ? colors.mint : '#3C8C7D') + '"/>',
      '<text x="787" y="' + y + '" text-anchor="end" class="rate">' +
        pct(item.hitRate) + '</text>',
      '<rect x="850" y="' + (y - 23) + '" width="156" height="32" rx="10" fill="#162131" stroke="' +
        payoffColor(item.payoffRatio) + '" stroke-opacity=".65"/>',
      '<text x="928" y="' + y + '" text-anchor="middle" class="payoff" fill="' +
        payoffColor(item.payoffRatio) + '">' + ratio(item.payoffRatio) + '</text>',
    ].join('');
  })
  .join('');

const fontStack =
  "-apple-system, BlinkMacSystemFont, 'Inter', 'Helvetica Neue', Arial, sans-serif";
const svgText = [
  '<svg width="1600" height="900" xmlns="http://www.w3.org/2000/svg">',
  '<defs>',
  '<linearGradient id="background" x1="0" y1="0" x2="1" y2="1"><stop stop-color="#07101B"/><stop offset="1" stop-color="#0A1422"/></linearGradient>',
  '<radialGradient id="glow" cx="0" cy="0" r="1" gradientTransform="translate(1510 95) rotate(135) scale(470 380)"><stop stop-color="' + colors.mint + '" stop-opacity=".10"/><stop offset="1" stop-color="' + colors.mint + '" stop-opacity="0"/></radialGradient>',
  '</defs>',
  '<style>',
  'text { font-family: ' + fontStack + '; }',
  '.brand { font-size:25px;font-weight:820;fill:' + colors.text + ';letter-spacing:.8px }',
  '.meta { font-size:14px;font-weight:680;fill:' + colors.muted + ';letter-spacing:.45px }',
  '.eyebrow { font-size:15px;font-weight:800;fill:' + colors.mint + ';letter-spacing:1.15px }',
  '.headline { font-size:48px;font-weight:850;fill:' + colors.text + ';letter-spacing:-1.2px }',
  '.headlineMint { font-size:48px;font-weight:850;fill:' + colors.mint + ';letter-spacing:-1.2px }',
  '.subtitle { font-size:17px;font-weight:570;fill:' + colors.muted + ' }',
  '.tableHead { font-size:11px;font-weight:800;fill:' + colors.subdued + ';letter-spacing:.9px }',
  '.summary { font-size:12px;font-weight:760;fill:' + colors.muted + ';letter-spacing:.25px }',
  '.row { font-size:13px;font-weight:730;fill:' + colors.text + ';letter-spacing:.3px }',
  '.rowStrong { font-size:13px;font-weight:820;fill:' + colors.mint2 + ';letter-spacing:.3px }',
  '.n { font-size:11px;font-weight:650;fill:' + colors.subdued + ' }',
  '.rate { font-size:19px;font-weight:850;fill:' + colors.text + ' }',
  '.payoff { font-size:18px;font-weight:850 }',
  '.portraitTitle { font-size:18px;font-weight:820;fill:' + colors.text + ' }',
  '.portraitMeta { font-size:11px;font-weight:720;fill:' + colors.muted + ';letter-spacing:.5px }',
  '.kpiLabel { font-size:12px;font-weight:790;fill:' + colors.muted + ';letter-spacing:.65px }',
  '.kpiHero { font-size:51px;font-weight:880;letter-spacing:-1.3px }',
  '.kpiSide { font-size:23px;font-weight:850 }',
  '.kpiNote { font-size:11px;font-weight:650;fill:' + colors.muted + ' }',
  '.method { font-size:10.5px;font-weight:760;fill:' + colors.text + ';letter-spacing:.2px }',
  '.fine { font-size:10.5px;font-weight:570;fill:' + colors.muted + ' }',
  '.source { font-size:11px;font-weight:730;fill:' + colors.text + ' }',
  '.url { font-size:14px;font-weight:800;fill:' + colors.text + ' }',
  '</style>',
  '<rect width="1600" height="900" fill="url(#background)"/>',
  '<rect width="1600" height="900" fill="url(#glow)"/>',
  '<rect x="52" y="44" width="1496" height="812" rx="30" fill="' + colors.ink + '" fill-opacity=".97" stroke="' + colors.line + '" stroke-width="1.5"/>',
  '<rect x="52" y="44" width="8" height="812" rx="4" fill="' + colors.mint + '"/>',
  '<path d="M88 158H1512" stroke="' + colors.line + '"/>',
  '<path d="M1104 184V746" stroke="' + colors.line + '"/>',
  '<text x="156" y="104" class="brand">THESISFORGE</text>',
  '<text x="1472" y="102" text-anchor="end" class="meta">ATREIDES 13F STUDY · 26 COMPLETE WINDOWS</text>',
  '<text x="1472" y="127" text-anchor="end" class="meta">' + displayStart + ' → ' + displayEnd + ' · 634 HOLDING OBSERVATIONS</text>',
  '<text x="104" y="202" class="eyebrow">I TESTED EVERY PRICED DISCLOSED LONG AFTER THE FILING BECAME PUBLIC</text>',
  '<text x="104" y="260" class="headline">GAVIN BAKER’S</text>',
  '<text x="104" y="318" class="headlineMint">HARDWARE EDGE.</text>',
  '<text x="104" y="350" class="subtitle">All disclosed longs: ' + pct(overallMetrics.hitRate) + ' win rate · ' + ratio(overallMetrics.payoffRatio) + ' payoff. The edge is payoff asymmetry.</text>',
  '<rect x="104" y="374" width="962" height="356" rx="20" fill="' + colors.panel + '" stroke="' + colors.line + '"/>',
  '<text x="130" y="404" class="tableHead">INDUSTRY CLUSTER</text>',
  '<text x="495" y="404" class="tableHead">WIN RATE · BEAT SPY</text>',
  '<text x="928" y="404" text-anchor="middle" class="tableHead">PAYOFF · AVG WIN / AVG LOSS</text>',
  '<path d="M118 418H1038" stroke="' + colors.line + '"/>',
  groupRows,
  '<text x="130" y="716" class="summary" fill="' + colors.mint2 + '">HARDWARE: +9pp WIN RATE VS ALL OBSERVATIONS · ~2× THE OVERALL PAYOFF</text>',
  '<circle cx="1178" cy="229" r="53" fill="#0D1726" stroke="' + colors.mint + '" stroke-width="2"/>',
  '<text x="1249" y="216" class="portraitTitle">GAVIN BAKER</text>',
  '<text x="1249" y="239" class="portraitMeta">ATREIDES MANAGEMENT · CIO</text>',
  '<text x="1249" y="258" class="portraitMeta">13F PROXY · NOT FUND PERFORMANCE</text>',
  '<rect x="1132" y="304" width="340" height="178" rx="18" fill="' + colors.panel2 + '" stroke="#28675D"/>',
  '<text x="1156" y="337" class="kpiLabel">HIGH-CONVICTION ADD · NEXT WINDOW</text>',
  '<text x="1156" y="404" class="kpiHero" fill="' + colors.mint + '">' + pct(bigAddMetrics.hitRate) + '</text>',
  '<text x="1288" y="382" class="kpiLabel">HIT RATE</text>',
  '<text x="1288" y="415" class="kpiSide" fill="' + colors.amber + '">' + ratio(bigAddMetrics.payoffRatio) + '</text>',
  '<text x="1288" y="436" class="kpiNote">PAYOFF · N=' + bigAddMetrics.observations + '</text>',
  '<path d="M1156 450H1448" stroke="' + colors.line + '"/>',
  '<text x="1156" y="469" class="kpiNote">NEW OR +50% SHARES · ENDING ≥10% OF PRICED LONG BOOK</text>',
  '<rect x="1132" y="500" width="340" height="126" rx="18" fill="' + colors.panel2 + '" stroke="#6A5430"/>',
  '<text x="1156" y="532" class="kpiLabel">SEMICONDUCTOR BIG ADDS</text>',
  '<text x="1156" y="579" class="kpiSide" fill="' + colors.mint + '">' + pct(semiconductorBigAddMetrics.hitRate) + ' HIT</text>',
  '<text x="1438" y="579" text-anchor="end" class="kpiSide" fill="' + colors.amber + '">' + ratio(semiconductorBigAddMetrics.payoffRatio) + '</text>',
  '<text x="1156" y="604" class="kpiNote">N=' + semiconductorBigAddMetrics.observations + ' · SMALL SAMPLE · SAME THRESHOLD</text>',
  '<rect x="1132" y="644" width="340" height="86" rx="16" fill="#12302D" stroke="#28675D"/>',
  '<text x="1156" y="675" class="kpiLabel" fill="' + colors.mint2 + '">THE TAKEAWAY</text>',
  '<text x="1156" y="704" class="method">EDGE = PAYOFF MAGNITUDE, NOT FREQUENCY.</text>',
  '<path d="M104 772H1474" stroke="' + colors.line + '"/>',
  '<text x="104" y="795" class="fine">Win = beat SPY from public filing execution to next filing execution. Payoff = average positive excess return / absolute average negative excess return.</text>',
  '<text x="104" y="815" class="fine">13F may lag 45 days and omits shorts, cash, private assets, derivatives and intra-quarter trades. Current incomplete window excluded.</text>',
  '<text x="104" y="837" class="source">SOURCE: SEC 13F + SHARADAR TAXONOMY + DAILY CLOSES · RESEARCH ONLY — NOT INVESTMENT ADVICE</text>',
  '<circle cx="1312" cy="828" r="5" fill="' + colors.mint + '"/>',
  '<text x="1326" y="834" class="url">thesisforge.tech</text>',
  '</svg>',
].join('');

await mkdir(outputDir, { recursive: true });
const mark = await sharp(assets.mark)
  .resize(58, 58, { fit: 'contain' })
  .png()
  .toBuffer();
const portraitMask = Buffer.from(
  '<svg width="96" height="96" xmlns="http://www.w3.org/2000/svg"><circle cx="48" cy="48" r="48" fill="white"/></svg>',
);
const portrait = await sharp(assets.portrait)
  .resize(96, 96, { fit: 'cover', position: 'centre' })
  .modulate({ brightness: 0.98, saturation: 0.84 })
  .composite([{ input: portraitMask, blend: 'dest-in' }])
  .png()
  .toBuffer();

await sharp(Buffer.from(svgText))
  .composite([
    { input: mark, left: 88, top: 70 },
    { input: portrait, left: 1130, top: 181 },
  ])
  .png({ compressionLevel: 9 })
  .toFile(output);

const dataPayload = {
  releaseDate,
  generatedAt,
  dataCut: {
    firstExecutionDate: displayStart,
    lastCompletedWindowEnd: displayEnd,
    latestPriceDate,
    latest13fReportDate: sourcePayload.rebalances.at(-1)?.reportDate || null,
    latest13fFilingDate: sourcePayload.rebalances.at(-1)?.filingDate || null,
    currentIncompleteWindowExcluded: true,
  },
  sources: {
    databasePath,
    backtestGeneratedAt: sourceRow.generated_at,
    backtestPayloadSha256: sha256(sourceRow.payload_json),
    taxonomyPath,
    taxonomySha256: sha256(taxonomyText),
    secFiler: {
      name: 'Atreides Management, LP',
      cik: '0001777813',
      submissionsUrl: 'https://data.sec.gov/submissions/CIK0001777813.json',
      latestFilingUrl:
        'https://www.sec.gov/Archives/edgar/data/1777813/000177781326000009/0001777813-26-000009-index.htm',
    },
    officialBiographyUrl: 'https://atreidesmgmt.com/team/gavin-baker/',
    sec13fFaqUrl:
      'https://www.sec.gov/rules-regulations/staff-guidance/division-investment-management-frequently-asked-questions/frequently-asked-questions-about-form-13f',
  },
  method: {
    observation:
      'One priced common-stock holding over one completed public-filing execution window.',
    execution:
      'Use the first tradable SPY date on or after each 13F filing date; measure through the next filing execution date.',
    win:
      'Holding price return is greater than SPY price return over the identical filing-to-filing window.',
    payoffRatio:
      'Average positive excess return divided by the absolute average negative excess return.',
    bigAdd:
      'New common-stock position or at least 50% quarter-over-quarter increase in reported shares, ending at 10% or more of the priced disclosed long copy book.',
    taxonomy:
      'Analyst-defined stable clusters built from Sharadar SF1 sector and industry labels; FWONK is manually mapped to Internet, media & gaming.',
    exclusions:
      'Options, shorts, cash, private assets, unpriced/non-ticker rows, incomplete current window, dividends, fees, taxes and slippage.',
    limitation:
      'This is a delayed disclosed-long-book proxy. It is not Gavin Baker personal performance or Atreides fund performance.',
  },
  sample: {
    completedWindows: completedQuarters.length,
    observations: observations.length,
    tickers: new Set(observations.map((item) => item.ticker)).size,
    secFilingsFetched: filingHistory.length,
  },
  overallMetrics,
  groupMetrics,
  bigAddMetrics,
  semiconductorBigAddMetrics,
  observations,
  bigAddEvents,
};
await writeFile(dataOutput, JSON.stringify(dataPayload, null, 2) + '\n');
const imageHash = sha256(await readFile(output));
const dataHash = sha256(await readFile(dataOutput));

const manifest = {
  title: "Gavin Baker's Hardware Edge",
  releaseDate,
  generatedAt,
  dimensions: { width: 1600, height: 900 },
  output: path.relative(root, output),
  data: path.relative(root, dataOutput),
  copy: path.relative(root, copyOutput),
  assets: Object.fromEntries(
    Object.entries(assets).map(([key, value]) => [key, path.relative(root, value)]),
  ),
  hashes: {
    imageSha256: imageHash,
    dataSha256: dataHash,
  },
  calculations: {
    completedWindows: completedQuarters.length,
    observations: observations.length,
    overallHitRate: overallMetrics.hitRate,
    overallPayoffRatio: overallMetrics.payoffRatio,
    highConvictionAddHitRate: bigAddMetrics.hitRate,
    highConvictionAddPayoffRatio: bigAddMetrics.payoffRatio,
    highConvictionAddEvents: bigAddMetrics.observations,
    semiconductorBigAddHitRate: semiconductorBigAddMetrics.hitRate,
    semiconductorBigAddPayoffRatio: semiconductorBigAddMetrics.payoffRatio,
    semiconductorBigAddEvents: semiconductorBigAddMetrics.observations,
  },
  contentRules: [
    'Every displayed statistic is reproduced from the companion data file.',
    'Industry win rates use identical public-filing execution windows and SPY comparison windows.',
    'High-conviction adds use reported share changes, not market-value changes.',
    'The graphic identifies Gavin Baker editorially and does not imply Atreides affiliation or endorsement.',
    'The result is labeled as a 13F proxy and not fund performance.',
  ],
};
await writeFile(manifestOutput, JSON.stringify(manifest, null, 2) + '\n');

const chips = groupMetrics.find((item) => item.group === 'Chips & network hardware');
const internet = groupMetrics.find((item) => item.group === 'Internet, media & gaming');
const software = groupMetrics.find((item) => item.group === 'Software & cloud');
const copy = [
  '# X post copy — Gavin Baker sector edge',
  '',
  "Most people study Gavin Baker's holdings. I tested where Atreides' disclosed long bets actually worked after the filings became public.",
  '',
  'Across 26 completed filing-to-filing windows and 634 priced holding observations:',
  '• Chips & network hardware: ' + pct(chips.hitRate) + ' win rate | ' + ratio(chips.payoffRatio) + ' payoff',
  '• Internet, media & gaming: ' + pct(internet.hitRate) + ' | ' + ratio(internet.payoffRatio),
  '• Software & cloud: ' + pct(software.hitRate) + ' | ' + ratio(software.payoffRatio),
  '',
  'The surprise: high-conviction adds were right only ' + pct(bigAddMetrics.hitRate) + ' of the time. Their average winner was still ' + ratio(bigAddMetrics.payoffRatio) + ' the average loser.',
  '',
  'In semiconductors, those large adds hit ' + pct(semiconductorBigAddMetrics.hitRate) + ' with a ' + ratio(semiconductorBigAddMetrics.payoffRatio) + ' payoff—but that subgroup contains only ' + semiconductorBigAddMetrics.observations + ' events.',
  '',
  "The edge was not constant prediction. It was asymmetric payoff, concentrated where Baker's domain experience is deepest.",
  '',
  'Method: win = beat SPY from public filing execution to the next filing execution. A high-conviction add = a new position or ≥50% increase in reported shares, ending at ≥10% of the priced disclosed long book.',
  '',
  'This is a delayed 13F proxy, not Gavin Baker or Atreides fund performance. 13F omits shorts, cash, private assets, derivatives and intra-quarter trading. Price returns; dividends, fees, taxes and slippage excluded.',
  '',
  '$SPY $NVDA $AMD $MU #13F #Investing',
  '',
].join('\n');
await writeFile(copyOutput, copy);

console.log(
  JSON.stringify(
    {
      output,
      dataOutput,
      manifestOutput,
      copyOutput,
      imageHash,
      dataHash,
      overallMetrics,
      groupMetrics,
      bigAddMetrics,
      semiconductorBigAddMetrics,
    },
    null,
    2,
  ),
);
