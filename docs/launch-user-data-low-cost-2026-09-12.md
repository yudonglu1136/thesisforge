# 用户数据库：复用现有 AWS，不新增固定资源预算

更新：2026-09-12。用户明确取消新增预算，先完成少量用户所需功能。此前独立 staging / RDS / $150 月度新增预算方案停止执行；没有创建这些资源。

状态：**本机存储适配、备份恢复及部署防覆盖已实现；尚未部署或迁移生产用户。** 总发布结论仍见[上线清单](launch-preparation-2026-09-12.md)。不把本机测试或合成 AWS 演练当成真实用户迁移验收。

## 1. 当前方案

继续使用已有 AWS Elastic Beanstalk 单台应用服务器，以及已存在的 S3 备份桶。不新建 RDS、EC2、ALB、NAT、KMS、Secrets Manager 或独立 staging。

| 层 | 当前实施 | 后续扩展方式 |
|---|---|---|
| 登录 | 保持现有 Supabase Auth / 已验证用户身份 | 不重建账户，不改用户 UUID |
| 组合与券商连接 | 保持每用户 SQLite；后端凭据密文；原有账户与 NAV 键不变 | 在现有 store/service 边界实现 PostgreSQL 适配器，验证后迁移 |
| 用户索引与登录 | 保持已有独立 SQLite 表和身份映射 | 与用户业务库一起迁移，不按邮箱猜测归属 |
| 假设、watch、策略、决策 | 保持 `investment_events` 的 owner、追加事件与幂等协议 | 以后替换存储，不要求改 UI / API 协议 |
| 行情、财报、13F、估值 | 继续独立研究数据库及原有来源规则 | 不与私人用户数据混成公开发行包 |
| 恢复 | 含 WAL 的在线备份、AES-256-GCM 加密、独立目录恢复核验 | 使用已有 S3；以后再评估托管备份与多可用区 |

