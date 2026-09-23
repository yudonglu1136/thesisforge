export const gurus = [
  {
    id: "jeff-bezos",
    name: "Jeff Bezos",
    chineseName: "贝索斯",
    entityName: "BEZOS JEFFREY P",
    cik: "0001043298",
    type: "insider",
    focusTicker: "AMZN",
    focusIssuer: "Amazon.com",
    role: "Amazon founder / executive chair",
    thesisTag: "Founder-controlled liquidity",
    excludeFromHeatmap: true,
    heatmapExclusionReason: "company founder / control-holder ownership distorts external consensus",
    notes: [
      "Personal insiders disclose transactions on Form 4 instead of quarterly 13F portfolio reports.",
      "For Bezos, the app tracks recent AMZN Form 4 transactions and post-transaction share counts."
    ]
  },
  {
    id: "elon-musk",
    name: "Elon Musk",
    chineseName: "马斯克",
    entityName: "MUSK ELON",
    cik: "0001494730",
    type: "insider",
    focusTicker: "TSLA",
    focusIssuer: "Tesla",
    role: "Tesla CEO / controlling owner",
    thesisTag: "Control holder + liquidity signals",
    excludeFromHeatmap: true,
    heatmapExclusionReason: "company founder / control-holder ownership distorts external consensus",
    notes: [
      "Musk's public-company trading disclosures are Form 4 filings, not 13F filings.",
      "The feed can include non-TSLA issuer disclosures when SEC links them to the same reporting owner CIK."
    ]
  },
  {
    id: "gavin-baker",
    name: "Gavin Baker",
    chineseName: "加文·贝克",
    entityName: "Atreides Management, LP",
    cik: "0001777813",
    type: "manager13f",
    role: "Atreides Management",
    thesisTag: "Tech and growth public equities",
    notes: [
      "Atreides files quarterly Form 13F-HR reports. Changes are computed against the prior 13F quarter."
    ]
  },
  {
    id: "renaissance-technologies",
    name: "Renaissance Technologies",
    chineseName: "文艺复兴科技",
    entityName: "RENAISSANCE TECHNOLOGIES LLC",
    cik: "0001037389",
    type: "manager13f",
    role: "Quantitative investment manager / public 13F proxy",
    thesisTag: "Systematic multi-factor U.S. long-equity disclosure",
    simulationNote:
      "Audited manager-level public 13F model: the strict 5Y curve keeps uncovered weight in cash and requires 90% execution coverage; the extended 10Y public-sleeve proxy, when needed, renormalizes only fully priceable Top-60 holdings. This is not the Medallion Fund portfolio.",
    excludeFromHeatmap: true,
    heatmapExclusionReason:
      "Excluded from concentrated-manager consensus because the manager-level filing is a broad systematic book rather than a concentrated conviction portfolio.",
    notes: [
      "Renaissance Technologies files quarterly Form 13F-HR reports. The app tracks the manager-level U.S.-reportable long-equity disclosure.",
      "This is not the Medallion Fund portfolio or a reconstruction of Renaissance's complete quantitative strategy. The 13F omits shorts, futures, swaps, many non-U.S. securities, cash, and intra-quarter trading.",
      "Because the disclosed book is highly diversified and can turn over quickly, use the audited top-60 public-13F simulation as delayed systematic ownership and factor evidence rather than as a literal copy-trade instruction."
    ]
  },
  {
    id: "chamath-palihapitiya",
    retiredFromGuru: true,
    disableSimulation: true,
    retirementReason: "manager_identity_mismatch",
    simulationNote: "Removed from the current Guru directory: the configured reporting entity is not verified as this manager. Historical records are retained for audit, not offered as a valid manager backtest.",
    name: "Chamath Palihapitiya",
    chineseName: "查马斯·帕里哈皮蒂亚",
    entityName: "SC US (TTGP), LTD. / Social Capital",
    cik: "0001607841",
    type: "manager13f",
    role: "Social Capital founder / public equity manager proxy",
    thesisTag: "Social Capital public 13F proxy",
    notes: [
      "Chamath's personal Form 4 feed only captures companies where he is a reporting insider, so it is not a complete portfolio view.",
      "This card uses SC US (TTGP), LTD.'s quarterly 13F as the better public-market proxy for Social Capital's disclosed long equity holdings.",
      "It still cannot show private investments, venture positions, crypto, offshore entities, short positions, or holdings below public disclosure thresholds."
    ]
  },
  {
    id: "bill-ackman",
    name: "Bill Ackman",
    chineseName: "比尔·阿克曼",
    entityName: "Pershing Square Capital Management, L.P.",
    cik: "0001336528",
    alternateCiks: ["0002026053"],
    type: "manager13f",
    role: "Pershing Square founder / CEO",
    thesisTag: "Concentrated activist compounders",
    notes: [
      "Pershing Square files quarterly Form 13F-HR reports. The app tracks the public long equity portfolio rather than Ackman's private investments.",
      "The strategy is unusually concentrated, so the holding list may look short versus diversified hedge funds.",
      "Public letters, presentations, interviews, and conference remarks can be useful for interpreting major position changes."
    ]
  },
  {
    id: "stanley-druckenmiller",
    name: "Stanley Druckenmiller",
    chineseName: "德鲁肯米勒",
    entityName: "Duquesne Family Office LLC",
    cik: "0001536411",
    type: "manager13f",
    role: "Duquesne Family Office founder / macro public-equity proxy",
    thesisTag: "Macro-informed concentrated 13F",
    notes: [
      "Duquesne Family Office files quarterly Form 13F-HR reports. The app treats this entity as Stanley Druckenmiller's public long-equity proxy.",
      "The 13F does not show the macro book, shorts, FX, rates, commodities, private investments, or positions outside the U.S. reportable universe.",
      "Use the copy-trade simulation as a delayed public-equity read, not as a full recreation of Druckenmiller's portfolio."
    ]
  },
  {
    id: "brad-gerstner",
    name: "Brad Gerstner",
    chineseName: "布拉德·格斯特纳",
    entityName: "Altimeter Capital Management, LP",
    cik: "0001541617",
    type: "manager13f",
    role: "Altimeter Capital founder / CEO",
    thesisTag: "Concentrated technology and travel compounders",
    notes: [
      "Altimeter Capital files quarterly Form 13F-HR reports. The app treats the firm-level 13F as Brad Gerstner's public-market proxy.",
      "The 13F can miss private holdings, short exposure, swaps, venture positions, and non-reportable securities.",
      "Public letters and interviews are useful context for large position changes because Altimeter often frames holdings with a platform-level thesis."
    ]
  },
  {
    id: "chase-coleman",
    name: "Chase Coleman",
    chineseName: "蔡斯·科尔曼",
    entityName: "TIGER GLOBAL MANAGEMENT LLC",
    cik: "0001167483",
    type: "manager13f",
    role: "Tiger Global founder / public-equity manager proxy",
    thesisTag: "Tiger Cub technology and global growth equities",
    notes: [
      "Tiger Global Management files quarterly Form 13F-HR reports. The app treats the firm-level 13F as Chase Coleman's public long-equity proxy.",
      "The 13F excludes Tiger Global's private investments, short exposure, derivatives outside the reportable table, and non-U.S. positions outside the 13F universe.",
      "Because Tiger Global has meaningful private and crossover exposure, use this as a delayed public-market signal rather than a complete fund view."
    ]
  },
  {
    id: "philippe-laffont",
    name: "Philippe Laffont",
    chineseName: "菲利普·拉丰",
    entityName: "COATUE MANAGEMENT LLC",
    cik: "0001135730",
    type: "manager13f",
    role: "Coatue founder / portfolio manager",
    thesisTag: "Tiger Cub technology and growth equities",
    notes: [
      "Coatue Management files quarterly Form 13F-HR reports. The app treats the 13F as Philippe Laffont's public long-equity proxy.",
      "The 13F does not show private investments, shorts, derivatives below disclosure thresholds, or fund-level net exposure."
    ]
  },
  {
    id: "li-lu",
    name: "Li Lu",
    chineseName: "李录",
    entityName: "Himalaya Capital Management LLC",
    cik: "0001709323",
    type: "manager13f",
    simulationWindows: [5],
    simulationNote:
      "The audited 5Y public-holdings simulation is available. The 10Y window is not published because the early filing history contains a single reportable position and does not meet the existing diversified proxy threshold.",
    role: "Himalaya Capital founder / Munger-style value investor",
    thesisTag: "Concentrated value compounders",
    notes: [
      "Himalaya Capital files quarterly Form 13F-HR reports. The app tracks the disclosed U.S.-listed long equity portfolio.",
      "Li Lu is often associated with Charlie Munger's value-investing circle, but the 13F only captures reportable U.S. securities.",
      "Non-U.S. ordinary shares, private holdings, and positions outside 13F scope are not shown."
    ]
  },
  {
    id: "chuck-akre",
    name: "Chuck Akre",
    chineseName: "查克·阿克雷",
    entityName: "AKRE CAPITAL MANAGEMENT LLC",
    cik: "0001112520",
    type: "manager13f",
    role: "Akre Capital founder / quality compounder investor",
    thesisTag: "Three-legged-stool quality compounding",
    notes: [
      "Akre Capital Management files quarterly Form 13F-HR reports. The app uses the firm-level 13F as Chuck Akre's public long-equity proxy.",
      "The Akre portfolio is typically concentrated in quality compounders, but the 13F only covers reportable securities and can miss cash, private holdings, and non-reportable instruments.",
      "Large quarter-to-quarter changes should be read with manager commentary and fund disclosures where available."
    ]
  },
  {
    id: "dev-kantesaria",
    name: "Dev Kantesaria",
    chineseName: "德夫·坎特萨里亚",
    entityName: "Valley Forge Capital Management, LP",
    cik: "0001697868",
    type: "manager13f",
    role: "Valley Forge Capital founder / concentrated quality investor",
    thesisTag: "Concentrated quality compounders",
    notes: [
      "Valley Forge Capital Management files quarterly Form 13F-HR reports. The app treats the firm-level 13F as Dev Kantesaria's public long-equity proxy.",
      "The portfolio is typically concentrated, so a small number of positions can drive most of the disclosed exposure.",
      "The 13F cannot show cash, shorts, private holdings, non-U.S. ordinary shares outside the 13F universe, or exact intra-quarter trading."
    ]
  },
  {
    id: "chris-bloomstran",
    name: "Chris Bloomstran",
    chineseName: "克里斯·布鲁姆斯特兰",
    entityName: "SEMPER AUGUSTUS INVESTMENTS GROUP LLC",
    cik: "0001115373",
    type: "manager13f",
    role: "Semper Augustus president / value investor",
    thesisTag: "Value discipline and Berkshire-oriented quality",
    notes: [
      "Semper Augustus files quarterly Form 13F-HR reports. The app uses the firm-level 13F as Chris Bloomstran's public long-equity proxy.",
      "Bloomstran's annual letters are important context because the 13F alone does not explain position sizing, cash, valuation discipline, or client account differences.",
      "The 13F does not include shorts, cash, private holdings, or securities outside the U.S. reportable universe."
    ]
  },
  {
    id: "samantha-mclemore",
    name: "Samantha McLemore",
    chineseName: "萨曼莎·麦克勒莫",
    entityName: "Patient Capital Management, LLC",
    cik: "0001854794",
    type: "manager13f",
    role: "Patient Capital founder / long-term public-equity investor",
    thesisTag: "Patient concentrated value and growth",
    notes: [
      "Patient Capital Management files quarterly Form 13F-HR reports. The app treats the firm-level 13F as Samantha McLemore's public long-equity proxy.",
      "Patient Capital was founded after McLemore's long tenure with Bill Miller; the public 13F should be read as the reportable U.S. long sleeve only.",
      "The 13F misses shorts, cash, private positions, foreign ordinary shares outside 13F scope, and intra-quarter trading."
    ]
  },
  {
    id: "dennis-lynch",
    name: "Dennis Lynch",
    chineseName: "丹尼斯·林奇",
    entityName: "Morgan Stanley Counterpoint Global",
    type: "profile",
    role: "Counterpoint Global head / public fund manager profile",
    thesisTag: "Long-duration disruptive growth strategy",
    sourceLabel: "Morgan Stanley IM / Counterpoint Global",
    profileUrl: "https://www.morganstanley.com/im/en-us/individual-investor/about-us/people-and-teams/investment-professionals/lynch-dennis.html",
    excludeFromHeatmap: true,
    heatmapExclusionReason: "Counterpoint Global is a team/strategy profile; Morgan Stanley firmwide 13F would overstate unrelated positions.",
    simulationNote: "Counterpoint Global does not publish a clean standalone team-level 13F feed, so the app does not run proportional 13F copy-trading for this profile.",
    notes: [
      "Dennis Lynch is tracked here as a research profile because Counterpoint Global is a Morgan Stanley Investment Management team, not a clean standalone 13F filer.",
      "Using Morgan Stanley's firmwide 13F would mix unrelated desks, strategies, custody positions, and accounts, so the app deliberately avoids presenting that as Lynch's portfolio.",
      "A future extension should ingest strategy-level fund reports, N-PORT holdings, and official Morgan Stanley product disclosures where the holdings map cleanly to Counterpoint Global."
    ]
  },
  {
    id: "terry-smith",
    name: "Terry Smith",
    chineseName: "特里·史密斯",
    entityName: "Fundsmith LLP",
    cik: "0001569205",
    type: "manager13f",
    role: "Fundsmith founder / CIO",
    thesisTag: "Quality compounders, long holding periods",
    notes: [
      "Fundsmith LLP files quarterly Form 13F-HR reports for U.S.-reportable holdings.",
      "This view captures the U.S. 13F sleeve and can miss non-U.S. ordinary shares held outside the 13F reporting universe."
    ]
  },
  {
    id: "stan-moss",
    name: "Stan Moss",
    chineseName: "斯坦·莫斯",
    entityName: "POLEN CAPITAL MANAGEMENT LLC",
    cik: "0001034524",
    type: "manager13f",
    role: "Polen Capital CEO",
    thesisTag: "Quality growth compounders",
    notes: [
      "Polen Capital Management files quarterly Form 13F-HR reports. This card uses Polen's institutional 13F as the public portfolio proxy for Stan Moss's platform.",
      "The 13F is firm-level and may include multiple strategies, so it should not be read as a personal portfolio."
    ]
  },
  {
    id: "baillie-gifford",
    name: "Baillie Gifford",
    chineseName: "柏基投资",
    entityName: "BAILLIE GIFFORD & CO",
    cik: "0001088875",
    type: "manager13f",
    role: "Long-duration global growth manager",
    thesisTag: "Patient growth and innovation platforms",
    notes: [
      "Baillie Gifford & Co files quarterly Form 13F-HR reports for U.S.-reportable holdings.",
      "The 13F can understate the global portfolio because non-U.S. ordinary shares and some fund holdings are outside the U.S. 13F scope."
    ]
  },
  {
    id: "peter-thiel",
    name: "Peter Thiel",
    chineseName: "彼得·蒂尔",
    entityName: "THIEL PETER",
    cik: "0001211060",
    type: "insider",
    role: "Founder / board-level investor",
    thesisTag: "Founder and board disclosures",
    excludeFromHeatmap: true,
    heatmapExclusionReason: "company founder / board-level ownership distorts external consensus",
    notes: [
      "Peter Thiel's personal public disclosures are Form 4 filings tied to issuer relationships.",
      "Founders Fund entities can file separate 13Fs, but there is not a single personal quarterly 13F for Thiel."
    ]
  },
  {
    id: "nancy-pelosi",
    name: "Nancy Pelosi",
    chineseName: "佩洛西",
    entityName: "Nancy Pelosi household disclosures",
    type: "congress",
    role: "U.S. Representative / household STOCK Act disclosures",
    thesisTag: "Congressional trading disclosure lag",
    profileUrl: "https://pelositracker.app/stocks",
    sourceLabel: "Pelosi Tracker / STOCK Act",
    notes: [
      "Members of Congress do not file SEC Form 4 or 13F reports for household trades.",
      "This view tracks disclosed household transactions under the STOCK Act; trades can be reported with a delay and amounts are ranges, not exact share counts.",
      "The normalized feed starts from Pelosi Tracker's public congressional disclosure page and links back to the original tracker/source view."
    ]
  },
  {
    id: "david-sacks",
    name: "David Sacks",
    chineseName: "大卫·萨克斯",
    entityName: "Sacks David O",
    cik: "0001891801",
    type: "insider",
    role: "Craft Ventures co-founder / public issuer reporting owner",
    thesisTag: "Venture operator Form 4 disclosures",
    excludeFromHeatmap: true,
    heatmapExclusionReason: "venture/private holdings and issuer-specific Form 4 disclosures are not complete portfolio signals",
    notes: [
      "David Sacks does not publish a current complete quarterly public-equity portfolio comparable to a 13F manager.",
      "This card tracks SEC Form 4 ownership-change disclosures tied to public issuer relationships and should not be read as Craft Ventures' full portfolio.",
      "Private investments, token or crypto exposure, venture funds, and non-reportable positions are outside this feed."
    ]
  },
  {
    id: "david-friedberg",
    name: "David Friedberg",
    chineseName: "大卫·弗里德伯格",
    entityName: "Friedberg David A",
    cik: "0001619941",
    type: "insider",
    role: "The Production Board founder / public issuer reporting owner",
    thesisTag: "Sparse operating-founder Form 4 disclosures",
    excludeFromHeatmap: true,
    heatmapExclusionReason: "sparse Form 4 disclosures are not a complete investable portfolio",
    notes: [
      "David Friedberg's SEC feed is a sparse Form 4 history, not a full public-equity portfolio.",
      "The Production Board's private-company and venture exposure is not captured by this SEC owner feed.",
      "Treat this card as a public issuer disclosure trail rather than a copy-tradable strategy."
    ]
  },
  {
    id: "reid-hoffman",
    name: "Reid Hoffman",
    chineseName: "里德·霍夫曼",
    entityName: "Hoffman Reid",
    cik: "0001519339",
    type: "insider",
    role: "LinkedIn co-founder / Greylock partner / public issuer reporting owner",
    thesisTag: "Venture and board-level Form 4 disclosures",
    excludeFromHeatmap: true,
    heatmapExclusionReason: "board, founder, and venture-linked Form 4 disclosures are not broad public-equity consensus signals",
    notes: [
      "Reid Hoffman's personal SEC feed is mostly Form 4 ownership-change activity tied to issuer relationships and affiliated vehicles.",
      "Greylock entities can file separate 13Fs, but this profile avoids treating a single fund vehicle as Hoffman's complete personal portfolio.",
      "The app uses these disclosures as a thesis/context trail, not as a proportional 13F copy-trade source."
    ]
  },
  {
    id: "alex-karp",
    name: "Alex Karp",
    chineseName: "亚历克斯·卡普",
    entityName: "Karp Alexander C.",
    cik: "0001823951",
    type: "insider",
    focusTicker: "PLTR",
    focusIssuer: "Palantir Technologies",
    role: "Palantir co-founder / CEO",
    thesisTag: "Founder CEO Form 4 selling and ownership",
    excludeFromHeatmap: true,
    heatmapExclusionReason: "company founder / control-holder ownership distorts external consensus",
    notes: [
      "Alex Karp's public-company trading disclosures are Form 4 filings tied to Palantir.",
      "Form 144 filings may also appear in SEC submissions, but this app focuses on completed Form 4 ownership-change reports."
    ]
  },
  {
    id: "warren-buffett",
    name: "Warren Buffett",
    chineseName: "巴菲特",
    entityName: "Berkshire Hathaway Inc.",
    cik: "0001067983",
    type: "manager13f",
    role: "Berkshire Hathaway chairman / value investor",
    thesisTag: "Insurance float and concentrated value compounders",
    notes: [
      "Berkshire Hathaway files quarterly Form 13F-HR reports. The app treats Berkshire's public long-equity portfolio as Warren Buffett's best public-market proxy.",
      "The 13F does not show Berkshire's wholly owned operating businesses, cash, Treasury bills, private deals, non-U.S. holdings outside 13F scope, or manager-level attribution between Buffett, Todd Combs, and Ted Weschler.",
      "Use the disclosed portfolio as a delayed public-equity signal rather than a complete Berkshire balance-sheet view."
    ]
  },
  {
    id: "tom-gayner",
    name: "Tom Gayner",
    chineseName: "汤姆·盖纳",
    entityName: "Markel Group Inc.",
    cik: "0001096343",
    type: "manager13f",
    role: "Markel CEO / investment chief",
    thesisTag: "Insurance float and long-term quality/value equities",
    notes: [
      "Markel Group files quarterly Form 13F-HR reports. The app treats Markel's disclosed public long-equity portfolio as Tom Gayner's best public-market proxy.",
      "The 13F does not show Markel's full insurance balance sheet, cash, fixed-income book, private investments, operating businesses, or manager-level attribution.",
      "Read major position changes alongside Markel annual letters and filings because the equity portfolio sits inside a broader insurance and capital-allocation framework."
    ]
  },
  {
    id: "nick-sleep-qais-zakaria",
    retiredFromGuru: true,
    retirementReason: "closed_partnership_no_current_simulation",
    name: "Nick Sleep / Qais Zakaria",
    chineseName: "尼克·斯利普 / 凯斯·扎卡里亚",
    entityName: "Sleep, Zakaria & CO Ltd. / Nomad Investment Partnership",
    cik: "0001384801",
    type: "manager13f",
    role: "Nomad Investment Partnership founders / archived 13F case study",
    thesisTag: "Archived long-term compounder case study",
    preferLatestNonZero13f: true,
    disableSimulation: true,
    excludeFromHeatmap: true,
    heatmapExclusionReason: "Nomad is an archived historical partnership, not a current external-consensus signal.",
    simulationNote: "Nomad is closed and has no current quarterly 13F feed; historical holdings are useful for case study work but not for live five-year copy-trading.",
    notes: [
      "Nomad Investment Partnership is not an active public 13F manager today. This profile uses archived Sleep, Zakaria & CO Ltd. SEC filings where available.",
      "The app intentionally disables current copy-trading and heatmap contribution for this profile because it would otherwise mix stale historical holdings with today's market.",
      "Use the Nomad letters and archived filings as a case-study lens on long-duration compounding rather than as a live guru portfolio."
    ]
  },
  {
    id: "chris-hohn",
    name: "Chris Hohn",
    chineseName: "克里斯·霍恩",
    entityName: "TCI Fund Management Ltd",
    cik: "0001647251",
    alternateCiks: ["0001362598"],
    type: "manager13f",
    role: "TCI founder / concentrated activist investor",
    thesisTag: "Concentrated global compounders and active ownership",
    notes: [
      "TCI Fund Management files quarterly Form 13F-HR reports. The app merges the current filer with its audited predecessor CIK so the public U.S. long-equity history remains continuous.",
      "The 13F is a delayed U.S.-reportable long-equity proxy and does not show TCI's complete global portfolio, shorts, derivatives, cash, or intra-quarter trading.",
      "Read large position changes alongside TCI's public ownership campaigns and issuer disclosures rather than treating the filing as a complete fund return series."
    ]
  },
  {
    id: "david-tepper",
    name: "David Tepper",
    chineseName: "大卫·泰珀",
    entityName: "Appaloosa LP",
    cik: "0001656456",
    alternateCiks: ["0001006438"],
    type: "manager13f",
    role: "Appaloosa founder / opportunistic value investor",
    thesisTag: "Macro-aware value, cyclicals, and dislocated growth",
    notes: [
      "Appaloosa files quarterly Form 13F-HR reports. The app merges the current and predecessor reporting entities to preserve the manager's disclosed U.S. long-equity history.",
      "Reported puts and calls are separated from the common-long book, while shorts, credit, cash, non-U.S. securities, and intra-quarter trading remain outside the 13F view.",
      "Use the simulation as a delayed public-equity proxy, not as a reconstruction of Appaloosa's total macro or credit portfolio."
    ]
  },
  {
    id: "dan-loeb",
    name: "Dan Loeb",
    chineseName: "丹·勒布",
    entityName: "Third Point LLC",
    cik: "0001040273",
    type: "manager13f",
    role: "Third Point founder / CEO",
    thesisTag: "Event-driven activism and catalyst-oriented equities",
    notes: [
      "Third Point files quarterly Form 13F-HR reports. The app tracks its disclosed U.S. common-long portfolio and separates options and other non-common claims from the investable book.",
      "The 13F does not reveal shorts, credit, private investments, hedges, non-U.S. positions outside the reporting universe, or the timing of intra-quarter trades.",
      "Third Point letters and issuer-specific catalysts are important context for interpreting concentrated additions and exits."
    ]
  },
  {
    id: "seth-klarman",
    name: "Seth Klarman",
    chineseName: "塞思·卡拉曼",
    entityName: "Baupost Group LLC/MA",
    cik: "0001061768",
    type: "manager13f",
    role: "Baupost CEO / portfolio manager",
    thesisTag: "Deep value, downside protection, and special situations",
    notes: [
      "Baupost Group files quarterly Form 13F-HR reports. The app uses the firm-level filing as Seth Klarman's public U.S. long-equity proxy.",
      "Legacy filings can use SEC thousands-scale values; the data pipeline normalizes those units before computing holdings, changes, and backtests.",
      "The 13F excludes cash, credit, private investments, shorts, many non-U.S. positions, and other assets central to Baupost's capital-preservation mandate."
    ]
  },
  {
    id: "nelson-peltz",
    name: "Nelson Peltz",
    chineseName: "纳尔逊·佩尔茨",
    entityName: "Trian Fund Management, L.P.",
    cik: "0001345471",
    type: "manager13f",
    role: "Trian founding partner / activist investor",
    thesisTag: "Concentrated operational activism in durable franchises",
    notes: [
      "Trian Fund Management files quarterly Form 13F-HR reports. The app treats the firm-level common-long filing as Nelson Peltz's best public-market proxy.",
      "Duplicate security lines are aggregated before concentration and change analysis so one economic position is not counted more than once.",
      "The filing does not show derivatives, shorts, cash, private arrangements, board influence, or the full operational plan behind an activist position."
    ]
  },
  {
    id: "andreas-halvorsen",
    name: "Andreas Halvorsen",
    chineseName: "安德烈亚斯·哈尔沃森",
    entityName: "Viking Global Investors LP",
    cik: "0001103804",
    type: "manager13f",
    role: "Viking Global founder / CIO",
    thesisTag: "Fundamental long-short growth and quality equities",
    notes: [
      "Viking Global Investors files quarterly Form 13F-HR reports. The app uses the manager-level filing as Andreas Halvorsen's delayed U.S. long-equity proxy.",
      "The 13F cannot show Viking's short book, net exposure, private investments, cash, non-U.S. securities outside scope, or intra-quarter trading.",
      "Position changes should be interpreted as public ownership evidence rather than as a complete reconstruction of Viking's long-short fund performance."
    ]
  },
  {
    id: "david-einhorn",
    name: "David Einhorn",
    chineseName: "大卫·艾因霍恩",
    entityName: "DME Capital Management, LP",
    cik: "0001489933",
    alternateCiks: ["0001079114"],
    type: "manager13f",
    role: "Greenlight Capital founder / value investor",
    thesisTag: "Value, short research, and catalyst-driven equities",
    notes: [
      "DME Capital Management is the current Form 13F reporting entity for this public-equity proxy. The app merges Greenlight Capital's predecessor CIK to preserve the historical series across the 2024 filer transition.",
      "The disclosure covers reportable U.S. longs; it omits the short book, credit, swaps, cash, private holdings, and exact intra-quarter execution.",
      "Greenlight's letters and presentations are essential context because the long-only 13F cannot represent the portfolio's hedges or short theses."
    ]
  },
  {
    id: "mohnish-pabrai",
    name: "Mohnish Pabrai",
    chineseName: "莫尼什·帕伯莱",
    entityName: "Dalal Street, LLC",
    cik: "0001549575",
    alternateCiks: ["0001173334"],
    type: "manager13f",
    simulationWindows: [5],
    simulationNote:
      "The audited 5Y public-holdings simulation is available. The 10Y window is not published because the early filing history contains a single reportable position and does not meet the existing diversified proxy threshold.",
    role: "Pabrai Funds founder / concentrated value investor",
    thesisTag: "Low-risk, high-uncertainty value and concentrated bets",
    notes: [
      "Dalal Street files quarterly Form 13F-HR reports for the current public U.S. long-equity sleeve. The app merges the predecessor personal filer CIK to retain historical continuity.",
      "The 13F can be highly concentrated and does not show cash, non-U.S. ordinary shares outside scope, private holdings, shorts, or intra-quarter trading.",
      "Use Pabrai's letters and talks to understand the underlying thesis; the filing alone shows delayed ownership, not position-level expected returns."
    ]
  },
  {
    id: "pat-dorsey",
    name: "Pat Dorsey",
    chineseName: "帕特·多尔西",
    entityName: "Dorsey Asset Management, LLC",
    cik: "0001671657",
    type: "manager13f",
    role: "Dorsey Asset Management founder / CIO",
    thesisTag: "Concentrated quality compounders with durable moats",
    notes: [
      "Dorsey Asset Management files quarterly Form 13F-HR reports. The app treats the firm-level filing as Pat Dorsey's public U.S. long-equity proxy.",
      "The concentrated book can make individual additions materially affect reported exposure, but the 13F does not reveal cash, shorts, private holdings, or intra-quarter execution.",
      "Position changes are most useful when paired with Dorsey's published framework on competitive advantages, capital allocation, and valuation."
    ]
  },
  {
    id: "william-heard",
    name: "William Heard",
    chineseName: "威廉·赫德",
    entityName: "Heard Capital LLC",
    cik: "0001796409",
    type: "manager13f",
    role: "Heard Capital founder / CEO / CIO",
    thesisTag: "Heard Capital public long-equity portfolio",
    notes: [
      "Heard Capital LLC files quarterly Form 13F-HR reports. The app uses the firm's reportable long holdings as William Heard's public-equity proxy.",
      "The 13F is not a personal portfolio or the firm's complete strategy: shorts, cash, private investments and intra-quarter trading are outside this view."
    ]
  },
  {
    id: "evan-mcgoff",
    name: "Evan McGoff",
    chineseName: "埃文·麦戈夫",
    entityName: "DOCK STREET ASSET MANAGEMENT INC",
    cik: "0001172779",
    type: "manager13f",
    role: "Dock Street Asset Management CIO",
    thesisTag: "Concentrated profitable businesses with competitive advantages",
    notes: [
      "Dock Street Asset Management Inc files quarterly Form 13F-HR reports. Holdings and changes belong to the reporting firm, not to Evan McGoff personally.",
      "The historical series begins before McGoff's tenure and must not be interpreted as his personal investment track record.",
      "The 13F omits cash, shorts, non-reportable securities and intra-quarter trading; it is not the complete client-account portfolio."
    ]
  },
  {
    id: "michael-cuggino",
    name: "Michael Cuggino",
    chineseName: "迈克尔·库吉诺",
    entityName: "PACIFIC HEIGHTS ASSET MANAGEMENT LLC",
    cik: "0001323414",
    type: "manager13f",
    role: "Pacific Heights Asset Management president / portfolio manager",
    thesisTag: "Pacific Heights reportable long-equity sleeve",
    notes: [
      "Pacific Heights Asset Management LLC is the Form 13F filer associated with Michael Cuggino. Filings are assigned by the reporting CIK, not by a filing agent's accession-number prefix.",
      "This manager-level 13F is not the complete Permanent Portfolio allocation: gold, bonds, currencies, cash and other non-reportable exposures are not reconstructed.",
      "Quarterly share changes are delayed ownership disclosures, not actual execution dates or a record of fund returns."
    ]
  },
  {
    id: "john-stamas",
    retiredFromGuru: true,
    retirementReason: "unverifiable_historical_price_coverage",
    name: "John Stamas",
    chineseName: "约翰·斯塔马斯",
    entityName: "Defender Capital, LLC.",
    cik: "0001766929",
    type: "manager13f",
    role: "Defender Capital CIO",
    thesisTag: "Defender Capital public long-equity portfolio",
    disableSimulation: true,
    simulationNote:
      "Historical holdings remain available, but the public 13F copy simulation is disabled because the audited filing history does not meet the existing price-coverage threshold. No lower-quality or cash-substitute curve is published.",
    notes: [
      "Defender Capital, LLC. is the Form 13F filer associated with CIO John Stamas. This is not the similarly named Defender Capital Partners private-fund entity.",
      "The app tracks the firm's reportable long holdings, not John Stamas's personal assets; cash, shorts, private investments and intra-quarter trading are not disclosed by this series."
    ]
  },
  {
    id: "george-soros",
    name: "George Soros",
    chineseName: "索罗斯",
    entityName: "SOROS FUND MANAGEMENT LLC",
    cik: "0001029160",
    type: "manager13f",
    simulationWindows: [5],
    simulationNote:
      "The audited 5Y public-holdings simulation is available. The 10Y window is not published because verified price coverage for the early filing history remains below the existing 30% proxy threshold.",
    role: "Soros Fund Management",
    thesisTag: "Multi-strategy public equities",
    notes: [
      "Soros Fund Management files quarterly Form 13F-HR reports. Changes are computed against the prior 13F quarter."
    ]
  }
];

