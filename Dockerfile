# --- Build Stage ---
FROM python:3.11-slim AS builder
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends gcc build-essential && rm -rf /var/lib/apt/lists/*
COPY requirements.txt .
RUN pip install --no-cache-dir --user -r requirements.txt

# --- Runtime Stage ---
FROM python:3.11-slim AS runner

# Run as an unprivileged user (defense in depth)
RUN useradd --create-home --uid 10001 appuser

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends curl && rm -rf /var/lib/apt/lists/*

# Copy installed deps into the non-root user's home, plus the app code
COPY --from=builder /root/.local /home/appuser/.local
COPY app/ ./

RUN chmod +x ./entrypoint.sh && chown -R appuser:appuser /app /home/appuser/.local

# HOME must point at appuser so Python resolves the user site-packages (.local)
ENV HOME=/home/appuser
ENV PATH=/home/appuser/.local/bin:$PATH
ENV PYTHONPATH=/home/appuser/.local/lib/python3.11/site-packages
ENV FLASK_ENV=Production
ENV PORT=5000

USER appuser

EXPOSE 5000

HEALTHCHECK --interval=30s --timeout=5s --start-period=40s --retries=3 \
    CMD curl -f http://localhost:5000/health || exit 1

# entrypoint.sh ensures the DB schema, then launches gunicorn
ENTRYPOINT ["./entrypoint.sh"]
