const FINANCIAL = new Set(['bank','insurance','card_network_lender','credit_services','capital_markets']);
const CUSTOMER_CASH = new Set(['asset_manager','insurance_broker','managed_care','payments_processor']);
const REVENUE_STAGE = new Set(['emerging_biotech','emerging_health_ai']);
const MULTI_METHOD = new Set([
  'software_growth','software_platform','hypergrowth_ai_software','defense_growth',
  'space_launch_growth','space_platform_ipo','genetic_diagnostics_growth',
  'semiconductor_growth','semiconductor_storage_cycle','optical_networking_turnaround',
  'energy_technology','ev_autonomy_platform','platform_marketplace_reinvestment',
  'subscription_streaming_platform',
]);
const OPERATING = new Set([
  'ads_ai_platform','biopharma','biopharma_growth','commodity_merchant',
  'consumer_cyclical','consumer_staples','defense_prime','energy_e_and_p',
  'energy_infrastructure','healthcare_distribution','healthcare_services',
  'industrial_gases_compounder','industrial_growth','information_services',
  'interactive_entertainment','materials','mature_medtech','media_telecom',
  'medtech_platform','mega_cap_platform','networking_hardware','payments_network',
  'platform_reinvestment','power_utility','quality_consumer','reit',
  'semiconductor_cyclical','semiconductor_equipment','semiconductor_foundry',
  'semiconductor_value','technology_hardware','transportation',
]);

// Older audited Jansen PIT rows predate the explicit modelRoute field. The
// profile was already persisted and deterministically selected the same model
// branch, so it is sufficient compatibility evidence; unknown profiles fail
// closed instead of being treated as operating companies.
export function valuationModelRoute(score={}) {
  if (typeof score.modelRoute==='string' && score.modelRoute) return score.modelRoute;
  const profile=typeof score.profile==='string'?score.profile:'';
  if(!profile)return null;
  if(FINANCIAL.has(profile))return 'financial_institution';
  if(CUSTOMER_CASH.has(profile))return 'customer_cash_earnings';
  if(REVENUE_STAGE.has(profile))return 'revenue_stage';
  if(profile==='bitcoin_treasury_software')return 'bitcoin_treasury';
  if(MULTI_METHOD.has(profile))return 'multi_method_growth';
  if(OPERATING.has(profile))return 'operating_company';
  return null;
}
