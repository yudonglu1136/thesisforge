# ThesisForge：投资工作流交付与验收

日期：2026-09-08。范围：可运行的本地纵向切片，不是全量 V1 / 生产发布。

## 1. 原来的 Journey

Guru / Ontology / Valuation / Portfolio 各自入口，以模块而非投资过程组织。
从 Guru 持仓能够打开当前股票估值，但没有用户正式情景 → 决策 → 财报变化
→ 复核的持久化链路。Valuation 首屏先展示市场地图；用户还需要寻找公司。

实际运行了现有 Flutter + Express 项目，并检查 Guru、财务 PIT、模型运行记录、
股票详情、回测、账户组合与 SQLite 结构。保留现有曲线、回测和终端入口。
在本仓库没有找到可接入的独立 CTA 净值引擎；搜索结果中的网页 CTA 是行动按钮，
不是趋势策略，不能混为一谈。

## 2. 新 Journey

Home Attention → 明确规则的 Discover → Company Research → Value / Reverse
→ Watch、Pass 或 Invest → 不可变 Decision Snapshot → 研究组合
→ 切换下一公开 PIT 数据期 → Review → Then vs Now → Maintain 或 Change
→ 不可变 Review Snapshot。

一级导航：Home / Research / Discover / Portfolio / Strategies。
主路径不调用 AI / LLM，不生成投资结论，不自动改预测，不发送券商订单。
新工作流以开关启用；未开启时仍是原终端。这里不是把五个菜单改名：
用户情景、来源、笔记、规则及复核记录会写入独立账本。

## 3. 复用的已有模块

- Flutter `Palette`、中英文 `LanguageScope`、`ApiClient`、品牌资源、股票 Logo。
- 原 `ValuationTrendChart`、股票研究抽屉及 Guru 持仓入口。
- 已发布 `valuation_pit_model_runs`、原始 PIT 财务输入、指引证据、价格观察。
- 已有 `lsegValuationOverlay.js` 中的 Parent-economic FCFE 折现内核。
- `guru_exposure_snapshots` 中有申报日期的历史持仓证据。
- 原审计过的回测和券商组合保持不变；没有重写或合并成虚构收益曲线。

## 4. 代码与架构

| 文件 | 职责 |
| --- | --- |
| `server/investmentMath.js` | 版本化纯函数：FCFE、反向估值、敏感性、规则、股数比较、组合重合、独立 CTA 风险接入数学 |
| `server/investmentSource.js` | 只读 PIT 适配器；日期、来源、公式、数据哈希；有界缓存按 SQLite 数据版本失效 |
| `server/investmentStore.js` | 独立 SQLite 追加式事件账本；账号隔离、哈希、事务、幂等键、禁止 UPDATE / DELETE |
| `server/investmentService.js` | 情景、决策、复核、关注、策略版本和研究组合的业务约束 |
| `server/investmentRoutes.js` | 复用现有鉴权；私有响应不缓存；生产环境默认拒绝启用预览 |
| `lib/investment_workflow.dart` | 新投资流程 UI，试算与保存分离，原始记录及复核历史可展开 |
| `lib/main.dart` | 编译期开关、导航与原终端共存 |
| `lib/stock_research.dart` | 原 Guru 股票抽屉进入统一 Research 的按钮 |
| `server/investmentWorkflow.test.js` | 29 个新增后端测试 |
| `test/investment_workflow_test.dart` | 20 个新页面/语言/尺寸组合测试 |
| `scripts/verify-investment-workflow.mjs` | 两家真实公司独立可重复验收脚本 |

数据源是私有的 2026-09-05 已发布生产快照的本地克隆，不是重新下载或扩大覆盖。
本轮无生产数据迁移、无 GitHub push、无 AWS 发布；保留工作区此前未提交修改。
新工作流不触发财务采集。检查原 Guru 页面时，其既有按请求刷新机制更新过一次
隔离副本内的 Ackman 回测缓存；生产库未改，随后两家公司来源哈希复验不变。

## 5. 如何实际走完

本机预览：`http://127.0.0.1:5184/?view=home&asOf=2026-06-01&lang=en`。
仅本机回环监听；包含本地开发身份，**不可把这个构建直接上传公网**。

