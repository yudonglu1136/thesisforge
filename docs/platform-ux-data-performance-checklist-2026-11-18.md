# ThesisForge 全平台用户体验、IBKR 自助连接、多端语言记忆、数据合理性与性能审计总清单（2026-11-18）

本清单覆盖三大核心交付：
1. **用户端 IBKR 自助连接与多账户容错修复（M1）**：解决为什么没有自动网页 OAuth 弹窗的说明与一键跳转引导、修复旧失效账户（如 `1200...`）连坐阻断新有效 `Yodlee` 账户（如 `1712970`）验证的 Bug、修复更新 Token 时产生重复孤儿账户的问题，并在前端展示精确到错误码的中文诊断与一键清理失效账户能力。
2. **跨浏览器 / 跨设备用户级语言习惯持久化（M2）**：实现「浏览器 `localStorage` + `tf_lang` Cookie + 登录账户加密偏好库（`/api/user/preferences`）」三层联动，做到「是中文下次进来就是中文，是英文一直都是英文」，并在桌面顶部栏与移动端顶部栏提供显眼的一键 `中文 / EN` 切换。
3. **全平台数据合理性、视觉交互易用性与前后端性能彻底优化（M3–M5）**：逐项修复审计发现的数值前后矛盾、财季部分披露误导、导航返回错位、策略实验室空状态卡死、移动端表格挤压、多 MB 冗余传输与 60fps 图表悬停重绘抖动，全部打勾验证并同步部署至 AWS Elastic Beanstalk 与 Vercel。

---

## M1 · 用户端 IBKR 连接流程与多账户验证修复（必须完成用户端闭环）
- [x] **M1.1 明确解释无 OAuth 弹窗原因 + 提供一键打开 IBKR 第三方服务页与三步指引**：在 `PortfolioAddAccountDialog`、`PortfolioConnectionPanel`、`PortfolioConnectionStatusPanel` 与 `PortfolioIbkrSetup` 中清晰说明 IBKR 不向独立研究终端开放零售网页 OAuth 弹窗，而是通过官方只读 `Third-Party Services -> Yodlee` 模板签发零交易权限的 Flex Token + Query ID；增加一键跳转 IBKR Portal 按钮，并明确提示页面下方显示 `There are no active third-party data feeds` 属于正常现象。
- [x] **M1.2 修复同 `Query ID` 更新 Token 时生成新 `account.id` 导致旧失效凭证残留的 Bug**：在 `server/userPortfolioStore.js` 的 `addPortfolioAccount` 中按 `id`、`replaceAccountId` 或相同 `ibkrFlexQueryId` 原地更新账户，并支持 `replaceFailedAccounts` 一键替换旧失效账户，杜绝旧失效 Token 留在列表中污染后续同步。
- [x] **M1.3 修复旧失效账户（如 `1200...`）连坐阻断新有效账户（如 `1712970`）验证与持仓入库的 Bug**：在 `server/portfolioClient.js` 与 `POST /api/portfolio/accounts` 中记录逐账户验证结果（`accountSyncResults` / `verifiedAccount`）；当新提交账户本身通过 IBKR 验证时，即使存在历史失效旧账户也保留新账户真实持仓（`linked_partial`）并明确返回 `verifiedAccount.ok = true` 与失效旧账户 ID，允许用户一键清理旧失效账户或自动替换。
- [x] **M1.4 优化 IBKR Flex `SendRequest` / `GetStatement` 重试与冗余历史查询保护**：在 `server/portfolioClient.js` 中对 IBKR `Error 1018`（频率限制）与 `Error 1019`（首次启用 Yodlee 报告正在生成）进行完整重试；当主查询 XML 已内置多日净值与现金流水（Yodlee 默认模板常见情况）时跳过紧接其后的第二次 `p=365` 请求，避免触发同 Token 连续请求限流。
- [x] **M1.5 前端透传精确 IBKR 诊断原因与逐账户健康徽章**：修复前端把所有非 `linked` 状态统一覆盖成笼统「验证没有完成」的问题，精确翻译并展示 IBKR 返回的错误码（`1012` Token 过期、`1015` Token 无效、`1018/1019` 报告生成中、Query ID 不匹配、IP 限制等），并在账户卡片上显示 `已验证 / 同步失败` 徽章与醒目的「移除此失效账户」按钮。

