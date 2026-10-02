"""Frozen ex-ante feature adapters. Intentionally never read forward prices/returns."""
import numpy as np
import pandas as pd

FORBIDDEN = {'entry_price', 'next_entry_price', 'next_return', 'entry_price_missing', 'next_endpoint_missing'}

def finite(frame, cols): return np.isfinite(frame[cols]).all(axis=1)

def build_features(d):
    """Inputs have only past/current source facts. Returns all base rows and masks."""
    def usd(prefix):
        return (np.isclose(d[prefix+'fxusd'], 1, rtol=0, atol=1e-8)
                & np.isclose(d[prefix+'revenueusd'], d[prefix+'revenue'], rtol=1e-6, atol=1))
    def cash_identity(prefix):
        return np.isclose(d[prefix+'fcf'], d[prefix+'ncfo']+d[prefix+'capex'], rtol=0, atol=1)
    base = d.signal_price.gt(0) & np.isfinite(d.signal_price)
    ttm = (d.master_currency.eq('USD') & usd('ttm_') & d.ttm_age_days.between(0,180)
           & d.ttm_revenue.gt(0) & d.ttm_ebitda.gt(0) & cash_identity('ttm_'))
    quarterly = d.q_age_days.between(0,180)
    d['enterprise_value_proxy'] = d.cap_m*1e6 + d.ttm_debt - d.ttm_cashneq
    d['operating_earnings_yield'] = (d.ttm_ebit/d.enterprise_value_proxy).where(d.enterprise_value_proxy.gt(0))
    d['net_equity_cash_payout_yield'] = -d.ttm_ncfcommon/(d.cap_m*1e6)
    d['negative_netdebt_ebitda'] = -d.netdebt_ebitda
    roic = d[[f'y{i}_roic_verified' for i in range(5)]]
    opm = pd.concat([d[f'y{i}_opinc']/d[f'y{i}_revenue'].where(d[f'y{i}_revenue'].gt(0)) for i in range(5)],axis=1)
    fcfm = pd.concat([d[f'y{i}_fcf']/d[f'y{i}_revenue'].where(d[f'y{i}_revenue'].gt(0)) for i in range(5)],axis=1)
    d['roic_median5'] = roic.median(axis=1,skipna=False)
    d['roic_min5'] = roic.min(axis=1,skipna=False)
    d['negative_opmargin_std5'] = -opm.std(axis=1,ddof=0,skipna=False)
    d['normalized_fcf_yield'] = fcfm.median(axis=1,skipna=False)*d.ttm_revenue/(d.cap_m*1e6)
    annual = d.annual_chain5_valid.eq(True) & d.annual_age_days.between(0,550)
    for i in range(5): annual &= usd(f'y{i}_') & cash_identity(f'y{i}_')
    d['earnings_yoy_signed'] = (d.q0_netinc-d.q4_netinc)/d.q4_netinc.abs().where(d.q4_netinc.ne(0))
    d['earnings_yoy_accel'] = d.earnings_yoy_signed-(d.q1_netinc-d.q5_netinc)/d.q5_netinc.abs().where(d.q5_netinc.ne(0))
    peers = d[base & np.isfinite(d.momentum6)].groupby(['q','sector']).momentum6.agg(['median','count'])
    keys = pd.MultiIndex.from_frame(d[['q','sector']])
    d['sector_sample_count'] = peers['count'].reindex(keys).to_numpy()
    d['sector_momentum6'] = peers['median'].reindex(keys).to_numpy()
    d.loc[d.sector_sample_count.lt(5),'sector_momentum6'] = np.nan
    features = {
        'buffett':['roic_median5','roic_min5','negative_opmargin_std5','normalized_fcf_yield','negative_netdebt_ebitda'],
        'ackman':['roic_verified','fcfmargin','opmargin','fcf_yield','operating_earnings_yield','opmargin_change_yoy','net_equity_cash_payout_yield'],
        'druckenmiller':['earnings_yoy_signed','earnings_yoy_accel','momentum12_1','momentum6','sector_momentum6']}
    masks = {
        'buffett':base & ttm & annual & finite(d,features['buffett']),
        'ackman':base & ttm & quarterly & d.q_chain5_valid.eq(True) & usd('q0_') & usd('q4_') & d.q0_revenue.gt(0) & d.q4_revenue.gt(0) & finite(d,features['ackman']),
        'druckenmiller':base & quarterly & d.q_chain6_valid.eq(True) & finite(d,features['druckenmiller'])}
    for i in [0,1,4,5]: masks['druckenmiller'] &= usd(f'q{i}_')
    d['base_price_valid']=base
    for model,mask in masks.items(): d[model+'_feature_complete']=mask
    d['common_feature_complete']=np.logical_and.reduce(list(masks.values()))
    d['buffett_style_gate'] = ((d[[f'y{i}_fcf' for i in range(5)]]>0).all(axis=1)
       & d.roic_median5.ge(.1) & (d[['ttm_revenue','ttm_fcf','ttm_netinc','ttm_ebitda']]>0).all(axis=1)
       & d.netdebt_ebitda.le(3))
    d['ackman_style_gate'] = ((d[['ttm_revenue','ttm_fcf','ttm_ebitda','enterprise_value_proxy']]>0).all(axis=1)
       & d.netdebt_ebitda.le(3))
    d['druckenmiller_style_gate'] = True
    # Diagnostic explicitly means 200 observed closes, not a validated consecutive-session MA.
    d['positive_trend_observed200_diagnostic'] = d.momentum6.gt(0) & d.price_vs_ma200.gt(0) & d.ma200_n.eq(200)
    return d,features
