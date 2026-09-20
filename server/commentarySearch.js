import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { XMLParser } from "fast-xml-parser";
import { gurus } from "./gurus.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const cacheDir = path.join(__dirname, "cache", "commentary");
const cacheTtlMs = 1000 * 60 * 60 * 12;

const xmlParser = new XMLParser({
  ignoreAttributes: false,
  attributeNamePrefix: "",
  trimValues: true
});

const directKeywords = [
  "said",
  "says",
  "interview",
  "remarks",
  "letter",
  "transcript",
  "podcast",
  "cnBC".toLowerCase(),
  "bloomberg",
  "conference",
  "quote",
  "tweet",
  "post",
  "shareholder",
  "annual meeting"
];

function toArray(value) {
  if (value === undefined || value === null) return [];
  return Array.isArray(value) ? value : [value];
}

function stringValue(value) {
  if (value === undefined || value === null) return "";
  return String(value).trim();
}

function numberValue(value) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : 0;
}

function dateValue(value) {
  const time = value ? new Date(value).getTime() : 0;
  return Number.isFinite(time) ? time : 0;
}

function isoDate(value) {
  if (!value) return "";
  return new Date(value).toISOString().slice(0, 10);
}

function addDays(value, days) {
  const date = new Date(value);
  date.setDate(date.getDate() + days);
  return date;
}

function gdeltDate(value) {
  return `${isoDate(value).replace(/-/g, "")}000000`;
}

