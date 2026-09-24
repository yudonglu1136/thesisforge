"""Read-only, fixed-clock feature panel; current-vintage reconstruction, not archival PIT.

No investor rule, ranking threshold or forward-price eligibility filter is applied.
Detailed derived files stay in bounded temporary storage; no canonical writes.
"""
import argparse, bisect, calendar, datetime as dt, hashlib, json, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--fact-root', type=Path, default=ROOT / 'data/fact_os')
args = parser.parse_args()
OUT = args.output.resolve()
OUT.mkdir(parents=True, exist_ok=True)
sys.path.insert(0, str(ROOT))
from fact_os.repository import FactRepository

def say(x): print(dt.datetime.now().isoformat(), x, flush=True)
def month(d, n):
    y = d.year + (d.month - 1 + n) // 12
    m = (d.month - 1 + n) % 12 + 1
    return dt.date(y, m, min(d.day, calendar.monthrange(y, m)[1]))
def export(c, sql, name):
    tmp = OUT / (name + '.staged')
    c.execute("COPY (" + sql + ") TO ? (HEADER, DELIMITER ',')", [str(tmp)])
    tmp.replace(OUT / name)
def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''): h.update(chunk)
    return h.hexdigest()
def rows(c, sql):
    r = c.execute(sql)
    return [dict(zip([x[0] for x in r.description], row)) for row in r.fetchall()]

