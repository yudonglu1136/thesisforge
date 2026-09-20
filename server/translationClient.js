const translationCache = new Map();
const OPENAI_API_KEY = process.env.OPENAI_API_KEY || "";
const OPENAI_BASE_URL = process.env.OPENAI_BASE_URL || "https://api.openai.com/v1";
const OPENAI_TRANSLATION_MODEL =
  process.env.TRANSCRIPT_QA_TRANSLATION_MODEL ||
  process.env.OPENAI_TRANSLATION_MODEL ||
  "gpt-4o-mini";
const TRANSLATION_PROVIDER = String(process.env.TRANSCRIPT_QA_TRANSLATION_PROVIDER || "auto")
  .trim()
  .toLowerCase();

const FALLBACK_TRANSLATIONS = new Map([
  [
    "Management response context is not available in the structured transcript extract.",
    "当前结构化电话会文本没有提供管理层回答上下文。"
  ]
]);

const CHINESE_POLISH_REPLACEMENTS = [
  [/收益电话会议/g, "财报电话会"],
  [/收益电话/g, "财报电话会"],
  [/电话会议/g, "电话会"],
  [/该指南/g, "该指引"],
  [/指南反映/g, "指引反映"],
  [/指导反映/g, "指引反映"],
  [/前瞻性指导/g, "业绩指引"],
  [/指导/g, "指引"],
  [/资本支出/g, "CapEx"],
  [/自由现金流/g, "自由现金流"],
  [/现金流量/g, "现金流"],
  [/货币波动性/g, "汇率波动"],
  [/外汇波动性/g, "汇率波动"],
  [/增值服务/g, "增值服务"],
  [/苹果智能/g, "Apple Intelligence"],
  [/第一资本和发现/g, "Capital One 和 Discover"],
  [/第一资本/g, "Capital One"],
  [/第一季度的公民/g, "一季度的 Citizens 组合"],
  [/公民的投资组合/g, "Citizens 组合"],
  [/公民投资组合/g, "Citizens 组合"],
  [/公民组合/g, "Citizens 组合"],
  [/投资组合的重叠/g, "组合切换的同比基数影响"],
  [/富国银行/g, "Wells Fargo"],
  [/同比增长指标/g, "同比增速"],
  [/同比增长度量/g, "同比增速"],
  [/由于它关于同比基数影响/g, "关于同比基数影响"],
  [/它关于同比基数影响/g, "关于同比基数影响"],
  [/就研磨而言/g, "关于同比基数影响"],
  [/与研磨有关/g, "关于同比基数影响"],
  [/关于研磨/g, "关于同比基数影响"],
  [/研磨而言/g, "同比基数影响"],
  [/研磨项目/g, "基数项目"],
  [/研磨影响/g, "同比基数影响"],
  [/研磨/g, "同比基数影响"],
  [/搭接影响/g, "同比基数影响"],
  [/重叠影响/g, "同比基数影响"],
  [/将会继续进行同比基数影响/g, "同比基数影响会继续存在"],
  [/继续进行同比基数影响/g, "同比基数影响会继续存在"],
  [/如果您将这些基数项目标准化/g, "如果把这些基数项目标准化"],
  [/这就是对第四季度的绝对描述/g, "这是第四季度绝对增速口径的桥接"],
  [/帮助我们缓解第三季度的减速/g, "帮我们拆解一下三季度以来增长放缓的桥接因素"],
  [/指南/g, "指引"],
  [/由于它与重叠有关/g, "关于同比基数影响"],
  [/我们在 美国 管理层： Federal 的交易中有/g, "我们在美国联邦业务中有"],
  [/美国 管理层： Federal/g, "美国联邦业务"],
  [/U\. S\./g, "美国"],
  [/U\.S\./g, "美国"],
  [/管理响应上下文不可用/g, "管理层回答上下文不可用"]
];

function cleanText(value) {
  return String(value || "")
    .replace(/\r\n/g, "\n")
    .replace(/[ \t]+/g, " ")
    .trim();
}

function cacheKey(targetLanguage, text) {
  return `${targetLanguage}:${text}`;
}

function isMostlyChinese(value) {
  return /[\u3400-\u9fff]/.test(value);
}

