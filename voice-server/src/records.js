// Saves prescriptions and logged doses from the app in Tiger Cloud,
// and reads them back (last dose, doses per day from the daily_doses aggregate).

import { db } from './db.js';

// Same fields and key as Prescription.swift. A rescan (refill) updates the row.
export async function savePrescription(rx) {
  await db.query(
    `INSERT INTO prescriptions (key, drug_name, dosage, quantity, pharmacy_name, pharmacy_address,
       prescriber, expiration_date, instructions, take_with_food, times_of_day, side_effects,
       min_hours_between_doses, max_doses_per_day, as_needed, last_scanned_at)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, now())
     ON CONFLICT (key) DO UPDATE SET
       drug_name = EXCLUDED.drug_name, dosage = EXCLUDED.dosage, quantity = EXCLUDED.quantity,
       pharmacy_name = EXCLUDED.pharmacy_name, pharmacy_address = EXCLUDED.pharmacy_address,
       prescriber = EXCLUDED.prescriber, expiration_date = EXCLUDED.expiration_date,
       instructions = EXCLUDED.instructions, take_with_food = EXCLUDED.take_with_food,
       times_of_day = EXCLUDED.times_of_day, side_effects = EXCLUDED.side_effects,
       min_hours_between_doses = EXCLUDED.min_hours_between_doses,
       max_doses_per_day = EXCLUDED.max_doses_per_day, as_needed = EXCLUDED.as_needed,
       last_scanned_at = now()`,
    [
      rx.key, rx.drugName, rx.dosage ?? null, rx.quantity ?? null, rx.pharmacyName ?? null,
      rx.pharmacyAddress ?? null, rx.prescriber ?? null, rx.expirationDate ?? null,
      rx.instructions ?? null, rx.takeWithFood ?? null, rx.timesOfDay ?? [], rx.sideEffects ?? [],
      rx.minHoursBetweenDoses ?? null, rx.maxDosesPerDay ?? null, rx.asNeeded ?? false,
    ]
  );
}

export async function logDose(prescriptionKey, takenAt, overrodeWarning = false) {
  await db.query(
    'INSERT INTO dose_logs (taken_at, prescription_key, overrode_warning) VALUES ($1, $2, $3)',
    [takenAt ?? new Date(), prescriptionKey, overrodeWarning]
  );
}

export async function lastDose(prescriptionKey) {
  const { rows } = await db.query(
    'SELECT max(taken_at) AS last FROM dose_logs WHERE prescription_key = $1',
    [prescriptionKey]
  );
  return rows[0]?.last ?? null;
}

// Doses per day for the last `days` days, from the daily_doses continuous aggregate.
export async function dailyDoses(prescriptionKey, days = 7) {
  const { rows } = await db.query(
    `SELECT day, doses_taken, warnings_overridden, last_dose_at
     FROM daily_doses
     WHERE prescription_key = $1 AND day >= now() - make_interval(days => $2)
     ORDER BY day DESC`,
    [prescriptionKey, days]
  );
  return rows;
}
