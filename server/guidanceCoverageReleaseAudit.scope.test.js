import test from 'node:test';
import assert from 'node:assert/strict';
import { assessGuidanceReleaseEvent } from './guidanceCoverageReleaseAudit.js';

function row(evidence, overrides = {}) {
  return { ticker: 'TEST', source_database: 'downloaded_online_earnings_transcript',
    source_id: 'test-owned-guidance', observed_at: '2026-03-10', fiscal_period: '2026-Q1',
    metric_name: 'revenue_guidance', amount: 6500, currency: 'USD', unit: 'million',
    actual_or_guidance: 'guidance', quality_status: 'clear', guidance_scope: 'quarter',
    guidance_subject: 'company_total', evidence_excerpt: evidence, ...overrides };
}

test('current forecast is not a historical forecast merely because its explanation says as we had expected', () => {
  const target = row('For the fourth quarter, we expect revenues between $6.4 billion and $6.6 billion, reflecting moderation in growth as we had expected.');
  assert.equal(assessGuidanceReleaseEvent(target).usable, true);
  for (const text of [
    'For the fourth quarter, we had expected revenues between $6.4 billion and $6.6 billion.',
    'For the fourth quarter, we previously expected revenues between $6.4 billion and $6.6 billion.',
    'For the quarter, revenues were $6.5 billion and we expect better margins next quarter.',
  ]) assert.equal(assessGuidanceReleaseEvent({ ...target, evidence_excerpt: text }).usable, false, text);
});

test('same free-cash-flow amount qualifier retains its following fiscal period', () => {
  const target = row('Moving on to free cash flow, we expect to generate between $1.4 and $1.5 billion of free cash flow in fiscal 2027.',
    { metric_name: 'free_cash_flow_guidance', amount: 1450, guidance_scope: 'full_year' });
  const a = assessGuidanceReleaseEvent(target);
  assert.equal(a.usable, true, JSON.stringify(a.rejectionReasons));
  assert.equal(assessGuidanceReleaseEvent({ ...target, evidence_excerpt:
    'We generated free cash flow of $1.45 billion. We expect higher revenue in fiscal 2027.' }).usable, false);
});

test('operating-income dollars cannot borrow the following net-income-per-share classification', () => {
  const target = row('For fiscal 2027, operating income is expected to be between $160 million and $180 million, and net income per share is expected to be $0.45 to $0.51.',
    { metric_name: 'operating_income_guidance', amount: 170, guidance_scope: 'full_year' });
  const a = assessGuidanceReleaseEvent(target);
  assert.equal(a.usable, true, JSON.stringify(a.rejectionReasons));
  assert.equal(assessGuidanceReleaseEvent({ ...target, evidence_excerpt:
    'For fiscal 2027, operating income per diluted share is expected to be $160 to $180.' }).usable, false);
});

test('long current main-clause forecast remains forward but historical metric ownership still wins', () => {
  const target = row('Looking forward, we expect continued progress throughout the year as we position the firm for sustainable long-term growth, increased operating leverage, and significant free cash flow generation toward our goal of $2.3 billion or more for the full year 2027.',
    { metric_name: 'free_cash_flow_guidance', amount: 2300, guidance_scope: 'full_year' });
  const a = assessGuidanceReleaseEvent(target);
  assert.equal(a.usable, true, JSON.stringify(a.rejectionReasons));
  assert.equal(assessGuidanceReleaseEvent({ ...target, evidence_excerpt:
    'For fiscal 2027 we expect higher revenue, but free cash flow was $2.3 billion last year.' }).usable, false);
});

test('raising and explicitly maintaining annual targets are forward, while prior targets alone are not', () => {
  for (const [text, amount] of [
    ['We are raising our annual revenue expectations from a range of $7.53 billion-$7.63 billion, to a range of $7.58 billion-$7.67 billion.', 7625],
    ['We have not changed our full-year free cash flow expectations and are maintaining our original guidance range of $450 million-$500 million.', 475],
    ['In terms of full year 2014 free cash flow, we are maintaining our previous guidance of about $2.2 billion.', 2200],
  ]) {
    const result = assessGuidanceReleaseEvent(row(text, { amount, guidance_scope: 'full_year', metric_name: text.includes('free cash flow') ? 'free_cash_flow_guidance' : 'revenue_guidance' }));
    assert.equal(result.usable, true, JSON.stringify(result.rejectionReasons));
  }
  assert.equal(assessGuidanceReleaseEvent(row('Our previous full-year free cash flow guidance was $450 million-$500 million.',
    { amount: 475, guidance_scope: 'full_year', metric_name: 'free_cash_flow_guidance' })).usable, false);
});

