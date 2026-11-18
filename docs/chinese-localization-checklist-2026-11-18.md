# ThesisForge 全平台中文化与机构级中文体验彻底优化清单

> [!IMPORTANT]
> **审计范围**：覆盖全平台 **54 个 Flutter 前端文件（`lib/*.dart`）**、**Web 启动壳层与字体配置（`web/index.html`、`pubspec.yaml`）**、**全部后端业务模块与策略配置（`server/*.js`、`server/config/*.json`）** 以及 **全量自动化 i18n 门禁（`scripts/audit-i18n.mjs`）**。  
> **优化准则**：零英文残留漏译、零 `snake_case` / 原始代码直出、统一机构级中文金融术语（剔除口语化/散户化黑话与生硬机翻）、修复 CJK 异体字形（Han Unification）与小字号模糊问题、中英双语测试与线上双端同步验证。

---

## C1 · 全局底座：语言持久化、Material 中文本地化、CJK 字体回退与字距排版
- [x] **C1.1 语言偏好本地持久化（`lib/main.dart`、`lib/browser_location*.dart`）**：切换中文/英文时持久化至浏览器存储；无 `?lang=` 参数重开网页或 OAuth 登录回调后自动保持上次选择的中文模式（有显式 `?lang=` 参数时优先遵循 URL）。
- [x] **C1.2 Web 启动壳层中文化与 `lang="zh-CN"` 字形修正（`web/index.html`）**：根据 URL `?lang=zh` 或本地存储动态设置 `<html lang="zh-CN">`（修复浏览器将汉字渲染为日文汉字字形的顽疾）、中文页面标题 `ThesisForge · 投研工作台`、加载提示 `正在载入投研工作台…` 及 `PingFang SC / Microsoft YaHei / Noto Sans CJK SC` 字体栈。
- [x] **C1.3 接入 `flutter_localizations` 与 `MaterialApp.locale`（`pubspec.yaml`、`lib/main.dart`）**：配置 `Locale('zh', 'CN')` 与 `GlobalMaterialLocalizations.delegates`，彻底消除 PIT 日期回放选择器、复核日期日历弹窗、右键菜单与内置组件在中文模式下的英文月份/星期/按钮（`Select date / Cancel / OK`）。
- [x] **C1.4 全局 CJK 字体回退栈与标题负字距修复（`lib/main.dart`、`lib/investment_desk.dart`、`lib/investment_workflow.dart`、`lib/investment_graphite.dart`）**：为 `ThemeData` 及 Canvas `TextPainter` 补齐简体中文字体回退链；中文模式下将标题负字距（`letterSpacing: -0.5` 至 `-1.0`）与英文大写正字距（`letterSpacing: 0.6`）归零，行高提升至 `>= 1.28`，消除汉字笔画粘连与上下裁切。
- [x] **C1.5 全局语言切换按钮原生标识（`lib/main.dart`）**：英文界面下的语言切换按钮统一显示自解释的 `中文`（替代生硬的 `ZH` 或 `Chinese`）。

---

## C2 · 全平台机构级中文术语统一与 `_uiChinese` 词典补全
- [x] **C2.1 统一核心投研术语口径（全模块）**：
  - 跟踪大师/机构：统一为 **投资大师 / 大师持仓**（消除 `大佬`、`大咖`、未翻译 `Guru` 混用）；8,000+ 全市场机构统一为 **申报机构 / 主动管理机构**。
  - 盈利与现金流利润率：统一 **营业利润率**（合并 `经营利润率`）、**自由现金流利润率 / FCF 利润率**（合并 `现金流率`）、**FCFE 利润率 / 末期 FCFE 利润率**（修复费解的 `反推末期率`）。
  - 估值与回测指标：统一 **估值空间 / 较现价折溢价**（替代 `模型差距`）、**年化收益率 / 年化**（`CAGR`）、**夏普比率 / 夏普**（`Sharpe`）、**最大回撤**（`MDD`）、**卡玛比率**（`Calmar`）、**溃疡指数**（`Ulcer`）、**个百分点**（`pp`）、**基点**（`bps`）、**今年至今**（统一 `年初至今` / `今年迄今`）。
