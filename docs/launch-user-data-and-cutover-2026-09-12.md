# 用户数据库与上线切换实施单

状态：**旧扩容方案已被用户的新预算要求取代，不执行、不申请新增资源。** 当前执行[复用现有 AWS 的低成本方案](launch-user-data-low-cost-2026-09-12.md)。以下仅保留为将来用户规模增长后的迁移参考，不能据此建立 RDS、staging 或付费 HTTPS 资源。
关联：[总任务清单](launch-preparation-2026-09-12.md)。以下方案不改变 Guru 字段、计算、评分或 UI。

## 1. 目标结构

保留现有 Supabase 登录与用户 UUID。用户业务库采用与 API 同区域（us-east-1）的独立托管 RDS PostgreSQL；行情/13F/模型继续走不可变、只读、带来源版本的数据发布包。

```text
浏览器 → Vercel → HTTPS API
                    ├─ Supabase Auth：验证身份，保留原账户
                    ├─ 用户 PostgreSQL：组合、连接、草稿、策略、任务
                    ├─ 只读研究快照：价格、财报、13F、PIT 模型
                    └─ worker：同步与回测，不阻塞页面请求
```

现有 Supabase 项目在首尔，不直接把跨区域业务查询延迟忽略掉。也不为每个用户创建一个 RDS 实例。RDS 支持 Multi-AZ 主备部署，但这不是恢复演练的替代品。[AWS PostgreSQL 部署说明](https://aws.amazon.com/rds/postgresql/pricing/)

## 2. 迁移对应关系

| 当前来源 | 目标职责 | 迁移必须保留的约束 |
|---|---|---|
| `portfolio-admin.sqlite / portfolio_user_registry` | 用户资料、旧目录映射 | 经验证的 Auth UUID 为主键；旧 HMAC 仅作迁移映射；不能按邮箱自动合并 |
| `login-activity.sqlite / login_activity_users` | 已验证登录与访问记录 | `user_key` 是 SHA-256，不是可直接转成 UUID 的原始 ID；用已核实 UUID 重算匹配；访问时间不能补作登录时间 |
| 每用户 `portfolio_connections` | 券商连接及账户配置 | provider/账户幂等，已有多账户语义不变；后端密文、用户隔离；迁移时禁止日志输出 token |
| `portfolio_connection_recovery` | 断连恢复窗口 | 原始过期时间保留；过期内容不得变成永久备份或恢复为有效连接 |
| `portfolio_nav_points` | 每账户每日 NAV/现金与来源 | 唯一键为用户+账户+日期；保留 source/source_date/payload；NULL 不是 0；不能从当前持仓伪造历史 |
| `investment_events` | watch、scenario、valuation_draft、decision、strategy 等 | 原 ID、sequence、kind、ticker、operation_id、request_hash、recorded_at、payload 与 hash 不变；追加审计与幂等语义不变 |
| 本机 owner 组合导入库 | 经显式确认的个人数据导入 | 不默认属于所有用户；不纳入公共研究发行包 |

本机 `local-dev-user` 的研究事件必须隔离留存，明确归属后才可迁移，绝不能挂到第一个正式用户或所有用户上。迁移前完整枚举实际 event kinds、账户及来源表；发现未识别表/字段即停止，不丢字段凑完成率。

## 3. 权限、加密与查询

- 运行角色非表 owner、无 BYPASSRLS、无 DDL 权限；迁移角色单独保存。
- 应用验证 JWT 的签名、issuer/audience、有效期后，在每个事务中用参数化 `set_config('app.user_id', $1, true)` 设置 UUID；commit/rollback 后归还连接。不得用连接级 SET，避免连接池残留用户身份。
- 所有用户表启用并强制 RLS，USING/WITH CHECK 均校验用户；RDS 不自带 Supabase `auth.uid()`。数据库不允许浏览器直连，运行凭据只供受信 API 使用。RLS 是纵深防护，不能代替防 SQL 注入或将客户端 owner 当成可信身份。
- 用户+账户+日期、用户+kind+sequence 等查询建立匹配索引。先用有界连接池、分页及当前版本投影；完整历史保留，不在每次加载时全表重放。
- 本机与 staging 使用相同 PostgreSQL major/schema；SQLite 单测不能当作 PostgreSQL/RLS 验证。
- 凭据使用带版本的信封加密与 KMS，稳定 UUID 不依赖加密 key。现有 AES-GCM 三段格式和旧目录 HMAC 只在受控迁移器中读取；先证明旧版本可解密、再重加密与核对，保留回滚密钥。不得直接换 `PORTFOLIO_CREDENTIALS_KEY` 后声称轮换完成。
- 会话撤销、账户删除、任务取消和法定留存分开处理；删除 Auth 用户不能假定已有 access token 已即时失效。[Supabase 安全说明](https://supabase.com/docs/guides/auth/sessions)

## 4. 未来资源变更参考（已取消本轮实施）

拟先建立独立 staging，不切现有用户流量；通过后才建立生产用户库并安排切流：

- 生产 RDS PostgreSQL：`db.t4g.small` Multi-AZ 起步；私有子网、安全组仅允许 API/迁移执行器；加密、删除保护、14 天自动备份。
- staging：独立 Single-AZ 小规格，合成用户与脱敏样本；不复用生产 broker key。
- API HTTPS：在新 staging 入口配置有效域名证书及 HTTPS，验证后再调整生产 EB/入口。**当前 `api.thesisforge.tech` 已承担 Ontology，不能覆盖它。** 不以 URL 改成 `https://` 假装现有 EB CNAME 有可用证书。
- KMS/Secrets Manager、加密备份存储、健康/同步/新鲜度/容量告警；不顺便购买 WAF、NAT、RDS Proxy 或大规格数据库。需要额外资源时重新说明原因与费用。

2026-09-12 用 AWS Price List API 查询 us-east-1 PostgreSQL 按需实例费：Multi-AZ `db.t4g.small` 为 $0.065/小时，Single-AZ 为 $0.032/小时；按每月 730 小时分别约 $47.45、$23.36。**两项合计 $70.81 仅是数据库实例费，不是全栈报价**；存储、备份、网络、负载均衡、密钥/秘密、日志、CPU credit 和税另计。[AWS 定价口径](https://aws.amazon.com/rds/postgresql/pricing/)

原建议新增预算 $150/月已撤回；用户要求先不新增预算，复用现有 AWS。当前没有创建任何这些资源。以上历史报价不作为现在的采购或部署指令，未来确需扩容时重新评估。

## 5. 未来托管库迁移参考（非当前执行清单）

- [ ] 批准新增云资源及费用；确认可用于财报增量的有效 API 权限。
- [ ] 只读核验生产主机 schema、用户库目录、磁盘余量、所有权映射；当前没有直接生产 SQL 证据。优先受控 SSM/私有执行器，不对公网开放 SSH 或内部 bearer API。
- [ ] 搭建 staging 网络/TLS/PostgreSQL；应用读写适配器、schema 迁移及 RLS 自动化测试。
- [ ] 用 SQLite backup API 获取含 WAL 的一致性副本；不能直接复制正在写入的 `.sqlite` 主文件。
- [ ] 合成双用户演练：访问隔离、连接池复用、重复导入、断连/恢复、密钥轮换；正确用户 count/hash/日期/币种逐项一致。
- [ ] 导入经确认的真实用户副本；只读对账、保留原始密文与 owner 映射；仍不切流。
- [ ] 每用户同步/NAV 调度、幂等队列、失败重试与告警；不能只运行 legacy operator 账户。
- [ ] 加密备份并在独立环境恢复到指定时间点；记录实际 RPO/RTO、恢复耗时、逐用户核对。目标 RPO≤15分钟/RTO≤60分钟，尚未测得。
- [ ] 公开数据完整候选发行：财报 append、价格截止日、32 位启用经理及所需 64 个 5Y/10Y 结果；不降低既有覆盖率和来源规则。
- [ ] 相同源提交、相同数据库的三轮性能门槛，Node 22/Flutter/桌面与移动端真实鉴权流程、构建产物核验。
- [ ] 取得真实数据迁移/写入冻结/切流授权，冻结写入、最终增量、对账、切流；在已定义窗口保留可执行的回滚路径。
- [ ] 仅当以上通过，才能在单独评审中解除 investment workflow 的 production guard；不得提前删除保护代码。

回滚前先冻结新写入、记录切换后的增量，不能直接恢复旧 SQLite 而丢失新用户的编辑。若需要回退前端/API，须与兼容的 schema/data 版本绑定。恢复与切流按 [RDS PITR 文档](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_PIT.html) 和 [EB HTTPS 文档](https://docs.aws.amazon.com/elasticbeanstalk/latest/dg/configuring-https.html) 实施。