test('an original long current guidance introduction scopes its target without blessing historical results', () => {
  const intro = 'With all of this as a backdrop, our guidance for the second quarter, which is based on non-GAAP results and excludes any non-cash stock-based compensation impacts and other non-recurring items, is as follows: ';
  const target = row(intro + 'revenues of approximately $1.35 billion-$1.4 billion, gross margin of approximately 61%.', { amount: 1375 });
  const result = assessGuidanceReleaseEvent(target);
  assert.equal(result.usable, true, JSON.stringify(result.rejectionReasons));
  assert.equal(assessGuidanceReleaseEvent({ ...target, evidence_excerpt: intro.replace('our guidance', 'our historical results') + 'revenues of approximately $1.35 billion-$1.4 billion.' }).usable, false);
});

test('a unique original monetary range owns current guidance rather than an earlier metric heading or actual', () => {
  const text = 'Regarding free cash flow and cash balance, year to date, we had adjusted free cash flow of $803 million, putting us right on track with our guidance for the full year adjusted free cash flow of between $1.4 billion-$1.6 billion, although the timing of free cash flow was earlier in the year than expected.';
  const target = row(text, { amount: 1500, guidance_scope: 'full_year', metric_name: 'free_cash_flow_guidance' });
  const result = assessGuidanceReleaseEvent(target);
  assert.equal(result.usable, true, JSON.stringify(result.rejectionReasons));
  assert.equal(assessGuidanceReleaseEvent({ ...target, amount: 803 }).usable, false);
  const different = 'We generated free cash flow of $803 million. We expect annual revenue between $1.4 billion-$1.6 billion.';
  assert.equal(assessGuidanceReleaseEvent({ ...target, evidence_excerpt: different }).usable, false);
});

test('quarter of a bare year outranks the year-outlook token for target scope', () => {
  const target = row('Now turning to our fourth quarter of 2024 outlook, we expect revenue to be approximately $7.5 billion, plus or minus $300 million, up 22% year-over-year.', { amount: 7500, growth_yoy: 22 });
  const result = assessGuidanceReleaseEvent(target);
  assert.equal(result.usable, true, JSON.stringify(result.rejectionReasons));
  assert.equal(assessGuidanceReleaseEvent({...target,guidance_scope:'full_year'}).usable, false);
});

test('current ranges survive a later old comparator and an incidental as-expected aside', () => {
  for (const [text, metric_name, amount] of [
    ["Adjusted free cash flow continues to trend better than last year, as we expected, and we are again reaffirming, reaffirming our guidance range of $850 million-$950 million for our fiscal 2024 year, which will be up $100 million higher compared with last year.", 'free_cash_flow_guidance', 900],
    ["Finally, we are raising and narrowing our full year adjusted free cash flow guidance to a range of $3.3 billion-$3.7 billion from our previous guidance of $3 billion-$3.5 billion.", 'free_cash_flow_guidance', 3500],
    ["Given the increased outlook for earnings and working capital productivity, we are now targeting to generate over $700 million of free cash flow this year.", 'free_cash_flow_guidance', 700],
    ["We expect full-year revenue growth of just below 10%, which is better than our prior expectation of faster than 7%.", 'revenue_guidance', null],
  ]) {
    const result = assessGuidanceReleaseEvent(row(text, { metric_name, amount, guidance_scope: 'full_year', ...(amount == null ? { growth_yoy: 10 } : {}) }));
    assert.equal(result.usable, true, JSON.stringify({text,reasons:result.rejectionReasons}));
  }
  for (const text of [
    'Our prior full-year free cash flow guidance was $900 million, as we expected.',
    'Free cash flow was $900 million this year, and we are reaffirming our revenue guidance.',
  ]) assert.equal(assessGuidanceReleaseEvent(row(text, { metric_name: 'free_cash_flow_guidance', amount: 900, guidance_scope: 'full_year' })).usable, false);
});