- [x] **C2.2 补齐 40 个平台估值行业原型（Archetype Sectors）与标准 GICS 行业中文映射（`lib/main.dart`）**：将 `AI semiconductor growth`、`Mega-cap platform`、`Enterprise software growth`、`Large-cap biopharma` 等全部 40 个估值行业分类及 GICS 别名全部纳入 `_uiChinese`。
- [x] **C2.3 修复 `_uiChinese` 大小写缺失与动态模式匹配（`lib/main.dart`）**：补齐 `'weight'`/`'return'`/`'contrib'`、`'STOCK'`、`'1Y'`/`'3Y'`/`'5Y'`/`'10Y'`、`'MDD≈'`、`'Tracked stocks'`/`'Cumulative sold'`/`'Sold shares'`、`'New / Exit'`/`'Filing lag'`/`'Total'`/`'Sharpe'`、`'monitored gurus'`/`'Signal spread'` 等词条，并支持 `IBKR account N` -> `盈透账户 N`、`Account N` -> `账户 N`、`X buy / Y sell` -> `X 笔买入 / Y 笔卖出` 等动态模式本地化。
- [x] **C2.4 修复投研工作流决策动作语义反转（`lib/investment_workflow.dart`、`lib/main.dart`）**：修复投资决策 `'Pass'` 未翻译或误映射为审计 `'通过'` 的严重语义错误，专门映射为 `观察（Watch）`、`放弃（Pass）`、`建仓（Invest）`、`维持（Maintain）`、`调整（Change）`、`加仓（Add）`、`减仓（Reduce）`、`清仓（Exit）`。

---

## C3 · 全局壳层、首页、搜索、工作流与面包屑导航
- [x] **C3.1 面包屑来源与 `13f_insights` 路由修复（`lib/investment_workspace_pages.dart`）**：修复 `'Discover / $name'` 硬编码英文，补齐 `'13f_insight'` / `'13f_insights'` 来源映射为 `'发现 / 13F 洞察'`（不再误显示为 `'直接研究公司'`），大师来源显示中文名。
- [x] **C3.2 大师影子组合（Shadow）表格与规则摘要中文化（`lib/investment_workspace_pages.dart`、`lib/investment_workflow.dart`）**：修复表头 `'Shadow'` -> `'影子权重'`、`'Top $n'` -> `'前 $n 大'`，并将规则摘要中的原始 `guruId`（如 `gavin-baker, bill-ackman`）映射为大师中文名。
- [x] **C3.3 首页、全局搜索与工作台提示中文化（`lib/investment_home.dart`、`lib/investment_company_search.dart`、`lib/investment_desk.dart`、`lib/investment_graphite.dart`）**：
  - `'去 Discover 寻找下一个机会'` -> `'前往「发现」寻找下一个投资机会'`；
  - 搜索无结果 `'没有匹配的 Fact OS 公司。'` -> `'未找到匹配的公司或股票代码。'`（屏蔽内部架构代号 `Fact OS`）；
  - 修复倒装语序 `'$asOf 截止暂无...'` -> `'截至 $asOf 暂无...'`；
  - 将“方法与覆盖边界”弹窗中的原始 JSON 替换为可读中文键值列表。
