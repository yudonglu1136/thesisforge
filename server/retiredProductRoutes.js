// Product retirement is explicit: old clients must not reach the abandoned
// snapshot service or accidentally receive the current application's HTML.
const retiredPrefixes = [
  '/api/ontology', '/api/dbmf', '/api/strategies', '/api/decision', '/api/market'
];
const retiredExactPaths = new Set([
  '/api/overview', '/api/graph', '/api/methodology', '/api/timeline',
  '/api/rankings', '/api/snapshot', '/api/investment/value-flow'
]);

export function isRetiredApiPath(value) {
  let pathname = String(value ?? '').split(/[?#]/, 1)[0];
  try { pathname = decodeURIComponent(pathname); } catch { return false; }
  pathname = pathname.toLowerCase().replace(/\/+$/, '');
  return retiredExactPaths.has(pathname)
    || retiredPrefixes.some(prefix => pathname === prefix || pathname.startsWith(`${prefix}/`))
    || /^\/api\/company\/[^/]+$/.test(pathname);
}

export function registerRetiredProductRoutes(app) {
  app.use((request, response, next) => {
    if (!isRetiredApiPath(request.path)) return next();
    response.setHeader('Cache-Control', 'no-store');
    return response.status(410).json({ error: 'module_retired' });
  });
}