这是**可迁移的单机方案，不是多机高可用方案**。SQLite 适合较低写入并发的应用；同一数据库只有一个 writer，不应把数据库放在网络共享盘上供多台 API 同时写入。是否升级以写锁等待、请求延迟和多实例需求为准，不机械按注册人数决定。[SQLite 使用边界](https://www.sqlite.org/whentouse.html)

## 2. 本机与 AWS 使用同一份路径解析

实现：`server/userDataPaths.js`。已有环境变量和默认目录兼容；不因新增配置自动搬家。

只有**确认没有旧用户数据的新环境**，才可使用下列布局（配置示例，不是已执行的生产配置）：

```text
SQLITE_DB_PATH=/var/app/data/guru-analysis.sqlite
USER_DATA_ROOT=/var/app/data/users

/var/app/data/users/
  investment.sqlite
  portfolios/
    portfolio-admin.sqlite
    login-activity.sqlite
    <现有用户 HMAC 目录>/portfolio.sqlite
```

既有生产目录必须原样保留，例如显式设置 `USER_PORTFOLIO_DATA_DIR=/var/app/data/user-portfolios`。`LOGIN_ACTIVITY_DB_PATH`、`INVESTMENT_DB_PATH` 的既有显式设置继续优先。不复制、不重算旧用户 HMAC；**不能为了路径整齐而直接改 `PORTFOLIO_CREDENTIALS_KEY`**，否则既有目录和密文可能不可用。

- 新 root 必须是绝对路径、专用私有目录，不能是发行或静态目录。
- 研究库、登录库、注册索引和投资事件库不能指向同一个文件。
- 若检测到旧目录有数据、配置会切换到另一目录，启动检查拒绝静默切换；不会显示一个“看似空账户”的新目录。
- 本机与候选环境都使用 Node 22.23.2 验证。在线 backup API 要求 Node ≥22.16；不以本机 Node 26 的结果代替生产 Node 22 验收。[Node SQLite API](https://nodejs.org/api/sqlite.html)
- 单台服务器上按原 service 调用复用 WAL/索引；用户数据库句柄最多128个，驱逐后按原用户身份重新打开。缓存限制128条、64个同时加载。没有新增全局逐用户扫描到页面请求中。

`investmentRoutes.js` 的 production guard **仍保留**。统一路径并不等于已经审计批准生产投资工作流；需要把身份、持久化、发行与迁移关卡一起验收，不能只删除报错保护。

## 3. 备份与恢复工具

```bash
npm run user-data -- inventory
npm run user-data -- backup --output /private/operator-backups/new-generation
npm run user-data -- restore --input /private/operator-backups/new-generation --output /private/operator-restores/new-generation
```

示例目录需由运维创建为私有目录；输出目录**必须尚不存在**。工具不会创建公共接口，不接受请求中的用户身份或目录，不覆盖、合并到线上目录。`inventory` 只打印类别和数量，不打印持仓、金额、令牌或用户目录名。

备份前通过受限运行环境提供独立的 `USER_DATA_BACKUP_KEY`（32字节随机值，64位十六进制）和可选 `USER_DATA_BACKUP_KEY_ID`。密钥不要出现在 shell 历史、命令行参数、Git、聊天或日志里；使用0600的运维密钥文件或已有安全配置渠道，另行离机保管。不要把密钥放在同一个备份对象里。原券商加密/HMAC 密钥必须单独保留，外层备份加密不能取代它。

备份特性：

- SQLite online backup 把已提交 WAL 纳入副本，而不是只复制 `.sqlite` 主文件。私有副本转成单文件后，校验完整性、schema hash、表计数及文件 SHA-256。[SQLite 在线备份](https://www.sqlite.org/backup.html)
- 数据文件和清单分别加密认证；清单也不公开用户目录、表计数或身份。文件0600，目录0700。
- 每个数据库一致；**多个数据库不是同一个跨库事务**。用于切流前仍须冻结写入再生成最后一份副本。
- 遇到未识别文件、表、符号链接、路径重复、未知格式、缺少已配置的事件库，失败而不是静默漏备份。
- 当前上限10,000个文件 / 1 GiB明文总量；达到上限停止并报告，不裁掉老用户或历史。运维任务使用独立进程和超时，不能在请求线程中运行大备份。
- 恢复重新验证密文、大小、hash、schema、行数与数据库 integrity；损坏、错 key、路径穿越均拒绝。失败只清理本次新建的恢复目录，不触碰既有数据。

**同一块根盘上的备份不等于灾备。** 已核实现有 EB 根盘 `DeleteOnTermination=true`；`/var/app/data` 可以独立于发行目录，但不能保证实例终止后仍在。

## 4. 复用已有 S3

已只读核实：

- `us-east-1` 现有 EB 为单台 `t3.small`，版本仍是 `guru-admin-20260906-730dc21`；没有扩容或重启。
- 已有桶 `guru-analysis-dashboard-eb-378477120101-us-east-1`，默认 SSE-S3 AES256。
- 实例角色已有 `GuruAnalysisDatabaseBackupWrite`，仅允许对该桶 `database-backups/*` 执行 PutObject / AbortMultipartUpload。**政策存在不等于已验证该主机实际运行成功。** 恢复读取应使用受控运维身份，不给应用自动覆盖恢复能力。
- 当前 SSM 没有在线管理节点，未获得实时生产 SQL/schema/磁盘余量证据；没有因此开放公网 SSH 或添加宽泛 IAM 权限。

正式备份使用已有桶下独立的 `database-backups/user-data/<generation>/` 前缀：上传加密数据库在先、`manifest.enc` 在后。新 generation 不能覆盖旧对象。只备份私人业务库，不把几百 MB 的研究数据每次一起导出。使用桶现有成本预算，S3 存储/请求仍按用量收费，**不承诺账单绝对为零**。

准备的运维验证命令：

```bash
node scripts/verify-user-data-aws.mjs --synthetic-only
```

该命令仅生成两个合成用户，使用随机临时加密密钥，把密文写入既有桶的唯一 `database-backups/user-data-validation/<UUID>/` 路径，重新下载、验证字节与恢复内容，最后仅删除本次成功创建的对象（启用版本控制时删除对应版本）。不读取环境指定的真实业务数据库，也不上传真实用户数据。不是默认测试命令或自动启动任务。

2026-09-12 实际运维身份演练通过：2个数据库、24,576 bytes明文、3个加密对象，上传→下载→恢复核对耗时9,455ms；3个测试对象清理成功。**未验证生产实例身份的实际上传、真实用户凭据解密或生产RTO。**

正式定时任务建议先每日一次、14天保留，每月演练恢复；**当前未安装 timer、未设置生命周期清理，也未测得生产 RPO/RTO**。启用前记录实际单次大小、耗时、失败通知目标和预算占用。第一次真实用户备份应先确认目录/owner与密钥可恢复，不能把合成演练算作生产验收。

## 5. 避免部署误覆盖

退休旧 `00-restore-portfolio-from-snapshot.sh` 自动挂载任意附加盘并合并用户目录的行为；保留 hook 为明确的无写入提示，不删除旧 marker 或快照。诊断 hook 不再把用户文件路径列到部署日志。

实际恢复流程：冻结新写入 → 导出当前数据 → 恢复到新私有目录 → 核对身份/账户/事件/日期/币种及凭据解密 → 单独批准路径切换 → 检查 → 保留旧目录以便回滚。若恢复后已产生新写入，回滚前先保存增量，不能直接丢弃用户新修改。备份工具不负责擅自改变数据归属。

## 6. 验证与尚未完成的上线事项

- Node22全量服务端1496项通过；新增路径/备份10项包含在线 WAL、两用户隔离、原事件不变、幂等重放、错 key / 篡改 / 路径穿越 / 原路径保护及硬链接去重。
- 用户数据专项77项通过（含部署 hook 不执行挂载、合并、枚举或写入）；performance 与发布保护合并回归57项通过。
- 未改 Guru 计算、估值模型、产品 UI 或公开研究数据；未新建任何付费云资源。
- 待验收：实际生产目录/schema/密钥恢复、真实用户离机备份与定时任务、全用户同步/NAV任务、现有资源上的 HTTPS、production workflow guard、完整性能压测、clean trunk 候选发布与回滚。财报 API 和全 Guru 数据问题仍按总清单处理。

后续只有出现持续写锁/延迟超标、需要多个 API 实例或更严格恢复目标时，才重新评估 PostgreSQL/RDS 等预算。届时用现有存储接口替换实现，并跑双用户隔离、幂等、事件顺序、NAV和 count/hash 对账；不是靠把 SQLite 文件共享给更多机器扩容。
