# ThesisForge Research Ontology：设计报告

日期：2026-09-20。状态：**研究与设计，未实现**。范围：现有仓库代码、本地 published Fact OS、Gavin Baker 的原始文章/访谈及明确标注的近原始转录。

## 结论先行

最小有用方案不是再做一套财务数据库，也不是给每位投资者造一张知识图谱，而是：**在 Fact OS 上增加一套可追溯、可反驳、带时间与适用条件的研究论证结构。**

- Fact OS 回答“记录了什么”；Research Ontology 表达“这能支持什么判断、还缺什么、什么会推翻它”。
- 先用 **6 类研究记录、6 个共享推理模块、1 份 Gavin Brain 配置**；不需要图数据库、全行业分类树或统一投资评分。
- Gavin Brain 保存他形成和修改判断的方法，而不是模仿他的语气，或把他的历史持仓解释为今天的推荐。
- 忠实度的关键是：**来源可定位、前提不省略、时代不混淆、反证不消失**。公开材料只能重建其公开表达的框架，不能宣称复制了 Atreides 内部完整决策系统。

下文区分三种内容：**[核实]** 本地数据/代码或来源明确内容；**[归纳]** 从材料总结的模式；**[设计]** 为系统提出的结构与规则。

## 1. Fact OS capability map：现有基础与真实边界

### 1.1 本次只读审计快照

通过 `FactRepository` 固定 published manifest 后查询；未复制数据库、未读私人组合数据、未运行刷新。当前 manifest SHA-256：

`813fccfd9a64777f6893334914b6772e22023c9415a9e332495e74f10b72c286`

| [核实] 数据范围 | 本地覆盖 | 解释边界 |
|---|---:|---|
| 全部 canonical datasets | 14 表、201,159,454 行 | 行数是观察记录，不是独立公司数 |
| 财务历史 | 3,217,364 行、17,844 个历史 ticker | ARQ 681,706 行；ART 688,437 行；含多期间/维度 |
| 当前未退市财务证券 | 5,525；其中 5,523 有截止日可用的最新 ART | 证券口径，不等于唯一经济发行人 |
| 股票价格 | 45,354,943 行、20,985 个历史 ticker | 当前未退市 SEP 股票 6,336；最新交易日 2026-09-18 |
| DAILY 估值 | 39,818,815 行、17,468 个历史 ticker | 最新日 2026-09-18；不是前瞻一致预期 |
| 机构持仓 | 81,202,367 行、31,202 个 ticker、13,257 个机构 ID | 全历史 53 季，2013Q2—2026Q2；不是本季活跃机构数 |

可复核入口：[manifest](../data/fact_os/manifests/catalog.json)、[FactRepository](../fact_os/repository.py)、`bin/fact-os status`。历史验收文档中的旧 SHA 不是本次快照。

### 1.2 必须区分“有数据”“有语义接口”“已有应用展示”

| 研究需求 | Fact OS 底层可供应的内容 | 仍需定义/外部补充 |
|---|---|---|
| 增长、利润率 | 收入、毛利、经营利润、净利润及季度/年度/滚动期间 | 同比/复合增长/增量利润等版本化特征；并购、汇率、产品组合解释 |
| 现金流 | 经营现金流、capex、FCF、投资/融资流量 | 现金转换的口径；营运资本暂时释放与持续改善的区别 |
| 资本效率 | 供应商 ROIC、ROE、ROA、平均投入资本、周转率 | 行业适用性；经济利润、增量回报不能由单个 ROIC 自动得出 |
| 价格、估值 | 原始/拆股调整/总回报调整价格；市值、EV、PE/PB/PS 等 | 明确价格基础；市场隐含预期与前瞻估值另行建模 |
| 稀释、资本配置 | 基本/加权/摊薄股数、SBC、股息、净股权融资、净并购、债务流量 | 总回购额/回购均价、收购回报、管理层决策理由不能由净额还原 |
| 机构持仓变化 | 投资者身份、证券类型、季末股数/市值及前后季变动 | 实际交易日、意图、完整净敞口；真实披露时间缺失时不能历史跟投 |

**注册层比底层窄得多。** [registry.py](../fact_os/registry.py) 当前仅注册 7 个 Metric：`Revenue`、`FreeCashFlow`、`ROIC`、`MarketCap`、`InstitutionalShareUnits`、`InstitutionalHolderCount`、`InstitutionalShareValue`；默认 Feature 仅 **`FCFMargin v1`**。现有 FeatureEngine 要求同一期间的兼容输入，不是已经完成的跨期特征计算器。

[investmentSource.js](../server/investmentSource.js) 的增长/利润率来自归档估值模型池，`availableTickers()` 也只是该池；[investmentQuality.js](../server/investmentQuality.js) 使用 curated 年度表。这些不能冒充覆盖全库的统一 Feature 服务。未来按需补语义注册是扩展现有接口，不是重建 Fact OS；未实现的指标请求必须返回“不支持”，不能让 Brain 自己拼供应商字段。

### 1.3 质量与 point-in-time 约束

在上述 5,523 个最新 eligible ART 中，非空数量：收入 **5,220**、FCF **5,078**、ROIC **5,196**、摊薄加权股数 **4,268**、SBC **4,854**、净普通股融资现金流 **4,885**、净并购/处置现金流 **4,699**。7 个证券最新可用日距截止日超过一年。**非空不是已验证有效，也不是每家公司拥有完整历史。**

