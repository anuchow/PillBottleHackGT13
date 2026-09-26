# Pill Point Voice Server

Reads a scanned prescription aloud in **English, Spanish, Hindi, Chinese, Vietnamese, Korean,
French, and Arabic**, for visually impaired and non-English-speaking users. The app's language
codes work as-is (`zh-Hans`, `es-MX`, …).

**Connecting the iOS app:** see [ios/INTEGRATION.md](ios/INTEGRATION.md).
**Open problems:** see [KNOWN_ISSUES.txt](KNOWN_ISSUES.txt).

The iOS app sends a prescription (the same fields as `Prescription.swift`) and gets back the
readout text plus an MP3.

## How it works

1. **Hand-written templates** ([src/templates.js](src/templates.js)) cover the dose and timing:
   "Take 1 tablet. Twice a day." Numbers are dropped into fixed sentences as digits,
   so "every 8 hours" can never be mistranslated.
2. **Grok (xAI)** ([src/grok.js](src/grok.js)) translates only the label text the templates
   don't cover, like warning stickers or "as needed for pain". If Grok changes any number,
   its answer is thrown away and the English is read instead. Each translation is followed by
   the original English as a safety check.
3. **Tiger Cloud** stores translations so each label line is only sent to Grok once, plus the
   prescriptions, a `dose_logs` hypertable, and a `daily_doses` continuous aggregate
   (refreshes every 15 minutes). See [db/schema.sql](db/schema.sql).
4. **ElevenLabs** ([src/elevenlabs.js](src/elevenlabs.js)) turns the text into speech.
   Each MP3 is cached in `audio-cache/`, so replaying a readout costs no credits.
   If it fails, the text is still returned so the phone's built-in voice can read it.

The Rx number is never read aloud.

## Setup

Requires Node.js 18+.

```bash
cd voice-server
npm install
cp .env.example .env     # Windows: copy .env.example .env
```

Fill in `.env` with your own keys (never commit it):

| Setting | Where to get it |
|---|---|
| `ELEVENLABS_API_KEY` | elevenlabs.io → Developers → API Keys (needs Text to Speech + Voices: Read) |
| `XAI_API_KEY` | console.x.ai → API Keys |
| `DATABASE_URL` | `tiger service get <service-id> --with-password` |
| `APP_TOKEN` | Optional. Any made-up password; the app must send it as `X-App-Token`. Set it before hosting publicly. |

The database tables are created by running `db/schema.sql` once on the Tiger service.

```bash
npm start          # or: npm run dev (restarts on changes)
```

## API

**`POST /readout`**

```json
{
  "language": "es",
  "lastTakenAt": "2026-09-26T08:15:00-04:00",
  "prescription": {
    "drugName": "LISINOPRIL",
    "dosage": "10 MG TABLET",
    "instructions": "TAKE 1 TABLET BY MOUTH TWICE DAILY WITH FOOD",
    "timesOfDay": ["morning", "evening"],
    "sideEffects": ["MAY CAUSE DIZZINESS"]
  }
}
```

Returns `{ language, text, sentences, audio }`. `audio` is a base64 MP3. Each sentence is tagged
`template`, `grok`, or `english`. Add `?format=mp3` to get the MP3 file directly, or send
`"audio": false` for text only. If `lastTakenAt` is left out and `prescription.key` is sent,
the last dose is looked up in Tiger.

| Endpoint | What it does |
|---|---|
| `POST /prescriptions` | Save or update a scanned bottle (same fields as `Prescription`, plus `key`) |
| `POST /doses` | `{ prescriptionKey, takenAt, overrodeWarning }` — log a dose in the `dose_logs` hypertable |
| `GET /prescriptions/:key/daily?days=7` | Doses per day, from the `daily_doses` continuous aggregate |
| `GET /languages` | Supported languages |
| `GET /health` | Shows which keys are set (true/false) |

Requests are limited to 30 per minute per address.

Try it with the samples:

```bash
curl -X POST http://localhost:3000/readout -H "Content-Type: application/json" -d @samples/lisinopril.json
```

## Before the demo

Have a native speaker check each language in [src/templates.js](src/templates.js).
