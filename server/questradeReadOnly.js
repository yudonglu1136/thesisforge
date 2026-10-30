// Questrade's refresh tokens rotate. Persist the replacement before reading
// accounts; callers must serialize refreshes per owner across workers.
const fail = code => Object.assign(new Error(code), {code});
const token = value => typeof value === 'string' && value.length >= 12 &&
  value.length <= 4096 && !/[\s\x00-\x1f]/.test(value);

export function questradeApiOrigin(value) {
  let url;
  try { url = new URL(value); } catch { throw fail('questrade_invalid_api_server'); }
  if (url.protocol !== 'https:' || url.username || url.password || url.port ||
      url.search || url.hash || !/^api\d+\.iq\.questrade\.com$/.test(url.hostname) ||
      !['/', '/v1', '/v1/'].includes(url.pathname)) {
    throw fail('questrade_invalid_api_server');
  }
  return url.origin;
}

async function jsonRequest(fetchImpl, url, options) {
  let response;
  try {
    response = await fetchImpl(url, {...options, redirect: 'error',
      signal: AbortSignal.timeout(15_000)});
  } catch { throw fail('questrade_connection_failed'); }
  // Do not propagate broker response text, URLs or credentials into logs/UI.
  if (!response.ok) throw fail(response.status === 401 ?
    'questrade_authorization_expired' : 'questrade_request_failed');
  try { return await response.json(); }
  catch { throw fail('questrade_invalid_response'); }
}

export async function refreshQuestradeSession(refreshToken, {
  fetchImpl = fetch, persistSession, now = Date.now(),
} = {}) {
  if (!token(refreshToken)) throw fail('questrade_invalid_token');
  if (typeof persistSession !== 'function') throw fail('questrade_persistence_required');
  const result = await jsonRequest(fetchImpl, 'https://login.questrade.com/oauth2/token', {
    method: 'POST', headers: {'Content-Type': 'application/x-www-form-urlencoded'},
    body: new URLSearchParams({grant_type: 'refresh_token', refresh_token: refreshToken}),
  });
  const origin = questradeApiOrigin(result.api_server);
  const ttl = Number(result.expires_in);
  if (!token(result.access_token) || !token(result.refresh_token) ||
      result.token_type?.toLowerCase() !== 'bearer' || !Number.isFinite(ttl) || ttl <= 0 || ttl > 86400) {
    throw fail('questrade_invalid_session');
  }
  const session = {accessToken: result.access_token, refreshToken: result.refresh_token,
    apiOrigin: origin, expiresAt: new Date(now + ttl * 1000).toISOString()};
  await persistSession(session);
  return session;
}

// No arbitrary endpoint, order, cancellation or transfer method is exposed.
export async function readQuestradeAccounts(session, {fetchImpl = fetch, now = Date.now()} = {}) {
  const deadline = Date.now() + 240_000;
  const origin = questradeApiOrigin(session?.apiOrigin);
  if (!token(session?.accessToken) || !(Date.parse(session.expiresAt) > now)) {
    throw fail('questrade_authorization_expired');
  }
  const get = path => {
    if (Date.now() > deadline) throw fail('questrade_read_timeout');
    return jsonRequest(fetchImpl, `${origin}/v1/${path}`, {
    method: 'GET', headers: {Authorization: `Bearer ${session.accessToken}`},
    });
  };
  const result = await get('accounts');
  if (!Array.isArray(result.accounts) || result.accounts.length > 100) throw fail('questrade_invalid_accounts');
  const seen = new Set();
  for (const account of result.accounts) {
    if (!/^\d{1,30}$/.test(String(account.number)) || seen.has(String(account.number))) {
      throw fail('questrade_invalid_accounts');
    }
    seen.add(String(account.number));
  }
  const accounts = [];
  for (const account of result.accounts) {
    const id = String(account.number);
    const balances = await get(`accounts/${id}/balances`);
    const positions = await get(`accounts/${id}/positions`);
    if (!Array.isArray(balances.perCurrencyBalances) || !Array.isArray(balances.combinedBalances) ||
        !Array.isArray(positions.positions)) throw fail('questrade_invalid_account_report');
    // Combined balances are alternate currency views, never additive accounts.
    // Preserve broker currency and instrument identities for normalization.
    accounts.push({account, balances, positions: positions.positions});
  }
  return {provider: 'questrade', access: 'read_only',
    retrievedAt: new Date(now).toISOString(), accounts};
}
