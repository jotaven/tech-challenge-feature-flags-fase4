"""Gera traces, métricas e logs sintéticos no formato dos serviços do ToggleMaster.

Serve para testar o OTel Collector, os dashboards e a regra de alerta de 5xx
antes de a instrumentação real dos microsserviços estar pronta.

Uso (a partir da raiz do repositório, com a stack local rodando):
    pip install opentelemetry-sdk opentelemetry-exporter-otlp-proto-grpc
    python observability/local/gerar_telemetria.py --segundos 120 --taxa-erro 0.2

Cada "requisição" simula evaluation-service -> flag-service -> auth-service,
com uma fração respondendo HTTP 500 no auth-service.
"""

import argparse
import logging
import random
import time

from opentelemetry import metrics, trace
from opentelemetry._logs import set_logger_provider
from opentelemetry.exporter.otlp.proto.grpc._log_exporter import OTLPLogExporter
from opentelemetry.exporter.otlp.proto.grpc.metric_exporter import OTLPMetricExporter
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk._logs import LoggerProvider, LoggingHandler
from opentelemetry.sdk._logs.export import BatchLogRecordProcessor
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.trace import SpanKind, Status, StatusCode

SERVICOS = ["evaluation-service", "flag-service", "auth-service"]


def provedores(servico, endpoint):
    recurso = Resource.create({"service.name": servico, "service.namespace": "togglemaster"})
    tp = TracerProvider(resource=recurso)
    tp.add_span_processor(BatchSpanProcessor(OTLPSpanExporter(endpoint=endpoint, insecure=True)))
    mp = MeterProvider(resource=recurso, metric_readers=[PeriodicExportingMetricReader(
        OTLPMetricExporter(endpoint=endpoint, insecure=True), export_interval_millis=5000)])
    lp = LoggerProvider(resource=recurso)
    lp.add_log_record_processor(BatchLogRecordProcessor(OTLPLogExporter(endpoint=endpoint, insecure=True)))
    return tp, mp, lp


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--endpoint", default="localhost:4317")
    ap.add_argument("--segundos", type=int, default=60)
    ap.add_argument("--taxa-erro", type=float, default=0.1, help="fração de 500 no auth-service")
    ap.add_argument("--rps", type=float, default=5.0)
    args = ap.parse_args()

    prov = {s: provedores(s, args.endpoint) for s in SERVICOS}
    tracers = {s: prov[s][0].get_tracer("gerar_telemetria") for s in SERVICOS}
    contadores = {s: prov[s][1].get_meter("gerar_telemetria").create_counter(
        "http.server.requests", description="requisições HTTP sintéticas") for s in SERVICOS}
    loggers = {}
    for s in SERVICOS:
        lg = logging.getLogger(s)
        lg.setLevel(logging.INFO)
        lg.addHandler(LoggingHandler(logger_provider=prov[s][2]))
        loggers[s] = lg

    def chamada(servico, rota, pai_ctx, status):
        with tracers[servico].start_as_current_span(
                f"GET {rota}", context=pai_ctx, kind=SpanKind.SERVER,
                attributes={"http.request.method": "GET", "http.route": rota,
                            "http.response.status_code": status}) as span:
            if status >= 500:
                span.set_status(Status(StatusCode.ERROR))
                loggers[servico].error("erro interno em %s (status %s)", rota, status)
            else:
                loggers[servico].info("%s respondeu %s", rota, status)
            contadores[servico].add(1, {"http.route": rota, "http.response.status_code": status})
            time.sleep(random.uniform(0.005, 0.03))
            return trace.set_span_in_context(span)

    fim = time.time() + args.segundos
    total = erros = 0
    while time.time() < fim:
        falha = random.random() < args.taxa_erro
        ctx = chamada("evaluation-service", "/evaluate", None, 502 if falha else 200)
        ctx = chamada("flag-service", "/flags/{name}", ctx, 401 if falha else 200)
        chamada("auth-service", "/validate", ctx, 500 if falha else 200)
        total += 1
        erros += falha
        time.sleep(1 / args.rps)

    for tp, mp, lp in prov.values():
        tp.shutdown()
        mp.shutdown()
        lp.shutdown()
    print(f"{total} requisições simuladas, {erros} com erro no auth-service")


if __name__ == "__main__":
    main()
