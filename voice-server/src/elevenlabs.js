// ElevenLabs turns the finished readout text into an MP3.
//
// Every MP3 is also saved in audio-cache/, named by a hash of the text, language and
// voice. Playing the same readout again costs no ElevenLabs credits.

import crypto from 'crypto';
import fs from 'fs/promises';

// "Sarah - Mature, Reassuring". A built-in voice, so it works on the free plan
// (free accounts can't use Voice Library voices through the API).
const DEFAULT_VOICE_ID = 'EXAVITQu4vr4xnSDxMaL';
const CACHE_DIR = new URL('../audio-cache/', import.meta.url);

export async function textToSpeech(text, lang) {
  if (!process.env.ELEVENLABS_API_KEY) {
    throw new Error('ELEVENLABS_API_KEY is not set in .env');
  }
  const voiceId = process.env.ELEVENLABS_VOICE_ID || DEFAULT_VOICE_ID;
  const model = process.env.ELEVENLABS_MODEL || 'eleven_flash_v2_5';

  const hash = crypto.createHash('sha256').update(`${voiceId}|${model}|${lang}|${text}`).digest('hex');
  const cacheFile = new URL(`${hash}.mp3`, CACHE_DIR);
  try {
    return await fs.readFile(cacheFile);
  } catch {
    // Not cached yet.
  }

  const res = await fetch(
    `https://api.elevenlabs.io/v1/text-to-speech/${voiceId}?output_format=mp3_44100_128`,
    {
      method: 'POST',
      headers: {
        'xi-api-key': process.env.ELEVENLABS_API_KEY,
        'Content-Type': 'application/json',
        Accept: 'audio/mpeg',
      },
      body: JSON.stringify({
        text,
        model_id: model,
        language_code: lang, // tells the model which language to speak
      }),
    }
  );
  if (!res.ok) throw new Error(`ElevenLabs ${res.status}: ${await res.text()}`);

  const mp3 = Buffer.from(await res.arrayBuffer());
  await fs.mkdir(CACHE_DIR, { recursive: true });
  await fs.writeFile(cacheFile, mp3);
  return mp3;
}