最重要的定义陷阱：

- 本地供应商字典将 ROIC 定义为 **EBIT / 平均投入资本**，投入资本为 Debt + Assets − Intangibles − Cash − Current liabilities。这不是通用税后 NOPAT ROIC，更不是“护城河事实”。有 288 个证券 ROIC 非空但平均投入资本不为正。
- `capex/rnd/ncfcommon/ncfbus` 的来源定义允许部分未报告且不可推算的值填 0；**0 不自动等于没有活动**。净回购/发行不是总回购；SBC 与股数影响不可重复计入同一稀释成本。
- 历史回放须用 AR 及期间/可用日双约束；MR 重述值不得倒灌。AR 可用日是日粒度，不证明当天盘中已知；现有首次下载也不等于拥有完整历史双时间档案。
- SF3 缺真实 filing availability，显式 `as_of` 请求会拒绝；季末持仓变化不是即时交易信号。当前证券主表也不是无生存偏差的历史可投资股票池。
- 历史原币未知时不能拿当前币种回填。只有满足现有来源一致性规则的同条观察比率才可抵消未知币种。

覆盖查询口径：在当前 `SF1/isdelisted=N` 集合中，选 `ART` 且 `reportperiod ≤ date ≤ 2026-09-20`，再按 ticker 取 `reportperiod DESC, date DESC` 第一条；非空计数不剔除 0、不跨期补值。机构数为全史 `COUNT(DISTINCT investorid)`。这些聚合可复核，但本文不导出许可数据明细。

## 2. 主要 qualitative-data gaps：不能靠财务表回答的问题

| 缺口 | 要补什么证据 | 对研究的影响 |
|---|---|---|
| 客户为什么购买、续费、扩张 | 客户原话、合同/招标、留存/队列、上线前后单位经济 | 收入增长不能证明客户 ROI 或产品不可替代 |
| 技术优势与竞争机制 | 同负载基准、总拥有成本、部署约束、替代品、失败/丢单 | benchmark 第一不等于客户迁移或利润归属 |
| TAM 与市场结构 | 客户数×可服务用量×付费意愿、竞争者/产能/价格及替代关系 | TAM、可获得份额、可获得利润是三件事 |
| 增长持续期 | 渗透率、复购、代际替换、供给反应、需求提前 | 高同比不等于长期终局扩大 |
| 市场预期 | 有历史时间戳的共识、修正、指引、价格隐含情景 | 实绩好不等于超预期；三类预期不能互换 |
| 资本配置与治理 | proxy 薪酬/PSU、投资决策原文、并购后结果、监管文件 | 报表显示花了多少钱，通常不解释为什么、是否值得 |
| 投资者推理与反证 | 本人原文、当时条件、实际案例、失败复盘 | 13F 只能提示研究对象，不能证明买入理由或信念强度 |

**可以复用而非重新抓一遍：** 本地已有 `valuation_pit_guidance`、`valuation_podcast_insights`、财报 Q&A 和来源摘录；相关代码见 [investmentGuidance.js](../server/investmentGuidance.js)、[investmentEarnings.js](../server/investmentEarnings.js)、[transcriptQaClient.js](../server/transcriptQaClient.js)。它们是可桥接的研究材料，不是已经具备验证关系的 Claim 图。本次核实结构/读取逻辑，不宣称这些材料覆盖所有公司或所有 Gavin 访谈。

现有 guidance 审核已区分主体、scope、目标年；earnings Q&A 明确 `researchOnly`，不自动进入估值输入。应保持这道边界。抽取字段 `confidence` 也不能当作投资结论正确概率。

## 3. 最有价值的 Gavin Baker 来源地图

下列是本次设计依据，不是穷尽其全部公开发言。A＝本人文章/采访出版方文字；B＝官方节目身份已核实、正文使用第三方转录。A 只表示更接近原话，不保证其投资判断正确。