function providerForRequest() {
  if (TRANSLATION_PROVIDER === "google" || TRANSLATION_PROVIDER === "google-translate") return "google";
  if (TRANSLATION_PROVIDER === "openai" || TRANSLATION_PROVIDER === "llm") {
    return OPENAI_API_KEY ? "openai" : "google";
  }
  return OPENAI_API_KEY ? "openai" : "google";
}

function splitForTranslation(value, maxChars = 3600) {
  const text = cleanText(value);
  if (text.length <= maxChars) return [text];
  const paragraphs = text.split(/\n{2,}/).map((part) => part.trim()).filter(Boolean);
  const chunks = [];
  let current = "";
  const pushCurrent = () => {
    if (current.trim()) chunks.push(current.trim());
    current = "";
  };
  for (const paragraph of paragraphs.length ? paragraphs : [text]) {
    if (paragraph.length > maxChars) {
      pushCurrent();
      const sentences = paragraph.match(/[^.!?。！？]+[.!?。！？]?/g) || [paragraph];
      for (const sentence of sentences) {
        if ((current + sentence).length > maxChars) pushCurrent();
        current = current ? `${current} ${sentence.trim()}` : sentence.trim();
      }
      continue;
    }
    if ((current + "\n\n" + paragraph).length > maxChars) pushCurrent();
    current = current ? `${current}\n\n${paragraph}` : paragraph;
  }
  pushCurrent();
  return chunks.length ? chunks : [text.slice(0, maxChars)];
}

function polishChineseTranslation(value) {
  let output = cleanText(value)
    .replace(/\s+([，。！？；：])/g, "$1")
    .replace(/([（【])\s+/g, "$1")
    .replace(/\s+([）】])/g, "$1")
    .replace(/\s{2,}/g, " ");
  for (const [pattern, replacement] of CHINESE_POLISH_REPLACEMENTS) {
    output = output.replace(pattern, replacement);
  }
  output = output
    .replace(/\bCEO\b/g, "CEO")
    .replace(/\bCFO\b/g, "CFO")
    .replace(/\bCOO\b/g, "COO")
    .replace(/Chief Executive Officer/g, "首席执行官")
    .replace(/Chief Financial Officer/g, "首席财务官")
    .replace(/Chief Operating Officer/g, "首席运营官")
    .replace(/Chairman and CEO/g, "董事长兼 CEO")
    .replace(/President and CEO/g, "总裁兼 CEO")
    .replace(/President, Chief Product Officer, and COO/g, "总裁、首席产品官兼 COO")
    .replace(/Management:/g, "管理层：")
    .replace(/Management：/g, "管理层：");
  return output.trim();
}

async function translateChunkWithGoogle(chunk) {
  const cleaned = cleanText(chunk);
  if (!cleaned || isMostlyChinese(cleaned)) return cleaned;
  const key = cacheKey("zh-CN:google", cleaned);
  if (translationCache.has(key)) return translationCache.get(key);

  const url = new URL("https://translate.googleapis.com/translate_a/single");
  url.searchParams.set("client", "gtx");
  url.searchParams.set("sl", "en");
  url.searchParams.set("tl", "zh-CN");
  url.searchParams.set("dt", "t");
  url.searchParams.set("q", cleaned);

  let lastError;
  for (let attempt = 0; attempt < 4; attempt += 1) {
    try {
      const response = await fetch(url, {
        headers: {
          "accept": "application/json,text/plain,*/*",
          "user-agent": "thesisforge/0.1"
        }
      });
      if (!response.ok) throw new Error(`translation upstream ${response.status}`);
      const payload = await response.json();
      const translated = Array.isArray(payload?.[0])
        ? payload[0].map((part) => part?.[0] || "").join("").trim()
        : "";
      if (!translated) throw new Error("translation upstream returned empty text");
      const polished = polishChineseTranslation(translated);
      translationCache.set(key, polished);
      return polished;
    } catch (error) {
      lastError = error;
      if (attempt < 3) await new Promise((resolve) => setTimeout(resolve, 250 * 2 ** attempt));
    }
  }
  throw lastError;
}

