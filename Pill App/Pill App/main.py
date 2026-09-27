"""
Pill App API

Runs on a Vultr instance. Stores prescriptions and every logged dose in Tiger Cloud
(TimescaleDB), and answers "is it too soon to take this?" from the full dose history,
so doses logged on any device count.

Env vars (see .env.example): DATABASE_URL (Tiger Cloud connection string), API_KEY
Run locally:  uvicorn main:app --reload
"""
import os
import secrets
from contextlib import asynccontextmanager
from datetime import datetime
from typing import Optional
from uuid import UUID

import asyncpg
from fastapi import Depends, FastAPI, Header, HTTPException, Query
from pydantic import BaseModel

DATABASE_URL = os.environ["DATABASE_URL"]
API_KEY = os.environ["API_KEY"]
pool: Optional[asyncpg.Pool] = None


@asynccontextmanager
async def lifespan(_app: FastAPI):
    global pool
    pool = await asyncpg.create_pool(DATABASE_URL, min_size=1, max_size=5)
    yield
    await pool.close()


app = FastAPI(title="Pill App API", lifespan=lifespan)


def patient(x_api_key: str = Header(...), x_patient_id: UUID = Header(...)) -> UUID:
    """Every request carries the app's API key and its random patient ID."""
    if not secrets.compare_digest(x_api_key, API_KEY):
        raise HTTPException(status_code=401, detail="Bad API key")
    return x_patient_id


def epoch(value: Optional[datetime]) -> Optional[float]:
    return value.timestamp() if value else None


# ---------------------------------------------------------------------------
# Models (snake_case, matching what the iOS app sends)
# ---------------------------------------------------------------------------
class PrescriptionIn(BaseModel):
    key: str
    drug_name: str
    dosage: Optional[str] = None
    quantity: Optional[int] = None
    instructions: Optional[str] = None
    take_with_food: Optional[bool] = None
    times_of_day: list[str] = []
    min_hours_between_doses: Optional[float] = None
    max_doses_per_day: Optional[int] = None
    as_needed: bool = False
    is_supplement: bool = False
    expiration_date: Optional[datetime] = None


class DoseIn(BaseModel):
    event_id: UUID
    prescription_key: str
    taken_at: datetime
    overrode_warning: bool = False
    source: str = "app"


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------
@app.get("/health")
async def health():
    await pool.fetchval("SELECT 1")
    return {"ok": True}


@app.post("/prescriptions")
async def upsert_prescription(rx: PrescriptionIn, patient_id: UUID = Depends(patient)):
    await pool.execute(
        """
        INSERT INTO prescriptions (patient_id, key, drug_name, dosage, quantity, instructions,
            take_with_food, times_of_day, min_hours_between_doses, max_doses_per_day,
            as_needed, is_supplement, expiration_date)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)
        ON CONFLICT (patient_id, key) DO UPDATE SET
            drug_name = EXCLUDED.drug_name, dosage = EXCLUDED.dosage, quantity = EXCLUDED.quantity,
            instructions = EXCLUDED.instructions, take_with_food = EXCLUDED.take_with_food,
            times_of_day = EXCLUDED.times_of_day,
            min_hours_between_doses = EXCLUDED.min_hours_between_doses,
            max_doses_per_day = EXCLUDED.max_doses_per_day, as_needed = EXCLUDED.as_needed,
            is_supplement = EXCLUDED.is_supplement, expiration_date = EXCLUDED.expiration_date,
            updated_at = now()
        """,
        patient_id, rx.key, rx.drug_name, rx.dosage, rx.quantity, rx.instructions,
        rx.take_with_food, rx.times_of_day, rx.min_hours_between_doses, rx.max_doses_per_day,
        rx.as_needed, rx.is_supplement, rx.expiration_date,
    )
    return {"ok": True}


@app.post("/doses")
async def log_dose(dose: DoseIn, patient_id: UUID = Depends(patient)):
    await pool.execute(
        """
        INSERT INTO dose_events (taken_at, patient_id, prescription_key, event_id, overrode_warning, source)
        VALUES ($1, $2, $3, $4, $5, $6)
        ON CONFLICT (event_id, taken_at) DO NOTHING
        """,
        dose.taken_at, patient_id, dose.prescription_key, dose.event_id,
        dose.overrode_warning, dose.source,
    )
    return {"ok": True}


@app.delete("/doses/{event_id}")
async def delete_dose(event_id: UUID, patient_id: UUID = Depends(patient)):
    await pool.execute(
        "DELETE FROM dose_events WHERE patient_id = $1 AND event_id = $2", patient_id, event_id
    )
    return {"ok": True}