- [x] **C3.4 工作流估值表头、公式来源与 JSON 字段人性化展示（`lib/investment_workflow.dart`）**：修复 `'FCFE M'` / `'PV M'` 英文表头、`'Invest'` 残留英文、`'stored ticker prices'` / `'stored PIT model'` 英文来源及 `Bear/Base/Bull` 在英文模式下被反向写死中文的问题。
- [x] **C3.5 旧版核心模块与 Canvas 悬浮框中文化（`lib/main.dart`）**：修复 `EquityPainter`（`Portfolio` / `Excess` -> `组合` / `超额收益`）、`PriceActionPainter`（`Close` / `Action` -> `收盘价` / `操作`）、`Latest Filings` 误译 `'最近财报'` -> `'最新 13F 申报'`、管理后台健康卡片与估值详情抽屉（`quarters` / `Period end` / `financial rows` / `transcript metrics` / `guide signals` / Podcast 标签）的全部英文残留。

---

## C4 · 发现页、大师持仓矩阵、大师档案（Dossier）、散点图与 13F 洞察
- [x] **C4.1 全链路打通 38 位投资大师 `chineseName`、`roleZh` 与中文研究备注（`server/gurus.js`、`server/investmentSource.js`、`server/investmentGuruProfile.js`、`server/investmentOpportunities.js`、`server/strategyDatabase.js`、`server/investmentPortfolio.js`、`server/portfolioGuruActivity.js`）**：后端全链路保留 `chineseName` 并补齐 38 位大师的中文头衔 `roleZh` 与模拟说明 `simulationNoteZh` / 动态备注中文，让全平台所有大师卡片、筛选器、持仓矩阵、档案页、策略回测与实盘对比在中文模式下优先展示标准中文名（如 `沃伦·巴菲特`、`李录`、`斯坦利·德鲁肯米勒`、`文艺复兴科技`）。
- [x] **C4.2 发现页导航与透镜卡片优化（`lib/investment_discovery.dart`、`lib/investment_discover_lenses.dart`、`lib/investment_explorer.dart`、`lib/investment_opportunities.dart`）**：将 `'Guru'` 子标签本地化为 `'大师持仓'`（兼容既有测试断言），加宽紧凑列宽防止中文换行截断，本地化机会页估值公式说明与单位 `'个百分点'`。
- [x] **C4.3 大师深度档案页（`GuruResearchDossier`）彻底汉化（`lib/investment_guru_dossier.dart`）**：修复大师头衔 `role`、策略标签 `thesisTag`、**“已识别行业权重分布”及每行持仓行业名称**（补齐 `context.ui(sector)` 调用！），修复非美元持仓硬编码 `\$` 符号问题。
- [x] **C4.4 大师散点图与大师研究面板（`lib/investment_guru_scatter.dart`、`lib/investment_guru_study.dart`、`lib/investment_guru_holdings.dart`）**：汉化散点图纵轴 `'CAGR (%)'` -> `'年化收益率 (%)'`、悬浮框 `'Sharpe'` -> `'夏普比率'`、周期芯片 `'1Y'` / `'3Y'` -> `'近 1 年'` / `'近 3 年'` 及卡片指标标签。
- [x] **C4.5 13F 机构洞察与行业钻取弹窗（`lib/investment_13f_insights.dart`、`lib/investment_13f_sector.dart`）**：统一 `'pp'` -> `'个百分点'`、`'bp'` -> `'基点'`，中文模式下股数格式化为 `'亿股 / 万股'`（替代 `12.4M`），隐藏内部版本号 `'active-sector-v1'`。

---