| ID | 来源、日期、访问状态 | 最有用的定位与研究用途 |
|---|---|---|
| G1 | [Columbia · Graham & Doddsville](https://business.columbia.edu/sites/default/files-efs/imce-uploads/Graham%20%26%20Doddsville_Issue%2043_vF.pdf)，2021 秋，访谈 10-25；A，全文 | 印刷 pp.7–9：可证伪假说、指定反方、公私市场交叉验证、电信定价机制 |
| G2 | [Investing Mistakes, Chapter 1001](https://gavin-baker.medium.com/investing-mistakes-chapter-1001-9f0b7dbc6637)，2020-08-14；A，全文 | Intel 失败复盘；定位 “So I was really focused” 及 “None of this mattered” 起首段 |
| G3 | [Software contracts…no revenue is truly recurring](https://gavin-baker.medium.com/software-contracts-first-lien-debt-and-the-reality-that-no-revenue-is-truly-recurring-6c4d164778d5)，2020-03-22；A，全文 | 客户规模/行业、获客、客户 ROI、定价利用率如何传导至收入与现金流 |
| G4 | [Category-leading retailers / Covid](https://gavin-baker.medium.com/why-category-leading-brick-and-mortar-retailers-are-likely-the-biggest-long-term-covid-d70b8dfadc20)，2020-10-18；A，全文 | Walmart/Best Buy：需求提前与经营能力永久改善的区别 |
| G5 | [Fear is the mind-killer](https://gavin-baker.medium.com/fear-is-the-mind-killer-secular-growth-stocks-are-becoming-increasingly-attractive-67127573204e)，2021-05-18；A，全文 | “Relative revisions” 段：短期预期修正、长期增长久期/ROIC、估值与行业偏好变化 |
| G6 | [Lessons…The Art of Execution](https://gavin-baker.medium.com/lessons-on-winning-and-losing-as-an-investor-from-the-art-of-execution-e6aafe817038)，2021-04-17；A，全文 | 本人加仓成败与风险边界；注意区分作者、书中样本和 Hempton 的规则 |
| G7 | [a16z Runtime 官方整理稿](https://www.a16z.news/p/gavin-baker-and-david-george-on-positional)，2025-10-30；A，轻度编辑 | “is AI a bubble?” 与 “Market structure” 段：从利用率、财务与竞争结构形成判断 |
| G8 | ILTB EP451，[官方](https://colossus.com/episode/nvidia-v-google-the-economics-of-ai/) / [转录](https://podscripts.co/podcasts/invest-like-the-best-with-patrick-oshaughnessy/gavin-baker-nvidia-v-google-scaling-laws-and-the-economics-of-ai-invest-like-the-best-ep451)，2025-12-09；B，正文相关章节已读 | 转录约 38:28–40:37 模型竞争观点更新；65:55–70:48 SaaS 毛利率与 AI 转型 |
| G9 | ILTB EP473，[官方](https://colossus.com/episode/watts-and-wafers/) / [转录](https://pod.wave.co/podcast/invest-like-the-best-with-patrick-oshaughnessy-48a998b1-8bc3-4e91-9c00-6d2f4d646fdd/gavin-baker-watts-and-wafers-invest-like-the-best-ep473)，2026-05-20；B，相关章节已读 | 约 26:28 产能约束、49:03 初创差异化、58:39 起管理层薪酬目标及其历年变化 |
| G10 | ILTB EP485，[官方](https://colossus.com/episode/ai-market-jitters/) / [转录](https://steadcast.co/show/invest-like-best/gavin-baker-ai-market-jitters-invest-like-the-best-ep-485)，2026-08-04；B，相关章节已读 | 官方 25:19 “What Would Actually Scare Him”；转录约 26:46–27:18 明确负面信号 |
| G11 | [Thoughts post E3 2019](https://gavin-baker.medium.com/thoughts-post-e3-2019-58cb42c61bf4)，2019-06-23 页面发布日期；A，全文 | 开头及平台分成段：游戏成本/使用场景改变 TAM，但分销竞争也会重分利润 |

[Atreides 官方简介](https://atreidesmgmt.com/)只用于核实长期、科技/消费、公私市场 crossover 定位，不作为完整方法论证据。[2024-08-27 官方访谈](https://www.joincolossus.com/episode/baker-ai-semiconductors-and-the-robotic-frontier/?tab=transcript)核实了入口与章节，但全文受访问限制，不冒充已读全文。

来源处理原则：节目官方章节与转录时间可能因广告错位；同时保留章节名、定位短语、转录提供方和验证状态。B 类存在芯片名/年份甚至褒贬词 ASR 错误，数字需回听/原始文件交叉验证。本次未声称逐段回听音频。多家转录转载同一访谈只算一个来源；投资经理和创投主持人的利益关系、成功案例选择偏差需要保留。

## 4. Gavin 的反复推理模式：不是语录合集

以下模块化名称与问题表达均为 **[归纳]**；来源中的观点保留当时时间与范围，不自动升为普适真理。

| 模式 | 从证据到结论的链条 | 适用层级与更新条件 |
|---|---|---|
| 先找可以错在哪里 | 写出假说 → 找反证/安排反方 → 判断关键前提是否仍成立 [G1] | 通用方法；“暂未推翻”不等于已证明 |
| 技术优越不等于投资胜出 | 工作负载/软件互补 → 客户采用 → 制造执行 → 份额与利润 [G2] | 公司/技术代际条件；互补前提失效可推翻优势 |
| TAM 扩大不等于平台利润扩大 | 云游戏降低游玩成本/增加场景 → 潜在需求变大；更多分销选择 → 内容方议价增强、平台分成承压 [G11] | 2019 游戏判断；分销技术与收费模式分开，本文不把当时预测当已验证结果 |
| 收入质量来自客户经济性 | 客户组成、ROI、定价/使用 → 留存与折扣 → 收款与现金流 [G3] | 软件压力情境；不是“订阅收入天然安全”的标签 |
| 研究增长的持续时间，而不只看速度 | 冲击引发采用 → 组织/单位经济是否改变 → 长期现金流 [G4]、[G5] | 需求提前与结构改善并列假说；短期修正与长期久期分开 |
| 竞争要看反应能力 | 对手能否复制、扩产/迭代需要多久 → 优势持续期 [G1]、[G9] | 行业规则；集中度、技术领先都不能单独推出定价权 |
| 财务指标要解释机制 | 毛利率下降可能源自新模式，不必然是质量下降；要看毛利额与费用/现金流 [G8] | 软件 AI 转型观察；不是普遍鼓励低毛利 |
| 观点允许被新机制改写 | 新技术改变反馈循环 → 调整进入壁垒判断 [G8] | 旧观点与更新分别保存；此处 2023–24 看法来自 2025 回顾，未核实同期原文，不能倒填历史 Brain |
| 好公司与好价格是两道题 | 近端预期、未来盈利/回报持续期 → 当前价格要求的兑现程度 [G5] | 未发现足以支持固定 DCF 参数或统一买入倍数的材料 |

### 三个不能丢掉的案例约束

**Intel 2020 [G2]：失败不应被事后改写。** 他买入时重视软件/工作负载优势、10nm 改进与估值，却未充分审查 7nm 执行假设。制程延期与 AMD 份额证据破坏链条。系统应记录“原先未验证的必要前提”，不能在复盘后把它伪装成当时已经设好的止损条件。

**全渠道零售 2020 [G4]：增长不是单一机制。** Walmart/Best Buy 的门店履约、获客和组织变化，支持他关于长期经济性改善的判断。这是当时假说，不是本文已完成的后验胜负检验。后续贡献利润、留存与履约成本检验属于分析者提出，应标明来源身份。

**AI 基建 2026 [G10]：证伪必须匹配对象。** 他点名经营现金流不再加速、GPU 租金持续大幅下降、GPU 更容易取得、模型企业合计活动停滞或下降等负面线索；同时提醒单个实验室减速可能被开源活动替代。单公司份额下降不等于全行业需求下降；本文不替他虚构跌幅/季度数阈值或这些信号的正式 AND/OR 组合。

这些案例要求系统分别记录 **投资者表达、研究者解释、公司真实结果**。它们不能混成一个“Gavin 正确/错误”的标签。

## 5. 最小 Research Ontology

### 5.1 语义上分清 11 种对象，存储上不必建 11 张表

建议 6 类研究记录：`Concept`、`Question`、`Assertion`、`Evidence`、`Method`、`CaseStudy`。Fact/Feature 通过引用接入；Module/Brain 是版本化组合配置，研究运行另存审计记录。

| 用户关心的对象 | 最小定义及必须保留的信息 | 归属 |
|---|---|---|
| Fact | 有主体、期间、可用时间、单位、来源及测量定义的观察；可有错误或修订，不等于绝对真相 | Fact OS 引用；定性原文中的观察暂存 Evidence，验证前不提升为 canonical Fact |
| Derived Feature | 确定性公式 + 版本 + 输入 Fact 引用 + 有效性条件；如 FCFMargin | 现有 Feature Registry 引用；不保存“护城河分数”冒充客观特征 |
| Investment Concept | 共享研究概念及边界，例如 CompetitiveAdvantage；不预设特定投资者的判定阈值 | Concept |
| Question | 面向某主体/期间、可回答的研究问题；含所需证据与何种缺口会阻止回答 | Question |
| Claim | 对事实含义/机制的可争议判断；说明谁提出、适用对象、依据、反方 | Assertion，类型 `claim` |
| Hypothesis | 待检验的因果或预测命题；除 Claim 字段外，须有预期观察、期限/观察条件、反证方式 | Assertion，类型 `hypothesis`；未设检验者保持 draft |
| Evidence | 某 Fact、Feature 或 SourceSpan 被用于支持/挑战某命题的角色；支持强度由具体推理决定 | Evidence；记录来源、片段定位、主体、可靠性与独立来源组 |
| Reasoning Rule | 在哪些条件下，哪些前提共同支持何种判断；注明例外和可用范围 | Method，类型 `reasoning`；是可撤销推理，不是自然定律 |
| Valuation Method | 有经济适用条件的估值方法、输入契约、假设及敏感性；输出是情景估值，不是事实 | Method，类型 `valuation`；连接现有估值引擎 |
| Falsification Rule | 哪项观察、什么范围/窗口，足以挑战哪个必要前提；区分警报、降信念、失效 | Method，类型 `falsification`；阈值作者必须明确 |
| Case Study | 一组按时间组织的真实问题、论据、假说、更新与后续结果 | CaseStudy；结果未知可保持开放，禁止只收成功例 |

**“他说 X”与“X 为真”分开。** 能确认 Gavin 在采访中说过某句话，只支持一个发言记录；不直接证明其技术、财务或因果判断。供应商预计算 ROIC 也必须带 `derivation_kind/provider_definition`，不能靠记录名叫 Fact 隐去其计算性质。

第一批共享概念只需八个：**需求持续性、客户经济性、竞争优势、资本效率、增长久期、资本配置、预期差、永久损失风险**。TAM 是需求问题的测量框架，技术拐点是机制/情境，DCF 是方法；暂不为每个热词新设一级概念。Moat 表达为竞争优势加“持续性/防守机制”约束；它可帮助检索，但不能与短暂竞争优势无条件等价。

### 5.2 最小关系与一个不能省的结构

| 关系 | 用途 |
|---|---|
| Question `about` Concept/Subject；`requires` InputContract | 从问题产生数据/研究需求，不从数据库有什么反向拼文章 |
| Claim/Hypothesis `answers` Question；`about` Subject | 多个竞争解释可以回答同一道题 |
| Evidence `supports/challenges` Assertion | 必须写出理由与适用范围；一篇来源可支持其中一段、反对另一段 |
| InferenceApplication：premises + Method → conclusion | 显式保存一次推理中所有必要前提与缺失项，不能把多条件链条摊成无条件的“相关”边 |
| Hypothesis `tested_by` FalsificationRule | 观察结果更新状态；数据缺失≠反证成立 |
| Assertion `supersedes/refines` Assertion | 保存观点演化而不覆盖历史 |
| CaseStudy `contains` 有日期的研究记录；Brain `selects` Module/Method | 案例可跨公司；配置共享引用，不复制概念 |

`InferenceApplication` 是运行中的审计记录，不新增投资概念。例如“技术基准好”与“可量产/客户能迁移”是联合前提；缺少后一项时系统不能输出“必然夺取份额”。

### 5.3 最小公共字段与状态

- **身份/范围：** 稳定 ID、版本；发行人与证券分离。优先复用 `company_id/security_id`；确有需要才添加产品/分部/市场或私人公司的 ResearchSubject，不用名称模糊匹配，不给私人公司捏造 ticker。
- **时间：** 经济事件/期间、来源公开时间及精度、系统收录时间、判断有效范围、预测期限；另标记 `contemporaneous / retrospective_recollection / analyst_reconstruction`。只知日期则注明精度；后来回忆可以描述早期事件，却不能回填早期已公开证据。
- **出处：** URL/来源 ID、片段或页码/时间码、content hash（未来采集时生成）、作者/说话者/转录方、来源依赖组、许可与访问范围。没有保存的 hash 不伪造。
- **认识地位：** `investor_explicit / analyst_inferred / system_proposed`；来源可靠性、抽取确定性、推理充分性分开，不计算一个看似精确的综合正确概率。
- **运行状态：** `draft / open / supported / contested / invalidated / superseded`；另有 `missing_data / not_applicable / unavailable_at_cutoff`。状态更新须有原因、旧版本与来源，`supported` 不是“已证实真理”。

不设万能 `related_to`；不把相关性直接升级成因果；不自动累计重复转载的“支持票数”。

## 6. 六个可复用 Reasoning Modules

模块是**问题、输入契约、证据要求、推理与反证的模板**，不是一段万能 prompt。以下均为 [设计]，由第 4 节材料约束；不同 Brain 可以改变顺序和解释。

量化状态：**R**＝已注册语义指标/Feature；**D**＝底层可得，但需未来经验证的语义注册/跨期计算；**X**＝本地 canonical 无该内容。

| 模块 | 关键问题 | 必需量化 + 定性证据 | 推理与反证 |
|---|---|---|---|
| M1 需求、客户经济性与 TAM | 为谁解决什么问题？客户为何持续付费？潜在空间是否可服务？ | R 收入；D 增长/现金收款；X 客户队列、用量、留存、价格。客户访谈/合同、付费意愿、替代方案 | 自下而上估计可服务量与客户净价值；区分总用量和可收费量。ROI 不成立、留存弱、重复计算市场则挑战假说 |
| M2 竞争、价值获取与技术替代 | 价值由谁获得？对手为何不能复制？互补条件是什么？ | D 毛利额、研发、capex；X 份额、产品 TCO/基准、迁移成本、竞品路线/投标 | 优势 × 采用约束 × 对手反应 → 利润持续性；必要互补条件失效或迁移成本下降则反证 |
| M3 资本效率、配置与每股经济性 | 增长消耗什么资本？回报流向股东还是员工/客户？ | R FCF、FCFMargin、供应商 ROIC；D 股数/SBC、净融资、再投资。proxy、并购原件、维护性/增长性支出 | 区分经营改善、会计口径、杠杆和净额；再投资回报不足、每股价值受损或激励错配则挑战 |
| M4 增长久期与拐点 | 增长提前还是终局变大？约束会限制峰值还是延长周期？ | D 多期增长、增量利润/资本；X 渗透率、产能/良率、复购、组织变化 | 机制 → 财务兑现时序 → 情景；需求回吐、供给越界或新业务经济性未改善则挑战 |
| M5 预期与估值 | 当前价格要求兑现什么？自己的证据与预期差在哪里？ | R 市值/FCF；D EV/利润、历史轨迹；X PIT 共识/修正。指引、市场叙事及明确估值假设 | 反推所需增长/利润/久期，与可证据化情景比较；只有管理层指引时不得称“超一致预期” |
| M6 反证、脆弱性与更新 | 哪个前提最可能错？什么会造成永久损失？何时重审？ | D 现金/债务/股数；X 合同、融资条款、技术/监管风险、异议证据 | 逐项攻击必要前提，记录触发窗口与替代解释；区分假说被推翻、估值不划算、风险预算不允许三种原因 |

估值使用 Method 选择而非统一公式：经营企业可比较 DCF/倍数/反向估值；银行保险等必须通过经济类型门槛选择适当方法。不因某个 Brain 喜欢增长就绕过原有现金流、币种或模型适用性检查。组合仓位/执行不是本轮 ontology 必须实现的第七模块。

## 7. Gavin Baker Brain：共享结构上的有来源配置

**不新增 `GavinMoat/GavinROIC/GavinTAM`。** 保存一个引用共享模块的、可版本化的公开框架重建：

| 配置部分 | 第一版内容 | 出处与约束 |
|---|---|---|
| 模块选择/顺序 | 先检查产品/技术与客户变化，再追踪价值获取/久期，连接估值；M6 全程伴随 | [归纳] G1–G5、G8–G10；不是本人公布的固定流水线 |
| 优先问题 | 优势依赖哪个未验证前提？对手实际进度如何？增长能持续多久？价格已经要求什么？ | 每题连接具体来源，不赋予虚构的 30%/20% 权重 |
| 概念解释 | 竞争优势看系统互补、采用/替代；资本效率看方向与经济机制；增长久期区别于眼前增长 | 同一 Concept 下记录带条件解释，不改变 Concept 的共享定义 |
| 推理链 | 客户 ROI→采用/留存→现金；技术/供给约束→竞争反应→利润持续期；预期修正与长期久期分开 | [归纳]，用案例验证，不能套用于所有行业 |
| 证据偏好 | 产品/技术细节、竞争者与私人公司进度、实际财务、管理层激励、主动反方 | G1、G2、G9；非公开渠道在本系统无访问时明确缺失，不编造 channel checks |
| 估值偏好 | 结合近端与未来盈利、增长持续期、资本回报解释价格；允许跨行业比较 | G5；没有证据支持固定终值、折现率或机械倍数买入线 |
| 更新/反证 | 必要前提更新优先于维护旧故事；技术机制改变可以改变原判断 | G1、G2、G8；G10 的具体风险条件仅用于对应 AI 周期 |
| 失败处理 | 记录是否逻辑失效、估值变化或风险约束；不把下跌本身等同于错误 | G6；书中样本和他引用他人的规则不得冒充其固定个人纪律 |
| 历史案例 | Intel 失败、软件压力、全渠道零售、模型竞争观点更新 | 每例区分当时可知材料、后来本人回顾、独立后验结果 |

配置也要区分：**长期方法 / 行业模板 / 特定周期参数 / 单家公司假说**。2026 年 AI 观点不能覆盖成 2020 年就持有的判断；现有 Guru 头像、简介、13F 和 sector-edge proxy 都不是足够的 Brain 证据。

## 8. 如何连接 Fact OS：一个可执行但尚未实现的设计

```text
Investor Brain（选题、优先级、解释偏好）
  → Shared Module / Question（主体、截止日、所需证据）
    ├→ Semantic Input Contract → 现有 Registry / FactRepository → Facts / Features
    └→ Source Research → 可定位原文/访谈/产品/客户证据
  → Evidence + InferenceApplication → Claim / Hypothesis / Counter-hypothesis
  → Falsification tests + Valuation scenarios
  → 可追溯研究结论、未决问题、更新原因
```

### 8.1 输入契约与运行记录

Brain 只请求类似“某公司在截止日可知的季度收入增长、资本效率、客户留存证据”，绑定**共享语义 ID、定义版本、期间、单位、适用性和截止日**。供应商表/列映射只存在现有 Registry/adapter 一侧。`Revenue/ROIC` 可接现有注册；`FCFMargin` 计算器已在 Python 层，但目前无 Node/RPC Feature endpoint，仍需受限只读 adapter 复用原计算器。`RevenueGrowthYoY` 等是未来待实现契约，当前应明确返回 `not_supported`。

返回结果必须包含数据 lineage、可用时间、质量/缺口、manifest generation。一次 ResearchRun 固定 ontology/module/brain/method/feature 版本、Fact OS generation、来源集合、模型与抽取版本、as-of、依赖引用及输出 hash，并保存原始结构化输出。

**hash 不等于永久可重放。** 现有 FactRepository 固定当前读会话，旧代次之后可被 GC。未来须在许可边界内，把必要 Fact/Feature 返回值及版本、来源放入私有运行证据包，不进 Git/公共导出；若只保存引用且旧代次已不可用，只能追溯，不能声称完整重算。保存输入也不保证 LLM 重新生成逐字相同的结论。

### 8.2 实例：大厂 ROIC 上升，能否证明 AI 投资值得？

[G7] 中 Gavin 用大厂财务/利用情况支持其 AI 判断。以下是**系统设计示例，不是已经完成的 AI 投资回报审计，也不假托为 Gavin 的完整推理**：

1. **问题：** 增加 AI 投资是否产生超过资本成本的增量回报？先定公司/分部、投资批次、观察期。
2. **Fact/Feature：** 读取收入、现金流、供应商 ROIC；请求尚待注册的 capex/资本效率轨迹。标明全公司口径不是 AI 项目口径。
3. **外部 Evidence：** 需要利用率、增量收入/成本、折旧寿命、项目资本及客户回报；没有就记录缺口。
4. **正方假说：** AI 改善产品/需求，新增盈利足以覆盖新增资本。**反方：** 旧业务利润、成本削减、分母口径或支出兑现滞后造成整体指标改善。
5. **推理门槛：** 无分部/项目归因和合理反事实，只能说“整体结果与该假说相容”，不能说“证明 AI ROI 为正”。
6. **下一步/反证：** 补客户与项目证据；检验新增收入/节约是否兑现。阈值和窗口由分析者另行定义；在数据缺失时保持 open，而非判定牛/熊胜出。

这比“读取高 ROIC→给高护城河分”更接近实际研究：系统明确知道**还不能推出什么**。正反方共享同一 Fact 集，而不是分别挑选有利事实。

### 8.3 与现有仓库的接点和不做的事

- 读取保持 [FactRepository/RPC](../fact_os/repository.py) → [Node bridge](../server/factRepository.js)；固定 manifest，批次不混 generation，不增加静默外网 fallback。
- 复用 guidance/Q&A/podcast 的来源对象作为 Evidence adapter；canonical 财务仍走 Fact OS。发表指引、分析师预测、模型假设各保持自身类型。
- 复用 [InvestmentStore](../server/investmentStore.js) 的 owner 隔离、append-only、幂等和版本思路承载私人研究更新；共享 ontology/module/brain 定义另做版本化 catalogue。**现有事件表有 owner/ticker 约束，不能把跨公司概念塞进假 ticker，也不能在未设计扩展前宣称兼容。**
- 原始资料权限随引用传播：私人研究/许可财务不能因被共享 Brain 引用而进入公共导出；共享定义不含私人研究值。
- 现有公开 fair value 保持归档状态；研究情景通过已有估值输入审核后生成独立 scenario，不覆盖已发布估值，也不把外部观点静默写进 DCF。
- 按 [Ontology retirement](audits/ontology-retirement-2026-09-13.md)，这层属于现有 investment research workspace 的语义基础，**不恢复已退役的独立 Ontology/DBMF 页面、API 或排名模块**。

## 9. 泛化与轻量 Ontology Auditor

### 9.1 其他 Investor Brains 不需要重新建 ontology

下表仅为**架构兼容性测试的候选配置**，不是本轮已完成原始材料验证的其他投资者 Brain。后续必须像 Gavin 一样用本人材料校准。

| 候选 Brain | 同一概念/模块可以怎样换优先级与解释 | 不需要改的部分 |
|---|---|---|
| Buffett | M2/M3：优势持续性、可理解性、再投资与股东现金；用不同现金流调整解释资本效率 | 同一竞争优势/资本效率、事实引用、证伪结构；调整作为有版本的方法 |
| Ackman | M2/M3/M5：商业结构、治理/资本配置改变、催化事件及估值兑现 | 催化剂是有期限 Hypothesis，治理原文是 Evidence，不需专属概念树 |
| Li Lu | M2/M3/M6：理解边界、管理层、长期价值与永久损失；更严的证据门槛 | 缺证据可拒绝结论，安全边际通过估值情景与风险条件表达 |
| Druckenmiller | M4/M5/M6：宏观/流动性、预期变化与时点；周期解释优先 | 新增宏观 Fact source adapter，不让现有 SF1 冒充利率数据；组合风控后续独立扩展 |
| 用户自己的框架 | 可保留以上任意链条并调整研究顺序，保存何时为何改变规则 | 仍指向同一事实、概念与方法；不复制成“我的 ROIC 数据库” |

同一 Concept 允许多个带范围的解释；同一 Method 可有不同参数；同一 Fact 可以产生互相竞争的 Claim。**定义共享不要求结论一致。** 新行业知识先作为 scope/证据/规则进入，只有出现不能由既有边界表达的重复需求，才新增概念。

### 9.2 Ontology Auditor：自动发现、验证与安全演化

触发：新增来源/Claim、规则变更、研究运行失败或 catalogue 发布。输入是来源片段、定义、依赖图与案例测试；输出是**带证据的变更提案**，不是自动宣布新的投资真理。

| 检查 | 最小自动检测与处理 |
|---|---|
| 重复概念 | 名称/定义/使用情境找候选；确认同一含义后建议 alias。相似 embedding 本身不能证明等价 |
| 应合并/拆分 | 合并看边界/输入/反证是否等价；拆分看同名概念是否在不同范围发生系统性冲突。保留历史 ID 与映射 |
| 过度泛化 | 缺范围、只基于单一公司/牛市例子、忽略必要前提的规则降级为 scoped/candidate |
| 无依据关系 | support 边须有可定位片段和推理理由；发现把受访者观点提升为事实、把相关写成因果时拦截 |
| 矛盾 | 先对齐判断作者、命题层级、主体、日期、口径、单位、条件；分清真冲突、观点更新、抽取错误、口径差异。分歧可以并存；`supersedes` 须有明确更新依据，不能自动消灭反方 |
| 投资者特有观念冒充普适 | 检查来源身份/适用范围；单个投资者偏好放 Brain overlay，不升级共享公理 |
| 时间/数据泄漏 | 阻止未来来源、MR 倒灌、无披露时间的持仓回放、同源转录重复计票、缺数据当反证 |

轻量流程：**检测 → 生成证据包/影响范围 → 在候选版本重放案例 → 非破坏性发布或隔离 → 可回滚**。

- 自动完成格式校验、完全重复去重、确定性坏引用拦截；同义候选先作为可逆检索 alias，不悄悄合并语义 ID。
- 有实质影响的 merge/split/规则修改进入 shadow catalogue；必须通过来源、范围、反证及历史案例测试。不能仅凭另一个 LLM 说“同意”而发布。
- 证据仍含糊时保留现版、隔离候选并报告异常，日常研究继续使用稳定版；这使系统不依赖逐条人工维护。高风险语义变更允许例外审阅，不能承诺全自动保证正确。
- 每次发布保存旧/新定义、依据、迁移映射、受影响 Claim/Run、测试结果及版本指针。旧研究不改写；未来受影响结论标记需重评；回滚 catalogue 指针即可恢复旧语义，不删除事件。

必须覆盖的回归例：`Moat` 不可与短暂优势无条件合并；税前供应商 ROIC 与税后经济回报不可合并；Intel 的未验证前提不可事后补造；G8 的观点更新不可误报为同一时期自相矛盾，2025 回顾也不能充当 2023 的同期证据；一期节目三个转载不可视为三个独立证据。

## 10. 推荐下一步：先做一条研究链，不先搭一座知识图谱

**下一实施单元：只读“问题 → 证据 → 正反假说”研究切片。** 本报告不实施它。

1. 冻结本文最小记录契约、八个初始概念和六模块定义；建立 `Gavin-public-framework v0.1` 的出处清单，不宣称真实内部 Brain。
2. 精标约 20–30 个来源片段，做三个测试案例：Intel 2020 失败、软件收入压力、2025–26 模型竞争观点更新。另以第 8 节 AI ROI 作数据连接验收题。来源定位与短摘录即可，不批量复制版权全文进 Git。
3. 先接已有 Revenue/FCF/ROIC，并以受限 Feature adapter 复用 FCFMargin 计算器；只为这批问题按需补经过验证的增长/利润/资本轨迹契约。不要为了填满页面就重建全部指标。
4. 输出一张研究卡：问题、已知事实、必要但未知的前提、正方/反方、反证、下一条最有价值的证据；每个结论能追到原片段或数据版本。
5. 跑 Auditor 的重复/时间/归属/坏引用/案例测试；再用第二位投资者的少量原始材料检验是否无需改变核心记录类型。

**验收标准：**

- 每个实质判断有来源或明确标为系统假设；不能把采访主持人、被引用作者的规则归到 Gavin 名下。
- 历史案例分开“当时公开资料”与“后来回忆”：例如 8 月 Intel 复盘不能作为 6 月投资时已知的公开证据。
- 缺前提、币种/口径不兼容、无 PIT 信息时能拒绝强结论；有许可范围内完整输入证据包的运行可审计重放，仅有失效引用者明确不可重算。
- 同一 Fact 集能表达正反两种解释，并列明哪条新证据会改变判断；没有因观点冲突就删除其中一方。
- Brain 配置看不到 Sharadar 表名/列名；新增第二个 Brain 不复制概念、不改 Fact OS 存储架构。
- 不更改已发布估值、不访问私人组合、不恢复退役模块；所有 ontology 变更可回滚。

成功标准不是“回答像 Gavin”，而是：**任何读者都能看到这个判断依赖什么、哪里还不知道、什么证据足以让它改变。**

---

### 本地代码核验索引

行号为本次工作树位置；这里只提供实现依据，本轮未修改这些文件。

| 文件 | 核验位置 / 内容 |
|---|---|
| [fact_os/registry.py](../fact_os/registry.py) | :6 七个 Metric；:64 同期输入 FeatureEngine；:81 唯一默认 Feature |
| [fact_os/repository.py](../fact_os/repository.py) | :68 固定快照；:163 lineage；:184 身份；:368/:415 财务 PIT；:446 持仓 PIT 限制；:627 语义指标 |
| [fact_os/maintenance.py](../fact_os/maintenance.py) | :10 旧代次 GC 与活跃读会话保护；generation hash 不保证永久可重放 |
| [fact_os/rpc.py](../fact_os/rpc.py)、[server/factRepository.js](../server/factRepository.js) | allowlist、缺失 fail closed；Node :69/:90 读/批读与 generation 约束 |
| [server/investmentSource.js](../server/investmentSource.js) | :55 模型池 universe；:108 能力缺口；:109 retrospective |
| [server/investmentQuality.js](../server/investmentQuality.js)、[server/valuationFacts.js](../server/valuationFacts.js) | curated quality；:106 archived_not_recomputed |
| [server/investmentGuidance.js](../server/investmentGuidance.js)、[server/investmentEarnings.js](../server/investmentEarnings.js) | 原文 scope/目标年审核；Q&A 可见日期及 research-only |
| [server/localDatabase.js](../server/localDatabase.js)、[server/importPitQuarterlyValuations.js](../server/importPitQuarterlyValuations.js) | :169 podcast insight schema；:228 guidance schema |
| [server/investmentStore.js](../server/investmentStore.js) | :22 owner/ticker 事件结构；:29 不可变触发器；:46 幂等追加 |

研究边界：没有完成 Gavin 全部历史音视频的逐字档案，也没有独立验证其每个公司观点的投资收益；本轮完成的是以真实资料约束的可实施设计，不是投资建议或已经上线的系统。

[G1]: https://business.columbia.edu/sites/default/files-efs/imce-uploads/Graham%20%26%20Doddsville_Issue%2043_vF.pdf
[G2]: https://gavin-baker.medium.com/investing-mistakes-chapter-1001-9f0b7dbc6637
[G3]: https://gavin-baker.medium.com/software-contracts-first-lien-debt-and-the-reality-that-no-revenue-is-truly-recurring-6c4d164778d5
[G4]: https://gavin-baker.medium.com/why-category-leading-brick-and-mortar-retailers-are-likely-the-biggest-long-term-covid-d70b8dfadc20
[G5]: https://gavin-baker.medium.com/fear-is-the-mind-killer-secular-growth-stocks-are-becoming-increasingly-attractive-67127573204e
[G6]: https://gavin-baker.medium.com/lessons-on-winning-and-losing-as-an-investor-from-the-art-of-execution-e6aafe817038
[G7]: https://www.a16z.news/p/gavin-baker-and-david-george-on-positional
[G8]: https://podscripts.co/podcasts/invest-like-the-best-with-patrick-oshaughnessy/gavin-baker-nvidia-v-google-scaling-laws-and-the-economics-of-ai-invest-like-the-best-ep451
[G9]: https://pod.wave.co/podcast/invest-like-the-best-with-patrick-oshaughnessy-48a998b1-8bc3-4e91-9c00-6d2f4d646fdd/gavin-baker-watts-and-wafers-invest-like-the-best-ep473
[G10]: https://steadcast.co/show/invest-like-best/gavin-baker-ai-market-jitters-invest-like-the-best-ep-485
[G11]: https://gavin-baker.medium.com/thoughts-post-e3-2019-58cb42c61bf4
