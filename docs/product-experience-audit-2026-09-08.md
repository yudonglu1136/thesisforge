# ThesisForge 产品流程审计

日期：2026-09-08。结论：当前是有可用计算与持久化基础的本地纵向切片，不是完成的产品改版。

## 范围与证据边界

本轮重读用户原始 27 节 guideline，逐步打开当前 5184 预览、原 Guru 工作区和公开 ISRG 案例，接受下列 11 张本轮截图。研究截止日先为 2026-06-01，再切至 2026-08-28 观察已保存的 ISRG 复核。所有截图保存后均打开核验。预览是隔离本地数据，不能据此宣称线上版本质量或全量数据审计通过。

没有提交决策、策略或复核，没有改动生产系统。原 Guru 页面自身显示缓存重验提示；浏览器访问可能刷新隔离库缓存，因此不声称整个本地数据库零写入。未验证注册/登录、管理员权限、真实券商对账、所有 Guru、所有财务模型、CTA 引擎或完整无障碍合规。

响应式截图尝试未在目标页生效，两个名为 12-mobile 的截图仍是桌面尺寸，已拒绝为手机证据。本报告不把它们算入已验收截图，也不把过去的移动测试当成本轮审计结果。

## 总体判断

可保留：PIT 日期/数据基础、已保存情景与不可变记录、DCF/反向计算、原 Guru 曲线/区间/持仓轨迹、统一 Logo。应重做：信息架构内的衔接、发现页、情景比较、决策表单、复盘对照、组合摘要，以及可读的来源抽屉。

最重要的不是颜色，而是三类断裂：**来源断裂、时点断裂、决策版本断裂**。同权重大卡片、过大的标题和微小正文又把这些问题放大。当前测试通过不等于用户能够理解并完成投资研究任务。

## 逐步审计

### 1. Home — 结构缺失

![Home，当前审计截图](/Users/yudonglu/Documents/guru-intelligence/output/product-audit-20260908/01-home.jpg)

- 已有优势：真实历史截止日、审查为空不造提醒、研究决策有入口。
- 问题：四块同权重满宽卡片、短文占据宽屏；不是注意力队列。历史时点隐蔽。持仓只有计数无可行动摘要。ticker按钮缺公司名和理由。
- 可用性/无障碍风险与边界：截图正文尺寸偏小；股票导航暴露为checkbox而非链接；图标legacy入口不直观。

### 2. Discover — 核心路径断开

![Discover，当前审计截图](/Users/yudonglu/Documents/guru-intelligence/output/product-audit-20260908/02-discover.jpg)

- 已有优势：筛选规则和排序披露清楚；不把13F说成动机。
- 问题：87个ticker芯片+29个follow开关替代发现页。Guru无头像/基金档案/季度/持仓/加减仓/曲线入口；Ontology缺席。过滤器不能编辑。
- 可用性/无障碍风险与边界：二维芯片视觉无稳定列；DOM为checkbox，跳页语义不符。

### 3. Research — 可读但有来源错误

![Research，当前审计截图](/Users/yudonglu/Documents/guru-intelligence/output/product-audit-20260908/03-research.jpg)

- 已有优势：真实曲线、股价与平台混合估值明确分列；PIT季度和公开日可见。
- 问题：从基本面入口却显示Ackman来源，代码硬选；首屏几乎被16年曲线占据，变化/异常/发现原因在屏外。图无可见区间/报告点查看控件。
- 可用性/无障碍风险与边界：较小图轴，细灰价格线；指标表DOMdisabledtextbox，读屏需要专项验证。

### 4. Valuation — 已有基础，决策解释不足

![Valuation，当前审计截图](/Users/yudonglu/Documents/guru-intelligence/output/product-audit-20260908/04-valuation.jpg)

- 已有优势：真实平台历史曲线和个人FCFE分列；简单输入。
- 问题：同屏313.54和178.02虽有标签但无口径差桥接；反推30.18%缺首屏期限和固定假设；Bear/Base/Bull只能切换而非对照。细节入口把另一套表单堆到下面。
- 可用性/无障碍风险与边界：输入与输出读取次序交错，图不提供可操作数据表；键盘读屏未完整验证。

### 5. Decision — 未完成的表单流程

![Decision，当前审计截图](/Users/yudonglu/Documents/guru-intelligence/output/product-audit-20260908/05-decision.jpg)

- 已有优势：不下单说明明确，无情景不能保存。
- 问题：默认Watch、重点观察、5%权重、15%规则预先选中，违背主动用户决策。没保存情景却展示完整表单再禁止提交。Watch仍展示目标仓位；规则与理由混杂无快照摘要。
- 可用性/无障碍风险与边界：全宽保存禁用，阻断原因远离按钮；选择应有radiogroup语义。

### 6. Portfolio — 只完成研究账本，不是完整组合

![Portfolio，当前审计截图](/Users/yudonglu/Documents/guru-intelligence/output/product-audit-20260908/06-portfolio.jpg)

- 已有优势：研究仓位和券商账户分开。
- 问题：仓位/日志重复占两张卡；无可行动的权重/估值/规则状态表。Shadow差异是全宽卡中小表；CTA unavailable另占卡。整体没有资产视角与研究视角切换。
- 可用性/无障碍风险与边界：表格semantic输出只有disabledtextboxes，待读屏核验；巨量无用空白增加滚动。

### 7. Review — 比较对象不够清楚

![Review，当前审计截图](/Users/yudonglu/Documents/guru-intelligence/output/product-audit-20260908/07-review.jpg)

