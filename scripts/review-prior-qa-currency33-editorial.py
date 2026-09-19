#!/usr/bin/env python3
"""Source-bound editorial review of the 33-field suffix-repair Qwen batch.

The English source is immutable. Ambiguous source quantities are retained and
reported separately, not silently repaired with inferred millions or decimals.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import sys

SPEC = importlib.util.spec_from_file_location("currency33_editor", Path(__file__).with_name("review-prior-qa-guard21-editorial.py"))
BASE = importlib.util.module_from_spec(SPEC); sys.modules[SPEC.name] = BASE; SPEC.loader.exec_module(BASE)
ENGINE = BASE.ENGINE

EDITS = [
 ("Alex Karp — CEO, Palantir Technologies:", [
  ("你实际上是在支付20，有时多出百分之多少", "你实际上多支付了百分之20，有时甚至更多"),
  ("我 spent a lot of my life in Europe. Europe does not adapt as quickly.", "我一生中有很长时间都在欧洲生活。欧洲没有那么快适应变化。"),
  ("美洲以外的市场", "美国以外的市场"), ("技术并购步伐较慢", "技术采购和采用的步伐较慢")],
  "Restore the percentage direction, remove an English echo, retain America rather than the Americas, and distinguish technology adoption from corporate M&A."),
 ("Andy Power — CEO, Digital Realty Trust:", [
  ("董事长兼首席执行官", "首席执行官"), ("诺福克地区", "北弗吉尼亚地区"),
  ("达成一项具有战略意义的协议，即作为Mars变电站的落点，我们已获得该站点的用地许可", "提供了一项具有战略意义的地役权，供Mars变电站落地使用"),
  ("2026 月初前", "2026 年初前"), ("在哥本哈根也完成了北侧超过 1 MW的签约", "在哥本哈根也签署了超过 1 MW的合同")],
  "Preserve CEO, Northern Virginia, the easement direction, beginning-of-year timing and north-of as a quantity threshold rather than geography."),
 ("Bob Halliday — CFO, Applied Materials:", [
  ("设备利用率尚未完全发挥，工具的使用效率仍需提升", "影响主要来自设备利用得更加充分、更高效"),
  ("得益于 Sym3 的最高水平CVD订单，以及新增的ALD业务布局", "来自 Sym3 刻蚀业务的进展、创纪录的CVD订单，以及新的ALD业务布局"),
  ("330 亿美元 万亿美元的WFE", "330 亿美元的WFE"),
  ("WFE的份额在 7.7 到 7.8 之间", "WFE市场规模约为 7.7 或 7.8"),
  ("在半导体服务领域的份额是 20 亿美元", "半导体服务业务规模为 20 亿美元"),
  ("这一比例将持续以 2016 的比例增长", "2016年该领域占整体支出的比例还将继续提高"),
  ("目前市场上大约有 1.3 万片晶圆，到今年年底将有大约 150 万片完成", "目前大约有 1.3 百万片晶圆；到今年年底完成的约为 150"),
  ("可能对整个公司构成影响", "可能拉低公司整体毛利率约一个百分点"),
  ("明年由于电视业务的下滑，我们依然相当健康", "明年即使电视业务下滑，我们仍将相当健康"),
  ("目前大约提升了一个百分点", "目前约造成一个百分点的压力"),
  ("：欢迎。", "：不客气。")],
  "Restore tool-utilization causality, separate Sym3/CVD/ALD, remove duplicate currency scale, preserve 1.3 million wafers and do not invent a scale for 150. Retain the gross-margin headwind sign and service-business monetary rather than share basis."),
 ("Bob Pragada — Chair and CEO, Jacobs Solutions:", [
  ("关于 40美元，这并不是 900 万美元，而是在第一季度发生的一笔支出", "关于 40美元，这里提到的 900 万美元是第一季度已经发生的支出")],
  "The fragmented spoken sentence identifies $9m as first-quarter incurred expense; preserve that timing and do not invent a scale for the shorthand $40."),
 ("Chris Kuehn — EVP and CFO, Trane Technologies: Yeah, Julian,", [
  ("我认为你接近了 Q4", "我认为你对 Q4 的估计大致在合理范围内"), ("订单 backlog", "积压订单")],
  "In the ballpark is an estimate assessment, not physical proximity to Q4; backlog is the order backlog."),
 ("Chris Kuehn — EVP and CFO, Trane Technologies: Yeah. I'll start", [
  ("12月到1月", "十二月到一月"),
  ("250美元 至 275 百万", "2.5 亿美元至2.75 亿美元"),
  ("75美元 至 100 百万", "7500 万美元至1 亿美元")],
  "Bind both endpoints of explicit shared-million ranges, and spell out the source's named months without introducing unexplained digit tokens."),
 ("Chris Kuehn — Executive Vice President and CFO, Trane Technologies:", [
  ("这将使全年目标落在 14% 左右", "这意味着第一季度约占全年目标的 14%"),
  ("而 Q1 则大约在 14% 的水平，相比全年中值有所提升", "以全年指引中值计算，Q1 约占全年的 14%")],
  "The two 14% statements are first-quarter contributions to the annual EPS guide, not annual growth or a comparison with the midpoint."),
 ("Gary Millerchip — CFO, Costco Wholesale:", [
  ("每笔订单支出达到 10美元 时可享受每月 150美元 优惠", "每月可享受 10美元 优惠、条件是购物篮金额达到 150美元"),
  ("高管会员", "Executive高级会员"), ("绝大部分的续费率提升", "续费率变动的绝大部分")],
  "Correct the source's $10 monthly benefit/$150 basket ownership inversion. Executive membership is a tier, not corporate executives. Do not call the discussed renewal decline an improvement."),
 ("Giordano Albertazzi — CEO, Vertiv:", [("去年11月", "去年十一月"), ("中标的率", "中标率")],
  "Retain the source's November month word and $500,000 per-MW magnitude; improve the win-rate label without changing its meaning."),
 ("Great. Thanks for taking the questions. Maybe just to follow up first on Meta AI,", [
  ("谢谢大家提问", "感谢你们回答问题"), ("本季度资本支出将处于 15美元 到 170 亿美元 之间", "该季度资本支出将处于 150 亿美元至170 亿美元 之间"),
  ("一个持续性的年度支出水平，即延续到 2025", "进入 2025 后可以延续的支出节奏")],
  "Restore the $15-$17bn quarterly range and preserve run-rate timing without converting quarterly capex into an annual amount."),
 ("Jeff Clarke — Vice Chairman and COO, Dell Technologies:", [
  ("副总裁兼首席运营官", "副董事长兼首席运营官"),
  ("这导致了我们的市场份额", "这也影响了我们的份额表现"),
  ("目前，是否仍存在比传统服务器更少的单位收入？但趋势是向好的", "从利润率来看，仍低于传统服务器，但正在改善")],
  "Vice chairman is not vice president; the server comparison is a margin rate, not unit revenue."),
 ("John Wall — Senior VP and CFO, Cadence:", [
  ("约翰·沃爾", "约翰·沃尔"), ("是的，當然，傑森，謝謝你的問題。是的，你看到的這一切主要來自於當前預期中納入了Hexagon Design and Engineering業務的影響。", "是的，当然，杰森，谢谢你的问题。你看到的主要是当前展望纳入Hexagon Design and Engineering业务的影响。"),
  ("该指南包含", "该指引包含"), ("现金产生的利息损失", "使用现金收购所损失的利息收入")],
  "Use simplified Chinese and preserve lost interest income on acquisition cash rather than implying an interest expense."),
 ("Marie Myers — CFO, Hewlett Packard Enterprise:", [
  ("我们把指引从 1.85美元-1.95美元 提升到了", "我们上调了指引，原话提到的区间为 1.85美元-1.95美元")],
  "Keep the source's incomplete revision wording without inventing a new endpoint. The separate $185-$195 source inconsistency is flagged, not repaired."),
 ("Matt Murphy — President and CEO, Marvell Technology: Sure, yeah.", [
  ("我们将将其", "我们将其"),
  ("今年400美元的计划更多地集中在后端，随着业务的逐步提升，这种延后效应，大约会推后两个季度，我们估计其影响可能会下降约一半", "今年400美元的计划原本更多集中在后半段。随着相关项目推迟约两个季度，我们估计今年这一金额可能约减半")],
  "Back-end loaded refers to timing; the annual program revenue amount, not the impact itself, is roughly halved. Leave missing monetary scale explicit."),
 ("Matt Murphy — President and CEO, Marvell Technology: Thanks, Toshiya,", [
  ("若干新的设计胜出", "若干新增产品获选"), ("这些新增订单明年", "这些新增产品获选预计明年")],
  "Design wins are customer product selections, not already booked purchase orders; retain the source's shorthand $800 without inventing its scale."),
 ("Matt Murphy — President and CEO, Marvell: Yeah, I think I'll focus", [
  ("具体是 210美元 到 230美元。", "具体是 210美元至230美元。")],
  "Bind only the final explicit source range as a range token; the preceding upward transition remains separate scalar amounts. No monetary scale is inferred."),
 ("Michael Hurlston — President and CEO, Lumentum Holdings Inc:", [
  ("订单 backlog", "积压订单"), ("进入四十年代", "进入百分之四十多的毛利率区间")],
  "Forties refers to gross-margin percentage levels, not a decade. The shorthand $400 after $400m remains flagged as source-scale ambiguity."),
 ("My question is on the tariff impact,", [
  ("250美元 至 350 百万", "2.5 亿美元至3.5 亿美元"),
  ("直到明年第一季度才被覆盖", "直到明年第一季度同比比较完全包含该影响")],
  "Restore the explicit shared-million range and the year-over-year lap meaning without claiming the tariff expires."),
 ("Olivier Pomel — Co-Founder and CEO, Datadog:", [
  ("这些操作虽然会增加成本，但通常并不会带来显著的价值", "那些被删减的数据和日志本身可能推高成本，却未必带来显著价值")],
  "Removing debug logs saves cost; the underlying logs, not the optimization actions, were the cost drivers."),
 ("Rob Johnson — CEO, Vertiv:", [("董事长兼首席执行官", "首席执行官")],
  "Preserve the source's CEO title without adding chairman; leave the unscaled $360 source quantity flagged."),
 ("Safra Catz — CEO, Oracle: Yes. Let me hit the buyback first,", [
  ("董事长兼首席执行官", "首席执行官"),
  ("我认为上个季度回购了大约 6 亿美元", "我认为再前一个季度回购了大约 6 亿美元"),
  ("8美元 亿美元", "80 亿美元"),
  ("毛利率润率", "毛利率")],
  "Preserve CEO and the two different preceding quarters. Explicit plural '$8 billions' means $8bn, not $8, and remove the duplicated margin suffix."),
 ("Sanjay Mehrotra — Chairman, President, and CEO, Micron Technology:", [
  ("我们已将全年收入预测从 25美元 提升至 30 十亿", "我们已上调HBM市场规模预估（由 250 亿美元至300 亿美元）"),
  ("HBM（高带宽内存）体积增加", "HBM（高带宽内存）需求量增加"),
  ("2025 年的第二季度", "2025 年的下半年"),
  ("早在 FQ3 月 2024 年", "早在 2024 年 FQ3"),
  ("1 亿美元 亿美元", "1 亿美元"),
  ("在 FQ1 年", "在 FQ1"), ("数亿美元的HBM收入", "数十亿美元的HBM收入")],
  "The estimate is HBM market size, not Micron company revenue. Preserve the upward $25bn-to-$30bn revision, second-half versus second-quarter timing, fiscal labels and multiple billions magnitude."),
 ("Tarek Robbiati — EVP and CFO, Hewlett Packard Enterprise:", [
  ("【prudent】", ""), ("【十亿】", ""), ("【OI&E】", "OI&E"),
  ("个位数低个位数水平", "低个位数的环比增长水平")],
  "Remove invented non-source bracket text including an unbound billion unit; preserve the low-single-digit sequential seasonality."),
 ("Thanks a lot. Lisa, I'm wondering", [
  ("将消费者GPU的市场份额维持在 20+% 是一个合理的基准目标", "以你们消费者GPU的 20+% 市场份额作为这里的参考目标是否合理")],
  "The question benchmarks AI-market aspirations against consumer-GPU share; it does not ask merely to maintain consumer share."),
 ("Toby Rice — President and CEO, EQT:", [
  ("董事长兼首席执行官", "总裁兼首席执行官"), ("应对刺激措施", "应对外部变化"),
  ("库存平衡", "供销平衡"), ("库存不平衡", "供销不平衡"),
  ("体积量", "气量"), ("各体积的流向", "各批气量的流向"), ("体积", "气量"),
  ("关闭了我们在墨西哥湾的所有产能，并在价格为", "停止向墨西哥湾方向输送相关气量，改为在盆地内出售，当时价格为"),
  ("在中至低 7美元 价位上以月前交易", "在7美元多区间的中低端，以一个月远期方式")],
  "Preserve president; gas-flow coordination and transport capacity are not inventory or production shutdown. Retain next-month contract timing and the source's low/mid-$7s range context."),
 ("What, again, the question is, what revenue level", [("削减一些投资", "推迟一些投资")],
  "Push out investment is a timing deferral, not a permanent spending cut."),
 ("When we're thinking about kind of third quarter earnings,", [
  ("中高个位数的杠杆水平", "十几个百分点中高端的经营杠杆水平"),
  ("考虑到前半段表现强劲的 Q2，后半段的调整情况", "在 Q2 表现强劲之后，下半年计划中纳入了怎样的预期")],
  "Mid-high teens is in the teens, not mid/high single digits. Preserve Q2-to-second-half planning context."),
 ("are you focusing on the big four or five", [("3美元 至 35 亿美元", "30 亿美元至35 亿美元")],
  "Both capex range endpoints share the explicit billion scale."),
 ("can you give us some more color into how you're thinking about commercial HVAC", [
  ("存在激烈的竞争环境", "面临较高的同期比较基数"),
  ("订单到交付比（book-to-bill）", "订单额与营收之比（book-to-bill）"),
  ("订单 backlog", "积压订单")],
  "Tough comps means comparison bases, not market competition; bill is revenue/billings, not delivery. Source typo '$6 billin' remains a flagged uncertainty."),
 ("can you talk about, you know, how those demand trends", [("在过去 90 天里观察到任何区域间的差异性", "与 90 天前相比是否出现变化")],
  "Preserve the temporal comparison with 90 days ago rather than substitute only a regional comparison."),
 ("what that was that made it so low in the second quarter.", [
  ("是什么导致第二季度的税率这么低？", "是什么使第二季度的这一指标这么低？"),
  ("0.07美元 这个税率情况", "与税项有关的 0.07美元 影响")],
  "The opening truncated subject is unknown, so do not invent tax rate. The dollar EPS effect is not itself a tax rate."),
 ("what's the timing for the H3C transaction", [("这个 H3C 交易的时点是从现在开始的", "从现在起，H3C 交易的时间安排是什么")],
  "Retain the question about future timing rather than turn it into a declarative start-date statement."),
]

SOURCE_WARNINGS = {
 "Alex Karp — CEO, Palantir Technologies:": "Contract amounts $50/$100/$200/$350/$400-$650/$750 have no explicit thousand/million scale in the source. No missing scale was inferred.",
 "Bob Halliday — CFO, Applied Materials:": "Source does not specify the scale of shorthand $640 or 150 wafers completed; 1.3 million is explicit and preserved. Do not infer a scale for the unqualified 150.",
 "Bob Pragada — Chair and CEO, Jacobs Solutions:": "Source gives shorthand $275 and $40 but explicit $9 million. These cannot be treated as a reconciled financial schedule without original-audio/filing confirmation.",
 "Marie Myers — CFO, Hewlett Packard Enterprise:": "The exact English source contains both $1.85-$1.95 and $185-$195. Possible missing decimals remain uncorrected; do not consume as financial guidance.",
 "Matt Murphy — President and CEO, Marvell Technology: Sure, yeah.": "Annual program plan is quoted as $400 without an explicit scale.",
 "Matt Murphy — President and CEO, Marvell Technology: Thanks, Toshiya,": "The source explicitly says $400 million then $800 the year after; the latter has no explicit scale.",
 "Matt Murphy — President and CEO, Marvell: Yeah, I think I'll focus": "Source uses shorthand $210/$20/$230 without a scale and explicitly states it is not formal guidance.",
 "Michael Hurlston — President and CEO, Lumentum Holdings Inc:": "The same discussion says $400 million and later that $400. The unscaled shorthand is retained, not silently converted.",
 "Mike Dastoor — CFO, Jabil:": "Source $825/$850 lacks a scale; the label free cash flow yields is insufficient to independently define its 50% denominator.",
 "Rob Johnson — CEO, Vertiv:": "The repeated pricing target $360 has no explicit thousand/million scale in the transcript.",
 "can you give us some more color into how you're thinking about commercial HVAC": "Source later uses '$6 billin', an apparent transcription typo after earlier $6 billion. The typo is not silently normalized into a fact.",
}


def normalize_range_representation(source, target):
    _, values = ENGINE.protect_numbers(source)
    output = target
    for value in sorted({value for value in values if "至" in value}, key=len, reverse=True):
        left, right = value.split("至")
        def flexible(text):
            return re.sub(r"(?:\\ )+", r"\\s*", re.escape(text))
        pattern = flexible(left) + r"\s*(?:至|到|[-–—])\s*" + flexible(right)
        expected = values.count(value)
        exact_count = output.count(value)
        if exact_count == expected:
            continue
        matches = list(re.finditer(pattern, output))
        if len(matches) != expected:
            raise ValueError(f"Ambiguous range representation requires exact editorial selection: {value}")
        output = re.sub(pattern, lambda _: value, output)
    return output


def review(cache, audit):
    if len(cache) != 33 or len(audit.get("sources", {})) != 33:
        raise ValueError("This review is scoped to exactly the 33-field suffix batch")
    corrections, notes = [], []
    edits_by_source = {}
    for prefix, replacements, reason in EDITS:
        matches = [source for source in cache if source.startswith(prefix)]
        if len(matches) != 1: raise ValueError(f"Expected unique source: {prefix}")
        edits_by_source[matches[0]] = (replacements, reason)
    for source, original in cache.items():
        target = original
        replacements, reason = edits_by_source.get(source, ([], "Source-aligned review; no substantive edit required."))
        for before, after in replacements:
            if before not in target: raise ValueError(f"Expected exact reviewed wording missing: {before}")
            target = target.replace(before, after)
        target = normalize_range_representation(source, target)
        warnings = [text for prefix, text in SOURCE_WARNINGS.items() if source.startswith(prefix)]
        notes.append({"sourceSha256": BASE.sha(source), "sourceWarnings": warnings,
                      "reviewScope": "exact_33_source_bilingual_editorial_review_not_source_factual_attestation"})
        if target == original:
            continue
        corrections.append({"sourceSha256": BASE.sha(source), "originalTranslationSha256": BASE.sha(original),
                            "protectedTranslation": BASE.protect_edited(source, target), "reason": reason})
    manifest = {"reviewer": "Codex exact-source bilingual editorial review, not a human review claim",
                "reviewedAt": "2026-09-06", "corrections": corrections}
    output, report = BASE.EDITOR.apply_review(cache, audit, manifest)
    report["exactSourceReview"] = {"sourceCount": 33, "sourceWarningsAreNotCorrectedFacts": True, "sources": notes}
    report["editorialNumericGuardVersion"] = ENGINE.NUMERIC_PROTECTION_VERSION
    return output, report, manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache", required=True, type=Path); parser.add_argument("--audit", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path); args = parser.parse_args()
    cache_bytes, audit_bytes = args.cache.read_bytes(), args.audit.read_bytes()
    output, report, manifest = review(json.loads(cache_bytes), json.loads(audit_bytes))
    report["editorialReview"]["priorCacheFileSha256"] = hashlib.sha256(cache_bytes).hexdigest()
    report["editorialReview"]["priorAuditFileSha256"] = hashlib.sha256(audit_bytes).hexdigest()
    args.output.mkdir(parents=True, exist_ok=False)
    for name, value in (("cache.json", output), ("audit.json", report), ("editorial-manifest.json", manifest)):
        with (args.output / name).open("x") as handle: handle.write(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    print(json.dumps({"sourceCount": 33, "editedSourceCount": len(manifest["corrections"]), "statusCounts": report["statusCounts"]}))


if __name__ == "__main__": main()
