/** Local synthetic narration with per-scene timing; never replaces silent video. */
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdir, readFile, writeFile, stat } from 'node:fs/promises';
import path from 'node:path';

const input = path.resolve(process.argv[2]);
const plan = JSON.parse(await readFile(input, 'utf8'));
const run = (cmd, args) => {
  const result = spawnSync(cmd, args, { encoding: 'utf8', maxBuffer: 8 * 1024 * 1024 });
  if (result.status !== 0) throw new Error(`${cmd}: ${result.stderr}`);
  return result.stdout;
};
const probe = (file) => JSON.parse(run('ffprobe', ['-v', 'error', '-show_streams', '-show_format', '-of', 'json', file]));
const hash = async (file) => createHash('sha256').update(await readFile(file)).digest('hex');
const directory = plan.outputDir;
if (!path.isAbsolute(directory) || !path.isAbsolute(plan.silentVideo)) throw new Error('Absolute output and source paths required.');
if (plan.voice !== 'Samantha' || plan.language !== 'en-US') throw new Error('Only the approved locally installed Samantha English voice is supported.');
if (plan.segments.length !== 7 || plan.segments.some((s) => !s.text || !(s.durationSeconds >= 2))) throw new Error('Seven exact narration scenes are required.');
await mkdir(directory, { recursive: true });
const segments = [];
let startSeconds = 0;
for (const [index, scene] of plan.segments.entries()) {
  const number = index + 1;
  const source = path.join(directory, `scene-${number}-samantha.aiff`);
  const spoken = path.join(directory, `scene-${number}.wav`);
  const textFile = path.join(directory, `scene-${number}.txt`);
  await writeFile(textFile, `${scene.text}\n`);
  const maximumSpeechSeconds = scene.durationSeconds - 0.35;
  let rate = plan.baseRate || 155;
  let duration = 0;
  for (let attempt = 0; attempt < 6; attempt++) {
    run('/usr/bin/say', ['-v', plan.voice, '-r', String(rate), '-f', textFile, '-o', source]);
    duration = Number(probe(source).format.duration);
    if (duration <= maximumSpeechSeconds && (duration >= maximumSpeechSeconds - 0.3 || rate <= 135)) break;
    const projectedRate = Math.ceil(rate * duration / (maximumSpeechSeconds - 0.12));
    rate = Math.min(190, Math.max(135, duration > maximumSpeechSeconds ? Math.max(rate + 5, projectedRate) : projectedRate));
  }
  if (duration > maximumSpeechSeconds) throw new Error(`Scene ${number}: speech ${duration}s exceeds ${maximumSpeechSeconds}s; never truncate words.`);
  // Preserve the voice signal; pause before it as needed so it ends 0.2s before the next cut.
  const leadSeconds = scene.durationSeconds - duration - 0.2;
  run('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-y', '-i', source, '-af', `adelay=${Math.round(leadSeconds * 1000)}:all=1,apad,atrim=duration=${scene.durationSeconds}`, '-ar', '48000', '-ac', '1', '-c:a', 'pcm_s16le', spoken]);
  segments.push({ number, text: scene.text, startSeconds, durationSeconds: scene.durationSeconds, voice: plan.voice, rateWordsPerMinute: rate, speechDurationSeconds: duration, leadSeconds, trailingSilenceSeconds: 0.2, source, sourceSha256: await hash(source), output: spoken, outputSha256: await hash(spoken) });
  startSeconds += scene.durationSeconds;
  console.log(`Narrated scene ${number}: ${duration.toFixed(2)}s speech at ${rate} wpm; ${scene.durationSeconds}s slot.`);
}
const joined = path.join(directory, 'narration.wav');
const args = ['-hide_banner', '-loglevel', 'error', '-y'];
segments.forEach((segment) => args.push('-i', segment.output));
args.push('-filter_complex', `${segments.map((_, i) => `[${i}:a]`).join('')}concat=n=${segments.length}:v=0:a=1,alimiter=limit=0.9:level=false[a]`, '-map', '[a]', '-ar', '48000', '-ac', '1', '-c:a', 'pcm_s16le', joined);
run('ffmpeg', args);
const audioDuration = Number(probe(joined).format.duration);
if (Math.abs(audioDuration - startSeconds) > 0.005) throw new Error('Narration timing failed.');
const output = path.join(path.dirname(directory), 'thesisforge-research-journey-en-narrated.mp4');
const sourceProbe = probe(plan.silentVideo);
if (Math.abs(Number(sourceProbe.format.duration) - startSeconds) > 0.05) throw new Error('Silent video duration and narration differ.');
run('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-y', '-i', plan.silentVideo, '-i', joined, '-map', '0:v:0', '-map', '1:a:0', '-c:v', 'copy', '-c:a', 'aac', '-b:a', '160k', '-t', String(startSeconds), '-movflags', '+faststart', output]);
const finalProbe = probe(output);
const videoStream = finalProbe.streams.find((s) => s.codec_type === 'video');
const audioStream = finalProbe.streams.find((s) => s.codec_type === 'audio');
if (videoStream.codec_name !== 'h264' || Number(videoStream.nb_frames) !== 1050 || audioStream.codec_name !== 'aac' || Math.abs(Number(finalProbe.format.duration) - 35) > 0.05) throw new Error('Narrated delivery verification failed.');
const decodedVideoHash = (file) => run('ffmpeg', ['-v', 'error', '-i', file, '-map', '0:v:0', '-f', 'hash', '-hash', 'sha256', '-']).trim();
const visualHash = decodedVideoHash(plan.silentVideo);
if (decodedVideoHash(output) !== visualHash) throw new Error('Narrated mux changed decoded video frames.');
const manifest = {
  createdAt: new Date().toISOString(), output, bytes: (await stat(output)).size,
  synthesis: 'Locally generated synthetic English narration using macOS say / Samantha; no voice cloning, third-party music or background audio.',
  voice: plan.voice, language: plan.language, durationSeconds: startSeconds,
  inputPlan: input, inputPlanSha256: await hash(input), silentVideo: plan.silentVideo,
  silentVideoSha256: await hash(plan.silentVideo), narratedVideoSha256: await hash(output),
  narration: joined, narrationSha256: await hash(joined), decodedVideoSha256: visualHash,
  exactSourceFramesRetained: true, codec: { video: videoStream.codec_name, audio: audioStream.codec_name, frames: videoStream.nb_frames, pixelFormat: videoStream.pix_fmt },
  segments,
};
await writeFile(path.join(directory, 'narration-manifest.json'), `${JSON.stringify(manifest, null, 2)}\n`);
await writeFile(path.join(directory, 'PROVENANCE.md'), `# Optional English narration\n\n${manifest.synthesis}\n\n- Source silent video remains unchanged.\n- Same 35 seconds and 1,050 decoded video frames; independent decoded-frame SHA-256 equality passed.\n- Narration is timed separately to each of seven scenes, with a 0.2-second trailing pause.\n- English action/benefit captions in the source video are unchanged.\n- Each segment is measured; speech is never cut off or accelerated with pitch shifting.\n- Output uses H.264 video stream copy and AAC audio.\n- No guaranteed returns or exact intra-quarter purchase dates are claimed.\n- Full wording, timing, source hashes and narration settings: narration-manifest.json.\n`);
console.log(JSON.stringify({ output, audio: joined, durationSeconds: startSeconds, videoFrameEquality: true, manifest: path.join(directory, 'narration-manifest.json') }, null, 2));