## C5 · AI 洞察（AI Insights）全界面与中文长图 PNG / Excel CSV 导出
- [x] **C5.1 标题、云厂商分组与按钮统一汉化（`lib/investment_ai_insights.dart`、`server/investmentAiInsights.js`）**：页面主标题统一为 `'AI 洞察'`；`'Neocloud'` 汉化为 `'新兴算力云'`（首次说明 `'新兴算力云（Neocloud）'`），补齐 `'hyperscaler'` -> `'超大规模云厂'`；按钮 `'打开 Research'` -> `'打开公司研究'`；修复未知币种 `'unknown 百万'` -> `'百万（原币种）'`；修复空图表 Canvas 硬编码 `'No comparable observations'` -> `'暂无可比观测数据'`。
- [x] **C5.2 统一 AI 洞察表头与提示中的同比/环比/百分点表述（`lib/investment_ai_insights.dart`）**：中文模式下统一 `'切到同比 (YoY) →'`、`'收入同比'`、`'同比增速变化'`、`'个百分点'`。
- [x] **C5.3 新增原生「中文长图 · PNG」导出与 Excel 兼容 CSV 导出（`lib/investment_ai_insights.dart`、`lib/investment_ai_insights_export.dart`）**：
  - 将 `_AiInsightsExportReport` 全量中英双语化并配置 CJK 字体回退，在导出菜单提供 **`中文长图 · PNG`**（保留 `'英文长图 · PNG'` 供英文报告分享及兼容既有测试）；
  - CSV 导出在中文模式下提供中文表头并写入 UTF-8 BOM（`\uFEFF`），彻底解决 Excel 打开中文 CSV 乱码问题。

---

## C6 · 个股研究总览、财务三表、估值拆解、研究笔记与反向 DCF
- [x] **C6.1 个股研究头部、行业原型标签与中国机构数字单位（`lib/investment_research.dart`）**：头部行业标签接入 `context.ui(sectorText)`（翻译全部 40 类行业原型）；修复移动端 `'FV'` -> `'估值'`、`'⌘K / Search'` -> `'⌘K / 搜索'`、`'Fact OS · 暂无平台模型'` -> `'财报事实库 · 暂无平台估值'`；财务柱状图悬浮框 `'YoY'`/`'QoQ'` -> `'同比'`/`'环比'`，中文模式下大额市值/营收展示为 `'万亿 / 亿 / 百万'`（图表坐标轴字号提升至 `>= 10.5px`）。
- [x] **C6.2 关键基本面变化证据字段（`evidence`）汉化（`lib/investment_research.dart`）**：修复 `revenueGrowth · operatingMargin · dilutedSharesGrowth` 等原始 `camelCase` 字段名直接拼接在中文结论后的问题，映射为标准中文财务指标名。
- [x] **C6.3 平台估值模型拆解卡片全量汉化（`lib/investment_research.dart`、`lib/investment_fundamentals.dart`）**：建立统一的估值方法名（`EV/销售额股权价值`、`标准化盈利能力估值`、`五年期 FCFE DCF`、`周期标准化 FCFE DCF`、`ROE 隐含市净率估值`、`EPS 交叉核验`、`报告期股东权益`）、计算步骤（`steps`）、输入参数（`parameters`）、排除原因（`exclusionReason`）及加权公式（`formula`）中文转换器。
- [x] **C6.4 公告披露列表与诊断比率（Diagnostic Ratios）数值格式化修复（`lib/investment_research.dart`、`server/researchWorkbench.js`、`server/fundamentalResearch.js`）**：
  - 公告类型 `'ARQ'` / `'ART'` / `'financial_update'` 与英文标题 `'AAPL 2026-Q2 financial disclosure'` 汉化为 `'季报披露'` / `'2026-Q2 财务披露记录'`；
  - 修复诊断比率用 `formatNumber` 把 `18.4%` 四舍五入显示为 `'0'` 的数值 Bug，并将全部 20+ 条指标计算公式双语化。