with FactRepository(args.fact_root) as repo:
    c = repo.db
    c.execute("SET memory_limit='1500MB'")
    c.execute("SET max_temp_directory_size='1200MB'")
    c.execute("SET preserve_insertion_order=false")
    c.execute("SET threads=1")
    say('pinned ' + repo.generation)
    spy = c.execute("SELECT date,closeadj FROM funds WHERE ticker='SPY' AND closeadj>0 ORDER BY date").fetchall()
    sessions = [r[0] for r in spy]; spyprice = dict(spy); cutoff = sessions[-1]
    def before(d):
        i = bisect.bisect_right(sessions, d) - 1
        return sessions[i] if i >= 0 and (d-sessions[i]).days <= 7 else None
    def after(d):
        i = bisect.bisect_right(sessions, d)
        return sessions[i] if i < len(sessions) and (sessions[i]-d).days <= 7 else None
    schedule = []
    for year in range(2012, 2027):
        for m in [3, 6, 9, 12]:
            q = dt.date(year, m, calendar.monthrange(year, m)[1])
            if q < dt.date(2012, 12, 31) or q > cutoff: continue
            signal = before(q); entry = after(q)
            if not entry: continue
            nextq = month(q, 3); nextq = nextq.replace(day=calendar.monthrange(nextq.year,nextq.month)[1])
            exitdate = after(nextq)
            schedule.append((q, signal, signal, entry, exitdate, before(month(signal,-6)), before(month(signal,-12)), before(month(signal,-1))))
    datecols = ['q','signal_date','info_date','entry','next_entry','pre6','pre12','pre1']
    c.execute('CREATE TEMP TABLE dates(' + ','.join(x+' DATE' for x in datecols) + ')')
    c.executemany('INSERT INTO dates VALUES (' + ','.join('?' for _ in datecols) + ')', schedule)
    # Current security-master classification is explicit, not asserted historical.
    c.execute('''CREATE TEMP TABLE master AS SELECT ticker,any_value(permaticker) permaticker,
      arg_max(category,lastupdated) category,arg_max(sector,lastupdated) sector,
      arg_max(industry,lastupdated) industry,arg_max(exchange,lastupdated) exchange,
      arg_max(isdelisted,lastupdated) isdelisted,arg_max(currency,lastupdated) master_currency
      FROM tickers WHERE "table"='SF1' GROUP BY ticker HAVING count(DISTINCT permaticker)=1''')
    c.execute('''CREATE TEMP TABLE caps AS SELECT d.q,dy.ticker,dy.date cap_date,
      dy.marketcap cap_m,dy.pe,dy.pb,dy.ps,dy.evebitda,dy.ev
      FROM dates d JOIN daily dy ON dy.date<=d.signal_date AND dy.date>=d.signal_date-INTERVAL 7 DAY
      QUALIFY row_number() OVER(PARTITION BY d.q,dy.ticker ORDER BY dy.date DESC)=1''')
    c.execute('''CREATE TEMP TABLE grid AS SELECT cp.*,m.* EXCLUDE(ticker)
      FROM caps cp JOIN master m USING(ticker)
      WHERE cp.cap_m>=1000
      AND m.category IN ('Domestic Common Stock','Domestic Common Stock Primary Class')
      AND m.exchange IN ('NYSE','NASDAQ','NYSEMKT')
      AND m.sector NOT IN ('Financial Services','Real Estate')''')
    ambiguous = c.execute('SELECT count(*) FROM (SELECT q,permaticker FROM grid GROUP BY q,permaticker HAVING count(*)>1)').fetchone()[0]
    if ambiguous: raise ValueError('Ambiguous duplicate security identities: '+str(ambiguous))
    say('common universe ' + str(c.execute('SELECT count(*),count(DISTINCT ticker) FROM grid').fetchone()))
    # Fix original filing-date row per period, without pretending values are old vintages.
    metrics = ['revenue','gp','opinc','ebit','ebitda','netinc','ncfo','capex','fcf','assets','equity',
      'debt','cashneq','sharesbas','shareswa','shareswadil','sharefactor','sbcomp','invcapavg',
      'roic','roa','roe','grossmargin','intexp','ncfcommon','depamor','workingcapital','fxusd','revenueusd']
    c.execute('''CREATE TEMP TABLE f0 AS SELECT ticker,dimension,reportperiod,date,lastupdated,
      fiscalperiod,_observed_at,_ingestion_run,
      try_cast(regexp_extract(fiscalperiod,'^(\\d{4})-Q([1-4])$',1) AS INTEGER) fiscal_year,
      try_cast(regexp_extract(fiscalperiod,'^(\\d{4})-Q([1-4])$',2) AS INTEGER) fiscal_quarter,
      ''' + ','.join(metrics) + ''' FROM fundamentals
      WHERE dimension IN ('ARQ','ART') AND reportperiod<=date
      AND ticker IN (SELECT DISTINCT ticker FROM grid)
      QUALIFY row_number() OVER(PARTITION BY ticker,dimension,reportperiod ORDER BY date ASC,lastupdated DESC)=1''')
    c.execute('''CREATE TEMP TABLE f AS SELECT *,fiscal_year*4+fiscal_quarter fiscal_id,
      count(*) OVER(PARTITION BY ticker,dimension,fiscal_year,fiscal_quarter) fiscal_id_count FROM f0''')
    def anchor(name, condition):
        c.execute('CREATE TEMP TABLE '+name+'''_keys AS SELECT g.q,g.ticker,d.info_date,f.dimension,f.reportperiod,f.date
          FROM grid g JOIN dates d USING(q) LEFT JOIN f ON f.ticker=g.ticker
          AND f.date<=d.info_date AND f.reportperiod<=d.info_date AND '''+condition+'''
          QUALIFY row_number() OVER(PARTITION BY g.q,g.ticker ORDER BY f.reportperiod DESC,f.date ASC)=1''')
        c.execute('CREATE TEMP TABLE '+name+''' AS SELECT k.q,k.ticker,k.info_date,f.* EXCLUDE(ticker)
          FROM '''+name+'''_keys k LEFT JOIN f ON f.ticker=k.ticker AND f.dimension=k.dimension
          AND f.reportperiod=k.reportperiod AND f.date=k.date''')
    anchor('qa', "f.dimension='ARQ'")
    anchor('ta', "f.dimension='ART'")
    anchor('ya', "f.dimension='ART' AND f.fiscal_quarter=4")
    tjoins = '\n'.join(f'''LEFT JOIN f t{i} ON t{i}.ticker=t0.ticker AND t{i}.dimension='ART'
      AND t{i}.fiscal_id=t0.fiscal_id-{i} AND t{i}.fiscal_id_count=1 AND t{i}.date<=t0.info_date
      AND t{i}.reportperiod<t0.reportperiod''' for i in range(1,6))
    tchain = lambda n: 't0.fiscal_id_count=1 AND ' + ' AND '.join(f"t{i}.fiscal_id IS NOT NULL AND datediff('day',t{i}.reportperiod,t{i-1}.reportperiod) BETWEEN 60 AND 120" for i in range(1,n+1))
    tlagcols = [f't{i}.{x} ttm_lag{i}_{x}' for i in [1,4,5] for x in ['netinc','revenue','reportperiod','date','lastupdated','fiscal_id']]
    c.execute('CREATE TEMP TABLE ttm_lags AS SELECT t0.q,t0.ticker,'+','.join(tlagcols)+f''',
      {tchain(4)} ttm_chain5_valid,{tchain(5)} ttm_chain6_valid,
      CASE WHEN {tchain(4)} AND t4.netinc<>0 THEN (t0.netinc-t4.netinc)/abs(t4.netinc) END earnings_signed_improvement,
      CASE WHEN {tchain(5)} AND t4.netinc<>0 AND t5.netinc<>0 THEN
        (t0.netinc-t4.netinc)/abs(t4.netinc)-(t1.netinc-t5.netinc)/abs(t5.netinc) END earnings_signed_accel
      FROM ta t0 {tjoins}''')
    # Retain all lag inputs and timing for independent auditing.
    qraw = ['revenue','gp','opinc','netinc','ncfo','capex','fcf','assets','sharesbas','sharefactor','sbcomp','fxusd','revenueusd']
    qselect = [f'q{i}.{x} q{i}_{x}' for i in range(6) for x in qraw + ['reportperiod','date','lastupdated','fiscal_id','fiscal_id_count']]
    joins = '\n'.join(f'''LEFT JOIN f q{i} ON q{i}.ticker=q0.ticker AND q{i}.dimension='ARQ'
      AND q{i}.fiscal_id=q0.fiscal_id-{i} AND q{i}.fiscal_id_count=1 AND q{i}.date<=q0.info_date
      AND q{i}.reportperiod<q0.reportperiod''' for i in range(1,6))
    chain = lambda n: 'q0.fiscal_id_count=1 AND ' + ' AND '.join(f"q{i}.fiscal_id IS NOT NULL AND datediff('day',q{i}.reportperiod,q{i-1}.reportperiod) BETWEEN 60 AND 120" for i in range(1,n+1))
    c.execute('CREATE TEMP TABLE quarterly AS SELECT q0.q,q0.ticker,' + ','.join(qselect) + f''',
      datediff('day',q0.reportperiod,q0.info_date) q_age_days,
      {chain(3)} q_chain4_valid,{chain(4)} q_chain5_valid,{chain(5)} q_chain6_valid,
      CASE WHEN {chain(4)} AND q4.revenue>0 THEN q0.revenue/q4.revenue-1 END revenue_yoy,
      CASE WHEN {chain(5)} AND q4.revenue>0 AND q5.revenue>0 THEN q0.revenue/q4.revenue-q1.revenue/q5.revenue END revenue_yoy_accel,
      CASE WHEN {chain(4)} AND q0.revenue>0 AND q4.revenue>0 THEN q0.opinc/q0.revenue-q4.opinc/q4.revenue END opmargin_change_yoy,
      CASE WHEN {chain(4)} AND q0.revenue>0 AND q4.revenue>0 THEN q0.fcf/q0.revenue-q4.fcf/q4.revenue END fcfmargin_change_yoy,
      CASE WHEN {chain(4)} AND q0.revenue>0 AND q4.revenue>0 THEN q0.gp/q0.revenue-q4.gp/q4.revenue END grossmargin_change_yoy,
      CASE WHEN {chain(4)} AND q4.sharesbas>0 THEN q0.sharesbas/q4.sharesbas-1 END shares_yoy,
      CASE WHEN {chain(3)} THEN q0.revenue+q1.revenue+q2.revenue+q3.revenue END arq_revenue_ttm,
      CASE WHEN {chain(3)} THEN q0.fcf+q1.fcf+q2.fcf+q3.fcf END arq_fcf_ttm
      FROM qa q0 {joins}''')
    yraw = ['revenue','gp','opinc','ebit','ebitda','netinc','ncfo','capex','fcf','assets','equity',
      'debt','cashneq','sharesbas','sharefactor','sbcomp','roic','invcapavg','fxusd','revenueusd']
    yselect = [f'y{i}.{x} y{i}_{x}' for i in range(6) for x in yraw + ['reportperiod','date','lastupdated','fiscal_year','fiscal_id_count']]
    yjoins = '\n'.join(f'''LEFT JOIN f y{i} ON y{i}.ticker=y0.ticker AND y{i}.dimension='ART'
      AND y{i}.fiscal_quarter=4 AND y{i}.fiscal_year=y0.fiscal_year-{i} AND y{i}.fiscal_id_count=1
      AND y{i}.date<=y0.info_date AND y{i}.reportperiod<y0.reportperiod''' for i in range(1,6))
    ychain = lambda n: 'y0.fiscal_id_count=1 AND '+ ' AND '.join(f"y{i}.fiscal_year IS NOT NULL AND datediff('day',y{i}.reportperiod,y{i-1}.reportperiod) BETWEEN 300 AND 430" for i in range(1,n))
    yroic = [f'CASE WHEN y{i}.invcapavg>0 AND abs(y{i}.ebit/y{i}.invcapavg-y{i}.roic)<=.0011 THEN y{i}.roic END y{i}_roic_verified' for i in range(6)]
    c.execute('CREATE TEMP TABLE annual AS SELECT y0.q,y0.ticker,' + ','.join(yselect+yroic)+f''',
      datediff('day',y0.reportperiod,y0.info_date) annual_age_days,
      {ychain(5)} annual_chain5_valid,{ychain(6)} annual_chain6_valid,
      CASE WHEN {ychain(6)} AND y0.revenue>0 AND y5.revenue>0 THEN pow(y0.revenue/y5.revenue,.2)-1 END revenue_cagr5,
      CASE WHEN {ychain(6)} AND y0.fcf>0 AND y5.fcf>0 THEN pow(y0.fcf/y5.fcf,.2)-1 END fcf_cagr5
      FROM ya y0 {yjoins}''')
    say('quarter and annual fundamentals ready')
    for temporary in ['f0','f','qa','ya','qa_keys','ta_keys','ya_keys','caps','master']:
        c.execute('DROP TABLE '+temporary)
    # Prices are only filtered by EX ANTE universe membership at some sample date.
    # No outcome completeness requirement may delete a signal-period selection.
    requested = ' UNION '.join('SELECT '+x+' date FROM dates' for x in ['signal_date','entry','next_entry','pre6','pre12','pre1'])
    c.execute(f'''CREATE TEMP TABLE px AS SELECT ticker,date,closeadj,close,closeunadj
      FROM stocks WHERE date IN ({requested}) AND ticker IN (SELECT DISTINCT ticker FROM grid)''')
    c.execute('''CREATE TEMP TABLE ma AS WITH w AS (
      SELECT ticker,date,closeadj,
        avg(closeadj) OVER(PARTITION BY ticker ORDER BY date ROWS BETWEEN 199 PRECEDING AND CURRENT ROW) ma200,
        count(closeadj) OVER(PARTITION BY ticker ORDER BY date ROWS BETWEEN 199 PRECEDING AND CURRENT ROW) ma200_n,
        min(date) OVER(PARTITION BY ticker ORDER BY date ROWS BETWEEN 199 PRECEDING AND CURRENT ROW) ma200_start
      FROM stocks WHERE ticker IN (SELECT DISTINCT ticker FROM grid) AND date>='2011-01-01' AND closeadj>0)
      SELECT * FROM w WHERE date IN (SELECT signal_date FROM dates)''')
    pricecols = ['signal_date','entry','next_entry','pre6','pre12','pre1']
    pjoins = '\n'.join(f'LEFT JOIN px p{i} ON p{i}.ticker=g.ticker AND p{i}.date=d.{x} AND p{i}.closeadj>0' for i,x in enumerate(pricecols))
    tcols = [f't.{x} ttm_{x}' for x in metrics+['reportperiod','date','lastupdated','fiscal_id_count']]
    c.execute('''CREATE TEMP TABLE panel AS SELECT g.*,d.* EXCLUDE(q),
      '''+','.join(tcols)+''',g.master_currency ttm_currency,
      datediff('day',t.reportperiod,d.info_date) ttm_age_days,
      CASE WHEN t.invcapavg>0 AND abs(t.ebit/t.invcapavg-t.roic)<=.0011 THEN t.roic END roic_verified,
      t.gp/nullif(t.revenue,0) grossmargin,t.opinc/nullif(t.revenue,0) opmargin,
      t.fcf/nullif(t.revenue,0) fcfmargin,t.ncfo/nullif(t.revenue,0) ocfmargin,
      CASE WHEN t.netinc>0 THEN t.ncfo/t.netinc END cash_conversion,
      t.fcf/(g.cap_m*1e6) fcf_yield,(t.fcf-t.sbcomp)/(g.cap_m*1e6) fcf_after_sbc_yield,
      CASE WHEN t.ebitda>0 THEN (t.debt-t.cashneq)/t.ebitda END netdebt_ebitda,
      CASE WHEN t.equity>0 THEN t.debt/t.equity END debt_equity,
      t.sbcomp/nullif(t.revenue,0) sbc_revenue,-t.capex/nullif(t.revenue,0) capex_revenue,
      CASE WHEN t.intexp>0 THEN t.ebit/t.intexp END interest_coverage,
      (abs(t.fcf-t.ncfo-t.capex)<=greatest(1,abs(t.fcf)*.000001)) ttm_fcf_formula_valid,
      qt.* EXCLUDE(q,ticker),an.* EXCLUDE(q,ticker),tl.* EXCLUDE(q,ticker),
      p0.closeadj signal_price,p0.closeunadj signal_price_unadjusted,p1.closeadj entry_price,p2.closeadj next_entry_price,
      p3.closeadj pre6_price,p4.closeadj pre12_price,p5.closeadj pre1_price,
      p0.closeadj/p3.closeadj-1 momentum6,p5.closeadj/p4.closeadj-1 momentum12_1,
      CASE WHEN ma.ma200_n=200 THEN ma.ma200 END ma200,ma.ma200_n,ma.ma200_start,
      CASE WHEN ma.ma200_n=200 THEN p0.closeadj/ma.ma200-1 END price_vs_ma200,
      p2.closeadj/p1.closeadj-1 next_return,
      (p1.closeadj IS NULL) entry_price_missing,(d.next_entry IS NULL) next_period_immature,
      (d.next_entry IS NOT NULL AND p2.closeadj IS NULL) next_endpoint_missing
      FROM grid g JOIN dates d USING(q) LEFT JOIN ta t USING(q,ticker)
      LEFT JOIN quarterly qt USING(q,ticker) LEFT JOIN annual an USING(q,ticker)
      LEFT JOIN ttm_lags tl USING(q,ticker)
      '''+pjoins+''' LEFT JOIN ma ON ma.ticker=g.ticker AND ma.date=d.signal_date''')
    export(c,'SELECT * FROM panel ORDER BY q,ticker','common-panel.csv')
    checks = rows(c, '''SELECT count(*) n,count(DISTINCT ticker) tickers,count(DISTINCT q) quarter_count,
      count(*) FILTER(WHERE isdelisted='Y') currently_delisted_rows,
      count(*) FILTER(WHERE entry_price_missing) entry_missing,
      count(*) FILTER(WHERE next_endpoint_missing) mature_endpoint_missing,
      count(*) FILTER(WHERE ttm_date>info_date OR q0_date>info_date OR y0_date>info_date) future_publications,
      count(*) FILTER(WHERE ttm_lastupdated>info_date) latest_art_updated_after_signal,
      count(*) FILTER(WHERE ttm_currency='USD' AND ttm_age_days BETWEEN 0 AND 180) fresh_usd_art,
      count(*) FILTER(WHERE annual_chain5_valid AND annual_age_days<=550) fresh_annual5,
      count(*) FILTER(WHERE annual_chain6_valid AND annual_age_days<=550) fresh_annual6
      FROM panel''')[0]
    coverage = rows(c, '''SELECT year(entry) entry_year,count(*) row_count,count(DISTINCT ticker) tickers,
      count(*) FILTER(WHERE ttm_currency='USD' AND ttm_age_days BETWEEN 0 AND 180) fresh_usd_art,
      count(*) FILTER(WHERE annual_chain5_valid AND annual_age_days<=550) fresh_annual5,
      count(*) FILTER(WHERE annual_chain6_valid AND annual_age_days<=550) fresh_annual6,
      count(*) FILTER(WHERE momentum12_1 IS NOT NULL AND ma200_n=200) momentum_complete,
      count(*) FILTER(WHERE next_endpoint_missing) mature_endpoint_missing
      FROM panel GROUP BY year(entry) ORDER BY 1''')
    states = {t: {k:v for k,v in repo._states[t].items() if k in ['row_count','min_date','max_date']} for t in ['fundamentals','stocks','daily','tickers']}
    dims = rows(c, '''SELECT dimension,count(*) row_count,min(date) min_publication,max(date) max_publication,
      min(_observed_at) first_observation,max(_observed_at) last_observation FROM fundamentals GROUP BY dimension ORDER BY dimension''')
    dates = [dict(zip(datecols,x)) for x in schedule]
    for d in dates:
        d['spy_entry_price'] = spyprice.get(d['entry']); d['spy_next_entry_price'] = spyprice.get(d['next_entry'])
        d['spy_next_return'] = d['spy_next_entry_price']/d['spy_entry_price']-1 if d['spy_next_entry_price'] else None
    meta = dict(factGeneration=repo.generation,priceCutoff=cutoff,checks=checks,coverageByEntryYear=coverage,
      dates=dates,sourceStates=states,fundamentalDimensions=dims,
      schema=[x[0] for x in c.execute('DESCRIBE panel').fetchall()],
      panelSha256=digest(OUT/'common-panel.csv'),scriptSha256=digest(Path(__file__)),
      timing='Quarter-end last SPY session signals; execute next SPY session close; exit following quarter next SPY session close.',
      vintage='Current-vintage, original as-reported-date reconstruction. Not archival strict point-in-time.',
      annualBasis='ART at fiscal Q4; one TTM per fiscal year. Six points required for five-year CAGR.',
      classifications='Current unique SF1 security master; not historical sector/exchange membership.',
      universe='Domestic common/primary common, NYSE/NASDAQ/NYSEMKT, current sector excluding Financial Services/Real Estate, signal-date cap>=USD1bn. No future return or delisting filter.',
      outputBytes=(OUT/'common-panel.csv').stat().st_size)
    (OUT/'common-metadata.json').write_text(json.dumps(meta,default=str,indent=2)+'\n')
    say('COMPLETE '+str(checks))
