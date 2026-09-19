#!/usr/bin/env python3
"""Exact, source-aligned editorial edits for the isolated 21-field Qwen rerun.

These edits are not a blanket semantic approval of the recovered full cache.
The saved manifest is consumed by the existing source/number-bound review tool.
"""
import argparse
from collections import Counter
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import sys

SPEC = importlib.util.spec_from_file_location("qa_guard21_editor", Path(__file__).with_name("review-valuation-qa-translations.py"))
EDITOR = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = EDITOR
SPEC.loader.exec_module(EDITOR)
ENGINE = EDITOR.ENGINE

EDITS = [
    ("where Kuiper is? Or sort of how do we think",
     [("Kuiper 在哪里？", "Kuiper目前进展如何？")],
     "Where Kuiper is asks about business/program progress, not a geographic location."),
    ("Is there something else going on with mix just given",
     [("围绕 48 左右上下浮动", "围绕百分之 48 左右上下浮动")],
     "48-ish is explicitly a chip gross-margin percentage level in the same sentence, not a unitless multiple."),
    ("how do you think about China? You did say memory",
     [("内存业务在整体营收中占比会相对较高", "内存业务在中国整体营收中所占权重会相对较高"),
      ("沿此路径，如果我从三月到六月剔除FPD的毛利率，季度环比下降 90 个基点", "同样地，剔除FPD因素后，从三月至六月毛利率环比下降 90 个基点")],
     "Retain the China revenue subset instead of broadening it to total company revenue; interpret back out FPD as excluding that factor without inventing a division."),
    ("when you folks are guiding gross margins up into the March quarter.",
     [("三月份的毛利率提升", "截至三月的季度毛利率提升"), ("通过苹果产品模型传导的过程", "逐步影响苹果财务模型的过程")],
     "March quarter is a reporting quarter, not only March; Apple's model is the financial model, not a hardware product model."),
    ("Brice Hill — SVP and CFO, Applied Materials:",
     [("晶圆厂逻辑业务", "晶圆代工及逻辑芯片业务"), ("落后边缘或ICAPS部分", "成熟制程或ICAPS部分"),
      ("相对于领先边缘", "与先进制程相比"), ("今年公司整体增速非常高", "今年公司在该市场的业务增速非常高"),
      ("领先晶圆代工及逻辑芯片业务", "先进制程晶圆代工及逻辑芯片业务"), ("植入", "离子注入")],
     "Preserve ICAPS-specific growth rather than claim company-total growth; lagging/leading edge and implant are semiconductor process terms."),
    ("How should we think about gross margins beyond the July quarter",
     [("七月份季度之后", "截至七月的季度之后"), ("硅材料的用量预计会持续增长", "硅相关业务似乎会继续环比增长")],
     "Do not invent silicon material consumption; preserve the source's tentative silicon business wording and sequential growth."),
    ("Thanks so much for taking the questions. Brian,",
     [("谢谢大家参与提问。", "非常感谢你们回答问题。"),
      ("尤其是在 30s 之后的未来表现", "尤其是未来维持在 30s（百分之三十多）的利润率水平是否可持续")],
     "30s refers to AWS profit-margin levels in the same sentence, not future years or a valuation multiple."),
    ("Kevin McDonnell — EVP and CFO, Kevin McDonnell:",
     [("凯文·麦克唐纳——首席财务官", "凯文·麦克唐纳——执行副总裁兼首席财务官"),
      ("高 30s 调整后毛利率", "30s 高端（百分之三十几的高端）的调整后毛利率"),
      ("价值接近 35 亿美元 的几乎所有单一来源IDIQ合同", "价值接近 35 亿美元、几乎全为独家供应的IDIQ合同"),
      ("一旦由于预算调整延迟的国防部门资金，以及来自“宏伟法案”的拨款最终到位", "一旦因政府停摆而延迟的“大而美法案”相关资金和美国战争部预算拨款到位"),
      ("一个或两个星期", "一个或两个月")],
     "Retain EVP, high-30s margin context and the source's sole-source qualification; restore government-shutdown cause, quoted department name and months rather than weeks."),
    ("Jim Moylan — CFO, Ciena:",
     [("这些线路系统需要随着时间逐步部署。一旦这些系统被部署完成，其毛利率将会上升", "这些线路系统日后还需要逐步配置容量。随着容量配置增加，相关收入的毛利率会更高")],
     "Populate installed line systems means add capacity, not install the initial line system again; preserve the mix explanation."),
    ("Marc Benioff — CEO, Salesforce:",
     [("明年它将为业务带来大约 100 亿美元 的价值", "我认为这项业务明年的业务规模将约为 100 亿美元"),
      ("它的联邦能力", "它的数据联邦能力"), ("联邦到IBM主frame上", "通过数据联邦连接至IBM大型主机"), ("IBM主frame", "IBM大型主机")],
     "The $10bn remark is business scale, not an enterprise valuation; federation/mainframe are data-platform technical terms."),
    ("Peter Klein — CFO, Microsoft Corporation:",
     [("成本 of goods sold（销售成本）", "销售成本（COGS）")],
     "Remove the incomplete English translation while retaining the standard COGS acronym."),
    ("Safra Catz — CEO, Oracle:",
     [("Safra Catz — 董事长", "Safra Catz — 首席执行官"), ("每天 7 天，每天 20 小时", "每周 7 天，每天 20 小时")],
     "CEO is not chairman; preserve the source's weekly and daily time units without altering its numbers."),
    ("Why are you expecting the decline in the gross margins?",
     [("还是混合因素", "还是销售组合变化")],
     "Mix in a gross-margin question is sales/product mix, not an unspecified mixture of factors."),
    ("can you give us the revenue percentages of PC DRAM,",
     [("特制DRAM", "特种DRAM"), ("按企业平均利润率来排序这四个细分领域的毛利率", "以公司平均毛利率为参照，对这四个细分业务的毛利率进行排序")],
     "Preserve specialty DRAM and the comparison of segment gross margins with the corporate average."),
    ("Jensen Huang — President and CEO, NVIDIA:",
     [("大约是 30 一些奇怪的百分比", "大约是百分之 30 多一点")],
     "Thirty-some-odd percent is an approximate thirty-something margin, not a strange or nonsensical percentage."),
    ("when you say low 70s gross margins,",
     [("低 70s 毛利率", "70s 低端（百分之七十出头）的毛利率"),
      ("是 73.5 被视为低 70s", "73.5 是否也算作 70s 低端"),
      ("指导总营收", "给出总营收指引"), ("quote and quote", "用你的原话说"),
      ("中国是否正在逐步回落至 Q4", "进入 Q4 时，中国业务是否会有所回落")],
     "Clarify low-seventies gross margins without changing protected numeric expressions; preserve several billion as Chinese 数十亿美元 (billions of USD), not 数亿美元 (hundreds of millions), and the Q4 time relationship."),
]


