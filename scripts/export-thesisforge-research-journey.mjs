/**
 * A coherent Guru -> reported position history -> same-stock valuation film.
 * This deterministic compositor never manufactures product state or chart data.
 * Usage: node scripts/export-thesisforge-research-journey.mjs /absolute/capture.json
 */
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { createRequire } from 'node:module';
import { mkdir, readFile, writeFile, stat } from 'node:fs/promises';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const root = path.resolve(import.meta.dirname, '..');
const require = createRequire(import.meta.url);
const W = 1920;
const H = 1080;
const FPS = 30;
const FRAME = { x: 20, y: 90, width: 1880, height: 850 };
const DEFAULT_MARK = path.join(root, 'web/brand/thesisforge-mark.png');
const sha256 = (bytes) => createHash('sha256').update(bytes).digest('hex');
const xml = (value = '') => String(value).replace(/[<>&"']/g, (s) => ({ '<': '&lt;', '>': '&gt;', '&': '&amp;', '"': '&quot;', "'": '&apos;' })[s]);
const concatQuote = (file) => `'${file.replaceAll("'", "'\\''")}'`;

function run(command, args) {
  const result = spawnSync(command, args, { encoding: 'utf8', maxBuffer: 32 * 1024 * 1024 });
  if (result.status !== 0) throw new Error(`${command} exited ${result.status}:\n${result.stderr}`);
  return result.stdout;
}

function getSharp() {
  try { return require('sharp'); } catch {
    return require(process.env.SHARP_MODULE || '/Users/yudonglu/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/sharp');
  }
}

/** Resolve actual timestamped screen captures into exact display durations. */
export async function expandCaptureManifests(config) {
  const expanded = structuredClone(config);
  if (!Array.isArray(expanded.scenes)) return expanded;
  for (const [index, scene] of expanded.scenes.entries()) {
    if (!scene.captureManifest) continue;
    if (scene.source || scene.frames || !path.isAbsolute(scene.captureManifest)) throw new Error(`Scene ${index + 1}: use one absolute captureManifest, not source/frames together.`);
    const bytes = await readFile(scene.captureManifest);
    const capture = JSON.parse(bytes);
    if (!Array.isArray(capture.frames) || capture.frames.length < 2 || !(capture.duration > 0)) throw new Error(`Scene ${index + 1}: capture needs multiple timestamped frames.`);
    if (capture.frames.some((frame, i) => !Number.isFinite(frame.t) || frame.t < 0 || (i && frame.t <= capture.frames[i - 1].t))) throw new Error(`Scene ${index + 1}: capture timestamps must strictly increase.`);
    if (capture.frames.at(-1).t >= capture.duration) throw new Error(`Scene ${index + 1}: capture duration must follow the last frame.`);
    const start = scene.startSeconds ?? capture.frames[0].t;
    const end = scene.endSeconds ?? capture.duration;
    if (!(end > start) || start < capture.frames[0].t || end > capture.duration || !(scene.durationSeconds > 0)) throw new Error(`Scene ${index + 1}: invalid selected source interval or delivery duration.`);
    const timingScale = (end - start) / scene.durationSeconds;
    scene.frames = capture.frames.flatMap((frame, i) => {
      if (path.basename(frame.file) !== frame.file) throw new Error('Capture frame files must be plain basenames beside the manifest.');
      const frameEnd = capture.frames[i + 1]?.t ?? capture.duration;
      const seconds = Math.min(frameEnd, end) - Math.max(frame.t, start);
      return seconds <= 0 ? [] : [{ path: path.join(path.dirname(scene.captureManifest), frame.file), durationSeconds: seconds / timingScale }];
    });
    scene.sourceUrl ||= capture.sourceUrl;
    scene.capturedAt ||= capture.capturedAt;
    scene.captureProvenance = {
      manifest: scene.captureManifest, manifestSha256: sha256(bytes), captureMethod: capture.captureMethod,
      selectedStartSeconds: start, selectedEndSeconds: end, timingScale,
      sourceDurationSeconds: capture.duration, sourceFrameCount: capture.frames.length,
      selectedFrameCount: scene.frames.length,
      fpsNote: 'Timestamped real production captures. Source frames are duplicated at delivery frame rate; no synthetic in-between UI frames.',
    };
    scene.startSeconds = 0;
    scene.speed = 1;
  }
  return expanded;
}

/** Fail closed on disconnected stocks, missing provenance, or false media. */
export function validateCapture(config) {
  if (!config || !Array.isArray(config.scenes) || config.scenes.length < 5 || config.scenes.length > 7) throw new Error('A research journey needs five to seven ordered scenes.');
  if (!config.guruName || String(config.guruName).length > 32) throw new Error('guruName is required (up to 32 characters).');
  if (!config.ticker || !/^[A-Z0-9.\-]{1,12}$/.test(config.ticker)) throw new Error('One verified ticker is required for the entire journey.');
  if (!config.holdingEvidence || String(config.holdingEvidence).trim().length < 16) throw new Error('holdingEvidence must explain the observed Guru-stock holding relationship.');
  if (!config.capturedAt || !Number.isFinite(Date.parse(config.capturedAt))) throw new Error('capturedAt must be a real ISO timestamp.');
  if (!config.outputDir || !path.isAbsolute(config.outputDir)) throw new Error('outputDir must be absolute.');
  const steps = [];
  for (const [index, scene] of config.scenes.entries()) {
    if (!Number.isInteger(scene.step) || scene.step < 0 || scene.step > 3 || (index && scene.step < config.scenes[index - 1].step)) throw new Error(`Scene ${index + 1}: step must progress from 0 through 3 without going backward.`);
    steps.push(scene.step);
    if (scene.ticker && scene.ticker !== config.ticker) throw new Error(`Scene ${index + 1}: stock differs from the journey ticker.`);
    if (!(scene.durationSeconds >= 2 && scene.durationSeconds <= 12) || Math.abs(scene.durationSeconds * FPS - Math.round(scene.durationSeconds * FPS)) > 1e-7) throw new Error(`Scene ${index + 1}: duration must be 2–12 seconds on a 30 fps boundary.`);
    for (const [key, limit] of [['instruction', 88], ['benefit', 105], ['dataDate', 95]]) {
      if (!scene[key] || String(scene[key]).length > limit || /\n/.test(scene[key])) throw new Error(`Scene ${index + 1}: ${key} must be one line, up to ${limit} characters.`);
    }
    if (!scene.sourceUrl || !/^https:\/\/(www\.)?thesisforge\.tech(?:\/|$)/.test(scene.sourceUrl)) throw new Error(`Scene ${index + 1}: source must be the real production website.`);
    if ((!scene.source && !scene.frames?.length) || (scene.source && scene.frames)) throw new Error(`Scene ${index + 1}: specify exactly one source or timestamped frame list.`);
    if (scene.source && !path.isAbsolute(scene.source)) throw new Error(`Scene ${index + 1}: source must be absolute.`);
    if (scene.mediaType && !['video', 'image'].includes(scene.mediaType)) throw new Error(`Scene ${index + 1}: invalid mediaType.`);
    if (scene.speed !== undefined && !(scene.speed > 0 && scene.speed <= 8)) throw new Error(`Scene ${index + 1}: invalid speed.`);
    if (scene.panels) throw new Error('Disconnected UI panels are prohibited; use one contiguous native crop.');
    if (scene.crop && !['x', 'y', 'width', 'height'].every((key) => Number.isInteger(scene.crop[key]) && scene.crop[key] >= (key === 'width' || key === 'height' ? 1 : 0))) throw new Error(`Scene ${index + 1}: invalid native crop.`);
    if (scene.frames) {
      const sum = scene.frames.reduce((total, frame) => {
        if (!path.isAbsolute(frame.path) || !(frame.durationSeconds > 0)) throw new Error(`Scene ${index + 1}: invalid timestamped frame.`);
        return total + frame.durationSeconds;
      }, 0);
      if (Math.abs(sum - scene.durationSeconds) > 0.001) throw new Error(`Scene ${index + 1}: frame durations do not equal scene duration.`);
    }
  }
  if (![0, 1, 2, 3].every((step) => steps.includes(step))) throw new Error('All four steps—Guru, stock, position history, valuation—must be shown.');
  const total = config.scenes.reduce((sum, scene) => sum + scene.durationSeconds, 0);
  if (total < 20 || total > 60) throw new Error('Total research journey must run 20–60 seconds.');
  return config;
}

function textSize(text, maximum, availableWidth, minimum = 18) {
  // Conservative em-width budget keeps deterministic external copy in its lane.
  return Math.max(minimum, Math.min(maximum, availableWidth / (String(text).length * 0.57)));
}

export function layerSvg(config, index, overlay = false) {
  const scene = config.scenes[index];
  const lanes = [
    { text: config.guruName, x: 397, width: 355 },
    { text: `$${config.ticker}`, x: 792, width: 240 },
    { text: 'Position history', x: 1072, width: 352 },
    { text: 'Valuation', x: 1464, width: 280 },
  ];
  const trail = lanes.map((lane, i) => {
    const active = scene.step === i;
    const done = scene.step > i;
    const color = active ? '#62D5B0' : done ? '#E3ECE9' : '#8190A3';
    return `<circle cx="${lane.x + 13}" cy="37" r="13" fill="${active ? '#62D5B0' : '#233043'}"/><text x="${lane.x + 13}" y="43" text-anchor="middle" font-size="16" font-weight="700" fill="${active ? '#09251B' : '#C2CCD9'}">${i + 1}</text><text x="${lane.x + 39}" y="45" font-size="${textSize(lane.text, 26, lane.width - 49)}" font-weight="${active ? 700 : 500}" fill="${color}">${xml(lane.text)}</text>${i < 3 ? `<text x="${lane.x + lane.width + 12}" y="45" font-size="26" fill="#506278">→</text>` : ''}${active ? `<rect x="${lane.x}" y="64" width="${lane.width}" height="3" rx="1.5" fill="#62D5B0"/>` : ''}`;
  }).join('');
  const progress = config.scenes.map((item, i) => `<rect x="${20 + i * (1880 / config.scenes.length)}" y="951" width="${1880 / config.scenes.length - 5}" height="3" fill="${i <= index ? '#62D5B0' : '#253145'}"/>`).join('');
  return Buffer.from(`<svg width="${W}" height="${H}" xmlns="http://www.w3.org/2000/svg"><style>text{font-family:Helvetica,Arial,sans-serif;}</style>${!overlay ? `<rect width="${W}" height="${H}" fill="#0B111A"/><rect x="${FRAME.x}" y="${FRAME.y}" width="${FRAME.width}" height="${FRAME.height}" fill="#0C121D"/>` : `<text x="82" y="45" font-size="28" font-weight="700" fill="#F1F6F8">ThesisForge</text>${trail}<text x="1900" y="79" text-anchor="end" font-size="15" fill="#7E8FA4">${xml(scene.dataDate)}</text>${progress}<text x="30" y="997" font-size="${textSize(scene.instruction, 33, 1810, 25)}" font-weight="700" fill="#F1F6F8">${xml(scene.instruction)}</text><text x="30" y="1030" font-size="${textSize(scene.benefit, 26, 1810, 21)}" fill="#B3C2D1">${xml(scene.benefit)}</text><text x="30" y="1065" font-size="17" fill="#7E8FA4">13F is delayed. Model values are estimates. Research only.</text><text x="1900" y="1065" text-anchor="end" font-size="19" font-weight="600" fill="#62D5B0">thesisforge.tech</text>`}</svg>`);
}

function imageInput(file, duration) { return ['-loop', '1', '-framerate', String(FPS), '-t', String(duration), '-i', file]; }

async function sourceMetadata(scene, ffprobe, sharp) {
  const files = [...new Set(scene.frames ? scene.frames.map((f) => f.path) : [scene.source])];
  const outputs = [];
  for (const file of files) {
    let width, height, duration;
    if (/\.(png|jpe?g|webp)$/i.test(file)) ({ width, height } = await sharp(file).metadata());
    else {
      const information = JSON.parse(run(ffprobe, ['-v', 'error', '-show_streams', '-show_format', '-of', 'json', file]));
      const stream = information.streams.find((s) => s.codec_type === 'video');
      if (!stream) throw new Error(`No visual stream in ${file}`);
      ({ width, height } = stream); duration = information.format.duration;
    }
    if (scene.crop && (scene.crop.x + scene.crop.width > width || scene.crop.y + scene.crop.height > height)) throw new Error(`Crop is outside ${file} (${width}×${height}).`);
    outputs.push({ path: file, bytes: (await stat(file)).size, sha256: sha256(await readFile(file)), width, height, duration: duration || null });
  }
  if (outputs.some((entry) => entry.width !== outputs[0].width || entry.height !== outputs[0].height)) throw new Error('All frames in one scene must have identical native dimensions.');
  return outputs;
}

export function srtTimestamp(seconds) {
  const milliseconds = Math.round(seconds * 1000);
  return `${String(Math.floor(milliseconds / 3600000)).padStart(2, '0')}:${String(Math.floor(milliseconds / 60000) % 60).padStart(2, '0')}:${String(Math.floor(milliseconds / 1000) % 60).padStart(2, '0')},${String(milliseconds % 1000).padStart(3, '0')}`;
}

export async function exportJourney(config) {
  config = await expandCaptureManifests(config);
  validateCapture(config);
  const ffmpeg = config.ffmpeg || 'ffmpeg';
  const ffprobe = config.ffprobe || 'ffprobe';
  const sharp = getSharp();
  const outputDir = config.outputDir;
  const assetsDir = path.join(outputDir, 'composition-assets');
  await mkdir(assetsDir, { recursive: true });
  const markPath = config.markSource || DEFAULT_MARK;
  const mark = await sharp(markPath).resize(46, 46, { fit: 'contain' }).png().toBuffer();
  const scenePaths = [], provenance = [], subtitles = [];
  let time = 0;
  for (const [index, scene] of config.scenes.entries()) {
    const duration = scene.durationSeconds;
    const metadata = await sourceMetadata(scene, ffprobe, sharp);
    const background = path.join(assetsDir, `scene-${index + 1}-background.png`);
    const overlay = path.join(assetsDir, `scene-${index + 1}-overlay.png`);
    await sharp(layerSvg(config, index)).png().toFile(background);
    await sharp(layerSvg(config, index, true)).composite([{ input: mark, left: 25, top: 12 }]).png().toFile(overlay);
    const args = ['-hide_banner', '-loglevel', 'warning', '-y'];
    if (scene.frames) {
      const listFile = path.join(assetsDir, `scene-${index + 1}-frames.ffconcat`);
      await writeFile(listFile, `ffconcat version 1.0\n${scene.frames.map((frame) => `file ${concatQuote(frame.path)}\nduration ${frame.durationSeconds}`).join('\n')}\nfile ${concatQuote(scene.frames.at(-1).path)}\n`);
      args.push('-f', 'concat', '-safe', '0', '-i', listFile);
    } else if (scene.mediaType === 'image' || /\.(png|jpe?g|webp)$/i.test(scene.source)) args.push(...imageInput(scene.source, duration));
    else {
      const available = Number(metadata[0].duration);
      const needed = duration * (scene.speed || 1);
      if (available && available + 0.05 < (scene.startSeconds || 0) + needed) throw new Error(`Scene ${index + 1}: source video is too short.`);
      args.push('-ss', String(scene.startSeconds || 0), '-t', String(needed), '-i', scene.source);
    }
    args.push(...imageInput(background, duration), ...imageInput(overlay, duration));
    const crop = scene.crop ? `crop=${scene.crop.width}:${scene.crop.height}:${scene.crop.x}:${scene.crop.y},` : '';
    const speed = scene.speed || 1;
    const filter = `[0:v]setpts=(PTS-STARTPTS)/${speed},${crop}fps=${FPS},scale=${FRAME.width}:${FRAME.height}:force_original_aspect_ratio=decrease:flags=lanczos,pad=${FRAME.width}:${FRAME.height}:(ow-iw)/2:(oh-ih)/2:color=0x0C121D,setsar=1,format=rgba[ui];[1:v][ui]overlay=${FRAME.x}:${FRAME.y}:shortest=1[framed];[framed][2:v]overlay=0:0:shortest=1,scale=out_range=tv:out_color_matrix=bt709,format=yuv420p,setparams=range=limited:color_primaries=bt709:color_trc=bt709:colorspace=bt709[out]`;
    const target = path.join(assetsDir, `scene-${index + 1}.mp4`);
    args.push('-filter_complex', filter, '-map', '[out]', '-an', '-frames:v', String(Math.round(duration * FPS)), '-r', String(FPS), '-c:v', 'libx264', '-preset', config.preset || 'medium', '-crf', '18', '-pix_fmt', 'yuv420p', '-color_range', 'tv', '-colorspace', 'bt709', '-color_primaries', 'bt709', '-color_trc', 'bt709', '-movflags', '+faststart', target);
    run(ffmpeg, args);
    scenePaths.push(target);
    subtitles.push(`${index + 1}\n${srtTimestamp(time)} --> ${srtTimestamp(time + duration)}\n${scene.instruction}\n${scene.benefit}\n`);
    provenance.push({
      index: index + 1, step: scene.step, ticker: config.ticker, startSeconds: time, durationSeconds: duration,
      sourceUrl: scene.sourceUrl, capturedAt: scene.capturedAt || config.capturedAt, dataDate: scene.dataDate,
      sourceType: scene.frames ? 'timestamped production screenshots' : (scene.mediaType || (/\.(png|jpe?g|webp)$/i.test(scene.source) ? 'image' : 'video')),
      sourceStartSeconds: scene.startSeconds || 0, playbackSpeed: speed,
      captureProvenance: scene.captureProvenance || null, crop: scene.crop || null, sources: metadata,
      instruction: scene.instruction, benefit: scene.benefit, notes: scene.notes || null,
      treatment: 'One contiguous unaltered production view per scene; proportional crop/scale only. External branding and explanatory text; no fabricated UI, controls, cursor, observations, or mouse actions.',
    });
    time += duration;
    console.log(`Rendered research-journey scene ${index + 1}/${config.scenes.length} (${duration}s).`);
  }
  const timeline = path.join(assetsDir, 'timeline.ffconcat');
  await writeFile(timeline, `ffconcat version 1.0\n${scenePaths.map((file) => `file ${concatQuote(file)}`).join('\n')}\n`);
  const output = path.join(outputDir, 'thesisforge-research-journey-en.mp4');
  run(ffmpeg, ['-hide_banner', '-loglevel', 'warning', '-y', '-f', 'concat', '-safe', '0', '-i', timeline, '-map', '0:v:0', '-an', '-t', String(time), '-c:v', 'copy', '-movflags', '+faststart', output]);
  const probe = JSON.parse(run(ffprobe, ['-v', 'error', '-show_streams', '-show_format', '-of', 'json', output]));
  const stream = probe.streams.find((s) => s.codec_type === 'video');
  const expectedFrames = Math.round(time * FPS);
  if (stream.width !== W || stream.height !== H || stream.codec_name !== 'h264' || stream.pix_fmt !== 'yuv420p' || Math.abs(Number(probe.format.duration) - time) > 0.05 || Number(stream.nb_frames) !== expectedFrames) throw new Error(`Output failed delivery checks: ${JSON.stringify(probe)}`);
  const poster = path.join(outputDir, 'thesisforge-research-journey-poster.jpg');
  const posterSeconds = config.posterSeconds ?? provenance.find((scene) => scene.step === 2).startSeconds + 1.5;
  if (!(posterSeconds >= 0 && posterSeconds < time)) throw new Error('posterSeconds falls outside the exported film.');
  run(ffmpeg, ['-hide_banner', '-loglevel', 'error', '-y', '-ss', String(posterSeconds), '-i', output, '-frames:v', '1', '-q:v', '2', poster]);
  const previewFrames = [];
  for (const scene of provenance) {
    const file = path.join(assetsDir, `review-${scene.index}.jpg`);
    run(ffmpeg, ['-hide_banner', '-loglevel', 'error', '-y', '-ss', String(scene.startSeconds + scene.durationSeconds * 0.6), '-i', output, '-frames:v', '1', '-q:v', '2', file]);
    previewFrames.push(file);
  }
  const contactSheet = path.join(outputDir, 'thesisforge-research-journey-review.jpg');
  const thumbWidth = 960, thumbHeight = 540;
  await sharp({ create: { width: thumbWidth * 2, height: thumbHeight * Math.ceil(previewFrames.length / 2), channels: 3, background: '#0B111A' } }).composite(await Promise.all(previewFrames.map(async (file, i) => ({ input: await sharp(file).resize(thumbWidth, thumbHeight).toBuffer(), left: (i % 2) * thumbWidth, top: Math.floor(i / 2) * thumbHeight })))).jpeg({ quality: 94 }).toFile(contactSheet);
  const srt = path.join(outputDir, 'thesisforge-research-journey-en.srt');
  await writeFile(srt, subtitles.join('\n'));
  const manifest = {
    title: `ThesisForge — ${config.guruName} to ${config.ticker}: position history and valuation`,
    generatedAt: new Date().toISOString(), capturedAt: config.capturedAt, guruName: config.guruName, ticker: config.ticker,
    holdingEvidence: config.holdingEvidence, productionVersion: config.productionVersion || null,
    dimensions: { width: W, height: H }, durationSeconds: time, frameRate: FPS, frameCount: expectedFrames,
    output, poster, contactSheet, subtitles: srt,
    sourceCaptureDescription: config.sourceCaptureDescription || 'See each scene source type and capture provenance.',
    sourcePreservation: { generatedUi: false, generatedFinancialData: false, generatedCursor: false, chartRetouching: false, disconnectedPanels: false, proportionalScalingOnly: true, finalCompression: 'H.264 delivery. Native source media retained.' },
    audio: 'Silent-first. Plain-English instructional subtitles burned in; no third-party music.',
    caveats: ['13F reports are delayed snapshots, not live transactions or exact trade dates.', 'Holding weight changes alone are not proof of buying; use reported share changes where describing adds.', 'Valuation is a dated model estimate, not a guaranteed return or necessarily a standalone DCF.', 'Position history and portfolio simulation are different series; do not describe either as actual fund return.', 'One verified Guru-stock link is retained throughout the walkthrough.'],
    scenes: provenance,
    hashes: { logoSha256: sha256(await readFile(markPath)), videoSha256: sha256(await readFile(output)), posterSha256: sha256(await readFile(poster)), subtitleSha256: sha256(await readFile(srt)) },
    technicalVerification: { codec: stream.codec_name, pixelFormat: stream.pix_fmt, duration: probe.format.duration, frameCount: stream.nb_frames, averageFrameRate: stream.avg_frame_rate, fastStart: true },
  };
  const manifestPath = path.join(outputDir, 'thesisforge-research-journey-manifest.json');
  await writeFile(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
  await writeFile(path.join(outputDir, 'PROVENANCE.md'), `# ThesisForge research journey\n\nGenerated: ${manifest.generatedAt}\n\n${manifest.sourceCaptureDescription}\n\n## Coherent example\n\n${config.guruName} → ${config.ticker} → reported position history → valuation of ${config.ticker}.\n\nHolding evidence: ${config.holdingEvidence}\n\n## Delivery\n\n- ${time} seconds; ${W} × ${H}; ${FPS} fps; H.264 / yuv420p / fast start.\n- Source dates remain distinct from capture date.\n- Source UI, charts, axes, figures and logos remain unaltered. A single native crop may be proportionally scaled per scene.\n- No generated cursor, fake click, inserted UI, or disconnected panel collage.\n- Source types, original timestamps, timing scales, crops and SHA-256 hashes are in the manifest.\n- Plain-English captions explain the actual operation and its benefit; no financial recommendation.\n- No posting, deployment or account data mutation is performed by this exporter.\n\n## Review checklist\n\nAutomatic codec/frame/duration checks passed. Review all contact-sheet frames and play the full video: verify the same ticker, visible quarter/axis/legend context, readable English text, exact reported-share wording, model-estimate labels, privacy and no unexpected cuts.\n`);
  return { output, poster, contactSheet, manifestPath, subtitles: srt, durationSeconds: time };
}

if (import.meta.url === pathToFileURL(process.argv[1] || '').href) {
  if (!process.argv[2] || process.argv[2] === '--help') {
    console.log(`Usage: node scripts/export-thesisforge-research-journey.mjs /absolute/capture.json\n\nRequired config: outputDir, capturedAt, guruName, ticker, holdingEvidence, scenes.\nFive to seven ordered scenes must include steps 0 (Guru), 1 (stock), 2 (history),\n3 (valuation). Each scene: durationSeconds (2–12), step, instruction (88 chars),\nbenefit (105 chars), dataDate (95 chars), production sourceUrl, and one of:\n  source: absolute video/image path; optional mediaType, startSeconds, speed\n  frames: [{path:absolutePath,durationSeconds:number},...]\n  captureManifest: absolute capture JSON; optional startSeconds/endSeconds\nCapture JSON: {frames:[{file:basename,t:number},...],duration:number,sourceUrl,\ncapturedAt,captureMethod}. A single crop {x,y,width,height} is optional.\nDo not use panels, old footage fallback, invented chart data or unrelated stocks.\nOptional: productionVersion, sourceCaptureDescription, posterSeconds, preset.\nOutput: 1920×1080 MP4, SRT, poster, contact sheet, manifest and provenance.\n`);
  } else {
    const config = JSON.parse(await readFile(path.resolve(process.argv[2]), 'utf8'));
    console.log(JSON.stringify(await exportJourney(config), null, 2));
  }
}