- 已有优势：有Then/Now真实指标、不可变记录、Maintain/Change动作。
- 问题：原始v1 $165.21与新实际/最后确认v2 $151.66并列，易误作同假设变化；缺Δ列和清晰同版本基准选择。高权重内容只有左角小表。Maintain预选，操作区在屏外。
- 可用性/无障碍风险与边界：原始status review_required暴露；数值变化缺文字方向/单位差异；无完整键盘验证。

### 8. Strategies — 说明占位，非完整产品

![Strategies，当前审计截图](/Users/yudonglu/Documents/guru-intelligence/output/product-audit-20260908/08-strategies.jpg)

- 已有优势：披露预览不冒充可执行回测。
- 问题：主按钮保存用户尚未看见/选择的固定3个经理；没有策略配置/收益/风险/窗口控制。绝大部分页面为空，成熟回测藏在legacy入口。
- 可用性/无障碍风险与边界：选择输入完全缺失；保存规则虽可操作但上下文不足。

### 9. 原Guru工作区 — 核心能力存在，整合缺失

![原Guru工作区，当前审计截图](/Users/yudonglu/Documents/guru-intelligence/output/product-audit-20260908/09-legacy-guru.jpg)

- 已有优势：真实头像、原有回测曲线、5Y/10Y、自由区间、持仓、季度轨迹、MarketLens均存在。
- 问题：跳出新工作流后换整套导航、PIT日期丢失、原图至8/31而新页截止8/28；不能无提示当历史证据。三栏在1440经理头字段严重截断。
- 可用性/无障碍风险与边界：低高度信息密集，截断名字/字段要可展开；slider无描述性日期读数需专项验证。

### 10. Guru季度轨迹 — 可复用但需核验异常

![Guru季度轨迹，当前审计截图](/Users/yudonglu/Documents/guru-intelligence/output/product-audit-20260908/10-guru-history.jpg)

- 已有优势：40季度选择、股票轨迹、Top10覆盖边界说明存在。
- 问题：同屏Common-long value显示$0却有UBER$2.48B等持仓，应核查字段/数据绑定，不可当真实零。季度横向长条，选择股票与跳转估值动作紧邻，缺显式双动作。
- 可用性/无障碍风险与边界：小字号及截断，横向季度列表可发现性弱。

### 11. 公开ISRG案例 — 叙事较清楚，终端交接未审

![公开ISRG案例，当前审计截图](/Users/yudonglu/Documents/guru-intelligence/output/product-audit-20260908/11-public-case.jpg)

- 已有优势：免登录；问题、日期、价格/综合估值/差值、假设/变化/反例结构清晰；可借用其证据叙事。
- 问题：公开页更清楚，入终端后却变成另一套信息结构；文案显示终端要求登录，保存前匿名连续体验尚未落实。
- 可用性/无障碍风险与边界：有Skiplink和数据表语义；本次截取当前731×735首屏，完整登录/键盘未测试。

## 必须先处理的具体问题

| 优先级 | 问题 | 证据 | 修复验收 |
| --- | --- | --- | --- |
| P0 信任 | 基本面筛选进入 MSFT，却写成 Ackman 来源 | 步骤 2→3；investment_graphite.dart 按 Ackman 字串优先 | 入口来源逐字对应实际事件，其他 Guru 证据单列；直接搜索也不能自动认领 Guru 来源 |
| P0 信任 | 历史回放跳 legacy 后不保留截止日 | 步骤 8→9：从 8/28 进入显示到 8/31 的曲线 | 同一时点查询；无支持时明确告知退出历史模式，不混入历史决策快照 |
| P0 信任 | Common-long 显示 $0，与同页非零持仓冲突 | 步骤 10；main.dart 5933 使用 number(quarter['commonLongValue']) | 查明源字段与空值路径；无有效值显示缺失并解释，不能默认为零 |
| P1 主流程 | Discover 无 Guru 持仓研究入口 | 步骤 2 | Guru→季度→股票轨迹→Research 全链路，不退回两套导航 |
| P1 决策所有权 | Watch/Maintain、5%权重等预设 | 步骤 5、7 与变量初始化 | Watch/Pass/Invest 无预选；仓位必须主动填写；Maintain 一等操作但非暗中替用户决定 |
| P1 策略所有权 | 保存按钮写入固定经理名单 | 步骤 8；strategyView 请求固定三名经理 | 展示并允许选择规则，保存前确认完整经理集合/TopN/去重/权重/费用/时点 |
| P1 估值理解 | 平台综合估值与个人 DCF 无数值口径解释 | 步骤 4 | 明确模型类型、权重、归属、时点；不同方法不伪装同模型变化 |
| P1 复盘理解 | v1 原值与 v2 重算值构成混合基准 | 步骤 7 | 原快照与最后确认快照可切换；每次 Then/Now 对照用同一版本，修改假设另列 |
| P1 导航与状态 | 二级 tab 不持久在 URL；返回原筛选不明确 | 当前导航代码与走查 | ticker/section/cutoff/origin/quarter/filter 在刷新、返回、分享后可恢复；隐私内容不放 URL |
| P2 视觉 | 同权重卡片、窄小数据表、大面积无用空白 | 步骤 1、2、5—8 | 每页独立构图；列表/工作台/对照页使用不同容器；字号与操作区统一 |

P0/P1 是本轮产品风险优先级，不是一次完整安全或财务模型审计评级。

## 不能从这些截图得出的结论

不能把“公开案例读得明白”推成转化率已提升；不能把可见真实曲线推成所有经理覆盖完成；不能把画面无溢出推成键盘/读屏合规；不能把预测模型有计算输出推成经济假设已经合理。

下一份设计依据见 [完整逐页设计蓝图](/Users/yudonglu/Documents/guru-intelligence/docs/product-redesign-blueprint-2026-09-08.md)。
