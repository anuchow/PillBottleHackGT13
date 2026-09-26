// ElevenLabs turns the finished readout text into an MP3.

// "Sarah - Mature, Reassuring". A built-in voice, so it works on the free plan
// (free accounts can't use Voice Library voices through the API).
const DEFAULT_VOICE_ID = 'EXAVITQu4vr4xnSDxMaL';

export async function textToSpeech(text, lang) {
  if (!process.env.ELEVENLABS_API_KEY) {
    throw new Error('ELEVENLABS_API_KEY is not set in .env');
  }
  const voiceId = process.env.ELEVENLABS_VOICE_ID || DEFAULT_VOICE_ID;

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
        model_id: process.env.ELEVENLABS_MODEL || 'eleven_flash_v2_5',
        language_code: lang, // tells the model which language to speak
      }),
    }
  );
  if (!res.ok) throw new Error(`ElevenLabs ${res.status}: ${await res.text()}`);

  return Buffer.from(await res.arrayBuffer());
}
