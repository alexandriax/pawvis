// Generates narration WAVs with OpenAI TTS.
// Key comes from $OPENAI_API_KEY, or from the repo-root .env (which is gitignored).
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { execSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const envPath = resolve(here, '../../.env');
let key = process.env.OPENAI_API_KEY;
if (!key && existsSync(envPath)) {
  key = readFileSync(envPath, 'utf8')
    .match(/^OPENAI_API_KEY=(.+)$/m)?.[1]?.trim().replace(/^["']|["']$/g, '');
}
if (!key) { console.error(`no OPENAI_API_KEY (env var or ${envPath})`); process.exit(1); }

const VOICE = 'nova';
const INSTRUCTIONS = `Warm, bright, confident female product-demo narrator with an easy smile in the voice.
Playful but professional — think a polished launch video. Medium pace, crisp articulation,
light emphasis on product names and feature words. "Pawvis" is pronounced PAW-viss.`;

const segs = JSON.parse(readFileSync('segments.json', 'utf8'));

for (const s of segs) {
  const res = await fetch('https://api.openai.com/v1/audio/speech', {
    method: 'POST',
    headers: { Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      model: 'gpt-4o-mini-tts',
      voice: VOICE,
      input: s.text,
      instructions: INSTRUCTIONS,
      response_format: 'wav',
      speed: 1.0,
    }),
  });
  if (!res.ok) { console.error(s.id, res.status, await res.text()); process.exit(1); }
  const buf = Buffer.from(await res.arrayBuffer());
  const f = `audio/${s.id}.wav`;
  writeFileSync(f, buf);
  const d = execSync(`ffprobe -v error -show_entries format=duration -of csv=p=0 ${f}`).toString().trim();
  console.log(`${s.id}\t${d}`);
}
