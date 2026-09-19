#!/usr/bin/env python3
"""Exact bilingual editorial of the remaining 19-field shared-money-range run.

English remains unchanged. Source ambiguities are separately recorded, never
silently transformed into guidance or an independently verified financial fact.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import sys

SPEC = importlib.util.spec_from_file_location("money19_editorial_base", Path(__file__).with_name("review-prior-qa-currency33-editorial.py"))
BASE = importlib.util.module_from_spec(SPEC); sys.modules[SPEC.name] = BASE; SPEC.loader.exec_module(BASE)
EDITS = [
 ("Charles Meyers — CEO and President, Equinix:", [
  ("董事长兼首席执行官", "首席执行官兼总裁"),
  ("可重复收入", "经常性收入"), ("MRR（月度收入）", "MRR（月度经常性收入）"),
  ("MRR（每月收入）", "MRR（月度经常性收入）"), ("每辆车的MRR", "每台机柜的MRR")],
  "CEO/president is not chairman; cabs means data-center cabinets, not vehicles. Retain recurring in MRR while flagging, not fixing, the original monthly/per-day contradiction."),
 ("Mike Dastoor — CFO, Jabil: Hey, Ruplu.", [
  ("我在报告里说AI 21 x，所以我确实已经计入了", "我在报告里提到AI共 21 x（次），我是数过的"),
  ("我们正从传统网络业务转向或替代这些与AI相关的业务", "我们正将传统网络业务转向AI相关业务，或以AI相关业务替代传统业务"),
  ("未来，即使在两年内", "再往后，即使看一两年之后")],
  "21 x counts spoken AI mentions, not a valuation multiple or financial inclusion. Retain replacement direction and the one-to-two-year outlook rather than an imposed deadline."),
 ("Kenneth Wilson — CEO, Jabil:", [
  ("回购跑率", "回购节奏"), ("WASO将约为110-113百万 FY 2025", "FY 2025的加权平均流通股数（WASO）将约为110-113百万股"),
  ("实现10.65美元所需的增量收入", "实现10.65美元每股收益所需的增量利润"),
  ("为增量收入", "为增量利润"),
  ("增量收入，净收入，我还要补充说明，同样如此。 扣除任何寄售影响的净额FY 2025已呈现", "增量营收；这里的净营收是指扣除FY 2025可能出现的寄售计量影响后的金额"),
  ("假设一个10%", "假设汽车业务增长10%"),
  ("汽车业务的利润率会显著低于10%", "汽车业务增速会显著低于10%"),
  ("1.2 亿美元的增量收入", "1.2 亿美元的增量利润"), ("用于支撑每单位的10.65美元", "用于支撑10.65美元的每股收益"),
  ("而且我是在说半导体，顺便说一下，半导体业务正显示出强劲的复苏迹象，【semicap】正在呈现非常强劲的复苏信号。 它【在这里】没有", "再看半导体设备业务，顺便说一下，该领域正显示出将要复苏的强烈迹象，尽管复苏尚未到来"),
  ("稳如老狗", "表现稳定"), ("所谈的收入增长 1.3 亿美元至1.4 亿美元", "所谈的增量利润 1.3 亿美元至1.4 亿美元"),
  ("你还将看到我们全年成本优化举措带来的全面影响 FY 2024", "你还将看到我们在 FY 2024 实施的成本优化举措所带来的全年效果")],
  "Income needed for EPS is incremental profit, not revenue; preserve revenue only for the $1-$1.5bn and $2bn sales bridge. WASO is shares, automotive 10% is growth, semicap is semiconductor equipment, and FY2024 actions yield a later full-year effect."),
 ("what assumptions are you making on NVIDIA content per GW", [
  ("每兆瓦", "每吉瓦"), ("在数据中心方面，由 2030 驱动", "截至 2030 年的数据中心支出规模")],
  "GW is gigawatts, not megawatts; by 2030 is a date horizon, not a growth driver. Do not infer the unscaled $30 across an or connector."),
 ("What was the AI revenue in July?", [
  ("可能会上升到 1 亿美元至1.25 亿美元 Q1Q", "可能会增加 1 亿美元至1.25 亿美元（原文为 Q1Q）")],
  "Tick up by is an increment, not the ending revenue level. Preserve the source's unusual Q1Q label without claiming a validated fiscal comparison."),
 ("Are you still getting the same win rate", [
  ("胜率", "中标率"), ("每兆瓦 300 万美元至350 万美元 的内容密度", "每兆瓦 300 万美元至350 万美元 的配套产品价值量")],
  "Win rate concerns project awards; content per MW is dollar product content, not power density."),
 ("Steve Demetriou — Chair and CEO, Jacobs:", [
  ("在高 3000 亿美元", "在三千多亿美元区间的高端（以 3000 亿美元为起点）"),
  ("我们看到在雅各布斯的覆盖范围中，大约在 85% 以上，我们目前能够看到的部分。我们尚未获得 100% 的内容", "根据目前能够拆解的法案内容，雅各布斯业务可覆盖的范围约为 85% 以上。我们尚未完成对 100% 内容的分析")],
  "High-$300bn means the upper three-hundred-billion range. Coverage is addressable opportunity, not awarded contracts or secured funding."),
 ("Chuck Robbins — Chair and CEO, Cisco:", [
  ("都存在与去年同期相比的巨大差异", "都面临较高的去年同期比较基数"),
  ("我们的营收环比略低于历史季度区间范围，大约为 1%", "环比表现略低于历史季度区间，差距大约为 1%"),
  ("上层 20s%", "20s% 的高端（百分之二十几的高端）"),
  ("订单连续性", "订单在季度内的分布节奏"), ("可重复收入", "经常性收入")],
  "Avoid inventing revenue as the unqualified metric. Preserve gap versus growth, high-twenties magnitude and intra-quarter order linearity."),
 ("Dave Regnery — Chair and CEO, Trane Technologies:", [
  ("我认为我们有，我认为是九个的14垂直领域实现了正增长", "我认为我们追踪的14个垂直行业中有九个实现了正增长"),
  ("提醒大家 rằng95%我们的账户经理或销售团队并不接触数据中心", "提醒大家，95%以上的客户经理或销售人员并不负责拜访数据中心客户"),
  ("克里斯·库恩——特瑞纳技术公司首席财务官", "克里斯·库恩——特瑞纳技术公司执行副总裁兼首席财务官"),
  ("积压订单的增长在1st本季度是", "第一季度（1st quarter）的积压订单增量是"),
  ("10 亿美元针对Stellar Energy", "10 亿美元来自Stellar Energy"),
  ("我们通常看到±2 亿美元关于过去几年每个季度的积压订单。季度内积压订单表现非常强劲，订单持续保持强劲态势", "过去几年每个季度的积压订单变动通常约为±2 亿美元。目前订单及积压订单的增长势头非常强劲，潜在项目储备也依然强劲")],
  "Remove a foreign-language artifact, retain more-than qualification and EVP, distinguish first quarter, acquisition contribution, quarterly backlog change and pipeline."),
 ("Mike Dastoor — CFO, Jabil: No, absolutely, Steve.", [
  ("交易关闭后立即启动", "移动业务交易完成且全部现金到账后立即启动"),
  ("回购数量将在 126 至 128 万之间", "[VASO]所指的股数预计在 126 至 128 百万股之间")],
  "126-128 million shares is a share-count measure, not 1.26-1.28m or shares repurchased. Retain the cash-receipt condition; source's final 2024/FY2025 wording remains flagged."),
 ("where you talked about, you know, growth accelerating", [
  ("你本季度的营收远高于正常季节性水平在 Q2", "你们在 Q2 的表现远高于正常季节性水平"),
  ("从 Q3 到 Q2 的需求回流", "把 Q3 的需求提前到 Q2"),
  ("我们是否应该期待在 50 亿美元至70 亿美元 时看到AI服务器的交付", "我们是否应该预期AI服务器交付额达到 50 亿美元至70 亿美元"),
  ("明年看到传统服务器需求的大幅增长", "明年看到非常大的服务器业务规模")],
  "Pull-in is timing acceleration; the range is delivery dollars, not a time. Do not narrow the final all-server question to traditional-server demand."),
 ("Adam Norwitt — President and CEO, Amphenol:", [
  ("阿姆芬ol", "安费诺"),
  ("我们的汽车业务规模是 5%，整体销售额为 6.6 亿美元，那季度的销售额是 3300 万美元至3500 万美元", "汽车业务占公司销售额的 5%，当季公司整体销售额为 6.6 亿美元，因此汽车业务销售额约为 3300 万美元至3500 万美元"),
  ("本季度的汽车业务销售额已接近 32 亿美元", "本季度公司的总销售额已接近 32 亿美元"),
  ("这些技术将如何融入 2024", "这样的业务表现进入 2024 后会如何发展")],
  "Restore revenue ownership: $3.2bn is company sales; automotive is 23%. The earlier $33-$35m is the automotive portion, not total sales."),
 ("Jayshree Ullal — Chairperson and CEO, Arista Networks:", [
  ("中个位数的年复合增长率，也一直相信个位数以上的增长", "十几个百分点中段的年复合增长率，也一直相信两位数增长"),
  ("新的客户标签", "新客户"),
  ("该客户是第五个主权AI客户", "第五个客户是主权AI客户"),
  ("但我们仍然相信实现了 7.5 亿美元 的后端目标收入，并且全年收入超过了 15 亿美元", "但我们仍然相信能够实现 7.5 亿美元 的后端收入目标，并且全年相关收入超过 15 亿美元")],
  "Mid-teens and double-digits are not single digits; the fifth customer is sovereign AI, not the fifth sovereign-AI customer. Preserve forecast versus already delivered results."),
 ("Chris Boerner — Board Chair and CEO, Bristol Myers Squibb:", [
  ("布里斯托-迈尔斯-西比尔", "百时美施贵宝"), ("布里特·迈尔斯·斯奎布", "百时美施贵宝"),
  ("勃林格殷格翰", "百时美施贵宝"), ("布鲁塞尔梅里尔-斯奎布公司副总裁兼首席财务官", "百时美施贵宝执行副总裁兼首席财务官"),
  ("埃利quis", "Eliquis"), ("艾利奎斯", "Eliquis"),
  ("自2024年1月1起", "自一月1日起"), ("去年八月2024", "2024年八月"),
  ("40%WAC", "40% 的WAC"),
  ("所以 hopefully，这应该有帮助", "希望这些说明有所帮助"), ("operator，我们可以请下一个问题吗", "接线员，请接入下一个问题")],
  "Preserve issuer identity instead of inventing Boehringer Ingelheim and inconsistent issuer names. Remove invented year/month digits; retain the source's dated August reference and EVP."),
 ("Keith Taylor — CFO, Equinix:", [
  ("尽管有关账单柜的评论存在，但你们知道，我们并不会像过去那样通过价格和销量的增长来推动收入增长，如果不能创造价值，就无法实现收入增长。而我们过去几个季度的收入增长，是远超 4000 万美元 的，按季度环比来看。在没有创造价值的情况下，这种增长是不可持续的", "尽管刚才讨论了可计费机柜数量，但如果我们没有创造价值，就不可能实现超过 4000 万美元的季度环比营收增长；这些增长来自价格、销量以及我们开展的各项工作"),
  ("可重复收入", "经常性收入"),
  ("3000 万美元 的订单", "3000 万美元 的贡献"),
  ("在指引中值，可重复收入为 7300 万美元", "再次强调，指引中值对应的总营收环比增量为 7300 万美元"),
  ("在指引中值，经常性收入为 7300 万美元", "再次强调，指引中值对应的总营收环比增量为 7300 万美元"),
  ("企业级房地产", "公司办公房地产"), ("转入上一季度", "转入本年最后一个季度"),
  ("可重复资本支出", "经常性资本支出"), ("实际现金流", "收入向盈利的传导表现")],
  "Restore price/volume growth causality and total incremental $73m, not recurring revenue level. xScale is nonrecurring-revenue contribution, costs are accelerated into the year's final quarter; flow-through is not explicitly cash flow."),
 ("Brian Robins — CFO, Snowflake Inc.:", [
  ("消费模式", "按用量付费的模式"), ("美国钢架雪车团队", "美国有舵雪车队"),
  ("他们在手机上使用Snowflake Intelligence的情况", "在我的手机上使用Snowflake Intelligence的情况")],
  "Bobsled is not skeleton; preserve whose phone the source names without repairing the source's awkward speaker/subject wording. Consumption means usage-based billing."),
 ("David Fallon — CFO, Vertiv:", [
  ("大家自然会有这样的期待", "自然也会相应传导到现金流表现"),
  ("指导中假设的", "指引中假设的")],
  "Retain EBITDA flow-through, distinguish guidance from instruction, and leave $1m/$200m and unscaled $350 source issues uncorrected and flagged."),
 ("Jeremy Knop — CFO, EQT:", [
  ("今年预算中包含的许多项目", "今年预算中包含的约一半项目"),
  ("将成为最大的资本支出项目", "可能是最大的资本支出项目"),
  ("的调整后自由现金流", "的自由现金流"), ("也不再追逐价格波动", "也不是追逐价格波动")],
  "Preserve roughly half and probably, do not relabel pre-growth-capex FCF as adjusted FCF, and avoid implying the company previously chased prices. Unscaled next $500 stays flagged."),
 ("Mark Mondello — Chairman and CEO, Jabil:", [
  ("将自然从云业务中流出", "将从云业务的营收计量中剔除"),
  ("从 FY 2022 增长到 FY 2023", "从 FY 2022 到 FY 2023"),
  ("云业务中， 5G 无线部分", "云与 5G 无线业务"), ("而到 5G 无线部分", "而云与 5G 无线业务到")],
  "Consignment reduces recognized pass-through material revenue, not physical cash outflow; cloud/5G is the combined business and a decline is not growth."),
]

SOURCE_WARNINGS = {
 "what assumptions are you making on NVIDIA content per GW": {"category": "unscaled_amount", "detail": "Source says '$30 or $40 billion'; $30 has no explicit scale and the or connector is not a validated shared-range token. Original GW and later $3-$4 trillion must be retained."},
 "What was the AI revenue in July?": {"category": "ambiguous_period_label", "detail": "Source Q1Q is unusual/possibly a transcription error; preserve it, do not treat as validated quarter-on-quarter guidance."},
 "Charles Meyers — CEO and President, Equinix:": {"category": "source_internal_inconsistency", "detail": "Source says MRR (monthly recurring revenue) run rate '$667 million a day'. Monthly versus per-day time units conflict. Do not annualize this transcript figure or silently remove a day."},
 "Mike Dastoor — CFO, Jabil: No, absolutely, Steve.": {"category": "source_internal_inconsistency", "detail": "Final source sentence says end of 2024 126-128m shares, then 'while in 2024' while managing through FY2025 for 115-118. The fiscal timing is internally inconsistent; do not repair 2024 into 2025."},
 "David Fallon — CFO, Vertiv:": {"category": "ambiguous_amount", "detail": "Source juxtaposes a '$1 million or $200 million' headwind and unscaled '$350'. Preserve both; no inferred $100m or $350m financial input is authorized."},
 "Jeremy Knop — CFO, EQT:": {"category": "unscaled_amount", "detail": "Source gives next '$500' without an explicit scale, after separately scaled ranges. Do not silently turn it into $500m."},
 "Brian Robins — CFO, Snowflake Inc.": {"category": "ambiguous_speaker_subject", "detail": "Source says they show Snowflake Intelligence 'on my phone'. Preserve phone ownership without silently changing the speaker or which party performs the demo."},
}


def review(cache, audit):
    if len(cache) != 19 or len(audit.get("sources", {})) != 19:
        raise ValueError("Exactly the 19-field remaining queue is required")
    by_source = {}
    for prefix, edits, reason in EDITS:
        matches = [s for s in cache if s.startswith(prefix)]
        if len(matches) != 1: raise ValueError(f"Expected unique source prefix: {prefix}")
        by_source[matches[0]] = edits, reason
    corrections, notes = [], []
    for source, original in cache.items():
        target = original
        edits, reason = by_source.get(source, ([], "Exact-source bilingual review; no substantive change needed."))
        for before, after in edits:
            # The two alternate $73m phrasings above are mutually exclusive
            # before/after the terminology edit; all other edits are exact-bound.
            if before not in target:
                if before.startswith("在指引中值，") and "7300 万美元" in before: continue
                raise ValueError(f"Expected exact target wording changed: {before}")
            target = target.replace(before, after)
        target = BASE.normalize_range_representation(source, target)
        warnings = [v for prefix, v in SOURCE_WARNINGS.items() if source.startswith(prefix)]
        notes.append({"sourceSha256": BASE.BASE.sha(source), "sourceWarnings": warnings,
                      "reviewScope": "exact_19_source_bilingual_editorial_not_source_factual_attestation"})
        # Even no-edit sources must pass an actual final-target count check.
        try:
            protected = BASE.BASE.protect_edited(source, target)
        except ValueError as error:
            raise ValueError(f"{source[:100]}: {error}") from error
        if target != original:
            corrections.append({"sourceSha256": BASE.BASE.sha(source), "originalTranslationSha256": BASE.BASE.sha(original),
                                "protectedTranslation": protected, "reason": reason})
    manifest = {"reviewer": "Codex exact-source bilingual editorial review, not a human review claim",
                "reviewedAt": "2026-09-06", "corrections": corrections}
    output, report = BASE.BASE.EDITOR.apply_review(cache, audit, manifest)
    report["exactSourceReview"] = {"sourceCount": 19, "sources": notes, "sourceWarningsAreNotCorrectedFacts": True}
    report["editorialNumericGuardVersion"] = BASE.ENGINE.NUMERIC_PROTECTION_VERSION
    return output, report, manifest


def main():
    p = argparse.ArgumentParser(description=__doc__)
    for name in ("cache", "audit", "output"): p.add_argument("--" + name, required=True, type=Path)
    args = p.parse_args(); cb, ab = args.cache.read_bytes(), args.audit.read_bytes()
    output, report, manifest = review(json.loads(cb), json.loads(ab))
    report["editorialReview"]["priorCacheFileSha256"] = hashlib.sha256(cb).hexdigest()
    report["editorialReview"]["priorAuditFileSha256"] = hashlib.sha256(ab).hexdigest()
    args.output.mkdir(parents=True, exist_ok=False)
    for name, value in (("cache.json", output), ("audit.json", report), ("editorial-manifest.json", manifest)):
        with (args.output / name).open("x") as h: h.write(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    print(json.dumps({"sourceCount": 19, "editedSourceCount": len(manifest["corrections"]), "statusCounts": report["statusCounts"]}))


if __name__ == "__main__": main()