## M2 · 每个用户语言习惯跨会话 / 跨设备持久化
- [x] **M2.1 后端用户偏好存储与接口（`GET / POST /api/user/preferences`）**：在 `server/userPortfolioStore.js` 每用户独立 SQLite 中新增 `user_preferences` 表（持久化 `language` 与 `colorBlind`），在 `server/index.js` 暴露鉴权读写接口并纳入 `/api/user` 隐私 `no-store` 头保护。
- [x] **M2.2 浏览器端 `localStorage` + `tf_lang` Cookie + HTML 首屏 `lang` 同步**：升级 `lib/browser_location_web.dart` 与 `web/index.html`，同时读写 `localStorage['thesisforge.language.v1']` 与 1 年期 `SameSite=Lax` Cookie `tf_lang`，并在 OAuth 登录跳转（`signInWithOAuth`）中保留当前语言参数。
- [x] **M2.3 登录态自动拉取与双向同步用户语言习惯**：在 `AuthGate` / `_GuruTerminalAppState` 中，用户登录后自动拉取 `/api/user/preferences`：若账号已保存语言习惯且当前 URL 未显式强制 `?lang=`，立即切到该用户的中文或英文习惯；若用户在任意端切换 `中文 / EN`，同步写入本地与后端账号库。
- [x] **M2.4 桌面端顶部工具栏与移动端顶部栏一键 `中文 / EN` 显式切换**：在 `lib/investment_graphite.dart` 桌面右上工具区（`As of` 控件旁）与移动端顶部栏提供清晰的 `中文 / EN` 胶囊按钮，无需翻找底部或弹窗。

## M3 · 全平台数据与金融逻辑合理性修复
- [x] **M3.1 修复 `QQQ ⇄ SCHD` 轮动雷达顶部实时指标与下方诊断文字前后矛盾**：在 `server/qqqSchdRotationStrategy.js` 与 `server/config/qqq-schd-rotation-dashboard.json` 中基于当前 `liveRadar` 标量动态生成 `actionInstruction`、`scissorsDiagnostic` 与 `nextTriggers.conditions[*]`（消除顶部显示 `\$656.95 / -13.52% / RSI 31.6` 而下方仍写 `\$679.89 / -10.5% / RSI 42.8` 的割裂）。
- [x] **M3.2 修复 `Breakout Pullback` 策略徽章硬编码倍数偏差**：将 `lib/investment_breakout_pullback.dart` 中硬编码的 `8.91x` / `7.54x` 改为优先读取实时 `_modeMultipleText`（保留测试兜底值）。
- [x] **M3.3 修复 `AI 洞察` `2026Q3` 跨财季部分披露（`32/50` 已披露、`NVDA/CRM/CRWD/SNOW` 等 10 月末财季未出季报）造成的误读**：在 `lib/investment_ai_insights.dart` 增加「当前财季披露进行中（32/50 已披露）」提示条与一键切换至最近完整披露季度（`2026Q2` `50/50`）按钮，并在公司排名表未披露行标注 `待披露（跨月财季）` 而非空白 `—`。
- [x] **M3.4 增强 `13F 洞察` 最新季度样本覆盖说明**：在 `lib/investment_13f_insights.dart` 对季度持仓变动脉冲补充可比申报机构覆盖口径提示，避免把单季申报样本切换误读为全市场清仓。

