from .contracts import TaskPlan, digest, record
from .registry import ordered


def input_vector(spec,snapshot):
    return {key:{field:item.get(field) for field in ('contentVersion','schema','status','sourceAsOf')}
        for key in (*spec.requiredInputs,*spec.optionalInputs)
        for item in [snapshot.inputs.get(key,{'status':'missing'})]}


def plan(specs,snapshot,previous=None,failed_sources=()):
    previous=previous or {}
    result=[]
    for spec in ordered(specs):
        vector=input_vector(spec,snapshot)
        missing=tuple(k for k in spec.requiredInputs if vector[k]['status']!='ready' or k in failed_sources)
        # Optional readiness AND failures affect identity; do not silently
        # replace a failed optional source with an empty data set.
        for key in spec.optionalInputs:
            if key in failed_sources: vector[key]={**vector[key],'status':'stale_after_failure'}
        fingerprint=digest({'spec':record(spec),'inputs':vector})
        prior=previous.get((spec.id,fingerprint))
        reason='required_dependency_unavailable' if missing else 'unchanged' if prior else 'input_or_contract_changed'
        result.append(TaskPlan(spec.id,fingerprint,reason,
            {k:[p['bucket'] for p in snapshot.inputs.get(k,{}).get('partitions',[])] for k in vector},
            prior, sum(p['bytes'] for k in vector for p in snapshot.inputs.get(k,{}).get('partitions',[])), missing, vector))
    return result
