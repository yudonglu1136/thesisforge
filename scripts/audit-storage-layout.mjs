import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const problems = [];
const warnings = [];
const ignored = new Set([
  ".git", ".dart_tool", ".venv-fact-os", "build", "dist", "node_modules"
]);

function walk(directory, visit) {
  if (!fs.existsSync(directory)) return;
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    if (entry.isDirectory() && ignored.has(entry.name)) continue;
    const file = path.join(directory, entry.name);
    if (entry.isDirectory()) walk(file, visit);
    else if (entry.isFile()) visit(file);
  }
}

const relative = (file) => path.relative(root, file).split(path.sep).join("/");
const runtimeRoot = path.join(root, "server", "data");
const factRoot = path.join(root, "data", "fact_os");

walk(root, (file) => {
  const rel = relative(file);
  const lower = rel.toLowerCase();
  const databaseLike = /\.(?:sqlite(?:3)?|db)(?:-(?:wal|shm))?$/.test(lower);
  const bulkLike = databaseLike || /\.(?:parquet|duckdb|zip)$/.test(lower);
  if (bulkLike && (rel.startsWith("output/") || rel.startsWith("outputs/") || rel.startsWith("docs/"))) {
    problems.push(`bulk artifact outside canonical data roots: ${rel}`);
  }
  if (databaseLike && file.startsWith(runtimeRoot + path.sep)) {
    const allowed = /^server\/data\/guru-analysis\.sqlite(?:-(?:wal|shm))?$/.test(rel) ||
      rel.startsWith("server/data/user-portfolios/") ||
      rel.startsWith("server/data/private-recovery/by-sha/");
    if (!allowed) problems.push(`unexpected runtime database: ${rel}`);
  }
});

for (const required of [
  path.join(factRoot, "manifests", "catalog.json"),
  path.join(root, "server", "data", "guru-analysis.sqlite"),
  path.join(root, "server", "data", "user-portfolios")
]) {
  if (!fs.existsSync(required)) problems.push(`missing canonical path: ${relative(required)}`);
}

const legacyFactBackup = path.join(factRoot, "legacy_backup");
if (fs.existsSync(legacyFactBackup)) problems.push("legacy full-database backup remains inside Fact OS");

const siblingNames = new Set([
  "fundamental-analysis", "fundamental-analysis-sp500", "guru-intelligence",
  "guru-analysis-dashboard", "jansen_us_firm_replication"
]);
const retiredSiblingPatterns = [
  /^guidance-audit-\d{8}$/,
  /^portfolio-refresh-\d{8}$/,
  /^investment-(?:composition-prices|market|prices)-/,
  /^strategy-(?:current|data-repair|filing-freshness|full-investment|market-refresh|september10)-/,
  /^tf-investment-public-release\./,
  /^thesisforge-(?:first-open-performance|ontology-retirement|private-)/
];
for (const entry of fs.readdirSync(path.dirname(root), { withFileTypes: true })) {
  if (
    entry.isDirectory() &&
    (siblingNames.has(entry.name) || retiredSiblingPatterns.some((pattern) => pattern.test(entry.name)))
  ) {
    problems.push(`retired sibling project still exists: ${entry.name}`);
  }
}

const report = {
  status: problems.length ? "fail" : "pass",
  root,
  canonical: {
    factOs: relative(factRoot),
    runtimeDatabase: "server/data/guru-analysis.sqlite",
    privatePortfolios: "server/data/user-portfolios",
    privateRecovery: "server/data/private-recovery/by-sha"
  },
  problems,
  warnings
};
console.log(JSON.stringify(report, null, 2));
if (problems.length) process.exitCode = 1;
