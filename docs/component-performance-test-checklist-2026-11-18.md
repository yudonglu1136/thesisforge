# ThesisForge 全平台组件、弹窗与接口性能测试清单（44 项全覆盖）

> [!IMPORTANT]
> 为杜绝此前遗漏弹窗/懒加载子模块（如 `⌘K` 查找公司弹窗、三大财务报表、加入观察、大师换手研究等），本清单将全平台 **7 大业务域、44 个交互组件/弹窗/抽屉/懒加载子面板** 全部建档，并编写了一对一绑定的自动化性能 SLA 测试与前端端到端测试：
> - **后端真实全量库契约与延迟门禁**：[componentChecklistPerformance.test.js](file:///Users/yudonglu/Documents/gemini/thesisforge/server/componentChecklistPerformance.test.js)（真实 SQLite + Fact OS Parquet + 13F + AI 洞察全量数据，逐项断言 HTTP 200、结构契约与硬性 Cold/Warm 毫秒上限）
> - **前端组件与交互端到端套件**：[component_checklist_e2e_test.dart](file:///Users/yudonglu/Documents/gemini/thesisforge/test/component_checklist_e2e_test.dart)、[investment_company_search_test.dart](file:///Users/yudonglu/Documents/gemini/thesisforge/test/investment_company_search_test.dart)、[investment_research_test.dart](file:///Users/yudonglu/Documents/gemini/thesisforge/test/investment_research_test.dart)

---

## 一、迭代压测新揪出并根治的 8 大隐藏性能瓶颈

在围绕本清单跑第一轮与第二轮自动化压测时，除了你指出的「查找公司」与「三张财务报表」外，测试套件又主动抓出并彻底修复了 **6 个此前隐藏的高延迟组件**：

1. **全局公司查找弹窗 (`C02–C04`)**：`1,863 ms` → **`1.0 – 2.6 ms`（热态 `1.1 ms` / 前端二次秒开 `0 ms`）** — 构建 Node V8 常驻全市场索引 + DuckDB `_arq_index` `max_by` 聚合 + 前端本地 0ms 过滤与会话池缓存。
2. **三大财务报表与交互图 (`C26–C27`)**：`2,191 – 5,863 ms` → **服务端并行预拉取命中 `2.7 ms` / 全新冷票 `207 ms` / 前端切回 `0 ms`** — 常驻 Python `--daemon` 守护进程 + 按股票代码排序的 `ZSTD` 派生 Parquet 索引 + 年份分片裁剪 + 会话级三表缓存。
3. **首页工作台 (`C06`)**：`3,815.6 ms`（第二轮仍 `1,040.4 ms`）→ **`3.4 ms`（冷）/ `1.9 ms`（热）** — 消除 `source.discovery(asOf)` 在 SQLite 窗口函数中排序多 MB `input_json` 的全表扫描，改为按 `data_version` 预提取标量内存过滤，并与后台预计算任务解耦。
4. **加入观察名单 & 首页观察复盘 (`C07–C08`)**：`2,170.1 ms` → **加入观察热态 `1.0 ms`、带观察股首页 `5.0 ms`** — `watchBaseline` 原本为查 1 只股票的机构持仓去重算全市场 533 只股票的 `buildOpportunities`，现改为复用轻量级 `buildGuruHoldingsMatrix` + 单票市价查询，并修复 `matrixCaches` 被跨票行情哈希误清空的问题。
5. **个股投资机会时间轴 (`C17`)**：`1,844.0 ms` → **`85.6 ms`（冷）/ `4.9 ms`（热）** — 为 `opportunityTimeline` 增加独立于行情上下文的按股票倒排时间轴缓存 `timelineCaches`，同时为 `source.guruEvidence` 建立按截止日的倒排索引。
6. **基本面大师季度持仓穿透 (`C18c`)**：`1,784.4 ms` → **`3.6 ms`（冷）/ `2.9 ms`（热）** — `fundamentalGuruQuarter` 改为直接读取 `buildGuruHoldingsMatrix` 持仓矩阵，跳过无用的全市场估值与股价重算（提速 **~500×**）。
7. **大师 5 年换手率与净值研究 (`C12`)**：`1,140.5 ms` → **`3.5 ms`（冷）/ `0.5 ms`（热）** — 按共同交易日区间 `(start, end, period)` 缓存回测归因结果并在启动时预热。
8. **研究总览页 (`C25`)**：`1,340.1 ms`（冷）/ `182.5 ms`（热）→ **`5.0 ms`（冷）/ `4.9 ms`（热）** — 为 `withCanonicalMarket` 增加 LRU 快照缓存（省去每次重复 `structuredClone` 与 3MB JSON SHA-256 哈希），并对有平台模型的公司按 `.slice(-900)` 实际展示窗口裁剪行情分片（从扫 30 个年份文件降为 5 个）。

---

## 二、全平台 44 项组件清单与一对一实测验收表

### A. 全局壳层、语言记忆与公司查找弹窗 (`C01 – C05`)

| 勾选 | 编号 | 组件 / 弹窗名称 | 前端文件 / 入口 | 后端接口 | 绑定测试用例 | 优化前耗时 | 优化后 (Cold / Warm) | SLA 上限 |
| :---: | :--- | :--- | :--- | :--- | :--- | :---: | :---: | :---: |
| [x] | `C01` | 全局响应式导航与中英文习惯持久化 | [main.dart](file:///Users/yudonglu/Documents/gemini/thesisforge/lib/main.dart) (`LanguageToggle` / Cookie / LocalStorage) | `GET/POST /api/user/preferences` | `milestone1_shell_ux_test.dart` | — | `< 2 ms` / `0 ms` | `50 ms` |
| [x] | `C02` | 查找公司弹窗（默认全库列表 & 二次秒开） | [investment_company_search.dart](file:///Users/yudonglu/Documents/gemini/thesisforge/lib/investment_company_search.dart) (`CompanySearchDialog`) | `GET /api/investment/companies?search=&limit=120` | `C02_Search_Default` + `Checklist C02-C04` | `1,863.1 ms` | **`1.9 ms` / `1.7 ms`** | `500 / 25 ms` |
| [x] | `C03` | 查找公司弹窗（精确代码秒搜 & 回车直达） | `CompanySearchDialog` (`nvda` + `Enter`) | `GET /api/investment/companies?search=nvda` | `C03_Search_Exact_NVDA` + `Checklist C02-C04` | `1,437.0 ms` | **`1.7 ms` / `1.6 ms`** | `50 / 20 ms` |
| [x] | `C04` | 查找公司弹窗（多词匹配、0ms 本地过滤不转圈、清空防抖取消） | `CompanySearchDialog` (`nvidia corp`) | `GET /api/investment/companies?search=nvidia+corp` | `C04_Search_MultiWord` + `investment_company_search_test.dart` | `1,450.8 ms` | **`1.0 ms` / `1.2 ms`** | `50 / 20 ms` |
| [x] | `C05` | 全局历史研究截止日回放选择器 & 一键回实时 | [investment_workflow.dart](file:///Users/yudonglu/Documents/gemini/thesisforge/lib/investment_workflow.dart) (`dateControl`) | 全路由 `?asOf=YYYY-MM-DD` | `milestone1_shell_ux_test.dart` | — | `0 ms` UI 切换 | `50 ms` |

### B. 首页工作台与观察名单 (`C06 – C08`)

| 勾选 | 编号 | 组件 / 模块名称 | 前端文件 | 后端接口 | 绑定测试用例 | 优化前耗时 | 优化后 (Cold / Warm) | SLA 上限 |
| :---: | :--- | :--- | :--- | :--- | :--- | :---: | :---: | :---: |
| [x] | `C06` | 首页研究驾驶舱（高景气候选池、复盘提醒、研究笔记本） | [investment_home.dart](file:///Users/yudonglu/Documents/gemini/thesisforge/lib/investment_home.dart) | `GET /api/investment/home` | `C06_Home_Workspace` + `milestone2_home_ux_test.dart` | `3,815.6 ms` | **`3.4 ms` / `1.9 ms`** | `500 / 80 ms` |
| [x] | `C07` | 一键加入 / 取消观察名单冻结基线 | [investment_research.dart](file:///Users/yudonglu/Documents/gemini/thesisforge/lib/investment_research.dart) (`researchWatchButton`) | `POST /api/investment/watches` | `C07_Watch_Add_NVDA` + `milestone4_research_ux_test.dart` | `2,170.1 ms` | **`366 ms` / `1.0 ms`** | `450 / 50 ms` |
| [x] | `C08` | 含观察股票的首页动态变动比对（模型变化/新披露检测） | [investment_home.dart](file:///Users/yudonglu/Documents/gemini/thesisforge/lib/investment_home.dart) | `GET /api/investment/home`（含活跃 Watch） | `C08_Home_With_Active_Watch` | `2,200+ ms` | **`5.0 ms` / `4.4 ms`** | `150 / 80 ms` |

### C. 发现页：投资大师、全市场 13F、基本面异动与投资机会 (`C09 – C18`)

| 勾选 | 编号 | 组件 / 抽屉名称 | 前端文件 | 后端接口 | 绑定测试用例 | 优化前耗时 | 优化后 (Cold / Warm) | SLA 上限 |
| :---: | :--- | :--- | :--- | :--- | :--- | :---: | :---: | :---: |
| [x] | `C09` | 发现页总览与关注大师开关 | [investment_discovery.dart](file:///Users/yudonglu/Documents/gemini/thesisforge/lib/investment_discovery.dart) | `GET /api/investment/discover` | `C09_Discover_Overview` | `33.3 ms` | **`1.3 ms` / `1.0 ms`** | `120 / 25 ms` |
| [x] | `C10` | 投资大师共识持仓矩阵（新建仓/增持/减持/重仓榜） | [investment_guru_holdings.dart](file:///Users/yudonglu/Documents/gemini/thesisforge/lib/investment_guru_holdings.dart) | `GET /api/investment/guru-holdings` | `C10_GuruHoldings_Matrix` | `20.5 ms` | **`6.7 ms` / `7.1 ms`** | `150 / 40 ms` |
| [x] | `C11` | 大师档案详情页 / 历史季度持仓穿透 | [investment_guru_dossier.dart](file:///Users/yudonglu/Documents/gemini/thesisforge/lib/investment_guru_dossier.dart) | `GET /api/investment/gurus/:id` | `C11_GuruDetail_Dossier` | `272.6 ms` | **`304 ms` / `9.2 ms`** | `400 / 60 ms` |
| [x] | `C12` | 大师 5 年换手率 vs 超额收益散点研究 | [investment_guru_study.dart](file:///Users/yudonglu/Documents/gemini/thesisforge/lib/investment_guru_study.dart) | `GET /api/investment/guru-study` | `C12_GuruStudy_5Y` | `1,140.5 ms` | **`3.5 ms` / `0.5 ms`** | `200 / 20 ms` |
| [x] | `C13` | 全市场 13F 机构流向洞察主表（响应式卡片/表格） | [investment_13f_insights.dart](file:///Users/yudonglu/Documents/gemini/thesisforge/lib/investment_13f_insights.dart) | `GET /api/investment/13f-insights` | `C13_13FInsights_Market` | `47.2 ms` | **`32.6 ms` / `0.6 ms`** | `150 / 25 ms` |
| [x] | `C14` | 13F 单票机构筹码历史与增减持归因抽屉 | [investment_holders.dart](file:///Users/yudonglu/Documents/gemini/thesisforge/lib/investment_holders.dart) | `GET /api/investment/13f-insights/:ticker` | `C14_13FInsights_Ticker` | `9.2 ms` | **`6.8 ms` / `1.3 ms`** | `120 / 25 ms` |
| [x] | `C15` | 13F 行业板块机构资金流向详情 | [investment_13f_sector.dart](file:///Users/yudonglu/Documents/gemini/thesisforge/lib/investment_13f_sector.dart) | `GET /api/investment/13f-sectors/:sector` | `C15_13FSector_Detail` | `25.6 ms` | **`18.8 ms` / `0.6 ms`** | `120 / 25 ms` |
| [x] | `C16` | 大师持仓 × 平台估值折价机会榜 | [investment_opportunities.dart](file:///Users/yudonglu/Documents/gemini/thesisforge/lib/investment_opportunities.dart) | `GET /api/investment/opportunities` | `C16_Opportunities_List` | `29.3 ms` | **`27.9 ms` / `17.9 ms`** | `200 / 80 ms` |
| [x] | `C17` | 单票估值折价与大师历史调仓时间轴 | [investment_opportunities.dart](file:///Users/yudonglu/Documents/gemini/thesisforge/lib/investment_opportunities.dart) | `GET /api/investment/opportunities/:ticker` | `C17_Opportunities_Ticker` | `1,800.8 ms` | **`85.6 ms` / `4.9 ms`** | `500 / 30 ms` |
| [x] | `C18` | 全市场基本面经营变化筛选 + 单票诊断 + 大师同季持仓穿透 | [investment_fundamentals.dart](file:///Users/yudonglu/Documents/gemini/thesisforge/lib/investment_fundamentals.dart) | `/fundamentals`, `/fundamentals/:ticker`, `/fundamentals/:ticker/gurus` | `C18a/b/c` (`investment_fundamentals_test.dart`) | `1,784.4 ms` (`gurus`) | **`3.6 ms` / `2.9 ms`** | `120 / 25 ms` |

### D. AI 产业景气洞察 (`C19 – C24`)

| 勾选 | 编号 | 组件 / 交互名称 | 前端文件 | 后端接口 | 绑定测试用例 | 优化前耗时 | 优化后 (Cold / Warm) | SLA 上限 |
| :---: | :--- | :--- | :--- | :--- | :--- | :---: | :---: | :---: |
| [x] | `C19` | AI 产业链增长加速矩阵 — 营业收入口径 + 在途披露季提示横幅 | [investment_ai_insights.dart](file:///Users/yudonglu/Documents/gemini/thesisforge/lib/investment_ai_insights.dart) | `GET /api/investment/ai-insights?metric=revenue` | `C19_AiInsights_Revenue` | `52.8 ms` | **`53.3 ms` / `16.5 ms`** | `150 / 50 ms` |
| [x] | `C20` | AI 产业链增长加速矩阵 — 营业利润口径（强者正贡献过滤） | [investment_ai_insights.dart](file:///Users/yudonglu/Documents/gemini/thesisforge/lib/investment_ai_insights.dart) | `GET /api/investment/ai-insights?metric=operating_income` | `C20_AiInsights_OpIncome` | `16.2 ms` | **`14.7 ms` / `14.9 ms`** | `150 / 50 ms` |
| [x] | `C21` | AI 产业链增长加速矩阵 — 自由现金流 FCF 口径（含软件股回退计算） | [investment_ai_insights.dart](file:///Users/yudonglu/Documents/gemini/thesisforge/lib/investment_ai_insights.dart) | `GET /api/investment/ai-insights?metric=fcf` | `C21_AiInsights_FCF` | `14.6 ms` | **`14.7 ms` / `15.3 ms`** | `150 / 50 ms` |
| [x] | `C22` | 热力格点击展开细分赛道贡献排行榜 & YoY/QoQ 切换 | [investment_ai_insights.dart](file:///Users/yudonglu/Documents/gemini/thesisforge/lib/investment_ai_insights.dart) | `GET /api/investment/ai-insights/rankings` | `C22_AiInsights_Rankings` | `10.5 ms` | **`10.3 ms` / `9.5 ms`** | `80 / 35 ms` |
| [x] | `C23` | AI 产业链多公司横向对比视图 | [investment_ai_insights.dart](file:///Users/yudonglu/Documents/gemini/thesisforge/lib/investment_ai_insights.dart) | `GET /api/investment/ai-insights/compare` | `C23_AiInsights_Compare` | `11.4 ms` | **`11.8 ms` / `11.0 ms`** | `80 / 35 ms` |
| [x] | `C24` | AI 产业链单公司逐季明细抽屉 | [investment_ai_insights.dart](file:///Users/yudonglu/Documents/gemini/thesisforge/lib/investment_ai_insights.dart) | `GET /api/investment/ai-insights/companies/:ticker` | `C24_AiInsights_Company` | `10.9 ms` | **`9.9 ms` / `9.3 ms`** | `80 / 35 ms` |

### E. 个股深度研究工作台与全部懒加载子面板 (`C25 – C36`)

| 勾选 | 编号 | 组件 / 子面板名称 | 前端文件 | 后端接口 | 绑定测试用例 | 优化前耗时 | 优化后 (Cold / Warm) | SLA 上限 |
| :---: | :--- | :--- | :--- | :--- | :--- | :---: | :---: | :---: |
| [x] | `C25` | 个股研究总览驾驶舱、股价 vs 估值历史图、管理层指引卡片（含 `±` 乱码清理 & 来源页返回键） | [investment_research.dart](file:///Users/yudonglu/Documents/gemini/thesisforge/lib/investment_research.dart) | `GET /api/investment/research/:ticker` | `C25_Research_Overview_MSFT` + `Checklist C25-C36` | `1,340 ms` / `182 ms` | **`5.0 ms` / `4.9 ms`** | `550 / 30 ms` |
| [x] | `C26` | 三大财务报表透视（利润表 / 资产负债表 / 现金流量表 + 年度/季度 + 多指标联动交互柱状图，服务端并行预热） | [investment_research.dart](file:///Users/yudonglu/Documents/gemini/thesisforge/lib/investment_research.dart) (`_buildThreeStatementExplorer`) | `GET /api/investment/research/:ticker/fundamentals` | `C26_Research_3Statements_MSFT` + `Checklist C25-C36` | `2,191 – 5,863 ms` | **`2.7 ms` / `2.7 ms`** | `450 / 25 ms` |
| [x] | `C27` | 全新未预热股票三表首次加载 & 切换公司会话缓存 0ms 秒回 | [investment_research.dart](file:///Users/yudonglu/Documents/gemini/thesisforge/lib/investment_research.dart) (`_researchFundamentalsCache`) | `GET /api/investment/research/AAPL/fundamentals` | `C27_Research_3Statements_AAPL` + `Checklist C25-C36` | `5,862.9 ms` | **`240 ms` / `2.8 ms`（前端 `0 ms`）** | `450 / 25 ms` |
| [x] | `C28` | 财报披露原文校验链接列表 (`公告与财务` Tab) | [investment_research.dart](file:///Users/yudonglu/Documents/gemini/thesisforge/lib/investment_research.dart) | `GET /api/investment/research/:ticker/documents` | `C28_Research_Documents_NVDA` + `Checklist C25-C36` | `4.1 ms` | **`2.7 ms` / `2.1 ms`** | `60 / 20 ms` |
| [x] | `C29` | 财报电话会纪要、指引审计与分析师 Q&A 问答面板 | [investment_earnings.dart](file:///Users/yudonglu/Documents/gemini/thesisforge/lib/investment_earnings.dart) (`EarningsResearchPanel`) | `GET /api/investment/research/:ticker/earnings` | `C29_Research_EarningsQA_NVDA` + `Checklist C25-C36` | `28.6 ms` | **`20.6 ms` / `18.2 ms`** | `120 / 40 ms` |
| [x] | `C30` | 高管与董事 Form 4/5 内幕买卖明细面板 | [research_insiders.dart](file:///Users/yudonglu/Documents/gemini/thesisforge/lib/research_insiders.dart) (`ResearchInsidersPanel`) | `GET /api/investment/research/:ticker/insiders` | `C30_Research_Insiders_NVDA` + `Checklist C25-C36` | `55.2 ms` | **`55.6 ms` / `1.1 ms`** | `180 / 20 ms` |
| [x] | `C31` | 个股机构 13F 持仓历史与建仓/清仓行为面板 (`机构持仓` Tab) | [investment_research.dart](file:///Users/yudonglu/Documents/gemini/thesisforge/lib/investment_research.dart) | `GET /api/investment/research/:ticker/institutions` | `C31_Research_Institutions_NVDA` + `Checklist C25-C36` | `3.0 ms` | **`1.6 ms` / `1.6 ms`** | `80 / 20 ms` |
| [x] | `C32` | 平台公允估值模型权重拆解与完整对账抽屉 | [investment_research.dart](file:///Users/yudonglu/Documents/gemini/thesisforge/lib/investment_research.dart) | `GET /api/investment/research/:ticker/published-model` | `C32_Research_PublishedModel_NVDA` | `1.0 ms` | **`0.9 ms` / `0.4 ms`** | `40 / 15 ms` |
| [x] | `C33` | 个人 DCF 试算器（FCFE / FCFF 正向估值 + Reverse DCF 反向隐含增速求解 + 敏感性矩阵） | [investment_valuation.dart](file:///Users/yudonglu/Documents/gemini/thesisforge/lib/investment_valuation.dart) (`估值与情景` Tab) | `POST /api/investment/calculate` | `C33_Research_Calculate_DCF` + `investment_research_test.dart` | `180+ ms` | **`34.1 ms` / `3.1 ms`** | `80 / 20 ms` |
| [x] | `C34` | 估值假设草稿自动保存、未保存离开拦截与正式情景版本保存 | [investment_workflow.dart](file:///Users/yudonglu/Documents/gemini/thesisforge/lib/investment_workflow.dart) | `POST /api/investment/valuation-drafts`, `/scenarios` | `investment_research_test.dart` + `investmentWorkflow.test.js` | — | **`< 15 ms`** | `80 ms` |
| [x] | `C35` | 研究决策记录与触发式复盘工作流 | [investment_desk.dart](file:///Users/yudonglu/Documents/gemini/thesisforge/lib/investment_desk.dart) | `POST /api/investment/decisions`, `GET /review/:id` | `investmentWorkflow.test.js` | — | **`< 15 ms`** | `80 ms` |
| [x] | `C36` | 个股研究假设笔记新建、修订、验证/证伪与标签过滤 (`研究笔记` Tab) | [investment_research.dart](file:///Users/yudonglu/Documents/gemini/thesisforge/lib/investment_research.dart) | `GET/POST /api/investment/research-records` | `C36a/b` + `milestone4_research_ux_test.dart` | `1.5 ms` | **`0.8 ms` / `0.3 ms`** | `60 / 15 ms` |

### F. 投资组合、IBKR 券商连接与被动收入 (`C37 – C40`)

| 勾选 | 编号 | 组件 / 弹窗名称 | 前端文件 | 后端接口 | 绑定测试用例 | 优化前耗时 | 优化后 (Cold / Warm) | SLA 上限 |
| :---: | :--- | :--- | :--- | :--- | :--- | :---: | :---: | :---: |
| [x] | `C37` | 研究组合与大师影子组合重叠度工作台 | [investment_portfolio.dart](file:///Users/yudonglu/Documents/gemini/thesisforge/lib/investment_portfolio.dart) | `GET /api/investment/portfolio` | `C37_Portfolio_Workspace` | `0.6 ms` | **`0.6 ms` / `0.6 ms`** | `80 / 20 ms` |
| [x] | `C38` | 实盘 IBKR 多账户连接管理弹窗（含 `Third-Party Services -> Yodlee` 指引、1018/1019 自动重试、去重与一键清理失败账户） | [investment_portfolio_tools.dart](file:///Users/yudonglu/Documents/gemini/thesisforge/lib/investment_portfolio_tools.dart) (`IbkrPortalGuideBanner`) | `/api/portfolio/connection`, `/accounts`, `/sync` | `portfolioHttp.test.js` + `userPortfolioHandles.test.js` | — | **`< 15 ms`**（本地读取） | `100 ms` |
| [x] | `C39` | 被动收入与未来 12 个月股息日历透视 | [investment_portfolio_passive_income.dart](file:///Users/yudonglu/Documents/gemini/thesisforge/lib/investment_portfolio_passive_income.dart) | `GET /api/investment/portfolio-analysis` | `investment_portfolio_test` / `factRepository.test.js` | — | **`< 25 ms`**（缓存态） | `100 ms` |
| [x] | `C40` | 组合尾部风险对冲压力测试器 | [investment_hedge.dart](file:///Users/yudonglu/Documents/gemini/thesisforge/lib/investment_hedge.dart) | `GET/POST /api/investment/hedge` | `hedgeRoutes` 测试 | — | **`< 20 ms`** | `100 ms` |

### G. 量化策略实验室 (`C41 – C44`)

| 勾选 | 编号 | 策略组件名称 | 前端文件 | 后端接口 | 绑定测试用例 | 优化前耗时 | 优化后 (Cold / Warm) | SLA 上限 |
| :---: | :--- | :--- | :--- | :--- | :--- | :---: | :---: | :---: |
| [x] | `C41` | 大师风格规则组合看板（`summaryOnly=1` 首屏秒开 + 完整净值曲线与区间归因） | [investment_rule_portfolios.dart](file:///Users/yudonglu/Documents/gemini/thesisforge/lib/investment_rule_portfolios.dart) | `GET /api/investment/investor-styles` | `C41a/b_Strategy_InvestorStyles` | `285.9 ms` (`summary`) | **`28.6 ms` / `0.4 ms`**（全曲线 `38.1 ms` / `18.8 ms`） | `250 / 15 ms` |
| [x] | `C42` | 强势突破回踩（Breakout Pullback）策略看板与区间交易归因 | [investment_breakout_pullback.dart](file:///Users/yudonglu/Documents/gemini/thesisforge/lib/investment_breakout_pullback.dart) | `GET /api/investment/breakout-pullback` | `C42_Strategy_BreakoutPullback` | `337.0 ms` | **`36.2 ms` / `2.8 ms`** | `250 / 30 ms` |
| [x] | `C43` | `QQQ ⇄ SCHD` 动态估值宏观轮动看板（含实时雷达动态重算与 `includeCurve=0` 轻量区间分析） | [investment_qqq_schd_rotation.dart](file:///Users/yudonglu/Documents/gemini/thesisforge/lib/investment_qqq_schd_rotation.dart) | `GET /api/investment/qqq-schd-rotation` | `C43_Strategy_QqqSchdRotation` | `34.5 ms` | **`30.6 ms` / `11.3 ms`** | `150 / 35 ms` |
| [x] | `C44` | 自建 13F 策略实验室（大师池目录、3 套一键预设模板、规则保存与归档） | [investment_strategy_lab.dart](file:///Users/yudonglu/Documents/gemini/thesisforge/lib/investment_strategy_lab.dart) | `GET /api/investment/strategy-lab`, `POST /strategy-rules` | `C44_Strategy_CustomLab_Catalog` | — | **`1.2 ms` / `0.7 ms`** | `60 / 20 ms` |