function stripHtml(value) {
  return stringValue(value)
    .replace(/<[^>]*>/g, " ")
    .replace(/&nbsp;/g, " ")
    .replace(/&amp;/g, "&")
    .replace(/&#39;/g, "'")
    .replace(/&quot;/g, "\"")
    .replace(/\s+/g, " ")
    .trim();
}

function normalizeUrl(url) {
  return stringValue(url).replace(/^https?:\/\/news\.google\.com\/rss\/articles\//, "google-news:");
}

function cacheKey(payload) {
  return `${payload.guruId}-${payload.ticker}-${payload.date}-${payload.action}`
    .replace(/[^a-z0-9_.-]/gi, "_")
    .slice(0, 180);
}

async function readCache(key) {
  try {
    const filePath = path.join(cacheDir, `${key}.json`);
    const parsed = JSON.parse(await fs.readFile(filePath, "utf8"));
    if (Date.now() - new Date(parsed.generatedAt).getTime() < cacheTtlMs) return parsed;
  } catch {
    return null;
  }
  return null;
}

async function writeCache(key, payload) {
  await fs.mkdir(cacheDir, { recursive: true });
  await fs.writeFile(path.join(cacheDir, `${key}.json`), JSON.stringify(payload, null, 2));
}

function shortIssuer(value) {
  return stringValue(value)
    .replace(/\b(COMMON|STOCK|CLASS|ORDINARY|SHARES|INC|CORP|CORPORATION|LTD|PLC|LLC|CO)\b/gi, " ")
    .replace(/[^a-z0-9 .&-]/gi, " ")
    .replace(/\s+/g, " ")
    .trim()
    .split(" ")
    .slice(0, 4)
    .join(" ");
}

function operationWindow(operation) {
  const baseTime = dateValue(operation.date || operation.filingDate) || Date.now();
  const baseDate = new Date(baseTime);
  const filingTime = dateValue(operation.filingDate);
  const is13f = operation.disclosureKind === "13F-HR" || operation.source === "13F";
  const start = addDays(baseDate, is13f ? -100 : -60);
  const endSeed = filingTime ? new Date(filingTime) : baseDate;
  const end = addDays(endSeed, is13f ? 30 : 60);
  const today = new Date();
  return {
    start: isoDate(start),
    end: isoDate(end > today ? today : end)
  };
}

function buildSearchQuery(guru, operation, window) {
  const ticker = stringValue(operation.ticker).toUpperCase();
  const issuer = shortIssuer(operation.issuer);
  const quotedGuru = `"${guru.name}"`;
  const companyPart = issuer && issuer !== ticker ? `"${issuer}"` : ticker;
  const actionTerm = ["new", "increased", "buy"].includes(operation.action) ? "buy OR bullish OR stake" : "sell OR sale OR trim OR reduce";
  const managerName = guru.type === "manager13f" && guru.entityName ? `"${guru.entityName}"` : quotedGuru;
  const primaryName = guru.type === "manager13f" ? `${quotedGuru} OR ${managerName}` : quotedGuru;

  return `${primaryName} ${ticker} ${companyPart} (${actionTerm} OR interview OR said OR letter) after:${window.start} before:${window.end}`;
}

async function fetchGoogleNews(query) {
  const url = `https://news.google.com/rss/search?q=${encodeURIComponent(query)}&hl=en-US&gl=US&ceid=US:en`;
  const response = await fetch(url, {
    headers: {
      "User-Agent": "Mozilla/5.0 thesisforge/0.1",
      "Accept": "application/rss+xml,text/xml,*/*"
    }
  });

  if (!response.ok) throw new Error(`Google News RSS ${response.status}`);
  const parsed = xmlParser.parse(await response.text());
  return toArray(parsed.rss?.channel?.item).map((item) => {
    const rawTitle = stripHtml(item.title);
    const source = stripHtml(item.source?.["#text"] || item.source || rawTitle.split(" - ").at(-1));
    const title = rawTitle.replace(new RegExp(`\\s+-\\s+${source.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}$`), "");
    return {
      id: `google-${normalizeUrl(item.link || title)}`,
      provider: "Google News RSS",
      title: title || rawTitle,
      url: item.link || "",
      source,
      publishedAt: item.pubDate ? new Date(item.pubDate).toISOString() : "",
      snippet: stripHtml(item.description),
      language: "en"
    };
  });
}

async function fetchGdelt(query, window) {
  const url = new URL("https://api.gdeltproject.org/api/v2/doc/doc");
  url.searchParams.set("query", query.replace(/after:[0-9-]+|before:[0-9-]+/g, "").replace(/\s+/g, " ").trim());
  url.searchParams.set("mode", "ArtList");
  url.searchParams.set("format", "json");
  url.searchParams.set("maxrecords", "12");
  url.searchParams.set("sort", "datedesc");
  url.searchParams.set("startdatetime", gdeltDate(window.start));
  url.searchParams.set("enddatetime", gdeltDate(window.end));

  const response = await fetch(url, {
    headers: {
      "User-Agent": "Mozilla/5.0 thesisforge/0.1",
      "Accept": "application/json"
    }
  });

  if (!response.ok) throw new Error(`GDELT ${response.status}`);
  const json = await response.json();
  return toArray(json.articles).map((article) => ({
    id: `gdelt-${normalizeUrl(article.url || article.title)}`,
    provider: "GDELT DOC",
    title: stripHtml(article.title),
    url: article.url || "",
    source: article.domain || article.sourceCountry || "GDELT",
    publishedAt: article.seendate ? new Date(article.seendate).toISOString() : "",
    snippet: "",
    language: article.language || ""
  }));
}

function scoreArticle(article, guru, operation) {
  const text = `${article.title} ${article.snippet} ${article.source}`.toLowerCase();
  const guruName = guru.name.toLowerCase();
  const lastName = guruName.split(" ").at(-1);
  const ticker = stringValue(operation.ticker).toLowerCase();
  const issuer = shortIssuer(operation.issuer).toLowerCase();
  let score = 0;

  if (text.includes(guruName)) score += 5;
  else if (lastName && text.includes(lastName)) score += 3;
  if (ticker && text.includes(ticker)) score += 4;
  if (issuer && text.includes(issuer)) score += 3;
  if (directKeywords.some((keyword) => text.includes(keyword))) score += 3;
  if (article.provider === "GDELT DOC") score += 1;
  return score;
}

function dedupeArticles(articles) {
  const seen = new Set();
  const deduped = [];
  for (const article of articles) {
    const key = normalizeUrl(article.url) || article.title.toLowerCase();
    if (!key || seen.has(key)) continue;
    seen.add(key);
    deduped.push(article);
  }
  return deduped;
}

function evidenceLevel(articles, guru, operation) {
  const direct = articles.some((article) => {
    const text = `${article.title} ${article.snippet}`.toLowerCase();
    return scoreArticle(article, guru, operation) >= 9 && directKeywords.some((keyword) => text.includes(keyword));
  });
  if (direct) {
    return {
      level: "direct_or_near_direct",
      label: "找到接近直接发言",
      tone: "positive"
    };
  }

  if (articles.length) {
    return {
      level: "related_reporting",
      label: "找到相关报道",
      tone: "neutral"
    };
  }

  return {
    level: "inference_only",
    label: "未找到直接发言",
    tone: "muted"
  };
}

function rationaleHypothesis(guru, operation) {
  const action = operation.action;
  const ticker = stringValue(operation.ticker).toUpperCase();
  const priceLine = operation.selectedClose
    ? `披露日附近 ${ticker} 约 ${formatDollar(operation.selectedClose)}，SPY 约 ${formatDollar(operation.spyClose)}。`
    : "";

  if (guru.type === "manager13f") {
    if (["new", "increased"].includes(action)) {
      return `${priceLine} 13F 显示的是季度末持仓变化，较合理的研究假设是：该 manager 在这个季度把 ${ticker} 视为组合风险回报更优的方向，但精确买点和完整 thesis 需要结合访谈/信件验证。`;
    }
    return `${priceLine} 13F 的减仓/清仓更可能代表组合权重、风险预算或 thesis 变化；由于披露滞后，不能直接等同于披露日看空。`;
  }

  if (guru.type === "congress") {
    return `${priceLine} STOCK Act 披露通常是家庭交易和金额区间，不披露投资理由；如果没有同期公开发言，只能把它作为“在该市场环境下发生的交易线索”，不能归因到本人明确观点。`;
  }

  if (["sell", "reduced", "sold_out"].includes(action)) {
    return `${priceLine} Form 4 卖出常见原因包括 10b5-1 计划、税务/流动性、集中持仓降风险；除非找到同期采访或计划文件，否则不能简单解读为看空 ${ticker}。`;
  }

  return `${priceLine} Form 4 买入/授予/行权需要区分主动买入、股权激励和期权行权；可先把它当作所有权变化，再用公开发言检验真实动机。`;
}

function formatDollar(value) {
  if (!Number.isFinite(value) || value === 0) return "-";
  return `$${Math.abs(value) >= 1000 ? value.toFixed(0) : value.toFixed(2)}`;
}

function disclosureCaveat(guru, operation) {
  if (guru.type === "manager13f") {
    return "13F 只能看到季度末持仓和披露日，无法看到真实成交日、均价、空头、海外仓位或完整组合对冲。";
  }
  if (guru.type === "congress") {
    return "STOCK Act 是区间金额和延迟披露，通常无法确认交易执行人、精确价格和完整理由。";
  }
  if (operation.action === "sell") {
    return "Form 4 卖出可能来自预设交易计划或流动性安排，不能自动等同于投资观点转空。";
  }
  return "Form 4 说明所有权变化，但不同交易代码可能代表主动交易、行权、授予、税务扣缴或赠与。";
}

export async function loadOperationCommentary(guruId, rawOperation = {}) {
  const guru = gurus.find((item) => item.id === guruId);
  if (!guru) throw new Error("Guru not found");

  const operation = {
    ticker: stringValue(rawOperation.ticker).toUpperCase(),
    issuer: stringValue(rawOperation.issuer),
    action: stringValue(rawOperation.action || "other"),
    date: stringValue(rawOperation.date),
    filingDate: stringValue(rawOperation.filingDate),
    disclosureKind: stringValue(rawOperation.disclosureKind),
    source: stringValue(rawOperation.source),
    selectedClose: numberValue(rawOperation.selectedClose),
    spyClose: numberValue(rawOperation.spyClose)
  };
  if (!operation.ticker || !operation.date) throw new Error("Missing operation ticker/date");

  const window = operationWindow(operation);
  const key = cacheKey({ guruId, ...operation });
  const cached = await readCache(key);
  if (cached) return { ...cached, cache: "hit" };

  const query = buildSearchQuery(guru, operation, window);
  let articles = [];
  const errors = [];

  try {
    articles.push(...await fetchGoogleNews(query));
  } catch (error) {
    errors.push(error.message);
  }

  if (articles.length < 4) {
    try {
      articles.push(...await fetchGdelt(query, window));
    } catch (error) {
      errors.push(error.message);
    }
  }

  articles = dedupeArticles(articles)
    .map((article) => ({
      ...article,
      score: scoreArticle(article, guru, operation)
    }))
    .filter((article) => article.score >= 3)
    .sort((a, b) => b.score - a.score || dateValue(b.publishedAt) - dateValue(a.publishedAt))
    .slice(0, 8);

  const evidence = evidenceLevel(articles, guru, operation);
  const payload = {
    generatedAt: new Date().toISOString(),
    guru: {
      id: guru.id,
      name: guru.name,
      type: guru.type
    },
    operation,
    window,
    query,
    evidence,
    hypothesis: rationaleHypothesis(guru, operation),
    caveat: disclosureCaveat(guru, operation),
    articles,
    errors
  };

  await writeCache(key, payload);
  return { ...payload, cache: "refreshed" };
}
