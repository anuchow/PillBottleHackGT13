// Pill App API (Node version of main.py). Runs on Vultr at port 3001, stores data in Tiger Data.
// Works with the new CloudSync.swift (snake_case bodies, x-patient-id header)
// and still accepts the older TigerSync.swift requests.
import "dotenv/config";
import express from "express";
import pg from "pg";

const pool = new pg.Pool({ connectionString: process.env.DATABASE_URL });
const app = express();
app.use(express.json());

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const epoch = (d) => (d ? new Date(d).getTime() / 1000 : null);
const pick = (obj, snake, camel) => (obj[snake] !== undefined ? obj[snake] : obj[camel]);

app.get("/health", async (req, res) => {
  try {
    await pool.query("SELECT 1");
    res.json({ ok: true, database: "connected" });
  } catch (e) {
    res.status(500).json({ ok: false, error: e.message });
  }
});

// API key on everything else
app.use((req, res, next) => {
  if (req.get("x-api-key") !== process.env.API_KEY) return res.status(401).json({ error: "Bad API key" });
  next();
});

// Patient ID comes from the x-patient-id header (new app) or the body/query (old app)
function patientId(req) {
  const id = req.get("x-patient-id") || req.body?.patientId || req.query.patientId;
  return id && UUID_RE.test(id) ? id : null;
}

const wrap = (fn) => async (req, res) => {
  try {
    await fn(req, res);
  } catch (e) {
    console.error(req.method, req.path, e.message);
    res.status(500).json({ error: e.message });
  }
};

// Save or update a bottle
async function upsertPrescription(req, res) {
  const pid = patientId(req);
  const b = req.body || {};
  const key = b.key;
  const drugName = pick(b, "drug_name", "drugName");
  if (!pid || !key || !drugName) return res.status(400).json({ error: "patient id, key and drug_name are required" });
  await pool.query(
    `INSERT INTO public.prescriptions
       (patient_id, key, drug_name, dosage, quantity, instructions, take_with_food, times_of_day,
        min_hours_between_doses, max_doses_per_day, as_needed, is_supplement, expiration_date)
     VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13)
     ON CONFLICT (patient_id, key) DO UPDATE SET
       drug_name = EXCLUDED.drug_name, dosage = EXCLUDED.dosage, quantity = EXCLUDED.quantity,
       instructions = EXCLUDED.instructions, take_with_food = EXCLUDED.take_with_food,
       times_of_day = EXCLUDED.times_of_day,
       min_hours_between_doses = EXCLUDED.min_hours_between_doses,
       max_doses_per_day = EXCLUDED.max_doses_per_day, as_needed = EXCLUDED.as_needed,
       is_supplement = EXCLUDED.is_supplement, expiration_date = EXCLUDED.expiration_date,
       updated_at = now()`,
    [
      pid, key, drugName, b.dosage ?? null, b.quantity ?? null, b.instructions ?? null,
      pick(b, "take_with_food", "takeWithFood") ?? null,
      pick(b, "times_of_day", "timesOfDay") ?? [],
      pick(b, "min_hours_between_doses", "minHoursBetweenDoses") ?? null,
      pick(b, "max_doses_per_day", "maxDosesPerDay") ?? null,
      pick(b, "as_needed", "asNeeded") ?? false,
      pick(b, "is_supplement", "isSupplement") ?? false,
      pick(b, "expiration_date", "expirationDate") ?? null,
    ]
  );
  res.json({ ok: true });
}
app.post("/prescriptions", wrap(upsertPrescription));
app.put("/prescriptions", wrap(upsertPrescription));

// Record a dose. Same event_id twice is ignored.
app.post("/doses", wrap(async (req, res) => {
  const pid = patientId(req);
  const b = req.body || {};
  const eventId = pick(b, "event_id", "eventId");
  const key = b.prescription_key ?? b.key;
  const takenAt = pick(b, "taken_at", "takenAt");
  if (!pid || !eventId || !key || !takenAt) return res.status(400).json({ error: "patient id, event_id, prescription_key and taken_at are required" });
  await pool.query(
    `INSERT INTO public.dose_events (taken_at, patient_id, prescription_key, event_id, overrode_warning, source)
     VALUES ($1,$2,$3,$4,$5,$6)
     ON CONFLICT DO NOTHING`,
    [takenAt, pid, key, eventId, pick(b, "overrode_warning", "overrodeWarning") ?? false, b.source ?? "app"]
  );
  res.json({ ok: true });
}));

// Every dose in the last N days, so the phone can match the database
app.get("/doses", wrap(async (req, res) => {
  const pid = patientId(req);
  const days = Math.min(Math.max(parseInt(req.query.days) || 60, 1), 365);
  if (!pid) return res.status(400).json({ error: "patient id required" });
  const { rows } = await pool.query(
    `SELECT event_id, prescription_key, taken_at, overrode_warning
     FROM public.dose_events
     WHERE patient_id = $1::uuid AND taken_at > now() - make_interval(days => $2::int)
     ORDER BY taken_at`,
    [pid, days]
  );
  res.json(rows.map((r) => ({
    event_id: r.event_id, key: r.prescription_key,
    taken_at: epoch(r.taken_at), overrode_warning: r.overrode_warning,
  })));
}));

// Undo a dose
app.delete("/doses/:eventId", wrap(async (req, res) => {
  const pid = patientId(req);
  if (!pid || !UUID_RE.test(req.params.eventId)) return res.status(400).json({ error: "bad ids" });
  await pool.query("DELETE FROM public.dose_events WHERE patient_id = $1 AND event_id = $2", [pid, req.params.eventId]);
  res.json({ ok: true });
}));

