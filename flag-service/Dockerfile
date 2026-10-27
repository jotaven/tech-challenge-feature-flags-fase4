FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    libpq-dev \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd --gid 10001 app \
    && useradd --uid 10001 --gid 10001 --no-create-home --shell /usr/sbin/nologin app

COPY requirements.txt .

RUN pip install --no-cache-dir -r requirements.txt

COPY --chown=10001:10001 . .

USER 10001:10001

EXPOSE 8002

# OpenTelemetry: o destino (OTEL_EXPORTER_OTLP_ENDPOINT) e o nome do serviço
# (OTEL_SERVICE_NAME) vêm do Deployment ou do docker-compose.
ENV OTEL_TRACES_EXPORTER=otlp \
    OTEL_METRICS_EXPORTER=otlp \
    OTEL_LOGS_EXPORTER=none \
    OTEL_EXPORTER_OTLP_PROTOCOL=grpc \
    OTEL_SEMCONV_STABILITY_OPT_IN=http \
    OTEL_PYTHON_FLASK_EXCLUDED_URLS="health,live"

CMD ["opentelemetry-instrument", "python", "app.py"]
