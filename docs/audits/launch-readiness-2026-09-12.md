# ThesisForge 上线就绪审计 · 2026-09-12

## 结论

**NO-GO：目前不应将本机新版直接发布为正式用户版本。**

页面可访问、AWS 环境显示 Green、单元测试通过，都不能代替业务数据、持久化与安全验收。本次同时发现现网业务健康失败、新版功能尚未允许生产启用、真实用户数据依赖单机根盘，以及公开 HTTP 回源链路。

这是只读审计，不是修复发布：没有更新生产数据库、修改云配置、轮换密钥、开通服务、执行迁移、重启服务或部署。新增的文件仅为审计脚本与脱敏结果。现有未提交工作全部保留。

审计规范：按数据库质量审计核对粒度、日期、约束与证据；按 Supabase 和安全审查规范区分身份认证、用户业务数据、租户隔离和运行边界；按 PostgreSQL 规范提出后续迁移建议。建议不代表已经实施。

## 1. 实际运行状态，而非计划配置

| 层 | 现场核验 | 判断 |
| --- | --- | --- |
| 正式前端 | apex 与 www 均指向同一 Vercel production 部署；Git `trunk` / `730dc21`，2026-09-06 | 域名一致性通过，但不是本机最新功能 |
| 正式 API | AWS EB `guru-analysis-api-prod`，版本 `guru-admin-20260906-730dc21`，Node.js 22 / AL2023 | 与本机候选代码不同 |
| AWS 计算 | 实际 1 台 `t3.small`；ASG 最小/最大均 1；无负载均衡器 | 单实例，没有故障接管或横向扩展能力 |
| 配置漂移 | 旧 `launchconfiguration.InstanceType` 仍写 `t3.micro`，实际实例为 `t3.small` | 应以实例清单为准，并统一部署配置 |
| 本机 API | `127.0.0.1:8789`；研究、策略、行情、个人组合分别读取多份库 | 本机可用不等于这些数据已在生产 |
| Supabase | ACTIVE_HEALTHY，PostgreSQL 17.6，首尔 `ap-northeast-2` | 是现有认证服务；与美国东部 API 跨区域 |
| 本机开发模式 | 本机开启开发身份和 investment workflow；线上前后端 bypass 均为 false | 隔离方向正确，开发身份数据不能直接当正式用户数据 |

现有目录有约 507 项此前未提交/未跟踪变更；审计文件加入后计数增长。不能直接将整个工作目录当作已审核发行包。`scripts/package-aws-backend.sh:12` 使用 `git archive HEAD`，未提交的新文件又不会自动进入 AWS 包；这是另一个“本机有、上线没有”的来源。

## 2. 数据库清单与兼容性

以下大小为 SQLite 主文件，另列必要 WAL；是本机现场数据，不冒充生产磁盘数据。

| 数据库角色 | 主文件大小 | 表数 | 关键内容 | 检查结果 |
| --- | ---: | ---: | --- | --- |
| 本机实际 runtime | 2,856 MiB | 26 | 4,461,535 行价格；65,038 行 PIT 财报；85,312 行指引；31,953 个模型节点 | integrity_check=ok；声明的外键检查 0 异常 |
| 本机 strategy warehouse | 4,208 MiB | 21 | 1,131 份 filings；192,592 行 holdings；5,435,057 行价格观测 | integrity_check=ok；声明的外键检查 0 异常 |
| composition prices | 519 MiB | 4 | 4,511,582 行价格，1,581 条 series | integrity_check=ok |
| 用户研究事件库 | 主文件 4 KiB，WAL 约 1.97 MiB | 1 | 67 个事件，当前仅 1 个开发 owner | JSON、payload hash、完整性均通过 |
| 本机 owner portfolio 镜像 | 256 KiB | 9 | 261 个 NAV 观测；daily_mtm 表为空 | 完整性通过；不代表有券商逐日 MTM |
| 仓库内默认 runtime seed | 192 MiB | 18 | 价格最晚 2026-09-03；没有 PIT 财报/指引/模型表 | 文件完整，但不等价于本机实际 runtime |
| 仓库内 Ontology snapshot | 0 字节 | 0 | 没有有效业务表或 manifest | 不能作为有效模块快照；空库 integrity=ok 不等于业务可用 |
| AWS runtime / 用户 SQLite | 路径与应用配置已核验 | 未直接读取生产 SQL | runtime 位于 `/var/app/data/guru-analysis.sqlite`；用户目录由其父目录派生 | 生产全量 integrity/schema/数据量仍需只读主机核验 |
| Supabase Postgres | 约 11 MB | public 业务表 0 | 27 个 Auth 用户；近 30 日有登录记录的 8 个；3 条既有管理员 RPC 迁移 | 认证库存在；未建立应用业务表 |

