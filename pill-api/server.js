// Small API between the iPhone app and Tiger Data.
// The phone never sees DATABASE_URL. It only sends the API_KEY header.
import "dotenv/config";
import express from "express";
import pg from "pg";

const pool = new pg.Pool({ connectionString: process.env.DATABASE_URL });
const app = express();
app.use(express.json());

// Open check so you can test the server from a browser
app.get("/health", async (req, res) => {
  try {
    await pool.query("SELECT 1");
    res.json({ ok: true, database: "connected" });
  } catch (e) {
    res.status(500).json({ ok: false, error: e.message });
  }
});

// Every other route needs the API key
app.use((req, res, next) => {
  if (req.get("x-api-key") !== process.env.API_KEY) {
    return res.status(401).json({ error: "bad api key" });
  }
  next();
});

// Save or update a scanned bottle
app.put("/prescriptions", async (req, res) => {
  const p = req.body;
  if (!p.patientId || !p.key || !p.drugName) {
    return res.status(400).json({ error: "patientId, key and drugName are required" });
  }
  try {
    await pool.query(
      `INSERT INTO public.prescriptions
         (patient_id, key, drug_name, dosage, quantity, instructions, take_with_food,
          times_of_day, min_hours_between_doses, max_doses_per_day, as_needed,
          is_supplement, expiration_date, updated_at)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13, now())
       ON CONFLICT (patient_id, key) DO UPDATE SET
         drug_name = EXCLUDED.drug_name,
         dosage = EXCLUDED.dosage,
         quantity = EXCLUDED.quantity,
         instructions = EXCLUDED.instructions,
         take_with_food = EXCLUDED.take_with_food,
         times_of_day = EXCLUDED.times_of_day,
         min_hours_between_doses = EXCLUDED.min_hours_between_doses,
         max_doses_per_day = EXCLUDED.max_doses_per_day,
         as_needed = EXCLUDED.as_needed,
         is_supplement = EXCLUDED.is_supplement,
         expiration_date = EXCLUDED.expiration_date,
         updated_at = now()`,
      [
        p.patientId, p.key, p.drugName, p.dosage ?? null, p.quantity ?? null,
        p.instructions ?? null, p.takeWithFood ?? null, p.timesOfDay ?? [],
        p.minHoursBetweenDoses ?? null, p.maxDosesPerDay ?? null,
        p.asNeeded ?? false, p.isSupplement ?? false, p.expirationDate ?? null,
      ]
    );
    res.json({ ok: true });
  } catch (e) {
    console.error(e);
    res.status(500).json({ error: e.message });
  }
});

// Record one dose. Sending the same eventId twice is safe (no duplicate).
app.post("/doses", async (req, res) => {
  const d = req.body;
  if (!d.patientId || !d.key || !d.eventId || !d.takenAt) {
    return res.status(400).json({ error: "patientId, key, eventId and takenAt are required" });
  }
  try {
    await pool.query(
      `INSERT INTO public.dose_events
         (taken_at, patient_id, prescription_key, event_id, overrode_warning, source)
       VALUES ($1,$2,$3,$4,$5,'app')
       ON CONFLICT DO NOTHING`,
      [d.takenAt, d.patientId, d.key, d.eventId, d.overrodeWarning ?? false]
    );
    res.json({ ok: true });
  } catch (e) {
    console.error(e);
    res.status(500).json({ error: e.message });
  }
});

// Ask the database if it's safe to take a dose right now
app.get("/check-dose", async (req, res) => {
  const { patientId, key } = req.query;
  if (!patientId || !key) return res.status(400).json({ error: "patientId and key are required" });
  try {
    const { rows } = await pool.query("SELECT * FROM public.check_dose($1, $2)", [patientId, key]);
    res.json(rows[0]);
  } catch (e) {
    console.error(e);
    res.status(500).json({ error: e.message });
  }
});

const port = process.env.PORT || 3000;
app.listen(port, "0.0.0.0", () => console.log(`pill-api listening on ${port}`));
