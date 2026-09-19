"""Small explicit registries; no rankings, forecasts or investment logic."""
from dataclasses import dataclass
from datetime import date
import math

METRICS={
    'Revenue':{'name':'Revenue','unit':'reporting_currency','table':'fundamentals','field':'revenue','scale':1,'derived':False},
    'FreeCashFlow':{'name':'Free cash flow','unit':'reporting_currency','table':'fundamentals','field':'fcf','scale':1,'derived':False},
    'ROIC':{'name':'Return on invested capital','unit':'ratio','table':'fundamentals','field':'roic','scale':1,'derived':False},
    'MarketCap':{'name':'Market capitalization','unit':'USD','table':'daily','field':'marketcap','scale':1000000,'derived':False},
    'InstitutionalShareUnits':{'name':'Institutional common-share units','unit':'shares','table':'holdings_ticker','field':'shrunits','scale':1000,'derived':False},
    'InstitutionalHolderCount':{'name':'Institutional common-share holders','unit':'institutions','table':'holdings_ticker','field':'shrholders','scale':1,'derived':False},
    'InstitutionalShareValue':{'name':'Institutional common-share market value','unit':'USD','table':'holdings_ticker','field':'shrvalue','scale':1000000,'derived':False},
}

for _metric_id, _definition in METRICS.items():
    _definition.update({'metric_id':_metric_id,'source':'Sharadar',
        'pit_supported':_definition['table']!='holdings_ticker',
        'definition_version':'1'})

class MetricRegistry:
    """Canonical definitions shield consumers from physical vendor field names."""
    def get(self,metric_id):
        if metric_id not in METRICS:raise ValueError('unknown canonical metric')
        return dict(METRICS[metric_id])
    def list(self):return [self.get(metric_id) for metric_id in METRICS]

@dataclass(frozen=True)
class FeatureDefinition:
    feature_id: str
    version: str
    inputs: tuple
    unit: str
    calculate: object

class FeatureRegistry:
    def __init__(self): self.definitions={}
    def register(self,definition):
        if not definition.feature_id or not definition.version or not callable(definition.calculate):
            raise ValueError('feature ID, calculation version and deterministic calculator required')
        if not definition.inputs or any(metric_id not in METRICS for metric_id in definition.inputs):
            raise ValueError('feature inputs must reference canonical metrics')
        key=(definition.feature_id,definition.version)
        if key in self.definitions: raise ValueError('feature version is immutable')
        self.definitions[key]=definition

def _currencies_compatible(definition, facts):
    monetary = [fact for fact in facts.values() if fact and fact.get('unit') in ('USD', 'reporting_currency')]
    if all(fact.get('currency') for fact in monetary):
        return len({fact['currency'] for fact in monetary}) <= 1
    # Unknown native currency cannot be combined with USD, or with a different
    # source row. A ratio of native amounts from one exact SF1 observation can
    # cancel currency without inventing a historical currency code (FCFMargin).
    if (definition.unit != 'ratio' or len(monetary) < 2 or
            any(fact['unit'] != 'reporting_currency' or fact.get('currency') for fact in monetary)):
        return False
    first = monetary[0]
    lineage = first.get('provenance') or {}
    return bool(first.get('security_id') and lineage.get('source') == 'Sharadar' and
        lineage.get('table') == 'fundamentals' and lineage.get('key') and lineage.get('ingestion_run') and
        all(fact.get('security_id') == first['security_id'] and fact.get('provenance') == lineage
            for fact in monetary))

class FeatureEngine:
    def __init__(self,repository,registry): self.repository,self.registry=repository,registry
    def calculate(self,feature_id,version,ticker,as_of,dimension='ART'):
        if as_of is None:
            raise ValueError('an explicit as-of date is required for a versioned feature')
        date.fromisoformat(str(as_of))
        d=self.registry.definitions[(feature_id,version)]
        facts={m:self.repository.get_metric(ticker,m,as_of=as_of,dimension=dimension) for m in d.inputs}
        periods={f['period_end'] for f in facts.values() if f}
        valid=all(f and f['value'] is not None and math.isfinite(f['value']) and f.get('pit_supported',True) for f in facts.values()) and len(periods)==1 and _currencies_compatible(d,facts)
        value=d.calculate({m:f['value'] for m,f in facts.items()}) if valid else None
        if value is not None and not math.isfinite(value):
            value=None
        return {'feature_id':feature_id,'version':version,'ticker':ticker,'as_of':as_of,
                'value':value,'unit':d.unit,'input_facts':facts,'status':'ok' if value is not None else 'missing_or_incompatible_inputs',
                'calculation_version':version,'dimension':dimension,'pit_as_of':as_of}

def default_registry():
    registry=FeatureRegistry()
    registry.register(FeatureDefinition('FCFMargin','1',('FreeCashFlow','Revenue'),'ratio',
        lambda f:f['FreeCashFlow']/f['Revenue'] if f['Revenue'] else None))
    return registry
