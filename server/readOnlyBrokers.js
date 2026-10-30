import crypto from 'node:crypto';
import {brokerOwnerHash, readReadOnlyBroker, updateReadOnlyBroker} from './userPortfolioStore.js';
import {refreshQuestradeSession, readQuestradeAccounts} from './questradeReadOnly.js';

const error = code => Object.assign(new Error(code), {code});
const digest = value => crypto.createHash('sha256').update(value).digest('hex');
const number = value => typeof value === 'number' && Number.isFinite(value) ? value : null;
const text = value => typeof value === 'string' ? value.slice(0, 160) : '';

function publicSnapshot(report) {
  if (report.provider === 'questrade') return {
    retrievedAt: report.retrievedAt,
    accounts: report.accounts.map(({account, balances, positions}) => ({
      id: String(account.number), name: text(account.type),
      balances: balances.perCurrencyBalances.map(b => ({currency: text(b.currency),
        cash: number(b.cash), marketValue: number(b.marketValue), totalEquity: number(b.totalEquity)})),
      positions: positions.map(p => ({ticker: text(p.symbol), quantity: number(p.openQuantity),
        price: number(p.currentPrice), value: number(p.currentMarketValue), currency: null})),
    })),
  };
  throw error('broker_report_invalid');
}

export function readBrokerStatus(user, provider) {
  const state = readReadOnlyBroker(user, provider);
  return {provider, access: 'read_only', connected: Boolean(state),
    status: state?.status || 'not_connected', snapshot: state?.snapshot || null,
    lastError: state?.lastError || null,
    connectorExpiresAt: state?.connectorExpiresAt || null};
}

// A database lease prevents simultaneous rotating-token refreshes in different
// API processes. Expired leases can be recovered; revisions reject late replies.
export async function syncQuestrade(user, {refreshToken, fetchImpl = fetch} = {}) {
  const lease = crypto.randomUUID(), started = Date.now();
  const state = updateReadOnlyBroker(user, 'questrade', old => {
    if (old?.leaseUntil > started) throw error('broker_sync_busy');
    if (!refreshToken && !old?.session?.refreshToken) throw error('broker_not_connected');
    return {...old, lease, leaseUntil: started + 300_000, status: 'syncing'};
  });
  const write = update => updateReadOnlyBroker(user, 'questrade', current => {
    if (current?.lease !== lease) throw error('broker_connection_changed');
    return update(current);
  });
  try {
    const session = await refreshQuestradeSession(refreshToken || state.session.refreshToken, {
      fetchImpl, persistSession: async session => write(current => ({...current, session})),
    });
    const report = await readQuestradeAccounts(session, {fetchImpl});
    write(current => ({...current, snapshot: publicSnapshot(report), status: 'connected',
      lastError: null, lease: null, leaseUntil: 0}));
    return readBrokerStatus(user, 'questrade');
  } catch (cause) {
    try { write(current => ({...current, status: 'error', lease: null, leaseUntil: 0,
      lastError: 'broker_sync_failed'})); } catch { /* disconnect wins */ }
    throw error(cause.code === 'broker_connection_changed' ? cause.code : 'broker_sync_failed');
  }
}

export function pairFutu(user) {
  const secret = crypto.randomBytes(32).toString('base64url');
  const connectorToken = `${brokerOwnerHash(user)}.${secret}`;
  const connectorExpiresAt = new Date(Date.now() + 30 * 86400_000).toISOString();
  updateReadOnlyBroker(user, 'futu', old => ({...old, tokenHash: digest(connectorToken),
    connectorExpiresAt, status: 'awaiting_connector'}));
  return {connectorToken, connectorExpiresAt};
}

export function acceptFutuSnapshot(token, input, now = Date.now()) {
  if (!/^[a-f0-9]{40}\.[A-Za-z0-9_-]{43}$/.test(token || '')) throw error('connector_unauthorized');
  const user = {adminPortfolioHash: token.split('.')[0]};
  // Authenticate before accessing incoming data. No account selection by index.
  const state = readReadOnlyBroker(user, 'futu');
  if (!state?.tokenHash || !crypto.timingSafeEqual(Buffer.from(state.tokenHash), Buffer.from(digest(token))) ||
      !(Date.parse(state.connectorExpiresAt) > now)) throw error('connector_unauthorized');
  const time = Date.parse(input?.retrievedAt);
  if (input?.provider !== 'futu' || input?.access !== 'read_only' ||
      !Number.isFinite(time) || time > now + 60_000 || time < now - 300_000 ||
      !/^\d+$/.test(String(input.account?.acc_id)) || input.account?.trd_env !== 'REAL' ||
      !Array.isArray(input.positions) || input.positions.length > 10000 ||
      !/^[A-Z]{3}$/.test(input.funds?.currency || '') || number(input.funds?.total_assets) === null) {
    throw error('connector_snapshot_invalid');
  }
  const snapshot = {retrievedAt: input.retrievedAt, accounts: [{id: String(input.account.acc_id),
    name: 'Futu / moomoo', balances: [{currency: input.funds.currency,
      totalEquity: input.funds.total_assets, cash: number(input.funds.cash),
      marketValue: number(input.funds.market_val)}],
    positions: input.positions.map(p => ({ticker: text(p.code), quantity: number(p.qty),
      price: number(p.nominal_price), value: number(p.market_val), currency: text(p.currency) || null}))}]};
  updateReadOnlyBroker(user, 'futu', current => {
    if (current?.tokenHash !== state.tokenHash) throw error('connector_unauthorized');
    if (Date.parse(current.snapshot?.retrievedAt) > time) throw error('connector_snapshot_older');
    return {...current, snapshot, status: 'connected', lastError: null};
  });
  return {ok: true, receivedAt: new Date(now).toISOString()};
}

export function disconnectBroker(user, provider) {
  updateReadOnlyBroker(user, provider, () => null);
  return {ok: true};
}

export function mountBrokerRoutes(app) {
  const respond = fn => async (req, res) => {
    res.setHeader('Cache-Control', 'no-store');
    try { res.json(await fn(req)); }
    catch (e) { res.status(e.code === 'broker_sync_busy' ? 409 : 400)
      .json({error: e.code || 'broker_request_failed'}); }
  };
  app.get('/api/portfolio/broker/:provider', respond(r => readBrokerStatus(r.user, r.params.provider)));
  app.post('/api/portfolio/broker/questrade/connect', respond(r => {
    if (typeof r.body?.refreshToken !== 'string' || !r.body.refreshToken.trim()) throw error('questrade_invalid_token');
    return syncQuestrade(r.user, {refreshToken: r.body.refreshToken.trim()});
  }));
  app.post('/api/portfolio/broker/questrade/sync', respond(r => syncQuestrade(r.user)));
  app.post('/api/portfolio/broker/futu/pair', respond(r => pairFutu(r.user)));
  app.delete('/api/portfolio/broker/:provider', respond(r => disconnectBroker(r.user, r.params.provider)));
}

// Register before normal login middleware. This capability can ONLY upload one
// owner's Futu snapshot; it cannot read data or access any other application API.
export function mountFutuConnectorRoute(app) {
  app.post('/api/broker-connector/futu', (req, res) => {
    res.setHeader('Cache-Control', 'no-store');
    try {
      res.json(acceptFutuSnapshot(req.get('authorization')?.replace(/^Bearer /, ''), req.body));
    } catch (e) { res.status(e.code === 'connector_unauthorized' ? 401 : 400)
      .json({error: e.code || 'connector_snapshot_invalid'}); }
  });
}
