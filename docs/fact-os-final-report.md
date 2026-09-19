# ThesisForge Local Fact OS — 本地迁移验收报告

项目最初在 `/Users/yudonglu/Documents/fundamental-analysis` 完成迁移；现已合并到唯一产品根
`/Users/yudonglu/Documents/thesisforge`。审计日：2026-09-19。
范围仅本机；未修改 production、AWS、Vercel、用户账户或私人组合。

**结论：本地 Fact OS 迁移与数据层验收通过。14 表全量历史、两轮真实 API 同步、
两轮固定输入离线重放、全表审计、去重和旧库保全均已完成。
这不是浏览器整页联调或 production 上线验收；数据源的 PIT 限制仍然存在。**

以下是 15 项交付结论。完整排错、中断轮次及逐表证据保存在
[迁移记录](fact-os-migration.md)和 `data/fact_os/audit/`，不将中断运行计为通过。

## 1. 原架构

行情、Guru 持仓和衍生缓存分散在应用 SQLite、JSON 与压缩响应档案中；旧行情使用 Yahoo 的
通用 `close`，不足以证明复权口径。141 家公司已有估值模型档案，但财报历史不完整。
旧自定义 13F 抓取、行情抓取与业务查询紧耦合。

原应用库有 20 张表、709,148,672 bytes，已做 SQLite backup API 一致性备份，
保留原库、缓存、模型和研究资料；独立用户组合库未复制或迁移。详细初始清单见迁移记录。

## 2. 新架构

```text
Sharadar 授权历史/API
  → 原始归档、官方 schema、checksum 与来源
  → 自然键校验、类型化、不可变 Parquet
  → DuckDB 写入目录 + 原子发布的读取 manifest
  → 离线 FactRepository + 受限只读 Node RPC
  → 现有应用消费者
```

普通查询不读 API key、不触发同步、不自动回退旧源。读者绑定单一不可变目录版本；
RPC 不接受任意 SQL，也不向子进程传递上游或私人账户凭据。
七个基础 MetricRegistry 指标和版本化 FeatureRegistry / FeatureEngine 已实现，
以 FCFMargin v1 验证确定性计算、事实来源及 PIT 截止；未新增排名、DCF 或组合算法。

## 3. 已入库的 Sharadar 表

必需九表：tickers、stocks、funds、fundamentals、daily、actions、
holdings、holdings_ticker、holdings_investor。
扩展五表：events、insiders、descriptions、metrics、sp500。

全部来自已验证的授权完整历史归档；`backfill_complete` 不由样例、短窗口或普通查询冒充。
财报保留 ARQ、ART、ARY、MRQ、MRT、MRY 六个维度，原始字段及来源不丢失。

## 4. 行数和日期覆盖

当前列来自两轮 API 同步、固定输入重放后的稳定目录全表扫描。
初始全量 201,157,932 条；最终合计 201,159,454 条来源事实/观察。

| 表 | 初始全量 | 最终行数 | 当前来源日期范围 |
|---|---:|---:|---|
| tickers | 74,232 | 74,235 | lastupdated 2008-01-02—2026-09-19 |
| stocks | 45,354,729 | 45,354,943 | 1997-12-31—2026-09-18 |
| funds | 15,637,679 | 15,637,697 | 1997-12-31—2026-09-18 |
| fundamentals | 3,217,358 | 3,217,364 | date 1990-06-06—2026-09-18 |
| daily | 39,818,727 | 39,818,815 | 1998-12-01—2026-09-18 |
| actions | 699,833 | 700,099 | 1997-12-31—2026-09-22 |
| holdings | 81,202,367 | 81,202,367 | 2013-06-30—2026-06-30 |
| holdings_ticker | 670,111 | 670,111 | 2013-06-30—2026-06-30 |
| holdings_investor | 306,476 | 306,476 | 2013-06-30—2026-06-30 |
| events | 2,531,469 | 2,531,473 | 1993-11-08—2026-09-18 |
| insiders | 11,554,002 | 11,554,192 | 2008-01-02—2026-09-18 |
| descriptions | 384 | 384 | 字段字典，无日期列 |
| metrics | 30,891 | 31,121 | 1997-12-31—2026-09-18 |
| sp500 | 59,674 | 60,177 | 1957-03-04—2026-09-19 |

日期范围不证明所有 ticker 连续覆盖。metrics 是稀疏快照；Actions 的未来日期可能是已公告
生效日期，不等于历史可知时间。记录增长也不直接等于新增公司或经济事件：

- 前序价格同步新增 213 个 stocks 键均有 raw 支持；最新两轮截至检查点未重复增加。
- Actions 的 +266 含 264 条重新定日的关系；metrics 的 +230 含 228 次观察日期变化。
  S&P 500 的 +503 只是 `current` 快照续记，成分集合没有增加。
