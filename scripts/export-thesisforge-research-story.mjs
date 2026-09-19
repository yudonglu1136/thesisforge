/** Story-led edit aligned to one continuous neural narration, not fixed voice slots. */
import { readFile, writeFile, mkdir, copyFile, stat } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { exportJourney } from './export-thesisforge-research-journey.mjs';

const root = path.resolve(import.meta.dirname, '..');
const baseDirectory = path.join(root, 'output/thesisforge-research-journey-2026-09-05');
const storyDirectory = path.join(root, 'output/thesisforge-research-story-2026-09-05');
const run = (cmd, args) => {
  const result = spawnSync(cmd, args, { encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 });
  if (result.status !== 0) throw new Error(`${cmd} failed: ${result.stderr}`);
  return result.stdout;
};
const probe = file => JSON.parse(run('ffprobe', ['-v', 'error', '-show_streams', '-show_format', '-of', 'json', file]));
const hash = async file => createHash('sha256').update(await readFile(file)).digest('hex');
const timestamp = text => {
  const match = text.match(/^(\d+):(\d+):(\d+),(\d+)$/);
  if (!match) throw new Error(`Invalid subtitle time: ${text}`);
  return Number(match[1]) * 3600 + Number(match[2]) * 60 + Number(match[3]) + Number(match[4]) / 1000;
};

export function parseSrt(text) {
  return text.trim().split(/\r?\n\s*\r?\n/).map(block => {
    const lines = block.split(/\r?\n/);
    const [start, end] = lines[1].split(' --> ').map(timestamp);
    if (!(end > start)) throw new Error('Invalid subtitle interval.');
    return { start, end, text: lines.slice(2).join(' ') };
  });
}

export function storyBoundaries(cues, duration) {
  const indexes = [0, 1, 3, 5, 6, 8, 9];
  const expected = ['Would you buy', 'First, pick', 'Rewind the quarters', 'Check the reported', "But here's", 'Compare market price', "A billionaire's"];
  if (cues.length !== 14 || indexes.some((index, i) => !cues[index].text.startsWith(expected[i]))) throw new Error('Neural sentence boundaries do not match the approved story.');
  if (cues.some((cue, i) => i && cue.start < cues[i - 1].end - 0.002)) throw new Error('Overlapping speech cues.');
  const frames = [0, ...indexes.slice(1).map(index => Math.round(cues[index].start * 30)), Math.ceil((duration + 0.4) * 30)];
  if (frames.some((frame, i) => i && (frame - frames[i - 1] < 60 || frame - frames[i - 1] > 360))) throw new Error('Story scene outside 2–12 seconds.');
  return frames;
}

