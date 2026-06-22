#!/bin/sh
set -e

# Wait for the database to accept connections, then ensure the schema exists.
# create_all() is idempotent (only creates missing tables), so it is safe to run
# on every container start. It does NOT, however, add new columns to tables that
# already exist — so additive column migrations are applied explicitly below
# (idempotent ADD COLUMN IF NOT EXISTS on Postgres). For richer schema evolution
# this is where a `flask db upgrade` (Alembic) step would go instead.
python - <<'PY'
import time
from sqlalchemy import text
from app import create_app, db

# Columns added after a table first shipped. create_all() won't add these to an
# existing table, so apply them idempotently. Skipped on SQLite (local/tests use
# a fresh create_all where the column already exists).
ADDITIVE_MIGRATIONS = [
    "ALTER TABLE profiles ADD COLUMN IF NOT EXISTS thumbnail_key VARCHAR(256)",
]

app = create_app()
last_error = None
for attempt in range(1, 31):
    try:
        with app.app_context():
            db.create_all()
            if db.engine.dialect.name == "postgresql":
                for stmt in ADDITIVE_MIGRATIONS:
                    db.session.execute(text(stmt))
                db.session.commit()
        print(f"Database ready; schema ensured (attempt {attempt})", flush=True)
        break
    except Exception as exc:  # noqa: BLE001
        last_error = exc
        print(f"Database not ready (attempt {attempt}/30): {exc}", flush=True)
        time.sleep(2)
else:
    raise SystemExit(f"Database never became ready: {last_error}")
PY

exec gunicorn --bind 0.0.0.0:5000 --workers 2 --timeout 60 app:app