// Is it too soon? Counts doses from every device.
async function check(req, res, epochDates) {
  const pid = patientId(req);
  const key = req.query.key;
  if (!pid || !key) return res.status(400).json({ error: "patient id and key are required" });
  const { rows } = await pool.query("SELECT * FROM public.check_dose($1::uuid, $2::text)", [pid, key]);
  const r = rows[0];
  if (!epochDates) return res.json(r);
  res.json({
    status: r.status,
    last_taken: epoch(r.last_taken),
    next_allowed: epoch(r.next_allowed),
    doses_last_24h: r.doses_last_24h,
    daily_limit: r.daily_limit,
  });
}
app.get("/check", wrap((req, res) => check(req, res, true)));
app.get("/check-dose", wrap((req, res) => check(req, res, false)));

// When each medication was last taken
app.get("/last-doses", wrap(async (req, res) => {
  const pid = patientId(req);
  if (!pid) return res.status(400).json({ error: "patient id required" });
  const { rows } = await pool.query(
    `SELECT prescription_key, max(taken_at) AS last_taken
     FROM public.dose_events
     WHERE patient_id = $1 AND taken_at > now() - INTERVAL '30 days'
     GROUP BY prescription_key`,
    [pid]
  );
  res.json(rows.map((r) => ({ key: r.prescription_key, last_taken: epoch(r.last_taken) })));
}));

// Per-day, per-medication history from the continuous aggregate
app.get("/adherence", wrap(async (req, res) => {
  const pid = patientId(req);
  const days = Math.min(Math.max(parseInt(req.query.days) || 30, 1), 365);
  if (!pid) return res.status(400).json({ error: "patient id required" });
  const { rows } = await pool.query(
    `SELECT to_char(d.day AT TIME ZONE 'America/New_York', 'YYYY-MM-DD') AS day,
            d.prescription_key, p.drug_name, d.doses_taken, d.overrides,
            CASE WHEN p.as_needed THEN NULL
                 ELSE COALESCE(NULLIF(cardinality(p.times_of_day), 0), p.max_doses_per_day, 1)
            END AS expected
     FROM public.daily_doses d
     LEFT JOIN public.prescriptions p ON p.patient_id = d.patient_id AND p.key = d.prescription_key
     WHERE d.patient_id = $1 AND d.day >= now() - make_interval(days => $2::int)
     ORDER BY d.day DESC, d.prescription_key`,
    [pid, days]
  );
  res.json(rows.map((r) => ({
    day: r.day, key: r.prescription_key, drug_name: r.drug_name,
    doses_taken: Number(r.doses_taken), expected: r.expected, overrides: Number(r.overrides),
  })));
}));

// Last N days, taken vs expected, for the Profile card
app.get("/adherence/summary", wrap(async (req, res) => {
  const pid = patientId(req);
  const days = Math.min(Math.max(parseInt(req.query.days) || 7, 1), 90);
  if (!pid) return res.status(400).json({ error: "patient id required" });
  const { rows } = await pool.query(
    `WITH days AS (
        SELECT generate_series(
            date_trunc('day', now() AT TIME ZONE 'America/New_York') - make_interval(days => $2::int - 1),
            date_trunc('day', now() AT TIME ZONE 'America/New_York'),
            INTERVAL '1 day') AS local_day
     ),
     rx AS (
        SELECT p.key,
               CASE WHEN p.as_needed THEN 0
                    ELSE COALESCE(NULLIF(cardinality(p.times_of_day), 0), p.max_doses_per_day, 1)
               END AS expected,
               (SELECT min(e.taken_at) FROM public.dose_events e
                 WHERE e.patient_id = p.patient_id AND e.prescription_key = p.key) AS first_dose
        FROM public.prescriptions p
        WHERE p.patient_id = $1::uuid
     ),
     taken AS (
        SELECT day AT TIME ZONE 'America/New_York' AS local_day,
               prescription_key, doses_taken, overrides
        FROM public.daily_doses
        WHERE patient_id = $1::uuid AND day >= now() - make_interval(days => $2::int + 1)
     )
     SELECT to_char(d.local_day, 'YYYY-MM-DD')                                    AS day,
            (d.local_day = date_trunc('day', now() AT TIME ZONE 'America/New_York'))  AS is_today,
            COALESCE(sum(LEAST(COALESCE(t.doses_taken, 0), rx.expected)), 0)::int AS taken,
            COALESCE(sum(rx.expected), 0)::int                                    AS expected,
            COALESCE(sum(t.overrides), 0)::int                                    AS overrides
     FROM days d
     CROSS JOIN rx
     LEFT JOIN taken t ON t.local_day = d.local_day AND t.prescription_key = rx.key
     WHERE rx.first_dose IS NOT NULL
       AND (rx.first_dose AT TIME ZONE 'America/New_York')::date <= d.local_day::date
     GROUP BY d.local_day
     ORDER BY d.local_day`,
    [pid, days]
  );
  // Same rule as the phone's streak card: today isn't judged until it's finished.
  // So an unfinished today shows no "missed" doses and isn't counted in the totals.
  const dayList = rows.map((r) => {
    const unfinishedToday = r.is_today && r.taken < r.expected;
    return {
      day: r.day,
      taken: r.taken,
      expected: unfinishedToday ? r.taken : r.expected,
      overrides: r.overrides,
      counted: !unfinishedToday,
    };
  });
  const counted = dayList.filter((d) => d.counted);
  res.json({
    days: dayList.map(({ counted, ...d }) => d),
    taken: counted.reduce((s, d) => s + d.taken, 0),
    expected: counted.reduce((s, d) => s + d.expected, 0),
    overrides: dayList.reduce((s, d) => s + d.overrides, 0),
  });
}));

const port = process.env.PORT || 3001;
app.listen(port, "0.0.0.0", () => console.log(`pill-api listening on ${port}`));
