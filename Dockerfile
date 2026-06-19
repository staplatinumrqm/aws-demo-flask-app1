# --- Build Stage ---
FROM python:3.11-slim AS builder
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends gcc build-essential && rm -rf /var/lib/apt/lists/*
COPY requirements.txt .
RUN pip install --no-cache-dir --user -r requirements.txt

# --- Runtime Stage ---
FROM python:3.11-slim AS runner
WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends curl && rm -rf /var/lib/apt/lists/*

COPY --from=builder /root/.local /root/.local
COPY app/ ./

RUN chmod +x ./entrypoint.sh

ENV PATH=/root/.local/bin:$PATH
ENV FLASK_ENV=Production
ENV PORT=5000

EXPOSE 5000

# entrypoint.sh ensures the DB schema, then launches gunicorn
ENTRYPOINT ["./entrypoint.sh"]
