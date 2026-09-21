// Capital structure is not an investment-quality score. It describes the
// funding vehicle behind the manager-level 13F and, specifically, whether the
// disclosed book is insulated from outside-investor redemption pressure.
//
// Be conservative: "permanent" is reserved for structures confirmed by a
// primary source. A family office is owner-controlled, but the owner can still
// reallocate or distribute capital. A manager with both closed- and open-ended
// mandates is "mixed" because a firm-level 13F cannot attribute each holding to
// one sleeve.

const permanent = {
  "warren-buffett": {
    form: "corporate_insurance_balance_sheet",
    detail: "Berkshire corporate capital and insurance float; no fund-investor redemption mechanism.",
    detailZh: "伯克希尔公司资本与保险浮存金，不存在基金投资者赎回机制。",
    evidenceUrl: "https://www.berkshirehathaway.com/2025ar/linksannual25.html"
  },
  "tom-gayner": {
    form: "corporate_insurance_balance_sheet",
    detail: "Markel corporate capital and insurance float support its public-equity portfolio.",
    detailZh: "Markel 的公司资本与保险浮存金支持其公开股票组合。",
    evidenceUrl: "https://www.markel.com/investor-relations"
  },
  "george-soros": {
    form: "family_foundation_permanent_capital",
    detail: "Soros Fund Management explicitly describes its family-office asset base as permanent capital.",
    detailZh: "Soros Fund Management 明确将其家族办公室资产基础称为永续资本。",
    evidenceUrl: "https://sorosfundmgmt.com/"
  },
  "chamath-palihapitiya": {
    form: "proprietary_technology_holding_company",
    detail: "Social Capital closed to outside capital in 2018 and identifies its proprietary asset base as permanent capital.",
    detailZh: "Social Capital 于 2018 年关闭外部资本，并明确将其自有资产基础定义为永续资本。",
    evidenceUrl: "https://www.socialcapital.com/ideas/2021-annual-letter"
  }
};

const mixed = {
  "bill-ackman": {
    form: "closed_end_and_other_manager_pools",
    detail: "Pershing Square manages the closed-ended PSH vehicle, but the manager-level 13F can aggregate other Pershing pools too.",
    detailZh: "Pershing Square 管理封闭式 PSH，但经理级 13F 也可能汇总其他 Pershing 资金池。",
    evidenceUrl: "https://pershingsquareholdings.com/"
  },
  "baillie-gifford": {
    form: "investment_trusts_and_open_ended_funds",
    detail: "Baillie Gifford manages both investment trusts and open-ended funds; its firm-level 13F cannot separate them.",
    detailZh: "Baillie Gifford 同时管理投资信托与开放式基金，机构级 13F 无法拆分归属。",
    evidenceUrl: "https://www.bailliegifford.com/en/uk/individual-investors/frequently-asked-questions/"
  }
};

const ownerControlled = {
  "stanley-druckenmiller": {
    form: "family_office",
    detail: "Duquesne is a family office: no ordinary outside-fund redemption queue, but owner capital is not legally locked forever.",
    detailZh: "Duquesne 是家族办公室：没有普通外部基金赎回队列，但所有者资本并非法律意义上永久锁定。",
    evidenceUrl: "https://www.sec.gov/edgar/browse/?CIK=1536411"
  },
  "david-tepper": {
    form: "owner_led_with_residual_external_capital",
    detail: "Appaloosa is owner-led and returned most outside capital, but public records do not support calling the whole manager-level filing strictly permanent.",
    detailZh: "Appaloosa 以所有者资本为主并返还了大部分外部资金，但公开记录不足以把整个经理级申报认定为严格永续。",
    evidenceUrl: "https://adviserinfo.sec.gov/firm/summary/281909"
  }
};

const archived = {
  "nick-sleep-qais-zakaria": {
    form: "closed_historical_partnership",
    detail: "Nomad is a closed historical partnership, not a current capital vehicle.",
    detailZh: "Nomad 是已经关闭的历史合伙基金，不是当前资本载体。",
    evidenceUrl: "https://www.sec.gov/edgar/browse/?CIK=1384801"
  }
};

const externalClientCapitalIds = new Set([
  "andreas-halvorsen", "brad-gerstner",
  "chase-coleman", "chris-bloomstran", "chris-hohn", "chuck-akre",
  "dan-loeb", "david-einhorn", "dev-kantesaria", "evan-mcgoff",
  "gavin-baker", "john-stamas", "li-lu", "michael-cuggino",
  "mohnish-pabrai", "nelson-peltz", "pat-dorsey", "philippe-laffont",
  "renaissance-technologies", "samantha-mclemore", "seth-klarman",
  "stan-moss", "terry-smith", "william-heard"
]);

const labels = {
  permanent: ["Permanent capital", "永续资本"],
  mixed: ["Mixed capital", "混合资本"],
  owner_controlled: ["Owner / family capital", "所有者 / 家族资本"],
  external_client: ["External / client capital", "外部 / 客户资本"],
  archived: ["Historical vehicle", "历史载体"],
  unclassified: ["Not classified", "尚未分类"]
};

export const GURU_CAPITAL_STRUCTURE_VERSION = "guru-capital-structure-v1-20260921";

export function guruCapitalStructure(guruOrId) {
  const id = String(typeof guruOrId === "object" ? guruOrId?.id || "" : guruOrId || "");
  let category = "unclassified", row = null;
  if (permanent[id]) { category = "permanent"; row = permanent[id]; }
  else if (mixed[id]) { category = "mixed"; row = mixed[id]; }
  else if (ownerControlled[id]) { category = "owner_controlled"; row = ownerControlled[id]; }
  else if (archived[id]) { category = "archived"; row = archived[id]; }
  else if (externalClientCapitalIds.has(id)) {
    category = "external_client";
    row = {
      form: "external_or_client_managed_capital",
      detail: "No verified permanent-capital basis for this manager-level 13F; outside-investor, fund or client mandates can create capital flows.",
      detailZh: "该经理级 13F 没有已核实的永续资本基础；外部投资者、基金或客户委托可能带来资金流动。",
      evidenceUrl: null
    };
  }
  return Object.freeze({
    version: GURU_CAPITAL_STRUCTURE_VERSION,
    category,
    permanentCapital: category === "permanent",
    label: labels[category][0],
    labelZh: labels[category][1],
    ...row
  });
}

export function assertCapitalStructureCoverage(catalog) {
  const missing = catalog
    .filter((guru) => guru.type === "manager13f")
    .filter((guru) => guruCapitalStructure(guru).category === "unclassified")
    .map((guru) => guru.id);
  if (missing.length) throw new Error(`unclassified_guru_capital_structure:${missing.join(",")}`);
  return true;
}