## M4 · 视觉合理性与「一眼看懂怎么用」交互升级
- [x] **M4.1 `AI 洞察` 行业热力图对齐修复与图例说明**：在 `lib/investment_ai_insights.dart` 修复左侧行业列与右侧季度矩阵 `12px` 高度错位、保持季度表头清晰对齐，并在矩阵上方补充紧凑三要素图例（顶行增速 · 中间最大正贡献龙头 · 底行拉动百分点 `pp`）。
- [x] **M4.2 修复跨模块进入「公司研究」后的返回路径错乱**：在 `lib/investment_graphite.dart`、`lib/investment_desk.dart` 与 `lib/investment_workspace_pages.dart` 记录真实来源页面（首页 / 组合 / 策略 / 发现），点击顶部返回面包屑准确回到原页面而非一律跳去「发现」。
- [x] **M4.3 修复「策略实验室 · 自由组合构建器」空状态禁用与整卡误触**：在 `lib/investment_strategy_lab.dart` 增加一键快速预设模板（巴菲特核心、多大师均衡、大师 + 股息防守）、明确显示「已选 N 位大师（至少选 1 位）」提示、拉开底部双按钮 `8px` 间距，并移除包裹滑块/开关的外层整卡 `InkWell`。
- [x] **M4.4 修复 `13F 洞察` 移动端 `390px` 五列挤压与桌面数字右对齐**：在 `lib/investment_13f_insights.dart` 对窄屏切换为清晰双行卡片布局，桌面端数值列统一右对齐 + `tabularFigures`。
- [x] **M4.5 消除反向 DCF、三表复选框、专业术语缩写与原始 JSON 困惑**：在估值页为 `outside_bounds` 提供通俗解释并支持点击「当前股价隐含什么假设？」直达反向 DCF；将财务三表左侧易被误认为批量勾选的 `Checkbox` 改为趋势图联动图标；为 `Pos-PE / Scissors / Ulcer / Calmar / WACC / PIT` 增加悬停/点击释义 `Tooltip`；为基本面筛选器输入框标注 `% / x` 单位；将工作流底层原始 JSON 收起至高级审计折叠区；修复移动端固定宽度指标卡参差、深色硬编码底色与负收益语义色。

## M5 · 前后端性能优化与全量验证上线
- [x] **M5.1 修复 `InvestmentSource.companyCache` 与大师详情缓存自清空 Bug**：在 `server/investmentSource.js` 与 `server/investmentGuruProfile.js` 中移除按单次请求标的变化的 `marketFactsVersion` 全局代际键，避免跨标的查询命中率归零。
- [x] **M5.2 优化 `/api/investment/fundamentals` 与 `PublicAnalysisArtifacts` 暖请求 CPU（`78ms -> <2ms`）**：在 `server/publicAnalysisArtifact.js` 对 `active.json` 做短周期 `stat` 缓存并支持 `{ clone: false }` 只读读取，在 `server/fundamentalResearch.js` 使用 `WeakMap` 复用全市场预评分缓存。
- [x] **M5.3 消除策略页多 MB 无用字段传输与重复计算**：为 `/api/investment/qqq-schd-rotation/analysis` 增加 `?includeCurve=0`（省去前端不读取的 `1.29MB` 逐日曲线）、为 `/api/investment/breakout-pullback/analysis` 增加 `?includeTrades=0`、为 `/api/investment/investor-styles` 增加切片缓存与 `?summaryOnly=1`（省去策略入口预取 `2.70MB` 全量包）、在 `server/rulePortfolioAnalysis.js` 用 `WeakMap` 缓存 `hydrateRuleLedger`、并在 `server/investmentAiInsights.js` 前置 `snapshotId` 缓存命中判断。
- [x] **M5.4 优化 Flutter 60fps 图表悬停局部重绘与图片解码内存**：修复 `_AiInsightsChartPainter.shouldRepaint` 恒返回 `true` 的问题，为高频悬停图表补充 `RepaintBoundary` 与同索引去重判断，为 `StockLogo` 与 `GuruAvatar` 补充 `cacheWidth / cacheHeight`，并将 `web/index.html` 加载图标替换为轻量 `favicon.png`。
- [x] **M5.5 全量自动化测试回归（i18n 审计 + Flutter 静态分析 + 685+ 单元测试 + Node 全套后端测试）**：新增覆盖 M1（IBKR 多账户/验证/去重）与 M2（用户语言偏好持久化）的自动化测试，确保全部 0 报错通过。
- [x] **M5.6 Git 提交推送 `origin/trunk` + AWS Elastic Beanstalk 与 Vercel 双端生产部署验证**：确认 AWS EB `thesisforge-api-prod` 处于 `Ready / Green`，Vercel `thesisforge.tech` 与 `www.thesisforge.tech` 指向同一最新 `● Ready` 部署。