export const requiredGuruCurveWindows = Object.freeze([5, 10]);

// Retirement removes current discovery / new-strategy entry points only.
// Keep the original identities for historical filings and saved research.
export const visibleGurus = Object.freeze(gurus.filter(guru => !guru.retiredFromGuru));

export function guruIsVisible(guruOrId) {
  const id = typeof guruOrId === "object" ? guruOrId?.id : guruOrId;
  return visibleGurus.some(guru => guru.id === id);
}

const publicProxyDeniedManagerWindows = new Set([
  "renaissance-technologies:5"
]);

/**
 * Return whether a separately audited public-holdings proxy may satisfy the
 * requested manager/window on public reads and release-health gates. Strict
 * curves are unaffected and always remain preferred.
 */
export function manager13fPublicProxyAllowed(guruOrId, years) {
  const guruId = String(
    typeof guruOrId === "object" ? guruOrId?.id || "" : guruOrId || ""
  ).trim();
  const normalizedYears = Number(years);
  return !publicProxyDeniedManagerWindows.has(`${guruId}:${normalizedYears}`);
}

export const enabledManager13fGurus = Object.freeze(gurus.filter((guru) =>
  guru.type === "manager13f" && !guru.disableSimulation && !guru.retiredFromGuru
));

export function requiredGuruCurveWindowsFor(guruOrId) {
  const supplied = typeof guruOrId === "object" ? guruOrId : null;
  const guru = gurus.find((item) => item.id === (supplied?.id || guruOrId)) || supplied;
  if (!guru || guru.disableSimulation || guru.retiredFromGuru || (guru.type && guru.type !== "manager13f")) return [];
  const configured = Array.isArray(guru.simulationWindows)
    ? guru.simulationWindows.map(Number)
    : requiredGuruCurveWindows;
  return requiredGuruCurveWindows.filter((years) => configured.includes(years));
}

export const expectedGuruCurveRows = enabledManager13fGurus.reduce(
  (total, guru) => total + requiredGuruCurveWindowsFor(guru).length,
  0
);
