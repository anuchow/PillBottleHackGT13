// Pill Point voice server.
//
//   POST /readout   { prescription, language, lastTakenAt?, timeZone?, audio? }
//     -> { language, text, sentences, audio (base64 MP3) }
//   POST /readout?format=mp3   -> the MP3 file itself (handy for testing)
//   GET  /languages
//   GET  /health

import 'dotenv/config';
import express from 'express';
import { LANGUAGES } from './templates.js';
import { buildReadout } from './readout.js';
import { textToSpeech } from './elevenlabs.js';

const app = express();
app.use(express.json());

// Shows which keys are set (true/false) without revealing them.
app.get('/health', (req, res) => {
  res.json({
    ok: true,
    elevenlabs: Boolean(process.env.ELEVENLABS_API_KEY),
    grok: Boolean(process.env.XAI_API_KEY),
    database: Boolean(process.env.DATABASE_URL),
  });
});

app.get('/languages', (req, res) => {
  res.json(Object.entries(LANGUAGES).map(([code, t]) => ({ code, name: t.name })));
});

app.post('/readout', async (req, res) => {
  const { prescription, language = 'en', lastTakenAt, timeZone, audio = true } = req.body ?? {};

  if (!prescription?.drugName) {
    return res.status(400).json({ error: 'prescription.drugName is required' });
  }
  if (!LANGUAGES[language]) {
    return res.status(400).json({ error: `language must be one of: ${Object.keys(LANGUAGES).join(', ')}` });
  }

  try {
    const readout = await buildReadout(prescription, language, { lastTakenAt, timeZone });

    if (req.query.format === 'mp3') {
      const mp3 = await textToSpeech(readout.text, language);
      return res.type('audio/mpeg').send(mp3);
    }

    if (audio) {
      try {
        readout.audio = (await textToSpeech(readout.text, language)).toString('base64');
      } catch (err) {
        // Still return the text so the app can fall back to the phone's built-in voice.
        readout.audioError = err.message;
      }
    }
    res.json(readout);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: err.message });
  }
});

const port = process.env.PORT || 3000;
app.listen(port, () => console.log(`Voice server running on http://localhost:${port}`));
