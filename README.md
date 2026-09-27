# Pill Point

Pill Point helps people who take several medications take the right one, at the right time, without double-dosing.
Scan a pill bottle once; after that the app checks you're holding the right bottle in AR before logging a dose,
blocks doses taken too close together, identifies a dropped pill, and can call or message your provider's office.

## Features

| Feature | What it does | Built with |
|---|---|---|
| Bottle scanning | Reads CVS prescription and Nature Made labels: drug, strength, quantity, directions, expiration | AVFoundation, Vision |
| AR bottle check | Green card over the right bottle, red over wrong ones, before you can log a dose | ARKit, RealityKit, Vision |
| Overdose prevention | Blocks doses taken too soon or over the daily limit, across devices | Swift, Tiger Data |
| Pill identification | Matches a loose pill's shape, color, and imprint to your own medications | Vision, Core Image, NLM Pillbox data |
| Listen & Translate | Reads medication info aloud, translated on-device into 6 languages | Apple Translation, AVSpeechSynthesizer |
| Adherence | Streaks, calendar, and a 7-day chart from the cloud | SwiftUI, Swift Charts, Tiger Data |
| AI assistant | Answers medication questions and decides when to contact your provider | Google Gemini, OpenAI Whisper |
| Provider calls | Calls the office, records the answer, falls back to WhatsApp | Twilio, Whisper, Gemini, WhatsApp Cloud API |
| Cloud sync | Every dose stored in a time-series hypertable | Vultr, Tiger Data (TimescaleDB) |

## Repository layout

```
ios/            Xcode project (SwiftUI, iOS 18+)
backend/        Python FastAPI server (runs on Vultr), talks to Tiger Cloud
voice-server/   Node voice server (server.js)
schema.sql      Tiger Cloud tables and SQL functions
tools/          build_pillbox_index.py (prepares the NLM Pillbox data)
```

## Architecture

```
iPhone app (SwiftData, works offline)
   │  doses and bottles, queued and retried
   ▼
FastAPI server on Vultr
   │
   ▼
Tiger Cloud (TimescaleDB)
   prescriptions        one row per bottle
   dose_events          hypertable: every dose logged
   check_dose()         overdose check across all devices
   adherence_summary()  doses taken vs. expected per day (time_bucket)
```

## Setup

**Database (Tiger Cloud)**
1. Create a service and run `schema.sql` in the SQL editor.

**Backend (Vultr)**
1. Copy `backend/` to the server, `pip install -r requirements.txt`.
2. Copy `.env.example` to `.env` and fill in `DATABASE_URL` and `API_KEY`.
3. Run with `uvicorn main:app` (see `pillapp-api.service` and `Caddyfile` for running it as a service with HTTPS).

**iOS app**
1. Copy `Secrets.example.plist` to `Secrets.plist` in the Xcode project and fill in your keys.
2. Build `pillbox_index.json` with `python3 tools/build_pillbox_index.py pillbox.csv pillbox_index.json`
   (CSV from the NLM Pillbox Archived Data page) and add it to the app target.
3. Run on a real iPhone (camera, AR, and Vision features don't work in the Simulator).

## Privacy

- The cloud stores a random ID per install, never a name.
- Dose reminders don't name the medication on the lock screen.
- Rx numbers are only used as database keys and are never read aloud.
- WhatsApp messages are shown to you before anything is sent.
- Translation and text recognition run on the device.
- API keys live in `Secrets.plist` / `.env`, which are not committed.

## Team

- Prathithi — _role_
- _Name_ — _role_
- _Name_ — _role_