- [x] **C6.5 反向 DCF（Reverse DCF）状态码与固定假设说明汉化（`lib/investment_research.dart`）**：映射 `'outside_bounds'` -> `'超出求解区间'`、`'multiple_solutions'` -> `'存在多解'`、`'unavailable'` -> `'暂不可计算'`，并将英文 `reverse['fixed']` 完整汉化。
- [x] **C6.6 研究笔记（Records）快捷标签、日历与复制 Markdown 汉化（`lib/investment_research.dart`）**：快捷标签汉化为 `'财报业绩 / 估值定价 / 护城河 / 风险点 / 催化剂'`，复制 Markdown 的字段标题（状态、基准日、复核日、支持证据、反证与缺口、证伪条件）随语言切换中文化。
- [x] **C6.7 个人估值工作台、当期情景卡与稳态价值趋势（`lib/investment_valuation.dart`、`lib/current_valuation_scenario.dart`、`lib/investment_value_trend.dart`、`lib/stock_research.dart`）**：
  - 修复 `CurrentValuationScenarioCard` 中 `'bear'` / `'bull'` 未识别导致同显示为 `'情景'` 的 Bug，仅在存在墨西哥比索字段时展示 `MXN` 行；
  - 修复个人估值 `'反推末期率'` -> `'反推末期 FCFE 利润率'`、`'5Y'/'10Y'` -> `'5 年期'/'10 年期'`、`'12,450m'` / `'USD m'` -> `'百万'`、点击 `'悲观/基准/乐观'` 时自动填入中文情景名；
  - 加宽 `SteadyValueChart` 环比百分比列宽防止超 `100%` 折行。

---

## C7 · 基本面选股器、成长质量、财报阅读器、机构持仓与内部人交易（Form 4）
- [x] **C7.1 基本面选股器（`Fundamentals`）状态码、连续增减持与逻辑修复（`lib/investment_fundamentals.dart`、`server/fundamentalResearch.js`）**：
  - `'家事实公司'` -> `'家覆盖公司'`，错误提示 `'前往 Research'` -> `'前往「个股研究」'`；
  - 修复机构广度与净股数方向背离时（`positive_breadth_net_decrease`）误判为一致增持的逻辑 Bug；
  - 修复 `'exit after hold'` / `'increased 2 quarters'` 原始英文直出，映射为 `'持有后清仓'` / `'连续增持 2 个季度'`；
  - 修复“研究地图”右侧原始状态码（`available` / `missing` / `not_observed` / `not_modeled` / `price_unavailable` / `currency_unverified` / `insufficient_peer_count`）及趋势图悬浮框 `'Rev'` / `'OpM'` 英文直出；
  - 将全部 `8px–9px` 极小中文字号提升至 `>= 11px`，动态计算趋势图图例间距防止重叠。
- [x] **C7.2 成长质量、财报电话会与披露持仓面板（`lib/investment_growth_quality.dart`、`lib/investment_earnings.dart`、`lib/investment_earnings_book.dart`、`lib/investment_holders.dart`）**：
  - `'FY 2025'` -> `'2025 财年'`，修复 `'unavailable'` 数据源文案；
  - 财报电话会管理层指引摘录支持高管头衔汉化与 `'以下为英文原话摘录'` 标注；统一财报阅读器中的 `'自由现金流利润率'` 与 `'变动 (百分点)'`；
  - 持仓面板修复 `'${n} 位披露'` 缺宾语问题（改为 `'${n} 家披露机构'`），股数支持 `'亿股 / 万股'`。
- [x] **C7.3 内部人交易（SEC Form 4 / Sharadar SF2）全量代码表汉化（`lib/research_insiders.dart`）**：
  - 补齐全部 14 类 SEC Form 4 交易代码（新增 `D` 交回处置、`J` 特定变更、`X` 实值期权行权、`I` 计划内自主交易、`W` 继承过户、`U` 要约交股、`L` 小额增持）；
  - 分号拆分并汉化高管职务缩写（`CEO;Pres` -> `首席执行官 (CEO)、总裁`，覆盖 `CFO/COO/CTO/CLO/CAO/CHRO/EVP/SVP/VP/Chair/Sec/Treas` 等 20+ 职务）；
  - 汉化证券类别（`Com` -> `普通股`、`ClA` -> `A类股`、`RSU` -> `限制性股票单位`、`Opt` -> `股票期权`、`Phant` -> `虚拟股` 等）与取得/处置代码（`NA/ND/DA/DD`）、直接/间接持有（`D/I` -> `直接持有 / 间接持有`）、表格类型（`4` / `RESTATED - 4` -> `Form 4 / Form 4/A 更正申报`）及时间窗口芯片（`近 3 个月 / 近 6 个月 / 近 1 年`）。

