import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import express from 'express';
import { fileURLToPath } from 'node:url';

const projectRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const releaseRoot = process.env.THESISFORGE_LOCAL_RELEASE_ROOT
  || path.join(projectRoot, 'data/releases/thesisforge-20260920-v3');
const researchDb = path.join(releaseRoot, 'research.sqlite');
const compositionDb = path.join(releaseRoot, 'composition.sqlite');
const insightsDb = path.join(releaseRoot, '13f-insights-20260922-v12/13f-insights.sqlite');
const factOsCatalog = path.join(projectRoot, 'data/fact_os/manifests/catalog.json');

const hasLocalRelease = [researchDb, compositionDb, insightsDb, factOsCatalog]
  .every(file => fs.existsSync(file));

test(
  'all checklist backend components satisfy functional contracts and cold/warm latency SLAs',
  { skip: !hasLocalRelease && 'Local Sharadar/Fact OS release artifacts not present' },
  async () => {
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'tf-checklist-perf-'));
    const savedEnv = { ...process.env };
    let server = null;
    let service = null;
    try {
      process.env.INVESTMENT_WORKFLOW_ENABLED = 'true';
      process.env.API_AUTH_DEV_BYPASS = 'true';
      process.env.SQLITE_DB_PATH = researchDb;
      process.env.INVESTMENT_SOURCE_DB_PATH = researchDb;
      delete process.env.STRATEGY_DATA_DB_PATH;
      process.env.STRATEGY_COMPOSITION_PRICE_DB_PATH = compositionDb;
      process.env.INVESTMENT_13F_INSIGHTS_DB_PATH = insightsDb;
      process.env.INVESTMENT_DB_PATH = path.join(tmpDir, 'investment.sqlite');
      process.env.FACT_OS_ROOT = path.join(projectRoot, 'data/fact_os');

      const { enableInvestmentPreview } = await import('./investmentRoutes.js');
      const { publicAnalysisArtifacts } = await import('./publicAnalysisArtifact.js');
      const app = express();
      app.use(express.json());
      app.use((req, _res, next) => {
        req.user = { id: 'checklist-verified-user' };
        req.auth = { user: { id: 'checklist-verified-user' } };
        next();
      });
      service = enableInvestmentPreview(app);
      server = await new Promise(resolve => {
        const listener = app.listen(0, '127.0.0.1', () => resolve(listener));
      });
      const base = `http://127.0.0.1:${server.address().port}/api/investment`;
      const asOf = service.date();

      // Allow server startup setImmediate warm-up & public artifacts to settle as before AWS EB health check Ready.
      await publicAnalysisArtifacts.warmCurrent(asOf).catch(() => {});
      await new Promise(resolve => setTimeout(resolve, 2500));

      const specs = [
        // Group A: Company Search
        { id: 'C02_Search_Default', method: 'GET', path: `/companies?asOf=${asOf}&search=&limit=120`, maxColdMs: 500, maxWarmMs: 25, check: j => j.companies?.length === 120 },
        { id: 'C03_Search_Exact_NVDA', method: 'GET', path: `/companies?asOf=${asOf}&search=nvda&limit=120`, maxColdMs: 50, maxWarmMs: 20, check: j => j.companies?.[0]?.ticker === 'NVDA' },
        { id: 'C04_Search_MultiWord', method: 'GET', path: `/companies?asOf=${asOf}&search=nvidia+corp&limit=120`, maxColdMs: 50, maxWarmMs: 20, check: j => j.companies?.[0]?.ticker === 'NVDA' },

        // Group B: Home & Watchlist
        { id: 'C06_Home_Workspace', method: 'GET', path: `/home?asOf=${asOf}`, maxColdMs: 500, maxWarmMs: 80, check: j => Array.isArray(j.discovery) && j.asOf === asOf },
        { id: 'C07_Watch_Add_NVDA', method: 'POST', path: '/watches', body: { ticker: 'NVDA', asOf, origin: 'holdings', operationId: 'checklist_watch_add_001' }, maxColdMs: 450, maxWarmMs: 50, check: j => j.ticker === 'NVDA' },
        { id: 'C08_Home_With_Active_Watch', method: 'GET', path: `/home?asOf=${asOf}`, maxColdMs: 150, maxWarmMs: 80, check: j => j.watches?.some(w => w.ticker === 'NVDA') },

        // Group C: Discover / Guru / 13F / Fundamentals / Opportunities
        { id: 'C09_Discover_Overview', method: 'GET', path: `/discover?asOf=${asOf}`, maxColdMs: 120, maxWarmMs: 25, check: j => Array.isArray(j.gurus) && j.gurus.length > 0 },
        { id: 'C10_GuruHoldings_Matrix', method: 'GET', path: `/guru-holdings?asOf=${asOf}`, maxColdMs: 150, maxWarmMs: 40, check: j => Array.isArray(j.rows) && j.rows.length > 0 },
        { id: 'C11_GuruDetail_Dossier', method: 'GET', path: `/gurus/baillie-gifford?asOf=${asOf}`, maxColdMs: 400, maxWarmMs: 60, check: j => j.guru?.id === 'baillie-gifford' },
        { id: 'C12_GuruStudy_5Y', method: 'GET', path: `/guru-study?asOf=${asOf}&period=common`, maxColdMs: 200, maxWarmMs: 20, check: j => j.version === 'guru-study-v1' && Array.isArray(j.rows) },
        { id: 'C13_13FInsights_Market', method: 'GET', path: `/13f-insights?asOf=${asOf}&limit=40`, maxColdMs: 150, maxWarmMs: 25, check: j => Array.isArray(j.rows) && j.rows.length > 0 },
        { id: 'C14_13FInsights_Ticker', method: 'GET', path: `/13f-insights/NVDA?asOf=${asOf}`, maxColdMs: 120, maxWarmMs: 25, check: j => j.ticker === 'NVDA' },
        { id: 'C15_13FSector_Detail', method: 'GET', path: `/13f-sectors/Technology?asOf=${asOf}`, maxColdMs: 120, maxWarmMs: 25, check: j => Boolean(j.sector) },
        { id: 'C16_Opportunities_List', method: 'GET', path: `/opportunities?asOf=${asOf}`, maxColdMs: 200, maxWarmMs: 80, check: j => Array.isArray(j.rows) },
        { id: 'C17_Opportunities_Ticker', method: 'GET', path: `/opportunities/AMZN?asOf=${asOf}`, maxColdMs: 500, maxWarmMs: 30, check: j => j.ticker === 'AMZN' && Array.isArray(j.events) },
        { id: 'C18a_Fundamentals_Universe', method: 'GET', path: `/fundamentals?asOf=${asOf}&limit=40`, maxColdMs: 200, maxWarmMs: 80, check: j => Array.isArray(j.rows) },
        { id: 'C18b_Fundamentals_Ticker', method: 'GET', path: `/fundamentals/AMZN?asOf=${asOf}`, maxColdMs: 500, maxWarmMs: 25, check: j => j.ticker === 'AMZN' && Array.isArray(j.sections) },
        { id: 'C18c_Fundamentals_Gurus', method: 'GET', path: `/fundamentals/NVDA/gurus?asOf=${asOf}`, maxColdMs: 120, maxWarmMs: 25, check: j => j.ticker === 'NVDA' && Array.isArray(j.managers) },

        // Group D: AI Sector Insights (Revenue / Operating Income / FCF + Rankings + Compare + Company)
        { id: 'C19_AiInsights_Revenue', method: 'GET', path: `/ai-insights?asOf=${asOf}&metric=revenue`, maxColdMs: 150, maxWarmMs: 50, check: j => Boolean(j.sectorMatrix || j.sectors || j.quarters) },
        { id: 'C20_AiInsights_OpIncome', method: 'GET', path: `/ai-insights?asOf=${asOf}&metric=operating_income`, maxColdMs: 150, maxWarmMs: 50, check: j => Boolean(j.sectorMatrix || j.sectors || j.quarters) },
        { id: 'C21_AiInsights_FCF', method: 'GET', path: `/ai-insights?asOf=${asOf}&metric=fcf`, maxColdMs: 150, maxWarmMs: 50, check: j => Boolean(j.sectorMatrix || j.sectors || j.quarters) },
        { id: 'C22_AiInsights_Rankings', method: 'GET', path: `/ai-insights/rankings?asOf=${asOf}&metric=revenue`, maxColdMs: 80, maxWarmMs: 35, check: j => Array.isArray(j.rows) || Boolean(j.rankings) },
        { id: 'C23_AiInsights_Compare', method: 'GET', path: `/ai-insights/compare?asOf=${asOf}&tickers=NVDA,AVGO,AMD`, maxColdMs: 80, maxWarmMs: 35, check: j => Boolean(j) },
        { id: 'C24_AiInsights_Company', method: 'GET', path: `/ai-insights/companies/NVDA?asOf=${asOf}`, maxColdMs: 80, maxWarmMs: 35, check: j => j.ticker === 'NVDA' || j.company?.ticker === 'NVDA' },

        // Group E: Research Workbench, 3-Statements, Earnings Q&A, Insiders, Institutions, DCF & Notebook
        { id: 'C25_Research_Overview_MSFT', method: 'GET', path: `/research/MSFT?asOf=${asOf}`, maxColdMs: 550, maxWarmMs: 30, check: j => j.ticker === 'MSFT' && Array.isArray(j.priceHistory) },
        { id: 'C26_Research_3Statements_MSFT', method: 'GET', path: `/research/MSFT/fundamentals?asOf=${asOf}`, maxColdMs: 450, maxWarmMs: 25, check: j => j.ticker === 'MSFT' && j.quarterly?.length > 0 && j.annual?.length > 0 },
        { id: 'C27_Research_3Statements_AAPL', method: 'GET', path: `/research/AAPL/fundamentals?asOf=${asOf}`, maxColdMs: 450, maxWarmMs: 25, check: j => j.ticker === 'AAPL' && j.quarterly?.length > 0 && j.annual?.length > 0 },
        { id: 'C27b_Research_Dividends_AAPL', method: 'GET', path: `/research/AAPL/dividends?asOf=${asOf}`, maxColdMs: 550, maxWarmMs: 25, check: j => j.ticker === 'AAPL' && j.status === 'paying' && j.yieldHistory?.length > 100 && j.events?.length > 20 },
        { id: 'C27c_Research_Dividends_SCHD', method: 'GET', path: `/research/SCHD/dividends?asOf=${asOf}`, maxColdMs: 550, maxWarmMs: 25, check: j => j.ticker === 'SCHD' && j.status === 'paying' && j.summary?.safetyLevel === 'fund_distribution' },
        { id: 'C28_Research_Documents_NVDA', method: 'GET', path: `/research/NVDA/documents?asOf=${asOf}`, maxColdMs: 60, maxWarmMs: 20, check: j => j.ticker === 'NVDA' && Array.isArray(j.rows) },
        { id: 'C29_Research_EarningsQA_NVDA', method: 'GET', path: `/research/NVDA/earnings?asOf=${asOf}`, maxColdMs: 120, maxWarmMs: 40, check: j => j.ticker === 'NVDA' && Array.isArray(j.periods) },
        { id: 'C30_Research_Insiders_NVDA', method: 'GET', path: `/research/NVDA/insiders?asOf=${asOf}`, maxColdMs: 180, maxWarmMs: 20, check: j => j.ticker === 'NVDA' && Array.isArray(j.rows) },
        { id: 'C31_Research_Institutions_NVDA', method: 'GET', path: `/research/NVDA/institutions?asOf=${asOf}`, maxColdMs: 80, maxWarmMs: 20, check: j => j.ticker === 'NVDA' },
        { id: 'C32_Research_PublishedModel_NVDA', method: 'GET', path: `/research/NVDA/published-model?asOf=${asOf}`, maxColdMs: 40, maxWarmMs: 15, check: j => j.ticker === 'NVDA' && j.status === 'available' },
        { id: 'C36a_Research_Record_Save', method: 'POST', path: '/research-records', body: { ticker: 'NVDA', asOf, question: 'Can Blackwell sustain 74% ±50 bps gross margin?', supportingEvidence: 'Supply-constrained backlog', status: 'open', operationId: 'checklist_rec_001' }, maxColdMs: 60, maxWarmMs: 25, check: j => j.ticker === 'NVDA' },
        { id: 'C36b_Research_Records_List', method: 'GET', path: `/research/NVDA/records?asOf=${asOf}`, maxColdMs: 40, maxWarmMs: 15, check: j => j.rows?.length === 1 },

        // Group F: Portfolio Workspace
        { id: 'C37_Portfolio_Workspace', method: 'GET', path: `/portfolio?asOf=${asOf}`, maxColdMs: 80, maxWarmMs: 20, check: j => j.asOf === asOf && Array.isArray(j.positions) },

        // Group G: Quantitative Strategy Dashboards & Custom Strategy Lab
        { id: 'C41a_Strategy_InvestorStyles_Summary', method: 'GET', path: `/investor-styles?asOf=${asOf}&summaryOnly=1`, maxColdMs: 250, maxWarmMs: 15, check: j => Boolean(j.snapshotId || j.backtest) },
        { id: 'C41b_Strategy_InvestorStyles_Full', method: 'GET', path: `/investor-styles?asOf=${asOf}`, maxColdMs: 350, maxWarmMs: 80, check: j => Array.isArray(j.backtest?.curve) },
        { id: 'C42_Strategy_BreakoutPullback', method: 'GET', path: `/breakout-pullback?asOf=${asOf}`, maxColdMs: 250, maxWarmMs: 30, check: j => Boolean(j.summary || j.curve || j.backtest) },
        { id: 'C43_Strategy_QqqSchdRotation', method: 'GET', path: `/qqq-schd-rotation?asOf=${asOf}`, maxColdMs: 150, maxWarmMs: 35, check: j => Boolean(j.liveRadar) },
        { id: 'C44_Strategy_CustomLab_Catalog', method: 'GET', path: `/strategy-lab?asOf=${asOf}`, maxColdMs: 60, maxWarmMs: 20, check: j => j.version === 'strategy-lab-catalog-v1' && Array.isArray(j.managers) },
      ];

      // Also fetch MSFT research template so we can test C33_Calculate_DCF!
      const msftOverview = await (await fetch(`${base}/research/MSFT?asOf=${asOf}`)).json();
      if (msftOverview?.templates?.Base) {
        specs.push({
          id: 'C33_Research_Calculate_DCF',
          method: 'POST',
          path: '/calculate',
          body: {
            ticker: 'MSFT',
            asOf,
            snapshotId: msftOverview.snapshot.id,
            assumptions: msftOverview.templates.Base,
          },
          maxColdMs: 80,
          maxWarmMs: 20,
          check: j => Number.isFinite(j.result?.fairValue) && j.result.fairValue > 0 && j.reverse != null,
        });
      }

      const report = [];
      const violations = [];
      for (const spec of specs) {
        const init = spec.body
          ? { method: spec.method, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(spec.body) }
          : { method: spec.method };

        const t0 = performance.now();
        const res1 = await fetch(base + spec.path, init);
        const text1 = await res1.text();
        const coldMs = +(performance.now() - t0).toFixed(1);
        if (res1.status !== 200) {
          violations.push(`${spec.id} cold HTTP ${res1.status}: ${text1.slice(0, 120)}`);
        } else {
          const json1 = JSON.parse(text1);
          if (!spec.check(json1)) violations.push(`${spec.id} cold payload contract failed`);
        }

        const t1 = performance.now();
        const res2 = await fetch(base + spec.path, init);
        const text2 = await res2.text();
        const warmMs = +(performance.now() - t1).toFixed(1);
        if (res2.status !== 200) {
          violations.push(`${spec.id} warm HTTP ${res2.status}`);
        } else if (!spec.check(JSON.parse(text2))) {
          violations.push(`${spec.id} warm payload contract failed`);
        }

        if (coldMs > spec.maxColdMs) {
          violations.push(`${spec.id} coldMs ${coldMs}ms > SLA ${spec.maxColdMs}ms`);
        }
        if (warmMs > spec.maxWarmMs) {
          violations.push(`${spec.id} warmMs ${warmMs}ms > SLA ${spec.maxWarmMs}ms`);
        }

        report.push({
          id: spec.id,
          coldMs,
          maxColdMs: spec.maxColdMs,
          warmMs,
          maxWarmMs: spec.maxWarmMs,
          kb: +(Buffer.byteLength(text1) / 1024).toFixed(1),
          pass: coldMs <= spec.maxColdMs && warmMs <= spec.maxWarmMs && res1.status === 200 && res2.status === 200,
        });
      }

      console.table(report);
      assert.deepEqual(violations, []);
    } finally {
      if (server) server.close();
      try { service?.source?.close(); } catch {}
      try { service?.store?.close(); } catch {}
      fs.rmSync(tmpDir, { recursive: true, force: true });
      for (const key of Object.keys(process.env)) {
        if (!(key in savedEnv)) delete process.env[key];
      }
      Object.assign(process.env, savedEnv);
    }
  },
);
