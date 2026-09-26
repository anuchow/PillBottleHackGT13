// Pill Point voice server.
//
//   POST /readout   { prescription, language, lastTakenAt?, timeZone?, audio? }
//     -> { language, text, sentences, audio (base64 MP3) }
//   POST /readout?format=mp3   -> the MP3 file itself (handy for testing)
//   POST /prescriptions        { ...prescription fields, key }  save/update a scanned bottle
//   POST /doses                { prescriptionKey, takenAt?, overrodeWarning? }
//   GET  /prescriptions/:key/daily?days=7   doses per day (daily_doses aggregate)
//   GET  /languages
//   GET  /health

import 'dotenv/config';
import express from 'express';
import { LANGUAGES, resolveLanguage } from './templates.js';
import { buildReadout } from './readout.js';
import { textToSpeech } from './elevenlabs.js';
import { db } from './db.js';
import { savePrescription, logDose, lastDose, dailyDoses } from './records.js';

const app = express();
app.use(express.json());

// Shows which keys are set (true/false) without revealing them.
app.get('/health', (req, res) => {
  res.json({
    ok: true,
    elevenlabs: Boolean(process.env.ELEVENLABS_API_KEY),
    grok: Boolean(process.env.XAI_API_KEY),
    database: Boolean(process.env.DATABASE_URL),
    appToken: Boolean(process.env.APP_TOKEN),
  });
});

// If APP_TOKEN is set in .env, every other request must send it in the X-App-Token
// header. This stops strangers from using our ElevenLabs/xAI credits once hosted.
app.use((req, res, next) => {
  if (process.env.APP_TOKEN && req.get('X-App-Token') !== process.env.APP_TOKEN) {
    return res.status(401).json({ error: 'Missing or wrong X-App-Token' });
  }
  next();
});

// Simple rate limit: at most 30 requests per minute from one address.
const recent = new Map();
app.use((req, res, next) => {
  const now = Date.now();
  const hits = (recent.get(req.ip) ?? []).filter((t) => now - t < 60_000);
  if (hits.length >= 30) return res.status(429).json({ error: 'Too many requests, try again in a minute' });
  recent.set(req.ip, [...hits, now]);
  next();
});

app.get('/languages', (req, res) => {
  res.json(Object.entries(LANGUAGES).map(([code, t]) => ({ code, name: t.name })));
});

app.post('/readout', async (req, res) => {
  const { prescription, lastTakenAt, timeZone, audio = true } = req.body ?? {};
  const language = resolveLanguage(req.body?.language);

  if (!prescription?.drugName) {
    return res.status(400).json({ error: 'prescription.drugName is required' });
  }
  if (!language) {
    return res.status(400).json({ error: `language must be one of: ${Object.keys(LANGUAGES).join(', ')}` });
  }

  try {
    // If the app didn't send the last dose, look it up in Tiger.
    let lastTaken = lastTakenAt;
    if (!lastTaken && prescription.key && db) {
      lastTaken = await lastDose(prescription.key).catch(() => null);
    }

    const readout = await buildReadout(prescription, language, { lastTakenAt: lastTaken, timeZone });

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

// --- Records in Tiger Cloud -------------------------------------------------

function needsDatabase(req, res, next) {
  if (!db) return res.status(503).json({ error: 'DATABASE_URL is not set in .env' });
  next();
}

app.post('/prescriptions', needsDatabase, async (req, res) => {
  const rx = req.body ?? {};
  if (!rx.key || !rx.drugName) return res.status(400).json({ error: 'key and drugName are required' });
  try {
    await savePrescription(rx);
    res.json({ saved: rx.key });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: err.message });
  }
});

app.post('/doses', needsDatabase, async (req, res) => {
  const { prescriptionKey, takenAt, overrodeWarning } = req.body ?? {};
  if (!prescriptionKey) return res.status(400).json({ error: 'prescriptionKey is required' });
  try {
    await logDose(prescriptionKey, takenAt, overrodeWarning);
    res.json({ logged: true });
  } catch (err) {
    // 23503 = the prescription hasn't been saved with POST /prescriptions yet.
    if (err.code === '23503') return res.status(404).json({ error: 'Unknown prescriptionKey; save the prescription first' });
    console.error(err);
    res.status(500).json({ error: err.message });
  }
});

app.get('/prescriptions/:key/daily', needsDatabase, async (req, res) => {
  const days = Math.min(Number(req.query.days) || 7, 90);
  try {
    res.json(await dailyDoses(req.params.key, days));
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: err.message });
  }
});

const port = process.env.PORT || 3000;
app.listen(port, () => console.log(`Voice server running on http://localhost:${port}`));
