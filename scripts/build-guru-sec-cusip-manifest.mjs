#!/usr/bin/env node
/**
 * Build the Guru security-master input manifest directly from official SEC
 * submissions and filing information tables.
 *
 * This deliberately does not read guru_snapshots, guru_backtests, or any other
 * derived application cache. Every observed CUSIP is tied to an accession,
 * document URL, and SHA-256 digest fetched from sec.gov.
 */

import crypto from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import { XMLParser } from "fast-xml-parser";
import { gurus } from "../server/gurus.js";
import { is13fCommonLongHolding } from "../server/thirteenF.js";

const DEFAULT_START_REPORT_DATE = "2021-03-31";
const HOLDING_SELECTION_POLICY =
  "top_60_common_long_shares_excluding_explicit_non_common_titles_by_reported_value_per_filing";
const SEC_ARCHIVES = "https://www.sec.gov/Archives/edgar/data";
const SEC_SUBMISSIONS = "https://data.sec.gov/submissions";
const DEFAULT_USER_AGENT = "ThesisForge research engineering contact@thesisforge.tech";

const parser = new XMLParser({
  ignoreAttributes: false,
  attributeNamePrefix: "",
  parseTagValue: false,
  removeNSPrefix: true,
  trimValues: true
});

function usage(message = "") {
  if (message) process.stderr.write(`${message}\n\n`);
  process.stderr.write(
    "Usage: node scripts/build-guru-sec-cusip-manifest.mjs " +
    "--output <json> --generated-at <ISO> [--start-report-date YYYY-MM-DD] " +
    "[--end-report-date YYYY-MM-DD] [--include-disabled] [--request-delay-ms 125] " +
    "[--response-cache-dir <untracked-dir>] [--manager-ids <comma-separated-IDs>]\n"
  );
  process.exit(message ? 2 : 0);
}

export function parseArgs(argv) {
  const args = {
    startReportDate: DEFAULT_START_REPORT_DATE,
    endReportDate: "9999-12-31",
    includeDisabled: false,
    requestDelayMs: 125,
    responseCacheDir: ""
  };
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    const next = () => {
      const value = argv[index + 1];
      if (!value || value.startsWith("--")) usage(`Missing value for ${token}`);
      index += 1;
      return value;
    };
    if (token === "--output") args.output = next();
    else if (token === "--generated-at") args.generatedAt = next();
    else if (token === "--start-report-date") args.startReportDate = next();
    else if (token === "--end-report-date") args.endReportDate = next();
    else if (token === "--request-delay-ms") args.requestDelayMs = Number(next());
    else if (token === "--response-cache-dir") args.responseCacheDir = next();
    else if (token === "--manager-ids") args.managerIds = next().split(",");
    else if (token === "--include-disabled") args.includeDisabled = true;
    else if (token === "--help" || token === "-h") usage();
    else usage(`Unknown argument: ${token}`);
  }
  if (!args.output) usage("--output is required");
  if (!args.generatedAt || !Number.isFinite(Date.parse(args.generatedAt))) {
    usage("--generated-at must be a valid, fixed ISO timestamp");
  }
  if (Date.parse(args.generatedAt) > Date.now() + 5 * 60 * 1000) {
    usage("--generated-at cannot be more than five minutes in the future");
  }
  if (!/^\d{4}-\d{2}-\d{2}$/.test(args.startReportDate) ||
      !/^\d{4}-\d{2}-\d{2}$/.test(args.endReportDate)) {
    usage("report dates must use YYYY-MM-DD");
  }
  if (!Number.isFinite(args.requestDelayMs) || args.requestDelayMs < 100) {
    usage("--request-delay-ms must be at least 100ms to respect SEC fair-access limits");
  }
  if (args.managerIds && (new Set(args.managerIds).size !== args.managerIds.length ||
      args.managerIds.some(id => !gurus.some(guru => guru.id === id && guru.type === "manager13f" &&
        (args.includeDisabled || !guru.disableSimulation))))) usage("--manager-ids must contain distinct eligible manager13f IDs");
  return args;
}

function sha256(value) {
  return crypto.createHash("sha256").update(value).digest("hex");
}

function stableJson(value) {
  if (Array.isArray(value)) return `[${value.map(stableJson).join(",")}]`;
  if (value && typeof value === "object") {
    return `{${Object.keys(value).sort().map((key) =>
      `${JSON.stringify(key)}:${stableJson(value[key])}`
    ).join(",")}}`;
  }
  return JSON.stringify(value);
}

function toArray(value) {
  if (value === undefined || value === null) return [];
  return Array.isArray(value) ? value : [value];
}

function valueOf(value) {
  if (value && typeof value === "object" && "value" in value) return valueOf(value.value);
  return String(value ?? "").trim();
}