1. 先使用上面的截止日。从 Home 点击发现对象，或搜索 ISRG / MSFT。
2. Evidence 查看财报期、公开日、原始数据和历史曲线。曲线是原发布综合估值，
   不冒充下方独立 FCFE 试算结果。
3. Value 选择 Bear / Base / Bull；编辑五年增长率、FCFE margin、Ke、g。
   输入比率采用 `0.20 = 20%`，界面有说明。修改仅影响 Sandbox。
4. 查看 What must I believe，选择反求收入增长或终期 margin；可改目标回报率、
   查看 Ke × g 敏感性和逐年现金流/PV。
5. 确认母公司普通股 FCFE 归属口径，命名并保存 Scenario Version。
6. Decide 选择 Invest，输入研究股数/目标权重/笔记。设置 Revenue YoY < 30%，
   连续 1 个新报告期，保存 Decision Snapshot。这是研究仓位，不是成交。
7. 刷新或重启，Portfolio 中记录仍在。ISRG 已保留本轮浏览器验收记录，
   不要对已有仓位重复 Invest；直接点 Review。MSFT 可以用于亲自走第二遍。
8. 将截止日改为 `2026-08-28`，Home 出现规则触发（如果该期已 Maintain，
   相同期间不重复提醒）。Portfolio → Review 随时可查看。
9. Then vs Now 显示原决策与新实际数据；重算明确标出使用的最后确认情景版本。
   Maintain 只追加复核，不改情景；Change 需编辑、保存新情景，再回 Review 保存。
10. 展开 Saved review history / Evidence and immutable original，查看每次决定。

另外实际走过：原终端 Bill Ackman → MSFT 持仓 → 股票抽屉 →
Research, value & decide → MSFT 研究页。Guru 来源可以展开查看，并由用户明确
选中是否作为自己的发现来源；不会自动把所有持有该股的经理当作用户投资理由。
Portfolio 可以进入独立 CTA 摘要，但真实 CTA 数字尚未接入。

### 重启本地预览

在仓库目录分别运行，使用 Node 26 和现有 Flutter 环境：

```sh
INVESTMENT_WORKFLOW_ENABLED=true \
INVESTMENT_DB_PATH=output/investment-workflow-20260908/decisions.sqlite \
SQLITE_DB_PATH=output/investment-workflow-20260908/runtime.sqlite \
USER_PORTFOLIO_DATA_DIR=output/investment-workflow-20260908/users \
PORTFOLIO_NAV_AUTO_CAPTURE=false DIVIDEND_CALENDAR_AUTO_REFRESH=false \
GURU_BACKTEST_AUTO_REFRESH=false API_AUTH_DEV_BYPASS=true PORT=8787 \
node server/index.js
```

```sh
flutter run -d web-server --web-hostname 127.0.0.1 --web-port 5174 \
  --dart-define=API_BASE_URL=http://127.0.0.1:8787 \
  --dart-define=AUTH_DEV_BYPASS=true \
  --dart-define=INVESTMENT_WORKFLOW_ENABLED=true
```

第二条是可继续开发的 5174 预览。5184 是本轮已构建的 release 静态预览。
账本 `decisions.sqlite` 与行情/PIT 的 `runtime.sqlite` 必须分开，不得覆盖原数据。

## 6. 两家公司真实验证

截止日从 2026-06-01 到 2026-08-28。以下仅用于模型一致性与历史流程验收，
不是新的股票推荐或完整估值意见。

| 验收项 | ISRG | MSFT |
| --- | ---: | ---: |
| 原财报期 → 新财报期 | 2026-Q1 → 2026-Q2 | 2026-Q3 → 2026-Q4 |
| 原独立 FCFE DCF，$/股 | 165.210762 | 178.024862 |
| 与已发布独立 DCF 的差异 | < 1e-8 | < 1e-8 |
| 新实际数据、原假设不变 | 172.703664 | 185.685175 |
| Ke 提高 1pp 的新情景 | 151.664508 | 160.645995 |
| 原日价格反求统一收入增长 | 31.119748% | 30.178864% |
| 反求价格回代误差 | 2.27e-13 | 1.14e-13 |
| 新期间规则触发 | 通过 | 通过 |
| 关库重开 / Maintain / Change / 原哈希不变 | 全部通过 | 全部通过 |

