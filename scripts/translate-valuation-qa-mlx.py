#!/usr/bin/env python3
"""Translate stored valuation transcript Q&A with a local audited MLX model.

The published translation cache intentionally remains a plain source-to-Chinese
JSON mapping because ``server/enrichValuationTranscriptQa.js`` consumes that
format.  A separate audit JSON records model lineage and validation results.

Numeric expressions are replaced with deterministic placeholders before model
inference.  This prevents an otherwise fluent language model from silently
changing a percentage, currency magnitude, date, quarter, or basis-point value.
"""

from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
import math
import re
import sqlite3
import sys
import time
from dataclasses import asdict, dataclass
from decimal import Decimal, InvalidOperation
from pathlib import Path
from typing import Iterable, Sequence


DEFAULT_MODEL = "mlx-community/Qwen3-4B-Instruct-2507-4bit"
NUMERIC_PROTECTION_VERSION = "deterministic-v8-shared-money-range-explicit-plural-scales"
DEFAULT_CHECKPOINT_EVERY = 100
DEFAULT_BATCH_SIZE = 12
DEFAULT_CHUNK_CHARS = 3_200
RETRY_FRAGMENT_CHARS = 280
FINAL_RETRY_FRAGMENT_CHARS = 140
NUMERIC_TEXT_SPAN_CHARS = 180
FINAL_NUMERIC_TEXT_SPAN_CHARS = 96

SYSTEM_PROMPT = """你是买方研究团队的资深中英双语财报编辑。把英文财报电话会文本逐句完整翻译成自然、准确的简体中文。不得概括、增添、删除或解释。保持说话人、产品名、ticker、缩写、时间顺序、因果关系及不确定语气。输入中的 ⟦N0⟧、⟦N1⟧ 等标记代表已审计的数字或金额；每个标记必须原样保留一次，不能改写、移动到错误句子或遗漏。严格区分现金流金额、现金流率和增速：free cash flow margin 或明确表示占营收比例的自由现金流译为自由现金流率；现金流金额不能改成比率；free cash flow growth 译为自由现金流增速。财务 margin 译为利润率，金额 gross profit 译为毛利、operating income 译为营业利润，不因同段出现 margin 就把所有利润金额改成利润率。revenue accelerated 表示营收增速加快。输出只含简体中文译文。"""
RETRY_SYSTEM_PROMPT = """你是财报翻译校对员。逐句完整翻译成自然、准确的简体中文，只输出译文。源文中每个用中文全角方括号【】包住的数字、年份、季度、金额或百分比均为已经校准的审计值；必须把每个完整括号片段原样保留在对应句子中，出现次数也必须完全相同，不得省略、复制或改写。"""
FINAL_RETRY_SYSTEM_PROMPT = """你是财报逐句翻译审计员。完整翻译下面这个很短的英文片段，只输出简体中文译文。寒暄、问题背景、限定词和比较关系都不能概括或省略。每个用中文全角方括号【】包住的审计值必须原样保留在对应位置，数量完全一致。不得直接照抄英文句子。"""
NUMERIC_SPAN_SYSTEM_PROMPT = """你是财报逐句翻译审计员。输入是从完整英文句子中截出的纯文本片段，片段的前后可能紧邻一个已被系统移除并单独保存的数字。只翻译输入片段本身，保持语序、连接词、标点、寒暄和限定语，不得概括、补写数字或照抄整段英文。只输出自然、准确的简体中文片段。"""