function numberValue(value) {
  const parsed = Number(valueOf(value).replace(/,/g, ""));
  return Number.isFinite(parsed) ? parsed : 0;
}

function normalizeCusip(value) {
  const cusip = valueOf(value).toUpperCase().replace(/\s+/g, "");
  return /^[0-9A-Z]{8,9}$/.test(cusip) ? cusip : "";
}

function cikPath(cik) {
  return String(cik).replace(/^0+/, "");
}

function accessionPath(accession) {
  return String(accession).replace(/-/g, "");
}

function recentRows(payload) {
  const recent = payload?.filings?.recent || payload?.recent || payload || {};
  return toArray(recent.form).map((form, index) => ({
    form: String(form || "").trim(),
    accessionNumber: recent.accessionNumber?.[index] || "",
    filingDate: recent.filingDate?.[index] || "",
    reportDate: recent.reportDate?.[index] || "",
    primaryDocument: recent.primaryDocument?.[index] || ""
  }));
}

function findInfoTable(root) {
  if (!root || typeof root !== "object") return [];
  if (root.infoTable !== undefined) return toArray(root.infoTable);
  for (const value of Object.values(root)) {
    const result = findInfoTable(value);
    if (result.length) return result;
  }
  return [];
}

export function holdingsFromInformationTable(xml) {
  const parsed = parser.parse(xml);
  const rows = findInfoTable(parsed);
  return rows
    .map((row) => ({
      cusip: normalizeCusip(row?.cusip),
      issuer: valueOf(row?.nameOfIssuer).replace(/\s+/g, " ").trim(),
      title: valueOf(row?.titleOfClass).replace(/\s+/g, " ").trim(),
      putCall: valueOf(row?.putCall).toUpperCase(),
      shareType: valueOf(row?.shrsOrPrnAmt?.sshPrnamtType).toUpperCase(),
      reportedValue: numberValue(row?.value)
    }))
    .filter((row) => row.cusip)
    .sort((left, right) =>
      left.cusip.localeCompare(right.cusip) ||
      left.issuer.localeCompare(right.issuer) ||
      left.title.localeCompare(right.title)
    );
}

export function cusipsFromInformationTable(xml) {
  return [...new Set(holdingsFromInformationTable(xml).map((row) => row.cusip))].sort();
}

export function selectTopCommonLongHoldings(reportedHoldings, limit = 60) {
  const commonLongByCusip = new Map();
  for (const holding of reportedHoldings.filter(is13fCommonLongHolding)) {
    const aggregate = commonLongByCusip.get(holding.cusip) || {
      cusip: holding.cusip,
      issuerNames: new Set(),
      titles: new Set(),
      reportedValue: 0
    };
    if (holding.issuer) aggregate.issuerNames.add(holding.issuer);
    if (holding.title) aggregate.titles.add(holding.title);
    aggregate.reportedValue += holding.reportedValue;
    commonLongByCusip.set(holding.cusip, aggregate);
  }
  return [...commonLongByCusip.values()]
    .sort((left, right) =>
      right.reportedValue - left.reportedValue ||
      left.cusip.localeCompare(right.cusip)
    )
    .slice(0, limit);
}

function chooseInformationTableDocument(items, primaryDocument) {
  const names = items.map((item) => String(item?.name || "")).filter(Boolean);
  const primaryBase = path.basename(primaryDocument || "");
  const xml = names.filter((name) => /\.xml$/i.test(name));
  const nonPrimary = xml.filter((name) => name !== primaryDocument && name !== primaryBase);
  return nonPrimary.find((name) => /infotable|information.?table|13f|q[1-4]/i.test(name)) ||
    nonPrimary[0] ||
    xml.find((name) => /infotable|information.?table/i.test(name)) ||
    "";
}

export function informationTableFromSubmissionText(submissionText) {
  const documents = String(submissionText || "").match(/<DOCUMENT>[\s\S]*?<\/DOCUMENT>/gi) || [];
  for (const document of documents) {
    const type = document.match(/<TYPE>\s*([^\r\n<]+)/i)?.[1]?.trim() || "";
    if (!/^INFORMATION\s+TABLE$/i.test(type)) continue;
    const documentName = document.match(/<FILENAME>\s*([^\r\n<]+)/i)?.[1]?.trim() || "";
    const xml = document.match(/<XML>\s*([\s\S]*?)\s*<\/XML>/i)?.[1]?.trim() || "";
    if (xml) return { documentName, xml };
  }
  return null;
}

function managerRows(includeDisabled) {
  return gurus
    .filter((guru) => guru.type === "manager13f")
    .filter((guru) => includeDisabled || !guru.disableSimulation)
    .map((guru) => ({
      id: guru.id,
      ciks: [...new Set([guru.cik, ...(guru.alternateCiks || [])].filter(Boolean))].sort()
    }))
    .sort((left, right) => left.id.localeCompare(right.id));
}