async function translateChunkWithOpenAI(chunk) {
  const cleaned = cleanText(chunk);
  if (!cleaned || isMostlyChinese(cleaned)) return cleaned;
  const directFallback = FALLBACK_TRANSLATIONS.get(cleaned);
  if (directFallback) return directFallback;
  const key = cacheKey(`zh-CN:openai:${OPENAI_TRANSLATION_MODEL}`, cleaned);
  if (translationCache.has(key)) return translationCache.get(key);

  const response = await fetch(`${OPENAI_BASE_URL.replace(/\/$/, "")}/chat/completions`, {
    method: "POST",
    headers: {
      "authorization": `Bearer ${OPENAI_API_KEY}`,
      "content-type": "application/json"
    },
    body: JSON.stringify({
      model: OPENAI_TRANSLATION_MODEL,
      temperature: 0.1,
      messages: [
        {
          role: "system",
          content: [
            "You are a senior bilingual financial editor translating US earnings-call transcript Q&A into polished Simplified Chinese for a buy-side investment terminal.",
            "Translate faithfully. Do not summarize, omit, add, or explain.",
            "Preserve all numbers, dates, percentages, dollar amounts, tickers, product names, company names, and acronyms such as ARR, RPO, ACV, CapEx, FCF, FX, GMV, AUM, EPS, M&A.",
            "Use natural institutional-investor Chinese. Prefer terms such as 指引, 同比基数影响, 汇率波动, 自由现金流, 增值服务, 续费率, 新签 ACV where appropriate.",
            "For speaker labels, keep the person's English name, translate role titles into Chinese, and use a Chinese colon.",
            "Return only the Chinese translation."
          ].join("\n")
        },
        {
          role: "user",
          content: `Translate this earnings-call Q&A text into Simplified Chinese:\n\n${cleaned}`
        }
      ]
    })
  });
  if (!response.ok) {
    const body = await response.text().catch(() => "");
    throw new Error(`openai translation upstream ${response.status}${body ? `: ${body.slice(0, 180)}` : ""}`);
  }
  const payload = await response.json();
  const translated = cleanText(payload?.choices?.[0]?.message?.content || "");
  if (!translated) throw new Error("openai translation upstream returned empty text");
  const polished = polishChineseTranslation(translated);
  translationCache.set(key, polished);
  return polished;
}

async function translateChunkToChinese(chunk) {
  const cleaned = cleanText(chunk);
  if (!cleaned || isMostlyChinese(cleaned)) return cleaned;
  const directFallback = FALLBACK_TRANSLATIONS.get(cleaned);
  if (directFallback) return directFallback;
  const provider = providerForRequest();
  if (provider === "openai") {
    try {
      return await translateChunkWithOpenAI(cleaned);
    } catch (error) {
      if (TRANSLATION_PROVIDER === "openai" || TRANSLATION_PROVIDER === "llm") throw error;
      console.warn(`openai translation failed; falling back to google: ${error.message}`);
    }
  }
  return translateChunkWithGoogle(cleaned);
}

export async function translateTextToChinese(value) {
  const source = cleanText(value);
  if (!source || isMostlyChinese(source)) return source;
  const directFallback = FALLBACK_TRANSLATIONS.get(source);
  if (directFallback) return directFallback;
  const provider = providerForRequest();
  const key = cacheKey(`zh-CN:${provider}:${OPENAI_TRANSLATION_MODEL}`, source);
  if (translationCache.has(key)) return translationCache.get(key);
  const chunks = splitForTranslation(source, provider === "openai" ? 5200 : 3600);
  const translatedChunks = [];
  for (const chunk of chunks) {
    translatedChunks.push(await translateChunkToChinese(chunk));
  }
  const translated = polishChineseTranslation(translatedChunks.join("\n\n"));
  translationCache.set(key, translated);
  return translated;
}

export async function translateTextsToChinese(texts) {
  const normalized = Array.isArray(texts)
    ? texts.map(cleanText).filter(Boolean).slice(0, 24)
    : [];
  const unique = [...new Set(normalized)];
  const translatedBySource = new Map();
  for (const source of unique) {
    translatedBySource.set(source, await translateTextToChinese(source));
  }
  return normalized.map((source) => ({
    source,
    translated: translatedBySource.get(source) || source
  }));
}