主库、strategy、composition 三份数据合计约 7.4 GiB，不应简单累加为内存需求；但在单机运行两个回测 worker、更新、备份和压缩时，应实际测 RSS、磁盘余量、临时空间与锁等待。

`foreign_key_check=0` 只覆盖已声明约束，不能证明所有经济含义、持仓归属、币种和源数据链接均正确。没有对全部公司重新进行财务重算，也没有宣称所有 PIT 结果已经获认证。

### 数据更新的具体缺口

- 本机价格共 1,598 个 symbol，1,517 个到达 2026-09-10，81 个更早。历史集合包含退市、旧代码等，不能把这 81 个全部视作漏更新；应与当前有效证券、持仓及交易日历相交后逐项审核。
- 本机 PIT 财报的 `available_at` 最晚仍为 **2026-08-27**；PIT 模型 `as_of_date` 最晚也是 **2026-08-27**。9 月更新的 `imported_at` 或 `generated_at` 不等于新的经济数据。
- **AVGO 明确落后**：实际库 ARQ/ART 最后报告期 2026-05-03、available_at 2026-06-09，模型日期 2026-06-09。官方已于 **2026-09-02** 披露截至 2026-08-02 的第三财季结果，因此截至 9 月 10 日仍展示旧节点不是“没有新财报”。[SEC 8-K](https://www.sec.gov/Archives/edgar/data/1730168/000173016826000076/avgo-20260902.htm)
- 31,953 个模型节点的已存 `financial_available_at`、`guidance_max_observed_at` 未发现晚于 `as_of_date` 的记录；已测 JSON 无解析错误。这只是元数据次序检查，不能排除源数据本身被重述后回填等更深层 PIT 问题。
- 现网 health 的行情最大日期也是 9 月 10 日，但这只是模块最大值，不能据此声称所有股票、所有模型均已更新。

## 3. 发现清单

优先级：P0 为正式开放前阻断项，P1 为生产可靠性/性能必修项，P2 为上线硬化项。这不是 CVSS 评分。

### LR-01 · P0 · 业务健康失败，曲线刷新与覆盖不达标

**证据：** 2026-09-12 现场请求 `/api/health` 返回 HTTP 503；AWS EB 自身仍显示 Green。现网 28 位启用经理 × 5Y/10Y 共 56 条必需结果中，仅 **1 条 displayable**（proxy），strictReady=0。5Y 为 0/28，10Y 为 1/28。55 个失败的首要原因均为 `strict_curve_stale`。

**不能误读为“55 条曲线都不存在”：** 失败明细中 28 条原始 strict 状态是 ready 但已过期，27 条为 insufficient_data；其中 26 条报告执行覆盖不足，1 条缺少 active price。当前生成新鲜度要求 48 小时，配置 `GURU_BACKTEST_AUTO_REFRESH=false`。有部分近期生成记录，所以仅凭该开关不能断言完全没有外部刷新任务。

**影响：** 真实用户看不到合规可展示的曲线；基础设施健康不能反映业务失效。

**修复方向：** 查明实际调度归属，恢复幂等刷新/告警；逐项处理覆盖缺口；完整执行当前启用 Guru × 时间窗 × strict/proxy 验证并原子发布。不得通过放宽覆盖门槛、伪造价格或混同 proxy/strict 让健康变绿。

**验收：** 业务 health 为 200；全部期望行有符合既有政策的结果；同一 generation/security-master/方法版本；错误刷新不能覆盖最后一份有效快照。修改经理名单时分母同步变化。

**来源：** `launch-readiness-2026-09-12/http.json`；`cloud.json`；`server/index.js:133`。

### LR-02 · P0 · 新功能没有完成生产适配与数据发布

**证据：** `server/investmentRoutes.js:45–49` 明确限制 investment workflow 为 local/preview，生产启用会主动抛错。AWS 当前未配置新版 workflow / investment / strategy 数据路径。默认 seed 缺少 8 个实际 runtime 表，Ontology seed 为空。正式前端/API 是 9 月 6 日版本。

**影响：** 直接上线页面可能出现接口缺失、进程启动失败、读取错误/旧数据库，或假设保存功能不可用。

**修复方向：** 保留这道安全门，先完成用户库迁移、只读研究库发行包、schema/version/hash/cutoff 清单、独立 staging；通过后再以单独评审发布启用。不可简单删除 production guard。

**验收：** 从干净 trunk 构建；Linux Node.js 22 验证；同一代码/数据 release ID；真实身份端到端可读写；本机与 staging 同 fixture 的结果一致；明确回滚流程。

**来源：** `server/investmentRoutes.js:45`；`scripts/package-aws-backend.sh:12`；`local-databases.json`；Vercel / AWS 只读部署元数据。

### LR-03 · P0 · Vercel → AWS 实际通过公开 HTTP 传输

**证据：** Vercel production `AWS_API_ORIGIN` 的实际配置为 `http://…elasticbeanstalk.com`，不是仅代码默认值。`api/proxy.js:40–47,87–95` 转发 Authorization，137 行起转发请求体，145 行依协议选择 HTTP/HTTPS。EB 实例安全组当前开放 80、没有 443，且没有 ALB。

**影响：** 浏览器到网站虽然是 HTTPS，但下一跳没有 TLS；用户 bearer token、提交的券商连接凭据及返回的个人组合数据存在传输保密性风险。没有证据表明已发生泄露。

**现有缓解：** `/api/internal/*` 大小写路径已在公开代理和 AWS 入口拒绝，实测均 404；内部任务秘密未在本次审计中发送。这只保护 internal namespace，不保护普通用户 API。

**修复方向：** 在 API 入口配置受信任 HTTPS（例如 ALB+ACM 或正确配置的反向代理 TLS），验证证书和回源策略；限制/关闭公开敏感 HTTP 访问；代理拒绝非 HTTPS 的正式上游。仅 HTTP 重定向不够，因为凭据可能在重定向前已发送。

**验收：** 从浏览器、Vercel、API、数据库逐段验证传输加密；非法证书失败关闭；未认证 401、内部端点 404 仍通过。不要因修复而向公开 API 发送 internal cron secret。

### LR-04 · P0 · 个人数据依赖随实例终止删除的未加密根盘

**证据：** 唯一挂载 EBS 为 30 GiB gp3，`Encrypted=false`，`DeleteOnTermination=true`。用户库默认根目录由 runtime 路径派生到 `/var/app/data/user-portfolios`；部署 hook 仅创建目录，不是外部持久化挂载。

**影响：** 同机普通重新部署可能保留 `/var/app/data`，但实例替换/终止不是同一回事；根盘丢失将同时影响公共 runtime 和个人连接/NAV/登记数据。多实例部署会产生多份互不一致的用户库。AES 加密凭据并不意味着整份 SQLite、邮箱与 NAV 均已加密。

**备份事实，避免过度断言：**

- 活跃根卷直接关联的快照 21 份，均未加密，最近 2026-09-06。
- 另找到 2 份带来源标签的加密回滚副本，最近 2026-09-03。因此不能说“完全没有加密备份”。
- 已知 S3 `database-backups/` 前缀有 11 个对象，最近 2026-09-05；`portfolio-backups/` 前缀为空。对象仅检查元数据，未验证内容或恢复。
- us-east-1 未找到 AWS Backup plan 或 DLM policy；这不排除其他前缀、区域或主机 cron 备份。
- 现有一次性 portfolio 恢复 hook 和迁移前备份不等于定期备份、可验证 RPO 或自动灾备。

**修复方向：** 将用户业务数据迁到独立托管 PostgreSQL；KMS 加密、私有网络、TLS、自动备份/PITR、删除保护和恢复演练。公共研究库使用带校验清单的不可变快照，可重建，不与用户写入混放。AWS 官方也要求将应用持久状态外置，而不是依赖可替换实例。[EB 持久状态设计](https://docs.aws.amazon.com/elasticbeanstalk/latest/dg/concepts.concepts.design.html)

**验收：** 在 staging 替换实例后账户、组合、草稿、策略完整保留；恢复指定时间点后逐用户核对记录数/hash；明确并演练 RPO/RTO。建议目标 RPO≤15 分钟、RTO≤60 分钟，尚未测得，不是现状承诺。

**来源：** `cloud.json`、补充云证据；`server/userPortfolioStore.js:9–15,79–81,127–158`；`.platform/hooks/predeploy/01_create_data_dir.sh:4`。

### LR-05 · P1 · 用户身份已有，但业务数据生命周期分散

**证据：** Supabase 有 Auth 用户而 public 无业务表；现有业务落在 per-user portfolio SQLite、admin registry、login activity 与 investment events 等不同库。本机研究事件全属于开发 owner。`server/userPortfolioStore.js:33–49` 同一秘密同时派生加密密钥和用户目录哈希；凭据载荷没有 key-version。`server/portfolioClient.js:1813` 定时捕获未传 user，走默认账户上下文，而不是遍历所有真实用户。

**影响：** 不能证明“每位用户均自动同步”；密钥轮换会同时改变目录定位与解密能力；账号删除、数据导出、历史迁移、连接恢复缺乏统一数据库约束与生命周期方案。

**已有保护：** 用户查询有 owner 限定、连接 AES-256-GCM 加密、事件有幂等键和不可修改触发器；真实未连接用户不会借用本机 owner 组合。这些应保留，而不是重写丢弃。

**修复方向：** 以 Supabase `sub`/UUID 为稳定用户主键；建立用户业务库、账号/快照/同步任务/研究事件关联；显式迁移开发 owner 与真实 owner，绝不批量公开私人草稿。凭据使用带版本的信封加密，密钥轮换不改变用户标识。定义账户删除与合法留存、撤销令牌/同步任务及恢复策略。

### LR-06 · P1 · 性能当前靠缓存，扩容保护仍不足

**实测：** 本机 Fundamentals 首个采样 5,409ms、缓存后单次 9–11ms；JSON 2,065,846 bytes、gzip 511,510 bytes。首个采样不是清空全部缓存/重启后的可重复冷启动基准。

**代码证据：**

- `server/investmentStore.js:31–32` 每次按 owner 读取全部事件并解码，没有 SQL 分页/上限；EXPLAIN 显示临时排序。当前只有 67 个事件，尚不能证明生产慢，但自动保存增长后会放大。
- `server/userPortfolioStore.js:15,165–174` 打开的每用户 SQLite handle 缓存无淘汰；`server/portfolioClient.js:54,1748–1760` 组合缓存也无总量界限，同一用户并发 miss 未做 single-flight。
- `server/strategyLabRoutes.js:8–17,29–35` 已使用 worker、超时和全局并发上限 2，但没有按用户公平队列、持久任务或结果去重缓存；扩成两个 API 实例时限额还会变成各进程独立。

**影响：** 首访等待、传输/解析开销、用户数增长后的内存/句柄积累，以及少数用户占满回测资源。

**修复方向：** 列表返回摘要+分页，详情按需加载；按发布版本预计算公共指标；用户数据坚持 private/no-store，不能为了缓存变为公共可缓存。事件增加 latest projection 与 cursor 分页；连接/缓存有界；同步单飞；重计算用可取消、按用户配额的队列与 worker，缓存键包含规则、数据版本、PIT cutoff 和访问范围。

### LR-07 · P1 · 财报/模型更新未随行情发布

详见 AVGO 与 PIT 日期核验。更新任务须分开记录价格日期、报告期、披露时间、导入时间和模型版本；按当时可用信息计算，再原子发布财报、指引、模型及其展示快照。不能仅改首页 as-of 或重新生成旧节点的时间戳。

**验收：** 每个在用公司都有最近应到财报与模型状态；AVGO 新季度可被实际 API 选择；已有用户假设仍保留；历史 PIT 节点不被当前新指引污染；失败批次不替换当前有效版本。

### LR-08 · P2 · 性能预算与安全硬化未全部过关

- `npm run test:performance`：40 通过、1 失败；Guru 头像总量 **1,157,636 bytes**，超过项目 **1,048,576 bytes** 预算，约超 10.4%。来源：`scripts/static-performance-budget.test.mjs:163–183`。应压缩/优化资产，不能单纯调高门槛。
- `npm audit --omit=dev`：1 项 moderate、0 high/critical，涉及传递依赖 qs 的 DoS 公告；有可用修复。当前应用实际可利用性未证实，锁文件升级后要重新测试。[qs 公告 1](https://github.com/advisories/GHSA-x5fp-wj9c-mxmx)、[公告 2](https://github.com/advisories/GHSA-4mjr-xmp4-gh2g)
- Supabase security advisor 提示 leaked-password protection 未启用；如果开放密码注册，应启用并验收。performance advisor 没有告警，但应用表为空，不能用它证明 SQLite 性能良好。[Supabase 密码保护](https://supabase.com/docs/guides/auth/password-security#password-strength-and-leaked-password-protection)
- 根页面实测有 HSTS，但无 CSP、frame-ancestors/X-Frame-Options、nosniff；应在不破坏 Flutter/CanvasKit 的前提下逐步启用安全头。未执行 CSP 改动。
- 非允许 Origin 返回 500，而非明确 403；未发现放行跨域，但错误处理需要收敛。代理请求体先整体缓冲，应增加明确大小/时间边界；实际平台限制及可利用性未完整测试。

## 4. 用户数据库应该怎么搭建

**不是再建一套登录系统，也不是给每个用户创建一个 PostgreSQL 数据库。** 保留现有 Supabase 认证与用户 UUID，把应用业务存储迁为一个独立、按用户隔离的托管关系数据库。

### 建议采用的方案

本项目 API 已在 AWS 美国东部，建议主方案为 **同区域的独立 RDS PostgreSQL 用户业务库 + 现有 Supabase Auth**。研究行情仍采用版本化只读数据包；不要为了“统一数据库”把所有价格、回测扫描和个人写入塞进同一个热点库。

```text
浏览器 ──HTTPS── Vercel ──HTTPS── AWS API
                                  ├─ 验证 Supabase 用户身份（现有账号不变）
                                  ├─ 用户业务 PostgreSQL（私网、TLS、按用户隔离）
                                  ├─ 公共研究只读快照（财报/13F/估值/价格版本一致）
                                  └─ 同步与回测队列 → 独立 worker → 结果/审计记录
```

这是建议架构，尚未购买或创建资源。替代方案是使用 Supabase 托管 Postgres 承载业务表，但现有项目在首尔，不能忽略其与美国东部 API 的跨区域往返。选择这一方案时须先验证区域延迟，必要时调整部署区域与迁移计划；不要为了新建库丢掉现有 27 个账号。

### 业务表与约束映射（建议，不是已经存在的新字段）

| 业务域 | 承接现有内容 | 必需的隔离/约束 |
| --- | --- | --- |
| 用户资料/偏好 | 现有 registry、语言、隐私设置 | `user_id` 唯一，取验证后的 Supabase sub，不以邮箱作为租户主键 |
| 券商连接/账户 | 已有 IBKR 连接和账户标识 | 用户+provider/account 唯一；凭据只对后端开放；带 key version 的密文 |
| 组合快照/持仓/NAV/收入 | 现有 portfolio 表及有来源的快照 | 用户、账户、日期/证券/来源的组合唯一键；保留币种、口径、source date；金额精度明确 |
| 研究事件与当前版本 | watch、scenario、valuation_draft、decision、strategy 等现有 event kinds | 保留 append-only 审计和幂等键；增加可索引的当前版本投影，历史 cursor 分页 |
| 同步/回测任务与结果 | 现有后台任务、策略 worker 结果 | 用户+幂等键；状态、版本与错误；重试可追踪；按用户配额 |

这些是后端迁移建议，不要求改动现有 Guru 字段、评分或 UI。业务行为和计算保持原样。

### 权限设计要点

- API 验证签名、issuer/audience/expiry 后才设定用户上下文，忽略请求体中的 owner。
- 所有用户表启用 RLS；应用运行角色非 owner、无 BYPASSRLS。RDS 不自带 Supabase 的 `auth.uid()`：必须由已验证 JWT 的 API 在**每个事务内**用 `SET LOCAL` 设置用户 UUID，并配置相应策略；连接池复用不得遗留上个用户身份。
- 若使用同一 Supabase 项目的业务表，采用 `(select auth.uid()) = user_id` 的 USING/WITH CHECK、明确角色授权与索引；涉及视图应核验 security-invoker。service-role 不得暴露给前端。[Supabase RLS](https://supabase.com/docs/guides/database/postgres/row-level-security)
- 凭据独立私有表/秘密存储，信封加密使用 KMS，轮换需支持旧版本解密并可追踪；日志不得写密钥或完整个人组合。
- 用户间不共享私有 API 缓存。公共研究缓存与个人草稿、券商连接分层。
- RDS 的 app 用户表以现有 Auth UUID 为键，但跨数据库不能直接 FK 到 Supabase `auth.users`；通过受控账号同步、注销/禁用流程和本地 FK 维护完整性。

### 迁移实施顺序

1. 先修 HTTPS；定义 prod/staging/dev 环境契约及密钥边界。
2. 在 staging 建立用户库、迁移版本、RLS、索引、连接池、备份与监控；dev 使用相同 PostgreSQL major/schema，而非仅靠 SQLite 测试代替。
3. 对所有现有用户 SQLite 做一致性备份（含 WAL 状态，通过 SQLite backup API，不是直接复制一个正在写入的主文件）；建立已核实的 UUID 映射。
4. 幂等导入连接、NAV、研究事件；逐用户 count/hash/日期/币种和抽样读数对账。开发 owner 必须人工确认归属后迁移，不能广播给所有账号。
5. 保留源 SQLite 与加密回滚备份；在短暂冻结写入或经过验证的增量捕获下完成最终同步与读写切换，避免未经验证的双写。
6. 两个真实测试用户验证注册、连接、同步、自动保存、重登恢复、越权访问拒绝、删除/撤销、实例替换和回滚。不要用开发 bypass 代替这项验收。
7. 公共数据通过另一条原子发布流水线同步，重新生成所有必要快照/曲线，只有全部 release gate 通过后才正式启用新版。

建议启用自动备份、PITR、删除保护，并在隔离环境定期恢复演练。RDS 的 PITR 会恢复为新实例，不能只看“备份任务成功”就认定恢复可用。[RDS 时间点恢复](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_PIT.html)

## 5. 性能测量与测试结果

### 接口测量

| 本机只读 API | 首个采样 | 缓存后单次 | c=5 的 p95 | 原始 JSON / gzip |
| --- | ---: | ---: | ---: | ---: |
| Fundamentals | 5,409ms | 9–11ms | 49ms | 2,065,846 / 511,510 bytes |
| GOOGL Research | 19ms | 2–3ms | 13ms | 330,598 / 47,908 bytes |
| Guru study | 1ms | <1ms–1ms | <1ms（毫秒取整记录为 0） | 20,845 / 5,209 bytes |

每条接口为 1 次首样、5 次顺序、20 次请求按并发 5 发送；全部 200，条件请求返回 304。不同接口共享已加载对象，后三者不能解读为互相独立的冷启动测试；未强制清缓存。受限采样的分位数不等于生产 SLO。

线上 health 首次约 4.95 秒；8 个并发元数据请求约 283–520ms，均返回 503。**失败响应变快不代表业务性能通过**。没有对生产执行重回测压测或真实用户数据批量请求。

CloudWatch 最近 24 小时（09-11 12:00 至 09-12 12:00 UTC），24 个小时桶平均 CPU 的平均值约 **0.30%**，观察到的桶内最大值约 **0.56%**。这是当时低负载，不是容量证明；未取得主机 RSS、磁盘空余、I/O 等待或真实高并发流量数据。当前没有证据支持“只升级服务器就能解决”。

### 已执行的验证

| 检查 | 结果 | 边界 |
| --- | --- | --- |
| `npm run test:server` | 1,472 通过，0 失败 | 当前本机代码，非现网数据全量验收 |
| `flutter test --no-pub --reporter expanded` | 527 通过 | 有 off-screen tap 警告；不能代替实际浏览器验收 |
| `flutter analyze --no-pub` | No issues found | 当前本机 Flutter 3.44.1 / Dart 3.12.1 |
| `npm run test:ontology` | Python 3 项、Node 22 项测试通过 | fixture 测试通过，不修复空的本地 snapshot |
| `npm run audit:i18n` | 通过 | 文本/覆盖检查，不等于所有页面视觉通过 |
| `npm run test:performance` | 40 通过、1 失败 | 头像总包预算超标 |
| `npm audit --omit=dev` | 1 moderate | qs 传递依赖，实际可利用性待确认 |
| 6 份非空本地 SQLite | integrity 均 ok；已声明 FK 0 异常 | 没有生产全量 integrity 结果 |
| 匿名受保护 API | 401 | 不能据此推断所有新版路由已部署 |
| 公开 internal 大小写路径 | 404 | www、apex、EB 入口均测；未发送 internal secret |
| Vercel aliases | 同一 production / trunk 部署 | 不代表本机候选已发版 |

本机 Node v26.7.0，AWS 为 Node 22；应在与生产一致的 Linux/Node 22 CI 再跑，当前结果不是跨运行时兼容性证明。

### 还没有通过/无法在本轮完成的发布验收

- 没有执行新的 production build/deploy；既有构建脚本会清理 `dist`，本轮审计没有覆盖用户当前构建产物。
- 尚无完整 Linux/Node 22 build、真实身份浏览器端到端与中英文桌面/移动分辨率验收。
- 未执行仓库规定的 60 顺序 + 60 并发（c=20）、三轮同快照性能门槛，以及全启用经理曲线发行矩阵；当前明确阻断项已足以判定不可放行。
- 没有取得生产主机的只读 SQL/文件系统通道：SSM 未列出可用托管实例，当前安全组无 SSH。没有为审计开端口或改变访问策略。
- 因此生产 schema/hash、逐证券完整性、用户库数量、磁盘余量、备份内容与恢复能力仍为**未验证**；应用 health 的 database healthy 不能填补这些证据。
- 数据供应商再分发许可、账单限额、监管/隐私合规和外部完整渗透测试不在本轮认证范围内。

## 6. 上线修复优先顺序与放行条件

1. **先保密与保数据：** HTTPS 回源；用户库独立持久化；加密、备份、恢复和 UUID 迁移。
2. **再统一发行版本：** prod/staging/dev 相同迁移；选定数据 release，修复 AVGO 等财报缺口与 Guru 曲线 readiness，原子发布。
3. **再做性能治理：** 首访摘要/预计算、事件分页、缓存边界、回测队列、头像预算、监控；用同版本基准决定是否扩机器。
4. **最后完整放行：** 代码测试、全数据矩阵、真实双用户隔离、断连/重试/重启恢复、双域名和双语言浏览器 QA、性能三轮与回滚演练全部通过。

P0 未清零前不建议正式开放；有了 PostgreSQL 也不会自动修复错误财报或过期曲线。对外应明确真实数据日期与未覆盖原因，不承诺“所有数据都已最新”。

## 7. 审计证据与复现

所有文件位于 `docs/audits/launch-readiness-2026-09-12/`：

- `collect.mjs`：只读采集脚本；database / freshness / cloud / http / preview-performance 模式。
- `local-databases.json`：本机表、计数、索引、完整性与 schema hash。
- `freshness.json`：精确 SQL、集合覆盖和 PIT 日期顺序结果。
- `http.json`：现网只读请求、曲线失败明细与并发 health 样本。
- `preview-performance.json`：本机请求延迟、字节、缓存头、条件响应。
- `observations.json`：测试汇总及补充 Vercel/Supabase/备份只读结果。
- `cloud.json`：AWS 配置、盘、快照与备份计划清单的脱敏摘要。

采样时间在各 JSON 内。原始用户名、邮箱、令牌、IBKR key 和组合金额未写入审计材料。报告是截至采样时刻的证据，不会自动随部署或数据库更新而刷新。
