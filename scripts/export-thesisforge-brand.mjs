import { createRequire } from 'node:module';
import { mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';

const require = createRequire(import.meta.url);
let sharp;
try {
  sharp = require('sharp');
} catch {
  sharp = require(
    process.env.SHARP_MODULE ||
      '/Users/yudonglu/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/sharp',
  );
}

const root = path.resolve(import.meta.dirname, '..');
const source =
  process.env.THESISFORGE_MARK_SOURCE ||
  path.join(root, 'docs/brand/2026-08-30/source-mark-imagegen.png');
const screenshotSource = path.join(root, 'docs/images/valuation-market-map.png');
const assetDir = path.join(root, 'assets/branding');
const webBrandDir = path.join(root, 'web/brand');
const exportDir = path.join(root, 'docs/brand/2026-08-30');
const englishScreenshot = path.join(
  exportDir,
  'valuation-market-map-en-1280x720.png',
);
const iconDir = path.join(root, 'web/icons');

const colors = {
  ink: '#0B111D',
  panel: '#111827',
  line: '#263248',
  mint: '#22D3A6',
  amber: '#E0B15A',
  text: '#F8FAFC',
  muted: '#A8B2C4',
};

await Promise.all([
  mkdir(assetDir, { recursive: true }),
  mkdir(webBrandDir, { recursive: true }),
  mkdir(exportDir, { recursive: true }),
]);

const sourcePixels = await sharp(source)
  .ensureAlpha()
  .raw()
  .toBuffer({ resolveWithObject: true });
const cleanedPixels = Buffer.from(sourcePixels.data);
for (let index = 0; index < cleanedPixels.length; index += 4) {
  const red = cleanedPixels[index];
  const green = cleanedPixels[index + 1];
  const blue = cleanedPixels[index + 2];
  const alpha = cleanedPixels[index + 3];
  if (alpha < 24 || (red < 48 && green < 48 && blue < 48)) {
    cleanedPixels[index + 3] = 0;
    continue;
  }
  const amber = red > green * 1.04 && red > blue * 1.5;
  const color = amber ? [224, 177, 90] : [34, 211, 166];
  cleanedPixels[index] = color[0];
  cleanedPixels[index + 1] = color[1];
  cleanedPixels[index + 2] = color[2];
}

const markBuffer = await sharp(cleanedPixels, {
  raw: {
    width: sourcePixels.info.width,
    height: sourcePixels.info.height,
    channels: 4,
  },
})
  .trim({ background: { r: 0, g: 0, b: 0, alpha: 0 } })
  .resize(820, 820, {
    fit: 'contain',
    background: { r: 0, g: 0, b: 0, alpha: 0 },
  })
  .extend({
    top: 102,
    bottom: 102,
    left: 102,
    right: 102,
    background: { r: 0, g: 0, b: 0, alpha: 0 },
  })
  .png({ compressionLevel: 9 })
  .toBuffer();

await Promise.all([
  writeFile(path.join(assetDir, 'thesisforge-mark.png'), markBuffer),
  writeFile(path.join(webBrandDir, 'thesisforge-mark.png'), markBuffer),
  writeFile(path.join(root, 'web/ontology/thesisforge-mark.png'), markBuffer),
]);

function roundedRect(width, height, radius, fill, stroke = 'none') {
  return Buffer.from(
    `<svg width="${width}" height="${height}" xmlns="http://www.w3.org/2000/svg"><rect width="${width}" height="${height}" rx="${radius}" fill="${fill}" stroke="${stroke}"/></svg>`,
  );
}

async function squareIcon(size, markScale, output) {
  const markSize = Math.round(size * markScale);
  const mark = await sharp(markBuffer)
    .resize(markSize, markSize, { fit: 'contain' })
    .png()
    .toBuffer();
  await sharp({
    create: {
      width: size,
      height: size,
      channels: 4,
      background: colors.ink,
    },
  })
    .composite([
      {
        input: mark,
        left: Math.round((size - markSize) / 2),
        top: Math.round((size - markSize) / 2),
      },
    ])
    .png({ compressionLevel: 9 })
    .toFile(output);
}

await Promise.all([
  squareIcon(192, 0.68, path.join(iconDir, 'Icon-192.png')),
  squareIcon(512, 0.68, path.join(iconDir, 'Icon-512.png')),
  squareIcon(192, 0.56, path.join(iconDir, 'Icon-maskable-192.png')),
  squareIcon(512, 0.56, path.join(iconDir, 'Icon-maskable-512.png')),
  squareIcon(64, 0.72, path.join(root, 'web/favicon.png')),
  squareIcon(64, 0.72, path.join(root, 'web/ontology/favicon.png')),
  squareIcon(400, 0.66, path.join(exportDir, 'thesisforge-x-avatar-400.png')),
  squareIcon(1024, 0.66, path.join(exportDir, 'thesisforge-x-avatar-1024.png')),
]);

const headerMark = await sharp(markBuffer)
  .resize(126, 126, { fit: 'contain' })
  .png()
  .toBuffer();
const headerSvg = Buffer.from(`
  <svg width="1500" height="500" xmlns="http://www.w3.org/2000/svg">
    <style>
      .brand { font: 800 70px -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; fill: ${colors.text}; letter-spacing: 0; }
      .tag { font: 650 34px -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; fill: ${colors.text}; letter-spacing: 0; }
      .meta { font: 500 23px -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; fill: ${colors.muted}; letter-spacing: 0; }
    </style>
    <rect width="1500" height="500" fill="${colors.ink}"/>
    <path d="M0 88H1500M0 250H1500M0 412H1500M198 0V500M750 0V500M1302 0V500" stroke="${colors.line}" stroke-width="1" opacity=".45"/>
    <rect x="176" y="104" width="1148" height="292" rx="18" fill="${colors.panel}" stroke="${colors.line}"/>
    <rect x="176" y="104" width="7" height="292" rx="3.5" fill="${colors.mint}"/>
    <text x="390" y="213" class="brand">ThesisForge</text>
    <text x="390" y="278" class="tag">Evidence before narrative.</text>
    <text x="390" y="331" class="meta">PIT fundamentals  ·  Management guidance  ·  13F intelligence  ·  Valuation</text>
  </svg>
`);

await sharp(headerSvg)
  .composite([{ input: headerMark, left: 220, top: 187 }])
  .png({ compressionLevel: 9 })
  .toFile(path.join(exportDir, 'thesisforge-x-header-1500x500.png'));

const englishUiOverlay = Buffer.from(`
  <svg width="1280" height="720" xmlns="http://www.w3.org/2000/svg">
    <style>
      .ui { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; letter-spacing: 0; }
      .title { font-size: 22px; font-weight: 800; fill: ${colors.text}; }
      .body { font-size: 12px; font-weight: 500; fill: ${colors.muted}; }
      .label { font-size: 13px; font-weight: 650; fill: ${colors.text}; }
      .small { font-size: 10px; font-weight: 650; fill: ${colors.muted}; }
      .control { font-size: 10.5px; font-weight: 650; fill: ${colors.text}; }
    </style>

    <rect x="1015" y="8" width="101" height="51" rx="9" fill="#121826" stroke="${colors.line}"/>
    <rect x="1021" y="14" width="44" height="39" rx="7" fill="#123F3A" stroke="#28675D"/>
    <text x="1035" y="39" class="ui control" fill="${colors.mint}">EN</text>
    <text x="1081" y="39" class="ui small">ZH</text>

    <rect x="50" y="88" width="510" height="35" fill="#121826"/>
    <rect x="24" y="121" width="540" height="26" fill="#121826"/>
    <text x="52" y="115" class="ui title">Valuation Market Map</text>
    <text x="25" y="138" class="ui body">533 securities · Prices 2026/08/27 · 532/533 PIT audits passed</text>

    <rect x="604" y="94" width="342" height="45" rx="9" fill="#111727" stroke="${colors.line}"/>
    <circle cx="625" cy="116" r="5" fill="none" stroke="${colors.muted}" stroke-width="2"/>
    <path d="M629 120l5 5" stroke="${colors.muted}" stroke-width="2" stroke-linecap="round"/>
    <text x="646" y="121" class="ui body">Search ticker, company, or industry</text>

    <rect x="953" y="94" width="112" height="45" rx="9" fill="#111727" stroke="${colors.line}"/>
    <text x="973" y="121" class="ui control">All valuations</text>
    <path d="M1052 113l4 4 4-4" fill="none" stroke="${colors.muted}" stroke-width="1.5"/>
    <rect x="1071" y="94" width="137" height="45" rx="9" fill="#111727" stroke="${colors.line}"/>
    <text x="1092" y="121" class="ui control">All quality</text>
    <path d="M1195 113l4 4 4-4" fill="none" stroke="${colors.muted}" stroke-width="1.5"/>

    <rect x="30" y="180" width="650" height="25" fill="#121826"/>
    <text x="39" y="199" class="ui small">INDUSTRY</text>
    <text x="299" y="199" class="ui small">COVERAGE</text>
    <text x="405" y="199" class="ui small">MEDIAN GAP</text>
    <text x="568" y="199" class="ui small">VALUATION MIX</text>

    <rect x="68" y="207" width="222" height="31" fill="#16232C"/>
    <text x="71" y="228" class="ui label">Software &amp; cloud services</text>

    <rect x="69" y="454" width="220" height="27" fill="#121826"/>
    <text x="71" y="474" class="ui label">Semiconductors &amp; hardware</text>
    <rect x="69" y="491" width="220" height="27" fill="#121826"/>
    <text x="71" y="511" class="ui label">Internet &amp; media</text>
    <rect x="69" y="528" width="220" height="27" fill="#121826"/>
    <text x="71" y="548" class="ui label">Healthcare</text>
    <rect x="69" y="565" width="220" height="27" fill="#121826"/>
    <text x="71" y="585" class="ui label">Financials &amp; payments</text>
    <rect x="69" y="602" width="220" height="27" fill="#121826"/>
    <text x="71" y="622" class="ui label">Consumer</text>
    <rect x="69" y="639" width="220" height="27" fill="#121826"/>
    <text x="71" y="659" class="ui label">Industrials &amp; defense</text>
    <rect x="69" y="676" width="220" height="27" fill="#121826"/>
    <text x="71" y="696" class="ui label">Energy &amp; utilities</text>
  </svg>
`);
const screenshotBrandMark = await sharp(markBuffer)
  .resize(30, 30, { fit: 'contain' })
  .png()
  .toBuffer();
const brandedScreenshot = await sharp(screenshotSource)
  .composite([
    { input: englishUiOverlay, left: 0, top: 0 },
    {
      input: roundedRect(38, 38, 8, '#123F3A', '#28675D'),
      left: 13,
      top: 14,
    },
    { input: screenshotBrandMark, left: 17, top: 18 },
  ])
  .png()
  .toBuffer();
await writeFile(englishScreenshot, brandedScreenshot);
const screenshotCard = await sharp(brandedScreenshot)
  .resize(820, 461, { fit: 'cover', position: 'top' })
  .composite([
    {
      input: roundedRect(820, 461, 14, 'none', colors.line),
      blend: 'over',
    },
  ])
  .png()
  .toBuffer();
const postMark = await sharp(markBuffer)
  .resize(92, 92, { fit: 'contain' })
  .png()
  .toBuffer();
const postSvg = Buffer.from(`
  <svg width="1600" height="900" xmlns="http://www.w3.org/2000/svg">
    <style>
      .eyebrow { font: 750 24px -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; fill: ${colors.mint}; letter-spacing: 1px; }
      .headline { font: 800 52px -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; fill: ${colors.text}; letter-spacing: 0; }
      .body { font: 500 25px -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; fill: ${colors.muted}; letter-spacing: 0; }
      .url { font: 700 24px -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; fill: ${colors.text}; letter-spacing: 0; }
    </style>
    <rect width="1600" height="900" fill="${colors.ink}"/>
    <path d="M0 124H1600M0 776H1600M124 0V900M1476 0V900" stroke="${colors.line}" stroke-width="1" opacity=".45"/>
    <rect x="72" y="72" width="1456" height="756" rx="24" fill="${colors.panel}" stroke="${colors.line}"/>
    <rect x="72" y="72" width="8" height="756" rx="4" fill="${colors.mint}"/>
    <text x="156" y="228" class="eyebrow">THESISFORGE</text>
    <text x="156" y="316" class="headline">Evidence before</text>
    <text x="156" y="378" class="headline">narrative.</text>
    <text x="156" y="462" class="body">Point-in-time fundamentals,</text>
    <text x="156" y="502" class="body">management guidance,</text>
    <text x="156" y="542" class="body">13F moves and valuation models.</text>
    <text x="156" y="582" class="body">One research workflow.</text>
    <rect x="156" y="638" width="300" height="58" rx="8" fill="#102C2B" stroke="#28675D"/>
    <circle cx="183" cy="667" r="6" fill="${colors.mint}"/>
    <text x="205" y="675" class="url">thesisforge.tech</text>
  </svg>
`);

await sharp(postSvg)
  .composite([
    { input: postMark, left: 149, top: 107 },
    { input: screenshotCard, left: 650, top: 220 },
  ])
  .png({ compressionLevel: 9 })
  .toFile(path.join(exportDir, 'thesisforge-first-post-1600x900.png'));

await writeFile(
  path.join(exportDir, 'manifest.json'),
  `${JSON.stringify(
    {
      brand: 'ThesisForge',
      product: 'ThesisForge',
      generatedAt: '2026-08-30',
      source: path.relative(root, source),
      palette: colors,
      files: {
        avatar: 'thesisforge-x-avatar-400.png',
        avatarHighResolution: 'thesisforge-x-avatar-1024.png',
        header: 'thesisforge-x-header-1500x500.png',
        firstPost: 'thesisforge-first-post-1600x900.png',
        englishProductScreenshot: 'valuation-market-map-en-1280x720.png',
        appMark: '../../../assets/branding/thesisforge-mark.png',
      },
      notes: [
        'Logo concept generated with OpenAI ImageGen, then deterministically cropped and exported.',
        'Header and launch image use exact SVG typography and platform-safe dimensions.',
        'The launch image uses the real valuation market-map screenshot; no financial data was invented.',
      ],
    },
    null,
    2,
  )}\n`,
);

console.log(`Brand exports written to ${exportDir}`);