- 本轮仅 insiders +190、events +4；其中含 Form 3、重述和未确认的来源映射变化，
  不能宣称为 194 笔新交易。Tickers 的 +3 是较早入库的两个证券，本轮前后均为 74,235。
- UGAZF 倒退日期、41 条 AMD 旧 insider 记录不再返回、CND/CRCL 疑似映射变化等原因未明。
  旧观察保留并标明限制，不自行删除、改数或合并不同公司；保留历史不等于认证其为最新有效记录。

对应四份独立只读证据：`stocks-small-windows-verification-20260919.json`、
`actions-new-key-audit-20260919.json`、`metrics-sp500-new-key-audit-20260919.json`、
`revision-safe-insiders-events-tickers-audit-20260919.json`。
相关官方键重复、旧 canonical 键丢失及输入来源字段差异均为零；这些不是新的上游下载。

## 5. 本地路径与保全

事实库现位于 `/Users/yudonglu/Documents/thesisforge/data/fact_os/`：

- `raw/` 永久保留来源；`parquet/` 保存不可变派生分区。
- `fact_os.duckdb` 保存写入目录/状态；`manifests/catalog.json` 原子发布读取目录。
- `sync/` 保存锁；`audit/` 保存证据；`legacy_backup/` 保存旧库备份。

一致性备份：`legacy_backup/guru-analysis.before-fact-os.sqlite`；
SHA256 `45731e05381e81b7a88cde46b714380a50024ef3704a488ea17741438dd50d45`。
最终原库与备份 integrity_check 均为 ok；全部 20 表计数与初始备份一致。
备份 SHA 未变，原库和备份在 100-byte SQLite 文件头之后的所有字节也一致。
文件头仅 backup API 的计数/版本元数据不同；没有把两份 SQLite 的整文件 hash 不同误判成内容变化。
证据：`audit/legacy-preservation-header-aware-final.json`。三个旧库 quick_check 均为 ok，
未打开独立用户组合库或读取私人行内容。

七个早期归档 metadata 已通过保存的全量入库、HTTP redirect、ETag/length、SHA256 和 ZIP 信息
恢复，不虚构下载结束时间。数据、key、venv 被 Git 排除。
最终存储审计 `audit/storage-migration-final.json`（18:49 UTC）通过：

| 存储部分 | 逻辑占用 |
|---|---:|
| 整个 Fact OS 目录 | 8,809,478,021 bytes（8.81 GB / 8.20 GiB） |
| raw 及 metadata | 4,781,246,763 bytes |
| 当前引用的 347 个 Parquet | 3,163,460,374 bytes |
| 保留的 19 个旧代 Parquet | 147,331,428 bytes |
| 旧库备份目录 | 709,215,446 bytes |

实际分配 8,832,761,856 bytes。38 个内容寻址 raw 全部 SHA 正确，raw/Parquet
字节完全相同的重复文件均为 0；无缺失分区，当前可 GC 文件为 0，本次删除 0 文件。
raw 与派生列式文件、以及保留的历史代次用途不同，不是重复查入事实表。
本机根卷当时约余 33 GiB、使用率 97%；后续应关注容量，不能据此宣称磁盘无限可扩。

## 6. 价格及金额语义

| 显式类型 | 来源字段 | 用途 |
|---|---|---|
| RAW_CLOSE | closeunadj | 未复权报价、估值比较 |
| SPLIT_ADJUSTED_CLOSE | close | 拆股/股票股息调整，不含现金股息 |
| TOTAL_RETURN_ADJUSTED_CLOSE | closeadj | 支持的拆股、股息、分拆总回报序列 |

NVDA 全史 6,957 日期三种语义逐项对应来源，零差异；它们不是同一列的别名。
股票/ETF 按官方主数据进入 SEP/SFP。DAILY 市值从 USD millions 明确换算成 USD。

财报原币与交易币分开：当前、无 as-of 的原币指标从精确 SF1/permaticker 主数据取报告币，
附 current-master 来源并声明币种 PIT 不支持；不借用 SEP/SFP 报价币。
BABA 的 CNY、TSM 的 TWD 已只读核实。估值适配器原有美元换算正确，未把这些原币当作 USD。

## 7. 机构持仓实现

`get_institutional_ownership_history` 覆盖库内可用 ticker，不仅是配置的 Guru，
返回季度持有人数、股数、市值、总价值、percent-of-total 及相邻季度变化。
`get_holder_changes` 对本季/上季机构键做完整并集，输出 NEW、INCREASED、UNCHANGED、
DECREASED、EXITED；保留机构身份/名称、前后 units/value 及变化。
`get_investor_portfolio` 提供排名和披露组合权重。

