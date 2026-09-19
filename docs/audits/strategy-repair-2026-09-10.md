# Strategies 回测与头像回归修复 — 2026-09-10

## 范围与结论

仅修复本地预览；没有部署 AWS、提交 Git 或修改主 runtime 数据库。复现配置：Bill Ackman、Li Lu、Warren Buffett；Top 5；估值溢价上限 30%；剔除后重新分配；KMLM 30%；杠杆 1×；交易成本 10 bps；请求区间 2021-08-28 至 2026-08-28。

修复后此配置 `ready`，有效交易区间 2021-08-30 至 2026-08-28，1,255 个真实日观察值、26 次披露后调仓、最低执行价格覆盖率 100%。起点顺延至周一是交易日对齐，并未截短五年样本以规避错误。

## 原因

1. 本地 launcher 已切换到结构化策略库，但旧持仓提取缺少原始证券类别核验。严格 reader 正确报出 `filing_classification_unverified`，首先命中 Ackman 的起始申报。不是 CTA 或用户配置错误。
2. 结构化 catalog 返回管理人时遗漏 `avatar` 字段；前端收到空 URL 后退回首字母。已有 PNG 资源并未消失。

## 修复

- 为截图中三位管理人恢复 2021 Q2 至 2026 Q2 的 63 个季度原始 SEC 信息表，并核对封面 CIK、报告期、表格类型、行数与合计。
- 按证券类别区分普通股、期权和债务；重复 CUSIP 合并后再选 Top N。合并申报按各原始组成部分保留来源。
- Li Lu 2026 Q2 的 8 行美元整数金额与封面总额相差 1 美元。记录原值与舍入残差；仅允许按独立整数舍入推导的有限误差 `(行数 + 1) / 2`，不改源金额、不放宽执行覆盖门槛。明显不符仍被测试拦截。
- 生成独立新 warehouse，通过完整性、外键和逐表指纹检查后才切换本地服务。保留旧库可回退。
- Catalog 恢复 canonical avatar URL；前端同时支持 `avatarUrl`、`avatar`，并在字段缺失时按合法 Guru ID 查找现有头像。刷新头像资源版本标识。
- 数据校验失败提示现在显示具体管理人姓名、报告期及证券类别/身份问题，而不只显示泛化错误和 slug。

## 本地数据与可复现文件

- 主源（只读）：`output/investment-workflow-20260908/runtime.sqlite`
- 原策略库（保留）：`output/strategy-store-20260910/strategy-current.sqlite`
- 新策略库：`output/strategy-repair-20260910-final/strategy.sqlite`
- 新 generation：`37295a08fe5d9a3283bfcc4bdd0a6ccbcd4712b6fea925731596635324d8cc76`
- 来源恢复：`scripts/recover-strategy-books.mjs`；证据目录 `output/strategy-repair-20260910` 和 `output/strategy-repair-20260910-final`。
- 13 组真实数据检查：`scripts/verify-strategy-repair.mjs`，结果为新证据目录中的 `verification.json`；完整截图配置结果为 `verification.screenshot.json`。
- 本地前端 build：`output/strategy-repair-preview-20260910`；localhost:5186；API localhost:8789。

原始信息表行数 2,345 → 5,026，持仓行数 10,958 → 11,546。只有申报、源文档、持仓解析/映射和相应覆盖问题表的指纹变化；价格、财务、指引、估值模型表指纹均未改变。源库写入计数为 0。

## 验证

- 后端恢复、数据库、策略、杠杆、路由：61/61。
- Flutter 全量：440/440；静态分析无问题。
- 静态性能契约：41/41；双语审计通过；release web build 成功。
- 38 个现有 Guru 头像均存在于新 build，尺寸 144×144。
- 13 组真实数据回测均 ready：原配置、Top 1/3/10、三位管理人分别单独运行、15% 溢价、DBMF 50%、无过滤/无 CTA、1.5× 杠杆与 4% 融资、1Y、3Y。
- 每次调仓验证权重合计、申报公开日早于执行日、估值可用日不晚于决策日。Top 10 的最低执行覆盖为 95%，其余这些组合为 100%；90% 门槛未改变。
- 本地实际 HTTP POST 返回 200 / ready；实际 UI 选择三位管理人并运行五年，出现四条比较曲线与 1,255 个日观察值；真实头像已在选择器及已选 chips 渲染。
- 浏览器验证了 1600×1000 桌面及 390×844 手机布局，中文切换后保留组合与完整回测结果，控制台没有 error/warn；结束时恢复英文与浏览器默认尺寸。实拍证据为新证据目录中的 `desktop-chart.png` 和 `mobile-avatars-zh.png`。

## 仍需诚实展示的限制

原配置部分季度估值覆盖最低 50%；缺估值份额保留现金。不能把现金较多导致的低回撤说成估值过滤有效，也不能宣称估值全覆盖。页面保留覆盖提示。

本轮核验针对这三位管理人的上述历史区间，不代表全部 Guru、所有历史申报均已恢复；其他未经核验的配置继续显式拦截。此次是独立策略输入恢复，不是主库 13F 全量更新或对线上历史数据的发布。
