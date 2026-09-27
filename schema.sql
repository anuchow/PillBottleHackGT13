-- Pill Point database on Tiger Cloud (TimescaleDB).
-- Run in the Tiger Cloud SQL editor. The editor runs one statement at a time,
-- so run each statement separately (or use "Run all" if your editor has it).

CREATE EXTENSION IF NOT EXISTS timescaledb;

-- One row per bottle. patient_id is a random ID per app install (no names stored).
CREATE TABLE IF NOT EXISTS public.prescriptions (
    patient_id               UUID        NOT NULL,
    key                      TEXT        NOT NULL,       -- "CVS PHARMACY-1234567" / "NATURE MADE-LIST-12345"
    drug_name                TEXT        NOT NULL,
    dosage                   TEXT,
    quantity                 INT,
    instructions             TEXT,
    take_with_food           BOOLEAN,
    times_of_day             TEXT[]      NOT NULL DEFAULT '{}',
    min_hours_between_doses  DOUBLE PRECISION,
    max_doses_per_day        INT,
    as_needed                BOOLEAN     NOT NULL DEFAULT false,
    is_supplement            BOOLEAN     NOT NULL DEFAULT false,
    expiration_date          TIMESTAMPTZ,
    updated_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (patient_id, key)
);

-- Every dose taken: time-series data, stored in a hypertable.
CREATE TABLE IF NOT EXISTS public.dose_events (
    taken_at          TIMESTAMPTZ NOT NULL,
    patient_id        UUID        NOT NULL,
    prescription_key  TEXT        NOT NULL,
    event_id          UUID        NOT NULL,               -- made on the phone, so retries don't double-log
    overrode_warning  BOOLEAN     NOT NULL DEFAULT false, -- logged anyway after "Dose may be too soon"
    source            TEXT        NOT NULL DEFAULT 'app'  -- 'ar_check', 'pill_scan', 'app', 'backfill'
);

SELECT create_hypertable('public.dose_events', by_range('taken_at', INTERVAL '7 days'), if_not_exists => TRUE);

CREATE UNIQUE INDEX IF NOT EXISTS dose_events_event_id ON public.dose_events (event_id, taken_at);
CREATE INDEX IF NOT EXISTS dose_events_lookup ON public.dose_events (patient_id, prescription_key, taken_at DESC);

-- Overdose check: same rules as the app, but sees doses logged from every device.
-- Only scans the last 48 hours, so only the newest chunks of the hypertable are read.
CREATE OR REPLACE FUNCTION public.check_dose(p_patient UUID, p_key TEXT, p_at TIMESTAMPTZ DEFAULT now())
RETURNS TABLE (status TEXT, last_taken TIMESTAMPTZ, next_allowed TIMESTAMPTZ, doses_last_24h INT, daily_limit INT)
LANGUAGE sql STABLE AS $$
    WITH rx AS (
        SELECT min_hours_between_doses AS min_hours, max_doses_per_day AS max_per_day
        FROM public.prescriptions
        WHERE patient_id = p_patient AND key = p_key
    ),
    recent AS (
        SELECT max(taken_at)                                                      AS last_taken,
               count(*) FILTER (WHERE taken_at > p_at - INTERVAL '24 hours')      AS n24,
               min(taken_at) FILTER (WHERE taken_at > p_at - INTERVAL '24 hours') AS oldest24
        FROM public.dose_events
        WHERE patient_id = p_patient AND prescription_key = p_key
          AND taken_at > p_at - INTERVAL '48 hours' AND taken_at <= p_at
    ),
    verdict AS (
        SELECT recent.*, rx.min_hours, rx.max_per_day,
               (rx.min_hours IS NOT NULL AND recent.last_taken IS NOT NULL
                AND p_at < recent.last_taken + make_interval(secs => rx.min_hours * 3600)) AS too_soon,
               (rx.max_per_day IS NOT NULL AND recent.n24 >= rx.max_per_day)            AS at_limit
        FROM recent LEFT JOIN rx ON true
    )
    SELECT CASE WHEN too_soon THEN 'too_soon' WHEN at_limit THEN 'daily_limit' ELSE 'ok' END,
           last_taken,
           CASE WHEN too_soon THEN last_taken + make_interval(secs => min_hours * 3600)
                WHEN at_limit THEN oldest24 + INTERVAL '24 hours' END,
           n24::int,
           max_per_day
    FROM verdict;
$$;

-- "Last 7 days" on the Profile screen: doses taken vs. expected per day, grouped with time_bucket.
CREATE OR REPLACE FUNCTION public.adherence_summary(p_patient UUID, p_days INT DEFAULT 7)
RETURNS TABLE (day DATE, taken INT, expected INT, overrides INT)
LANGUAGE sql STABLE AS $$
    WITH days AS (
        SELECT generate_series(
            date_trunc('day', now() AT TIME ZONE 'America/New_York') - make_interval(days => p_days - 1),
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
        WHERE p.patient_id = p_patient
    ),
    t AS (
        SELECT time_bucket(INTERVAL '1 day', taken_at, 'America/New_York') AT TIME ZONE 'America/New_York' AS local_day,
               prescription_key,
               count(*) AS doses_taken,
               count(*) FILTER (WHERE overrode_warning) AS overrides
        FROM public.dose_events
        WHERE patient_id = p_patient AND taken_at >= now() - make_interval(days => p_days + 1)
        GROUP BY 1, 2
    )
    SELECT d.local_day::date,
           COALESCE(sum(LEAST(COALESCE(t.doses_taken, 0), rx.expected)), 0)::int,
           COALESCE(sum(rx.expected), 0)::int,
           COALESCE(sum(t.overrides), 0)::int
    FROM days d
    CROSS JOIN rx
    LEFT JOIN t ON t.local_day = d.local_day AND t.prescription_key = rx.key
    WHERE rx.first_dose IS NOT NULL
      AND (rx.first_dose AT TIME ZONE 'America/New_York')::date <= d.local_day::date
    GROUP BY d.local_day
    ORDER BY d.local_day;
$$;