SF3 保留 SHR、CLL、PUT、WNT、DBT、PRF、FND、UND；千单位/百万美元仅在语义层换算。
缺失季度不推断全部退出；身份用官方 investor ID/验证的 CIK，不按模糊名字合并。
GOOGL 2026 Q2 的 6,491 个机构键与源数据核对、单位变化守恒。
这些是披露观察和数量差异，不等于已核实的交易意图或整个基金 NAV。

## 8. PIT 与币种边界

AR 按可用日期和 fiscal reportperiod 双截止；ART 不重复年化。MR 重述数据拒绝历史 as-of。
25 条来源报告期晚于可用日期的记录保留并标记，语义层不用于 PIT。lastupdated 不是申报日；
日期精度也不保证同日收盘前可交易。首次历史下载并不构成迁移前完整的双时间版本档案。

**SF3 没有实际申报公开时点**：可看季末持仓/QoQ，但精确申报日回测明确不支持，
不编造 45 天可知时间、不返回旧曲线冒充。

历史/显式 as-of 的原币 currency 仍未知，不能倒用今天的报告币。
未知原币金额不得与 USD 混算；只有同一证券、同一 SF1 完整来源行的原币比率允许币种抵消。
FCFMargin v1 数值与七个基础指标定义未改。当前主数据也不是历史可投资股票池。

## 9. 旧源退出与消费者兼容

默认关闭行情、Guru、分红、旧 Ontology 定量缓存的旧源 fallback。
`FACT_OS_ENABLED=0` 仅是明确操作员 rollback，不是自动降级。
来源/缓存边界见[消费路径清单](fact-os-consumers.md)；组合 overlay 缓存按用户、来源模式和目录代次隔离。

当前报价/财务读取 canonical。Dart 的列表、两处详情与贵便宜判断已修复：
缺价只显示缺失，不借用 archived consensus.currentPrice 或旧 selectedRow。
已发布 DCF 输入/输出仍是明确标注的归档模型，fair value 未改、未重算。
保留独立 canonical 输入导出和隔离重建方案，但本次未构建新模型、排名或 Ontology 功能。

## 10. 日常同步策略与验收状态

自然键 UPSERT 保留旧历史；单作业锁防并发重复下载。SF3 默认回查最近三季，可配置 1—3 季。
财报使用四年初始窗口，DAILY 一年，stocks/funds 在已知历史使用 31 天窗口；
本地最早日期前仍覆盖 1900 年起的范围。满额/超时范围继续分解，完整集合双读后再发布。

关键修复已经纳入回归：上游分页/CSV/伪空问题、历史范围静默裁剪、A→B→A 修订恢复。
DAILY 补偿输入 291,900 条，原漏 93,094 键全部恢复，十个来源字段与本地一致。
“结果稳定”不等于“范围完整”，需独立覆盖证据。
当前内容相同才 no-op：不重写 Parquet/行来源；每次有效观察可新增 metadata receipt，
相同 checksum 的多条验证记录不是重复事实，raw 仍按内容去重。

已完成的真实 API 运行：`audit/live-sync-revision-safe-verified.json`；
起点指纹：`audit/live-sync-revision-safe-source-start.json`。
2026-09-19T15:48:52.578931Z—18:41:04.149292Z，两轮 14×2 全部成功，第二轮全 unchanged；
四项断言全部 true（历史未缩短、第二轮行数/日期覆盖相同、全部同步成功），errors 为空。
`live-sync-revision-safe-source-final.json` 的冻结源码核验通过。此前全部中断运行仍不计通过。
第一轮实际后台时长：

| 表 | 结果 / 本地行数 | 输入行数 | 耗时 |
|---|---|---:|---:|
| stocks | unchanged / 45,354,943 | 2,688,554 | 2,826.132 秒（47.1 分钟） |
| funds | unchanged / 15,637,697 | 2,435,263 | 718.242 秒 |
| daily | unchanged / 39,818,815 | 274,947 | 154.522 秒 |
| holdings | unchanged / 81,202,367 | 7,255,286 | 2,023.388 秒（33.7 分钟） |

后台完整验证仍慢，不能宣传为稳定提速或生产 SLA。
若来源两轮间合法变化，保留原始断言并用 source-key 证据解释，不擅改为通过。
离线固定输入重放不能替代真实 API 验收。额外的
`audit/offline-replay-partition-aware-final.json` 已在 OS 禁网下通过：14 表各重放两次全部
unchanged，366 个 Parquet 的路径、字节、mtime、全部表行数/日期均不变，只新增审计 metadata。
前一次预检将旧分区不存在的质量列与 union-by-name 的 null 混淆，造成工具假失败；
已修验证器并增加回归，原失败 `offline-replay-revision-safe-final.json` 保留，不改写为成功。

