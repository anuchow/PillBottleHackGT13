-- Pill Point database (Tiger Cloud / TimescaleDB)
-- Mirrors the Prescription and DoseLog models in the iOS app.

-- One row per pill bottle. `key` is the same "<PHARMACY>-<RX NUMBER>" key the app uses,
-- so rescanning a refill updates the row instead of adding a new one.
CREATE TABLE prescriptions (
    key                      TEXT PRIMARY KEY,
    drug_name                TEXT NOT NULL,
    dosage                   TEXT,
    quantity                 INT,
    pharmacy_name            TEXT,
    pharmacy_address         TEXT,
    prescriber               TEXT,
    expiration_date          DATE,
    instructions             TEXT,
    take_with_food           BOOLEAN,
    times_of_day             TEXT[] NOT NULL DEFAULT '{}',
    side_effects             TEXT[] NOT NULL DEFAULT '{}',
    min_hours_between_doses  DOUBLE PRECISION,
    max_doses_per_day        INT,
    as_needed                BOOLEAN NOT NULL DEFAULT false,
    last_scanned_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- One row per dose the user logs. A hypertable splits it into time chunks
-- automatically, so "doses in the last 24 hours" stays fast as the log grows.
CREATE TABLE dose_logs (
    taken_at          TIMESTAMPTZ NOT NULL,
    prescription_key  TEXT NOT NULL REFERENCES prescriptions (key) ON DELETE CASCADE,
    overrode_warning  BOOLEAN NOT NULL DEFAULT false
) WITH (
    tsdb.hypertable,
    tsdb.partition_column = 'taken_at'
);

-- "When was the last dose of this prescription?"
CREATE INDEX dose_logs_prescription_time ON dose_logs (prescription_key, taken_at DESC);

-- Doses per prescription per day (Atlanta time), kept up to date by TimescaleDB.
CREATE MATERIALIZED VIEW daily_doses
WITH (timescaledb.continuous) AS
SELECT
    time_bucket(INTERVAL '1 day', taken_at, 'America/New_York') AS day,
    prescription_key,
    count(*)                                  AS doses_taken,
    count(*) FILTER (WHERE overrode_warning)  AS warnings_overridden,
    min(taken_at)                             AS first_dose_at,
    max(taken_at)                             AS last_dose_at
FROM dose_logs
GROUP BY day, prescription_key
WITH NO DATA;

-- Refresh every 15 minutes.
SELECT add_continuous_aggregate_policy('daily_doses',
    start_offset      => NULL,
    end_offset        => INTERVAL '15 minutes',
    schedule_interval => INTERVAL '15 minutes');

-- Also include doses logged since the last refresh, so a dose shows up immediately.
ALTER MATERIALIZED VIEW daily_doses SET (timescaledb.materialized_only = false);

-- Grok translations, saved so each label line is only translated once per language.
CREATE TABLE translations (
    source_text      TEXT NOT NULL,
    language         TEXT NOT NULL CHECK (language IN ('es', 'hi', 'zh', 'vi', 'ko')),
    translated_text  TEXT NOT NULL,
    model            TEXT,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (source_text, language)
);