export async function exportStory(voice = 'brian') {
  if (!['brian', 'andrew'].includes(voice)) throw new Error('Only the generated neural voice sources are accepted.');
  const directory = path.join(storyDirectory, voice);
  await mkdir(directory, { recursive: true });
  const speech = path.join(storyDirectory, `audio/${voice}-full.mp3`);
  const speechSubtitles = path.join(storyDirectory, `audio/${voice}-full.srt`);
  const cues = parseSrt(await readFile(speechSubtitles, 'utf8'));
  const voiceDuration = Number(probe(speech).format.duration);
  const boundaries = storyBoundaries(cues, voiceDuration);
  const config = JSON.parse(await readFile(path.join(baseDirectory, 'capture-plan.json'), 'utf8'));
  config.outputDir = directory;
  config.posterSeconds = boundaries[5] / 30 + 2;
  config.sourceCaptureDescription = 'Re-edited from the preserved September 5 production captures. Continuous neural narration determines the cut points. No new UI/data is synthesized.';
  const instructions = [
    'Ackman owns it. Should you?',
    'Start with UBER.',
    'A position tells a story.',
    'More shares. What happened to the price?',
    'His holding. Your entry price.',
    'Price is visible. Value needs a model.',
    'An idea from Ackman. A decision by you.',
  ];
  const benefits = [
    'A famous investor can give you a lead. The next step is your own research.',
    'Open Position History. Select the stock you want to understand.',
    'Rewind the quarters. Compare reported weights and values—not assumed purchases.',
    'Check reported changes against price history. A filing is not a real-time trade alert.',
    'Take the same stock into Valuation. Ask what price makes sense to you.',
    'Compare the market with the estimate. Then inspect what drives it.',
    'ThesisForge · Follow the idea. Do the research. · thesisforge.tech',
  ];
  config.scenes.forEach((scene, index) => {
    scene.durationSeconds = (boundaries[index + 1] - boundaries[index]) / 30;
    scene.instruction = instructions[index];
    scene.benefit = benefits[index];
  });
  // Enter on the already chosen manager; the preceding click is in the archived source.
  config.scenes[0].startSeconds = 3;
  // Keep the actual result click/scroll but shorten the search lead-in, never use the stale curve.
  config.scenes[3].startSeconds = 3.7;
  // A transparent jump cut removes the loading wait. The complete original remains archived;
  // this edit makes no claim about production latency or one-click stock carry-over.
  config.scenes[4].startSeconds = 6;
  config.scenes[4].notes = 'Enter on the verified fully loaded UBER Valuation view. The preceding navigation/search/loading wait is omitted as an editorial jump cut, not an instantaneous-navigation or performance claim.';
  await writeFile(path.join(directory, 'capture-plan.json'), `${JSON.stringify(config, null, 2)}\n`);
  const visual = await exportJourney(config);
  const total = boundaries.at(-1) / 30;
  const delivery = path.join(directory, `thesisforge-compelling-en-${voice}.mp4`);
  run('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-y', '-i', visual.output, '-i', speech,
    '-map', '0:v:0', '-map', '1:a:0', '-c:v', 'copy',
    '-af', `loudnorm=I=-16:TP=-1.5:LRA=11,apad,atrim=duration=${total}`,
    '-c:a', 'aac', '-b:a', '192k', '-ar', '48000', '-ac', '1', '-t', String(total), '-movflags', '+faststart', delivery]);
  const final = probe(delivery);
  const video = final.streams.find(stream => stream.codec_type === 'video');
  const audio = final.streams.find(stream => stream.codec_type === 'audio');
  if (Number(video.nb_frames) !== boundaries.at(-1) || Math.abs(Number(final.format.duration) - total) > 0.05 || audio.codec_name !== 'aac') throw new Error('Final audiovisual duration/codec mismatch.');
  const decodedHash = file => run('ffmpeg', ['-v', 'error', '-i', file, '-map', '0:v:0', '-f', 'hash', '-hash', 'sha256', '-']).trim();
  const unchangedVideo = decodedHash(visual.output) === decodedHash(delivery);
  if (!unchangedVideo) throw new Error('Audio mux changed video frames.');
  run('ffmpeg', ['-v', 'error', '-i', delivery, '-f', 'null', '-']);
  await copyFile(speechSubtitles, path.join(directory, 'spoken-subtitles-en.srt'));
  const metadata = {
    generatedAt: new Date().toISOString(), delivery, bytes: (await stat(delivery)).size,
    voice: `en-US-${voice === 'brian' ? 'Brian' : 'Andrew'}MultilingualNeural`,
    speechService: 'Microsoft Edge neural TTS accessed through edge-tts; synthetic stock voice, not a human recording or a clone.',
    synthesisRate: '-2%', audioTimeStretch: false, narrationMode: 'One continuous take; no sentence-by-sentence voice splicing.',
    voiceDurationSeconds: voiceDuration, finalDurationSeconds: total, sceneBoundariesFrames: boundaries,
    speech, speechSha256: await hash(speech), spokenText: await readFile(path.join(storyDirectory, 'narration-en.txt'), 'utf8'),
    speechSubtitles, speechSubtitleSha256: await hash(speechSubtitles), deliverySha256: await hash(delivery),
    unchangedVideo, nativeSourceManifest: visual.manifestPath,
    technicalChecks: { fullDecode: true, frames: video.nb_frames, width: video.width, height: video.height, videoCodec: video.codec_name, audioCodec: audio.codec_name },
    listeningLimitation: 'Assistant audio-input playback was unavailable. Audio was checked technically; naturalness is for user review, not claimed as a human listening test.',
    dataCaveats: ['Dated platform estimates and reported holdings only.', 'Weight changes are not purchases.', 'Reported share deltas have corporate-action validation pending.', 'Model values are not independently validated or guaranteed returns.'],
  };
  await writeFile(path.join(directory, 'narration-manifest.json'), `${JSON.stringify(metadata, null, 2)}\n`);
  await writeFile(path.join(directory, 'AUDIO-PROVENANCE.md'), `# Neural narration\n\nGenerated stock voice: ${metadata.voice}. This is synthetic narration, not a voice clone or a human recording.\n\nOne continuous take replaces the prior macOS Samantha voice. Cut points follow actual sentence timestamps. No audio time stretching, artificial pitch changes, added music, or fabricated investment claims.\n\nSource software: [edge-tts maintainer documentation](https://github.com/rany2/edge-tts). The approved promotional text alone was submitted for synthesis; no credentials, private data or raw research datasets.\n\nTechnical audio/video checks are recorded in narration-manifest.json. Naturalness has not been falsely represented as a human listening test.\n`);
  return { delivery, durationSeconds: total, poster: visual.poster, contactSheet: visual.contactSheet, manifest: path.join(directory, 'narration-manifest.json') };
}

if (import.meta.url === pathToFileURL(process.argv[1] || '').href) console.log(JSON.stringify(await exportStory(process.argv[2] || 'brian'), null, 2));
