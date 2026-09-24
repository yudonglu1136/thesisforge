// A segment is an independently funded replay, never a continuation across an
// unpriced entitlement. Consumers must select one segment before computing.
export function ruleSegments(style, curve) {
  return style.coverage?.segments ?? (curve.length ? [{from:curve[0].date,to:curve.at(-1).date}] : []);
}

export function ruleRangeCovered(style, curve, start, end) {
  return ruleSegments(style, curve).find(s=>s.from<=start && s.to>=end) ?? null;
}

export function emptyRuleMetrics() {
  return {totalReturn:null,cagr:null,maxDrawdown:null,volatility:null,sharpeZeroRf:null,endingValue:null};
}