## 11. 手动命令

```sh
cd /Users/yudonglu/Documents/thesisforge
bin/fact-os status
bin/fact-os inspect --tables fundamentals
bin/fact-os backfill
bin/fact-os sync
bin/fact-os sync --tables holdings holdings_ticker holdings_investor --quarters 3
bin/fact-os gc
```

`inspect` 主动联网查权限；`status` 无需 key，仅反映本地覆盖/同步状态，
不等于当前远端授权。Key 只放本机 `.env.local` 的 `SHARADAR_API_KEY` 或环境变量。
`gc` 默认只预览；不会清理 raw。运行使用项目 `.venv-fact-os`。

本项目前端/API 未启动，未更改隔壁 5184 的旧预览。
后续本地页面验收可用 `FACT_OS_ENABLED=1 PORTFOLIO_NAV_AUTO_CAPTURE=false npm run dev`，
此处未执行；关闭 NAV timer 避免验收时写入私人历史。

## 12. 每日自动同步

Codex heartbeat `thesisforge` 已配置 ACTIVE，每天 Asia/Riyadh 07:30，仅失败通知。
任务仅本机运行 sync、检查 status、成功后可 gc --apply；排除 production 和私人库。
GC 只清理无引用且至少七天前的派生分区，保留每个分区至少两代并服从读锁，raw 永久保留。
配置已回读核实；首次无人值守执行尚未验收，不是云端保证执行的 cron。

## 13. 降级与权限失效

远端短窗口或 401/403 不得截短本地历史，其他可用表可继续；schema/分页异常停止对应发布。
空响应不推进 watermark，不代表全部证券消失；不换 key、不退回 Yahoo。
旧历史离线可读，授权状态另行记录。技术保全不改变许可条款；未来公开分发/production
仍需单独审查授权，本次未部署。

## 14. 最终验证结果

| 测试 | 最新结果 |
|---|---|
| Fact OS Python | 127/127；含 A→B→A 六项、币种语义九项新增回归 |
| Node | 51/51 |
| 迁移辅助工具 | 32/32；含离线重放验证器十四项、SQLite 备份头部检查三项 |
| Flutter | 15/15；相关 analyze 无问题 |

最终 `migration-final-verified.json` 在 OS 禁网下完成完整扫描：14/14 表、
201,159,454 行，所有自然键重复/空键为 0，backfill/state 行数一致，无缺失必需表。
目录 SHA `7032087b9290d2c5b592ee60c0df74cfcf6f95f240e8f4ae72cea0fdefcda58e`
扫描期间稳定，与最终存储审计一致。股票/基金异常价格为 0，25 条财报来源 PIT 异常全部标记并排除，
10/10 真实离线语义探针通过。此结论并不证明官方来源每个数字都没有经济含义上的错误。
NVDA 全史三价格零差异；MSFT 6,992 天市值单位核对零差异。
最新实际消费者 `consumer-offline-migration-final.json` 在 OS 禁网下 Node/Python 通过，
fetchAttempts=0；股票/ETF 价格到 2026-09-18，AVGO 报告期 2026-08-02、可用日 2026-09-10。
归档 fair value 保持未重算。股票历史调用 620—979 ms、基金 374—507 ms，
MSFT/AVGO 估值适配 2,216/1,963 ms，
不是浏览器整页或线上压力指标。运行版本 Python 3.14.7、DuckDB 1.5.5、httpx 0.28.1。

验收链：真实 API 两轮 → 源码指纹 → 固定输入两轮重放 → 稳定全表扫描 →
存储去重 → 旧库保全 → 实际离线消费者，均有独立 receipt，保存在 `data/fact_os/audit/`。

## 15. 剩余限制

- 本次通过的是本地事实库与已适配消费者验收，不代表所有业务功能或数据来源本身都已无误。
- SF3 缺实际披露时点；部分非 13F/重叠机构映射仍缺失，不猜身份或伪造回测。
- 外国 listing/ADR、历史币种/股票池未知时保持缺失，不拿今天的属性倒填历史。
- 已发布估值档案未重建；新增事实不等于旧模型已更新。
- 某些来源撤回、改标和重新定日原因未明；保留观察不等于认可其为最新有效经济事件。
- 前端/API 未运行新版，完整浏览器联调、生产部署/容量/许可及首次定时执行均未验收。

最终原则：**Sharadar 提供数据；本地 Fact OS 保全数据；FactRepository 提供语义读取。**