浏览器完整操作了 ISRG 保存、投资、跨期、Maintain、Change、服务重启后还原；
实际打开 MSFT 研究和 Guru 跳转。两家完整的持久化闭环另由真实数据验收脚本执行，
不是声称两个完整 UI 流程都逐一手工点击过。

私有验收输出：
`output/investment-workflow-20260908/acceptance-final/acceptance.json`。
它包含来源哈希和计算签名，不应把私有数据库或付费原始数据提交公开仓库。

## 7. 测试与计算过程

- 新后端：29 / 29 通过；现有全部 `server/*.test.js` 回归通过。
- Flutter：151 / 151 通过，其中新增 20 个组合覆盖英文/中文、桌面/390px 手机、
  五个一级页面及 Research → Value。修复了窄屏标题溢出和卡片点击反馈被遮挡。
- `flutter analyze --no-pub` 通过；私有 Flutter release Web 构建通过。
- 本轮还执行了既有 performance 测试 41 项、i18n、Ontology 模块/测试门禁，均通过。
  这些是回归，不是生产延迟基准；没有声称性能提升百分比。

独立手算：Revenue0=1000m，shares=100m，五年增长10%，FCFE margin20%，
Ke10%，g2.5%。FCFE 为 220、242、266.2、292.82、322.102m。
显性 PV = 1000m；终值 PV = 322.102×1.025/0.075/1.1^5。
每股价值 = (显性 PV + 终值 PV)/100。测试没有引用同一个内核来伪装独立校验。

反向估值：增长求解固定五年 margin 与 g；margin 求解固定增长和前四年 margin，
只调整第五年及永续 margin。使用 90 次二分、明确边界、返回回代误差；越界返回无解。
目标回报率作为 Ke 输入，不是额外承诺的收益率。

其他覆盖：无未来 PIT/指引/汇率日期、13F 可用日、重复持仓、Top3 排序、
股数与价格驱动权重区别、拆股不可比、Missing/非法分母、场景版本、追加快照、
账号隔离、重复请求、并发旧 head、历史组合截止日、缺价/异币种、成本批次未对账、
连续新财报期规则、Maintain 不改假设、Change 必须新版本。
CTA 只有精确日期对齐的独立数学测试，不是实盘/回测引擎接入验收。
额外验证：比较股价缺失会关闭反向求解，但不阻止与股价无关的正向 DCF 计算。

## 8. PIT / as-of 与可审计性

- 每个请求有显式截止日，拒绝未来日期；只读模型节点公开日 ≤ 截止日。
- 检查财务可用日、指引 max observed、嵌套来源的 filed/datekey/observedAt/rateDate。
- 保留 fiscal period、period end、financial available、模型节点日期、价格日期、
  decisionDate、实际 recordedAt；executionDate 为 null，不冒充历史成交。
- 保存数据快照、原始来源、公式、预测路径、现金流/PV、版本与 SHA-256。
- 决策/情景/复核不 UPDATE 或 DELETE。新实际数据只用于新计算，原预测不被覆盖。
- 新情景/复核必须由用户写入；旧数据日期看不到未来版本或未来组合调整。
- Guru 按实际 filing availability，不把季末当披露日。未验证公司行动的原始股数变化
  只能作为待复核披露事实，不能断言真正增减持或推测动机。
- 不完整价格不会作为零；异币种不直接相加或计算假权重；缺失 CTA 不显示零风险。
- 比率计算保留 IEEE-754 完整精度；UI 金额两位、百分比两位；不在中间步骤四舍五入。
  固定输入、截止日、规则/计算版本的结果及计算签名一致，事件 UUID/写入时间当然不同。

限制：这是已发布数据的**回溯 PIT 重放**，不是证明系统当年实时发出了提醒。
没有独立重审供应商历史修订、每个股票的公司行动或全量管理层指引经济语义。
原发布模型的 lineage pass 也不等于 economic-model validated。
当前 Base 是原独立 DCF 现金流路径的可编辑参数化；不能把它称为新的全模型审计结论。

