import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
export const caseDir = path.join(root, 'web/research/isrg');
export const escapeHtml = (value) => String(value).replace(/[&<>"']/g, (c) => ({ '&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#39;' }[c]));
const money = (n) => `$${n.toFixed(2)}`;
const billion = (n) => `$${(n / 1000).toFixed(2)}B`;
const pct = (n) => `${n >= 0 ? '+' : ''}${n.toFixed(1)}%`;
const date = (s) => new Date(`${s}T00:00:00Z`).toLocaleDateString('en-GB', { day:'numeric', month:'short', year:'numeric', timeZone:'UTC' });
const timestamp = (s) => Date.parse(`${s}T00:00:00Z`);

export function chartSvg(data) { return chartVariant(data, false) + chartVariant(data, true); }

function chartVariant(data, compact) {
  const first = data.prices[0].date;
  const last = data.priceDate;
  const start = timestamp(first), end = timestamp(last);
  const history = data.history.filter((p) => timestamp(p.date) <= end);
  const inWindow = history.filter((p) => timestamp(p.date) >= start);
  const prior = history.filter((p) => timestamp(p.date) < start).at(-1);
  const values = [...(prior ? [{ date:first, fairValue:prior.fairValue }] : []), ...inWindow];
  if (!values.length) throw new Error('Public case requires actual modeled history');
  const ceiling = Math.ceil(Math.max(...data.prices.map((p) => p.price), ...values.map((p) => p.fairValue)) / 100) * 100;
  const left = compact ? 48 : 68, right = compact ? 452 : 1014;
  const bottom = compact ? 228 : 278;
  const x = (s) => left + (timestamp(s) - start) / (end - start) * (right - left);
  const y = (n) => bottom - n / ceiling * (compact ? 196 : 242);
  const n = (v) => v.toFixed(2);
  const pricePath = data.prices.map((p, i) => `${i ? 'L' : 'M'}${n(x(p.date))},${n(y(p.price))}`).join(' ');
  // Fair values change at actual model nodes, not along a smoothed spline.
  const valuePath = values.map((p, i) => i ? `H${n(x(p.date))}V${n(y(p.fairValue))}` : `M${n(x(p.date))},${n(y(p.fairValue))}`).join(' ') + ` H${n(x(last))}`;
  const grids = Array.from({ length:5 }, (_, i) => {
    const value = ceiling / 4 * i;
    return `<line class="grid" x1="${left}" x2="${right}" y1="${n(y(value))}" y2="${n(y(value))}"/><text x="${left - 12}" y="${n(y(value) + 4)}" text-anchor="end">$${value}</text>`;
  }).join('');
  const yearTicks = [];
  for (let yr = new Date(start).getUTCFullYear() + 1; yr <= new Date(end).getUTCFullYear(); yr++) {
    const d = `${yr}-01-01`;
    if (!compact || yr % 2 === 0) yearTicks.push(`<text x="${n(x(d))}" y="${bottom + 27}" text-anchor="middle">${yr}</text>`);
  }
  const id = compact ? 'mobile' : 'desktop';
  return `<svg class="chart chart-${id}" viewBox="0 0 ${compact ? '480 275' : '1080 330'}" role="img" aria-labelledby="chart-title-${id} chart-desc-${id}" xmlns="http://www.w3.org/2000/svg"><title id="chart-title-${id}">ISRG market price and point-in-time model fair value</title><desc id="chart-desc-${id}">${escapeHtml(date(first))} to ${escapeHtml(date(last))}. USD per share, zero-based vertical axis. Actual sampled market observations are connected in gold; model estimates change at reporting nodes in green. Latest model fair value ${money(data.fairValue)}, comparison price ${money(data.price)}. Historical fair values are retrospective point-in-time-input calculations using a constant model version, not archived forecasts. Exact observations are in the data table below.</desc>${grids}${yearTicks.join('')}<path class="price-line" d="${pricePath}"/><path class="value-line" d="${valuePath}"/>${inWindow.map((p) => `<circle class="event-point" cx="${n(x(p.date))}" cy="${n(y(p.fairValue))}" r="${compact ? 2.5 : 3.5}"><title>${escapeHtml(date(p.date))}: model ${money(p.fairValue)}</title></circle>`).join('')}<circle cx="${n(x(last))}" cy="${n(y(data.price))}" r="4" fill="#e4bc70"/><circle cx="${n(x(last))}" cy="${n(y(data.fairValue))}" r="4" fill="#62d5b0"/></svg>`;
}

export function renderCase(d) {
  const a = d.assumptions, p = d.previous, s = d.scenario;
  const gap = (d.fairValue / d.price - 1) * 100;
  const terminal = '/?view=valuation&amp;valuation=ISRG&amp;lang=en&amp;ref=isrg-public-case';
  const canonical = 'https://www.thesisforge.tech/research/isrg/';
  const modelChange = (d.fairValue / p.fairValue - 1) * 100;
  const rows = [
    ['Forward revenue', billion(p.forwardRevenueM), billion(a.forwardRevenueM), pct((a.forwardRevenueM / p.forwardRevenueM - 1) * 100)],
    ['Forward model FCF', billion(p.forwardFcfM), billion(a.forwardFcfM), pct((a.forwardFcfM / p.forwardFcfM - 1) * 100)],
    ['Blended fair value / share', money(p.fairValue), money(d.fairValue), pct(modelChange)],
  ];
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>ISRG: price vs. value | ThesisForge</title>
<meta name="description" content="An open ISRG research case: ${money(d.price)} market price vs ${money(d.fairValue)} modeled fair value. Explore the dated curve, assumptions and a downside scenario. No sign-in.">
<link rel="canonical" href="${canonical}"><meta name="robots" content="index,follow">
<meta property="og:type" content="article"><meta property="og:site_name" content="ThesisForge"><meta property="og:locale" content="en_US"><meta property="og:title" content="ISRG: price vs. value"><meta property="og:description" content="The price fell. The model moved up. Inspect the assumptions—and what could break the thesis. Dated research, not a live quote."><meta property="og:url" content="${canonical}"><meta property="og:image" content="${canonical}social.jpg"><meta property="og:image:alt" content="ISRG dated valuation case with market price, blended fair value and historical curve">
<meta name="twitter:card" content="summary_large_image"><meta name="twitter:site" content="@thesisforger"><meta name="twitter:title" content="ISRG: price vs. value"><meta name="twitter:description" content="A dated valuation case. One chart. Three assumptions. One way the thesis could fail. No sign-in."><meta name="twitter:image" content="${canonical}social.jpg">
<link rel="icon" type="image/png" sizes="64x64" href="/brand/thesisforge-black-mark-64.png?v=20261119"><link rel="shortcut icon" href="/favicon.ico?v=20261119"><link rel="stylesheet" href="/research/isrg/case.css?v=20260905-1">
</head><body>
<a class="skip" href="#main">Skip to research</a><div class="wrap">
<header class="header"><a class="brand" href="/research/isrg/" aria-label="ThesisForge public research"><img src="/brand/thesisforge-black-mark-192.png?v=20261119" width="34" height="34" alt=""><span>ThesisForge<small>EVIDENCE BEFORE NARRATIVE.</small></span></a><nav aria-label="Main"><a class="about-link" href="#methodology">How this works</a><a class="terminal-link" href="${terminal}">Open terminal <span aria-hidden="true">&nbsp;↗</span></a></nav></header>
<main id="main"><section class="hero" aria-labelledby="headline"><div class="eyebrow">ISRG · Intuitive Surgical <span>Open research / 01</span></div><div class="hero-row"><h1 id="headline">Price fell.<br><em>What about value?</em></h1><p class="hero-copy">A lower share price is only interesting if the business still holds up. In this dated case, the ISRG model moved <strong>${pct(modelChange)}</strong>. Here is what changed, what we assume, and where we could be wrong.</p></div><div class="date-line"><span>Dated case · not a live quote</span><span>Model: <time datetime="${d.asOfDate}">${date(d.asOfDate)}</time></span><span>Market close: <time datetime="${d.priceDate}">${date(d.priceDate)}</time></span></div></section>
<section class="chart-panel" aria-label="Valuation snapshot"><div class="metrics"><div class="metric"><span class="metric-label">Market price</span><strong class="metric-value">${money(d.price)}</strong><small>${date(d.priceDate)} close · USD</small></div><div class="metric"><span class="metric-label">Model fair value</span><strong class="metric-value mint">${money(d.fairValue)}</strong><small>Blended estimate, not pure DCF</small></div><div class="metric"><span class="metric-label">Model gap to price</span><strong class="metric-value mint">${pct(gap)}</strong><small>Not an expected return</small></div></div><div class="chart-head"><h2>When price and model value diverge</h2><div class="legend"><span><i></i>Model fair value</span><span class="price"><i></i>Market price</span></div></div>${chartSvg(d)}<div class="chart-foot"><p>Historical model replay using information available at each reporting node—not a record of forecasts published at the time. Price observations are sampled; connecting lines are not extra daily quotes.</p><a href="#observations">Inspect chart data ↓</a></div></section>
<p class="chart-note"><strong>The question is not “will it return to its high?”</strong> It is whether the earnings and cash-flow assumptions still deserve this valuation.</p>
<nav class="reading-nav" aria-label="Research sections"><a href="#assumptions">01 &nbsp; The assumptions</a><a href="#changes">02 &nbsp; What changed</a><a href="#downside">03 &nbsp; What could go wrong</a><a class="primary-link" href="#methodology">Check the method ↓</a></nav>
<section class="section" id="assumptions"><div class="section-heading"><div><span class="index">01 / UNDER THE HOOD</span><h2>Three assumptions to challenge.</h2></div><p>These are model choices, not company promises.</p></div><div class="assumptions"><article class="assumption"><span class="number">EARNINGS</span><h3>Normalized earnings multiple</h3><div class="big">${a.targetPE.toFixed(1)}×</div><p>The earnings component has a 66% weight. This premium multiple needs durable growth; it is not a bargain multiple.</p></article><article class="assumption"><span class="number">GROWTH</span><h3>Normalized growth input</h3><div class="big">${a.normalizedGrowthPct.toFixed(1)}%</div><p>A point-in-time financial-trend input. The DCF forecast fades growth over five years; it does not assume this rate forever.</p></article><article class="assumption"><span class="number">RISK</span><h3>Cost of equity</h3><div class="big">${(a.costOfEquity * 100).toFixed(1)}%</div><p>The FCFE DCF has a 34% weight and a ${(a.terminalGrowth * 100).toFixed(2)}% terminal growth assumption. A higher required return lowers its value.</p></article></div><p class="method-note">The ${money(d.fairValue)} estimate combines normalized earnings and FCFE DCF. The standalone DCF is ${money(d.standaloneDcf)} per share. Share price is a comparison, not an input to model fair value.</p></section>
<section class="section" id="changes"><div class="section-heading"><div><span class="index">02 / THE UPDATE</span><h2>The estimate rose. Here is why.</h2></div></div><div class="change-layout"><div class="body-copy"><p>Between the <strong>${date(p.asOfDate)}</strong> and <strong>${date(d.asOfDate)}</strong> model nodes, forward revenue and modeled free cash flow increased. The blended estimate rose from <strong>${money(p.fairValue)} to ${money(d.fairValue)}</strong>.</p><p>These are model-forward inputs—not a claim that management issued equivalent full-year guidance. The figures compare two reporting nodes under the same valuation method.</p><p>The ${money(d.change.fairValue)} increase breaks into <strong>+${money(d.change.earningsContribution)}</strong> from the weighted earnings component and <strong>+${money(d.change.dcfContribution)}</strong> from DCF. Growth and the discount rate stayed unchanged; margins, shares and the target multiple also moved.</p></div><div><div class="table-wrap"><table class="change-table"><caption class="sr-only">Latest two reporting-node comparison</caption><thead><tr><th scope="col">Model input / output</th><th scope="col">${date(p.asOfDate)}</th><th scope="col">${date(d.asOfDate)}</th><th scope="col">Change</th></tr></thead><tbody>${rows.map((r) => `<tr>${r.map((v, i) => `<${i ? 'td' : 'th'}${i ? '' : ' scope="row"'}>${v}</${i ? 'td' : 'th'}>`).join('')}</tr>`).join('')}</tbody></table></div><p class="table-note">Changes are comparisons, not additive attribution. The two component contributions reconcile to the total increase.</p></div></div></section>
<section class="section" id="downside"><div class="section-heading"><div><span class="index">03 / THE COUNTERCASE</span><h2>What if the premium is not earned?</h2></div></div><div class="bear"><div><h3>Growth disappoints. Investors pay less.</h3><p>Illustrative stress test: normalized earnings and the entire projected FCFE stream fall 15%, and the earnings multiple compresses from ${a.targetPE.toFixed(1)}× to ${s.targetPE.toFixed(0)}×. Keep the same weights, discount rate, terminal growth and share count. This is a scenario—not a probability-weighted forecast.</p></div><div class="bear-metric"><span>Stressed blended value / share</span><strong>${money(s.fairValue)}</strong><small>${pct((s.fairValue / d.price - 1) * 100)} vs the dated price</small></div></div><p class="risk-note">A price below the base estimate is not automatically a buy signal. The apparent gap can disappear if earnings quality, growth or the premium multiple fails to hold.</p></section>
<section class="section" id="methodology"><div class="section-heading"><div><span class="index">REPRODUCIBLE, NOT A BLACK BOX</span><h2>Check the work.</h2></div><p>No account needed to inspect this case.</p></div><details><summary>Valuation formula, inputs and limitations</summary><div class="method"><p><strong>Base estimate:</strong> ${d.components.map((c) => `${(c.weight * 100).toFixed(0)}% × ${escapeHtml(c.label)} ${money(c.value)}`).join(' + ')} = ${money(d.fairValue)} per share.</p><ul><li>Forward revenue ${billion(a.forwardRevenueM)}; normalized net margin ${a.effectiveNetMarginPct.toFixed(2)}%; quoted-security shares ${a.sharesM.toFixed(3)} million.</li><li>Earnings value = forward revenue × normalized net margin ÷ shares × ${a.targetPE.toFixed(4)}.</li><li>Forward model FCFE ${billion(a.forwardFcfM)}. Discount explicit year-end flows and the terminal value at the cost of equity. No separate dividend or buyback value is added.</li><li>Model version: <code>${escapeHtml(d.modelVersion)}</code>.</li><li>The historical green line is a constant-method replay on point-in-time inputs. It must not be interpreted as a published contemporaneous forecast or a backtest of trading returns.</li><li>This public page is a fixed, reviewed snapshot, not a live feed. A new filing, new price or a methodology revision requires a separately checked update.</li></ul><p><a href="/research/isrg/snapshot.json">Read the curated model inputs and component-change bridge (JSON)</a></p><p>Sources: ${d.sources.map((src) => `<a href="${escapeHtml(new URL(src.url, canonical).href)}" rel="noopener noreferrer">${escapeHtml(src.title)}</a>`).join(' · ')}.</p></div></details><details id="observations"><summary>Chart observations and dates</summary><div class="method"><p>Green estimates are shown as steps at real model nodes. The last estimate is carried visually through the price date; no new model run is implied. Price points are exact sampled stored observations, not interpolated prices.</p><div class="data-audit table-wrap"><table><caption>Point-in-time model nodes · USD per share</caption><thead><tr><th scope="col">Model date</th><th scope="col">Model fair value</th><th scope="col">Dated comparison price</th></tr></thead><tbody>${d.history.map((v) => `<tr><td>${escapeHtml(v.date)}</td><td>${money(v.fairValue)}</td><td>${Number.isFinite(v.price) ? money(v.price) : 'Not available'}</td></tr>`).join('')}</tbody></table></div><p><a href="/research/isrg/snapshot.json">All displayed price observations and source provenance (JSON)</a></p></div></details></section>
<section class="cta"><div><h2>Go beyond the headline.</h2><p>Open ISRG in the full valuation terminal to continue your research.</p></div><div class="cta-action"><a class="button" href="${terminal}">Continue with ISRG <span aria-hidden="true">↗</span></a><small>Sign-in is required for the terminal, not this page.</small></div></section></main>
<footer class="footer"><a class="brand" href="/research/isrg/"><img src="/brand/thesisforge-black-mark-192.png?v=20261119" alt="" width="25" height="25">ThesisForge</a><p>Independent research; not affiliated with or endorsed by Intuitive Surgical. Estimates are uncertain and may be wrong. This is a dated research example, not personalized investment advice or a promised return. Market and model dates are stated above. <a href="https://x.com/thesisforger">Follow @thesisforger</a>.</p></footer></div></body></html>\n`;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const data = JSON.parse(fs.readFileSync(path.join(caseDir, 'snapshot.json'), 'utf8'));
  const output = path.join(caseDir, 'index.html');
  const html = renderCase(data);
  if (process.argv.includes('--check')) {
    if (!fs.existsSync(output) || fs.readFileSync(output, 'utf8') !== html) throw new Error('Public case HTML is stale. Run npm run build:research.');
    console.log('Public ISRG page matches its reviewed snapshot.');
  } else {
    fs.writeFileSync(output, html);
    console.log(`Built public ISRG case from ${data.modelVersion}; model ${data.asOfDate}, price ${data.priceDate}.`);
  }
}
