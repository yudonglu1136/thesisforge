// Optional, additive accelerators for the exact existing health summaries.
// Installation is an explicit maintenance operation, never a request/startup
// side effect. SQLite maintains these indexes in the same transaction as data.
export const valuationHealthSourceDate = `COALESCE(
  NULLIF(json_extract(payload_json, '$.history[#-1].asOfDate'), ''),
  NULLIF(json_extract(payload_json, '$.latest.asOfDate'), '')
)`;

export const databaseHealthIndexes = Object.freeze([
  { name: "tf_health_v1_valuation_generated", table: "valuation_ticker_snapshots", expression: "generated_at" },
  { name: "tf_health_v1_valuation_source", table: "valuation_ticker_snapshots", expression: valuationHealthSourceDate },
  { name: "tf_health_v1_prices_updated", table: "price_points", expression: "updated_at" },
  { name: "tf_health_v1_prices_date", table: "price_points", expression: "date" }
].map((spec) => Object.freeze({
  ...spec,
  sql: `CREATE INDEX ${spec.name} ON ${spec.table} (${spec.expression})`
})));

// SQLite ignores keyword case and whitespace outside tokens, including around
// parentheses. Compare tokens rather than stored SQL formatting. Quoted JSON
// paths/string literals remain byte-exact: lowercasing them changes semantics.
const normalizeSql = (sql) => (String(sql || "").match(
  /'(?:''|[^'])*'|"(?:""|[^"])*"|`(?:``|[^`])*`|\[[^\]]*\]|[A-Za-z_][A-Za-z0-9_]*|\d+|[^\s]/g
) || []).map(token => /^[A-Za-z_]/.test(token) ? token.toLowerCase() : token).join(" ");

export function inspectDatabaseHealthIndexes(db) {
  const entries = new Map(db.prepare(
    "SELECT name, tbl_name, sql FROM sqlite_schema WHERE type = 'index' AND name LIKE 'tf_health_v1_%'"
  ).all().map((row) => [row.name, row]));
  return databaseHealthIndexes.map((spec) => {
    const actual = entries.get(spec.name);
    return {
      name: spec.name,
      table: spec.table,
      state: !actual ? "missing"
        : actual.tbl_name === spec.table && normalizeSql(actual.sql) === normalizeSql(spec.sql)
          ? "ready" : "incompatible"
    };
  });
}

/** Explicit operator-only migration: all four indexes install atomically. */
export function installDatabaseHealthIndexes(db) {
  db.exec("BEGIN IMMEDIATE");
  try {
    const before = inspectDatabaseHealthIndexes(db);
    if (before.some((row) => row.state === "incompatible")) {
      throw new Error("Health index name has an incompatible definition; no indexes were replaced");
    }
    const created = [];
    for (const [index, spec] of databaseHealthIndexes.entries()) {
      if (before[index].state === "ready") continue;
      db.exec(spec.sql);
      created.push(spec.name);
    }
    const after = inspectDatabaseHealthIndexes(db);
    if (after.some((row) => row.state !== "ready")) throw new Error("Health index validation failed");
    db.exec("COMMIT");
    return { version: 1, created, indexes: after };
  } catch (error) {
    db.exec("ROLLBACK");
    throw error;
  }
}