PLACEHOLDER_RE = re.compile(r"⟦N(\d+)⟧")
RETRY_PLACEHOLDER_RE = re.compile(r"ZXNUM(\d+)ZX")
RETRY_END_RE = re.compile(r"ZXEND(\d+)ZX")
MONEY_RANGE_PATTERN = (
    r"(?P<moneyrange>(?P<range_between>\bbetween\s+)?"
    r"(?P<range_currency>US\$|CA\$|AU\$|HK\$|NZ\$|\$|£|€|¥)\s*"
    r"(?P<range_left>[-+]?\d[\d,]*(?:\.\d+)?)"
    r"(?:\s*(?P<range_left_scale>trillions?|billions?|millions?|thousands?|[TBMK])(?![A-Za-z0-9]))?"
    r"\s*(?(range_between)and|(?:to\b|through\b|[-–—]))\s*"
    r"(?:(?P=range_currency)\s*)?(?P<range_right>[-+]?\d[\d,]*(?:\.\d+)?)"
    r"(?:\s*(?P<range_right_scale>trillions?|billions?|millions?|thousands?|[TBMK])(?![A-Za-z0-9]))?)"
)
BASE_PROTECTED_VALUE_RE = re.compile(
    r"(?P<money>(?:US\$|CA\$|AU\$|HK\$|NZ\$|\$|£|€|¥)\s*"
    r"[-+]?\d[\d,]*(?:\.\d+)?(?:\s*(?:trillions?|billions?|millions?|thousands?|[TBMK])(?![A-Za-z0-9]))?)"
    r"|(?P<quarter>\b(?:FY\s*)?20\d{2}\s*Q[1-4]\b|\bQ[1-4]\s*(?:FY\s*)?20\d{2}\b|\bFY\s*20\d{2}\b|\bQ[1-4]\b)"
    r"|(?P<identifier>\b(?:FY\d{2}|[A-Za-z][A-Za-z0-9.-]*\d[A-Za-z0-9.-]*|\d+(?:\.\d+)?[A-Za-z][A-Za-z0-9.-]*)\b)"
    r"|(?P<bps>[-+]?\d[\d,]*(?:\.\d+)?\s*(?:basis points?|bps)\b)"
    r"|(?P<percent>[-+]?\d[\d,]*(?:\.\d+)?\s*%)"
    r"|(?P<engineering>\b\d[\d,]*(?:\.\d+)?\s*(?:[KMGT](?:bps|bits?|bytes?|B|Hz)?|gigs?|terabits?)\b)"
    r"|(?P<number>\b\d[\d,]*(?:\.\d+)?\b)",
    re.IGNORECASE,
)
PROTECTED_VALUE_RE = re.compile(MONEY_RANGE_PATTERN + "|" + BASE_PROTECTED_VALUE_RE.pattern, re.IGNORECASE)

ABBREVIATIONS = (
    "U.S.", "U.K.", "e.g.", "i.e.", "Mr.", "Ms.", "Dr.", "Inc.", "Ltd.",
    "Corp.", "Co.", "vs.", "approx.",
)


@dataclass
class SourceAudit:
    source_sha256: str
    translation_sha256: str
    source_chars: int
    translation_chars: int
    chunk_count: int
    status: str
    warnings: list[str]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", required=True, help="Valuation SQLite database containing ticker snapshots.")
    parser.add_argument("--cache", required=True, help="Output source-to-Chinese translation JSON cache.")
    parser.add_argument("--audit", required=True, help="Output translation lineage and validation JSON.")
    parser.add_argument("--model", default=DEFAULT_MODEL)
    parser.add_argument("--context", default="", help="Explicit translation-domain context, recorded in prompt hashes; never an instruction to alter source facts.")
    parser.add_argument("--batch-size", type=int, default=DEFAULT_BATCH_SIZE)
    parser.add_argument("--chunk-chars", type=int, default=DEFAULT_CHUNK_CHARS)
    parser.add_argument("--checkpoint-every", type=int, default=DEFAULT_CHECKPOINT_EVERY)
    parser.add_argument("--limit", type=int, default=0, help="Translate at most N missing source fields; 0 means all.")
    parser.add_argument("--force", action="store_true", help="Discard existing cache entries and translate every source again.")
    parser.add_argument("--dry-run", action="store_true", help="Report source inventory without loading the model.")
    return parser.parse_args()