---

## C8 · 实盘投资组合、被动现金流（股息+卖 Call）与券商连接弹窗
- [x] **C8.1 被动现金流（Passive Income）英文漏洞与期权徽标修复（`lib/investment_portfolio_passive_income.dart`）**：
  - 修复月度卡片 `w('Call', 'Call')` 导致中文模式显示 **`Call USD ...`** 的明显漏译，统一为 **`卖 Call`**；
  - 区分 `'现金股息'` 与 `'代付股息 (PIL)'`；将 `'卖 Call 到期作废'` 优化为准确的期权术语 `'卖 Call 虚值到期归零'`；
  - 待到期看涨/看跌期权芯片汉化为 `'NVDA $200 看涨(Call) · 2026-12-11 · 5张'`，并将 `9.5px–10.5px` 标签字号提升至 `>= 11.5px`。
- [x] **C8.2 实盘组合行业分布、期权持仓徽标与风险归因汉化（`lib/investment_portfolio.dart`、`lib/investment_portfolio_visuals.dart`、`lib/investment_portfolio_home.dart`、`lib/investment_portfolio_gurus.dart`）**：
  - 修复“行业敞口”列表与饼图（`PortfolioAllocationChart`）未调用 `context.ui()` 导致 `Technology`、`Healthcare` 等全英文直出的问题；
  - 修复桌面端与移动端持仓表期权徽标硬编码 `'Short NVDA · ... Call'`，汉化为 `'卖出 NVDA · ... 看涨(Call)'`；
  - 修复净值曲线区间芯片 `'1M' / '3M' / '1Y'` -> `'近1月 / 近3月 / 近1年'`；
  - `'负现金 / 净资产'` 优化为 `'融资负债 / 净资产'`，对比表头 `'你'` -> `'我的权重'`，明确映射 4 类估值排除原因码。
- [x] **C8.3 券商连接管理弹窗与错误提示全汉化（`lib/investment_portfolio_tools.dart`、`lib/main.dart`）**：汉化券商名称（`盈透证券 (IBKR)`、`富途 / moomoo`）、输入框标签（`IBKR Flex 网络服务令牌`、`活动 Flex 查询 ID`）、账户类型（`保证金账户 / 现金账户`）、后台同步状态与常见错误消息，并补齐管理端只读 `PortfolioDashboard` 的中文化。

---

## C9 · 量化策略组合、突破回踩、规则组合、QQQ/SCHD 轮动与期权对冲实验室
- [x] **C9.1 顶部 4 大量化策略卡片与公共导航去英文化（`lib/investment_breakout_pullback.dart`、`lib/investment_rule_portfolios.dart`）**：
  - 去除 `'Strategy Portfolio · 策略组合'`、`'DAILY TACTICAL · ...'`、`'QUARTERLY FUNDAMENTAL · ...'` 的冗余英文前缀；
  - 4 张核心策略卡上的指标胶囊全量汉化（`'10年 8.91x'`、`'年化 24.4%'`、`'夏普 1.03'`、`'最大回撤 -29.9%'`、`'10 基点'`）。
- [x] **C9.2 热门突破回踩策略（Breakout Pullback）细节与弹窗代码泄漏修复（`lib/investment_breakout_pullback.dart`、`server/config/hot-breakout-pullback-dashboard.json`）**：
  - 修复个股批次明细弹窗（`_showStockLotsDialog`）直出原始 `Trailing_TakeProfit`、`Hard_StopLoss`、`Time_Backstop_180d` 代码的严重漏洞；
  - 修复 `'STEP 01'` -> `'第 01 步'`、区间 `'1Y..10Y'` -> `'1年..10年'`、持仓天数 `'15d'` -> `'15天'`、`'0% Rf'` -> `'0% 无风险利率'`，并将实证对比胶囊（`findings[*].metric`）双语化。