@app.get("/check")
async def check(key: str, patient_id: UUID = Depends(patient)):
    """Before logging: is it too soon, or is today's limit reached? Uses every device's doses."""
    row = await pool.fetchrow("SELECT * FROM check_dose($1, $2)", patient_id, key)
    return {
        "status": row["status"],
        "last_taken": epoch(row["last_taken"]),
        "next_allowed": epoch(row["next_allowed"]),
        "doses_last_24h": row["doses_last_24h"],
        "daily_limit": row["daily_limit"],
    }


@app.get("/last-doses")
async def last_doses(patient_id: UUID = Depends(patient)):
    """When each medication was last taken."""
    rows = await pool.fetch(
        """
        SELECT prescription_key, max(taken_at) AS last_taken
        FROM dose_events
        WHERE patient_id = $1 AND taken_at > now() - INTERVAL '30 days'
        GROUP BY prescription_key
        """,
        patient_id,
    )
    return [{"key": r["prescription_key"], "last_taken": epoch(r["last_taken"])} for r in rows]


@app.get("/adherence")
async def adherence(days: int = Query(30, ge=1, le=365), patient_id: UUID = Depends(patient)):
    """Doses taken vs. expected per medication per day, from the continuous aggregate."""
    rows = await pool.fetch(
        """
        SELECT d.day, d.prescription_key, p.drug_name, d.doses_taken, d.overrides,
               CASE WHEN p.as_needed THEN NULL
                    ELSE COALESCE(NULLIF(cardinality(p.times_of_day), 0), p.max_doses_per_day, 1)
               END AS expected
        FROM daily_doses d
        LEFT JOIN prescriptions p ON p.patient_id = d.patient_id AND p.key = d.prescription_key
        WHERE d.patient_id = $1 AND d.day >= now() - make_interval(days => $2)
        ORDER BY d.day DESC, d.prescription_key
        """,
        patient_id, days,
    )
    return [
        {
            "day": r["day"].date().isoformat(),
            "key": r["prescription_key"],
            "drug_name": r["drug_name"],
            "doses_taken": r["doses_taken"],
            "expected": r["expected"],
            "overrides": r["overrides"],
        }
        for r in rows
    ]


@app.get("/adherence/summary")
async def adherence_summary(days: int = Query(7, ge=1, le=90), patient_id: UUID = Depends(patient)):
    """
    Doses taken vs. expected for each of the last `days` days (Atlanta time), for the Profile card.
    Reads the daily_doses continuous aggregate, so it stays fast however long the history gets.
    Days with no doses still count as missed once a medication has started being tracked.
    """
    rows = await pool.fetch(
        """
        WITH days AS (
            SELECT generate_series(
                date_trunc('day', now() AT TIME ZONE 'America/New_York') - make_interval(days => $2 - 1),
                date_trunc('day', now() AT TIME ZONE 'America/New_York'),
                INTERVAL '1 day') AS local_day
        ),
        rx AS (
            SELECT p.key,
                   CASE WHEN p.as_needed THEN 0
                        ELSE COALESCE(NULLIF(cardinality(p.times_of_day), 0), p.max_doses_per_day, 1)
                   END AS expected,
                   (SELECT min(e.taken_at) FROM dose_events e
                     WHERE e.patient_id = p.patient_id AND e.prescription_key = p.key) AS first_dose
            FROM prescriptions p
            WHERE p.patient_id = $1
        ),
        taken AS (
            SELECT day AT TIME ZONE 'America/New_York' AS local_day,
                   prescription_key, doses_taken, overrides
            FROM daily_doses
            WHERE patient_id = $1 AND day >= now() - make_interval(days => $2 + 1)
        )
        SELECT d.local_day::date                                               AS day,
               COALESCE(sum(LEAST(COALESCE(t.doses_taken, 0), rx.expected)), 0)::int AS taken,
               COALESCE(sum(rx.expected), 0)::int                              AS expected,
               COALESCE(sum(t.overrides), 0)::int                              AS overrides
        FROM days d
        CROSS JOIN rx
        LEFT JOIN taken t ON t.local_day = d.local_day AND t.prescription_key = rx.key
        WHERE rx.first_dose IS NOT NULL
          AND (rx.first_dose AT TIME ZONE 'America/New_York')::date <= d.local_day::date
        GROUP BY d.local_day
        ORDER BY d.local_day
        """,
        patient_id, days,
    )
    day_list = [
        {"day": r["day"].isoformat(), "taken": r["taken"], "expected": r["expected"], "overrides": r["overrides"]}
        for r in rows
    ]
    return {
        "days": day_list,
        "taken": sum(d["taken"] for d in day_list),
        "expected": sum(d["expected"] for d in day_list),
        "overrides": sum(d["overrides"] for d in day_list),
    }
