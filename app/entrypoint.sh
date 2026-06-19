#!/bin/sh
set -e

# Wait for the database to accept connections, then ensure the schema exists.
# create_all() is idempotent (only creates missing tables), so it is safe to run
# on every container start. For richer schema evolution this is where a
# `flask db upgrade` (Alembic) step would go instead.
python - <<'PY'
import time
from app import create_app, db

app = create_app()
last_error = None
for attempt in range(1, 31):
    try:
        with app.app_context():
            db.create_all()
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
