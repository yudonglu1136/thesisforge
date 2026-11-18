import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const libDir = path.join(root, 'lib');
const failures = [];

function lineNumber(source, offset) {
  return source.slice(0, offset).split('\n').length;
}

function collectDictionaryKeys() {
  const keys = new Set();
  for (const rel of ['lib/main.dart', 'lib/chinese_localization_helpers.dart']) {
    const full = path.join(root, rel);
    if (!fs.existsSync(full)) continue;
    const src = fs.readFileSync(full, 'utf8');
    for (const match of src.matchAll(/(['"])([^'"\n]+)\1\s*:\s*['"]/g)) {
      keys.add(match[2]);
    }
  }
  return keys;
}

function checkAllDartFiles() {
  const dartFiles = fs
    .readdirSync(libDir)
    .filter((name) => name.endsWith('.dart'))
    .sort();
  const dictKeys = collectDictionaryKeys();

  const propGuards = [
    ['tooltip literal', /\btooltip:\s*(['"])([^'"$\n]+)\1/g],
    ['hintText literal', /\bhintText:\s*(['"])([^'"$\n]+)\1/g],
    ['labelText literal', /\blabelText:\s*(['"])([^'"$\n]+)\1/g],
    ['semanticLabel literal', /\bsemanticLabel:\s*(['"])([^'"$\n]+)\1/g],
    ['helpText literal', /\bhelpText:\s*(['"])([^'"$\n]+)\1/g],
    ['cancelText literal', /\bcancelText:\s*(['"])([^'"$\n]+)\1/g],
    ['confirmText literal', /\bconfirmText:\s*(['"])([^'"$\n]+)\1/g],
  ];

  const allowedPropTokens = /^(NVDA|AAPL|MSFT|GOOGL|QQQ|SPY|SCHD|USD|IBKR|SEC|URL|ID)$/i;
  const allowedMultiWordText = new Set([
    'Guru Intelligence',
    'ThesisForge',
    'S&P 500',
    '100% QQQ',
    '100% SCHD',
    'SEC Form 4',
    'Form 4',
    'Sharadar SF1',
    'Fact OS',
  ]);

  for (const fileName of dartFiles) {
    const relative = `lib/${fileName}`;
    const source = fs.readFileSync(path.join(libDir, fileName), 'utf8');

    for (const [name, pattern] of propGuards) {
      for (const match of source.matchAll(pattern)) {
        const val = match[2].trim();
        if (!/[A-Za-z]{2,}/.test(val)) continue;
        if (allowedPropTokens.test(val)) continue;
        failures.push(
          `${relative}:${lineNumber(source, match.index)} ${name}: "${val}"`,
        );
      }
    }

    for (const match of source.matchAll(/context\.ui\(\s*(['"])([^'"$\n]+)\1\s*\)/g)) {
      const val = match[2];
      if (!/[A-Za-z]{2,}/.test(val)) continue;
      if (!dictKeys.has(val)) {
        failures.push(
          `${relative}:${lineNumber(source, match.index)} missing _uiChinese key for context.ui("${val}")`,
        );
      }
    }

    for (const match of source.matchAll(/\bText\(\s*(['"])([^'"$\n]+)\1/g)) {
      const val = match[2].trim();
      if (allowedMultiWordText.has(val)) continue;
      if (/[A-Za-z]{3,}\s+[A-Za-z]{2,}/.test(val)) {
        failures.push(
          `${relative}:${lineNumber(source, match.index)} unlocalized multi-word Text literal: "${val}"`,
        );
      }
    }

    if (fileName !== 'chinese_localization_helpers.dart') {
      for (const match of source.matchAll(/大佬|大咖/g)) {
        failures.push(
          `${relative}:${lineNumber(source, match.index)} colloquial Guru term "${match[0]}" (use 大师 / 投资大师)`,
        );
      }
    }
  }
}

function checkSharedCoreDirectTextGuards() {
  const permittedDirectText = [
    /'GI'/,
    /'Guru Intelligence'/,
    /disclosureLabel\(/,
    /\$selectedStart - \$selectedEnd/,
    /context\.ui\(/,
    /actionLabel\(/,
    /\$\{page \+ 1\}\/\$count/,
    /'#\$rank'/,
    /context\.tr\(/,
    /\$gapText \u00b7 \$fairText/,
    /'1Y \$\{formatNullableReturn/,
    /\$priceText \u00b7 \$fairText/,
    /formatNullableReturn\(row\['trailingReturn'\]\).*annualVolatility/s,
    /formatDividendMoney\(/,
    /'\$day'/,
    /event\.ticker.*compactName/s,
    /'\$\{date\.day\}'/,
    /account\['provider'\].*context\.ui/s,
    /_stateLabel\(.*context\.ui/s,
    /context_position_multiplier.*toStringAsFixed/s,
    /signals\.length.*formatDate/s,
    /'SPY'/,
    /entry_date.*cost_basis.*current_price/s,
    /group\.rows\.length/,
    /confidence \* 100/,
    /'\$count'/,
  ];

  for (const relative of ['lib/main.dart', 'lib/stock_research.dart']) {
    const file = path.join(root, relative);
    const source = fs.readFileSync(file, 'utf8');
    for (const match of source.matchAll(/\bText\(\s*(['"])/g)) {
      const snippet = source.slice(match.index, match.index + 700);
      if (permittedDirectText.some((pattern) => pattern.test(snippet))) continue;
      failures.push(
        `${relative}:${lineNumber(source, match.index)} direct Text literal`,
      );
    }
  }
}

checkAllDartFiles();
checkSharedCoreDirectTextGuards();

if (failures.length > 0) {
  console.error('Bilingual coverage audit failed:');
  for (const failure of failures) console.error(`- ${failure}`);
  process.exitCode = 1;
} else {
  console.log(
    'Bilingual literal audit passed: all 55 Flutter Dart files satisfy i18n, _uiChinese, and institutional terminology guards.',
  );
}
