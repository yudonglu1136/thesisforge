/**
 * Exact-content compositor for the September 2026 product-usage video.
 * No UI, chart, financial figure, mouse event or model output is generated here.
 * Accepts freshly captured production clips, stills or timestamped image lists.
 *
 * node scripts/export-thesisforge-product-demo-20s.mjs /absolute/capture.json
 * See --help for the capture-manifest contract. Never use old media as a fallback.
 */
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { createRequire } from 'node:module';
import { mkdir, readFile, writeFile, stat } from 'node:fs/promises';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const root = path.resolve(import.meta.dirname, '..');
const require = createRequire(import.meta.url);
const W = 1080;
const H = 1350;
const FPS = 30;
const FRAME = { x: 44, y: 359, width: 992, height: 728 };
const DEFAULT_MARK = path.join(root, 'web/brand/thesisforge-mark.png');
const DURATIONS = [3, 3, 3, 4, 3, 4];
const LABELS = ['GURU / REPORTED HOLDINGS', 'GURU / HOLDING CHANGES', 'VALUATION / YOUR RESEARCH', 'VALUATION / PRICE VS. MODEL', 'VALUATION / ASSUMPTIONS', 'PUBLIC RESEARCH / ISRG'];
const HEADLINES = [
  ['Who’s buying?'],
  ['See what', 'changed.'],
  ['What’s your stock', 'worth?'],
  ['Price fell.', 'What about value?'],
  ['Check the', 'assumptions.'],
  ['Explore the ISRG case.', 'No login.'],
];
const CAPTIONS = [
  'Who’s buying?', 'See what changed.', 'What’s your stock worth?',
  'Price fell. What about value?', 'Check the assumptions.',
  'Explore the ISRG case. No login.',
];
const sha256 = (buffer) => createHash('sha256').update(buffer).digest('hex');
const xml = (text = '') => String(text).replace(/[<>&"']/g, (s) => ({ '<': '&lt;', '>': '&gt;', '&': '&amp;', '"': '&quot;', "'": '&apos;' })[s]);
const concatQuote = (file) => `'${file.replaceAll("'", "'\\''")}'`;

function run(command, args) {
  const result = spawnSync(command, args, { encoding: 'utf8', maxBuffer: 32 * 1024 * 1024, stdio: ['ignore', 'pipe', 'pipe'] });
  if (result.status !== 0) throw new Error(`${command} exited ${result.status}:\n${result.stdout}\n${result.stderr}`);
  return result.stdout;
}

function getSharp() {
  try { return require('sharp'); } catch {
    return require(process.env.SHARP_MODULE || '/Users/yudonglu/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/sharp');
  }
}

export async function expandCaptureManifests(config) {
  const expanded = structuredClone(config);
  if (!Array.isArray(expanded.scenes)) return expanded;
  for (const [index, scene] of expanded.scenes.entries()) {
    if (!scene.captureManifest) continue;
    if (scene.source || scene.frames || !path.isAbsolute(scene.captureManifest)) throw new Error(`Scene ${index + 1}: captureManifest must be an absolute path and cannot be combined with source/frames.`);
    const bytes = await readFile(scene.captureManifest);
    const capture = JSON.parse(bytes);
    if (!Array.isArray(capture.frames) || capture.frames.length < 2 || !(capture.duration > 0)) throw new Error(`Scene ${index + 1}: capture manifest needs multiple timestamped frames.`);
    if (capture.frames.some((frame, frameIndex) => !Number.isFinite(frame.t) || (frameIndex > 0 && frame.t <= capture.frames[frameIndex - 1].t))) throw new Error(`Scene ${index + 1}: capture times must be strictly increasing.`);
    const start = scene.startSeconds ?? capture.frames[0].t;
    const end = scene.endSeconds ?? capture.duration;
    if (!(end > start) || start < capture.frames[0].t || end > capture.duration) throw new Error(`Scene ${index + 1}: invalid capture time selection.`);
    const speed = (end - start) / DURATIONS[index];
    scene.frames = capture.frames.flatMap((frame, frameIndex) => {
      const frameEnd = capture.frames[frameIndex + 1]?.t ?? capture.duration;
      const seconds = Math.min(frameEnd, end) - Math.max(frame.t, start);
      if (seconds <= 0) return [];
      if (path.basename(frame.file) !== frame.file) throw new Error('Capture frame files must be plain basenames beside the manifest.');
      return [{ path: path.join(path.dirname(scene.captureManifest), frame.file), durationSeconds: seconds / speed }];
    });
    scene.sourceUrl ||= capture.sourceUrl;
    scene.capturedAt ||= capture.capturedAt;
    scene.captureProvenance = { manifest: scene.captureManifest, manifestSha256: sha256(bytes), captureMethod: capture.captureMethod, sourceDurationSeconds: capture.duration, selectedStartSeconds: start, selectedEndSeconds: end, timingScale: speed, sourceFrameCount: capture.frames.length, selectedFrameCount: scene.frames.length, fpsNote: 'Real browser captures with recorded timestamps; frame duplication to delivery 30 fps. No synthesized in-between UI frames.' };
    scene.speed = 1;
    scene.startSeconds = 0;
  }
  return expanded;
}

export function validateCapture(config) {
  if (!config || !Array.isArray(config.scenes) || config.scenes.length !== 6) throw new Error('Exactly six scene captures are required.');
  if (!config.capturedAt || !Number.isFinite(Date.parse(config.capturedAt))) throw new Error('capturedAt must be a real ISO timestamp.');
  if (!config.outputDir || !path.isAbsolute(config.outputDir)) throw new Error('outputDir must be an absolute path.');
  for (const [index, scene] of config.scenes.entries()) {
    if (!scene.sourceUrl || !/^https:\/\/(www\.)?thesisforge\.tech(?:\/|$)/.test(scene.sourceUrl)) throw new Error(`Scene ${index + 1} must identify the actual production source URL.`);
    if (!scene.dataDate) throw new Error(`Scene ${index + 1} must disclose its visible data cut; do not label capture time as data time.`);
    if (!scene.source && !scene.frames?.length) throw new Error(`Scene ${index + 1} has no source media.`);
    if (scene.source && scene.frames) throw new Error(`Scene ${index + 1}: use source or frames, not both.`);
    if (scene.source && !path.isAbsolute(scene.source)) throw new Error(`Scene ${index + 1} source must be absolute.`);
    if (scene.frames) {
      const total = scene.frames.reduce((sum, frame) => {
        if (!path.isAbsolute(frame.path) || !(frame.durationSeconds > 0)) throw new Error(`Scene ${index + 1}: invalid frame path or duration.`);
        return sum + frame.durationSeconds;
      }, 0);
      if (Math.abs(total - DURATIONS[index]) > 0.001) throw new Error(`Scene ${index + 1} image durations total ${total}; expected ${DURATIONS[index]}.`);
    }
    if (scene.mediaType && !['video', 'image'].includes(scene.mediaType)) throw new Error(`Scene ${index + 1}: mediaType must be video or image.`);
    if (scene.speed !== undefined && !(scene.speed > 0 && scene.speed <= 10)) throw new Error(`Scene ${index + 1}: invalid speed.`);
    if (scene.panels && (scene.crop || scene.panels.length !== 2)) throw new Error(`Scene ${index + 1}: panels requires exactly two stacked native crops, without crop.`);
    for (const crop of scene.panels || (scene.crop ? [scene.crop] : [])) {
      if (!['x', 'y', 'width', 'height'].every((key) => Number.isInteger(crop[key]) && crop[key] >= (key === 'width' || key === 'height' ? 1 : 0))) throw new Error(`Scene ${index + 1}: crop must be nonnegative integer x/y and positive integer width/height.`);
    }
    if (scene.context && (!Array.isArray(scene.context) || scene.context.length > 2 || scene.context.some((line) => String(line).length > 70))) throw new Error(`Scene ${index + 1}: context supports two short lines (70 characters each).`);
  }
  return config;
}

function layerSvg(index, scene, overlay = false) {
  const grid = Array.from({ length: 14 }, (_, i) => `<path d="M${i * 84} 0V${H}" stroke="#698094" stroke-opacity=".045"/>`).join('');
  const headline = HEADLINES[index];
  const headlineFont = index === 5 ? 65 : 74;
  const titleY = headline.length === 1 ? 274 : 250;
  const progress = DURATIONS.map((_, part) => `<rect x="${44 + part * 167}" y="139" width="157" height="4" rx="2" fill="${part <= index ? '#62D5B0' : '#243041'}"/>`).join('');
  const body = scene.context || [];
  return Buffer.from(`<svg width="${W}" height="${H}" xmlns="http://www.w3.org/2000/svg">
    <style>text{font-family:Helvetica,Arial,sans-serif;} .muted{fill:#ABB7C7;} .white{fill:#F5F8FB;}</style>
    ${!overlay ? `<defs><radialGradient id="glow"><stop stop-color="#163D35" stop-opacity=".35"/><stop offset="1" stop-color="#0B111A" stop-opacity="0"/></radialGradient></defs><rect width="${W}" height="${H}" fill="#0B111A"/>${grid}<ellipse cx="960" cy="90" rx="650" ry="480" fill="url(#glow)"/><rect x="${FRAME.x - 2}" y="${FRAME.y - 2}" width="${FRAME.width + 4}" height="${FRAME.height + 4}" rx="15" fill="#1F2B3A"/><rect x="${FRAME.x}" y="${FRAME.y}" width="${FRAME.width}" height="${FRAME.height}" fill="#0C121D"/>` : ''}
    ${overlay ? `<text x="130" y="80" font-size="34" font-weight="700" class="white">ThesisForge</text><text x="131" y="108" font-size="18" letter-spacing=".2" class="muted">Evidence before narrative.</text><text x="1036" y="80" text-anchor="end" font-size="18" letter-spacing="1.8" fill="#62D5B0">PRODUCT WALKTHROUGH</text>${progress}<text x="44" y="191" font-size="20" letter-spacing="1.8" font-weight="700" fill="#62D5B0">${LABELS[index]}</text>${headline.map((line, row) => `<text x="40" y="${titleY + row * 80}" font-size="${headlineFont}" font-weight="700" letter-spacing="-2.3" fill="${row === 1 ? '#62D5B0' : '#F5F8FB'}">${xml(line)}</text>`).join('')}<circle cx="54" cy="1125" r="5" fill="#62D5B0"/><text x="71" y="1133" font-size="23" class="muted">${xml(scene.dataDate)}</text>${body.map((line, row) => `<text x="44" y="${1180 + row * 34}" font-size="27" font-weight="500" class="white">${xml(line)}</text>`).join('')}${index === 5 ? '<rect x="44" y="1168" width="992" height="84" rx="15" fill="#62D5B0"/><text x="540" y="1221" text-anchor="middle" font-size="32" font-weight="700" fill="#09221A">thesisforge.tech/research/isrg</text>' : '<text x="44" y="1252" font-size="26" font-weight="700" fill="#62D5B0">thesisforge.tech</text>'}<path d="M44 1280H1036" stroke="#253142"/><text x="44" y="1315" font-size="19" fill="#8290A4">Research only · Not investment advice</text><text x="1036" y="1315" text-anchor="end" font-size="19" fill="#8290A4">${index + 1} / 6</text>` : ''}
  </svg>`);
}

function imageInput(file, duration) {
  return ['-loop', '1', '-framerate', String(FPS), '-t', String(duration), '-i', file];
}

async function sourceMetadata(scene, ffprobe) {
  const files = scene.frames ? scene.frames.map((f) => f.path) : [scene.source];
  const outputs = [];
  for (const file of files) {
    const information = JSON.parse(run(ffprobe, ['-v', 'error', '-show_streams', '-show_format', '-of', 'json', file]));
    const stream = information.streams.find((s) => s.codec_type === 'video');
    if (!stream) throw new Error(`No video/image stream in ${file}`);
    for (const crop of scene.panels || (scene.crop ? [scene.crop] : [])) {
      if (crop.x + crop.width > stream.width || crop.y + crop.height > stream.height) throw new Error(`Crop is outside ${file} (${stream.width}×${stream.height}).`);
    }
    outputs.push({ path: file, bytes: (await stat(file)).size, sha256: sha256(await readFile(file)), width: stream.width, height: stream.height, duration: information.format.duration || null });
  }
  if (outputs.some((entry) => entry.width !== outputs[0].width || entry.height !== outputs[0].height)) throw new Error('Frames in one scene must have identical dimensions.');
  return outputs;
}

function srtTimestamp(seconds) {
  return `00:00:${String(Math.floor(seconds)).padStart(2, '0')},${String(Math.round((seconds % 1) * 1000)).padStart(3, '0')}`;
}

export async function exportDemo(config) {
  config = await expandCaptureManifests(config);
  validateCapture(config);
  const ffmpeg = config.ffmpeg || 'ffmpeg';
  const ffprobe = config.ffprobe || 'ffprobe';
  const sharp = getSharp();
  const outputDir = config.outputDir;
  const assetsDir = path.join(outputDir, 'composition-assets');
  await mkdir(assetsDir, { recursive: true });
  const markPath = config.markSource || DEFAULT_MARK;
  const mark = await sharp(markPath).resize(66, 66, { fit: 'contain' }).png().toBuffer();
  const scenePaths = [];
  const provenance = [];
  let time = 0;
  const subtitles = [];

  for (const [index, scene] of config.scenes.entries()) {
    const duration = DURATIONS[index];
    const metadata = await sourceMetadata(scene, ffprobe);
    const background = path.join(assetsDir, `scene-${index + 1}-background.png`);
    const overlay = path.join(assetsDir, `scene-${index + 1}-overlay.png`);
    await sharp(layerSvg(index, scene)).png().toFile(background);
    await sharp(layerSvg(index, scene, true)).composite([{ input: mark, left: 43, top: 48 }]).png().toFile(overlay);
    const args = ['-hide_banner', '-loglevel', 'warning', '-y'];
    if (scene.frames) {
      const listFile = path.join(assetsDir, `scene-${index + 1}-frames.ffconcat`);
      await writeFile(listFile, `ffconcat version 1.0\n${scene.frames.map((frame) => `file ${concatQuote(frame.path)}\nduration ${frame.durationSeconds}`).join('\n')}\nfile ${concatQuote(scene.frames.at(-1).path)}\n`);
      args.push('-f', 'concat', '-safe', '0', '-i', listFile);
    } else if (scene.mediaType === 'image' || /\.(png|jpe?g|webp)$/i.test(scene.source)) {
      args.push(...imageInput(scene.source, duration));
    } else {
      const available = Number(metadata[0].duration);
      const required = duration * (scene.speed || 1);
      if (available && available + 0.05 < (scene.startSeconds || 0) + required) throw new Error(`Scene ${index + 1} clip too short: ${available}s, requires ${required}s after ${scene.startSeconds || 0}s.`);
      args.push('-ss', String(scene.startSeconds || 0), '-t', String(required), '-i', scene.source);
    }
    args.push(...imageInput(background, duration), ...imageInput(overlay, duration));
    const crop = scene.crop ? `crop=${scene.crop.width}:${scene.crop.height}:${scene.crop.x}:${scene.crop.y},` : '';
    const speed = scene.speed || 1;
    let sourceFilter = `[0:v]setpts=(PTS-STARTPTS)/${speed},${crop}fps=${FPS},scale=${FRAME.width}:${FRAME.height}:force_original_aspect_ratio=decrease:flags=lanczos,pad=${FRAME.width}:${FRAME.height}:(ow-iw)/2:(oh-ih)/2:color=0x0C121D,setsar=1,format=rgba[ui]`;
    if (scene.panels) {
      sourceFilter = `[0:v]setpts=(PTS-STARTPTS)/${speed},fps=${FPS},split=2[p0][p1];` + scene.panels.map((panel, part) => `[p${part}]crop=${panel.width}:${panel.height}:${panel.x}:${panel.y},scale=${FRAME.width}:${part ? 376 : 352}:force_original_aspect_ratio=decrease:flags=lanczos,pad=${FRAME.width}:${part ? 376 : 352}:(ow-iw)/2:(oh-ih)/2:color=0x0C121D,setsar=1,format=rgba[c${part}]`).join(';') + ';[c0][c1]vstack=inputs=2[ui]';
    }
    const filter = `${sourceFilter};[1:v][ui]overlay=${FRAME.x}:${FRAME.y}:shortest=1[framed];[framed][2:v]overlay=0:0:shortest=1,scale=out_range=tv:out_color_matrix=bt709,format=yuv420p,setparams=range=limited:color_primaries=bt709:color_trc=bt709:colorspace=bt709[out]`;
    const target = path.join(assetsDir, `scene-${index + 1}.mp4`);
    args.push('-filter_complex', filter, '-map', '[out]', '-an', '-frames:v', String(duration * FPS), '-r', String(FPS), '-c:v', 'libx264', '-preset', config.preset || 'medium', '-crf', '18', '-pix_fmt', 'yuv420p', '-color_range', 'tv', '-colorspace', 'bt709', '-color_primaries', 'bt709', '-color_trc', 'bt709', '-movflags', '+faststart', target);
    run(ffmpeg, args);
    scenePaths.push(target);
    subtitles.push(`${index + 1}\n${srtTimestamp(time)} --> ${srtTimestamp(time + duration)}\n${CAPTIONS[index]}\n`);
    provenance.push({ index: index + 1, startSeconds: time, durationSeconds: duration, sourceUrl: scene.sourceUrl, capturedAt: scene.capturedAt || config.capturedAt, dataDate: scene.dataDate, sourceType: scene.frames ? 'timestamped production screenshots' : (scene.mediaType || (/\.(png|jpe?g|webp)$/i.test(scene.source) ? 'image' : 'video')), sourceStartSeconds: scene.startSeconds || 0, playbackSpeed: speed, captureProvenance: scene.captureProvenance || null, crop: scene.crop || null, stackedNativePanels: scene.panels || null, sources: metadata, caption: CAPTIONS[index], context: scene.context || [], notes: scene.notes || null, treatment: 'Unaltered source UI, with proportional scaling/crop and external deterministic branding. No charts, figures, controls or cursor events are generated.' });
    time += duration;
    console.log(`Rendered scene ${index + 1}/6 (${duration}s).`);
  }

  const timeline = path.join(assetsDir, 'timeline.ffconcat');
  await writeFile(timeline, `ffconcat version 1.0\n${scenePaths.map((file) => `file ${concatQuote(file)}`).join('\n')}\n`);
  const output = path.join(outputDir, 'thesisforge-product-demo-en-20s.mp4');
  const finalArgs = ['-hide_banner', '-loglevel', 'warning', '-y', '-f', 'concat', '-safe', '0', '-i', timeline];
  if (config.audio === 'original-tone') {
    finalArgs.push('-f', 'lavfi', '-i', 'aevalsrc=0.014*sin(2*PI*110*t)+0.007*sin(2*PI*165*t)+0.003*sin(2*PI*220*t):s=48000:d=20', '-map', '0:v:0', '-map', '1:a:0', '-af', 'afade=t=in:st=0:d=0.6,afade=t=out:st=18.7:d=1.3', '-c:a', 'aac', '-b:a', '128k');
  } else finalArgs.push('-map', '0:v:0', '-an');
  finalArgs.push('-t', '20', '-c:v', 'copy', '-movflags', '+faststart', output);
  run(ffmpeg, finalArgs);
  const probe = JSON.parse(run(ffprobe, ['-v', 'error', '-show_streams', '-show_format', '-of', 'json', output]));
  const stream = probe.streams.find((s) => s.codec_type === 'video');
  if (stream.width !== W || stream.height !== H || stream.codec_name !== 'h264' || stream.pix_fmt !== 'yuv420p' || Math.abs(Number(probe.format.duration) - 20) > 0.05 || Number(stream.nb_frames) !== 600) throw new Error(`Output failed dimensions/codec/duration/frame-count checks: ${JSON.stringify(probe)}`);
  const poster = path.join(outputDir, 'thesisforge-product-demo-en-poster.jpg');
  run(ffmpeg, ['-hide_banner', '-loglevel', 'error', '-y', '-ss', '10.5', '-i', output, '-frames:v', '1', '-q:v', '2', poster]);
  const previewFrames = [];
  for (const [index, seconds] of [1.5, 4.5, 7.5, 11, 14.5, 18].entries()) {
    const file = path.join(assetsDir, `review-${index + 1}.jpg`);
    run(ffmpeg, ['-hide_banner', '-loglevel', 'error', '-y', '-ss', String(seconds), '-i', output, '-frames:v', '1', '-q:v', '2', file]);
    previewFrames.push(file);
  }
  const contactSheet = path.join(outputDir, 'thesisforge-product-demo-review.jpg');
  await sharp({ create: { width: 1080, height: 900, channels: 3, background: '#0B111A' } }).composite(await Promise.all(previewFrames.map(async (file, index) => ({ input: await sharp(file).resize(360, 450).toBuffer(), left: (index % 3) * 360, top: Math.floor(index / 3) * 450 })))).jpeg({ quality: 92 }).toFile(contactSheet);
  const srt = path.join(outputDir, 'thesisforge-product-demo-en.srt');
  await writeFile(srt, subtitles.join('\n'));
  const manifest = {
    title: 'ThesisForge — Who’s buying? What’s it worth?',
    generatedAt: new Date().toISOString(), capturedAt: config.capturedAt,
    dimensions: { width: W, height: H }, durationSeconds: 20, frameRate: FPS, frameCount: 600,
    output, poster, contactSheet, subtitles: srt,
    sourceCaptureDescription: config.sourceCaptureDescription || 'See scene sourceType and source capture provenance.',
    productionVersion: config.productionVersion || null,
    sourcePreservation: { generatedUi: false, generatedFinancialData: false, priceOrChartRetouching: false, proportionalScalingOnly: true, finalCompression: 'H.264 lossy delivery; full-resolution source media retained separately.' },
    audio: config.audio === 'original-tone' ? 'Original deterministic sine-tone bed; no third-party music.' : 'Silent-first; English captions burned in.',
    caveats: ['Guru holdings and the ISRG valuation are distinct research workflows; no Ackman ownership of ISRG is implied.', 'Valuation is a dated model estimate, not a guaranteed return or necessarily a standalone DCF.', 'PIT replay is not evidence of contemporaneously archived forecasts.', 'Public case is no-login; the full terminal remains authenticated.'],
    scenes: provenance,
    hashes: { logoSha256: sha256(await readFile(markPath)), videoSha256: sha256(await readFile(output)), posterSha256: sha256(await readFile(poster)), subtitleSha256: sha256(await readFile(srt)) },
    technicalVerification: { codec: stream.codec_name, pixelFormat: stream.pix_fmt, duration: probe.format.duration, frameCount: stream.nb_frames, averageFrameRate: stream.avg_frame_rate, fastStart: true },
  };
  const manifestPath = path.join(outputDir, 'thesisforge-product-demo-manifest.json');
  await writeFile(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
  await writeFile(path.join(outputDir, 'PROVENANCE.md'), `# ThesisForge product demo\n\nGenerated: ${manifest.generatedAt}\n\n${manifest.sourceCaptureDescription}\n\n- Current production URL: https://www.thesisforge.tech/\n- Public case CTA: https://www.thesisforge.tech/research/isrg/\n- Delivery: 20.0 seconds, 1080 × 1350, 30 fps, H.264 / yuv420p / fast start.\n- Source assets and hashes: thesisforge-product-demo-manifest.json.\n- Production data dates remain distinct from screen-capture dates.\n- UI, charts and values are preserved from the sources; only crop, proportional scale and external branding are applied.\n- Bill Ackman and ISRG are separate examples; this is not a claim that Ackman holds ISRG.\n- Research only. Not investment advice.\n- No social post or deployment is performed by this exporter.\n\n## Review checklist\n\nTechnical checks pass automatically. A human/agent must still review all six contact-sheet frames for text legibility, accurate dates, private information, misleading crops and fit, plus the full video for timing and unexpected cuts.\n`);
  return { output, poster, contactSheet, manifestPath, subtitles: srt };
}

if (import.meta.url === pathToFileURL(process.argv[1] || '').href) {
  if (!process.argv[2] || process.argv[2] === '--help') {
    console.log(`Usage: node scripts/export-thesisforge-product-demo-20s.mjs /absolute/capture.json\n\nCapture JSON:\n{\n  "outputDir": "/absolute/output-directory",\n  "capturedAt": "2026-09-05T00:00:00Z",\n  "sourceCaptureDescription": "Actual production browser recording ...",\n  "productionVersion": "verified commit/deployment",\n  "audio": "silent",\n  "scenes": [ // Exactly six scenes; duration fixed at 3,3,3,4,3,4 seconds.\n    {"source": "/absolute/scene-1.mp4", "mediaType": "video",\n     "sourceUrl": "https://www.thesisforge.tech/?view=guru&lang=en",\n     "startSeconds": 0, "speed": 1,\n     "crop": {"x": 0, "y": 0, "width": 1280, "height": 720},\n     "dataDate": "Reported holdings · Q2 2026",\n     "context": ["Optional verified short explanation"],\n     "notes": "Capture/selection evidence"}\n  ]\n}\n\nFor a still use mediaType:image. For a genuine capture sequence replace source\nand mediaType with frames:[{path:"/absolute/frame.jpg",durationSeconds:0.1},...].\nSequence durations must exactly equal the scene duration. Still-image sequences\nare disclosed as such in provenance; never label them continuous recordings.\nNo default/old media is accepted. Crops must be inside the native source.\n`);
  } else {
    const config = JSON.parse(await readFile(path.resolve(process.argv[2]), 'utf8'));
    console.log(JSON.stringify(await exportDemo(config), null, 2));
  }
}