def sha(text):
    return hashlib.sha256(text.encode()).hexdigest()


def protect_edited(source, target):
    _, values = ENGINE.protect_numbers(source)
    result = target
    for value in sorted(set(values), key=lambda v: (-len(v), v)):
        indices = [index for index, candidate in enumerate(values) if candidate == value]
        pattern = r"(?<![A-Za-z0-9])" + re.escape(value) + r"(?![A-Za-z0-9])"
        if len(re.findall(pattern, result)) != len(indices):
            raise ValueError(f"Expected protected expression count changed: {value}")
        iterator = iter(indices)
        result = re.sub(pattern, lambda _match: f"⟦N{next(iterator)}⟧", result)
    remaining = ENGINE.PLACEHOLDER_RE.sub("", result)
    if ENGINE.PROTECTED_VALUE_RE.search(remaining) or re.search(r"\d", remaining):
        raise ValueError("Editorial change introduced an unbound numeric expression")
    return result


def review(cache, audit):
    if len(cache) != 21 or len(audit.get("sources", {})) != 21:
        raise ValueError("This editorial review is scoped to exactly the 21 rerun sources")
    corrections = []
    for prefix, replacements, reason in EDITS:
        matches = [source for source in cache if source.startswith(prefix)]
        if len(matches) != 1:
            raise ValueError(f"Editorial source must match exactly once: {prefix}")
        source = matches[0]
        target = cache[source]
        for before, after in replacements:
            if before not in target:
                raise ValueError(f"Expected reviewed wording changed: {before}")
            target = target.replace(before, after)
        corrections.append({"sourceSha256": sha(source), "originalTranslationSha256": sha(cache[source]),
                            "protectedTranslation": protect_edited(source, target), "reason": reason})
    manifest = {"reviewer": "Codex exact-source bilingual editorial review, not a human review claim",
                "reviewedAt": "2026-09-06", "corrections": corrections}
    output, report = EDITOR.apply_review(cache, audit, manifest)
    return output, report, manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache", type=Path, required=True)
    parser.add_argument("--audit", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    cache_bytes, audit_bytes = args.cache.read_bytes(), args.audit.read_bytes()
    output, report, manifest = review(json.loads(cache_bytes), json.loads(audit_bytes))
    report["editorialReview"]["priorCacheFileSha256"] = hashlib.sha256(cache_bytes).hexdigest()
    report["editorialReview"]["priorAuditFileSha256"] = hashlib.sha256(audit_bytes).hexdigest()
    args.output.mkdir(parents=True, exist_ok=False)
    for name, payload in (("cache.json", output), ("audit.json", report), ("editorial-manifest.json", manifest)):
        with (args.output / name).open("x") as handle:
            handle.write(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    print(json.dumps({"sourceCount": len(output), "editedSourceCount": len(manifest["corrections"]), "statusCounts": report["statusCounts"]}))


if __name__ == "__main__":
    main()
