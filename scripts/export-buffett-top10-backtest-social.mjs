import { createHash } from 'node:crypto';
import { createRequire } from 'node:module';
import { mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { DatabaseSync } from 'node:sqlite';

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
const requestedGuruId = process.env.GURU_BACKTEST_ID || 'warren-buffett';
const guruConfigs = {
  'warren-buffett': {
    id: 'warren-buffett',
    managerName: 'Warren Buffett',
    managerPossessive: "Buffett's",
    entityName: 'Berkshire Hathaway',
    entityShort: 'Berkshire',
    outputStem: 'buffett-top10-backtest',
    portrait: path.join(root, 'web/guru-avatars/warren-buffett.png'),
    metaLabel: 'BERKSHIRE TOP 10',
    portraitMeta: 'BERKSHIRE 13F PROXY',
    portraitDisclaimer: "NOT BUFFETT'S FULL RETURN",
    headlineOne: "BUFFETT'S TOP 10",
    headlineTwo: "DIDN'T BEAT SPY.",
    subtitle: 'The delayed 13F is not the same thing as owning Berkshire.',
    manifestTitle: "Buffett Top 10 Didn't Beat SPY",
    backtestStart: null,
    excludeSparseAmendments: false,
    qualityNote: '',
  },
  'bill-ackman': {
    id: 'bill-ackman',
    managerName: 'Bill Ackman',
    managerPossessive: "Ackman's",
    entityName: 'Pershing Square Capital Management',
    entityShort: 'Pershing Square',
    outputStem: 'ackman-top10-backtest',
    portrait: path.join(root, 'web/guru-avatars/bill-ackman.png'),
    metaLabel: 'PERSHING SQUARE TOP 10',
    portraitMeta: 'PERSHING SQUARE 13F PROXY',
    portraitDisclaimer: 'NOT FUND PERFORMANCE',
    headlineOne: "ACKMAN'S TOP 10",
    headlineTwo: 'BEAT SPY.',
    subtitle: 'More return. More drawdown. Slightly lower risk-adjusted return.',
    manifestTitle: 'Ackman Top 10 Beat SPY — With More Risk',
    backtestStart: '2020-02-14',
    excludeSparseAmendments: true,
    qualityNote: 'Sparse confidential-treatment amendments are excluded.',
  },
};
const guruConfig = guruConfigs[requestedGuruId];
if (!guruConfig) {
  throw new Error(`Unsupported GURU_BACKTEST_ID: ${requestedGuruId}`);
}
const outputDir = path.join(root, 'docs/brand/2026-08-30');
const output = path.join(outputDir, `${guruConfig.outputStem}-en-1600x900.png`);
const dataOutput = path.join(outputDir, `${guruConfig.outputStem}-equity-daily.json`);
const manifestOutput = path.join(outputDir, `${guruConfig.outputStem}-manifest.json`);
const copyOutput = path.join(outputDir, `${guruConfig.outputStem}-copy-en.md`);
const databasePath =
  process.env.BUFFETT_BACKTEST_DB ||
  '/Users/yudonglu/Documents/thesisforge/server/data/guru-analysis.sqlite';

const assets = {
  mark: path.join(root, 'assets/branding/thesisforge-mark.png'),
  portrait: guruConfig.portrait,
};

const colors = {
  ink: '#0B111D',
  panel: '#101826',
  panel2: '#141E2D',
  line: '#263248',
  mint: '#22D3A6',
  mintDeep: '#0E6D5B',
  amber: '#E0B15A',
  red: '#FF7B7B',
  text: '#F8FAFC',
  muted: '#A8B2C4',
  subdued: '#718096',
};

const db = new DatabaseSync(databasePath, { readOnly: true });
const sourceRow = db
  .prepare(
    `SELECT generated_at, payload_json
       FROM guru_backtests
      WHERE guru_id = ? AND years = 0`,
  )
  .get(guruConfig.id);

if (!sourceRow?.payload_json) {
  throw new Error(`Missing all-history ${guruConfig.managerName} backtest in ${databasePath}`);
}

const sourcePayload = JSON.parse(sourceRow.payload_json);
if (!Array.isArray(sourcePayload.equity) || sourcePayload.equity.length < 2) {
  throw new Error('The source backtest has no usable daily equity series.');
}
if (
  !Array.isArray(sourcePayload.quarterContributions) ||
  sourcePayload.quarterContributions.some(
    (quarter) => !Array.isArray(quarter.contributions) || !quarter.contributions.length,
  )
) {
  throw new Error('The source backtest does not contain full quarterly holding attribution.');
}

const sourceHash = createHash('sha256').update(sourceRow.payload_json).digest('hex');
const rebalanceMetadata = new Map(
  (sourcePayload.rebalances || []).map((rebalance) => [
    rebalance.executionDate,
    rebalance,
  ]),
);
const sparseAmendment = (quarter) => {
  const metadata = rebalanceMetadata.get(quarter.executionDate);
  return Boolean(
    guruConfig.excludeSparseAmendments &&
      metadata?.positions <= 1 &&
      metadata?.totalValue < 1_000_000_000,
  );
};
const eligibleQuarterContributions = sourcePayload.quarterContributions.filter(
  (quarter) =>
    (!guruConfig.backtestStart || quarter.executionDate >= guruConfig.backtestStart) &&
    !sparseAmendment(quarter),
);
const excludedSparseFilings = sourcePayload.quarterContributions
  .filter(
    (quarter) =>
      (!guruConfig.backtestStart || quarter.executionDate >= guruConfig.backtestStart) &&
      sparseAmendment(quarter),
  )
  .map((quarter) => ({
    reportDate: quarter.reportDate,
    filingDate: quarter.filingDate,
    executionDate: quarter.executionDate,
    reason: 'Sparse one-position amendment below $1bn excluded; prior valid weights carried forward.',
  }));

// Rebuild the strategy from the production backtest's filing-visible holding book.
// Each quarter is independently ranked by disclosed market value, capped at ten
// securities, and renormalized to 100%. Share classes remain separate securities.
const rebalances = eligibleQuarterContributions
  .map((quarter) => {
    const selected = [...quarter.contributions]
      .filter(
        (holding) =>
          holding.ticker && Number.isFinite(holding.value) && holding.value > 0,
      )
      .sort((left, right) => right.value - left.value)
      .slice(0, 10);
    const selectedValue = selected.reduce((sum, holding) => sum + holding.value, 0);
    return {
      reportDate: quarter.reportDate,
      filingDate: quarter.filingDate,
      executionDate: quarter.executionDate,
      selectedValue,
      holdings: selected.map((holding) => ({
        ticker: holding.ticker,
        issuer: holding.issuer,
        value: holding.value,
        weight: holding.value / selectedValue,
      })),
    };
  })
  .filter((rebalance) => rebalance.holdings.length)
  .sort((left, right) => left.executionDate.localeCompare(right.executionDate));

const sourceEquity = sourcePayload.equity.filter(
  (point) => point.date >= rebalances[0].executionDate,
);
const sourceDates = sourceEquity.map((point) => point.date);
const startDate = sourceDates[0];
const endDate = sourceDates.at(-1);
const spyBaseValue = sourceEquity[0].benchmark;

const tickers = [...new Set(rebalances.flatMap((item) => item.holdings.map((holding) => holding.ticker)))];
const priceStatement = db.prepare(
  `SELECT date, close
     FROM price_points
    WHERE symbol = ? AND date >= ? AND date <= ?
    ORDER BY date`,
);
const priceMaps = new Map(
  tickers.map((ticker) => [
    ticker,
    new Map(
      priceStatement
        .all(ticker, startDate, endDate)
        .map((point) => [point.date, point.close]),
    ),
  ]),
);

function dailyReturn(priceMap, previousDate, date) {
  const previous = priceMap?.get(previousDate);
  const current = priceMap?.get(date);
  if (!Number.isFinite(previous) || !Number.isFinite(current) || previous <= 0) {
    return null;
  }
  return current / previous - 1;
}

let activeWeights = rebalances[0].holdings;
let rebalanceIndex = 0;
let portfolioValue = 1;
const dailyReturns = [];
const coverage = [];
const equity = [
  {
    date: sourceEquity[0].date,
    top10: portfolioValue,
    spy: 1,
  },
];

for (let index = 1; index < sourceDates.length; index += 1) {
  const previousDate = sourceDates[index - 1];
  const date = sourceDates[index];
  let returnPct = 0;
  let coveredWeight = 0;

  for (const holding of activeWeights) {
    const holdingReturn = dailyReturn(
      priceMaps.get(holding.ticker),
      previousDate,
      date,
    );
    if (Number.isFinite(holdingReturn)) {
      returnPct += holding.weight * holdingReturn;
      coveredWeight += holding.weight;
    }
  }

  portfolioValue *= 1 + returnPct;
  dailyReturns.push(returnPct);
  coverage.push(coveredWeight);
  equity.push({
    date,
    top10: portfolioValue,
    spy: sourceEquity[index].benchmark / spyBaseValue,
  });

  // A filing that becomes public on date D is applied after D's close, matching
  // the production engine's execution convention and avoiding look-ahead.
  while (
    rebalanceIndex + 1 < rebalances.length &&
    rebalances[rebalanceIndex + 1].executionDate <= date
  ) {
    rebalanceIndex += 1;
    activeWeights = rebalances[rebalanceIndex].holdings;
  }
}

function mean(values) {
  return values.length
    ? values.reduce((sum, value) => sum + value, 0) / values.length
    : 0;
}

function stdev(values) {
  if (values.length < 2) return 0;
  const average = mean(values);
  return Math.sqrt(
    values.reduce((sum, value) => sum + (value - average) ** 2, 0) /
      (values.length - 1),
  );
}

function maxDrawdown(points, key) {
  let peak = points[0]?.[key] || 1;
  let drawdown = 0;
  for (const point of points) {
    peak = Math.max(peak, point[key]);
    drawdown = Math.min(drawdown, point[key] / peak - 1);
  }
  return drawdown;
}

function metrics(points, key, returns) {
  const first = points[0];
  const last = points.at(-1);
  const days = Math.max(
    1,
    (Date.parse(`${last.date}T00:00:00Z`) -
      Date.parse(`${first.date}T00:00:00Z`)) /
      86_400_000,
  );
  const volatility = stdev(returns) * Math.sqrt(252);
  return {
    totalReturn: last[key] / first[key] - 1,
    cagr: (last[key] / first[key]) ** (365.25 / days) - 1,
    volatility,
    sharpe: volatility ? (mean(returns) / stdev(returns)) * Math.sqrt(252) : 0,
    maxDrawdown: maxDrawdown(points, key),
  };
}

const top10Metrics = metrics(equity, 'top10', dailyReturns);
const spyReturns = equity.slice(1).map((point, index) => {
  const previous = equity[index];
  return point.spy / previous.spy - 1;
});
const spyMetrics = metrics(equity, 'spy', spyReturns);
const averageCoverage = mean(coverage);

const strategy = {
  name: `${guruConfig.entityShort} Top 10 13F Copy`,
  startDate,
  endDate,
  rebalances: rebalances.length,
  positionsPerRebalance: 10,
  sourceGeneratedAt: sourceRow.generated_at,
  top10: top10Metrics,
  spy: spyMetrics,
  excessCagr: top10Metrics.cagr - spyMetrics.cagr,
  excessTotalReturn: top10Metrics.totalReturn - spyMetrics.totalReturn,
  averageCoverage,
};

const percent = (value, digits = 1) => `${value >= 0 ? '+' : '−'}${Math.abs(value * 100).toFixed(digits)}%`;
const unsignedPercent = (value, digits = 1) => `${(value * 100).toFixed(digits)}%`;
const moneyFromTenK = (value) => `$${Math.round(value * 10_000).toLocaleString('en-US')}`;

const chart = { x: 106, y: 380, width: 960, height: 330 };
const startMs = Date.parse(`${startDate}T00:00:00Z`);
const endMs = Date.parse(`${endDate}T00:00:00Z`);
const minValue = Math.max(
  0,
  Math.floor(Math.min(...equity.flatMap((point) => [point.top10, point.spy])) * 10) /
    10 -
    0.1,
);
const maxValue =
  Math.ceil(Math.max(...equity.flatMap((point) => [point.top10, point.spy])) * 2) /
  2;

function coordinates(point, key) {
  const time = Date.parse(`${point.date}T00:00:00Z`);
  return [
    chart.x + ((time - startMs) / (endMs - startMs)) * chart.width,
    chart.y +
      ((maxValue - point[key]) / (maxValue - minValue)) * chart.height,
  ];
}

function curvePath(key) {
  return equity
    .map((point, index) => {
      const [x, y] = coordinates(point, key);
      return `${index ? 'L' : 'M'}${x.toFixed(2)} ${y.toFixed(2)}`;
    })
    .join(' ');
}

const top10Path = curvePath('top10');
const spyPath = curvePath('spy');
const [top10EndX, top10EndY] = coordinates(equity.at(-1), 'top10');
const [spyEndX, spyEndY] = coordinates(equity.at(-1), 'spy');
const top10Area = `${top10Path} L${top10EndX.toFixed(2)} ${(chart.y + chart.height).toFixed(2)} L${chart.x} ${(chart.y + chart.height).toFixed(2)} Z`;
const yearTicks = [2014, 2016, 2018, 2020, 2022, 2024, 2026];
const yTicks = [1, 2, 3, 4, 5].filter(
  (value) => value >= minValue && value <= maxValue,
);
const xForDate = (date) =>
  chart.x +
  ((Date.parse(`${date}T00:00:00Z`) - startMs) / (endMs - startMs)) *
    chart.width;
const yForValue = (value) =>
  chart.y + ((maxValue - value) / (maxValue - minValue)) * chart.height;

const fontStack = `-apple-system, BlinkMacSystemFont, 'Inter', 'Helvetica Neue', Arial, sans-serif`;
const svg = Buffer.from(`
  <svg width="1600" height="900" xmlns="http://www.w3.org/2000/svg">
    <defs>
      <linearGradient id="background" x1="0" y1="0" x2="1" y2="1">
        <stop stop-color="#07101B"/>
        <stop offset="1" stop-color="#0A1422"/>
      </linearGradient>
      <linearGradient id="top10Area" x1="0" y1="0" x2="0" y2="1">
        <stop stop-color="${colors.mint}" stop-opacity=".24"/>
        <stop offset="1" stop-color="${colors.mint}" stop-opacity="0"/>
      </linearGradient>
      <radialGradient id="glow" cx="0" cy="0" r="1" gradientTransform="translate(1480 110) rotate(135) scale(430 350)">
        <stop stop-color="${colors.amber}" stop-opacity=".10"/>
        <stop offset="1" stop-color="${colors.amber}" stop-opacity="0"/>
      </radialGradient>
      <filter id="softGlow" x="-30%" y="-30%" width="160%" height="160%">
        <feGaussianBlur stdDeviation="5" result="blur"/>
        <feMerge><feMergeNode in="blur"/><feMergeNode in="SourceGraphic"/></feMerge>
      </filter>
    </defs>
    <style>
      text { font-family: ${fontStack}; }
      .brand { font-size: 25px; font-weight: 820; fill: ${colors.text}; letter-spacing: .8px; }
      .meta { font-size: 14px; font-weight: 680; fill: ${colors.muted}; letter-spacing: .45px; }
      .eyebrow { font-size: 16px; font-weight: 800; fill: ${colors.mint}; letter-spacing: 1.25px; }
      .headline { font-size: 48px; font-weight: 850; fill: ${colors.text}; letter-spacing: -1.25px; }
      .headlineMint { font-size: 48px; font-weight: 850; fill: ${colors.mint}; letter-spacing: -1.25px; }
      .subtitle { font-size: 17px; font-weight: 570; fill: ${colors.muted}; }
      .chartTitle { font-size: 13px; font-weight: 790; fill: ${colors.text}; letter-spacing: .8px; }
      .axis { font-size: 11px; font-weight: 650; fill: ${colors.subdued}; }
      .legend { font-size: 13px; font-weight: 720; fill: ${colors.muted}; }
      .endLabel { font-size: 12px; font-weight: 850; }
      .kpiHero { font-size: 43px; font-weight: 860; letter-spacing: -1px; }
      .kpiLabel { font-size: 12px; font-weight: 790; fill: ${colors.muted}; letter-spacing: .65px; }
      .kpiValue { font-size: 23px; font-weight: 830; fill: ${colors.text}; }
      .kpiCompare { font-size: 12px; font-weight: 690; fill: ${colors.muted}; }
      .portraitTitle { font-size: 18px; font-weight: 820; fill: ${colors.text}; }
      .portraitMeta { font-size: 11px; font-weight: 720; fill: ${colors.muted}; letter-spacing: .5px; }
      .method { font-size: 10.5px; font-weight: 760; fill: ${colors.text}; letter-spacing: .2px; }
      .fine { font-size: 11px; font-weight: 570; fill: ${colors.muted}; }
      .source { font-size: 11px; font-weight: 730; fill: ${colors.text}; }
      .url { font-size: 14px; font-weight: 800; fill: ${colors.text}; }
    </style>

    <rect width="1600" height="900" fill="url(#background)"/>
    <rect width="1600" height="900" fill="url(#glow)"/>
    <rect x="52" y="44" width="1496" height="812" rx="30" fill="${colors.ink}" fill-opacity=".965" stroke="${colors.line}" stroke-width="1.5"/>
    <rect x="52" y="44" width="8" height="812" rx="4" fill="${colors.mint}"/>
    <path d="M88 158H1512" stroke="${colors.line}"/>
    <path d="M1104 184V772" stroke="${colors.line}"/>

    <text x="156" y="104" class="brand">THESISFORGE</text>
    <text x="1472" y="102" text-anchor="end" class="meta">${guruConfig.metaLabel} · DISCLOSURE-DATE BACKTEST</text>
    <text x="1472" y="127" text-anchor="end" class="meta">${startDate} → ${endDate} · ${rebalances.length} REBALANCES</text>

    <text x="104" y="204" class="eyebrow">I TESTED THE PORTFOLIO ORDINARY INVESTORS CAN ACTUALLY COPY</text>
    <text x="104" y="263" class="headline">${guruConfig.headlineOne}</text>
    <text x="104" y="321" class="headlineMint">${guruConfig.headlineTwo}</text>
    <text x="104" y="352" class="subtitle">${guruConfig.subtitle}</text>

    <rect x="104" y="374" width="962" height="356" rx="20" fill="${colors.panel}" stroke="${colors.line}"/>
    <text x="130" y="405" class="chartTitle">GROWTH OF $10,000 · PRICE RETURN</text>
    <circle cx="706" cy="401" r="5" fill="${colors.mint}"/>
    <text x="719" y="406" class="legend">Top 10 13F copy</text>
    <circle cx="876" cy="401" r="5" fill="${colors.amber}"/>
    <text x="889" y="406" class="legend">SPY</text>

    ${yTicks
      .map(
        (value) => `
          <path d="M${chart.x} ${yForValue(value).toFixed(2)}H${chart.x + chart.width}" stroke="${colors.line}" stroke-opacity=".65"/>
          <text x="${chart.x + 8}" y="${(yForValue(value) - 7).toFixed(2)}" class="axis">${moneyFromTenK(value)}</text>`,
      )
      .join('')}
    ${yearTicks
      .map(
        (year) => `
          <path d="M${xForDate(`${year}-01-01`).toFixed(2)} ${chart.y}V${chart.y + chart.height}" stroke="${colors.line}" stroke-opacity=".34"/>
          <text x="${xForDate(`${year}-01-01`).toFixed(2)}" y="${chart.y + chart.height + 22}" text-anchor="middle" class="axis">${year}</text>`,
      )
      .join('')}

    <path d="${top10Area}" fill="url(#top10Area)"/>
    <path d="${spyPath}" fill="none" stroke="${colors.amber}" stroke-width="3" stroke-linejoin="round" stroke-linecap="round"/>
    <path d="${top10Path}" fill="none" stroke="${colors.mint}" stroke-width="4" stroke-linejoin="round" stroke-linecap="round" filter="url(#softGlow)"/>
    <circle cx="${spyEndX.toFixed(2)}" cy="${spyEndY.toFixed(2)}" r="6" fill="${colors.amber}" stroke="${colors.ink}" stroke-width="3"/>
    <circle cx="${top10EndX.toFixed(2)}" cy="${top10EndY.toFixed(2)}" r="7" fill="${colors.mint}" stroke="${colors.ink}" stroke-width="3"/>
    <rect x="${(spyEndX - 95).toFixed(2)}" y="${(spyEndY - 31).toFixed(2)}" width="89" height="24" rx="8" fill="#3A2F20" stroke="#6A5430"/>
    <text x="${(spyEndX - 50).toFixed(2)}" y="${(spyEndY - 14).toFixed(2)}" text-anchor="middle" class="endLabel" fill="${colors.amber}">SPY ${moneyFromTenK(equity.at(-1).spy)}</text>
    <rect x="${(top10EndX - 105).toFixed(2)}" y="${(top10EndY + 10).toFixed(2)}" width="99" height="24" rx="8" fill="#123F3A" stroke="#28675D"/>
    <text x="${(top10EndX - 55).toFixed(2)}" y="${(top10EndY + 27).toFixed(2)}" text-anchor="middle" class="endLabel" fill="${colors.mint}">TOP 10 ${moneyFromTenK(equity.at(-1).top10)}</text>

    <circle cx="1178" cy="229" r="53" fill="#0D1726" stroke="${colors.amber}" stroke-width="2"/>
    <text x="1249" y="216" class="portraitTitle">${guruConfig.managerName.toUpperCase()}</text>
    <text x="1249" y="239" class="portraitMeta">${guruConfig.portraitMeta}</text>
    <text x="1249" y="258" class="portraitMeta">${guruConfig.portraitDisclaimer}</text>

    <rect x="1132" y="304" width="340" height="118" rx="18" fill="${colors.panel2}" stroke="#28675D"/>
    <text x="1156" y="336" class="kpiLabel">TOP 10 COPY · TOTAL RETURN</text>
    <text x="1156" y="388" class="kpiHero" fill="${colors.mint}">${percent(top10Metrics.totalReturn)}</text>
    <text x="1448" y="402" text-anchor="end" class="kpiCompare">${moneyFromTenK(equity.at(-1).top10)} ending value</text>

    <rect x="1132" y="438" width="340" height="118" rx="18" fill="${colors.panel2}" stroke="#6A5430"/>
    <text x="1156" y="470" class="kpiLabel">SPY · TOTAL RETURN</text>
    <text x="1156" y="522" class="kpiHero" fill="${colors.amber}">${percent(spyMetrics.totalReturn)}</text>
    <text x="1448" y="536" text-anchor="end" class="kpiCompare">${moneyFromTenK(equity.at(-1).spy)} ending value</text>

    <rect x="1132" y="572" width="104" height="98" rx="16" fill="${colors.panel2}" stroke="${colors.line}"/>
    <text x="1153" y="604" class="kpiLabel">CAGR</text>
    <text x="1153" y="637" class="kpiValue">${unsignedPercent(top10Metrics.cagr)}</text>
    <text x="1153" y="657" class="kpiCompare">SPY ${unsignedPercent(spyMetrics.cagr)}</text>

    <rect x="1248" y="572" width="104" height="98" rx="16" fill="${colors.panel2}" stroke="${colors.line}"/>
    <text x="1269" y="604" class="kpiLabel">MAX DD</text>
    <text x="1269" y="637" class="kpiValue" fill="${colors.red}">${percent(top10Metrics.maxDrawdown)}</text>
    <text x="1269" y="657" class="kpiCompare">SPY ${percent(spyMetrics.maxDrawdown)}</text>

    <rect x="1364" y="572" width="108" height="98" rx="16" fill="${colors.panel2}" stroke="${colors.line}"/>
    <text x="1385" y="604" class="kpiLabel">SHARPE</text>
    <text x="1385" y="637" class="kpiValue">${top10Metrics.sharpe.toFixed(2)}</text>
    <text x="1385" y="657" class="kpiCompare">SPY ${spyMetrics.sharpe.toFixed(2)}</text>

    <rect x="1132" y="686" width="340" height="44" rx="13" fill="#161C25" stroke="#4D3E2F"/>
    <text x="1302" y="713" text-anchor="middle" class="method">TOP 10 · VALUE-WEIGHTED · POST-FILING REBALANCE</text>

    <path d="M104 772H1474" stroke="${colors.line}"/>
    <text x="104" y="795" class="fine">13F may lag 45 days and excludes cash, private assets, shorts and intra-quarter trades. Price returns; dividends, fees, taxes and slippage excluded.</text>
    ${guruConfig.qualityNote ? `<text x="104" y="815" class="fine">QUALITY CONTROL: ${guruConfig.qualityNote}</text>` : ''}
    <text x="104" y="837" class="source">SOURCE: SEC 13F + DAILY CLOSES · RESEARCH ONLY — NOT INVESTMENT ADVICE</text>
    <circle cx="1312" cy="828" r="5" fill="${colors.mint}"/>
    <text x="1326" y="834" class="url">thesisforge.tech</text>
  </svg>
`);

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

await sharp(svg)
  .composite([
    { input: mark, left: 88, top: 70 },
    { input: portrait, left: 1130, top: 181 },
  ])
  .png({ compressionLevel: 9 })
  .toFile(output);

const dataPayload = {
  generatedAt: '2026-08-31',
  source: {
    databasePath,
    cachedBacktestGeneratedAt: sourceRow.generated_at,
    cachedPayloadSha256: sourceHash,
  },
  method: {
    portfolio:
      `At each ${guruConfig.entityName} 13F, select up to ten priced disclosed securities with the largest reported market values and normalize their disclosed values to 100%.`,
    execution:
      'Use the first tradable SPY date on or after the filing date; new weights apply after that close.',
    benchmark: 'SPY',
    returnType: 'Unadjusted daily close price return; dividends excluded for both strategy and benchmark.',
    costs: 'Transaction costs, taxes and slippage excluded.',
    securityTreatment:
      'Distinct share classes remain separate because the SEC information table reports distinct securities.',
    qualityControl:
      guruConfig.qualityNote || 'No additional filing-level exclusions applied.',
    excludedSparseFilings,
  },
  strategy,
  equity: equity.map((point) => [point.date, point.top10, point.spy]),
  rebalances,
};
await writeFile(dataOutput, `${JSON.stringify(dataPayload, null, 2)}\n`);

await writeFile(
  manifestOutput,
  `${JSON.stringify(
    {
      title: guruConfig.manifestTitle,
      generatedAt: '2026-08-31',
      dimensions: { width: 1600, height: 900 },
      output: path.relative(root, output),
      data: path.relative(root, dataOutput),
      copy: path.relative(root, copyOutput),
      assets: Object.fromEntries(
        Object.entries(assets).map(([key, value]) => [key, path.relative(root, value)]),
      ),
      calculations: {
        top10TotalReturn: top10Metrics.totalReturn,
        top10Cagr: top10Metrics.cagr,
        top10MaxDrawdown: top10Metrics.maxDrawdown,
        top10Sharpe: top10Metrics.sharpe,
        spyTotalReturn: spyMetrics.totalReturn,
        spyCagr: spyMetrics.cagr,
        spyMaxDrawdown: spyMetrics.maxDrawdown,
        spySharpe: spyMetrics.sharpe,
        excessCagr: strategy.excessCagr,
        excessTotalReturn: strategy.excessTotalReturn,
        rebalances: rebalances.length,
        averagePriceCoverage: averageCoverage,
      },
      contentRules: [
        'Every plotted point comes from the daily series stored in the companion data file.',
        'The two series use the same linear axis and identical date window.',
        'No Berkshire logo, affiliation or endorsement claim is used.',
        'The title describes the disclosed Top 10 copy strategy, not Berkshire Hathaway or Buffett personal performance.',
      ],
    },
    null,
    2,
  )}\n`,
);

await writeFile(
  copyOutput,
  `# X post copy — ${guruConfig.managerName} Top 10 backtest\n\nEveryone says: “Just copy ${guruConfig.managerPossessive} top 10.” So I tested the version an ordinary investor could actually execute.\n\nEach quarter: wait for ${guruConfig.entityShort}'s 13F, take up to the 10 largest priced disclosed positions, weight them by reported value, and rebalance only after the filing is public.\n\n${startDate} → ${endDate}:\n• Top 10 copy: ${percent(top10Metrics.totalReturn)} total return | ${unsignedPercent(top10Metrics.cagr)} CAGR\n• SPY: ${percent(spyMetrics.totalReturn)} total return | ${unsignedPercent(spyMetrics.cagr)} CAGR\n\n${strategy.excessCagr >= 0 ? `The copy portfolio beat SPY by ${(strategy.excessCagr * 100).toFixed(1)} percentage points a year—but its maximum drawdown was ${unsignedPercent(Math.abs(top10Metrics.maxDrawdown))} versus ${unsignedPercent(Math.abs(spyMetrics.maxDrawdown))} for SPY.` : `The delayed copy portfolio lagged SPY by ${Math.abs(strategy.excessCagr * 100).toFixed(1)} percentage points a year.`}\n\nThat is not ${guruConfig.managerName}'s or ${guruConfig.entityShort}'s actual return. A 13F can arrive 45 days late and omits cash, shorts, hedges, derivatives, private assets and intra-quarter moves.${guruConfig.qualityNote ? ` ${guruConfig.qualityNote}` : ''}\n\nCopy the research process, not just the delayed positions.\n\n$SPY #13F #Investing\n\nPrice-return backtest; dividends, fees, taxes and slippage excluded. Research only, not investment advice.\n`,
);

console.log(
  JSON.stringify(
    {
      output,
      dataOutput,
      manifestOutput,
      copyOutput,
      strategy,
    },
    null,
    2,
  ),
);