- [x] **C9.3 QQQ / SCHD 宏观估值恐慌轮动策略专业化与全表汉化（`lib/investment_qqq_schd_rotation.dart`、`server/config/qqq-schd-rotation-dashboard.json`）**：
  - 修复净值图悬浮栏直出内部键名 **`STATIC7030`** 的 Bug（改为 `'70/30 静态'`）；
  - 汉化年度收益表、12 策略横评表、5×5 稳健性网格、税后敏感度表、牛熊归因表的全部英文表头（`70/30 Static`、`15% CGT CAGR`、`Sharpe / MDD`、`Ulcer`、`Peak PE`、`M6 Flagship`、`%/yr`）；
  - 将 JSON 配置中的 12 个 `metricBadge` 与实时雷达触发条件 `conditions` 双语化；
  - 将散户化口语文案（`死拿`、`打脸32次`、`白菜价`、`一把满仓杀回`、`接飞刀`）全面升级为严谨机构投研表述（`买入持有`、`32 次假信号止损磨损`、`深度折价区间`、`全仓切回 QQQ`、`过早左侧抄底`），并将 `9.5px–10.8px` 徽标字号提升至 `>= 11.5px`。
- [x] **C9.4 策略构建器（Strategy Lab）、规则组合与期权保护实验室（Hedge Lab）（`lib/investment_strategy_lab.dart`、`lib/investment_rule_analysis.dart`、`lib/investment_rule_portfolios.dart`、`lib/investment_strategy_hedge.dart`、`lib/investment_hedge.dart`、`lib/investment_strategy_mix.dart`、`lib/investment_strategy_chart.dart`、`lib/investment_strategy_snapshot.dart`）**：
  - 修复 `'Collar'` 未翻译、`'看跌借记价差'` -> `'熊市看跌价差'`，以及 `investment_strategy_hedge.dart` 直接拼接原始 `hedge_notional_below_one_contract` 等 `snake_case` 错误码的漏洞；
  - 将 OCC 原始期权合约代码（`O:QQQ260515P00608000`）格式化为易读中文合约标签；
  - 修复 `Strategy Lab` 股票组合模式下误显示 `'次披露调仓'`（应为 `'次季度调仓'`）、`'bps'` -> `'基点'`、`'Top N'` -> `'前 N 名'`，以及规则组合中 `y0_date` 显示 `'年度观测 0 披露日'` 的 `0` 索引起始问题。

---

## C10 · 全平台自动化 i18n 门禁升级、全量测试与双端生产上线
- [x] **C10.1 升级全平台 i18n 自动化审计脚本（`scripts/audit-i18n.mjs`）**：从原先仅扫描 2 个文件扩展为扫描全部 **55 个 `lib/*.dart` 文件**，自动拦截未本地化的 `tooltip / hintText / labelText / semanticLabel`、未收录进 `_uiChinese` 的静态 `context.ui('...')` 词条及常见硬编码英文 UI 文本。
- [x] **C10.2 全量验证与回归测试**：运行 `npm run audit:i18n`、`flutter analyze lib test`、全套 Flutter 单元与组件测试（含中文模式专项测试）及全部 Node 后端测试（含 `test:performance`、`test:ai-insights`、`test:strategy:db`、`test:hedge`、`test:research`），确保 100% 零报错通过。
- [x] **C10.3 Git 提交推送与 AWS EB + Vercel 生产环境同步上线**：提交至 `origin/trunk`，同步部署 AWS Elastic Beanstalk（`thesisforge-api-prod` -> `Ready / Green`）与 Vercel 前端生产环境，并核验 `https://thesisforge.tech` 与 `https://www.thesisforge.tech` 双域名指向同一最新 Ready 部署。