export async function main(argv = process.argv.slice(2)) {
  const args = parseArgs(argv);
  const userAgent = process.env.SEC_USER_AGENT || DEFAULT_USER_AGENT;
  const responseCacheDir = args.responseCacheDir ? path.resolve(args.responseCacheDir) : "";
  let lastRequestAt = 0;
  const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
  const cachedFetch = async (url, accept) => {
    const cachePath = responseCacheDir
      ? path.join(responseCacheDir, `${sha256(url)}.response`)
      : "";
    if (cachePath) {
      try {
        return await fs.readFile(cachePath, "utf8");
      } catch {
        // A cache miss is expected on the first direct-source audit.
      }
    }
    for (let attempt = 0; attempt < 5; attempt += 1) {
      const remaining = args.requestDelayMs - (Date.now() - lastRequestAt);
      if (remaining > 0) await sleep(remaining);
      const response = await fetch(url, {
        headers: { "User-Agent": userAgent, "Accept": accept }
      });
      lastRequestAt = Date.now();
      if (response.ok) {
        const body = await response.text();
        if (cachePath) {
          await fs.mkdir(path.dirname(cachePath), { recursive: true });
          await fs.writeFile(cachePath, body, "utf8");
        }
        return body;
      }
      const retryable = response.status === 429 || response.status >= 500;
      if (!retryable || attempt === 4) {
        throw new Error(`SEC request failed ${response.status}: ${url}`);
      }
      const retryAfterSeconds = Number(response.headers.get("retry-after"));
      const retryDelayMs = Number.isFinite(retryAfterSeconds) && retryAfterSeconds > 0
        ? retryAfterSeconds * 1000
        : Math.min(8_000, 500 * (2 ** attempt));
      await sleep(retryDelayMs);
    }
    throw new Error(`SEC request failed after retries: ${url}`);
  };
  const fetchJson = async (url) => {
    return JSON.parse(await cachedFetch(url, "application/json, text/plain, */*"));
  };
  const fetchText = async (url) => {
    return cachedFetch(url, "text/xml, text/plain, */*");
  };

  const selectedManagers = managerRows(args.includeDisabled)
    .filter(manager => !args.managerIds || args.managerIds.includes(manager.id));
  const filings = [];
  const cusipObservations = new Map();

  for (const manager of selectedManagers) {
    for (const cik of manager.ciks) {
      const submissionUrl = `${SEC_SUBMISSIONS}/CIK${cik}.json`;
      const submission = await fetchJson(submissionUrl);
      const allRows = recentRows(submission);
      for (const shard of toArray(submission?.filings?.files)) {
        const name = String(shard?.name || "").trim();
        if (!name) continue;
        allRows.push(...recentRows(await fetchJson(`${SEC_SUBMISSIONS}/${name}`)));
      }
      const unique = new Map();
      for (const row of allRows) {
        if (!/^13F-HR(?:\/A)?$/i.test(row.form)) continue;
        if (!row.reportDate || row.reportDate < args.startReportDate ||
            row.reportDate > args.endReportDate) continue;
        if (!row.accessionNumber) continue;
        unique.set(row.accessionNumber, row);
      }
      for (const row of [...unique.values()].sort((left, right) =>
        left.accessionNumber.localeCompare(right.accessionNumber)
      )) {
        const baseUrl = `${SEC_ARCHIVES}/${cikPath(cik)}/${accessionPath(row.accessionNumber)}`;
        const indexUrl = `${baseUrl}/index.json`;
        const index = await fetchJson(indexUrl);
        let documentName = chooseInformationTableDocument(
          toArray(index?.directory?.item), row.primaryDocument
        );
        let documentUrl = "";
        let documentHashScope = "document_body";
        let documentContainerSha256 = "";
        let xml = "";
        if (documentName) {
          documentUrl = `${baseUrl}/${documentName}`;
          xml = await fetchText(documentUrl);
        } else {
          const submissionUrl = `${baseUrl}/${row.accessionNumber}.txt`;
          const submissionText = await fetchText(submissionUrl);
          const embedded = informationTableFromSubmissionText(submissionText);
          if (!embedded) {
            throw new Error(`No information-table XML for ${manager.id} ${row.accessionNumber}`);
          }
          documentName = embedded.documentName || `${row.accessionNumber}.txt`;
          if (embedded.documentName) {
            const embeddedDocumentUrl = `${baseUrl}/${embedded.documentName}`;
            try {
              const directXml = await fetchText(embeddedDocumentUrl);
              if (holdingsFromInformationTable(directXml).length) {
                documentUrl = embeddedDocumentUrl;
                xml = directXml;
              }
            } catch {
              // Some legacy submissions expose the table only inside the full filing text.
            }
          }
          if (!xml) {
            documentUrl = submissionUrl;
            documentHashScope = "embedded_information_table_xml";
            documentContainerSha256 = sha256(submissionText);
            xml = embedded.xml;
          }
        }
        const reportedHoldings = holdingsFromInformationTable(xml);
        const holdings = selectTopCommonLongHoldings(reportedHoldings, 60);
        const cusips = [...new Set(holdings.map((holding) => holding.cusip))].sort();
        const selectedCommonLongValue = holdings.reduce(
          (sum, holding) => sum + holding.reportedValue,
          0
        );
        if (!cusips.length) {
          throw new Error(`No valid CUSIPs in ${manager.id} ${row.accessionNumber} ${documentUrl}`);
        }
        filings.push({
          managerId: manager.id,
          cik,
          accessionNumber: row.accessionNumber,
          form: row.form,
          reportDate: row.reportDate,
          filingDate: row.filingDate,
          documentName,
          documentUrl,
          documentHashScope,
          documentSha256: sha256(xml),
          ...(documentContainerSha256 ? { documentContainerSha256 } : {}),
          reportedCusipCount: new Set(reportedHoldings.map((holding) => holding.cusip)).size,
          selectedCommonLongCusipCount: cusips.length,
          selectedCommonLongReportedValue: selectedCommonLongValue
        });
        for (const holding of holdings) {
          const { cusip } = holding;
          const observation = cusipObservations.get(cusip) || {
            cusip,
            managerIds: new Set(),
            accessions: new Set(),
            issuerNames: new Set(),
            titles: new Set(),
            maxSelectedWeightPpm: 0,
            firstReportDate: row.reportDate,
            lastReportDate: row.reportDate
          };
          observation.managerIds.add(manager.id);
          observation.accessions.add(row.accessionNumber);
          for (const issuer of holding.issuerNames) observation.issuerNames.add(issuer);
          for (const title of holding.titles) observation.titles.add(title);
          const selectedWeight = selectedCommonLongValue > 0
            ? holding.reportedValue / selectedCommonLongValue
            : 0;
          observation.maxSelectedWeightPpm = Math.max(
            observation.maxSelectedWeightPpm,
            Math.round(selectedWeight * 1_000_000)
          );
          observation.firstReportDate = [observation.firstReportDate, row.reportDate].sort()[0];
          observation.lastReportDate = [observation.lastReportDate, row.reportDate].sort().at(-1);
          cusipObservations.set(cusip, observation);
        }
      }
    }
  }

  filings.sort((left, right) =>
    left.managerId.localeCompare(right.managerId) ||
    left.reportDate.localeCompare(right.reportDate) ||
    left.accessionNumber.localeCompare(right.accessionNumber)
  );
  const cusips = [...cusipObservations.values()]
    .map((row) => ({
      cusip: row.cusip,
      managerIds: [...row.managerIds].sort(),
      issuerNames: [...row.issuerNames].sort(),
      titles: [...row.titles].sort(),
      observationCount: row.accessions.size,
      maxSelectedWeightPpm: row.maxSelectedWeightPpm,
      firstReportDate: row.firstReportDate,
      lastReportDate: row.lastReportDate
    }))
    .sort((left, right) => left.cusip.localeCompare(right.cusip));

  const records = { managers: selectedManagers, filings, cusips };
  const payload = {
    schemaVersion: 1,
    generatedAt: new Date(args.generatedAt).toISOString(),
    sourcePolicy: "direct_official_sec_submissions_and_archive_documents_no_derived_cache",
    holdingSelectionPolicy: HOLDING_SELECTION_POLICY,
    source: {
      provider: "U.S. Securities and Exchange Commission",
      submissionsBaseUrl: SEC_SUBMISSIONS,
      archivesBaseUrl: SEC_ARCHIVES,
      fairAccessPolicyUrl: "https://www.sec.gov/about/developer-resources"
    },
    window: {
      startReportDate: args.startReportDate,
      endReportDate: args.endReportDate,
      includeDisabledManagers: args.includeDisabled
    },
    selection: {
      managerCount: selectedManagers.length,
      filerCikCount: selectedManagers.reduce((sum, manager) => sum + manager.ciks.length, 0),
      filingCount: filings.length,
      observedCusips: cusips.length
    },
    recordsSha256: sha256(stableJson(records)),
    ...records
  };
  await fs.mkdir(path.dirname(path.resolve(args.output)), { recursive: true });
  await fs.writeFile(args.output, `${JSON.stringify(payload, null, 2)}\n`, "utf8");
  process.stdout.write(`${JSON.stringify({
    output: path.resolve(args.output),
    ...payload.selection,
    recordsSha256: payload.recordsSha256
  })}\n`);
}

const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : "";
if (invokedPath === fileURLToPath(import.meta.url)) {
  main().catch((error) => {
    process.stderr.write(`${error.stack || error.message}\n`);
    process.exit(1);
  });
}