## 9. 未完成项 / V1 未通过部分

1. **CTA 实际接入与完整组合风险**：未找到真实净值引擎，组合配置、相关性、收益贡献、
   回撤、Sharpe 等线上数字未接通。页面明确 unavailable，不生成占位曲线。
2. **完整 Guru Shadow 执行与绩效对照**：目前是有版本的披露 Top3 预览，证券身份或
   所选集合不完整会关闭权重。没有执行日价格/交易成本现金账本及用户组合相对收益。
   原终端回测保留，不把新预览伪装成原已审计策略；两者规则身份明确分离。
3. **覆盖不同公司模型的情景编辑**：当前只开放有独立 FCFE 且币种一致的经营公司；
   SOTP、保险/银行、复杂 NCI、EPS 组合等仍沿用原只读估值，未通用化成预测编辑器。
4. **研究比较和发现来源**：有自身历史分位；无审核过的同行/行业队列、ROIC、
   RPO/ARR 等经营 KPI。Ontology 仍保留在原终端，尚未统一接入发现来源。
   Follow 偏好可以保存，但关注经理的个性化发现流尚未完成。
5. **研究组合不是券商账本**：没有完整公司行动、成交批次、PnL、板块风险或预期
   CAGR。Add/Reduce 后成本标记不可用，不伪造成本。真实账号身份/备份迁移待生产验收。
6. **规则覆盖和运行方式**：已有四个财务指标、连续期和原始 Guru 新披露复核；
   未开放价格回报率、仓位集中度、自定义 KPI、原 Guru 精确股数阈值规则。
   目前打开 Home / 切换日期时计算，不是后台提醒调度器。
7. **历史明细**：选定情景和每次 Review 完整保存；一次决策未同时将用户全部
   Bear/Base/Bull 正式版本集合打包。多次已退出再进入的决策全集页面仍需完善。

因此：完整纵向切片已实现，**不能把这次交付标为用户列出的全量 V1 全部完成**。
新路径零运行时 AI；原终端遗留独立功能没有在本轮被全面删除或重新认证。

## 10. 下一阶段优先级

1. **统一真实组合与 CTA 账本**：先确定 CTA 数据位置/合同、成交/公司行动规则，
   对齐可审计 NAV，再提供 Fundamental / Shadow / CTA 的独立与合并风险。
2. **完整 Guru → Decision → Monitoring**：接完整证券映射和公司行动、Follow 发现流、
   原来源披露阈值；复用原回测执行内核形成真实 Shadow 版本与绩效差异。
3. **扩展研究与模型，并做生产发布门禁**：审核同行 cohort、公司 KPI、不同估值口径；
   覆盖情景集合、后台规则调度、真实账号权限/备份/升级回滚后，再审查生产启用。

## 11. 用户选定方案 1：Graphite 视觉落地

- 在原 Flutter 工作流上实现石墨底色、232px 左导航、中央真实历史曲线、右侧个人情景，未另建静态假终端。
- 首页、发现、组合、策略、决策及复核沿用统一导航与视觉令牌；原终端可打开。
- 默认保持英文，可切换中文；桌面分栏，手机上下排列。
- 三个紧凑参数使用百分数，未编辑参数仍传原始完整精度；五年预测、反向估值、敏感性、来源与版本记录可展开。
- 保存通过明确的归属确认，不自动下单。日期切换使旧研究失效；输入变化立即作废过期异步计算，避免旧响应覆盖新假设。
- 最终前端静态检查通过，Flutter 176 项通过（含 45 项工作流测试），后端工作流 29 项通过，本地 release 构建通过。
- 浏览器实测 MSFT 2026-06-01 Base：综合估值 $313.54、个人 FCFE $178.02；只改 Ke 到 10% 后个人值 $154.02，历史图仍为 66 个估值节点和 900 个价格点。
- 测试使用隔离本地数据库，未部署 Vercel/AWS、未推送 GitHub、未修改金融源数据或旧决策记录。
- 视觉对照及证据路径见项目根目录 `design-qa.md`。第 9 节的功能限制未因本次视觉重做而解除。