def sha256_text(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def split_speaker_label(text: str) -> tuple[str, str]:
    """Preserve the exact attributed speaker/company; translate the answer.

    Numeric checks cannot catch a fluent translation that silently assigns a
    CEO to another company. This prefix is factual source identity, not prose
    for the language model to reconstruct.
    """
    match = re.match(r"^([^:\n]{1,180}\s+[—–]\s+[^:\n]{1,220}:)\s*(.+)$", text, re.S)
    if match and re.search(r"\b(?:CEO|CFO|COO|president|officer|director|chairman|founder|relations|controller|treasurer)\b", match[1], re.I):
        return match[1], match[2]
    return "", text


def has_chinese(value: str) -> bool:
    return bool(re.search(r"[\u3400-\u9fff]", value or ""))


def enough_chinese(value: str, source: str) -> bool:
    label, body = split_speaker_label(source)
    if label and value and value.startswith(label):
        source, value = body, value[len(label):].strip()
    if not value or not has_chinese(value):
        return False
    chinese_chars = len(re.findall(r"[\u3400-\u9fff]", value))
    if len(source) < 16:
        return chinese_chars >= 2
    if len(source) < 80:
        return chinese_chars >= max(4, int(len(source) * 0.12))
    return chinese_chars >= max(12, int(len(source) * 0.12))


def read_json(path: Path, fallback):
    if not path.exists():
        return fallback
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return fallback


def reusable_source_audit(source: str, translated, audit):
    """Resume only an exact audited source/target pair, never a status flag.

    A modified cache must be regenerated even if a previous process left a
    passing sidecar behind. Reuse only this generator's understood row schema;
    richer editorial/recovery packages retain their own separate merger and
    provenance rules rather than being silently flattened here.
    """
    if not isinstance(translated, str) or not isinstance(audit, dict):
        return None
    if (audit.get("status") not in {"pass", "approved"}
            or audit.get("source_sha256") != sha256_text(source)
            or audit.get("translation_sha256") != sha256_text(translated)
            or audit.get("source_chars") != len(source)
            or audit.get("translation_chars") != len(translated)
            or audit.get("warnings") != []
            or not enough_chinese(translated, source)):
        return None
    try:
        record = SourceAudit(**audit)
    except TypeError:
        return None
    if (isinstance(record.chunk_count, bool)
            or not isinstance(record.chunk_count, int) or record.chunk_count < 1):
        return None
    if chunk_warnings(source, translated):
        return None
    return record


def atomic_write_json(path: Path, payload) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    temporary.replace(path)


def extract_sources(db_path: Path) -> list[str]:
    sources: set[str] = set()
    with sqlite3.connect(str(db_path)) as connection:
        connection.execute("PRAGMA query_only = ON")
        connection.execute("PRAGMA temp_store = MEMORY")
        rows = connection.execute("SELECT payload_json FROM valuation_ticker_snapshots ORDER BY ticker").fetchall()
    for (payload_json,) in rows:
        payload = json.loads(payload_json)
        for history_row in payload.get("history") or []:
            youtube = ((history_row.get("dataSnapshot") or {}).get("youtubeEarnings") or {})
            for qa in youtube.get("qa") or []:
                question = str(qa.get("question") or "").strip()
                answer = str(qa.get("answer") or "").strip()
                if question:
                    sources.add(question)
                if answer:
                    sources.add(answer)
    return sorted(sources, key=lambda value: (len(value), value))


def decimal_text(value: Decimal) -> str:
    rendered = format(value.normalize(), "f")
    if "." in rendered:
        rendered = rendered.rstrip("0").rstrip(".")
    return rendered


def currency_name(symbol: str) -> str:
    return {
        "$": "美元",
        "US$": "美元",
        "CA$": "加元",
        "AU$": "澳元",
        "HK$": "港元",
        "NZ$": "新西兰元",
        "£": "英镑",
        "€": "欧元",
        "¥": "日元",
    }.get(symbol, symbol)


def deterministic_money(value: str) -> str:
    match = re.fullmatch(
        r"(US\$|CA\$|AU\$|HK\$|NZ\$|\$|£|€|¥)\s*([-+]?\d[\d,]*(?:\.\d+)?)\s*(trillions?|billions?|millions?|thousands?|[TBMK])?",
        value.strip(),
        flags=re.IGNORECASE,
    )
    if not match:
        return value
    symbol, raw_number, raw_scale = match.groups()
    try:
        number = Decimal(raw_number.replace(",", ""))
    except InvalidOperation:
        return value
    scale = (raw_scale or "").lower().removesuffix("s")
    multiplier = {
        "trillion": Decimal("1000000000000"),
        "t": Decimal("1000000000000"),
        "billion": Decimal("1000000000"),
        "b": Decimal("1000000000"),
        "million": Decimal("1000000"),
        "m": Decimal("1000000"),
        "thousand": Decimal("1000"),
        "k": Decimal("1000"),
        "": Decimal("1"),
    }.get(scale)
    if multiplier is None:
        return value
    base = number * multiplier
    absolute = abs(base)
    if absolute >= Decimal("100000000"):
        rendered = f"{decimal_text(base / Decimal('100000000'))} 亿"
    elif absolute >= Decimal("10000"):
        rendered = f"{decimal_text(base / Decimal('10000'))} 万"
    else:
        rendered = decimal_text(base)
    return f"{rendered}{currency_name(symbol)}"


def deterministic_protected_value(match: re.Match[str]) -> str:
    value = match.group(0).strip()
    if match.lastgroup == "moneyrange":
        currency = match.group("range_currency")
        right_scale = match.group("range_right_scale") or ""
        left_scale = match.group("range_left_scale") or right_scale
        left = deterministic_money(currency + match.group("range_left") + " " + left_scale)
        right = deterministic_money(currency + match.group("range_right") + " " + right_scale)
        return left + "至" + right
    if match.lastgroup == "money":
        return deterministic_money(value)
    if match.lastgroup == "bps":
        number = re.match(r"[-+]?\d[\d,]*(?:\.\d+)?", value)
        return f"{number.group(0)} 个基点" if number else value
    return re.sub(r"\s+%$", "%", value)


def protected_value_spans(source: str):
    for match in PROTECTED_VALUE_RE.finditer(source):
        if match.lastgroup == "moneyrange":
            # A by-X-to-Y revision is not a range. Nor is a left-only scale
            # sufficient proof that an explicitly quoted right amount shares it.
            preceding = source[:match.start()]
            delta_revision = re.search(r"\bby\s*$", preceding, re.IGNORECASE)
            left_only_scale = match.group("range_left_scale") and not match.group("range_right_scale")
            if delta_revision or left_only_scale:
                for scalar in BASE_PROTECTED_VALUE_RE.finditer(source, match.start(), match.end()):
                    yield scalar.start(), scalar.end(), deterministic_protected_value(scalar)
                continue
        yield match.start(), match.end(), deterministic_protected_value(match)


def protect_numbers(source: str, *, retry: bool = False) -> tuple[str, list[str]]:
    values: list[str] = []
    pieces = []
    cursor = 0
    for start, end, value in protected_value_spans(source):
        pieces.append(source[cursor:start])
        placeholder = retry_token(len(values), value) if retry else f"⟦N{len(values)}⟧"
        values.append(value)
        pieces.append(placeholder)
        cursor = end
    pieces.append(source[cursor:])
    return "".join(pieces), values


def restore_numbers(translated: str, values: Sequence[str], *, retry: bool = False) -> str:
    if retry:
        output = translated
        expected = Counter(retry_token(index, value) for index, value in enumerate(values))
        failures = [
            f"{token} expected={count} actual={output.count(token)}"
            for token, count in expected.items()
            if output.count(token) != count
        ]
        numeric_brackets = re.findall(r"【[^】]*\d[^】]*】", output)
        unknown = sorted(set(numeric_brackets) - set(expected))
        if failures or unknown:
            raise ValueError(
                "numeric audit token mismatch: "
                f"failures={failures} unknown={unknown}"
            )
        for token, count in expected.items():
            value = token[1:-1]
            output = output.replace(token, value, count)
        return output.strip()

    placeholder = (lambda index: f"ZXNUM{index}ZX") if retry else (lambda index: f"⟦N{index}⟧")
    pattern = RETRY_PLACEHOLDER_RE if retry else PLACEHOLDER_RE
    expected = [placeholder(index) for index in range(len(values))]
    found = pattern.findall(translated)
    found_placeholders = [placeholder(value) for value in found]
    if sorted(found_placeholders) != sorted(expected):
        missing = sorted(set(expected) - set(found_placeholders))
        duplicate = sorted({item for item in found_placeholders if found_placeholders.count(item) > 1})
        unknown = sorted(set(found_placeholders) - set(expected))
        raise ValueError(f"numeric placeholder mismatch: missing={missing} duplicate={duplicate} unknown={unknown}")
    output = translated
    for index, value in enumerate(values):
        output = output.replace(placeholder(index), value)
    if pattern.search(output):
        raise ValueError("numeric placeholder remained after restoration")
    return output.strip()


def retry_token(index: int, value: str) -> str:
    del index
    return f"【{value.strip()}】"


def safe_boundary(text: str, start: int, target: int) -> int:
    if target >= len(text):
        return len(text)
    lower = max(start + 1, target - 700)
    protected = text
    for abbreviation in ABBREVIATIONS:
        protected = protected.replace(abbreviation, abbreviation.replace(".", "∯"))
    candidate = protected[lower:target]
    boundaries = [match.end() for match in re.finditer(r"[.!?][\"')\]]?\s+|\n+", candidate)]
    if boundaries:
        return lower + boundaries[-1]
    clauses = [match.end() for match in re.finditer(r"[;:]\s+|,\s+", candidate)]
    if clauses:
        return lower + clauses[-1]
    return target


def split_source(source: str, max_chars: int) -> list[str]:
    source = re.sub(r"\s+", " ", source).strip()
    if len(source) <= max_chars:
        return [source]
    chunks: list[str] = []
    cursor = 0
    while cursor < len(source):
        end = safe_boundary(source, cursor, min(len(source), cursor + max_chars))
        if end <= cursor:
            end = min(len(source), cursor + max_chars)
        chunk = source[cursor:end].strip()
        if chunk:
            chunks.append(chunk)
        cursor = end
    return chunks


def retry_system_prompt(values: Sequence[str], *, final: bool = False) -> str:
    base = FINAL_RETRY_SYSTEM_PROMPT if final else RETRY_SYSTEM_PROMPT
    if not values:
        return base
    marker_counts = Counter(retry_token(index, value) for index, value in enumerate(values))
    markers = "、".join(
        f"{marker}（{count} 次）" if count > 1 else marker
        for marker, count in marker_counts.items()
    )
    return f"{base}\n本片段必须原样保留的审计值清单：{markers}。"


def has_financial_margin(source: str) -> bool:
    without_idiom = re.sub(
        r"\bby\s+(?:(?:such\s+)?a\s+)?(?:very\s+)?(?:wide|long|large|significant|considerable)\s+margin\b",
        "",
        source,
        flags=re.IGNORECASE,
    )
    without_idiom = re.sub(
        r"\b(?:on|at)\s+(?:the\s+)?margins?\b|\bmargins?\s+of\s+(?:a\s+)?(?:problem|error|safety)\b",
        "",
        without_idiom,
        flags=re.IGNORECASE,
    )
    without_idiom = re.sub(
        r"\bmargin\s+(?:loans?|accounts?|calls?|collateral|requirements?)\b",
        "",
        without_idiom,
        flags=re.IGNORECASE,
    )
    return bool(re.search(r"\bmargins?\b", without_idiom, re.IGNORECASE))


def normalize_financial_terms(source: str, translated: str) -> str:
    output = translated
    # A paragraph can contain both an amount and its margin. Global replacement
    # would turn correctly translated gross profit into gross margin. In mixed
    # owner clauses leave the wording to translation/review, not regex guessing.
    gross_amount_owner = bool(re.search(r"\bgross profits?\b", source, re.IGNORECASE))
    operating_amount_owner = bool(re.search(r"\boperating (?:income|profits?)\b", source, re.IGNORECASE))
    if re.search(r"\bcontribution margins?\b", source, re.IGNORECASE):
        output = re.sub(r"贡献毛利率?|贡献利润(?!率)", "贡献利润率", output)
    if not gross_amount_owner and re.search(r"\bgross margins?\b", source, re.IGNORECASE):
        output = re.sub(r"毛利(?!率)", "毛利率", output)
    if not operating_amount_owner and re.search(r"\boperating margins?\b", source, re.IGNORECASE):
        output = re.sub(r"营业利润(?!率)", "营业利润率", output)
    if re.search(r"\bprofit margins?\b", source, re.IGNORECASE):
        output = output.replace("利润空间", "利润率")
    if re.search(r"\bfree cash flow margins?\b", source, re.IGNORECASE):
        output = output.replace("自由现金流利润率", "自由现金流率")
    if has_financial_margin(source):
        if not gross_amount_owner:
            output = re.sub(r"毛利(?!率)", "毛利率", output)
        output = output.replace("利润空间", "利润率")
    return output


def split_numeric_spans(source: str) -> list[tuple[str, str]]:
    spans: list[tuple[str, str]] = []
    cursor = 0
    for start, end, value in protected_value_spans(source):
        if start > cursor:
            spans.append(("text", source[cursor:start]))
        spans.append(("value", value))
        cursor = end
    if cursor < len(source):
        spans.append(("text", source[cursor:]))
    return spans


def chunk_warnings(source: str, translated: str) -> list[str]:
    warnings: list[str] = []
    label, _ = split_speaker_label(source)
    if label and not translated.startswith(label):
        warnings.append("speaker_identity_changed_or_not_preserved")
    if not enough_chinese(translated, source):
        warnings.append("insufficient_chinese")
    if "<think>" in translated.lower() or "</think>" in translated.lower():
        warnings.append("reasoning_leak")
    if len(source) >= 160 and len(translated) < max(30, int(len(source) * 0.12)):
        warnings.append("possible_truncation")
    if has_financial_margin(source) and "利润率" not in translated and "率" not in translated:
        warnings.append("margin_semantics_missing")
    if re.search(r"generated\s+\d+(?:\.\d+)?%\s+adjusted free cash flow", source, re.IGNORECASE):
        if "自由现金流率" not in translated:
            warnings.append("free_cash_flow_margin_semantics_missing")
    return warnings


def numeric_span_warnings(source: str, translated: str) -> list[str]:
    warnings = chunk_warnings(source, translated)
    # Short English connectors often contract to only a few Chinese characters.
    # The complete-source check below still enforces adequate Chinese coverage.
    if len(source.strip()) < 32 and has_chinese(translated):
        warnings = [warning for warning in warnings if warning != "insufficient_chinese"]
    if re.search(r"\d", translated):
        warnings.append("unexpected_numeric_text_in_translated_span")
    return sorted(set(warnings))


def batches(values: Sequence, size: int) -> Iterable[Sequence]:
    for index in range(0, len(values), size):
        yield values[index:index + size]


def translate_chunk_batch(model, tokenizer, chunk_rows: list[dict], system_prompt: str | None = None) -> list[str]:
    system_prompt = system_prompt or SYSTEM_PROMPT
    from mlx_lm import batch_generate
    from mlx_lm.sample_utils import make_sampler

    labels_and_bodies = [split_speaker_label(row["protected"]) for row in chunk_rows]
    prompts = [
        tokenizer.apply_chat_template(
            [
                {"role": "system", "content": row.get("systemPrompt", system_prompt)},
                {"role": "user", "content": body},
            ],
            add_generation_prompt=True,
            tokenize=True,
        )
        for row, (_, body) in zip(chunk_rows, labels_and_bodies, strict=True)
    ]
    max_tokens = [max(160, min(4_096, int(math.ceil(len(row["source"]) * 0.92)))) for row in chunk_rows]
    response = batch_generate(
        model,
        tokenizer,
        prompts,
        max_tokens=max_tokens,
        sampler=make_sampler(temp=0.0),
        verbose=False,
    )
    return [f"{label} {translated}" if label else translated
            for (label, _), translated in zip(labels_and_bodies, response.texts, strict=True)]


def translate_retry_fragments(
    model,
    tokenizer,
    source: str,
    *,
    batch_size: int,
    max_chars: int,
    final: bool,
) -> tuple[str, list[str]]:
    rows: list[dict] = []
    for fragment in split_source(source, max_chars):
        protected, values = protect_numbers(fragment, retry=True)
        rows.append({
            "source": fragment,
            "protected": protected,
            "values": values,
            "systemPrompt": retry_system_prompt(values, final=final),
        })

    raw_translations: list[str] = []
    for row_batch in batches(rows, batch_size):
        raw_translations.extend(translate_chunk_batch(model, tokenizer, list(row_batch)))

    translated_fragments: list[str] = []
    failures: list[str] = []
    for row, raw in zip(rows, raw_translations, strict=True):
        try:
            translated = restore_numbers(raw.strip(), row["values"], retry=True)
        except ValueError as error:
            failures.append(f"numeric {error}; output={raw[:160]}")
            continue
        translated = normalize_financial_terms(row["source"], translated)
        warnings = chunk_warnings(row["source"], translated)
        if warnings:
            failures.append(f"quality {','.join(warnings)}; output={raw[:160]}")
            continue
        translated_fragments.append(translated)

    if failures:
        return "", failures
    return " ".join(translated_fragments).strip(), []


def translate_with_fragment_retry(model, tokenizer, source: str, batch_size: int) -> tuple[str, list[str]]:
    translated, failures = translate_retry_fragments(
        model,
        tokenizer,
        source,
        batch_size=batch_size,
        max_chars=RETRY_FRAGMENT_CHARS,
        final=False,
    )
    if translated:
        return translated, []
    final_translation, final_failures = translate_retry_fragments(
        model,
        tokenizer,
        source,
        batch_size=batch_size,
        max_chars=FINAL_RETRY_FRAGMENT_CHARS,
        final=True,
    )
    if final_translation:
        return final_translation, []
    segmented_translation, segmented_failures = translate_numeric_span_segments(
        model,
        tokenizer,
        source,
        batch_size=batch_size,
        max_chars=NUMERIC_TEXT_SPAN_CHARS,
    )
    if segmented_translation:
        return segmented_translation, []
    final_segmented_translation, final_segmented_failures = translate_numeric_span_segments(
        model,
        tokenizer,
        source,
        batch_size=batch_size,
        max_chars=FINAL_NUMERIC_TEXT_SPAN_CHARS,
    )
    if final_segmented_translation:
        return final_segmented_translation, []
    return "", [
        *(f"fragment retry {failure}" for failure in failures[:4]),
        *(f"final fragment retry {failure}" for failure in final_failures[:4]),
        *(f"numeric span retry {failure}" for failure in segmented_failures[:4]),
        *(f"final numeric span retry {failure}" for failure in final_segmented_failures[:4]),
    ]


def translate_numeric_span_segments(
    model,
    tokenizer,
    source: str,
    *,
    batch_size: int,
    max_chars: int,
) -> tuple[str, list[str]]:
    spans = split_numeric_spans(source)
    rows: list[dict] = []
    row_destinations: list[tuple[list[str], int]] = []
    output_parts: list[str | list[str]] = []
    for position, (kind, value) in enumerate(spans):
        if kind == "value":
            output_parts.append(value)
            continue
        if not re.search(r"[A-Za-z]", value):
            output_parts.append(value)
            continue
        pieces = split_source(value, max_chars)
        translated_pieces = [""] * len(pieces)
        output_parts.append(translated_pieces)
        for piece_index, piece in enumerate(pieces):
            rows.append({
                "source": piece,
                "protected": piece,
                "systemPrompt": NUMERIC_SPAN_SYSTEM_PROMPT,
            })
            row_destinations.append((translated_pieces, piece_index))

    raw_translations: list[str] = []
    for row_batch in batches(rows, batch_size):
        raw_translations.extend(translate_chunk_batch(model, tokenizer, list(row_batch)))

    failures: list[str] = []
    for row, destination, raw in zip(rows, row_destinations, raw_translations, strict=True):
        translated = normalize_financial_terms(row["source"], raw.strip())
        warnings = numeric_span_warnings(row["source"], translated)
        if warnings:
            failures.append(f"{','.join(warnings)}; output={raw[:160]}")
            continue
        translated_pieces, piece_index = destination
        translated_pieces[piece_index] = translated

    if failures:
        return "", failures
    translation = "".join(
        "".join(part) if isinstance(part, list) else part
        for part in output_parts
    ).strip()
    expected_values = [value for kind, value in spans if kind == "value"]
    for value, count in Counter(expected_values).items():
        if translation.count(value) < count:
            failures.append(f"deterministic reinsertion failed for {value}: expected={count}")
    if failures or not enough_chinese(translation, source):
        if not enough_chinese(translation, source):
            failures.append("segmented translation insufficient_chinese")
        return "", failures
    return translation, []


def write_checkpoint(
    cache_path: Path,
    audit_path: Path,
    translations: dict[str, str],
    audits: dict[str, SourceAudit],
    model_name: str,
    source_count: int,
    started_at: str,
) -> None:
    atomic_write_json(cache_path, translations)
    status_counts: dict[str, int] = {}
    for audit in audits.values():
        status_counts[audit.status] = status_counts.get(audit.status, 0) + 1
    atomic_write_json(
        audit_path,
        {
            "schemaVersion": 1,
            "model": model_name,
            "systemPromptSha256": sha256_text(SYSTEM_PROMPT),
            "retrySystemPromptSha256": sha256_text(RETRY_SYSTEM_PROMPT),
            "finalRetrySystemPromptSha256": sha256_text(FINAL_RETRY_SYSTEM_PROMPT),
            "numericSpanSystemPromptSha256": sha256_text(NUMERIC_SPAN_SYSTEM_PROMPT),
            "numericProtection": NUMERIC_PROTECTION_VERSION,
            "financialTerminologyPolicy": "deterministic-margin-semantics-v1",
            "startedAt": started_at,
            "updatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "sourceCount": source_count,
            "translatedCount": len(translations),
            "statusCounts": status_counts,
            "sources": {key: asdict(value) for key, value in sorted(audits.items())},
        },
    )


def main() -> int:
    global SYSTEM_PROMPT, RETRY_SYSTEM_PROMPT, FINAL_RETRY_SYSTEM_PROMPT, NUMERIC_SPAN_SYSTEM_PROMPT
    args = parse_args()
    if args.context.strip():
        context = "\n仅用于理解术语的领域背景，不得因此增加原文没有的事实或职务：" + args.context.strip()
        SYSTEM_PROMPT += context
        RETRY_SYSTEM_PROMPT += context
        FINAL_RETRY_SYSTEM_PROMPT += context
        NUMERIC_SPAN_SYSTEM_PROMPT += context
    db_path = Path(args.db).expanduser().resolve()
    cache_path = Path(args.cache).expanduser().resolve()
    audit_path = Path(args.audit).expanduser().resolve()
    if not db_path.exists():
        raise SystemExit(f"valuation database not found: {db_path}")
    if args.batch_size < 1 or args.chunk_chars < 500:
        raise SystemExit("batch size must be >= 1 and chunk chars must be >= 500")

    sources = extract_sources(db_path)
    existing_cache = {} if args.force else read_json(cache_path, {})
    existing_audit_payload = {} if args.force else read_json(audit_path, {})
    if args.context.strip() and existing_cache and existing_audit_payload.get("systemPromptSha256") != sha256_text(SYSTEM_PROMPT):
        raise SystemExit("Translation context changed; use a new cache/audit path to preserve the prior translation lineage.")
    if existing_cache and existing_audit_payload.get("numericProtection") != NUMERIC_PROTECTION_VERSION:
        raise SystemExit("Numeric protection changed; use a new cache/audit path rather than silently reuse old numeric output.")
    if existing_cache and existing_audit_payload.get("systemPromptSha256") != sha256_text(SYSTEM_PROMPT):
        raise SystemExit("Translation prompt changed; use a new cache/audit path to preserve the prior prompt lineage.")
    if existing_cache and existing_audit_payload.get("model") != args.model:
        raise SystemExit("Translation model changed; use a new cache/audit path to preserve the prior model lineage.")
    existing_source_audits = existing_audit_payload.get("sources") or {}
    translations, audits = {}, {}
    current_sources = set(sources)
    for source, translated in existing_cache.items():
        if source not in current_sources:
            continue
        record = reusable_source_audit(source, translated, existing_source_audits.get(source))
        if record is not None:
            translations[source] = translated
            audits[source] = record
    missing_sources = [source for source in sources if source not in translations]
    if args.limit > 0:
        missing_sources = missing_sources[: args.limit]

    total_chars = sum(len(source) for source in sources)
    missing_chars = sum(len(source) for source in missing_sources)
    print(json.dumps({
        "database": str(db_path),
        "sources": len(sources),
        "sourceChars": total_chars,
        "cached": len(translations),
        "missing": len(missing_sources),
        "missingChars": missing_chars,
        "model": args.model,
    }, ensure_ascii=False))
    if args.dry_run or not missing_sources:
        return 0

    from mlx_lm import load

    started_at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    model, tokenizer = load(args.model)
    source_states: dict[str, dict] = {}
    chunk_tasks: list[dict] = []
    for source in missing_sources:
        chunks = split_source(source, args.chunk_chars)
        source_states[source] = {
            "chunks": chunks,
            "translations": [None] * len(chunks),
            "warnings": [],
            "failed": False,
            "remaining": len(chunks),
        }
        for chunk_index, chunk in enumerate(chunks):
            protected, values = protect_numbers(chunk)
            chunk_tasks.append({
                "owner": source,
                "chunkIndex": chunk_index,
                "source": chunk,
                "protected": protected,
                "values": values,
            })

    translated_since_checkpoint = 0
    completed_sources = 0
    for task_batch in batches(chunk_tasks, args.batch_size):
        raw_translations = translate_chunk_batch(model, tokenizer, list(task_batch))
        for row, raw in zip(task_batch, raw_translations, strict=True):
            state = source_states[row["owner"]]
            initial_failures: list[str] = []
            try:
                translated = restore_numbers(raw.strip(), row["values"])
            except ValueError as error:
                translated = ""
                initial_failures.append(f"initial numeric {error}; output={raw[:160]}")
            else:
                translated = normalize_financial_terms(row["source"], translated)
                initial_warnings = chunk_warnings(row["source"], translated)
                initial_failures.extend(f"initial quality {warning}" for warning in initial_warnings)

            if initial_failures:
                translated, retry_failures = translate_with_fragment_retry(
                    model,
                    tokenizer,
                    row["source"],
                    args.batch_size,
                )
                if not translated:
                    state["warnings"].extend(initial_failures)
                    state["warnings"].extend(retry_failures)
                    state["failed"] = True
            if translated:
                state["warnings"].extend(chunk_warnings(row["source"], translated))
                state["translations"][row["chunkIndex"]] = translated
            state["remaining"] -= 1

            if state["remaining"] != 0:
                continue

            source = row["owner"]
            translation = " ".join(value or "" for value in state["translations"]).strip()
            unique_warnings = sorted(set(state["warnings"]))
            if state["failed"] or not enough_chinese(translation, source):
                status = "failed"
            elif unique_warnings:
                status = "review"
            else:
                status = "pass"
            if status != "failed":
                translations[source] = translation
            audits[source] = SourceAudit(
                source_sha256=sha256_text(source),
                translation_sha256=sha256_text(translation) if translation else "",
                source_chars=len(source),
                translation_chars=len(translation),
                chunk_count=len(state["chunks"]),
                status=status,
                warnings=unique_warnings,
            )

            completed_sources += 1
            translated_since_checkpoint += 1
            if translated_since_checkpoint >= args.checkpoint_every or completed_sources == len(missing_sources):
                write_checkpoint(
                    cache_path,
                    audit_path,
                    translations,
                    audits,
                    args.model,
                    len(sources),
                    started_at,
                )
                translated_since_checkpoint = 0
                print(
                    f"translated {completed_sources}/{len(missing_sources)} missing fields; "
                    f"cache={len(translations)}/{len(sources)}; latest={status}",
                    flush=True,
                )

    failed_count = sum(1 for audit in audits.values() if audit.status == "failed")
    review_count = sum(1 for audit in audits.values() if audit.status == "review")
    print(json.dumps({
        "sources": len(sources),
        "translated": len(translations),
        "failed": failed_count,
        "review": review_count,
        "cache": str(cache_path),
        "audit": str(audit_path),
    }, ensure_ascii=False))
    return 1 if failed_count else 0


if __name__ == "__main__":
    sys.exit(main())
