// Connection to the Tiger Cloud database (DATABASE_URL in .env).
// If DATABASE_URL is empty, `db` is null and the server runs without saving anything.

import pg from 'pg';

export const db = process.env.DATABASE_URL
  ? new pg.Pool({ connectionString: process.env.DATABASE_URL })
  : null;
