"""Explicit dependencies. Independent sources/review gates are never invented."""
from pathlib import Path
from ..contracts import TABLES
from ..store import checksum
from .contracts import TaskSpec, digest

PROJECT = Path(__file__).resolve().parents[2]


def source_hash(*files):
    return digest({name:checksum(PROJECT/name) for name in files})


def tasks():
    common = source_hash('fact_os/pipeline/builders.py','fact_os/pipeline/checks.py','fact_os/repository.py','fact_os/contracts.py')
    def task(id, required, *, optional=(), code=(), configs=(), method='1', schema='1', kind='derived', policy='automatic_after_checks'):
        return TaskSpec(id=id,kind=kind,implementationVersion=digest([common,source_hash(*code)]),
            methodologyVersion=method,configHashes={p:checksum(PROJECT/p) for p in configs},
            requiredInputs=tuple(required),optionalInputs=tuple(optional),outputSchemaVersion=schema,
            publicationGroup=id,publicationPolicy=policy)
    return (
        task('canonical',TABLES,kind='read_release',schema='canonical-read-v1'),
        task('ai_insights',('tickers','fundamentals'),optional=('actions',),
             code=('fact_os/ai_insights.py','server/aiInsightsMetrics.js','server/investmentAiInsights.js'),
             configs=('server/config/ai-insights-universe.json',),method='ai-insights-v1'),
        task('institutional_13f',('holdings','holdings_ticker','holdings_investor','actions','fundamentals','daily','tickers','sp500'),
             code=('scripts/build-13f-insights.py','scripts/build-13f-active-insights.py','scripts/active_sector_analysis.py',
                   'scripts/package-13f-insights-artifact.mjs'),method='institutional-13f-insights-v5',schema='institutional-13f-artifact-v7'),
        # These are canonical INPUT releases, not automatic publication of
        # models/backtests, and do not mutate saved user scenarios or records.
        task('research_inputs',('tickers','fundamentals','stocks'),optional=('actions','events','descriptions'),kind='read_release'),
        task('public_observations',('tickers','fundamentals','stocks'),
             code=('fact_os/pipeline/observations.py','scripts/import-investment-quality.py'),
             method='annual-quality-v1',schema='canonical-public-observations-v1'),
        task('strategy_inputs',('tickers','stocks','funds','actions','daily'),kind='read_release'),
        task('guru_strict',('tickers','holdings','holdings_investor','stocks','funds','actions','external.sec_accepted_filings','external.guru_reviewed_matrix'),
             kind='review_gate',policy='reviewed_atomic_matrix'),
        task('valuation_candidates',('tickers','fundamentals','stocks','external.reviewed_model_release'),
             kind='review_gate',policy='candidate_only_never_auto_publish'),
    )


def ordered(specs):
    remaining={spec.id:spec for spec in specs}
    if len(remaining)!=len(specs): raise ValueError('duplicate_task_id')
    result=[]
    while remaining:
        ready=[spec for spec in remaining.values() if set(spec.dependsOn)<=set(s.id for s in result)]
        if not ready: raise ValueError('cyclic_or_missing_task_dependency')
        for spec in ready:
            result.append(spec);del remaining[spec.id]
    return result
